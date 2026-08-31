# Makefile — the project control panel.
#
# Everything is declarative and repeatable: these targets wrap the kind / docker
# / helm / kubectl commands so the whole cluster can be built, torn down, and
# rebuilt with single words. Nothing is configured by hand-editing live cluster
# state — the Helm chart in charts/ is the source of truth for the app.
#
# Phase 3 packaged the app as a Helm chart (charts/) installed as two side-by-side
# releases — a lean `dev` and a bigger `prod`, each in its own namespace. Phase 4
# then handed the actual deploy to GitOps: Argo CD watches this repo and reconciles
# the cluster to the chart on `main`, so `up` installs Argo and bootstraps an
# app-of-apps instead of running `helm install` itself. The raw manifests in k8s/
# are kept as the Phase 1/2 reference; k8s/ingress-nginx/ is still installed
# directly (cluster-level infra, not part of the app chart).
#
# Typical first run:
#   make up            # cluster, build+load image, ingress, Argo CD, app-of-apps
#   kubectl -n argocd get applications   # watch dev + prod + monitoring go Synced/Healthy
#   make seed && make seed-dev           # demo links through both hosts
#   open http://urlshortener.localtest.me          (prod)
#   open http://dev.urlshortener.localtest.me      (dev)
#   make argocd-ui                       # the Argo CD dashboard
#   make grafana-ui                      # Prometheus/Grafana observability (Phase 5)
#
# Tear it all down with `make down`.

CLUSTER   := url-shortener
IMAGE     := url-shortener:dev
CHART     := charts/url-shortener
NS_DEV    := url-shortener-dev
NS_PROD   := url-shortener-prod
NS_EKS    := url-shortener-eks
EKS_CLUSTER := url-shortener-k8s-eks
HOST_DEV  := dev.urlshortener.localtest.me
HOST_PROD := urlshortener.localtest.me

# Argo CD is pinned to a specific release so an install is reproducible. The full
# install.yaml is ~19k lines, so (unlike the vendored ingress-nginx manifest) we
# apply it straight from the pinned upstream URL instead of committing it.
ARGOCD_VERSION := v3.4.5
ARGOCD_MANIFEST := https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml

.PHONY: help cluster-up cluster-down build load ingress-install \
        lint ci-validate template helm-dev helm-prod up down uninstall \
        argocd-install argocd-bootstrap argocd-password argocd-ui gitops-up \
        grafana-ui prometheus-ui load-demo \
        load-test hpa-watch \
        status logs port-forward seed seed-dev restart-app \
        eks-init eks-plan eks-up eks-kubeconfig eks-ingress eks-bootstrap \
        eks-url eks-status eks-seed eks-load-test eks-hpa-watch eks-down

# Load-test knobs (Phase 6). Override on the command line, e.g.
#   make load-test LOAD_CONCURRENCY=80 LOAD_DURATION=600
# LOAD_DURATION is in seconds (busybox `sleep` in the alpine pod takes no suffix).
LOAD_CONCURRENCY ?= 40
LOAD_DURATION    ?= 300

# The load generator image.
#
# NOT williamyeh/hey, which this used to be. That image is published for
# linux/amd64 ONLY (single-arch manifest, no manifest list) — and every node this
# project runs on is arm64: kind on Colima (Apple Silicon) and the EKS Graviton
# (t4g) node group alike. The pod fails to start with the same error the app
# image hit in Phase 7: "no match for platform in manifest".
#
# alpine is an official multi-arch image, so a pod running parallel busybox wget
# loops works unchanged on both clusters. It gives up hey's latency histogram,
# but the job here is to generate CPU pressure and trip the HPA — and it removes
# an architecture assumption rather than adding one.
LOAD_IMAGE ?= alpine:3

# Shell run inside that pod: fan out $(LOAD_CONCURRENCY) request loops, hold them
# for $(LOAD_DURATION) seconds, then exit so `--rm` cleans the pod up.
define LOAD_SCRIPT
for i in $$(seq 1 $(LOAD_CONCURRENCY)); do \
  (while true; do wget -q -O- $(1)/healthz >/dev/null 2>&1; done) & \
done; \
sleep $(LOAD_DURATION)
endef

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

