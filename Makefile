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
#   kubectl -n argocd get applications   # watch dev + prod go Synced/Healthy
#   make seed && make seed-dev           # demo links through both hosts
#   open http://urlshortener.localtest.me          (prod)
#   open http://dev.urlshortener.localtest.me      (dev)
#   make argocd-ui                       # the Argo CD dashboard
#
# Tear it all down with `make down`.

CLUSTER   := url-shortener
IMAGE     := url-shortener:dev
CHART     := charts/url-shortener
NS_DEV    := url-shortener-dev
NS_PROD   := url-shortener-prod
HOST_DEV  := dev.urlshortener.localtest.me
HOST_PROD := urlshortener.localtest.me

# Argo CD is pinned to a specific release so an install is reproducible. The full
# install.yaml is ~19k lines, so (unlike the vendored ingress-nginx manifest) we
# apply it straight from the pinned upstream URL instead of committing it.
ARGOCD_VERSION := v3.4.5
ARGOCD_MANIFEST := https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml

.PHONY: help cluster-up cluster-down build load ingress-install \
        lint template helm-dev helm-prod up down uninstall \
        argocd-install argocd-bootstrap argocd-password argocd-ui gitops-up \
        status logs port-forward seed seed-dev restart-app

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

argocd-bootstrap: ## Apply the AppProject + app-of-apps root (Argo then deploys dev + prod)
	kubectl apply -f gitops/project.yaml
	kubectl apply -f gitops/root-app.yaml
	@echo "Bootstrapped. Watch it converge:  kubectl -n argocd get applications -w"

argocd-password: ## Print the initial Argo CD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d && echo

argocd-ui: ## Port-forward the Argo CD UI to https://localhost:8080 (user: admin)
	@echo "Argo CD UI at https://localhost:8080  (user 'admin', pw: make argocd-password)"
	kubectl -n argocd port-forward svc/argocd-server 8080:443

gitops-up: argocd-install argocd-bootstrap ## Install Argo CD and bootstrap the app-of-apps

# Phase 4 made Argo CD the app deployer (GitOps): `up` no longer runs helm-dev/
# helm-prod directly — it installs Argo CD and bootstraps the app-of-apps, and
# Argo pulls the chart from git and deploys both releases. `load` still builds and
# `kind load`s the image first (no registry yet), and ingress-install runs before
# the app so the Ingress objects pass the controller's admission webhook.
up: cluster-up load ingress-install argocd-install argocd-bootstrap ## Full stack: cluster + Argo CD + dev + prod (GitOps)
	@echo "\nAll up (GitOps).  prod: http://$(HOST_PROD)   dev: http://$(HOST_DEV)"
	@echo "Argo:  make argocd-ui  (then https://localhost:8080, user 'admin', pw: make argocd-password)"
	@echo "Then:  make seed  &&  make seed-dev"

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
