# Makefile — the project control panel.
#
# Everything is declarative and repeatable: these targets wrap the kind / docker
# / helm / kubectl commands so the whole cluster can be built, torn down, and
# rebuilt with single words. Nothing is configured by hand-editing live cluster
# state — the Helm chart in charts/ is the source of truth for the app.
#
# Phase 3 switched the app's deploy path from raw `kubectl apply -f k8s/` to a
# Helm chart installed as two side-by-side releases: a lean `dev` and a bigger
# `prod`, each in its own namespace. The raw manifests in k8s/ are kept as the
# Phase 1/2 reference; k8s/ingress-nginx/ is still installed directly (it's
# cluster-level infra, not part of the app chart).
#
# Typical first run:
#   make up        # cluster, build+load image, ingress, then helm dev + prod
#   make seed      # create demo links through the prod host
#   open http://urlshortener.localtest.me          (prod)
#   open http://dev.urlshortener.localtest.me      (dev)
#
# Tear it all down with `make down`.

CLUSTER   := url-shortener
IMAGE     := url-shortener:dev
CHART     := charts/url-shortener
NS_DEV    := url-shortener-dev
NS_PROD   := url-shortener-prod
HOST_DEV  := dev.urlshortener.localtest.me
HOST_PROD := urlshortener.localtest.me

.PHONY: help cluster-up cluster-down build load ingress-install \
        lint template helm-dev helm-prod up down uninstall \
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

helm-dev: ## Install/upgrade the lean dev release into its own namespace
	helm upgrade --install dev $(CHART) -n $(NS_DEV) --create-namespace -f $(CHART)/values-dev.yaml
	kubectl -n $(NS_DEV) rollout status deployment/dev-url-shortener --timeout=120s

helm-prod: ## Install/upgrade the prod release into its own namespace
	helm upgrade --install prod $(CHART) -n $(NS_PROD) --create-namespace -f $(CHART)/values-prod.yaml
	kubectl -n $(NS_PROD) rollout status deployment/prod-url-shortener --timeout=120s

# ingress-install runs before the releases: the Ingress objects are validated by
# the controller's admission webhook, which must be running first.
up: cluster-up load ingress-install helm-dev helm-prod ## Full stack: cluster + dev + prod
	@echo "\nAll up.  prod: http://$(HOST_PROD)   dev: http://$(HOST_DEV)   (then)  make seed"

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
