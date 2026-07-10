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

## Current state (as of 2026-07-10)

**Phase 4 complete — GitOps with Argo CD.** The cluster now **pulls** its desired
state from git instead of us pushing it. Argo CD (pinned **v3.4.5**, applied from
the upstream URL by `make argocd-install`) watches this repo and reconciles an
**app-of-apps** defined under `gitops/`:

- `gitops/project.yaml` — an `AppProject` (`url-shortener`) scoping the one source
  repo and the three destination namespaces (`argocd`, `url-shortener-dev`,
  `url-shortener-prod`); only `Namespace` is whitelisted cluster-scoped.
- `gitops/root-app.yaml` — the root `Application` we bootstrap once; its "manifests"
  are the files in `gitops/apps/`, so Argo creates the child Apps itself.
- `gitops/apps/{dev,prod}.yaml` — one `Application` each, pointing at the **same**
  `charts/url-shortener` chart with `values-dev.yaml` / `values-prod.yaml`, into
  `url-shortener-dev` / `url-shortener-prod`. Both are auto-sync + prune + self-heal.

`make up` no longer runs `helm install` directly: it does cluster → build/load
image → ingress-install → `argocd-install` → `argocd-bootstrap`, and Argo deploys
both releases from `main`. New targets: `argocd-install`, `argocd-bootstrap`,
`argocd-password`, `argocd-ui`, `gitops-up`. `helm-dev`/`helm-prod` remain as a
labeled manual/reference path (running them alongside Argo would create a second
owner that fights self-heal).

Handoff note: the live cluster already had the Phase-3 `dev`/`prod` **Helm**
releases, so ownership was handed to Argo once — `helm uninstall`ed both (the
Postgres StatefulSet `volumeClaimTemplates` PVCs and the namespaces are retained,
so data survived), then bootstrapped Argo to re-adopt the objects as sole owner.
Because Argo pulls from GitHub `main`, `gitops/` must be pushed before a bootstrap
takes effect. The image is still `kind load`ed locally (`pullPolicy: IfNotPresent`),
so no registry is needed until Phase 7.

The raw `k8s/00–40` manifests stay in the repo as the Phase 1/2 reference;
`k8s/ingress-nginx/` is still installed directly (cluster-level infra). Tooling:
`kind`/`kubectl`/`helm` via Homebrew (helm v4.2.2), Argo CD v3.4.5.

Next: **Phase 5** — Observability (kube-prometheus-stack + a `/metrics` endpoint +
ServiceMonitor + a Grafana dashboard).

## Conventions

- **Commits / PRs: no AI attribution** (workspace-wide rule).
- **Infra is declarative.** Cluster state lives in manifests/Helm/Argo, not in
  imperative `kubectl edit` by hand — mirror the Terraform discipline from
  project #3.
- **Each phase leaves a visible demo** (seed via `scripts/seed_demo.py`).