cluster-up: ## Create the kind cluster (idempotent)
	@kind get clusters | grep -qx $(CLUSTER) \
		&& echo "cluster '$(CLUSTER)' already exists" \
		|| kind create cluster --name $(CLUSTER) --config kind-config.yaml

cluster-down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

build: ## Build the app container image
	docker build -t $(IMAGE) ./app

load: build ## Load the image into the kind cluster (no registry needed)
	kind load docker-image $(IMAGE) --name $(CLUSTER)

ingress-install: ## Install the ingress-nginx controller (vendored, pinned)
	kubectl apply -f k8s/ingress-nginx/controller.yaml
	kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

lint: ## Validate the chart renders for both environments
	helm lint $(CHART) -f $(CHART)/values-dev.yaml
	helm lint $(CHART) -f $(CHART)/values-prod.yaml

template: ## Render the chart to stdout (dry run, no cluster needed)
	helm template prod $(CHART) -f $(CHART)/values-prod.yaml

# ci-validate mirrors exactly what the `validate` job in .github/workflows/ci.yml
# runs, so you can catch a broken chart before pushing. Needs kubeconform on PATH
# (brew install kubeconform). The CRD schema-location lets it validate the
# ServiceMonitor (a Prometheus CRD, not core Kubernetes).
CRD_SCHEMA := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
ci-validate: lint ## Run the CI validation locally (helm lint + kubeconform on both envs)
	@for env in dev prod; do \
		echo "== kubeconform $$env =="; \
		helm template $$env $(CHART) -f $(CHART)/values-$$env.yaml \
			| kubeconform -strict -summary \
				-schema-location default \
				-schema-location '$(CRD_SCHEMA)' \
				-ignore-missing-schemas; \
	done

# helm-dev / helm-prod are the Phase-3 manual deploy path, kept for reference and
# for `helm template`/debugging. Since Phase 4, Argo CD owns the live releases, so
# these are NOT part of `up` — running them would create a second owner that fights
# Argo's self-heal. Use them only against a cluster where Argo isn't managing the app.
helm-dev: ## (manual/reference — Argo owns the live release) install the lean dev release
	helm upgrade --install dev $(CHART) -n $(NS_DEV) --create-namespace -f $(CHART)/values-dev.yaml
	kubectl -n $(NS_DEV) rollout status deployment/dev-url-shortener --timeout=120s

helm-prod: ## (manual/reference — Argo owns the live release) install the prod release
	helm upgrade --install prod $(CHART) -n $(NS_PROD) --create-namespace -f $(CHART)/values-prod.yaml
	kubectl -n $(NS_PROD) rollout status deployment/prod-url-shortener --timeout=120s

# --- GitOps / Argo CD (Phase 4) ---------------------------------------------
# The cluster PULLS its desired state from git instead of us pushing it. Argo CD
# watches this repo and reconciles the app-of-apps (gitops/) to match `main`.

argocd-install: ## Install Argo CD (pinned version) into the argocd namespace
	kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd
	# --server-side: the ApplicationSet CRD is larger than the 256KB limit on the
	# last-applied-config annotation that a client-side `kubectl apply` would write,
	# so a plain apply fails on it. Server-side apply doesn't use that annotation.
	kubectl apply -n argocd --server-side -f $(ARGOCD_MANIFEST)
	kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

argocd-bootstrap: ## Apply the AppProjects + app-of-apps root (Argo then deploys dev + prod + monitoring)
	kubectl apply -f gitops/project.yaml
	kubectl apply -f gitops/project-platform.yaml
	kubectl apply -f gitops/root-app.yaml
	@echo "Bootstrapped. Watch it converge:  kubectl -n argocd get applications -w"

argocd-password: ## Print the initial Argo CD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d && echo

argocd-ui: ## Port-forward the Argo CD UI to https://localhost:8080 (user: admin)
	@echo "Argo CD UI at https://localhost:8080  (user 'admin', pw: make argocd-password)"
	kubectl -n argocd port-forward svc/argocd-server 8080:443

gitops-up: argocd-install argocd-bootstrap ## Install Argo CD and bootstrap the app-of-apps

