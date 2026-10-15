# XOIDCConnector

An upstream Git vendor connector — this is what lets a Git host's users sign in through the broker. Its per-org team allow-list is **generated from
`XScmTeam`s**, so adding a team to broker login is labelling an `XScmTeam`, not hand-editing `orgs[].teams` and restarting the broker.

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XOIDCConnector` |
| **Plural** | `xoidcconnectors` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/oidc-connector/`](../../package/auth/oidc-connector) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

## How a team gets into the `groups` claim

Per org, every [`XScmTeam`](scm-team.md) labelled `scm.wxops.cloud/oidc-login: "true"`, bound to the **same** `XScmConnection` (matched by `baseUrl` — an
org name is only unique per host) and in that org (`status.org`), contributes its `status.dexTeam` — unioned with whatever `orgs[].teams` lists by hand,
for a team the SCM family doesn't model. An org whose `teams` ends up empty is not an error: both the Gitea and GitHub broker connectors treat an empty
list as "admit the whole org" — their own documented behaviour, not something this package invents. `status.teams` shows the resolved list per org.

**`orgs` itself may not be empty** — that would admit every user the connection's token can see.

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `connectionRef.name` | `string` | yes | — | The `XOIDCConnection` this connector belongs to. |
| `connectorId` | `string` | yes | — | Immutable; part of every `sub` the broker issues. Also this resource's own identifier — the remote key is `<vendor>/connectors/<connectorId>`. |
| `displayName` | `string` | | `""` | |
| `scmRef.name` | `string` | yes | — | The `XScmConnection` to authenticate against — its vendor becomes the broker connector `type`, its `baseUrl` the connector's own base URL. |
| `oauthAppRef.name` | `string` | yes | — | The `XScmOAuthApp` whose client id/secret this connector uses. Its `status.vaultKey` is read, not assumed. |
| `orgs` | `[]object` (`name`, `teams`) | yes (≥1) | — | See above. |

Not XR fields — hard-coded in the pushed record: `loadAllGroups: false` and `useLoginAsID: false` (both vendors), `teamNameField: slug` (GitHub only — Gitea's connector has no such field).

GitHub's slug is always lowercase; Gitea allows uppercase team names and has no slug concept, so `orgs[].teams` can carry two different cases for what's really the same claim — not normalized here, left for RFC-005's authorization layer.

## Field names differ per vendor

| | Gitea | GitHub |
|---|---|---|
| Base URL field | `baseURL`, always set | `hostName`, present only for GitHub Enterprise (omitted for github.com) |
| Team name format | the team's own name | `teamNameField: "slug"` — always requested, matching `XScmTeam.status.dexTeam` |

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the record has been pushed at least once. **Absent** — not `false` — until then. |
| `ready` | `boolean` | Equal to `created` by construction. |
| `vaultKey` | `string` | Where the record was pushed. |
| `teams` | `map[string][]string` | Per org, the full resolved team list (generated + hand-listed) — what will actually appear in a `groups` claim. |

## Example

[`examples/oidc-connector/xr.yaml`](../../examples/oidc-connector/xr.yaml)
