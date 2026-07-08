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

**Phase 3 complete — Helm chart, dev + prod releases.** The raw manifests were
converted into a chart under `charts/url-shortener/` (`Chart.yaml`, `values.yaml`,
`templates/` for config/secret, postgres, app, ingress, plus `_helpers.tpl` and
`NOTES.txt`). A `_helpers.tpl` scopes every object's name to the release
(`<release>-url-shortener[-postgres]`) and stamps the standard
`app.kubernetes.io/*` labels, so two installs never collide. `POSTGRES_HOST` is
computed from the release name, so each release's app points at its own database.

Two overlays: `values-dev.yaml` (1 replica, 512Mi PVC,
`dev.urlshortener.localtest.me`) and `values-prod.yaml` (3 replicas, CPU/mem
requests+limits, `urlshortener.localtest.me`). Installed as two releases —
`dev` in ns `url-shortener-dev`, `prod` in ns `url-shortener-prod`. Verified
side by side end-to-end (redirects/stats/healthz on both hosts, isolated data).

Migration note: the old Phase 1/2 `url-shortener` namespace (raw-manifest deploy)
owned the prod host, so the first `prod` install failed on the ingress admission
webhook (duplicate host+path). Deleted that superseded namespace, re-applied
prod. The raw `k8s/00–40` manifests stay in the repo as the reference the chart
was derived from; `k8s/ingress-nginx/` is still installed directly (cluster-level
infra, not part of the app chart).

`make up` now does: cluster → build/load image → ingress-install → `helm-dev` +
`helm-prod` (both via `helm upgrade --install`). New targets: `lint`, `template`,
`helm-dev`, `helm-prod`, `uninstall`, `seed-dev`. Tooling: `kind`/`kubectl`/`helm`
via Homebrew (helm v4.2.2).

Next: **Phase 4** — GitOps with Argo CD pointing at `charts/url-shortener`.

## Conventions

- **Commits / PRs: no AI attribution** (workspace-wide rule).
- **Infra is declarative.** Cluster state lives in manifests/Helm/Argo, not in
  imperative `kubectl edit` by hand — mirror the Terraform discipline from
  project #3.
- **Each phase leaves a visible demo** (seed via `scripts/seed_demo.py`).