# --- Observability / monitoring (Phase 5) -----------------------------------
# The kube-prometheus-stack (Prometheus + Grafana + operator) is itself an Argo CD
# Application (gitops/apps/monitoring.yaml), so `make up` already brings it up. The
# app emits /metrics; a ServiceMonitor tells Prometheus to scrape it; Grafana
# auto-loads the dashboard the chart ships. These targets just open the UIs and
# generate demo traffic.

grafana-ui: ## Open the Grafana dashboard at http://localhost:3000 (user: admin, pw: admin)
	@echo "Grafana at http://localhost:3000  (user 'admin', pw 'admin') — see the 'URL Shortener' dashboard"
	kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

prometheus-ui: ## Open Prometheus at http://localhost:9090 (Status -> Targets to see scrapes)
	@echo "Prometheus at http://localhost:9090  (Status -> Targets shows the app scrape endpoints)"
	kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090

load-demo: ## Generate demo traffic against prod so the Grafana graphs move (Ctrl-C to stop)
	@echo "Driving traffic at http://$(HOST_PROD) — watch the Grafana dashboard. Ctrl-C to stop."
	@code=$$(curl -s -X POST http://$(HOST_PROD)/api/links -H 'Content-Type: application/json' \
		-d '{"url":"https://example.com/load-demo"}' | sed -n 's/.*"code":"\([^"]*\)".*/\1/p'); \
	echo "created /$$code — following it in a loop"; \
	while true; do \
		curl -s -o /dev/null http://$(HOST_PROD)/$$code; \
		curl -s -o /dev/null http://$(HOST_PROD)/healthz; \
		curl -s -o /dev/null http://$(HOST_PROD)/does-not-exist; \
		sleep 0.3; \
	done

# --- Autoscaling / resilience (Phase 6) -------------------------------------
# metrics-server (installed as its own Argo app, gitops/apps/metrics-server.yaml)
# feeds pod CPU to a HorizontalPodAutoscaler in the prod release, which scales the
# app between 3 and 9 replicas on CPU. `make up` already installs both. These
# targets drive load and watch the HPA react. The load generator runs INSIDE the
# cluster (a throwaway `hey` pod) and hits the prod Service directly, so no host
# tool is needed and the load fans out across replicas as they scale.

load-test: ## Fire load at prod from an in-cluster pod to trip the HPA (watch: make hpa-watch)
	@echo "Firing $(LOAD_CONCURRENCY) request loops at prod for $(LOAD_DURATION)s."
	@echo "Run 'make hpa-watch' in another terminal to watch replicas scale out, then back in."
	kubectl -n $(NS_PROD) run load-test --rm -i --restart=Never --image=$(LOAD_IMAGE) -- \
		sh -c '$(call LOAD_SCRIPT,http://prod-url-shortener)'

eks-load-test: ## Same load test, against the EKS release (watch: make eks-hpa-watch)
	@echo "Firing $(LOAD_CONCURRENCY) request loops at the EKS release for $(LOAD_DURATION)s."
	kubectl -n $(NS_EKS) run load-test --rm -i --restart=Never --image=$(LOAD_IMAGE) -- \
		sh -c '$(call LOAD_SCRIPT,http://eks-url-shortener)'

eks-hpa-watch: ## Watch the EKS HPA add/remove app replicas live
	kubectl -n $(NS_EKS) get hpa,deployment -w

hpa-watch: ## Watch the prod HPA add/remove app replicas live
	@echo "Watching the prod HPA (Ctrl-C to stop). TARGETS jumps past 60% under load, then REPLICAS climb."
	kubectl -n $(NS_PROD) get hpa,deployment -w

# Phase 4 made Argo CD the app deployer (GitOps): `up` no longer runs helm-dev/
# helm-prod directly — it installs Argo CD and bootstraps the app-of-apps, and
# Argo pulls the chart from git and deploys both releases. `load` still builds and
# `kind load`s the image first (no registry yet), and ingress-install runs before
# the app so the Ingress objects pass the controller's admission webhook.
up: cluster-up load ingress-install argocd-install argocd-bootstrap ## Full stack: cluster + Argo CD + dev + prod (GitOps)
	@echo "\nAll up (GitOps).  prod: http://$(HOST_PROD)   dev: http://$(HOST_DEV)"
	@echo "Argo:     make argocd-ui   (https://localhost:8080, user 'admin', pw: make argocd-password)"
	@echo "Grafana:  make grafana-ui  (http://localhost:3000, admin/admin — the monitoring app may take a few min to sync)"
	@echo "Scale:    make hpa-watch  (one terminal)  +  make load-test  (another) — watch prod autoscale on CPU"
	@echo "Then:     make seed && make seed-dev && make load-demo"

