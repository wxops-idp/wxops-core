# platform-database-clusters

Crossplane Configuration package that provisions a platform-managed
[CloudNativePG](https://cloudnative-pg.io/) `Cluster` — the shared PostgreSQL
foundation that [`tenant-database`](../tenant-database) provisions tenant
databases on top of.

Each `XPlatformDatabaseCluster` claim maps to one CNPG `Cluster`, an optional
RW/RO PgBouncer `Pooler`, optional Barman backups, optional `managedRoles[]`,
and superuser credentials seeded to Vault via `PushSecret`. Composition logic
is written in KCL — see [`kcl/platform-database-clusters/main.k`](../../../kcl/platform-database-clusters/main.k).

## Prerequisites

Install once per cluster (`make providers`):

```bash
kubectl apply -f providers/provider-kubernetes.yaml
kubectl apply -f providers/rbac-provider-kubernetes.yaml
kubectl apply -f providers/runtimeconfig-provider-kubernetes.yaml
kubectl apply -f providers/providerconfig-kubernetes.yaml
kubectl apply -f providers/provider-sql.yaml
kubectl apply -f providers/function-kcl.yaml
```

Also requires the [CloudNativePG operator](https://cloudnative-pg.io/) and an
ESO `ClusterSecretStore` (for Vault credential seeding) in-cluster.

## Install

**Production** (registry):

```bash
kubectl apply -f package/install/platform/platform-database-clusters.yaml
```

**Development** (direct apply):

```bash
kubectl apply -k package/platform/platform-database-clusters/
```

## Usage

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XPlatformDatabaseCluster
metadata:
  name: cluster-a
spec:
  parameters:
    clusterName: cluster-a
    namespace: cnpg-system
    instances: 1
    postgresVersion: 16
    storageSize: "8Gi"
    shared: true         # enables discovery by XTenantDatabase tier: shared
    environment: dev     # pool filtered by environment
    vaultPlatformSecretStore: "vault-platform"
```

> **Discovery label required**: every `XPlatformDatabaseCluster` XR must
> include `wxops.cloud/managed-by: platform-database-clusters` in
> `metadata.labels`. `XTenantDatabase` uses this label to discover clusters
> for `tier: shared` pool assignment. See
> [`docs/api-reference/platform-database-clusters.md`](../../../docs/api-reference/platform-database-clusters.md#required-discovery-label)
> for details.

See [`examples/platform-database-clusters/xr.yaml`](../../../examples/platform-database-clusters/xr.yaml)
for the full set of optional fields (pooler, tuning, backup, monitoring,
`managedRoles[]`, `bootstrapFrom`), and
[`docs/api-reference/platform-database-clusters.md`](../../../docs/api-reference/platform-database-clusters.md)
for the complete `spec.parameters` reference.

## Status

| Field | Description |
|---|---|
| `clusterName` | CNPG cluster name (echoed from spec.parameters.clusterName). |
| `namespace` | Namespace where the CNPG cluster lives. |
| `shared` | Whether this cluster is in the shared multi-tenant pool. |
| `environment` | Environment this cluster serves (dev, staging, prod). |
| `created` | True once every composed resource has been observed at least once. |
| `ready` | True when the cluster can serve connections: the CNPG Cluster is up, and any enabled pooler is up too (tenants are handed the pooler endpoint, not the cluster's). |
| `synced` / `syncMessage` | `synced` is false while a composed resource's last apply failed (its `Ready` can stay True from the earlier success); `syncMessage` is the provider's message, truncated. Absent until the first reconcile |

Full reference: [`docs/api-reference/platform-database-clusters.md`](../../../docs/api-reference/platform-database-clusters.md#status).

## Relation to other packages

```
XPlatformDatabaseCluster (cluster-a, shared: true, environment: dev)
├── XTenantDatabase (rocket-team / payment-db)   ← tier: shared, auto-assigned
└── XTenantDatabase (rocket-team / analytics-db) ← tier: dedicated, composes own cluster
```
