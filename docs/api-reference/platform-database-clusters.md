# XPlatformDatabaseCluster

Platform-managed CloudNativePG cluster with pooler, Vault credential seeding,
and optional shared-cluster labeling for dynamic tenant pool discovery.

| | |
|---|---|
| **Group** | `platform.wxops.cloud` |
| **Kind** | `XPlatformDatabaseCluster` |
| **Plural** | `xplatformdatabaseclusters` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/platform/platform-database-clusters/`](../../package/platform/platform-database-clusters) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |
| **Composition function** | [`function-kcl`](https://github.com/crossplane-contrib/function-kcl) — see [`kcl/platform-database-clusters/main.k`](../../kcl/platform-database-clusters/main.k) |

## `spec.parameters`

> **Vault path convention**: all `PushSecret`/`ExternalSecret` paths in this
> package omit the `platform/` prefix (e.g. `database-clusters/...`, not
> `platform/database-clusters/...`). The `vault-platform` `ClusterSecretStore`
> is itself scoped to the `platform/` KV2 path, so adding `platform/` again
> here would duplicate it and write to `platform/platform/database-clusters/...`.

### Core

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `cluster` | `string` | | `"default"` | Name of the provider-kubernetes `ProviderConfig` to apply composed resources through. `"default"` is the local hub cluster — the only one wired up today, so leaving this unset is behaviour-neutral. Set it to target a spoke cluster once a `ProviderConfig` for it exists — see [multi-cluster.md](../core-ideas/multi-cluster.md). |
| `clusterName` | `string` | yes | | CNPG cluster name. Tenants pass this value as `clusterRef` in `XTenantDatabase` to locate the cluster and its superuser secret. |
| `namespace` | `string` | yes | | Kubernetes namespace where the CNPG cluster is created. |
| `instances` | `integer` (1–9) | | `1` | Number of PostgreSQL instances. `1` = standalone (dev/test), `3` = HA. |
| `postgresVersion` | `integer` | | `16` | PostgreSQL major version. Maps to the community image `ghcr.io/cloudnative-pg/postgresql:{version}`. |
| `storageSize` | `string` | | `"8Gi"` | PVC storage size per instance. |
| `shared` | `boolean` | | `false` | Mark this cluster as available for shared multi-tenant use. When `true`, the composition writes `status.shared: true`, and `XTenantDatabase` filters by this status field to build the shared pool. |
| `environment` | `string` (`dev`, `staging`, `prod`) | | `"dev"` | Environment this cluster serves. When `shared: true`, `XTenantDatabase` only auto-assigns databases whose `environment` matches — dev databases go to dev clusters, prod to prod. Written to `status.environment`. |
| `vaultPlatformSecretStore` | `string` | | `"vault-platform"` | ESO `ClusterSecretStore` name used by `PushSecret` to mirror CNPG's own `{clusterName}-superuser` and `{clusterName}-app` secrets to Vault at `database-clusters/{clusterName}/superuser-creds` and `database-clusters/{clusterName}/app-creds`. Each push writes the whole secret in one go (no per-key `property`), so only one Vault KV2 version is created per reconcile. When `enablePooler` is true, pooler-prefixed connection strings (`pooler-host`, `pooler-port`, `pooler-uri`, `pooler-jdbc-uri`, `pooler-pgpass`) are merged into both Vault entries via the PushSecret's `spec.template`. |

### Pooler (RW)

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `enablePooler` | `boolean` | | `true` | Deploy a PgBouncer `Pooler` (type `rw`) alongside the cluster. |
| `poolMode` | `string` (`transaction`, `session`) | | `transaction` | PgBouncer pool mode for the RW pooler. |

### `postgresConfig`

PostgreSQL server configuration (`postgresql.conf`) and client authentication
rules (`pg_hba.conf`), passed through to `spec.postgresql` on the CNPG
`Cluster`. Some parameters are fixed by CNPG and cannot be overridden here
(e.g. `archive_command`, `listen_addresses`, `wal_level`, `port`,
`data_directory`) — see the [CNPG postgresql.conf docs](https://cloudnative-pg.io/documentation/1.29/postgresql_conf/).

| Field | Type | Default | Description |
|---|---|---|---|
| `postgresConfig.tuning` | `object` | `{}` | Common/popular `postgresql.conf` settings with sensible defaults. Use these for routine sizing/tuning changes. |
| `postgresConfig.tuning.maxConnections` | `integer` | `200` | |
| `postgresConfig.tuning.sharedBuffers` | `string` | | e.g. `"256MB"`, `"1GB"` |
| `postgresConfig.tuning.workMem` | `string` | | e.g. `"16MB"` |
| `postgresConfig.tuning.maintenanceWorkMem` | `string` | | e.g. `"256MB"` |
| `postgresConfig.tuning.effectiveCacheSize` | `string` | | e.g. `"3GB"` |
| `postgresConfig.tuning.maxWalSize` | `string` | | e.g. `"2GB"` |
| `postgresConfig.tuning.minWalSize` | `string` | | e.g. `"512MB"` |
| `postgresConfig.tuning.checkpointCompletionTarget` | `string` | | Float as string, e.g. `"0.9"` |
| `postgresConfig.tuning.randomPageCost` | `string` | | Float as string. Use `"1.1"` for SSD-backed storage (default planner assumption is `"4"` for spinning disks). |
| `postgresConfig.tuning.logMinDurationStatement` | `string` | | Milliseconds, or `"-1"` to disable. e.g. `"1000"` |
| `postgresConfig.tuning.logStatement` | `string` (`none`, `ddl`, `mod`, `all`) | | |
| `postgresConfig.tuning.statementTimeout` | `string` | | e.g. `"30s"`, `"5min"` |
| `postgresConfig.tuning.idleInTransactionSessionTimeout` | `string` | | e.g. `"10min"` |
| `postgresConfig.extraParameters` | `object` (`additionalProperties: string`) | `{}` | Free-form `postgresql.conf` parameters for cluster-specific requirements not covered by `tuning`. Keys here override the same key in `tuning`. Example: `{"track_io_timing": "on", "wal_compression": "zstd"}`. |
| `postgresConfig.pgHba` | `array<string>` | `[]` | Additional `pg_hba.conf` rules, appended after CNPG's own default rules (CNPG always keeps the rules it needs for the superuser and streaming replication). Example: `- "hostssl app app_db 10.0.0.0/8 scram-sha-256"`. |

### `monitoring`

Prometheus Operator integration.

| Field | Type | Default | Description |
|---|---|---|---|
| `monitoring.enablePodMonitor` | `boolean` | `false` | When true, CNPG creates a `PodMonitor` so Prometheus Operator scrapes the cluster metrics endpoint (port 9187). Requires the Prometheus Operator CRDs to be installed in the cluster. |

### `backup`

Barman object-store backup configuration. When enabled, WAL archiving is
activated on the cluster and a `ScheduledBackup` CR is created.

| Field | Type | Default | Description |
|---|---|---|---|
| `backup.enabled` | `boolean` | `false` | |
| `backup.destinationPath` | `string` | | Object store destination path. S3/MinIO: `s3://my-bucket/cnpg/cluster-a`; GCS: `gs://my-bucket/cnpg/cluster-a`. |
| `backup.endpointURL` | `string` | | Override the storage endpoint (MinIO, Ceph RGW, etc.). Leave blank for native AWS S3, GCS, or Azure Blob. |
| `backup.credentialsSecretRef` | `object` | | Existing K8s Secret containing cloud storage credentials. S3/MinIO: keys `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`. GCS: key `APPLICATION_CREDENTIALS` (service-account JSON). Azure: keys `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_KEY`. The Secret must exist before the XR is applied. |
| `backup.credentialsSecretRef.name` | `string` | | |
| `backup.credentialsSecretRef.namespace` | `string` | | |
| `backup.schedule` | `string` | `"0 0 2 * * *"` | `ScheduledBackup` cron expression (6-field: sec min hr dom mon dow). Default: daily at 02:00 UTC. |
| `backup.retentionPolicy` | `string` | `"30d"` | Barman WAL and base-backup retention window (e.g. `7d`, `30d`, `90d`). |

