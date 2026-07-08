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

Needs Docker, [`kind`](https://kind.sigs.k8s.io/), and `kubectl`. The `Makefile`
wraps the whole workflow (`make help` lists every target):

```bash
make up            # cluster + image + ingress-nginx + app manifests
make seed          # add demo links + clicks (through the ingress)
open http://urlshortener.localtest.me      # use the app — no port-forward
make down          # delete the whole cluster
```

`urlshortener.localtest.me` is a real domain that resolves to `127.0.0.1`, so it
reaches the in-cluster **ingress-nginx** controller with no `/etc/hosts` edits.
(`make port-forward` still works as a fallback if you'd rather not use ingress.)

**Prove the state model** — the app is stateless, the database isn't:

```bash
kubectl -n url-shortener delete pod -l app=url-shortener   # kill an app pod
kubectl -n url-shortener delete pod postgres-0             # kill the database pod
# ...both come back; the links + click counts are still there. The data lives on
# the StatefulSet's PersistentVolumeClaim, not in any pod.
```

### What's in the cluster

- **Namespace** `url-shortener` — everything grouped under one name.
- **Postgres** as a **StatefulSet** + headless Service + a 1Gi **PVC** — stable
  identity and its own disk, so data outlives the pod.
- The app as a 2-replica **Deployment** + ClusterIP **Service**, with
  **liveness/readiness probes** on `/healthz` and an init container that waits
  for Postgres before starting.
- A **ConfigMap** (non-secret settings) + **Secret** (DB password); the app
  assembles `DATABASE_URL` from both at runtime.
- **ingress-nginx** controller (vendored in `k8s/ingress-nginx/`, pinned to
  v1.15.1) + an **Ingress** routing `urlshortener.localtest.me` to the app
  Service — the cluster's public front door.

### Try it without Kubernetes (Phase 0 smoke test)

```bash
docker compose up --build      # builds the image, starts app + Postgres
open http://127.0.0.1:8000
docker compose down
```

## Build status

Built phase-by-phase; see [`docs/PLAN.md`](docs/PLAN.md) for the full arc.
**Currently: Phase 2 (ingress-nginx front door).** Helm packaging is next.
