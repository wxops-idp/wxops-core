# tenant-database

> Being replaced by [`database`](../../../tenant/database) (`XDatabase`, ADR-005, RFC-010): the same database, created in the team's own namespace. A database holds data — see [migrating to the new kinds](../../../../docs/user-guide/migrating-to-new-kinds.md#xtenantdatabase--xdatabase) before moving one. This kind stays served until every XR has moved.

Crossplane Configuration package that provisions a tenant-facing PostgreSQL
database on a platform [`XPlatformDatabaseCluster`](../platform-database-clusters),
with a continuously reconciled `provider-sql` `Role` and Vault-backed
connection credentials synced via ESO.

Each `XTenantDatabase` claim maps to a CNPG `Database` CR + a `provider-sql`
`Role` + a `PushSecret` that writes connection creds to Vault at
`tenants/{owner}/databases/{dbName}/connection-creds`. Composition logic is
written in KCL — see
[`kcl/tenant-database/main.k`](../../../../kcl/_archives/tenant-database/main.k).

Two tiers are available:
- **`shared`** (default) — auto-assigns to the least-loaded
  `XPlatformDatabaseCluster` labeled `shared: true`, discovered dynamically
  via `function-extra-resources`.
- **`dedicated`** — composes a child `XPlatformDatabaseCluster` inline
  (1 cluster = 1 database, fully isolated).

## Prerequisites

Install once per cluster (`make providers`):

```bash
kubectl apply -f providers/packages/provider-kubernetes.yaml
kubectl apply -f providers/rbac/provider-kubernetes.yaml
kubectl apply -f providers/packages/runtimeconfig-provider-kubernetes.yaml
kubectl apply -f providers/config/providerconfig-kubernetes.yaml
kubectl apply -f providers/packages/provider-sql.yaml
kubectl apply -f providers/functions/function-kcl.yaml
kubectl apply -f providers/functions/function-extra-resources.yaml
```

For `tier: shared`, at least one
[`XPlatformDatabaseCluster`](../platform-database-clusters) with
`shared: true` must exist. For `tier: dedicated`, the composition creates
the cluster automatically.

## Install

**Production** (registry):

```bash
kubectl apply -f package/install/platform/tenant-database.yaml
```

**Development** (direct apply):

```bash
kubectl apply -k package/platform/tenant-database/
```

## Usage

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XTenantDatabase
metadata:
  name: rocket-team-payment-db
spec:
  parameters:
    # tier: shared     # default — auto-assigns to least-loaded shared cluster
    # tier: dedicated  # composes a child cluster (1:1 isolation)
    dbName: payment-db
    owner: rocket-team
    extensions:
      - uuid-ossp
      - pgcrypto
```

> **Discovery labels required**: every `XTenantDatabase` XR must include
> `wxops.cloud/tenant-database: "true"` in `metadata.labels` — needed for
> per-cluster tenant counting and `dbName` collision detection. Every
> `XPlatformDatabaseCluster` must include
> `wxops.cloud/managed-by: platform-database-clusters` for shared pool
> discovery. See
> [`docs/api-reference/platform/tenant-database.md`](../../../../docs/api-reference/_archives/tenant-database.md#required-discovery-labels)
> for details.

See [`examples/platform/tenant-database/xr.yaml`](../../../../examples/_archives/tenant-database/xr.yaml) (shared tier)
and the [dedicated tier example](../../../../docs/api-reference/_archives/tenant-database.md#examples) for full examples, and
[`docs/api-reference/platform/tenant-database.md`](../../../../docs/api-reference/_archives/tenant-database.md) for the complete
`spec.parameters` reference (including `dedicatedCluster` sizing and
`databaseReclaimPolicy` semantics).

## Status

| Field | Description |
|---|---|
| `clusterRef` | Resolved CNPG cluster name this database is provisioned on. |
| `clusterNamespace` | Namespace of the resolved cluster. |
| `tier` | Resolved tier (shared, dedicated, or explicit). |
| `dbName` | PostgreSQL database name (echoed for cross-XR collision checks). |
| `created` | True once every composed resource has been observed at least once. |
| `ready` | True when the database is usable: it exists, its owning role exists, and the connection Secret has materialised (plus, on tier: dedicated, the child cluster is up). |
| `synced` / `syncMessage` | `synced` is false while a composed resource's last apply failed (its `Ready` can stay True from the earlier success); `syncMessage` is the provider's message, truncated. Absent until the first reconcile |

Full reference: [`docs/api-reference/platform/tenant-database.md`](../../../../docs/api-reference/_archives/tenant-database.md#status).

## Relation to other packages

```
XPlatformDatabaseCluster (shared: true)
└── XTenantDatabase (tier: shared → auto-assigned)
    └── PushSecret → Vault: tenants/{owner}/databases/{dbName}/connection-creds
        └── ExternalSecret (GitOps) → Secret in app namespace
            └── XTenantApp (secretsFrom.database.enabled: true)
```
