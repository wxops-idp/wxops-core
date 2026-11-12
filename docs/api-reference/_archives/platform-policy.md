# XPlatformPolicy

> **Replaced by [`XPolicy`](../auth/policy.md)** ([ADR-005](../../../development-docs/adr/005-kind-ownership-scope-and-naming.md)): the same templates, the same
> parameters, a name that does not repeat the API group. `XPlatformPolicy` stays served so existing policies keep working, and a later release archives it.
> Move a policy with [the handover](../../user-guide/migrating-to-new-kinds.md#xplatformpolicy--xpolicy). New policies should be `XPolicy`.

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XPlatformPolicy` |
| **Plural** | `xplatformpolicies` |
| **Scope** | `Cluster` |
| **Package** | [`package/auth/platform-policy/`](../../../package/auth/archives/platform-policy) |

Every field, template and example is on the [`XPolicy` page](../auth/policy.md); replace `XPolicy` with `XPlatformPolicy` in a manifest to use the old kind. Both kinds
render from one source (`kcl/platform-policy/main.k`), so they cannot drift.
