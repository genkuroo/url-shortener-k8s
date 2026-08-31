# Secrets: how the database password lives in a public repo

Phase 8. Everything else in this repo is desired state that is safe to publish —
manifests, values, image tags. The database password was the one exception, and
it sat in `values.yaml` in the clear.

That is the awkward corner of GitOps: *git is the source of truth*, except for
the parts you can't write down. **Sealed Secrets** closes it.

---

## The idea in one paragraph

The controller generates an RSA keypair and keeps the **private** half inside the
cluster. `kubeseal` encrypts a value with the **public** half, producing a
`SealedSecret` — ciphertext that is useless to anyone reading the repo. The
controller watches for `SealedSecret` objects and decrypts each one into an
ordinary `Secret`.

So the flow inverts. Instead of a human pushing a credential into the cluster out
of band, the cluster **pulls ciphertext from git and unseals it itself** — the
same pull model as the rest of Phase 4, finally covering the one thing that used
to need hands.

**Nothing that consumes the secret changed.** `app.yaml` and `postgres.yaml` still
read a `Secret` named `<fullname>-secret` through `secretKeyRef`. They neither
know nor care that a controller created it rather than Helm. Only the delivery
mechanism moved.

---

## What's where

| Piece | Location |
|---|---|
| Controller (pinned v0.39.1, vendored) | `k8s/sealed-secrets/controller.yaml` |
| Argo Application (wave `-2`) | `gitops/apps/sealed-secrets.yaml` |
| Chart template | `charts/url-shortener/templates/sealedsecret.yaml` |
| Plaintext fallback (off when sealing is on) | `charts/url-shortener/templates/config.yaml` |
| Ciphertext, per environment | `values-dev.yaml`, `values-prod.yaml`, `values-eks.yaml` |
| CLI | `brew install kubeseal` |

The controller is **vendored rather than installed from a Helm repo**: the chart
repo at `bitnami-labs.github.io/sealed-secrets` now returns 404, and the chart
moved to an OCI registry under Bitnami's reorganised distribution. Vendoring is
also simply the right call for something that holds a decryption key — the exact
applied bytes are committed and reviewable, and the install can't shift
underneath you because someone re-tagged something.

---

## Two scopes, and both will bite you

**1. Ciphertext is bound to a namespace AND a name.** The default `strict` scope
folds both into the encryption. A value sealed for `dev-url-shortener-secret` in
`url-shortener-dev` will *not* decrypt as `prod-url-shortener-secret` in
`url-shortener-prod`. That's a feature — it stops someone copying your sealed prod
credential into a namespace they can already read — and it's why every overlay
carries its own `encryptedPassword` instead of sharing one.

Verified directly: applying dev's ciphertext into a different namespace on the
*same cluster with the same key* fails with

```
no key could decrypt secret (POSTGRES_PASSWORD)
```

**2. Ciphertext is bound to one cluster's keypair — this is the one that ruins
days.** A fresh controller generates a fresh key. Rebuild the cluster (`kind
delete`, a new EKS cluster, a colleague cloning the repo) and every
`encryptedPassword` in this repo becomes undecryptable garbage. The symptom is
indirect and easy to misread: the `SealedSecret` exists, no `Secret` ever appears,
and the app sits in `CreateContainerConfigError` waiting for something that will
never arrive. The reason is only in the controller log.

Two ways out — re-seal everything against the new key, or restore the old key:

```bash
make seal-key-backup     # once, on the cluster that owns the key
make seal-key-restore    # on the new cluster, BEFORE the app syncs
```

`sealed-secrets-key*.yaml` is gitignored. **That one file decrypts every
SealedSecret in this repo** — it belongs in a password manager, not in this
directory and never in git.

---

## Rotating a password

```bash
make seal-password RELEASE=dev NAMESPACE=url-shortener-dev
```

It generates a password, rotates it **inside Postgres**, seals it, and prints the
YAML block to paste into that environment's values file. Then commit, push, and
let Argo reconcile:

```bash
kubectl -n url-shortener-dev rollout restart deploy/dev-url-shortener
```

### Why the restart, and why `ALTER USER`

Two things that look like they should be automatic, and aren't:

- **Changing `POSTGRES_PASSWORD` in a manifest does nothing to an existing
  database.** `initdb` reads that variable exactly once, when the data directory
  is first created. On an initialized volume it is ignored completely. The
  password has to be changed *in Postgres* with `ALTER USER`, which is why
  `seal-password` does that first.
- **Updating a Secret does not restart the pods that consume it.** Env vars from
  `secretKeyRef` are injected at pod start; running pods keep the old value until
  they're replaced. Hence the explicit `rollout restart`.

Sequence matters: rotate in Postgres → update the Secret → restart the app. In
the gap between the first and last step, already-pooled connections keep working
while brand-new ones fail, so keep the window short.

### Generate alphanumeric passwords

The password is interpolated into a `postgresql://user:PASS@host:port/db` URL. A
`/`, `+`, or `@` — all of which raw `base64` or `openssl rand -base64` produce
happily — will silently corrupt the connection string. `seal-password` generates
alphanumeric values for exactly this reason.

---

## On EKS

`values-eks.yaml` was sealed **offline**, against only the controller's public
certificate, with no cluster contacted:

```bash
kubeseal --raw --from-file=/dev/stdin \
  --namespace url-shortener-eks --name eks-url-shortener-secret \
  --cert pub-cert.pem
```

That's how you'd seal a value in CI, where there is no kubeconfig at all. It also
means the EKS value was committed before the cluster it targets existed.

The catch is scope #2: a new EKS cluster has a new key, so the bootstrap must
restore this one first.

```bash
make eks-bootstrap
make seal-key-restore    # before the app syncs
```

No password rotation is needed there — EKS gets a fresh EBS volume every session,
so Postgres runs `initdb` and simply adopts whatever the Secret carries.

---

## What this does *not* protect against

Worth being honest about, because "encrypted" invites overclaiming:

- **The old password is still in git history.** `localdevpw` was public for weeks.
  Encrypting going forward would have protected nothing, so dev and prod were
  **rotated** to fresh 32-character passwords, not merely hidden. Treat any
  credential that reached a public repo as burned. Rewriting history would not
  help either — it's been cloned and cached.
- **Anyone who can read Secrets in `kube-system` can read the private key**, and
  therefore every secret in the repo. Sealed Secrets protects the *repo*, not the
  cluster; cluster RBAC is still what protects the cluster.
- **A Secret is still only base64 inside etcd.** Sealing changes how the value
  gets *there*, not how it's stored once unsealed. Encryption at rest is a
  separate control (on EKS, a KMS key via `encryption_config`).
- **This is a single-key setup with no rotation of the key itself.** The
  controller supports key renewal; a longer-lived cluster should use it.

The honest summary: this removes plaintext credentials from a public git
repository, which was a real problem. It is not a full secrets-management story —
that would be external-secrets backed by AWS Secrets Manager or Vault, which was
deliberately not chosen here because it would tie the chart to one cloud and undo
the portability the EKS phase exists to prove.
