# Makefile — the Phase 1 control panel.
#
# Everything is declarative and repeatable: these targets just wrap the kind /
# docker / kubectl commands so the whole cluster can be built, torn down, and
# rebuilt with single words. Nothing here is configured by hand-editing live
# cluster state — the manifests in k8s/ are the source of truth.
#
# Typical first run:
#   make up            # create cluster, build+load the image, apply manifests
#   make port-forward  # in one terminal: expose the app on localhost:8000
#   make seed          # in another: create demo links
#   open http://localhost:8000
#
# Tear it all down with `make down`.

CLUSTER  := url-shortener
IMAGE    := url-shortener:dev
NS       := url-shortener
HOST     := urlshortener.localtest.me

.PHONY: help cluster-up cluster-down build load ingress-install deploy up down status logs port-forward seed restart-app

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

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

deploy: ## Apply app manifests (k8s/ is non-recursive, so ingress-nginx/ is skipped)
	kubectl apply -f k8s/
	kubectl -n $(NS) rollout status statefulset/postgres --timeout=120s
	kubectl -n $(NS) rollout status deployment/url-shortener --timeout=120s

# ingress-install runs before deploy: the Ingress in k8s/ is validated by the
# controller's admission webhook, which must be running first.
up: cluster-up load ingress-install deploy ## Full stack from scratch
	@echo "\nAll up. App: http://$(HOST)   (then)  make seed"

down: cluster-down ## Tear everything down (deletes the whole cluster)

restart-app: ## Rebuild the image, reload it, and roll the app pods
	$(MAKE) load
	kubectl -n $(NS) rollout restart deployment/url-shortener
	kubectl -n $(NS) rollout status deployment/url-shortener --timeout=120s

status: ## Show what's running in the namespace
	kubectl -n $(NS) get all,pvc

logs: ## Tail the app logs (structured JSON access lines)
	kubectl -n $(NS) logs -l app=url-shortener --tail=50 -f

port-forward: ## Fallback access without ingress: app on http://localhost:8000
	@echo "App at http://localhost:8000  (Ctrl-C to stop)"
	kubectl -n $(NS) port-forward svc/url-shortener 8000:80

seed: ## Create demo links through the ingress host
	BASE_URL=http://$(HOST) python3 scripts/seed_demo.py
