# database

`XDatabase` is the namespaced successor of [`XTenantDatabase`](../../platform/archives/tenant-database) (ADR-005, RFC-010): the same role, database and credentials, created **in
the team's own namespace**, so the namespace decides whose it is and the platform decides which cluster it lives on. `XTenantDatabase` is archived: every XR moved by the handover in
[migrating to the new kinds](../../../docs/user-guide/migrating-to-new-kinds.md#xtenantdatabase--xdatabase), kept for the record.

Crossplane Configuration package that provisions a tenant PostgreSQL database on a platform
[`XDatabaseCluster`](../../platform/database-cluster), with a continuously reconciled `provider-sql` `Role` and OpenBao-backed connection credentials synced via ESO.

Each `XDatabase` maps to a CNPG `Database` CR + a `provider-sql` `Role` + a `PushSecret` that writes connection creds to OpenBao at
`tenants/{owner}/databases/{dbName}/connection-creds`, where `{owner}` is the namespace's `wxops.cloud/owner`. Composition logic is written in KCL — see
[`kcl/database/main.k`](../../../kcl/database/main.k).

Two tiers are available:
- **`shared`** (default) — a shared `XDatabaseCluster` for the database's environment, chosen by the platform with a stable hash of owner and name, and kept in
  `status.clusterRef`.
- **`dedicated`** — the `XDatabaseCluster` the platform team created for this database (`<owner>-<dbName>-cluster`, labelled with its owner, `shared: false`). The
  database only uses it.

## Prerequisites

Install once per cluster (`make providers`):

```bash
kubectl apply -f providers/packages/provider-kubernetes.yaml
kubectl apply -f providers/rbac/provider-kubernetes.yaml
kubectl apply -f providers/packages/runtimeconfig-provider-kubernetes.yaml
kubectl apply -f providers/config/providerconfig-kubernetes.yaml
kubectl apply -f providers/config/providerconfig-kubernetes-m.yaml   # the hub, as the ClusterProviderConfig namespaced Objects use
kubectl apply -f providers/packages/provider-sql.yaml
kubectl apply -f providers/functions/function-kcl.yaml
kubectl apply -f providers/functions/function-extra-resources.yaml   # reads the XR's Namespace and the platform's clusters
```

**The tenants secret store, `vault-tenant`.** A `ClusterSecretStore` named `vault-tenant`, scoped to OpenBao's `tenants/` mount, must exist before the first
`XDatabase`. The composition fixes the name — a tenant cannot choose another — and its `PushSecret` writes the connection credentials through it. Without it the
`PushSecret` fails to find its store, `status.synced` turns false and `ready` never does.

The [`database-cluster`](../../platform/database-cluster) package installed beside this one, and — for `tier: shared` — at least one `XDatabaseCluster` with
`shared: true`. For `tier: dedicated`, the platform team creates the database's cluster first.

## Install

**Production** (registry):

```bash
kubectl apply -f package/install/tenant/database.yaml
```

**Development** (direct apply):

```bash
kubectl apply -k package/tenant/database/
```

## Usage

```yaml
apiVersion: tenant.wxops.cloud/v1alpha1
kind: XDatabase
metadata:
  name: payment-db                     # the database's logical name unless dbName is set
  namespace: rocket-team-production    # whose it is, through the namespace's wxops.cloud/owner label
spec:
  parameters:
    environment: dev                   # optional, any name — picks the shared pool; absent means "dev"
    extensions:
      - uuid-ossp
      - pgcrypto
```

There is no owner, cluster, namespace or secret store to name, and no discovery label on the `XDatabase`: it does not look for other databases. Every
`XDatabaseCluster` needs `wxops.cloud/managed-by: platform-database-clusters` (and a dedicated one `wxops.cloud/owner`) so it can be found. See
[`docs/api-reference/tenant/database.md`](../../../docs/api-reference/tenant/database.md#required-discovery-labels).

See [`examples/tenant/database/xr.yaml`](../../../examples/tenant/database/xr.yaml) and
[`docs/api-reference/tenant/database.md`](../../../docs/api-reference/tenant/database.md) for the complete `spec.parameters` reference (including `databaseReclaimPolicy`
semantics and how the cluster is chosen).

## Status

| Field | Description |
|---|---|
| `clusterRef` | The CNPG cluster this database is provisioned on. Sticky once assigned. |
| `clusterNamespace` | Namespace of that cluster. |
| `tier` | `shared` or `dedicated`. |
| `dbName` | The logical name. |
| `databaseName` | The PostgreSQL database's own name — `<owner>-<dbName>` unless `databaseName` was set. |
| `owner` | The namespace's `wxops.cloud/owner`. Absent when it has none: the XR then renders nothing and `syncMessage` says so. |
| `created` | True once every composed resource has been observed at least once. |
| `ready` | True when the database is usable: it exists, its owning role exists, and the connection Secret has materialised (plus, on `tier: dedicated`, its cluster is ready). |
| `synced` / `syncMessage` | `synced` is false while a composed resource's last apply failed (its `Ready` can stay True from the earlier success); `syncMessage` is the provider's message, truncated — or why nothing was rendered. |

Full reference: [`docs/api-reference/tenant/database.md`](../../../docs/api-reference/tenant/database.md#status).

## Relation to other packages

```
XDatabaseCluster (shared: true, or dedicated and owned)     ← written by the platform team
└── XDatabase (in the team's namespace)
    └── PushSecret → OpenBao: tenants/{owner}/databases/{dbName}/connection-creds
        └── ExternalSecret (GitOps) → Secret in app namespace
            └── XApp (secretsFrom.database.enabled: true)
```
