# database-cluster

`XDatabaseCluster` replaces [`XPlatformDatabaseCluster`](../archives/platform-database-clusters) (ADR-005): the same CNPG cluster, pooler, backups and credentials, a name that does not repeat the group. `XPlatformDatabaseCluster` is archived: every XR moved by the handover in [migrating to the new kinds](../../../docs/user-guide/migrating-to-new-kinds.md#xplatformdatabasecluster--xdatabasecluster), kept for the record.

Crossplane Configuration package that provisions a platform-managed
[CloudNativePG](https://cloudnative-pg.io/) `Cluster` — the PostgreSQL
foundation that [`database`](../../tenant/database) (`XDatabase`) provisions tenant
databases on top of.

Each `XDatabaseCluster` claim maps to one CNPG `Cluster`, an optional
RW/RO PgBouncer `Pooler`, optional Barman backups, optional `managedRoles[]`,
and superuser credentials seeded to Vault via `PushSecret`. Composition logic
is written in KCL — see [`kcl/database-cluster/main.k`](../../../kcl/database-cluster/main.k).

## Prerequisites

Install once per cluster (`make providers`):

```bash
kubectl apply -f providers/packages/provider-kubernetes.yaml
kubectl apply -f providers/rbac/provider-kubernetes.yaml
kubectl apply -f providers/packages/runtimeconfig-provider-kubernetes.yaml
kubectl apply -f providers/config/providerconfig-kubernetes.yaml
kubectl apply -f providers/packages/provider-sql.yaml
kubectl apply -f providers/functions/function-kcl.yaml
```

Also requires the [CloudNativePG operator](https://cloudnative-pg.io/) and an
ESO `ClusterSecretStore` (for Vault credential seeding) in-cluster.

## Install

**Production** (registry):

```bash
kubectl apply -f package/install/platform/database-cluster.yaml
```

**Development** (direct apply):

```bash
kubectl apply -k package/platform/database-cluster/
```

## Usage

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XDatabaseCluster
metadata:
  name: cluster-a
spec:
  parameters:
    clusterName: cluster-a
    namespace: cnpg-system
    instances: 1
    postgresVersion: 16
    storageSize: "8Gi"
    shared: true         # joins the shared pool XDatabase (tier: shared) is placed on
    environment: dev     # the pool is per environment; an XDatabase with none uses dev
    vaultPlatformSecretStore: "vault-platform"
```

> **Discovery label required**: every `XDatabaseCluster` XR must
> include `wxops.cloud/managed-by: platform-database-clusters` in
> `metadata.labels` — the value keeps its old name on purpose, so a manifest moves between the two kinds by changing `kind:` alone. `XDatabase` uses this label to discover clusters
> for `tier: shared` placement and to find a `tier: dedicated` database's cluster. See
> [`docs/api-reference/platform/database-cluster.md`](../../../docs/api-reference/platform/database-cluster.md#required-discovery-label)
> for details.

See [`examples/platform/database-cluster/xr.yaml`](../../../examples/platform/database-cluster/xr.yaml)
for the full set of optional fields (pooler, tuning, backup, monitoring,
`managedRoles[]`, `bootstrapFrom`), and
[`docs/api-reference/platform/database-cluster.md`](../../../docs/api-reference/platform/database-cluster.md)
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

Full reference: [`docs/api-reference/platform/database-cluster.md`](../../../docs/api-reference/platform/database-cluster.md#status).

## Relation to other packages

```
XDatabaseCluster (cluster-a, shared: true, environment: dev)
└── XDatabase (rocket-team-production / payment-db) ← tier: shared, placed by environment, kept in status.clusterRef

XDatabaseCluster (rocket-team-analytics-db-cluster, shared: false, wxops.cloud/owner: rocket-team)  ← created by the platform team
└── XDatabase (rocket-team-production / analytics-db) ← tier: dedicated, uses this cluster only
```
