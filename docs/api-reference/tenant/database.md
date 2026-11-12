# XDatabase

> `XDatabase` is the namespaced successor of [`XTenantDatabase`](../_archives/tenant-database.md) ([ADR-005](../../../development-docs/adr/005-kind-ownership-scope-and-naming.md),
> [RFC-010](../../../development-docs/rfc/010-namespaced-tenant-kinds.md)). `XTenantDatabase` is archived: every XR moved by
> [the handover](../../user-guide/migrating-to-new-kinds.md#xtenantdatabase--xdatabase), kept for the record.

Tenant PostgreSQL database on a platform CNPG cluster: a role, the database, and connection credentials generated once and pushed to OpenBao. Created in the team's own
namespace, so the namespace decides whose it is and the platform decides where it lives.

| | |
|---|---|
| **Group** | `tenant.wxops.cloud` |
| **Kind** | `XDatabase` |
| **Plural** | `xdatabases` |
| **Scope** | `Namespaced` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/tenant/database/`](../../../package/tenant/database) — see [`VERSIONS.yaml`](../../../VERSIONS.yaml) for the current package version |
| **Composition functions** | [`function-extra-resources`](https://github.com/crossplane-contrib/function-extra-resources) (the XR's namespace, the platform's clusters) + [`function-kcl`](https://github.com/crossplane-contrib/function-kcl) — see [`kcl/database/main.k`](../../../kcl/database/main.k) |

## Prerequisite: the tenants secret store

**The tenants secret store, `vault-tenant`.** A `ClusterSecretStore` named `vault-tenant`, scoped to OpenBao's `tenants/` mount, must exist before the first
`XDatabase`. The composition fixes the name — a tenant cannot choose another — and its `PushSecret` writes the connection credentials through it. Without it the
`PushSecret` fails to find its store, `status.synced` turns false and `ready` never does.

## What the namespace and the platform decide

`XTenantDatabase` made you type an owner, a cluster and a secret store. `XDatabase` has none of them:

| Question | Answer | Field it replaces |
|---|---|---|
| Whose is it? | The namespace's `wxops.cloud/owner`. It scopes the role, the Secrets and the OpenBao path | `owner` |
| Which cluster? | The platform's — [choosing the cluster](#choosing-the-cluster) | `cluster`, `clusterRef`, `clusterNamespace`, `dedicatedCluster` |
| In which OpenBao store? | The platform's tenants store: the `ClusterSecretStore` `vault-tenant`, scoped to the `tenants/` mount | `vaultSecretStoreName` |
| What is the PostgreSQL database called? | `<owner>-<dbName>`, unique on its cluster by construction | — |

Everything composed but the XR's own objects lives in the CNPG cluster's namespace — a CNPG `Database` must sit beside its `Cluster` — and the `Role` is
cluster-scoped. They carry the owner label, because the owner-stamping policy cannot reach them.

## `spec.parameters`

Every parameter is optional. A minimal database is `spec: {parameters: {}}`, named after the XR.

| Field | Type | Default | Description |
|---|---|---|---|
| `tier` | `string` (`shared`, `dedicated`) | `"shared"` | **`shared`** — a shared cluster for this database's `environment`, chosen by the platform. **`dedicated`** — the cluster the platform team created for this database. |
| `environment` | `string` | | Optional, any name (lowercase letters, digits and `-`). For `tier: shared`, the pool is the shared clusters whose environment matches. **Absent means `dev`**, the pool every `XTenantDatabase` defaulted to. Ignored for `tier: dedicated`. |
| `dbName` | `string` | the XR's name | The database's logical name. It scopes the role (`<owner>-<dbName>`), the connection Secret and the OpenBao path `tenants/<owner>/databases/<dbName>/connection-creds`. Unique per owner. |
| `databaseName` | `string` | `<owner>-<dbName>` | The PostgreSQL database's own name. Set it **only to adopt** a database an `XTenantDatabase` created under its bare `dbName` — the name of an existing CNPG database cannot change. |
| `extensions` | `array<string>` | `[]` | PostgreSQL extensions to enable in the database. Example: `[uuid-ossp, pgcrypto, postgis]`. |
| `databaseReclaimPolicy` | `string` (`delete`, `retain`) | `"retain"` | CNPG `Database.spec.databaseReclaimPolicy`. `retain` protects the database from XR deletion: the database and its owning role both survive and must be cleaned up manually if the tenant is decommissioned. `delete` drops the database on XR deletion, which also lets the role be dropped. Two namespaced `Usage`s order it: `DROP ROLE` waits for `DROP DATABASE`, and the connection Secret's deletion waits for `DROP ROLE`. |

Not parameters, and rejected if you write them: `owner`, `cluster`, `clusterRef`, `clusterNamespace`, `dedicatedCluster`, `vaultSecretStoreName`.

> **Password rotation** is intentionally not implemented: `provider-sql`'s `Role` reconciler only sets the role's password at `Create()` time and never
> re-applies changes on an existing role, so any rotation must also converge Postgres itself — a platform-level concern (e.g. OpenBao's database secrets engine).

> **Changing `databaseReclaimPolicy` on a live XR**: switching from `retain` to `delete` and then deleting the XR cleans up the Kubernetes resources but **not the
> OpenBao entry**: the `PushSecret`'s `deletionPolicy` becomes `Delete`, but ESO only honours that for entries it created under a `Delete` policy. Remove the stale
> entry by hand (`vault kv metadata delete tenants/<owner>/databases/<dbName>/connection-creds`). An XR created with `delete` from the start is fully cleaned up.

## Choosing the cluster

**`tier: shared`.** The choice is made once, on first assignment, and kept in `status.clusterRef`, so adding a cluster to the pool never moves a database. The first
assignment is a hash of `<owner>/<dbName>` over the shared clusters whose environment matches, sorted by name — the same database always lands on the same cluster.

This is a **stable spread, not least-loaded**. `XDatabase` does not read other teams' databases: a namespaced kind is not reliably listable across namespaces, and the
PostgreSQL name is unique by construction, so nothing needs them. Least-loaded balancing returns if cluster tests show other namespaces can be read.

**`tier: dedicated`.** The platform team creates the cluster, an `XDatabaseCluster` named **`<owner>-<dbName>-cluster`**, labelled `wxops.cloud/owner: <owner>` and
`wxops.cloud/managed-by: platform-database-clusters`, with `shared: false`, and sizes it there. The database only uses it. The database is `ready` only when that
cluster is.

## When it will not render

| Cause | A new XR | An XR that already composed resources |
|---|---|---|
| The namespace has no `wxops.cloud/owner` — it is not a tenant namespace | Renders nothing; `status.syncMessage` says so | The reconcile **fails** with the reason; what exists is left untouched |
| `tier: shared` and no shared cluster serves the environment | Renders nothing; `syncMessage` says so | Not applicable — it keeps its cluster |
| `tier: dedicated` and the platform has not created its cluster | Renders nothing; `syncMessage` names the cluster it expects | The reconcile fails with the reason |

The difference is deliberate. Rendering nothing for a database that already exists would delete its objects, and with `databaseReclaimPolicy: delete` that includes the
database. A failed reconcile leaves everything exactly as it was until the cause is fixed.

## Channels

Every release labels its Composition `channel: stable`; `make install-dev` overrides it to `channel: nightly` via Kustomize. Track a channel with
`spec.crossplane`, a sibling of `spec.parameters`, not a field inside it:

```yaml
spec:
  parameters: {...}
  crossplane:
    compositionRevisionSelector:
      matchLabels:
        channel: stable          # or nightly
    compositionUpdatePolicy: Automatic
```

Full mechanism, the `Manual`-pin alternative, and why: [Channels](../../../development-docs/development/releasing.md#channels).

## `status`

| Field | Type | Description |
|---|---|---|
| `clusterRef` | `string` | The CNPG cluster this database is provisioned on. Sticky once assigned. |
| `clusterNamespace` | `string` | Namespace of that cluster. |
| `tier` | `string` | `shared` or `dedicated`. |
| `dbName` | `string` | The logical name. |
| `databaseName` | `string` | The PostgreSQL database's own name — `<owner>-<dbName>` unless `databaseName` was set. |
| `owner` | `string` | The namespace's `wxops.cloud/owner`. Absent when it has none. |
| `created` | `boolean` | True once every composed resource has been observed at least once. Indicates provisioning has started, not that it succeeded. |
| `ready` | `boolean` | True when the database is usable: it exists, its owning role exists, and the connection Secret has materialised (plus, on `tier: dedicated`, its cluster is ready). Derived from observed composed-resource state. |
| `synced` | `boolean` | False while a composed resource's last apply failed — its `Ready` condition can stay True from the earlier success. Absent until the first reconcile. See [Sync state](../status-contract.md#sync-state--every-package). |
| `syncMessage` | `string` | The failing resource and the provider's own message, truncated to ~400 characters; or why nothing was rendered ([above](#when-it-will-not-render)). |

## Required discovery labels

`XDatabase` needs no label of its own: it does not look for other databases.

| Resource | Required label | Purpose |
|---|---|---|
| `XDatabaseCluster` | `wxops.cloud/managed-by: platform-database-clusters` | Found as a candidate for the shared pool, or as a dedicated database's cluster. The value keeps its old name on purpose, so a cluster manifest moves between `XPlatformDatabaseCluster` and `XDatabaseCluster` by changing `kind:` alone |
| `XDatabaseCluster` (dedicated) | `wxops.cloud/owner: <owner>` | Says whose it is. A dedicated cluster without it is not found |

Labels **must be in the XR manifest** — they cannot be set by a composition. Crossplane's composite reconciler writes `status` from dxr updates but ignores
`metadata.labels`.

## Example

See [`examples/tenant/database/xr.yaml`](../../../examples/tenant/database/xr.yaml). A dedicated database, with the cluster the platform team creates for it:

```yaml
# Written by the platform team — it sizes and owns the cluster.
apiVersion: platform.wxops.cloud/v1alpha1
kind: XDatabaseCluster
metadata:
  name: rocket-team-analytics-db-cluster       # <owner>-<dbName>-cluster
  labels:
    wxops.cloud/managed-by: platform-database-clusters
    wxops.cloud/owner: rocket-team
spec:
  parameters:
    clusterName: rocket-team-analytics-db-cluster
    namespace: cnpg-system
    shared: false
    instances: 1
    storageSize: "1Gi"
---
# Written by the team, in its own namespace.
apiVersion: tenant.wxops.cloud/v1alpha1
kind: XDatabase
metadata:
  name: analytics-db
  namespace: rocket-team-production
spec:
  parameters:
    tier: dedicated
    extensions:
      - uuid-ossp
      - pgcrypto
```
