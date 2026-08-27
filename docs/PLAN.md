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

## Phase 2 — Ingress ✅

- Installed **ingress-nginx** (kind provider, pinned to v1.15.1, vendored in
  `k8s/ingress-nginx/` so the version is reviewable and reproducible). One local
  edit: re-added the `ingress-ready=true` nodeSelector the v1.15.1 manifest
  dropped, so the controller is pinned to the control-plane node — the only node
  whose host ports 80/443 are forwarded to the laptop.
- Added an **Ingress** (`k8s/40-ingress.yaml`) routing `urlshortener.localtest.me`
  (a domain that resolves to 127.0.0.1) to the app Service.

**Demo:** `make seed`, then hit `http://urlshortener.localtest.me` in a browser —
UI, API, and short-link redirects all work with no port-forward.

## Phase 3 — Helm chart ✅

- Converted the raw manifests into a chart under `charts/url-shortener` with a
  `values.yaml`, plus `values-dev.yaml` / `values-prod.yaml` overlays (different
  replica counts / resource sizes / hostnames). A `_helpers.tpl` scopes every
  object's name to the release, so the two installs never collide.
- The Makefile deploy path switched from raw `kubectl apply -f k8s/` to
  `helm upgrade --install` of two releases; the raw manifests stay in `k8s/` as
  the reference the chart was derived from.

**Demo:** `make up` installs the **same chart** as a lean `dev` (1 replica,
`dev.urlshortener.localtest.me`) and a bigger `prod` (3 replicas + resource
requests/limits, `urlshortener.localtest.me`) side by side. `helm list -A` shows
both; each has its own isolated Postgres and serves redirects/stats through its
own ingress host.

## Phase 4 — GitOps with Argo CD ✅

- Installed **Argo CD** (pinned v3.4.5, applied from the upstream URL by
  `make argocd-install`) and defined an **app-of-apps** under `gitops/`: an
  `AppProject` scopes the repo + the three namespaces, a root `Application`
  reconciles `gitops/apps/`, and the two child `Application`s point at the same
  `charts/url-shortener` chart with the `values-dev` / `values-prod` overlays. The
  cluster now **pulls** its desired state from git (auto-sync, prune, self-heal).
- The Makefile deploy path moved off direct `helm install`: `make up` now installs
  Argo CD and bootstraps the app-of-apps, and Argo deploys both releases. The
  `helm-dev`/`helm-prod` targets stay as a labeled manual/reference path.
- One-time handoff on the existing cluster: `helm uninstall`ed the Phase-3 releases
  (Postgres StatefulSet PVCs are retained, so data survived) and let Argo re-adopt
  the objects as their sole owner.

**Demo:** bump a replica count in `values-dev.yaml`, push, and watch Argo CD
reconcile the cluster to match with no `kubectl apply`; or hand-edit a live
Deployment and watch self-heal revert it.

## Phase 5 — Observability ✅

- Installed **kube-prometheus-stack** (Prometheus + Grafana + operator) the GitOps
  way — as another Argo CD `Application` (`gitops/apps/monitoring.yaml`, pinned
  chart 87.15.1) under a dedicated `platform` AppProject. Needs `ServerSideApply`
  (the CRDs blow the 256KB annotation limit) and a `sync-wave: "-1"` so the
  operator's CRDs land before the app's ServiceMonitor.
- Added a Prometheus `/metrics` endpoint to the app (prometheus-fastapi-
  instrumentator, pinned **7.1.0** for FastAPI 0.115 compatibility), wired in
  before the greedy `/{code}` route so it isn't swallowed, plus a **ServiceMonitor**
  in the app chart (enabled per-env) so Prometheus scrapes both releases.
