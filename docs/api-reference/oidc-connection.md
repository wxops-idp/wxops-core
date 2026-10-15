# XOIDCConnection

Points at one broker install and publishes the facts every other `oidc-*` kind needs — which remote-key prefix to write under, and whether the broker's
own config render is currently succeeding. Dex is the only broker in this release — see
[RFC-004](../../development-docs/rfc/004-dex-identity-and-portal-authentication.md).

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XOIDCConnection` |
| **Plural** | `xoidcconnections` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/oidc-connection/`](../../package/auth/oidc-connection) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

## Core renders no broker config

The W'xOps [`dexidp` chart](https://github.com/wxops-idp/charts/tree/main/dexidp) owns that: one `ExternalSecret` scans `<vendor>/connectors`,
`<vendor>/clients` and `<vendor>/users` in OpenBao, merges them with its own `dynamicConfig.base` (issuer, storage, web, expiry — chart values, never
written by Core), and writes the broker's config Secret. Reloader restarts the broker. This package only **observes** that `ExternalSecret` —
`managementPolicies: ["Observe"]` on a `provider-kubernetes` `Object` — so Core's only window into "did the broker get every record" is its Ready
condition.

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `vendor` | `string` (`dex`) | | `dex` | The remote-key prefix every `oidc-*` kind writes under. |
| `issuer` | `string` | yes | — | Must equal the chart's own `dynamicConfig.base.issuer`. |
| `secretStoreRef.name` | `string` | | `vault-platform` | Must read the same OpenBao mount the chart's `SecretStore` reads. |
| `config.namespace` | `string` | yes | — | Namespace the chart installed the broker (and its `ExternalSecret`) into. |
| `config.externalSecretName` | `string` | | `dex-config` | The chart's `dynamicConfig.secretName`. |

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the chart's config `ExternalSecret` has been observed at least once. **Absent** — not `false` — until then. |
| `ready` | `boolean` | True when the chart's `ExternalSecret` reports `Ready: "True"` — the last render, with every record, succeeded. **Never** that the broker has actually reloaded; Core cannot observe that. |
| `message` | `string` | The `ExternalSecret`'s own condition message when not ready — a malformed record, a duplicate id, or a missing store, straight from the chart's fail-closed template. |
| `callbackUrl` | `string` | `<issuer>/callback` — what every `XOIDCConnector`'s upstream OAuth application redirect URI must contain. |

## Example

[`examples/oidc-connection/xr.yaml`](../../examples/oidc-connection/xr.yaml)
