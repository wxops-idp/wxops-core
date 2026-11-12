# XPlatformDatabaseCluster

> **Replaced by [`XDatabaseCluster`](../platform/database-cluster.md)** ([ADR-005](../../../development-docs/adr/005-kind-ownership-scope-and-naming.md)): the same cluster, the same
> parameters, a name that does not repeat the API group. `XPlatformDatabaseCluster` stays served so existing clusters keep working, and a later release archives it.
> Move a cluster with [the handover](../../user-guide/migrating-to-new-kinds.md#xplatformdatabasecluster--xdatabasecluster). New clusters should be `XDatabaseCluster`.

| | |
|---|---|
| **Group** | `platform.wxops.cloud` |
| **Kind** | `XPlatformDatabaseCluster` |
| **Plural** | `xplatformdatabaseclusters` |
| **Scope** | `Cluster` |
| **Package** | [`package/platform/platform-database-clusters/`](../../../package/platform/archives/platform-database-clusters) |

Every field and example is on the [`XDatabaseCluster` page](../platform/database-cluster.md); replace `XDatabaseCluster` with `XPlatformDatabaseCluster` in a manifest to use the old
kind. Both kinds render from one source (`kcl/platform-database-clusters/main.k`), so they cannot drift.
