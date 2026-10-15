# XOIDCStaticPassword

A local broker user — a bootstrap admin, or a break-glass account — with no Git membership behind it. The password is never written in Git or an XR
field: it is either ESO-generated or read once from an operator-written OpenBao key, and the bcrypt hash the broker needs is computed inside the same
render that reads it.

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XOIDCStaticPassword` |
| **Plural** | `xoidcstaticpasswords` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/oidc-static-password/`](../../package/auth/oidc-static-password) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `connectionRef.name` | `string` | yes | — | The `XOIDCConnection` this user belongs to. |
| `email` | `string` | yes | — | Sign-in identifier, per the broker's own documented contract. |
| `username` | `string` | yes | — | Display login and this resource's own identifier — the remote key is `<vendor>/users/<username>` (and `<vendor>/users-def/<username>`). |
| `displayName` | `string` | | `""` | |
| `userId` | `string` | | `username` | The broker's own stable identifier for this user. Deterministic, never random. |
| `groups` | `[]string` | | `[]` | Claim groups — independent of any `XScmTeam`, since this is a local account with no Git membership behind it. |
| `secret.source` | `string` (`generate`, `static`) | yes | — | See below. |
| `secret.generator` | `object` (`length`, `digits`, `symbols`, `noUpper`, `allowRepeat`) | | `{length: 32, digits: 8, symbols: 0}` | `generate` only. |
| `rotation.generation` | `integer` (≥1) | | `1` | Bump to regenerate (`generate`) or re-read (`static`). |

## `secret.source`

| | `generate` | `static` |
|---|---|---|
| Password comes from | an ESO `Password` generator | an operator-written `<vendor>/users-def/<username>` key, property `password` — **plaintext**, never a hash |
| Plaintext ends up at | `<vendor>/users-def/<username>` — Core pushes `{password, generation}` there for the human to read | already there — the operator wrote it |
| Use for | a break-glass account nobody needs to choose | the first bootstrap admin, or any password you want to set yourself |

Either way, `<vendor>/users/<username>` holds the **record** the broker reads (never the plaintext): `email`, `username`, `name`, `userID`, `groups`, and
a bcrypt `hash`, computed by ESO's v2 template engine's Sprig `bcrypt` function (`{{ .password | bcrypt }}`).

## Editing a user vs rotating its password

| You want to… | Do this |
|---|---|
| Change `groups` / `email` / `displayName` / `userId` | Edit the XR — syncs on its own, no bump. The password is untouched; the hash is re-salted, so the broker restarts once. |
| **`generate`:** a new random password | Bump `rotation.generation` — the only thing that re-runs the generator. |
| **`static`:** a new password | Write it to `<vendor>/users-def/<username>`, **then** bump `rotation.generation`. |

> [!IMPORTANT]
> `rotation.generation` is the only thing that changes the password. ESO does not poll OpenBao, so in `static` mode overwriting `users-def` does
> nothing until the bump. See the package
> [README](../../package/auth/oidc-static-password/README.md#editing-a-user-vs-rotating-its-password) for how the two `ExternalSecret`s are split.

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the record has been pushed at least once. **Absent** — not `false` — until then. |
| `ready` | `boolean` | Equal to `created` by construction. |
| `userId` | `string` | The resolved userId (the XR's own `userId`, or `username` if left unset). |
| `vaultKey` | `string` | Where the record (not the password) was pushed. |

## Example — the bootstrap admin

[`examples/oidc-static-password/xr.yaml`](../../examples/oidc-static-password/xr.yaml)
