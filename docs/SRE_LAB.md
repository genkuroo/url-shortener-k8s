# SRE pressure-test lab

A hands-on course run against this project's local kind cluster, built for NVIDIA
SRE interview prep. The specific gap it targets: interview feedback that Ethan
reads as more inclined toward *building* systems than *operating/maintaining*
them. Each module breaks something real in this cluster on purpose and drills
the diagnosis workflow, not just the fix.

**Format:** Claude explains the mechanism and sets up the lab; Ethan drives the
terminals and reports what he sees. The point is muscle memory, not a
transcript — a module isn't "done" until Ethan has personally run it and
watched the signals himself, not just read about someone else's run.

## Status

| # | Module | What breaks | Status |
|---|---|---|---|
| 1 | HPA / CPU scaling | `make load-test` hammers `/healthz` (deliberately DB-free) with 80 concurrent loops | **Done (2026-09-04/05).** Ethan ran it hands-on: watched 3→6→9 scale-up, then watched the 5-min scale-down stabilization play out live and correctly read `ScaleDownStabilized` in `describe hpa`. Confirmed the HPA/PDB behavior discussed (below) was default Kubernetes, not project config. |
| 2 | Database bottlenecks | Hammer `/{code}` (the real hot path — does a Postgres `SELECT` + `INSERT` per request, see below) instead of `/healthz` | Designed, not run. Lab steps below. |
| 3 | Pod-level failure injection | OOMKill, crash loops, bad readiness probes | Not designed yet |
| 4 | Network / dependency failures | Ingress misroutes, timeouts, a slow downstream | Not designed yet |
| 5 | Capstone: blind incident | Claude breaks something without saying what; full diagnosis from cold | Not designed yet |

## The resources in play (read this before module 1)

- **Deployment** `prod-url-shortener` — app pods. `requests: 100m cpu/128Mi mem`,
  `limits: 500m cpu/256Mi mem` (`charts/url-shortener/values-prod.yaml`).
- **Service** `prod-url-shortener` — ClusterIP in front of whichever pods are
  `Ready`, port 80 → 8000.
- **HorizontalPodAutoscaler** — reads CPU as a % of the *request*, not the
  limit: target is 60% of 100m = 60m/pod. `minReplicas: 3`, `maxReplicas: 9`
  (`charts/url-shortener/templates/hpa.yaml`).
- **metrics-server** — measures real pod CPU and feeds the HPA. Separate
  pipeline from Prometheus/Grafana — conflating the two is a logged weak spot.
- **Prometheus + Grafana** (kube-prometheus-stack) — scrapes the app's own
  `/metrics` via a `ServiceMonitor`. Feeds dashboards, not the HPA.
- **Postgres** (`prod-url-shortener-postgres-0`) — `max_connections: 100`
  (confirmed live, default, nothing overrides it in the chart).

## Module 1 — HPA / CPU scaling

**Mechanism:** `make load-test` runs a throwaway `alpine:3` pod inside the
cluster (`kubectl run --rm`). It forks `LOAD_CONCURRENCY` background shell
loops, each doing `while true; do wget -q -O- <url>/healthz; done`, held open
for `LOAD_DURATION` seconds. `/healthz` is deliberately DB-free
(`app/main.py:272-279`) — Kubernetes hits it for liveness/readiness, so a
Postgres hiccup shouldn't kill an otherwise-healthy pod. That also means this
test measures pure HTTP-handling CPU overhead, nothing about the database path.

Not a fixed RPS — no rate limiter, no pacing. Each loop fires the next request
the instant the last one returns, so throughput self-reinforces as the app
scales out and gets faster.

**Lab (three terminals):**
```sh
# 1 — the scaling decision
kubectl -n url-shortener-prod get hpa,deployment -w

# 2 — fire the load
make load-test LOAD_CONCURRENCY=80 LOAD_DURATION=180

# 3 — why it scaled (or didn't) — read the Events: section
kubectl -n url-shortener-prod describe hpa prod-url-shortener
```
Also useful: `kubectl -n url-shortener-prod get events --sort-by='.lastTimestamp'`,
`kubectl -n url-shortener-prod top pods`, `make grafana-ui` (localhost:3000,
admin/admin), `make prometheus-ui` (localhost:9090).

### Concepts drilled hands-on (2026-09-04/05)

Ethan's own run surfaced this behavior live — replicas scaled up, then sat at 9
for several minutes with CPU already back down at 2%. Turned into a deeper pass
than originally scoped, worth keeping:

- **Scale-up is instant, scale-down is deliberately slow.** Unconfigured HPA
  `behavior` defaults to `stabilizationWindowSeconds: 0` on scale-up, `300`
  (5 min) on scale-down — it looks back over the last 5 min of recommendations
  and applies the *highest* one, specifically to avoid flapping on bursty
  traffic. Confirmed via `grep -rn behavior charts/` — nothing in this repo
  configures it; it's pure Kubernetes default, same as HPA/PDB being core API
  types kind ships for free but does nothing with until you use them.
