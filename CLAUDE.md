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

## Current state (as of 2026-08-26)

**Phase 7 complete — CI/CD (GitHub Actions + GHCR), the final planned phase.**
The delivery loop closes: push to `main` → `validate` (helm lint + kubeconform on
both overlays) → `build` (image to GHCR, tagged with the immutable short SHA) →
`deploy-dev` (writes that tag into `values-dev.yaml` and **commits back to main**).
Argo CD reconciles from there.

- **CI has no cluster credentials.** Nothing in the pipeline runs `kubectl`; it
  ends at committing desired state to git, and the in-cluster Argo CD pulls. That's
  the payoff of Phase 4 — a leaked CI token can't reach Kubernetes.
- **Prod is not auto-deployed.** `.github/workflows/promote.yml` is a manual
  `workflow_dispatch` that defaults to whatever dev is running, verifies the tag
  exists in GHCR before writing it, and commits to `values-prod.yaml`.
- **Image source now differs per env.** Neither values overlay had an `image:`
  block before Phase 7; CI created one in `values-dev.yaml`, so **dev pulls from
  GHCR** while **prod still uses the `kind load`ed local image** until its first
  promotion. Expect that asymmetry until you run `promote.yml` once.
- **First run green on the first attempt** (2026-08-26): validate 7s, build 39s,
  deploy-dev 6s → `ci: deploy d6b6fba to dev [skip ci]`. The GHCR package is
  **public**, so anonymous pulls (and `promote.yml`'s check) work.
- ⚠️ **Images must be multi-arch.** GitHub's runners are x86; the kind nodes are
  **arm64** (Apple Silicon/Colima). The first amd64-only image pulled with
  `no match for platform in manifest`. The build now runs
  `docker/setup-qemu-action@v3` with `platforms: linux/amd64,linux/arm64` so one
  image index serves both (build 39s → ~1m45s, arm64 emulated). Don't drop that.
- ⚠️ **Argo's sync state goes stale across a cluster outage.** After a Colima
  restart every app read `Synced` while actually pinned to an 18-day-old commit —
  "Synced" means "matches the revision I last fetched," not "matches `main`." Force
  a re-poll with
  `kubectl annotate app <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`.
- ✅ **Prod promotion verified 2026-08-26:** `promote.yml` (blank input) resolved
  dev's tag, verified it in GHCR, and committed the bump; Argo rolled all 3 prod
  replicas onto `ghcr.io/genkuroo/url-shortener:ba71052`. A marker link created on
  the old image kept its `created_at` and click history across the swap — the
  Postgres PVC is genuinely separate state. **Both envs are now on GHCR**, so the
  dev/prod image-source asymmetry noted above is resolved.
- ✅ **Verified in-cluster 2026-08-26:** Argo rolled dev to
  `ghcr.io/genkuroo/url-shortener:2055e3a`; pod Running, app served through the
  ingress (created a link, 307 redirect followed, click recorded in `/stats`), all
  five Applications Synced/Healthy. The rolling update kept the old pod serving
  throughout the failed-pull episode, so dev never went down.
- Remaining work is **stretch only**: EKS-ready Terraform, and
  sealed-secrets/external-secrets so the DB Secret isn't plaintext in git.
- Minor upkeep: Actions warns `actions/checkout@v4`, `azure/setup-helm@v4`, and the
  `docker/*` actions still target Node 20 (forced onto Node 24). Bump when convenient.

**Phase 6 complete — Autoscaling & resilience.** Prod scales itself on CPU via a
HorizontalPodAutoscaler, fed by metrics-server; both are delivered by Argo CD.

- **metrics-server:** kind ships no pod-CPU metrics API (`kubectl top` and any CPU
  HPA read `<unknown>`), so it's installed the GitOps way — its own Argo Application
  (`gitops/apps/metrics-server.yaml`, pinned chart **3.13.1**) under the existing
  `platform` AppProject, `sync-wave: "-1"` (up before the app's HPA). The one config
  it needs is **`--kubelet-insecure-tls`** (appended to the chart's default args):
  kind's kubelet serving certs aren't signed by the cluster CA, so without it every
  node reads "unavailable". The metrics-server Helm repo was added to the platform
  project's `sourceRepos`.
- **HPA (app chart, bumped to 0.3.0):** `templates/hpa.yaml` (gated by
  `autoscaling.enabled`, prod only) scales the app Deployment **3→9 replicas** to
  hold CPU at **60% of the request** (`autoscaling/v2`, Resource/cpu/Utilization).
  Enabled in `values-prod.yaml` only — dev sets no CPU request, so a percentage
  target is meaningless there. **Critical detail:** when `autoscaling.enabled`, the
  Deployment template **omits `spec.replicas`** so the HPA is the sole owner of the
  count; if the chart also declared it, Argo self-heal would keep reverting the
  HPA's scaling. `minReplicas: 3` holds prod's availability floor.
- **Load test:** `make load-test` runs a throwaway `hey` pod **inside the cluster**
  (`williamyeh/hey`, `kubectl run --rm`) against the prod Service's `/healthz`, so
  no host tool is needed and the load fans out across replicas as they scale.
  `make hpa-watch` tails `kubectl get hpa,deployment -w`. Concurrency/duration are
  overridable (`LOAD_CONCURRENCY`, `LOAD_DURATION`).

**Phase 5 — Observability (Prometheus + Grafana), GitOps-managed.** The
app now emits Prometheus metrics and both environments are scraped and graphed.

- **App `/metrics`:** `app/main.py` wires `prometheus-fastapi-instrumentator`
  (pinned **7.1.0** — 8.x needs Starlette ≥1.0, which `fastapi==0.115.6` won't
  allow). It's registered **before the greedy `GET /{code}` route** or that
  catch-all would swallow `/metrics` (FastAPI matches routes in definition order).
- **Monitoring stack via Argo:** `gitops/apps/monitoring.yaml` deploys
  **kube-prometheus-stack** (pinned chart **87.15.1**) from the prometheus-community
  Helm repo, under a new **`platform` AppProject** (`gitops/project-platform.yaml`)
  that has the broad cluster-scoped perms the app project deliberately lacks. Two
  Argo gotchas handled: `syncOptions: ServerSideApply=true` (the Prometheus CRDs
  exceed the 256KB last-applied-config annotation limit) and
  `argocd.argoproj.io/sync-wave: "-1"` (so the operator's CRDs exist before the
  app's ServiceMonitor syncs). Lean inline values: Alertmanager off, Grafana
  admin/admin, `serviceMonitorSelectorNilUsesHelmValues: false` (scrape all SMs),
  `grafana.sidecar.dashboards.searchNamespace: ALL`.
- **App chart (bumped to 0.2.0):** `templates/servicemonitor.yaml` (gated by
  `serviceMonitor.enabled`, on for both envs) scrapes the Service's `http` port at
  `/metrics`; `templates/grafana-dashboard.yaml` ships a dashboard ConfigMap
  (label `grafana_dashboard: "1"`) that the Grafana sidecar auto-imports — the JSON
  lives in `charts/url-shortener/dashboards/url-shortener.json` and is embedded via
  `.Files.Get` (so Grafana's `{{ }}` legend syntax isn't parsed by Helm). The
  dashboard ships from **prod only** (`dashboard.enabled` prod overlay) so there's
  one copy; its `namespace` variable switches dev/prod.
- **Makefile:** `argocd-bootstrap` now also applies the platform project. New
  targets: `grafana-ui`, `prometheus-ui`, `load-demo`. `make up` brings up
  monitoring automatically (it's part of the app-of-apps; first sync takes a few
  min).

**Phase 4 — GitOps with Argo CD.** The cluster **pulls** its desired state from
git. Argo CD (pinned **v3.4.5**, applied from the upstream URL by
`make argocd-install`) watches this repo and reconciles an **app-of-apps** under
`gitops/`:

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

Next: **Phase 7** — CI/CD (GitHub Actions: build → push to GHCR → `helm lint` +
`kubeconform` → bump the Argo-tracked image tag, GitOps-style).

## Conventions

- **Commits / PRs: no AI attribution** (workspace-wide rule).
- **Infra is declarative.** Cluster state lives in manifests/Helm/Argo, not in
  imperative `kubectl edit` by hand — mirror the Terraform discipline from
  project #3.
- **Each phase leaves a visible demo** (seed via `scripts/seed_demo.py`).
