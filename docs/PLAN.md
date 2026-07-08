# Build plan — url-shortener-k8s

Phase-by-phase. Each phase ends with something visibly working (a running pod, a
Grafana graph, a green pipeline), per the workspace `leave-demo-data` convention.
The app is reused as-is from the AWS/ECS version of this project; every phase
below is about the **platform around it**, not the business logic.

Everything runs locally on **kind** (Kubernetes IN Docker) so the whole project
costs $0 and can be left running for a demo. A stretch phase makes it EKS-ready.

---

## Phase 0 — Scaffold & containerize ✅

- Repo skeleton, docs, the FastAPI app copied in, Dockerfile.
- One code change vs. the ECS version: the DB URL now comes only from the
  `DATABASE_URL` env var (a Kubernetes Secret will supply it), so the AWS
  Secrets Manager / boto3 path is gone and the image is smaller.
- `docker-compose.yml` is the local smoke test: `docker compose up --build`
  starts the app + a Postgres and proves the image runs before any Kubernetes.

**Demo:** `docker compose up --build`, open http://127.0.0.1:8000, shorten a URL.

## Phase 1 — kind cluster + raw manifests ✅

- A `kind-config.yaml` (1 control-plane + 2 workers) and a `Makefile` that
  wraps create/destroy plus build → `kind load` → `kubectl apply`.
- Raw YAML under `k8s/`: Namespace, Postgres **StatefulSet** + headless Service +
  PVC, a Secret (DB password) and ConfigMap, the app **Deployment** + Service,
  with **liveness/readiness probes** on `/healthz`. An init container waits for
  Postgres so the app starts cleanly instead of crash-looping.
- The app assembles `DATABASE_URL` at runtime from the ConfigMap + Secret via
  `$(VAR)` env expansion, so the password lives only in the Secret.
- Build the image and `kind load docker-image` it into the cluster (no registry
  needed yet).

**Demo:** `make up`, `make port-forward`, `make seed`, shorten a URL, then
`kubectl delete pod` both the app pod and `postgres-0` — the links + click counts
survive (proves the DB is really separate state on the PVC).

## Phase 2 — Ingress

- Install **ingress-nginx**; add an Ingress routing `urlshortener.localtest.me`
  (a domain that resolves to 127.0.0.1) to the app Service.

**Demo:** hit the app through the ingress host in a browser, no port-forward.

## Phase 3 — Helm chart

- Convert the raw manifests into a chart under `charts/url-shortener` with a
  `values.yaml`, plus `values-dev.yaml` / `values-prod.yaml` overlays (different
  replica counts / resource sizes).

**Demo:** `helm install` the same chart into a `dev` and a `prod` namespace with
different values side by side.

## Phase 4 — GitOps with Argo CD

- Install **Argo CD**; define an `Application` that points at the Helm chart in
  this git repo. The cluster now pulls its desired state from git.

**Demo:** change replica count in git, push, watch Argo CD reconcile the cluster
to match — no `kubectl apply` by hand.

## Phase 5 — Observability

- Install **kube-prometheus-stack** (Prometheus + Grafana).
- Add a Prometheus `/metrics` endpoint to the app (prometheus-fastapi-
  instrumentator) and a **ServiceMonitor** so Prometheus scrapes it.
- A Grafana dashboard: request rate, latency, error rate, and link/click counts.

**Demo:** drive traffic with `seed_demo.py`, watch the Grafana dashboard fill in.

## Phase 6 — Autoscaling & resilience

- Set resource **requests/limits**; add a **HorizontalPodAutoscaler** on CPU.
- Load-test with `k6`/`hey` to push CPU past the target.

**Demo:** `kubectl get hpa -w` shows replicas scale out under load, then back in.

## Phase 7 — CI/CD

- **GitHub Actions**: on push, build the image, push to **GHCR**, run `helm lint`
  + `kubeconform` (manifest validation), and bump the image tag in the
  Argo-tracked values file (GitOps-style image update).

**Demo:** a green pipeline run; a commit produces a new image that Argo deploys.

## Stretch

- **EKS-ready:** Terraform for an EKS cluster so the same manifests deploy to
  real cloud on demand (tear down after, like the other AWS projects).
- **sealed-secrets / external-secrets** so the DB Secret isn't plaintext in git.