- **HPA failure modes** (the logged weak spot, now drilled): it's reactive not
  instant (~22s lag before first scale-up in the run above); pods still need
  schedulable *nodes* — HPA and a node-level autoscaler (Cluster
  Autoscaler/Karpenter) are two separate layers; CPU-based HPA is blind to a
  non-CPU bottleneck (a saturated DB won't show as high CPU) — direct segue
  into Module 2.
- **CPU limits throttle; memory limits kill.** Same `resources:` block, two
  different failure modes — foreshadows Module 3.
- **No PodDisruptionBudget exists on this Deployment** (`kubectl get pdb` —
  empty). PDB governs *voluntary* disruptions only (node drains, managed node
  group upgrades, Cluster Autoscaler consolidation) — never involuntary ones
  (crashes, OOMKills). `minReplicas: 3` is a load-scaling floor, not a
  maintenance-disruption guarantee; those are different problems. A PDB also
  can't fix the single-replica Postgres pod — no redundancy to protect.
- **Draining a node** = cordon (stop new scheduling) + evict existing pods one
  at a time via the Eviction API (which is what checks the PDB). Pods aren't
  migrated — they're terminated with a grace period (SIGTERM, default 30s)
  and a *replacement* pod is scheduled elsewhere; what's preserved is
  workload capacity and in-flight requests, not the pod itself.
- **Draining is automated on managed cloud node groups** (EKS/GKE/AKS node
  version bumps, Cluster Autoscaler/Karpenter consolidation) but fully manual
  on unmanaged/self-managed clusters — including this local kind cluster,
  which has no cloud-provider automation layer at all. Argo CD (this
  project's GitOps tool) has nothing to do with node draining — it reconciles
  workloads against Git, a completely separate concern from node lifecycle.

### Findings from Claude's solo run (2026-09-04) — reference only, re-verify hands-on

| t | CPU util | Replicas |
|---|---|---|
| +0s | 3% | 3 (baseline) |
| +11s | 49% | 3 |
| +22s | 251% | 3 → scale triggered |
| +43s | 219% | 6 |
| +53s | 208% | 9 (max) |
| +53s–3m | 137–208% | 9, pinned at max |

- Even at `maxReplicas: 9`, CPU stayed 2–3.5x over the 60% target for the rest
  of the run. Ambiguous whether that's a real capacity gap or an artifact of
  the 3-node kind cluster sharing one laptop's cores — worth re-testing and
  reasoning through, not just citing.
- `kubectl describe hpa` showed `FailedGetScale: Unauthorized` firing 45x over
  2.8 days — the HPA controller itself briefly failing to auth against the API
  server. Self-healing, likely correlated with metrics-server restarts (5x)
  and, on a kind-on-laptop setup, probably clock skew after the host sleeps.
  Never showed up in `-w`, only in `describe`.
- The load tool itself has a gap: `wget -q` discards status codes and timing.
  It proves pods got busy, not that users were served correctly. Worth fixing
  before calling this a real load test.
- Alertmanager is off in this cluster (a cost-saving default, not a considered
  tradeoff) — none of the above would have paged anyone.

## Module 2 — Database bottlenecks

**The real bug already found (not contrived):** `_connect()` in
`app/main.py:114-116` opens a brand-new Postgres connection on *every request*,
no pooling:
```python
def _connect():
    """Open a fresh Postgres connection (one per request — simple and robust)."""
    return psycopg2.connect(_DSN)
```
`/{code}` (the redirect endpoint) does `SELECT long_url ...` then
`INSERT INTO clicks ...` per hit — a real read+write per request, unlike
`/healthz`. Postgres's `max_connections` is 100 (confirmed live, default).
Hypothesis: hammering `/{code}` should show connection count climbing toward
100 and, pushed hard enough, hard failures (`FATAL: sorry, too many clients
already`) — a different failure mode than CPU saturation.

**Lab:**
```sh
# 0 — get a real code to hit (unlike /healthz, this path needs one)
curl -s -X POST http://urlshortener.localtest.me/api/links \
  -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'

# 1 — watch Postgres connections live
watch -n2 'kubectl -n url-shortener-prod exec prod-url-shortener-postgres-0 -- \
  psql -U appuser -d urlshortener -c "SELECT count(*) FROM pg_stat_activity;"'

# 2 — fire load at the REAL path, capturing status codes this time
kubectl -n url-shortener-prod run db-load-test --rm -i --restart=Never --image=alpine:3 -- \
  sh -c 'for i in $(seq 1 80); do
    (while true; do wget -q -S -O- http://prod-url-shortener/<YOUR_CODE> 2>&1 | grep "HTTP/"; done) &
  done; sleep 60'

# 3 — app side, same as module 1
kubectl -n url-shortener-prod get hpa,pods -w
```

## Modules 3–5

Not designed yet. Rough intent, to fill in when we get there:
- **3 (pod failure injection):** `kubectl delete pod` mid-load, a deliberately
  wrong `readinessProbe`, a memory limit set below actual usage to trigger
  OOMKill — read `kubectl describe pod` events and restart counts.
- **4 (network/dependency):** break ingress-nginx routing or simulate a slow
  Postgres (e.g. an artificial `pg_sleep` in a query) and drill the four
  golden signals + "what changed" triage end-to-end.
- **5 (capstone):** Claude injects an unannounced fault; Ethan diagnoses cold
  using only the tools from modules 1–4, then writes a short postmortem.
