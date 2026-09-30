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
| 2 | Database bottlenecks | Hammer `/{code}` (the real hot path — does a Postgres `SELECT` + `INSERT` per request, see below) instead of `/healthz` | **Closed (2026-09-05 → 2026-09-17).** The original connection-exhaustion hypothesis was never cleanly confirmed — a more valuable bug (health-check thread starvation) surfaced instead, got fixed in two layers (async liveness, capacity-aware readiness), shipped through the real CI/CD pipeline, and verified on both dev and prod. |
| 3 | Pod-level failure injection | OOMKill, mid-load pod deletion, a bad readiness probe on rollout | **Done (2026-09-21 → 2026-09-23).** All three tests run hands-on and verified: pod deletion under load (zero impact), OOMKill (bypasses probes entirely), a broken readiness probe on rollout (stalls safely, never kills). |
| 4 | Network / dependency failures | A slow (not stuck) Postgres query, drilled via the four golden signals | **Closed (2026-09-25 → 2026-09-29).** Confirmed the predicted `statement_timeout` behavior, then found an unplanned real bug — a connection leak on every DB route's exception path — fixed, and verified on dev + prod under real load. |
| 5 | Capstone: blind incident | Claude breaks something without saying what; full diagnosis from cold | **Designed (2026-09-30), not yet run.** Rules, scorecard, and postmortem template below; the fault itself is deliberately not written down anywhere. |

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

**Lab (four terminals):**
```sh
# 1 — the scaling decision (HPA). NOTE: `get hpa,deployment -w` looks tempting
# but kubectl rejects --watch on more than one resource type at once
# ("error: you may only specify a single resource type") — confirmed on
# v1.36.2/v1.36.1, and there's no combination of types where it's allowed
# (tested even two plain core types together, still rejected). Split it:
kubectl -n url-shortener-prod get hpa -w

# 1b — the scaling decision (Deployment), separate pane
kubectl -n url-shortener-prod get deployment prod-url-shortener -w

# 2 — fire the load
make load-test LOAD_CONCURRENCY=80 LOAD_DURATION=180

# 3 — why it scaled (or didn't) — read the Events: section
kubectl -n url-shortener-prod describe hpa prod-url-shortener
```
Also useful: `kubectl -n url-shortener-prod get events --sort-by='.lastTimestamp'`,
`kubectl -n url-shortener-prod top pods`, `make grafana-ui` (localhost:3000,
admin/admin), `make prometheus-ui` (localhost:9090). For watching several
resource types together without juggling panes, see the note on `k9s` and on
building a Grafana dashboard from the `kube-state-metrics` this cluster
already runs, further down.

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

# 2 — fire load at the REAL path, capturing status codes this time.
# One line on purpose — see the paste gotcha below.
kubectl -n url-shortener-prod run db-load-test --rm -i --restart=Never --image=alpine:3 -- sh -c 'for i in $(seq 1 80); do (while true; do wget -q -S -O- http://prod-url-shortener/<YOUR_CODE> 2>&1 | grep "HTTP/"; done) & done; sleep 60'