- A **Grafana dashboard** shipped as a ConfigMap the Grafana sidecar auto-imports
  (via `.Files.Get` so Grafana's own `{{ }}` legends survive Helm): request rate by
  status, p50/p95/p99 latency, 5xx error share, and links-created — with a
  `namespace` variable to switch between dev and prod.

**Demo:** `make load-demo` drives traffic at prod; `make grafana-ui` → the
URL-Shortener dashboard fills in. `make prometheus-ui` → Status→Targets shows both
app scrape endpoints UP.

## Phase 6 — Autoscaling & resilience ✅

- Prod already carried resource **requests/limits** (Phase 3); this phase adds a
  **HorizontalPodAutoscaler** (app chart, `templates/hpa.yaml`, prod only) that
  scales the app **3→9 replicas** to hold CPU at **60% of the request**. When
  autoscaling is on, the Deployment **stops declaring `replicas`** so the HPA — not
  Argo self-heal — owns the count (otherwise the two fight).
- An HPA needs a pod-CPU metrics API, which kind doesn't ship, so **metrics-server**
  is installed the GitOps way — its own Argo Application
  (`gitops/apps/metrics-server.yaml`, pinned chart 3.13.1) under the `platform`
  project, with the `--kubelet-insecure-tls` flag kind requires.
- **Load-tested** from an in-cluster throwaway `hey` pod against the prod Service
  (`make load-test`), so no host tooling is needed and load fans out across replicas.

**Demo:** `make hpa-watch` in one terminal, `make load-test` in another — replicas
scale out under load, then back in a few minutes after it stops.

## Phase 7 — CI/CD ✅

- **`ci.yml` — three jobs, each gated on the last.** `validate` runs on every push
  *and* PR: `helm lint` plus `kubeconform -strict` over both rendered env overlays,
  with the datree CRD catalog as a second schema source so the Phase-5
  ServiceMonitor validates instead of being skipped. `build` (main only) builds
  `app/Dockerfile` and pushes to **GHCR** tagged with the immutable **short SHA**
  (plus a moving `latest` for humans — GitOps never references it). `deploy-dev`
  writes that repo+tag into `values-dev.yaml` and **commits it back to main**.
- **CI never touches the cluster.** The pipeline's last act is a commit; Argo CD
  (watching `main`, auto-sync + self-heal since Phase 4) is what changes the
  cluster. So CI holds **no cluster credentials** — a leaked CI token gets an
  attacker a registry image and a revertible commit, not a foothold in Kubernetes.
  The bot commit carries `[skip ci]`, and `GITHUB_TOKEN` pushes don't retrigger
  workflows anyway, so there's no loop.
- **`promote.yml` — prod is a human decision.** A `workflow_dispatch` that resolves
  a tag (blank input = whatever dev is on), **verifies it exists in GHCR** via an
  anonymous manifest HEAD before writing it (so a typo'd tag fails loudly instead
  of putting prod in `ImagePullBackOff`), then commits to `values-prod.yaml`.
  Running the workflow *is* the approval, and the Actions tab is the audit trail.
- **`make ci-validate`** mirrors the `validate` job locally (needs `kubeconform` on
  PATH) so a broken chart is caught before pushing.

**First run (2026-08-26):** green end-to-end on the first attempt — validate 7s,
build 39s, deploy-dev 6s — producing the bot commit
`ci: deploy d6b6fba to dev [skip ci]`. Three predicted snags didn't materialize:
the GHCR package came out **public** (anonymous manifest pull returns 200, so
`promote.yml`'s check works), the `contents: write` job permission was enough to
push to `main`, and the `mikefarah/yq` step worked (`ubuntu-latest` ships yq v4
regardless). Note `values-dev.yaml` had **no `image:` block** before this — yq
created it — so dev moved off the `kind load`ed local image onto GHCR, while
**prod stays on the local image until its first promotion**.

### The one real bug: CPU architecture

A green pipeline still couldn't deploy. The first pull on the cluster failed with
**`no match for platform in manifest`** — GitHub's runners are **x86**, so
`docker/build-push-action` published an **amd64-only** image, while the kind nodes
run on **Apple Silicon (arm64)** via Colima. The registry had the image; the nodes
had no layer they could execute.

Fix: add `docker/setup-qemu-action@v3` and `platforms: linux/amd64,linux/arm64`
to the build step, so one build publishes an **image index** and each node pulls
its own match. Costs build time (39s → ~1m45s, since arm64 is emulated under QEMU)
and is the same lesson as the ECS project's ARM64/Graviton images — with the
architectures reversed.

Worth noting what *didn't* break: dev never went down. The rolling update kept the
old pod serving while the new one failed to pull, so the outage was confined to
"the new version isn't live yet."

**Verified in-cluster (2026-08-26):** after the multi-arch fix, Argo rolled dev to
`ghcr.io/genkuroo/url-shortener:2055e3a`, the pod went Running, and the app served
through the ingress — created a link, followed the 307 redirect, and confirmed the
click landed in `/stats`. All five Argo Applications Synced/Healthy.

⚠️ **Argo's cache goes stale across a cluster outage.** After Colima restarted, all
apps reported `Synced` while actually sitting on the Phase-6 commit (`reconciledAt`
was 18 days old). A `kubectl annotate app <name> argocd.argoproj.io/refresh=hard`
forces a re-poll. "Synced" means "matches the revision I last fetched," not
"matches `main`."

**Prod promotion verified (2026-08-26).** Ran `promote.yml` with a blank input to
exercise the default path: it resolved dev's tag (`ba71052`), confirmed the image
in GHCR, and committed `ci: promote ba71052 to prod [skip ci]`. Argo then rolled
prod — a genuine staged rollout across 3 replicas, old pods serving while new ones
came up. All three prod pods now run the GHCR image.

**The state claim holds:** a marker link created on the *old* image kept its exact
`created_at` and all 3 click timestamps across the swap, and new clicks continued
to accumulate on the same row — the Postgres StatefulSet's PVC is genuinely
separate state, untouched by an app-image change.

**The HPA still owns the replica count.** The rendered Deployment declares no
`replicas:` field; the live object shows one only because the HPA writes it through
the scale subresource. Argo doesn't manage that field, so self-heal can't fight it.


**Demo:** a green pipeline run; a commit produces a new image that Argo deploys.

## Stretch

- **EKS-ready:** Terraform for an EKS cluster so the same manifests deploy to
  real cloud on demand (tear down after, like the other AWS projects).
- **sealed-secrets / external-secrets** so the DB Secret isn't plaintext in git.