down: cluster-down ## Tear everything down (deletes the whole cluster)

uninstall: ## Remove both Helm releases (leaves the cluster running)
	-helm uninstall dev  -n $(NS_DEV)
	-helm uninstall prod -n $(NS_PROD)

restart-app: ## Rebuild the image, reload it, and roll both releases' app pods
	$(MAKE) load
	kubectl -n $(NS_DEV)  rollout restart deployment/dev-url-shortener
	kubectl -n $(NS_PROD) rollout restart deployment/prod-url-shortener
	kubectl -n $(NS_DEV)  rollout status deployment/dev-url-shortener  --timeout=120s
	kubectl -n $(NS_PROD) rollout status deployment/prod-url-shortener --timeout=120s

status: ## Show what's running in both release namespaces
	@echo "=== dev ($(NS_DEV)) ==="  && kubectl -n $(NS_DEV)  get all,pvc
	@echo "\n=== prod ($(NS_PROD)) ===" && kubectl -n $(NS_PROD) get all,pvc

logs: ## Tail the prod app logs (structured JSON access lines)
	kubectl -n $(NS_PROD) logs -l app.kubernetes.io/component=app --tail=50 -f

port-forward: ## Fallback access without ingress: prod app on http://localhost:8000
	@echo "prod app at http://localhost:8000  (Ctrl-C to stop)"
	kubectl -n $(NS_PROD) port-forward svc/prod-url-shortener 8000:80

seed: ## Create demo links through the prod host
	BASE_URL=http://$(HOST_PROD) python3 scripts/seed_demo.py

seed-dev: ## Create demo links through the dev host
	BASE_URL=http://$(HOST_DEV) python3 scripts/seed_demo.py

# --- EKS (stretch phase) ----------------------------------------------------
# The same chart and the same GitOps machinery, on a real managed Kubernetes
# cluster instead of kind. Terraform builds the cluster; Argo CD deploys the app
# into it — the same split as everywhere else in this repo.
#
# Everything here costs money while it exists (~$0.24/hour: control plane, two
# nodes, NAT gateway, NLB), so the intended cycle is apply, demo, destroy in one
# sitting. Full runbook in docs/EKS.md.
#
#   make eks-up          # ~15-20 min: VPC, control plane, nodes, addons
#   make eks-kubeconfig  # point kubectl at it
#   make eks-ingress     # install ingress-nginx (its Service creates the NLB)
#   make eks-bootstrap   # Argo CD + the EKS app-of-apps
#   make eks-url         # the address to open
#   make eks-down        # release the NLB, then destroy everything

TF_DIR       := terraform
EKS_INGRESS_VERSION := controller-v1.15.1
# The AWS variant of the same pinned ingress-nginx release the kind cluster
# vendors in k8s/ingress-nginx/. It differs in one important way: its Service is
# type LoadBalancer with NLB annotations, instead of using host ports.
EKS_INGRESS_MANIFEST := https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(EKS_INGRESS_VERSION)/deploy/static/provider/aws/deploy.yaml

eks-init: ## Initialize Terraform (downloads providers)
	cd $(TF_DIR) && terraform init

eks-plan: ## Preview what Terraform would create (no changes, no cost)
	cd $(TF_DIR) && terraform plan

eks-up: ## Create the EKS cluster with Terraform (~15-20 min, starts billing)
	@echo "Creating the EKS cluster. The control plane alone takes 10-15 minutes."
	@echo "This starts costing roughly \$$0.24/hour until 'make eks-down'."
	cd $(TF_DIR) && terraform init -input=false && terraform apply

