# tenant-database

Crossplane Configuration package that provisions a tenant-facing PostgreSQL
database on a platform [`XPlatformDatabaseCluster`](../platform-database-clusters),
with a continuously reconciled `provider-sql` `Role` and Vault-backed
connection credentials synced via ESO.

Each `XTenantDatabase` claim maps to a CNPG `Database` CR + a `provider-sql`
`Role` + a `PushSecret` that writes connection creds to Vault at
`tenants/{owner}/databases/{dbName}/connection-creds`. Composition logic is
written in KCL — see
[`kcl/tenant-database/main.k`](../../../kcl/tenant-database/main.k).

Two tiers are available:
- **`shared`** (default) — auto-assigns to the least-loaded
  `XPlatformDatabaseCluster` labeled `shared: true`, discovered dynamically
  via `function-extra-resources`.
- **`dedicated`** — composes a child `XPlatformDatabaseCluster` inline
  (1 cluster = 1 database, fully isolated).

## Prerequisites

Install once per cluster (`make providers`):

```bash
kubectl apply -f providers/provider-kubernetes.yaml
kubectl apply -f providers/rbac-provider-kubernetes.yaml
kubectl apply -f providers/runtimeconfig-provider-kubernetes.yaml
kubectl apply -f providers/providerconfig-kubernetes.yaml
kubectl apply -f providers/provider-sql.yaml
kubectl apply -f providers/function-kcl.yaml
kubectl apply -f providers/function-extra-resources.yaml
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
> [`docs/api-reference/tenant-database.md`](../../../docs/api-reference/tenant-database.md#required-discovery-labels)
> for details.

See [`examples/tenant-database/xr.yaml`](../../../examples/tenant-database/xr.yaml)
and [`examples/tenant-database/xr-dedicated.yaml`](../../../examples/tenant-database/xr-dedicated.yaml)
for full examples, and
[`docs/api-reference/tenant-database.md`](../../../docs/api-reference/tenant-database.md) for the complete
`spec.parameters` reference (including `dedicatedCluster` sizing and
`databaseReclaimPolicy` semantics).

## Relation to other packages

```
XPlatformDatabaseCluster (shared: true)
└── XTenantDatabase (tier: shared → auto-assigned)
    └── PushSecret → Vault: tenants/{owner}/databases/{dbName}/connection-creds
        └── ExternalSecret (GitOps) → Secret in app namespace
            └── XTenantApp (secretsFrom.database.enabled: true)
```
