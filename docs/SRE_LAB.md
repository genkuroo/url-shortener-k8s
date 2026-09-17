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
| 2 | Database bottlenecks | Hammer `/{code}` (the real hot path — does a Postgres `SELECT` + `INSERT` per request, see below) instead of `/healthz` | **Closed (2026-09-05 → 2026-09-14).** Three sub-tests, see below. The original connection-exhaustion hypothesis was never cleanly confirmed — a more valuable bug (health-check thread starvation) surfaced instead and is now fixed. |
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

**Layer not yet applied, for later:**
- A `lock_timeout`/`statement_timeout` on the app's DB connections, so a
  stuck query fails fast instead of holding a thread (and a connection)
  forever. This is what actually frees the wedged threads back up on its
  own — without it, a saturated pod stays readiness-failed until whatever
  external thing is blocking it (the lock, in our test) resolves; with it,
  the pod can self-heal within seconds even if nobody is watching. For this
  app specifically, every query is a simple indexed lookup or single-row
  insert with no legitimate reason to take more than tens of milliseconds,
  so an aggressive `lock_timeout` (~1s) and `statement_timeout` (~2s) are
  both safe here — a genuinely slow, legitimate query would be a sign that
  work belongs in a background job, not this request path, rather than a
  reason to raise the number.

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

## Modules 3–5

Not designed yet. Rough intent, to fill in when we get there:
- **3 (pod failure injection):** `kubectl delete pod` mid-load, a deliberately
  wrong `readinessProbe`, a memory limit set below actual usage to trigger
  OOMKill — read `kubectl describe pod` events and restart counts. Already has
  a real, unplanned head start: Module 2's table-lock test (above) showed
  liveness/readiness sharing a thread pool with request handling, causing
  Kubernetes to kill busy-but-healthy pods. Worth designing this module
  around the liveness-vs-readiness distinction directly — which probe should
  fail, and whether failing it should restart the pod at all.
- **4 (network/dependency):** break ingress-nginx routing or simulate a slow
  Postgres (e.g. an artificial `pg_sleep` in a query) and drill the four
  golden signals + "what changed" triage end-to-end.
- **5 (capstone):** Claude injects an unannounced fault; Ethan diagnoses cold
  using only the tools from modules 1–4, then writes a short postmortem.
