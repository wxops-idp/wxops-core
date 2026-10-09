# Setup — installing W'xOps Core on a cluster

> Install the shared providers once, seed a connection token, install the packages, then apply a first resource. For what each resource does once it exists, see
> the [API reference](../api-reference/README.md).

**Table of Contents**
- [Prerequisites](#prerequisites)
- [Platform dependencies, per package](#platform-dependencies-per-package)
- [1 — Install providers once per cluster](#1--install-providers-once-per-cluster)
- [2 — Seed a connection token](#2--seed-a-connection-token)
- [3 — Install packages](#3--install-packages)
- [4 — Apply a first resource](#4--apply-a-first-resource)
- [Uninstalling](#uninstalling)
- [Next](#next)

---

## Prerequisites

- The [`crossplane` CLI](https://docs.crossplane.io/latest/cli/), v2.3 or later
- `kubectl` pointed at a cluster with Crossplane v2.3 or later installed
- `pre-commit`, only if you will change this repository (see the
  [development guide](../../development-docs/development/README.md))

## Platform dependencies, per package

W'xOps Core composes resources that other operators reconcile. Install what the packages you use need:

| Package | Needs in the cluster |
|---|---|
| `scm-connection`, `scm-repository`, `scm-oauth-app` | A reachable Gitea or GitHub host and an admin/API token, written to the secret store (step 2) |
| `platform-database-clusters` | CloudNativePG operator; External Secrets Operator with a Vault `ClusterSecretStore`; provider-sql (installed by step 1) |
| `tenant-database` | Everything `platform-database-clusters` needs, plus a cluster labelled for discovery; see [Required discovery labels](../api-reference/tenant-database.md#required-discovery-labels) |
| `tenant-app` | Only what the XR enables: cert-manager for `ingress.tls`, Traefik CRDs for `ingress`, Prometheus Operator CRDs for `monitoring`, Stakater Reloader for `reloader` |
| Darlane TTL enforcement (optional) | Kyverno, plus [`providers/policies/darlane-ttl.yaml`](../../providers/policies/darlane-ttl.yaml) |

## 1 — Install providers once per cluster

```bash
make providers
```

Installation is two steps, in this order:

```bash
make providers         # providers and functions, then waits for them to report Healthy
make provider-configs  # the ProviderConfigs, once their CRDs are served
```

A ProviderConfig cannot exist before its provider's CRDs are served, which is why they are separate targets rather than one apply. Override the wait with
`WAIT_TIMEOUT=600s` if image pulls are slow. A GitOps engine needs neither step: `providers/kustomization.yaml` is the all-at-once view, and Argo CD or Flux
retry until the CRDs appear.

Together they apply everything in `providers/`: `provider-opentofu`, `provider-kubernetes` (plus RBAC and a `ProviderConfig`), `provider-sql`,
`function-patch-and-transform`, `function-kcl`, `function-extra-resources`, and the OpenTofu `ProviderConfig`. **`provider-terraform` is archived**
(`providers/archive/`) and not applied: the only packages that ran on it (`gitea-*`) are themselves archived — see
[`providers/archive/README.md`](../../providers/archive/README.md).

> [!NOTE]
> **`make providers` is required before `make install`.**
> - **Dependency names.** Crossplane's `dependsOn` in `crossplane.yaml` can auto-install missing
>   dependencies, but under long names derived from the OCI path (for example
>   `crossplane-contrib-function-kcl` instead of `function-kcl`). Compositions reference the short
>   names set by `providers/*.yaml`, so auto-installed dependencies are not found.
> - **Provider configuration.** Providers like `provider-kubernetes` also need a `RuntimeConfig`, RBAC
>   and a `ProviderConfig`, which `dependsOn` cannot provide.
>
> `dependsOn` is a **version-constraint safety net**, not an installer.

## 2 — Seed a connection token

Every `scm-*` resource reads its vendor/token through one `XScmConnection`; the host token is the one secret Core cannot create itself. Write it to the secret
store `XScmConnection` renders from (`vault-platform` by default), property `token`, at `platform/scm/<connection-name>/credentials`:

```bash
export BAO_ADDR=https://openbao.example.com     # or a port-forward to the in-cluster service
bao login                                       # however your operators authenticate
bao kv put platform/scm/github-wxops-idp/credentials token="your-admin-or-pat-token"
```

See [Seeding a connection's token](../../examples/scm-connection/token-secret.md) for the full walkthrough, including what scope the token needs per vendor.

## 3 — Install packages

**Production** — pulls the Configuration packages pinned in `package/install/` from the OCI registry:

```bash
make install
```

**Development** — applies XRDs and Compositions straight from this checkout, with no registry:

```bash
make install-dev
```

`make install-dev` is for a disposable development cluster only. Against a cluster that already runs the packages, it overwrites package-managed XRDs and
Compositions and skips every release gate. Everything it applies carries `channel: nightly` (production packages ship `channel: stable`) — see
[Channels](../../development-docs/development/releasing.md#channels) for how an XR opts into either.

## 4 — Apply a first resource

```bash
kubectl apply -f examples/scm-connection/xr.yaml
kubectl apply -f examples/scm-repository/xr.yaml
kubectl get xscmrepositories
kubectl describe xscmrepository <name>
crossplane resource trace xscmrepository <name>   # the XR and everything it composed
```

Wait for `status.created` and `status.ready`; see [Reading status](../api-reference/README.md#reading-status).

## Uninstalling

```bash
make uninstall       # remove registry-installed Configuration packages
make uninstall-dev   # remove XRDs and Compositions applied by make install-dev
```

Delete XRs first, and read each Kind's deletion notes before you do. Kinds that hold data, like `XTenantDatabase`, keep it by default.

## Next

- Ship an application end to end: [app onboarding](app-onboarding.md)
- Every Kind and what the reconcile loop does for it: [API reference](../api-reference/README.md)
- Build a portal on top: [portal integration](portal-integration.md)
