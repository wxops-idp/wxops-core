# XOIDCClient

A downstream OAuth client — an application that logs in through the broker, such as Pinniped, the Portal, or oauth2-proxy. Platform-defined: the platform team chooses every client id and redirect URI, and tenants do not create clients — see
[RFC-004](../../development-docs/rfc/004-dex-identity-and-portal-authentication.md#tenant-clients).

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XOIDCClient` |
| **Plural** | `xoidcclients` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/oidc-client/`](../../package/auth/oidc-client) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `connectionRef.name` | `string` | yes | — | The `XOIDCConnection` this client belongs to. |
| `clientId` | `string` | yes | — | The OAuth client id and this resource's own identifier — the remote key is `<vendor>/clients/<clientId>`. |
| `displayName` | `string` | | `""` | |
| `redirectUris` | `[]string` | yes | — | Accepted redirect URIs. |
| `public` | `boolean` | | `false` | True for a browser-only client (PKCE instead of a secret) — no generator runs, the record carries no `secret` field. |
| `trustedPeers` | `[]string` | | `[]` | Other client ids allowed to exchange tokens on this client's behalf. |
| `owner` | `string` (`platform`) | | `platform` | `platform` only in this release. |
| `secret.source` | `string` (`generate`, `static`) | | `generate` | Ignored when `public` is true. `static` reads `<vendor>/clients-def/<clientId>` (property `secret`) — the same `<vendor>/<kind>-def/<id>` convention `oidc-static-password` uses, derived from `clientId`; no separate "where" field. |
| `secret.generator` | `object` | | `{length: 32, digits: 8, symbols: 0}` | `generate` only. |
| `rotation.generation` | `integer` (≥1) | | `1` | Bump to rotate. |

## Editing a client vs rotating its secret

Editing `redirectUris` / `displayName` / `trustedPeers` syncs on its own — it never re-runs the generator. Only `rotation.generation` changes the secret:
`generate` re-runs the generator; `static` re-reads `<vendor>/clients-def/<clientId>` (write the new value there first, then bump). In `generate` mode Core
also writes `{secret, generation}` to `clients-def`, and the record waits for that generation before it renders.

## Rotation, and what it costs

**Not zero-downtime**: a broker client has exactly one secret, so the old value stops working the moment the new one is pushed, and every consumer needs
to pick up the new value (its own `ExternalSecret` refresh) before it can authenticate again.

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the record has been pushed at least once. **Absent** — not `false` — until then. |
| `ready` | `boolean` | Equal to `created` by construction. |
| `synced` | `boolean` | False while a composed resource's last apply failed — its `Ready` condition can stay True from the earlier success. Absent until the first reconcile. See [Sync state](status-contract.md#sync-state--every-package). |
| `syncMessage` | `string` | The failing resource and the provider's own message, truncated to ~400 characters; present only while something is not synced. |
| `clientId` | `string` | Echoed from spec. |
| `vaultKey` | `string` | Where the record (not the secret) was pushed. |

## Example

[`examples/oidc-client/xr.yaml`](../../examples/oidc-client/xr.yaml) — confidential, secret ESO-generated.
