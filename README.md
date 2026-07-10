# url-shortener-k8s

A URL shortener running on **Kubernetes** — the fourth project in a cloud-learning
arc that climbs from fully-managed platforms to full control over the stack.

The app is deliberately small (paste a long URL, get a short one; visiting it
redirects and logs a click). **The platform around it is the subject:** a local
Kubernetes cluster, Helm packaging, GitOps delivery, Prometheus/Grafana
monitoring, and autoscaling.

## Where this fits

| # | Project | What I owned |
|---|---|---|
| 1 | Cloudflare edge | app + data only — the platform hides everything else |
| 2 | AWS serverless (Lambda/SAM) | IAM, IaC, managed services |
| 3 | AWS containers (ECS Fargate + Terraform) | VPC, load balancer, RDS, CI/CD |
| **4** | **This — Kubernetes** | **the orchestrator itself: scheduling, service networking, GitOps delivery, monitoring, autoscaling** |

Project #3 was *"let AWS run my containers."* This one is *"I run the orchestrator
myself."* Same Docker image — but now I own the scheduler.

## Stack

**kind** (local Kubernetes, $0) · **Helm** · **Argo CD** (GitOps) · **Prometheus +
Grafana** · **Horizontal Pod Autoscaler** · **ingress-nginx** · **GitHub Actions →
GHCR**. App inside the container: **Python + FastAPI** talking to **Postgres**.

## Run it (on a local Kubernetes cluster)

Needs Docker, [`kind`](https://kind.sigs.k8s.io/), `kubectl`, and
[`helm`](https://helm.sh/). The `Makefile` wraps the whole workflow
(`make help` lists every target):

```bash
make up            # cluster + image + ingress-nginx + Argo CD, which deploys dev + prod
kubectl -n argocd get applications   # watch dev + prod go Synced / Healthy
make seed          # add demo links + clicks to prod (make seed-dev for dev)
open http://urlshortener.localtest.me          # prod  — no port-forward
open http://dev.urlshortener.localtest.me      # dev   — the same chart, 1 replica
make down          # delete the whole cluster
```

The app is packaged as a **Helm chart** (`charts/url-shortener`) deployed as **two
releases from the same chart**: a lean `dev` (1 replica, smaller volume) in
`url-shortener-dev` and a bigger `prod` (3 replicas, resource requests/limits) in
`url-shortener-prod`. Only the values differ (`values-dev.yaml` /
`values-prod.yaml`); the templates are identical. Since Phase 4 the chart isn't
installed by hand — **Argo CD deploys it from git** (see below).

`urlshortener.localtest.me` / `dev.urlshortener.localtest.me` are real domains
that resolve to `127.0.0.1`, so they reach the in-cluster **ingress-nginx**
controller with no `/etc/hosts` edits, and ingress-nginx routes each host to the
right release. (`make port-forward` still works as a fallback.)

**Prove the state model** — the app is stateless, the database isn't:

```bash
kubectl -n url-shortener-prod delete pod -l app.kubernetes.io/component=app  # kill an app pod
kubectl -n url-shortener-prod delete pod prod-url-shortener-postgres-0       # kill the database pod
# ...both come back; the links + click counts are still there. The data lives on
# the StatefulSet's PersistentVolumeClaim, not in any pod.
```

### What's in the cluster

The Helm chart renders, per release:

- **Postgres** as a **StatefulSet** + headless Service + a **PVC** — stable
  identity and its own disk, so data outlives the pod.
- The app as a **Deployment** (replica count per environment) + ClusterIP
  **Service**, with **liveness/readiness probes** on `/healthz` and an init
  container that waits for Postgres before starting.
- A **ConfigMap** (non-secret settings) + **Secret** (DB password); the app
  assembles `DATABASE_URL` from both at runtime.
- An **Ingress** routing the release's hostname to its app Service.

Cluster-level (installed once, outside the chart): the **ingress-nginx**
controller (vendored in `k8s/ingress-nginx/`, pinned to v1.15.1). The original
raw manifests are kept in `k8s/` as the Phase 1/2 reference the chart was
derived from.

### GitOps: the cluster pulls its state from git (Argo CD)

Nothing above is deployed by hand. **Argo CD** watches this repo and continuously
reconciles the cluster to match the chart on `main` — the desired state lives in
git, not in whatever `kubectl`/`helm` commands someone happened to run. `make up`
installs Argo CD (pinned **v3.4.5**) and applies one bootstrap object; Argo does
the rest.

The delivery model is **app-of-apps**, under [`gitops/`](gitops/):

- `project.yaml` — an **AppProject** that scopes Argo to *this* repo and *only*
  the three namespaces it owns (least-privilege for the delivery pipeline).
- `root-app.yaml` — the **root Application** you bootstrap once. Its contents are
  simply the other Application files in `gitops/apps/`, so Argo reads that folder
  from git and creates the child apps itself.
- `apps/dev.yaml`, `apps/prod.yaml` — one **Application** each, pointing at the
  same `charts/url-shortener` chart with the dev / prod values. Both are set to
  **auto-sync, prune, and self-heal**.

```bash
kubectl -n argocd get applications     # url-shortener-root, dev, prod → Synced/Healthy
make argocd-ui                         # open the dashboard at https://localhost:8080
make argocd-password                   # the initial 'admin' password
```

Two things this buys you, both demoable:

- **Change via git, not kubectl.** Edit a replica count in `values-dev.yaml`, push
  to `main`, and Argo reconciles the cluster to match — no `kubectl apply`.
- **Self-heal.** Hand-edit a live object (`kubectl scale deploy/prod-url-shortener
  --replicas=5`) and Argo reverts it back to what git says. Git is the only source
  of truth.

### Try it without Kubernetes (Phase 0 smoke test)

```bash
docker compose up --build      # builds the image, starts app + Postgres
open http://127.0.0.1:8000
docker compose down
```

## Build status

Built phase-by-phase; see [`docs/PLAN.md`](docs/PLAN.md) for the full arc.
**Currently: Phase 4 (GitOps with Argo CD — app-of-apps deploying dev + prod).**
Observability (Prometheus + Grafana) is next.
