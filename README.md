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

## Try it locally (Phase 0 — no Kubernetes needed yet)

```bash
docker compose up --build      # builds the image, starts app + Postgres
open http://127.0.0.1:8000     # shorten a URL in the browser
python scripts/seed_demo.py http://localhost:8000   # add demo links + clicks
docker compose down
```

## Build status

Built phase-by-phase; see [`docs/PLAN.md`](docs/PLAN.md) for the full arc.
**Currently: Phase 0 (scaffold + containerized app).** Kubernetes phases next.