### `readReplica`

Dedicated read-only PgBouncer Pooler for replica traffic.

| Field | Type | Default | Description |
|---|---|---|---|
| `readReplica.enablePooler` | `boolean` | `false` | Deploy a second PgBouncer `Pooler` of type `ro` in addition to the RW pooler. Exposes service `{clusterName}-ro-pooler` for read workloads. |
| `readReplica.poolerInstances` | `integer` (1–9) | `1` | |

### `managedRoles[]`

General, cluster-wide PostgreSQL roles (e.g. `readonly`, a second superuser)
managed declaratively via `spec.managed.roles[]` on the CNPG `Cluster` —
platform fully owns this array, so no Server-Side-Apply coordination with
`tenant-database` is needed.

Each entry gets its own ESO Password generator and a STABLE `ExternalSecret`
(`{clusterName}-{name}-creds`, `refreshInterval: "0"` — NOT auto-rotated). To
change the password, delete that Secret; CNPG then regenerates it and runs
`ALTER ROLE` with the new value. A `PushSecret` syncs each role's credentials
to Vault at `database-clusters/{clusterName}/roles/{name}/creds` (whole-secret push, one Vault version per reconcile).

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `managedRoles[].name` | `string` | yes | | PostgreSQL role name. |
| `managedRoles[].ensure` | `string` (`present`, `absent`) | | `present` | |
| `managedRoles[].login` | `boolean` | | `true` | |
| `managedRoles[].superuser` | `boolean` | | `false` | |
| `managedRoles[].createdb` | `boolean` | | `false` | Grant `CREATEDB` privilege. |
| `managedRoles[].createrole` | `boolean` | | `false` | Grant `CREATEROLE` privilege. |
| `managedRoles[].inherit` | `boolean` | | `true` | Inherit privileges of roles this role is a member of (via `inRoles`). Default `true` per PostgreSQL convention. |
| `managedRoles[].replication` | `boolean` | | `false` | Grant `REPLICATION` privilege. |
| `managedRoles[].bypassrls` | `boolean` | | `false` | Bypass row-level security policies. |
| `managedRoles[].connectionLimit` | `integer` | | `-1` | Max concurrent connections for this role. `-1` = unlimited. |
| `managedRoles[].inRoles` | `array<string>` | | `[]` | Roles this role is a member of. Use for PostgreSQL predefined roles (`pg_read_all_data`, `pg_write_all_data`, `pg_monitor`, `pg_signal_backend`, etc.) or custom parent roles. See [PostgreSQL predefined roles](https://www.postgresql.org/docs/current/predefined-roles.html). |

### `bootstrapFrom`

Override how the cluster is initialized. Default (`initdb`) creates a fresh
empty cluster.

Import types use CNPG's built-in pg_dump-based import — see the
[CNPG database import docs](https://cloudnative-pg.io/docs/1.29/database_import).

- **`import-microservices`** — copy one database from an external PostgreSQL.
  The new cluster owns only that database. Roles are NOT copied; application
  roles must be recreated (e.g. via `XTenantDatabase`). Best for migrating a
  single micro-service database.
- **`import-monolith`** — copy multiple databases and their owners from an
  external PostgreSQL. Roles matching `sourceDatabases` owners are also
  imported. Best for migrating a legacy shared-database application.

Both import types require the source PostgreSQL to be reachable from the
cluster during bootstrap. The import is a one-time operation; the source
instance is never touched after the cluster is `Ready`.

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `bootstrapFrom.type` | `string` (`initdb`, `import-microservices`, `import-monolith`) | | `"initdb"` | |
| `bootstrapFrom.sourceHost` | `string` | | | Hostname or IP of the source PostgreSQL instance. |
| `bootstrapFrom.sourcePort` | `integer` | | `5432` | |
| `bootstrapFrom.sourceDatabase` | `string` | | | Single database to import (`import-microservices` only). |
| `bootstrapFrom.sourceDatabases` | `array<string>` | | `[]` | Database names to import (`import-monolith` only). |
| `bootstrapFrom.sourceRoles` | `array<string>` | | `[]` | PostgreSQL role names to import in addition to database owners (`import-monolith` only). |
| `bootstrapFrom.sourceUser` | `string` | | `postgres` | Superuser name on the source instance. |
| `bootstrapFrom.sourceSSLMode` | `string` (`disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`) | | `require` | |
| `bootstrapFrom.sourcePasswordSecretRef` | `object` | | | Existing K8s Secret with key `password` holding the source superuser password. Must exist before the XR is applied. |
| `bootstrapFrom.sourcePasswordSecretRef.name` | `string` | | | |
| `bootstrapFrom.sourcePasswordSecretRef.namespace` | `string` | | | |

## Channels

Every release labels its Composition `channel: stable`; `make install-dev` overrides it to
`channel: nightly` via Kustomize. Track a channel with `spec.crossplane`, a sibling of
`spec.parameters`, not a field inside it:

```yaml
spec:
  parameters: {...}
  crossplane:
    compositionRevisionSelector:
      matchLabels:
        channel: stable          # or nightly
    compositionUpdatePolicy: Automatic
```

Full mechanism, the `Manual`-pin alternative, and why: [Channels](../../development-docs/development/releasing.md#channels).

## `status`

| Field | Type | Description |
|---|---|---|
| `clusterName` | `string` | Echoed from `spec.parameters.clusterName`. |
| `namespace` | `string` | Namespace where the CNPG cluster lives. |
| `shared` | `boolean` | Whether this cluster is in the shared multi-tenant pool. |
| `environment` | `string` | Environment this cluster serves (`dev`, `staging`, `prod`). |
| `created` | `boolean` | True once every composed resource has been observed at least once. Indicates provisioning has started, not that it succeeded. |
| `ready` | `boolean` | True when the cluster can serve connections: the CNPG `Cluster` is up, and any enabled pooler is up too — tenants are handed the pooler endpoint, not the cluster's directly. Derived from observed composed-resource state rather than the native `type: Ready` condition, which is unreliable on Crossplane v2.3 with function-kcl v0.12.1. **Poll this field, not conditions.** Vault credential seeding and scheduled backups are deliberately excluded — neither stops a running cluster from serving. |

## Required discovery label

`XTenantDatabase` discovers platform clusters via `function-extra-resources`,
which selects XRs by label. Every `XPlatformDatabaseCluster` XR **must**
include this label in its manifest:

```yaml
metadata:
  labels:
    wxops.cloud/managed-by: platform-database-clusters
```

> **Why a manifest label?** Crossplane's composite reconciler writes `status`
> fields from composition dxr updates, but **ignores `metadata.labels`**. The
> composition cannot set discovery labels automatically — they must be in the
> XR manifest applied by the user or GitOps. Without this label,
> `XTenantDatabase` will not discover the cluster for `tier: shared`
> auto-assignment.

The composition uses `status.shared` and `status.environment` (written by
the dxr update) to filter the pool — the label only controls **which XRs
are fetched**, not which ones are selected as shared.

## Example

See [`examples/platform-database-clusters/xr.yaml`](../../examples/platform-database-clusters/xr.yaml).