eks-kubeconfig: ## Point kubectl at the EKS cluster
	$$(cd $(TF_DIR) && terraform output -raw kubeconfig_command)
	kubectl get nodes

eks-ingress: ## Install ingress-nginx on EKS (its Service provisions the NLB)
	kubectl apply -f $(EKS_INGRESS_MANIFEST)
	kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
	@echo "Waiting for AWS to attach a load balancer to the controller Service..."
	@kubectl -n ingress-nginx wait --for=jsonpath='{.status.loadBalancer.ingress}' \
		svc/ingress-nginx-controller --timeout=300s \
		|| echo "Still pending. If it never resolves, the subnet ELB tags are wrong — see docs/EKS.md."

eks-bootstrap: ## Install Argo CD and bootstrap the EKS app-of-apps
	$(MAKE) argocd-install
	kubectl apply -f gitops/project.yaml
	kubectl apply -f gitops/project-platform.yaml
	kubectl apply -f gitops/eks/root-app-eks.yaml
	@echo "Bootstrapped. Watch it converge:  kubectl -n argocd get applications -w"

eks-url: ## Print the URL the app is reachable at (the NLB's DNS name)
	@echo "http://$$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
		-o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

eks-status: ## Show the EKS release: pods, PVC (should be Bound), HPA, Argo apps
	@echo "=== nodes ===" && kubectl get nodes -o wide
	@echo "\n=== argo ===" && kubectl -n argocd get applications
	@echo "\n=== release ===" && kubectl -n url-shortener-eks get pods,pvc,hpa

eks-seed: ## Create demo links through the EKS load balancer
	BASE_URL=$$($(MAKE) -s eks-url) python3 scripts/seed_demo.py

# TEARDOWN ORDER MATTERS.
#
# Terraform only knows about resources Terraform created. Two AWS resources here
# were created by KUBERNETES instead, and Terraform has no idea they exist:
#
#   1. The NLB      — created by the ingress-nginx Service (type: LoadBalancer).
#                     Destroying the VPC while it still has ENIs in the subnets
#                     fails, leaving a half-destroyed stack and a billing NLB.
#   2. The EBS vol  — created by the EBS CSI driver for the Postgres PVC.
#                     Destroying the cluster just orphans it: it survives in
#                     `available` state, billing per provisioned GiB, forever.
#                     (Found the hard way on 2026-08-30 — a 4Gi gp3 volume was
#                     left behind by the first teardown.)
#
# Both have the same fix and the same lesson: anything Kubernetes provisioned in
# AWS has to be deleted THROUGH Kubernetes, before Terraform tears the cluster
# out from under it. Argo's auto-sync would recreate the workload, so its
# Applications go first.
eks-down: ## Release the K8s-created AWS resources, then destroy everything
	@echo "1/4  Removing Argo Applications so self-heal can't recreate the workload..."
	-kubectl -n argocd delete app url-shortener-eks-root eks eks-metrics-server eks-storageclass \
		--ignore-not-found --timeout=180s
	@echo "2/4  Deleting the release namespace so the CSI driver deletes the EBS volume..."
	-kubectl delete namespace $(NS_EKS) --ignore-not-found --timeout=300s
	@echo "3/4  Deleting the ingress-nginx Service so AWS releases the NLB..."
	-kubectl -n ingress-nginx delete svc ingress-nginx-controller --ignore-not-found --timeout=300s
	@echo "     Polling AWS until both are actually gone (a fixed sleep is a guess)..."
	@for i in $$(seq 1 40); do \
		LB=$$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 1); \
		VOL=$$(aws ec2 describe-volumes --filters Name=status,Values=available \
			Name=tag:kubernetes.io/cluster/$(EKS_CLUSTER),Values=owned \
			--query 'length(Volumes)' --output text 2>/dev/null || echo 1); \
		echo "       load_balancers=$$LB orphaned_volumes=$$VOL"; \
		[ "$$LB" = "0" ] && [ "$$VOL" = "0" ] && echo "     released." && break; \
		sleep 15; \
	done
	@echo "4/4  terraform destroy"
	cd $(TF_DIR) && terraform destroy
	@echo "\nDestroyed. Confirm nothing is left behind:"
	@echo "  aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'"
	@echo "  aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'"
