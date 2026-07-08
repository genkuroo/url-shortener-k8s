# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A URL shortener running on **Kubernetes**. Project #4 in the cloud-learning arc
(after Cloudflare edge, AWS serverless, and AWS containers/ECS). The app is
deliberately small — **the platform is the subject**: a local Kubernetes cluster,
Helm packaging, GitOps delivery (Argo CD), Prometheus/Grafana observability, and
autoscaling.

The one-line arc: project #3 (ECS Fargate) was *"let AWS run my containers."*
This one is *"I run the orchestrator myself."* Same Docker image; now I own the
scheduler, service networking, delivery pipeline, and monitoring stack.

It closes the biggest gaps the earlier projects left (see the workspace
`PORTFOLIO-REVIEW.md`): **Kubernetes** (had none), a **real multi-stage CI/CD
pipeline**, **GitOps**, **Prometheus/Grafana observability**, **autoscaling**, and
**multi-environment** (dev/prod).

Built phase-by-phase; each phase ends with something visibly working, per the
workspace `leave-demo-data` convention. See `docs/PLAN.md`.

## The app

Reused as-is from the AWS/ECS version of this project (`url-shortener-aws`):

- `GET  /` — lightweight web UI (a form to shorten a URL)
- `POST /api/links` — create a short link
- `GET  /{code}` — redirect to the long URL + record a click
- `GET  /api/links/{code}/stats` — click count + recent hits
- `GET  /healthz` — liveness/readiness probe

Stack inside the container: **Python + FastAPI** talking to **Postgres**.

**Only code change vs. the ECS version:** the DB URL comes solely from the
`DATABASE_URL` env var (a Kubernetes Secret supplies it), so the AWS Secrets
Manager / boto3 startup path was removed and the image is smaller. The app is
otherwise identical and orchestrator-agnostic.

## Everything runs locally on kind

The whole project runs on **kind** (Kubernetes IN Docker) so it costs $0 and can
be left running for a demo — unlike the AWS projects, which are torn down between
sessions. A stretch phase adds EKS-ready Terraform for an on-demand cloud deploy.

- Build the image locally and `kind load docker-image` it into the cluster (no
  registry needed until the CI phase, which pushes to GHCR).
- The `DATABASE_URL` value lives in a Kubernetes Secret. Do not commit real
  secret values; a stretch phase adds sealed-secrets/external-secrets.

## Current state (as of 2026-07-08)

**Phase 1 complete — kind cluster + raw manifests.** A `kind-config.yaml`
(1 control-plane + 2 workers) and a `Makefile` that wraps create/destroy plus
build → `kind load` → `kubectl apply`. Raw YAML under `k8s/`: Namespace, Postgres
StatefulSet + headless Service + 1Gi PVC, ConfigMap + Secret, the app
Deployment (2 replicas) + ClusterIP Service, liveness/readiness probes on
`/healthz`, and an init container that waits for Postgres. Verified: deleting the
app pod and `postgres-0` leaves links + click counts intact (data lives on the
PVC). Tooling: `kind`/`kubectl` installed via Homebrew; `helm` not needed until
Phase 3.

Next: **Phase 2** — install ingress-nginx and route `urlshortener.localtest.me`
to the app Service (host ports 80/443 are already forwarded in `kind-config.yaml`).

## Conventions

- **Commits / PRs: no AI attribution** (workspace-wide rule).
- **Infra is declarative.** Cluster state lives in manifests/Helm/Argo, not in
  imperative `kubectl edit` by hand — mirror the Terraform discipline from
  project #3.
- **Each phase leaves a visible demo** (seed via `scripts/seed_demo.py`).
