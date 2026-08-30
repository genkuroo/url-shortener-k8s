# Running this on EKS

The stretch phase: Terraform that stands up a real **Amazon EKS** cluster and
deploys the *same* Helm chart to it, via the *same* Argo CD GitOps setup.

The point isn't "it runs in AWS." It's proving the chart and the GitOps machinery
were never secretly kind-shaped — that "declarative and portable" was a real
property and not just a claim in the README.

> **This costs money while it exists** — roughly **$0.24/hour** (see [Cost](#cost)).
> The intended cycle is apply, demo, destroy in one sitting, like the sibling
> ECS project. Budget **2.5–4 hours** the first time.

---

## What's different from kind, and what isn't

Everything describing *what should run* is unchanged. What gets replaced is the
machinery underneath.

| Layer | kind | EKS |
|---|---|---|
| App code, Dockerfile, CI/CD | — | **identical** |
| Chart templates | — | **identical** (one new values file) |
| Argo CD, app-of-apps pattern | — | **identical** |
| Control plane | a container on your laptop | AWS-managed, multi-AZ |
| Nodes | 3 Docker containers in Colima | EC2 managed node group, Graviton arm64 |
| Network | Docker bridge | VPC, 2 AZs, NAT, ELB-tagged subnets |
| Storage | kind's local-path provisioner | EBS CSI driver + gp3 StorageClass |
| Identity | none | **IRSA** — OIDC provider + per-ServiceAccount IAM roles |
| Ingress reach | `localtest.me` → 127.0.0.1 | the NLB's own DNS name |
| metrics-server | needs `--kubelet-insecure-tls` | doesn't (EKS certs are properly signed) |

**Graviton for free.** The nodes are `t4g` (arm64), ~20% cheaper than the x86
equivalent. That's only possible because CI has published a **multi-arch** image
since Phase 7 — a change originally made because the laptop is Apple Silicon. It
paid for itself twice.

### Why there's a second GitOps tree

Both clusters watch the same repo. If EKS bootstrapped `gitops/root-app.yaml` it
would faithfully deploy *kind's* desired state — `*.localtest.me` hostnames that
resolve to 127.0.0.1, a metrics-server carrying kind's TLS workaround, and the
whole monitoring stack onto two nodes.

So there are two explicit trees:

```
gitops/apps/        -> kind    (make argocd-bootstrap)
gitops/eks/apps/    -> EKS     (make eks-bootstrap)
```

Same chart underneath; only the values overlay differs. No branching, no
ApplicationSet templating — just two directories that each say plainly what they
deploy.

---

## Prerequisites

- AWS credentials with permission to create VPC / EKS / IAM / EC2 resources
- `terraform` ≥ 1.6, `awscli` v2, `kubectl`, `helm`
- The GHCR image must be **public** (it is) so nodes can pull without a secret

---

## The run

```bash
make eks-plan        # preview — no resources, no cost
make eks-up          # ~15-20 min. Billing starts here.
make eks-kubeconfig  # point kubectl at the cluster; prints nodes
make eks-ingress     # install ingress-nginx; its Service creates the NLB
make eks-bootstrap   # Argo CD + the EKS app-of-apps
make eks-status      # pods, PVC, HPA, Argo applications
make eks-url         # the address to open
make eks-seed        # demo links, so there's something to look at
```

`eks-up` is slow and that's normal: the control plane alone takes 10–15 minutes,
the node group another ~5.

Load-test the EKS release with `make eks-load-test` (watch it with
`make eks-hpa-watch`).

### Verified run — 2026-08-30

First real apply of this stack, on **Kubernetes 1.36** (bumped from the 1.31 the
phase was written against — see [Cost](#cost)):

- `terraform apply` — **29 added, 0 changed, 0 destroyed**, no errors
- 2 nodes Ready on `v1.36.3-eks`, `aarch64` — Graviton confirmed
- NLB attached on the first attempt (the subnet ELB tags are right)
- **PVC `Bound`** to a 4Gi gp3 volume — EBS CSI + IRSA + default StorageClass
- All 4 Argo Applications Synced/Healthy
- App served through the NLB: create → **307** redirect → click recorded in stats
- metrics-server healthy with **no `--kubelet-insecure-tls`**, as predicted
- HPA scaled **2 → 4 → 6** under load (peak `456%/60%`), all 6 pods Running with
  none Pending — which is exactly the ceiling `maxReplicas: 6` was chosen for
- …then back down to **2** about 4.5 min after the load stopped. Scale-out is
  immediate; scale-in waits out the HPA's default 300s stabilization window, so a
  brief lull can't cause replica flapping. The full 2→6→2 cycle is the demo.

Nothing in `charts/` changed to make any of that work.

### Verifying it actually worked

```bash
kubectl get nodes                          # 2 Ready, arm64
kubectl get storageclass                   # gp3 (default)
kubectl -n url-shortener-eks get pvc       # Bound  <- the real proof
kubectl -n argocd get applications         # all Synced / Healthy

URL=$(make -s eks-url)
curl -s -X POST "$URL/api/links" -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com/eks"}'
curl -si "$URL/<code>" | head -1           # 307
curl -s "$URL/api/links/<code>/stats"      # click recorded
```

**The PVC going `Bound` is the single most informative check.** It means the EBS
CSI driver is installed *and* its IRSA role is correct *and* the gp3 StorageClass
is default. Three things at once.

### Teardown

```bash
make eks-down
```

This deletes the ingress-nginx Service **first**, waits for AWS to release the
load balancer, and only then runs `terraform destroy`. Order matters — see below.

Then confirm nothing survived:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
```

---

## Cost

Approximate, `us-east-1`, while running:

| Component | $/hour |
|---|---|
| EKS control plane | 0.10 |
| 2 × t4g.medium | 0.067 |
| NAT gateway | 0.045 |
| NLB | 0.023 |
| **Total** | **≈ 0.24** |

A four-hour session is about **$1**. The control plane bills whether or not a
single pod runs on it, which is the whole reason `eks-down` exists.

> ⚠️ **That $0.10 assumes a Kubernetes version still in standard support.** Once a
> version ages out, AWS keeps the cluster running but silently moves it to the
> **extended-support** rate of **$0.60/hour** — the same cluster, six times the
> control-plane bill, with no warning at apply time. Check before you apply:
>
> ```bash
> aws eks describe-cluster-versions \
>   --query 'clusterVersions[].{v:clusterVersion,eol:endOfStandardSupportDate}' --output table
> ```
>
> This bit us on 2026-08-30: `cluster_version` had been pinned to **1.31** when the
> stretch phase was written, and 1.31 left standard support on 2025-11-25. Applying
> as-written would have cost ~**$0.74/hr** instead of $0.24. Now pinned to **1.36**.
> Since the add-ons are unpinned (`addon_version = null`, EKS picks the default for
> whatever version the cluster is), bumping is a one-line change.

Because it's cheap by the hour, **leave the cluster up while iterating** rather
than destroying between attempts — a destroy/recreate cycle costs 25+ minutes of
your time to save about six cents.

---

## Gotchas

**A stale `cluster_version` costs money, not errors.** Terraform will happily
create a cluster on an out-of-standard-support version; the only symptom is a 6x
control-plane bill (see [Cost](#cost)). Re-check the supported list any time this
stack has sat unapplied for a few months — pins rot faster than code does.

**Subnet tags are load-bearing.** The AWS cloud provider finds subnets for a load
balancer *only* by `kubernetes.io/role/elb` (public) and
`kubernetes.io/role/internal-elb` (private). Get them wrong and there is no
useful error — the Service just sits at `EXTERNAL-IP <pending>` forever. They're
spelled out explicitly in `terraform/network.tf` rather than hidden in a module.

**EKS ships no default StorageClass.** kind bundles a local-path provisioner, so
the chart's PVC binds without anyone thinking about it. On EKS, without the CSI
driver *and* a default StorageClass, `postgres-0` sits `Pending` forever and the
release never goes Healthy. Terraform installs the driver; Argo applies the
StorageClass (`gitops/eks/manifests/gp3-storageclass.yaml`).

**`WaitForFirstConsumer` is deliberate.** An EBS volume lives in one AZ and can
only attach to a node in that AZ. Binding late — after the scheduler picks a node
— guarantees the volume lands in the right place. `Immediate` binding can strand
a volume in AZ *a* while the pod is scheduled into AZ *b*, and the pod never
starts.

**Teardown order, or you leak a billing load balancer.** The NLB is created by
*Kubernetes* (the ingress-nginx Service), not by Terraform, so Terraform has no
idea it exists. Destroying the VPC while the balancer still has ENIs in its
subnets fails, and the usual result is a half-destroyed stack plus an orphaned
NLB quietly charging. `make eks-down` handles the ordering; don't run
`terraform destroy` directly.

**Your tools have architectures too, not just your app.** Phase 7 made the *app*
image multi-arch. But `make load-test` still pulled `williamyeh/hey`, which
publishes **linux/amd64 only** — a plain single-arch manifest, not an index.

That target has always worked on kind, and the reason is worth understanding: the
Colima VM registers `qemu-x86_64` in `/proc/sys/fs/binfmt_misc`, and binfmt_misc
is a **kernel-global** facility, so kind's node containers inherit it and the
amd64 binary runs under transparent QEMU emulation. Verified — the pod completes
normally on the arm64 kind nodes.

Two consequences:

- **The failure would not look like Phase 7's.** `no match for platform in
  manifest` comes from a manifest *index* containing no entry for your platform.
  A single-arch manifest has nothing to match against, so it pulls happily on any
  architecture and would instead fail later, at exec, with `exec format error`.
- **A Graviton EC2 node has no such emulation layer**, so it is expected to fail
  there. (Expected, not observed — the load generator was swapped to a multi-arch
  image before load was ever run on EKS, so `hey` was never actually exercised on
  Graviton.)

The swap to a multi-arch `alpine:3` pod (`LOAD_IMAGE` in the Makefile) is still
the right call, for a reason independent of whether `hey` would have run: a load
test that silently depends on **laptop-only CPU emulation** is both unportable and
measuring the wrong thing, since the emulated generator burns host CPU competing
with the very workload it is trying to load.

**Node sizing is the knob.** Pods going `Pending` means you're out of capacity,
not out of luck. Raise `node_desired_size` or move to `t4g.large` in
`terraform.tfvars`.

**The AMI type must match the instance type.** `AL2023_ARM_64_STANDARD` pairs
with `t4g`. Switching to an x86 instance type means switching to
`AL2023_x86_64_STANDARD`, or the node group fails to launch after several
minutes of waiting.

---

## Monitoring is off here — and how to turn it on

The EKS overlay deliberately ships without kube-prometheus-stack. It's ~2–3 GiB
across Prometheus, Grafana, the operator, node-exporters and kube-state-metrics,
and it's exactly what pushed the 2 GiB Colima VM over its ceiling in Phase 5. The
first apply has enough new failure surface without it.

metrics-server **is** installed, so `kubectl top` works and the HPA autoscales.

To enable the full stack, three things change together:

1. Flip `serviceMonitor.enabled` and `dashboard.enabled` to `true` in
   `charts/url-shortener/values-eks.yaml`
2. Add `gitops/eks/apps/monitoring.yaml` — copy `gitops/apps/monitoring.yaml`,
   drop Prometheus retention to a few hours (the cluster is ephemeral) and give
   it a gp3 PVC
3. Raise capacity in `terraform.tfvars`: `node_desired_size = 3`, or
   `node_instance_type = "t4g.large"`

### What you can't monitor on EKS, and why

On kind, the `kubeScheduler` / `kubeControllerManager` / `kubeEtcd` / `kubeProxy`
scrape jobs were disabled because those components bind to 127.0.0.1 there.

**On EKS they stay disabled for the opposite reason: AWS runs the control plane
and doesn't expose those endpoints at all.** It isn't a limitation of the setup —
it's the boundary of the managed service, and a concrete answer to "what do you
give up with EKS?"

The EKS-native replacement is control-plane logs in CloudWatch, via the
`cluster_log_types` variable in `terraform/variables.tf`. It's empty by default so
a throwaway cluster doesn't accrue log charges. So observability splits:

- **workloads** → Prometheus + Grafana, same as kind
- **control plane** → CloudWatch

(Amazon Managed Prometheus / Grafana and CloudWatch Container Insights are the
fully-managed alternatives. Overkill here — and running your own Prometheus is
the portable choice, for the same reason ingress-nginx was chosen over the AWS
Load Balancer Controller.)

---

## Why ingress-nginx and not the AWS Load Balancer Controller

**ingress-nginx** is a real nginx pod in the cluster; its Service asks AWS for an
**NLB**, which is layer 4 and just forwards TCP. All routing happens in-cluster,
so `ingress.className: nginx` works unchanged on kind, EKS, or anywhere else.

**The AWS Load Balancer Controller** instead configures a layer-7 **ALB** that
does the routing itself, in AWS. More AWS-native, and it unlocks WAF and ACM
certificates — but it needs its own IRSA role, an `ingressClassName` swap, and
ALB-specific annotations in values, which would quietly make the chart AWS-only.

For a project whose entire thesis is "the same manifests deploy anywhere," nginx
is the right call. ALB would be the right call for a production AWS-only service.