# 3 — app side, same as module 1
kubectl -n url-shortener-prod get hpa,pods -w
```

**Terminal-paste gotcha (hit live, worth keeping):** the first attempt used a
multi-line version of the load-test command and zsh choked with
`bad pattern: [200~kubectl` — that's a leaked *bracketed-paste* marker
(`\e[200~`/`\e[201~`, the invisible codes a terminal wraps around a paste so
the shell treats it as one block), and when it leaks through as literal text
zsh tries to glob-match the brackets and aborts before `kubectl` ever runs.
Fix: collapse multi-line `kubectl run ... sh -c '...'` commands to one line
before pasting into zsh — nothing left for the paste marker to corrupt.

### Findings from Ethan's hands-on run (2026-09-05/06)

| Signal | Baseline | Peak during load | Read as |
|---|---|---|---|
| Postgres connections (`pg_stat_activity`) | 6 | 12 | Nowhere near the 100 ceiling — no pileup |
| HPA CPU | 3–6% | 96% (then 92%) | Real pressure, HPA reacted |
| Replicas | 3 | 5 (`ceil(3 × 96/60)`) | Proportional HPA math, not a fixed step |

- **The connection-exhaustion hypothesis didn't hold at this load level.**
  `_connect()` really does open a fresh connection per request (confirmed:
  count visibly moved off baseline under load), but each one lives only a few
  milliseconds — open, `SELECT`+`INSERT`, commit, close — so 80 concurrent
  loops never built a backlog. No pooling is a **latent risk, not an active
  one** here: it only becomes a real failure mode when connections are held
  open longer than new ones arrive (much higher concurrency, or a slow query).
- **CPU still spiked meaningfully (96%, 3→5 replicas) — but for a different
  reason than Module 1.** Establishing a *new* TCP + Postgres-auth handshake
  and spawning a fresh backend process on every request is itself real CPU
  work that a pool would let you skip entirely. So the missing pool showed up
  as a CPU tax, not a connection-count crisis — a genuinely different, more
  nuanced finding than the one we set out to reproduce.
- **Peak CPU here (96%) was much lower than Module 1's pure `/healthz` test
  (251%), despite similar tooling.** Cause: `wget` follows redirects by
  default. `/{code}` returns a `307` which `wget` then follows out to
  `https://example.com` — a second HTTP round trip per loop iteration that
  costs zero cluster CPU (it's an external site) but eats real wall-clock time
  each loop spends waiting instead of hammering the app back-to-back. Net
  effect: this test was quietly load-testing `example.com` too, and only
  landing roughly half its requests on the actual app. (`wget --max-redirect=0`
  would fix this if re-run for a fairer comparison against Module 1.)
- **We did not reproduce the "low CPU + high latency" signature** — the
  original point of testing the DB path. That pattern needs the dependency
  itself to be slow (queries genuinely queuing/blocking), not just numerous.
  Postgres was never under real stress here, so the pods were always doing
  real work, never blocked waiting — hence CPU rose instead of staying flat.
  **Next step, not yet run:** add an artificial delay (`pg_sleep(1)`) inside
  one query so connections are held open instead of released instantly — the
  actual mechanism behind a real "slow dependency" incident, and the scenario
  the HPA (CPU-only) would be blind to.

### Follow-up A — an artificial `pg_sleep`, hands-on (2026-09-10)

The connection-exhaustion hypothesis above needs a dependency that's actually
*slow* (queries genuinely blocking), not just numerous. Rather than edit
`app/main.py` (prod pulls its image from GHCR since Phase 7, so an app change
means rebuild → push → Argo sync, and it muddies "what changed"), the fault was
injected straight into the live database as a trigger:

```sql
CREATE FUNCTION slow_click() RETURNS trigger AS $$
BEGIN PERFORM pg_sleep(1); RETURN NEW; END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER clicks_slow BEFORE INSERT ON clicks
  FOR EACH ROW EXECUTE FUNCTION slow_click();
```

`/{code}`'s `INSERT INTO clicks` now takes 1s, holding its connection open for
that long instead of releasing it instantly. One dropped/re-added the whole
thing several times before it worked — worth keeping as the failure modes are
mundane and recurring:

- Pasting `C=<CODE>` literally into a `kubectl run ... sh -c` one-liner: zsh
  reads `<` as input redirection from a file called `CODE`, then chokes —
  `sh: syntax error: unexpected ";"`.
- Substituting a placeholder code (`abc123`, or a code from an *example* in
  chat) instead of the actual code returned by `POST /api/links`. Every
  request 404s before reaching the `INSERT`, so the trigger never fires — the
  run looks active (real CPU, real HPA scaling) but is silently testing the
  wrong thing entirely, indistinguishable from a real result unless you check
  for `307`/`~1s` first.
- `kubectl get hpa,deployment -w` fails on a newer kubectl:
  `error: you may only specify a single resource type` — watching two
  resource kinds together is no longer allowed; split into two `kubectl get
  <kind> -w` panes.
- `kubectl logs -l ... -f` across many pods: `maximum allowed concurrency is
  5, use --max-log-requests` — cap it or drop `-f` for a point-in-time check.

**The correct run** (real code, trigger confirmed via
`SELECT tgname FROM pg_trigger`, a single curl proving `307` in ~1s *before*
generating load), at 40 concurrent loops:

| Signal | Reading |
|---|---|
| Client latency | steady `307 ~1.01s` — every request pays the full second |
| App pod CPU | 12–18m of a 100m request — pods idle, blocked on the socket |
| Postgres CPU | 166m (down from 497m during an earlier bad run) |
| HPA `TARGETS` | fell to 2–15%/60% — **no scale-up** |
| PG connections | plateaued ~67/100, held open (vs. ~6 baseline) |

This is the signature the module was chasing: users in pain (1s on every
request), CPU near zero, so a CPU-only HPA has no signal and does nothing. A
slow dependency is invisible to it — you'd only catch this on a latency or
saturation metric. At this concurrency nothing queued (3 pods × 40 worker
threads = 120 slots > 40 loops), so latency sat flat instead of climbing, and
the ceiling was never approached — left for the next test.

### Follow-up B — a table lock, and an unplanned discovery (2026-09-14)

A cleaner way to force the *hard* failure (Postgres's `max_connections: 100`
ceiling): an uncommitted transaction holding an exclusive lock, instead of a
timed sleep. `pg_sleep` self-throttles — every connection releases itself
after 1s, so connections drain almost as fast as they fill, which is why the
above never approached the ceiling. A lock doesn't let go until you say so:

```sql
BEGIN;
LOCK TABLE clicks IN ACCESS EXCLUSIVE MODE;  -- held open, not committed
```

`/{code}`'s `SELECT` still works (different table); the `INSERT` right after
blocks indefinitely. Run by Claude at Ethan's explicit request while Ethan
observed (not independently re-run hands-on by Ethan — flagged here rather
than folded silently into "done"), 120 concurrent loops against the real code:

**What happened was not the connection-ceiling test — it was worse, and more
useful.** Around 45–60s in, all 40 worker threads per pod filled with
requests blocked on the lock. `/healthz` shares that exact thread pool despite
touching no database — so it stopped being able to run at all. The literal
kubelet event:

```
Liveness probe failed: Get "http://...:8000/healthz": context deadline
exceeded (Client.Timeout exceeded while awaiting headers)
```

Kubernetes concluded the pods were dead and killed them — pods that were
never actually broken, just busy. Readiness then also failed post-restart
(`connection refused`, container still starting). Nearly every pod restarted
1–9 times within ~90 seconds; each restart severed that pod's blocked
Postgres connections, so the connection count kept getting yanked back down
instead of climbing to a clean plateau — the original hard-failure hypothesis
(`FATAL: sorry, too many clients already`) was never actually reached,
because Kubernetes' own self-healing intervened first. The HPA scaled to its
max (9 replicas), but from the CPU cost of repeated container restarts, not
from sustained real load — a good example of an autoscaling metric being
noisy and misleading during a cascading probe-failure incident, and of
automated remediation (restart-on-failed-liveness) making an incident worse:
killing an overloaded-but-fine pod doesn't fix overload, it just adds churn.

**Root cause:** `/healthz` was defined as a synchronous `def`, so FastAPI ran
it through the same shared worker-thread pool as every DB-touching route.
Being "DB-free" in its own code didn't matter once that pool was fully
occupied by other requests — it never got a thread to run on.

**Fix 1 applied and verified (2026-09-15):** `/healthz` in `app/main.py` is
now `async def` instead of `def`, so it runs on the event loop instead of the
shared worker-thread pool. Shipped through the real pipeline (commit → push →
CI build+push to GHCR → Argo sync to dev) and re-tested on dev by repeating
this exact table-lock fault against the freshly deployed image — 1 replica,
60 concurrent loops (over the 40-thread pool), lock held ~70s:

| | Before (prod, sync `healthz`) | After (dev, async `healthz`, same fault) |
|---|---|---|
| Restarts | up to 9 in ~90s | **0** |
| `/healthz` while saturated | timed out (`context deadline exceeded`) | **200 in 3–9ms**, every check |
| Connections | chaotic (33 ↔ 105, kept getting severed by restarts) | climbed to 42, **held flat** — clean plateau |
| Probe-failure events | multiple `Unhealthy` | **none** |

Confirms the mechanism precisely: the pod's *actual* work (every `/{code}`
request) still stalls exactly as before — that part is untouched — but
Kubernetes now correctly reads "alive, just busy" instead of "dead," and
stops making the incident worse by restarting a pod that isn't broken.

**What fix 1 alone does *not* solve — and makes slightly worse in one way:**
liveness and readiness pointed at the same endpoint, so fixing it made
*readiness* report healthy too. A pod with all 40 threads permanently wedged
now stays in the Service's traffic rotation indefinitely — Kubernetes has no
signal that it can't actually do anything, so it keeps routing new requests
into a queue that will never drain. Silent, dashboard-green, zero real
capacity — worse than the restart storm in the sense that nothing about it
looks wrong from the outside.

**Fix 2 applied (2026-09-16):** a new `/readyz` endpoint, separate from
`/healthz`, answers a different question — not "is the process alive" but
"does this pod have spare capacity right now." It reads FastAPI's shared
worker-thread limiter directly (`anyio.to_thread.current_default_thread_
limiter()`) and returns `503` once `available_tokens` hits 0. Deliberately
reads a counter instead of running a query or acquiring a connection, so the
readiness check itself can never get stuck in the exact contention it exists
to detect. The Helm chart's `readinessProbe` now points at `/readyz` while
`livenessProbe` stays on `/healthz` (`charts/url-shortener/templates/
app.yaml`, chart bumped to 0.5.0) — the two probes finally check two
different things instead of one shared one. `anyio` (already a transitive
dependency via FastAPI/Starlette, confirmed 4.15.1 in the built image) is now
pinned directly in `requirements.txt` since the app imports it itself.

Net effect once this ships: a saturated pod fails *readiness* (pulled from
the Service, no restart) while liveness stays green (it's not broken) — and
it rejoins automatically the moment a thread frees up. No restart, no manual
intervention, no more silent black hole.

**Shipped and verified on dev (2026-09-17).** Went through the real pipeline
(commit → push → CI build+push → Argo sync), then the same table-lock fault
was repeated against dev, this time watching `/readyz`, the pod's `Ready`
condition, and the Service's `Endpoints` object together:

| | |
|---|---|
| `/readyz` under saturation | `{"status":"saturated","available_threads":0,"total_threads":40}` |
| Pod pulled from Service endpoints | moved from `addresses` to `notReadyAddresses`; kubelet logged `Readiness probe failed: ... statuscode: 503` |
| Restarts, entire test | **0** |
| After lock released | pod flipped back to `Ready` and rejoined endpoints **automatically** — `/readyz` back to `40/40`, no restart, no manual fix |

Confirms the fix does exactly what it's for: a saturated pod is pulled from
traffic, not killed, and self-heals the moment capacity returns.

**Gotcha hit along the way — a CI/CD race between a chart change and the
image that implements it.** The probe-path change (`readinessProbe` →
`/readyz`, in the chart) and the code that serves that route (in the image)
landed in the same commit, but they don't *ship* at the same time: the chart
change is live the instant Argo syncs the commit, while the new image only
exists once CI's build job finishes and writes a follow-up commit a minute or
two later. In that window, Argo pointed the readiness probe at `/readyz` on a
pod still running the *previous* image — which doesn't have that route —
so it 404'd, the rollout stalled ("1 old replicas are pending termination"),
and the pod never went `Ready`. It self-resolved once CI's tag-bump commit
landed and Kubernetes cut over to a ReplicaSet with the correct image+probe
combination, but a slower CI run (or a manual chart-only edit with no
matching image change) could leave a deployment stuck like this for a while.
Worth remembering as its own class of CI/CD footgun: a probe change and its
implementing code are coupled and should land together, atomically, not
across two separate commits with a gap in between.

**A second, more fundamental finding — redundancy and readiness are a
package deal.** For part of the saturation window, `/healthz` *itself*
returned `503` too, going in through the public hostname — but it wasn't the
app failing (kubelet's own liveness probe, which hits the pod directly by IP
and bypasses the Service, kept passing the whole time — that's exactly why
restarts stayed at 0). It was **nginx** returning its own error page, because
dev runs a single replica: the instant that one pod got marked `NotReady`,
the Service had *zero* ready endpoints, and ingress-nginx had nowhere to
route any request at all — mine included. Pulling a saturated pod from
rotation only degrades gracefully if there's another pod left to take the
traffic. With one replica, "graceful" and "total outage" are the same event.
Prod runs `minReplicas: 3`, so the same fault there should pull one bad pod
while the other two keep serving — degraded, not dark; worth confirming
directly when this ships to prod, not just assumed.

**Fix 3 (2026-09-18): `lock_timeout`/`statement_timeout` — the self-healing
layer.** Both probe fixes stop Kubernetes from making a stuck-DB incident
worse, but neither one bounds how long a query can actually stay stuck — a
saturated pod depended entirely on something else (redundancy, or readiness
eventually pulling it) to recover. `_connect()` in `app/main.py` now opens
every connection with `lock_timeout=1000` / `statement_timeout=2000`
(milliseconds) via psycopg2's `options` parameter. Safe to set this
aggressively here specifically because every query in this app is a single
indexed lookup or single-row insert — no legitimate case for taking more than
tens of milliseconds. Verified directly against a live lock before it even
shipped: an `INSERT` failed with `LockNotAvailable` at exactly `1.00s`.

Worth being precise about what this fixes and what it doesn't: the table
lock itself is not something that happens naturally — nobody's database
spontaneously grabs `ACCESS EXCLUSIVE` and sits on it forever; that was
engineered on purpose because it's a controllable, deterministic fault for a
lab. But the underlying *class* of problem — a request stuck waiting on the
database long enough to tie up a worker thread — is genuinely common, just
usually with more mundane triggers: a live schema change (`ALTER TABLE`,
`CREATE INDEX` without `CONCURRENTLY`) run against a live table, a forgotten
open transaction from a debugging session, a batch/cleanup job holding a
lock longer than expected, or simply a table that grew past what an index
can serve quickly. `lock_timeout`/`statement_timeout` don't care *why* a
query is stuck — real cause or engineered one, they look identical to the
app — which is why the fix generalizes rather than only patching the
specific fault used to find it.

**Verified on dev (2026-09-18), one continuous timeline (bash `SECONDS`, no
inter-call gaps this time — an earlier two-command version of this test had
an untrustworthy timeline and was explicitly re-run for this reason):**

| t | What happened |
|---|---|
| 0–20s | Same fault as Fix 2's test (table lock + 60-loop saturating load) running simultaneously. `/readyz` oscillates between `saturated` (0 threads) and partial recovery (8–11 free) as blocked requests keep timing out and getting replaced. Every live request either fails **fast** (0.01–1.87s) or occasionally succeeds — **never hangs** |
| 20s | Load's firing window ends; no more new attempts generated |
| 22–24s | Threads fully recover to `40/40` |
| 25s | Lock releases (matches the lock session's own `COMMIT` log) |
| 26s+ | Genuine `307` successes resume, ~15ms — fully normal |

**`podReady` stayed `true` for all 17 samples across the entire test** —
even while repeatedly touching full saturation, it never accumulated the 3
*consecutive* probe failures (~15s at this chart's `periodSeconds: 5`)
needed to flip `NotReady`. The timeout resolves fast enough that readiness
never has to step in — the layers work together exactly as designed, not
redundantly. Restarts stayed at 0, as expected (liveness was never at risk
here). Worst observed request latency: 1.87s — bounded, compared to the
fully unbounded hang (however long a human chose to hold the lock) before
this fix existed.

**Confirmed on prod (2026-09-17).** Both fixes promoted via `promote.yml`
(the exact tag verified on dev, `196e475`), Argo rolled all 3 replicas
cleanly, 0 restarts. Re-ran the identical table-lock fault, this time aimed
at **one specific pod's IP directly** (bypassing the Service's round-robin)
so exactly one of three would saturate on purpose, rather than leaving it to
chance:

| | |
|---|---|
| Targeted pod | `NotReady` at t=12s, pulled from the Service's endpoint list |
| Other two pods | stayed `Ready` the entire test, never left the endpoint list |
| Public traffic (`urlshortener.localtest.me/healthz`, through ingress) | **`200` on every check, the full 84s** — zero visible degradation |
| Restarts, all 3 pods | **0** |
| HPA | `4%/60%`, untouched — nothing CPU-expensive happened this time |
| Recovery | targeted pod rejoined `Ready` and the endpoint list automatically at t=57s, right after the lock released |

This is the dev result's mirror image, exactly as predicted: identical fault,
identical fix, but `minReplicas: 3` turns "one pod wedged" into invisible
degraded capacity instead of a total outage. Module 2 closes here — the
original connection-exhaustion hypothesis was never confirmed, but the path
that replaced it (async liveness → capacity-aware readiness → redundancy)
produced two real, shipped, prod-verified fixes and a clear demonstration of
why they only work together.

## Operational note: pausing the cluster without destroying it

Discovered 2026-09-06: after ~49–56 days of continuous uptime, the cluster
(3 kind nodes + Postgres + Argo CD + Prometheus/Grafana, all inside Colima's
VM) was a measurable drag on the host laptop — Colima's VM disk image alone
had grown to **19GB**, plus the always-on RAM/CPU reservation competing with
everything else running. Confirmed via `colima status`, `ps aux`, `vm_stat`
that stopping it fully released those resources.

**To pause for a while and resume later, use `colima stop` / `colima start` —
never `make down`.** `make down` calls `kind delete cluster`, which destroys
everything (Postgres data, Argo CD state, all Helm releases) and requires a
full `make up` rebuild. `colima stop` just pauses the VM; all container
filesystems are untouched on disk and come back with `colima start`. Expect a
possible transient `FailedGetScale: Unauthorized` in `describe hpa` right
after resuming (see Module 1 findings) — self-heals within a minute, harmless.

## Operational note: watching several resource types at once

`kubectl get <type1>,<type2> -w` doesn't work — confirmed unconditional (even
two plain core types like `pods,replicasets` are rejected the same way), not
version- or resource-specific. Two real options instead of split panes:

- **`k9s`** (`brew install k9s`) — a terminal UI that talks to the same
  watch API directly. Doesn't merge two types into one table either, but
  switching between live single-type views is a two-character command
  (`:hpa`, `:deploy`, `:pods`) instead of a fresh `kubectl` invocation in a
  new pane, and it drills into logs/shell/describe from the same screen.
- **Grafana** (`make grafana-ui`) — a genuinely different category: not a
  live object-state viewer, a stored *metrics* dashboard. This cluster
  already runs `kube-state-metrics` (part of the `kube-prometheus-stack`
  install from Module 5's monitoring phase), which turns Kubernetes object
  state itself — HPA current/desired replicas, deployment ready-replica
  counts, pod restart counts, pod ready/not-ready — into Prometheus metrics.
  That means a single dashboard with multiple panels (HPA target %, replica
  count, restart count, ready-pod count) is genuinely buildable, all
  auto-refreshing together. The real tradeoff: Grafana refreshes on
  Prometheus's scrape interval (commonly 15–30s), not instantly like `-w` —
  fine for watching a trend over minutes, too coarse for the kind of fast
  fault injection this lab does (a lock going up and a pod flipping
  `NotReady` inside 10–15s can blur or be missed entirely between scrapes).
  That's why every module here uses raw `kubectl` polling every 2–5s instead
  of Grafana during an active test.

## Module 3 — Pod-level failure injection

**Why this module is different from 1 and 2:** those both broke something
*external* to a pod (CPU load, a DB lock) and watched Kubernetes react. This
module breaks pods *directly* — kills them, starves their memory, ships a
probe that can never pass — and drills the specific self-healing mechanism
each failure triggers. It also has a real, unplanned head start: Module 2's
table-lock test showed liveness and readiness sharing one thread pool with
request handling, which caused Kubernetes to restart pods that were busy, not
actually broken. Test C below re-tests that exact scenario now that the
async `/healthz` + capacity-aware `/readyz` fix is live, to confirm the fix
actually holds under a fresh angle rather than just the original repro.

Three independent tests, each isolated (run one, let the Deployment settle
back to steady state, then move to the next):

### Test A — `kubectl delete pod` mid-load

**Mechanism:** a Deployment's whole job is to keep the *desired replica
count* running, not any specific pod — so deleting one directly (not
`kubectl scale`, not a crash) is the cleanest way to isolate "how fast and
how visibly does self-healing happen" from any of the CPU/DB variables in
Modules 1–2. With 3 prod replicas behind a Service, deleting one should be
invisible to traffic: the Service already excludes it once it's Terminating
(kubelet marks it `NotReady` and removes it from Endpoints before the
container actually stops), and the ReplicaSet controller notices the
replica-count gap and schedules a replacement immediately.

**What to watch for:** the gap between "pod marked for deletion" and "new
pod Ready" — that's the real user-facing blast radius, not the deletion
itself. And whether the Service's endpoint list ever drops below 2 addresses
(if it does, that's a sign requests hit a `Terminating` pod through a race,
worth digging into rather than shrugging off).

**Lab (three terminals):**
```sh
# 1 — watch pods churn
kubectl -n url-shortener-prod get pods -w

# 2 — watch which pods the Service actually considers healthy
kubectl -n url-shortener-prod get endpoints prod-url-shortener -w

# 3 — fire load, then mid-run, delete one pod
make load-test LOAD_CONCURRENCY=20 LOAD_DURATION=60
# in a fourth terminal, once load is running:
kubectl -n url-shortener-prod delete pod <one-of-the-three-pod-names>
```
Afterward: `kubectl -n url-shortener-prod get events --sort-by='.lastTimestamp'`
to read the Killing/Scheduled/Pulled/Started sequence with real timestamps.

### Findings — Test A (2026-09-21)

Two hiccups on the way to a valid run, both worth remembering:

- **First attempt deleted a pod before load was running at all** — proved
  self-healing works, but not that it's invisible to traffic, since nothing
  was requesting anything during the gap.
- **Second attempt deleted a pod *after* the HPA had already scaled to 9**
  (20 concurrent loops against `/healthz` is enough CPU to cross the 60%
  target), so a 3-pod outage story became "one of nine," a much smaller
  blast radius, and no longer testing what Test A set out to test. Waited
  for the HPA's 5-minute scale-down stabilization back to 3 before retrying.

**Clean run, one continuous script (client probe every ~0.2s against
`/healthz` through the real ingress, endpoint/pod state polled every 1s, all
on one shared clock):**

| t (s) | Event |
|---|---|
| 0–14 | Load running, 3/3 endpoints, all probes `200` |
| 14 | `kubectl delete pod` on one of the three |
| 15 | Endpoints **3 → 2** — the dying pod is `Terminating`; its replacement (`skwh9`) appears at `Init:0/1` in the same second |
| 16–21 | Replacement is `Running` but `0/1` — not yet in Endpoints, `/readyz` gating it out |
| 22 | Replacement hits `1/1`, endpoints back to **3** |

**Result: 322/322 probes returned `200`, including all 38 fired during the
14–22s kill-and-replace window.** Endpoints never dropped below 2. Total
replacement time ≈ 8s, of which ~1s was the init container
(`wait-for-postgres`, a `pg_isready` loop gating the app container's start)
and the rest was the app itself waiting out `/readyz`'s own gate.

**What this run doesn't prove:** the client probe only measured whether new
requests succeeded, at low concurrency (~5 req/s) — it can't say whether a
request already in flight on the pod at the moment of deletion survived, and
the deletion here was graceful (`SIGTERM`, not a hard kill), so the app got
to finish in-flight work cleanly. See the "graceful vs. ungraceful shutdown"
discussion below Test B for the harder case.

### Test B — OOMKill

**Mechanism:** set the app's memory *limit* below what it actually uses at
rest, so the container gets killed by the kernel's cgroup OOM killer, not by
a Kubernetes probe. This is a fundamentally different failure signature from
everything in Modules 1–2 — no probe ever gets a chance to fail, because the
process is killed at the OS level the instant it crosses the memory
ceiling — and it's worth seeing that distinction live rather than just
reading about it.

**What to watch for:** `kubectl describe pod` reporting
`Last State: Terminated, Reason: OOMKilled, Exit Code: 137` — 137 = 128 + 9
(`SIGKILL`), the kernel giving the process no chance to clean up — and the
restart count incrementing with **no** corresponding liveness-probe failure
event, proof this path bypasses probes entirely.

**Lab (as actually run — see findings below for why the original plan
changed):**
```sh
# helm upgrade doesn't work here -- see findings. Argo CD renders this chart
# itself and applies manifests directly; there's no Helm-tracked release to
# upgrade ("has no deployed releases"). Patch the live Deployment instead:
kubectl -n url-shortener-prod patch deployment prod-url-shortener --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"limits":{"memory":"16Mi","cpu":"500m"},"requests":{"memory":"8Mi","cpu":"100m"}}}]}}}}'
# (requests must drop below the new limit too, or the API server rejects the patch)

kubectl -n url-shortener-prod get pods -w
kubectl -n url-shortener-prod describe pod <the-oomkilled-pod>
```
Revert the same way, with the real values, once done. **Both of Argo's
self-heal layers need to be off first** — see findings for why; the two
commands are in the findings section below.

### Findings — Test B (2026-09-22 → 2026-09-23)

This test fought GitOps self-heal for two full rounds before producing clean
evidence — worth documenting in detail, since the fight itself became the
more interesting lesson for a while.

**Round 0 — `helm upgrade` doesn't work at all.** `helm list -n
url-shortener-prod` shows zero releases. Argo CD doesn't install this chart
via Helm's own release/revision bookkeeping — it renders the chart
internally and applies the resulting manifests directly, so there's nothing
for `helm upgrade` to attach to (`Error: UPGRADE FAILED: "prod-url-shortener"
has no deployed releases`). Switched to `kubectl patch` on the live
Deployment instead — the same category of move as Test A's `kubectl delete
pod`, an imperative one-off against a live object rather than a chart
change.

**Round 1 — self-heal reverted the patch in under a second.** The patched
pod (new ReplicaSet, new pod-template hash) went `Init:0/1` →
`Terminating` → `Error` within 3 seconds of being created — too fast to be
a real OOM. `kubectl -n argocd get application prod -o
jsonpath='{.status.operationState}'` showed a sync `startedAt`/`finishedAt`
about one second apart, timestamped right when the patch landed: Argo's
`prod` Application (`selfHeal: true`, `gitops/apps/prod.yaml:31`) noticed
the live Deployment drifted from git and reverted it almost instantly. Not
a 3-minute polling cycle — Argo's app controller watches managed resources
live via informers, not just on a timer, so drift correction on a resource
it directly owns can be sub-second.

**Round 2 — disabling `prod`'s own self-heal got reverted too, just as
fast, by a different app.** `kubectl -n argocd patch application prod
--type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'`
reported success, but a follow-up `get` immediately showed `selfHeal: true`
again. Reason: `prod`'s own sync policy is *itself* declared in git
(`gitops/apps/prod.yaml`), and that file is watched by the root app-of-apps,
`url-shortener-root` — which *also* has `selfHeal: true`. Patching a live
object that a parent Application considers itself the source of truth for
just gets reverted by the parent, same mechanism, one level up the
app-of-apps tree. Disabling `url-shortener-root`'s own self-heal (nothing
sits above it — it's the one thing bootstrapped by hand) is what actually
let a change to `prod`'s syncPolicy stick.

**Round 3 — turning off root's self-heal wasn't enough on its own.** With
only `url-shortener-root`'s self-heal off, the memory patch on the
Deployment kept reappearing and disappearing over roughly 22 minutes (two
distinct attempts, `wtjdh` then `snnnp`, each a brand-new pod object, never
the same one restarting). Checked the live Deployment mid-test and found it
back at the real values (`256Mi`/`128Mi`) — meaning `prod`'s **own**
`selfHeal: true` (a separate field from `url-shortener-root`'s, governing
the actual workload resources rather than the Application CR's own spec)
was still independently reverting the patch, just on its normal reconcile
cadence rather than instantly. Disabling root's self-heal only stopped root
from reverting *`prod`'s spec* — it did nothing to stop `prod` from
reverting *the Deployment*. Two separate self-heal flags, two separate
levels of the tree, both had to be off at once:
```sh
kubectl -n argocd patch application url-shortener-root --type merge -p \
  '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
kubectl -n argocd patch application prod --type merge -p \
  '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
```
This step was blocked when attempted by Claude Code directly — the tool's
own auto-mode classifier flagged disabling self-heal as "Security Weaken"
and required Ethan to run it by hand. A real, deliberate guardrail, same
category as the `gh workflow run promote.yml` block from Module 2's prod
promotion — not a bug.

**The clean run, once both flags were actually off:** the same pod
(`jwxpd`) restarted in place 4 times over ~90s, backoff intervals growing
(~10s, ~25s, ~40s apart) exactly as `CrashLoopBackOff` is supposed to
behave. `kubectl describe pod` confirmed:
```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
Restart Count:  4
```
`137 = 128 + 9` (`SIGKILL`) — the kernel's OOM killer, no graceful shutdown
possible. The init container (`wait-for-postgres`) was unaffected the whole
time (`Exit Code: 0`, `Reason: Completed`, under a second) since the patch
only touched the `app` container's resources. **No `Unhealthy`/liveness-probe
event appears anywhere in this pod's Events** — the clean confirmation of
what this test set out to show: an OOMKill bypasses Kubernetes' probe
machinery entirely, a completely different failure path from Module 2's
probe-starvation bug. The other 3 prod pods stayed `1/1 Running`, 0
restarts, throughout — the crash-looping pod was never Ready, so it never
took traffic and never affected the working ones.

**Why this crash loop never self-resolves, on purpose:** the fault here
isn't a spike or a leak — the 16Mi limit is below what the app needs just to
finish importing/starting, before it ever serves a request. Every attempt
fails identically, at the same point, for the same reason, forever, because
neither side of the mismatch moves on its own. That's a useful diagnostic
pattern to recognize for real: a service in `CrashLoopBackOff`/`OOMKilled`
where **every** replica fails near-instantly and identically points at a bad
config (a limit, most likely), not a memory leak — a genuine leak wouldn't
kill a brand-new pod within its first second of life. Contrast the three
shapes an OOMKill can take: every-replica/instant/deterministic (bad
config, this test), slow-climb-then-die-then-repeat (a leak), or
correlated-with-traffic-spikes (per-request memory under-provisioned for
some requests but not others).

**Cleanup:** reverted the Deployment to the real values (`limits:
{cpu: 500m, memory: 256Mi}`, `requests: {cpu: 100m, memory: 128Mi}`, from
`values-prod.yaml`) and re-enabled both self-heal flags (`url-shortener-root`
then `prod`). Confirmed back to 3/3 `Running`, 0 restarts, both Applications
`selfHeal: true` again.

### Test C — a readiness probe that can never pass, during a rollout

**Mechanism:** ship a new image with `/readyz` deliberately pointed at a
nonexistent path (a stand-in for "someone's code change broke health checks
and it shipped anyway"). Kubernetes' rolling-update strategy won't route
traffic to a new pod until it's `Ready`, and won't scale down an old
(working) pod until a new one *is* — so a rollout with a broken readiness
probe should hang forever with zero downtime, not take the app offline. This
is the real payoff of the liveness/readiness split from Module 2: readiness
failing should only ever pull a pod from traffic and block a rollout, never
kill it — confirm that's actually what happens, on purpose this time instead
of by accident.

**What to watch for:** `kubectl rollout status` never completing, old pods
staying `Running`/`Ready` the entire time, new pods stuck `0/1 Ready`, and
critically — **zero liveness restarts** on the new pods, since a bad
readiness probe alone should never trigger a kill.

**Lab (as actually run):** no new image needed — the bug this test models
doesn't require broken app code, just a chart/app disagreement over a
string. `/readyz` stays correctly implemented; only the *chart's* probe
config is patched to ask for a path the app never registered. Same
`kubectl patch` pattern as Test B, and same precondition: **both of Argo's
self-heal layers (`url-shortener-root` and `prod`) have to be off first**,
or the patch gets reverted before the rollout can even get stuck.
```sh
kubectl -n argocd patch application url-shortener-root --type merge -p \
  '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
kubectl -n argocd patch application prod --type merge -p \
  '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'

kubectl -n url-shortener-prod patch deployment prod-url-shortener --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"app","readinessProbe":{"httpGet":{"path":"/ready","port":8000},"initialDelaySeconds":3,"periodSeconds":5}}]}}}}'

kubectl -n url-shortener-prod get pods -w
kubectl -n url-shortener-prod rollout status deployment/prod-url-shortener
kubectl -n url-shortener-prod describe pod <the-stuck-pod>
```
Recover by patching the path back to `/readyz` (not `rollout undo` — the
live template is what's wrong, and patching it back matches git exactly),
then re-enable both self-heal flags.

### Findings — Test C (2026-09-23)

Clean run this time — no confounders, because both self-heal levels were
disabled *before* the fault, from having already paid for that lesson in
Test B.

**The rollout stalled exactly as predicted, indefinitely:**
```
Waiting for deployment "prod-url-shortener" rollout to finish: 1 out of 3 new replicas have been updated...
```
Confirmed for over 2 minutes with no progress and no error — a rollout with
a broken readiness probe doesn't fail loudly, it just never finishes.

**The new pod never reached the Service's endpoint list.** `kubectl -n
url-shortener-prod get endpoints prod-url-shortener` showed the same 3
original pod IPs the entire time; the new pod's IP never appeared, even
though it had been `Running` for minutes.

**The actual proof, straight from the pod's own events:**
```
Warning  Unhealthy  35s (x25 over 2m35s)  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
```
Real confirmation of the exact mechanism: kubelet hit `/ready`, got FastAPI's
default 404 for an unregistered route, and correctly read that as "not
ready" — once every 5s (`periodSeconds: 5`), 25 times over the window.

**The two things this test set out to prove, both confirmed:** `Restart
Count: 0`, container `State: Running` throughout — never touched by
liveness, which is a fully independent probe (`http-get
http://:8000/healthz`) that never appears anywhere in this pod's events.
And public traffic through the real ingress, checked live during the stuck
rollout: `200 200 200 200 200` — zero visible impact, the whole time.

**What this confirms about the Module 2 fix, on a fresh angle:** a broken
readiness probe — even a permanently, deterministically broken one that
will never self-resolve — only ever pulls a pod from traffic and blocks
forward progress on a rollout. It never kills anything. That's the
liveness/readiness split from Fixes 1–2 doing exactly its job, verified
here from an intentional, different trigger than the accidental one that
originally found the bug.

Module 3 closes here — all three tests done, self-heal cleanup confirmed
back to normal (`selfHeal: true` on both `prod` and `url-shortener-root`,
3/3 pods `Running`, 0 restarts).

## Module 4 — Network/dependency failure: the four golden signals, drilled

**Why this module is shaped differently from 1–3:** each of those isolated
one specific mechanism and confirmed a specific hypothesis, using
internals-aware diagnostics (thread-limiter internals, `pg_locks`, exact
`describe pod` fields). This module drills a different skill: given a fault,
work it *systematically* through the four golden signals — latency,
traffic, errors, saturation — plus "what changed," the way real on-call
triage actually starts, using this project's own observability stack
(Grafana/Prometheus) rather than internals.

**Mechanism:** reuses the trigger-based `pg_sleep` technique from Module 2's
Follow-up A — injected straight into Postgres, not the app, so "what
changed" has a real, checkable, correct answer (nothing did, in git or
Argo). The sleep duration this time is deliberately **3 seconds** —
*longer* than Fix 3's `statement_timeout` (2s). That's not arbitrary: Fix
3 was verified once already, but only via a table lock, which exercises
its `lock_timeout` half. A plain slow-running statement (no lock involved)
exercises the separate `statement_timeout` half, which has never been
directly confirmed. This module tests that.

```sql
CREATE FUNCTION slow_click() RETURNS trigger AS $$
BEGIN PERFORM pg_sleep(3); RETURN NEW; END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER clicks_slow BEFORE INSERT ON clicks
  FOR EACH ROW EXECUTE FUNCTION slow_click();
```

**A prediction worth writing down before running it, so the result can
actually surprise us:** `app/main.py`'s redirect route
(`app/main.py:389-400`) has no `try`/`except` around its DB calls. If
`statement_timeout` correctly cancels the `INSERT` at ~2s, that raises a
`psycopg2` exception with nothing in this app's code to catch it — it
should propagate uncaught to FastAPI's default handler. Predicted result:
a plain, generic `500` at ~2s, not a clean `503` and not the full 3s hang.
Worth confirming exactly what a real client sees, since "the timeout fired
correctly" and "the failure is handled *well*" are two different claims.

**Lab:**
```sh
# 0 — get a real code to hit
curl -s -X POST http://urlshortener.localtest.me/api/links \
  -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'

# 1 — inject the fault directly into Postgres (not the app -- keeps "what
# changed" honest: nothing in git or Argo will show this)
kubectl -n url-shortener-prod exec -i prod-url-shortener-postgres-0 -- \
  psql -U appuser -d urlshortener <<'SQL'
CREATE FUNCTION slow_click() RETURNS trigger AS $$
BEGIN PERFORM pg_sleep(3); RETURN NEW; END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER clicks_slow BEFORE INSERT ON clicks
  FOR EACH ROW EXECUTE FUNCTION slow_click();
SQL

# 2 -- sanity check ONE request before generating load (the Module 2
# "wrong code" gotcha applies here too)
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  http://urlshortener.localtest.me/<YOUR_CODE>

# 3 — fire load
kubectl -n url-shortener-prod run db-load-test --rm -i --restart=Never --image=alpine:3 -- sh -c 'for i in $(seq 1 20); do (while true; do wget -q -S -O- http://prod-url-shortener/<YOUR_CODE> 2>&1 | grep "HTTP/"; done) & done; sleep 60'
```

**The drill — work these signals in order, don't jump to a conclusion
early:**

1. **Latency** — `make grafana-ui`, the app dashboard's latency panel, or a
   plain `curl -w` loop against `/<YOUR_CODE>`.
2. **Traffic** — request rate, same dashboard (or the load generator's own
   throughput).
3. **Errors** — status-code breakdown. This is the one to watch closely
   given the prediction above — is it `307`s that got slow, or real
   non-2xx failures, and at what rate?
4. **Saturation** — `/readyz`'s thread-pool numbers, `kubectl top pods`,
   live Postgres connections
   (`kubectl -n url-shortener-prod exec prod-url-shortener-postgres-0 --
   psql -U appuser -d urlshortener -c "SELECT count(*) FROM
   pg_stat_activity;"`), the HPA's CPU target.
5. **"What changed"** — `git log --oneline -10`,
   `kubectl -n argocd get application prod -o
   jsonpath='{.status.sync.revision}'`,
   `kubectl -n url-shortener-prod get events --sort-by=.lastTimestamp`. The
   correct conclusion here is "nothing" — a live, ad hoc DB-side event with
   no corresponding deploy. Recognizing *that* is itself the point: not
   every real incident traces back to something in git.

**Cleanup:**
```sh
kubectl -n url-shortener-prod exec -i prod-url-shortener-postgres-0 -- \
  psql -U appuser -d urlshortener <<'SQL'
DROP TRIGGER clicks_slow ON clicks;
DROP FUNCTION slow_click();
SQL
```

### Findings — Module 4 (2026-09-25 → 2026-09-29)

**The predicted part held exactly.** Sanity check: `500` at `2.3s` — matches
`statement_timeout` (2000ms) plus a little overhead. Load test: every single
request failed with `500` for the full run, because the fault is a
*permanent* 3s tax on every insert, not a transient one — there was never
going to be a request that succeeded while the trigger was attached. Pods
stayed `Running`, 0 restarts — liveness genuinely never involved, exactly as
predicted.

**What wasn't predicted, and became the real finding:** Postgres connections
climbed for the whole 60s run and ended in `FATAL: sorry, too many clients
already` — confirmed live: `pg_stat_activity` showed **103** connections
against a **100** ceiling, **97 idle**, the oldest 10+ minutes old, each
one's last statement a bare `ROLLBACK`. That combination — transaction
cleaned up, connection never closed — pointed straight at a real bug rather
than exhausted capacity from legitimate work.

**Root cause:** `app/main.py`'s DB routes used `with _connect() as conn:`.
psycopg2's own `with connection:` only wraps the *transaction* (commit on a
clean exit, rollback on an exception) — it never closes the connection
either way, regardless of outcome. With no connection pooling in this app,
the success path mostly got away with it (short-lived objects get garbage
collected reasonably promptly), but the exception path — which, under this
fault, was *every single request* — left a live connection sitting open
with nothing to ever reclaim it. Not specific to the artificial `pg_sleep`:
any unhandled exception on a DB-touching route leaks the same way, in real
production use, unrelated to this lab.

This closes Module 2's very first hypothesis for real. "No pooling →
connection exhaustion" was proposed back at the start of Module 2, never
confirmed under normal load (connections peaked at 12/100), and set aside in
favor of the probe-starvation bug that turned out to be there instead.
Turns out the original hypothesis was true all along — it just needed a
fault that makes *every* request throw to actually surface it, rather than
the successful, well-behaved load the earlier tests generated.

**Fix 4 (2026-09-29): a connection-lifecycle context manager.**
`app/main.py` adds `_db()` — `_connect()` wrapped in a `try`/`finally` so
`.close()` always runs regardless of outcome — and swaps all four DB call
sites (`_init_db`, `create_link`, `link_stats`, `follow`) onto it. Minimal
diff: each call site only changes `_connect()` → `_db()`, so the fix lives
in exactly one place rather than four repeated `try`/`finally` blocks that
could drift out of sync or get missed on a future fifth route.

**Verified on dev, against the real running app** (not just an isolated
script — an early attempt at that showed the isolated-script version of
this test doesn't reliably reproduce the leak's timing, since Python's own
reference counting can close a leaked connection anyway once a caught
exception's traceback goes out of scope; the real bug's persistence depends
on how long the ASGI server's own error-handling machinery holds that
traceback alive, which a standalone script doesn't replicate — so this was
verified the same way every other fix in this lab has been, against the
real deployed app under the real fault, not a synthetic stand-in):
re-injected the identical `pg_sleep(3)` trigger, fired the identical 20
concurrent loops for 45s. **Connections held flat at 26 (baseline 6 + 20
in-flight) for the entire run, idle count 0 throughout, back to 6 within 5
seconds of the load ending.** 440/440 requests got `500`, as expected — the
fix doesn't make the permanently-slow dependency succeed, it stops the
*failures themselves* from compounding into a second, worse outage.

**Confirmed on prod (2026-09-29),** promoted via `promote.yml`, all 3
replicas rolled onto the fix cleanly, 0 restarts. Identical fault,
identical load: connections held flat at 26, idle 0 the entire 45s, back to
6 within 5s of load ending, 420/420 requests `500`. Public traffic
(`/healthz` through the real ingress) stayed `200` throughout — the fix
holds under real traffic, not just the isolated dev repro.

Module 4 closes here, with an unplanned second finding on top of the
planned one — same shape as Module 2, where the test built to confirm one
hypothesis found a more valuable bug than the one it went looking for.

## Module 5 — Capstone: a blind incident

Every earlier module announced the fault up front: the drill was *watching*
a known mechanism play out. Real incidents don't come with the answer
attached. This module withholds it: Claude injects one unannounced fault,
Ethan diagnoses it cold with only the tools and signals from Modules 1–4, then
writes a postmortem. It comes last because it tests whether the earlier
modules stuck, not anything new.

### Rules of the exercise

**Injection is blind.** The fault is chosen at run time and appears nowhere
in this repo or in the chat until the incident is closed. Claude injects it
as an encoded one-shot script at a random moment inside an announced window.
The command is visible in the session, but its contents aren't readable at a
glance, and Ethan doesn't decode it. That's the honor-system part.

**The fault may or may not show up in change history.** Checking what
changed (`git log`, Argo CD sync history, recent rollouts) is a legitimate
first move and part of the drill. It won't necessarily find anything, since
plenty of real faults never pass through the deploy pipeline.

**Detection is by symptom, not by alert.** Alertmanager is off in this
cluster (`gitops/apps/monitoring.yaml`), so nothing will page. Instead a
synthetic prober runs against the real hot path, and the incident "starts"
when it shows something wrong:

```bash
# one terminal, left running for the whole window. CODE = a real prod code.
CODE=<code>; while true; do printf '%s ' "$(date +%T)"; \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  http://urlshortener.localtest.me/$CODE; sleep 2; done
```

That detection depends on a human watching a terminal is itself a finding.
It belongs in the postmortem's action items.

**What's fair game:** anything an on-call engineer would have: `kubectl`
(get / describe / logs / events / top), Grafana and Prometheus, `psql` into
Postgres, the Argo CD UI, the repo. **Not fair game:** asking Claude what
was injected. Claude can be asked for a *hint* after 20 minutes without
progress; every hint gets recorded in the timeline, and that's fine,
because it's honest data about what hasn't stuck yet.

**Mitigate first, then root-cause.** As in a real incident, restoring
service is allowed to come before understanding. A `rollout restart` that
makes the symptom go away counts as a mitigation, not a diagnosis, and the
postmortem has to say which one it was.

**Done when:** (1) service is restored and the prober is clean for 5
minutes, (2) Ethan states the root cause *before* Claude reveals it, and
(3) the postmortem below is written. Any permanent fix ships through the
normal pipeline (commit → CI → Argo; `promote.yml` for prod), never as a
live `kubectl edit`.

### Scorecard (filled in after the reveal)

| | |
|---|---|
| Fault injected at | *(Claude fills in after the reveal)* |
| Detected at (prober first showed it) | |
| Mitigated at (prober clean) | |
| Root cause stated at | |
| Hints used | |
| Root cause correct? | |
| First signal checked, and was it the right one? | |

### Postmortem template

Blameless: describe what the *system* allowed to happen, not who did it.

```markdown
## Summary
One paragraph: what broke, how long, who/what was affected.

## Impact
Which endpoints, what error rate / latency, dev vs prod, data lost (y/n).

## Timeline
HH:MM — each observation, hypothesis, action, and result, including the
wrong turns. The dead ends are the most useful part.

## Detection
How it was noticed, how long after it started, and what *should* have
noticed it.

## Root cause
The mechanism, down to why the system allowed it. Not just "X was broken."

## Resolution
What mitigated it, what fixed it, and how the fix was verified.

## What went well / what didn't

## Action items
Concrete, each one prevents recurrence or speeds up detection/diagnosis.
```

### Status

Designed 2026-09-30. Lab environment rebuilt on the Windows/WSL desktop the
same day (kind, 16 CPU / ~16 GB) with the Sealed Secrets key restored from the
Mac cluster, so no values changed. All six Argo apps Synced/Healthy; prod and
dev verified end to end (create → 307). Not yet run.
