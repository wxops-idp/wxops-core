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

## Choosing which teams can sign in

A connector admits people by org and, optionally, by team. Which teams are allowed is yours to decide, and there are two ways to say so that can be used together.
Whatever the result, `status.teams` shows the exact per-org list the broker will use.

| You want | Do this | Where the name comes from |
|---|---|---|
| A team Core already manages | Label its [`XScmTeam`](scm-team.md) `scm.wxops.cloud/oidc-login: "true"` | The team's `status.dexTeam` — written for you |
| A team Core does not manage (a pre-existing or built-in one) | List it in `orgs[].teams` | Exactly what you type |
| Everyone in the org | Leave the org's list empty (no labelled team, nothing listed) | The host's own "no team restriction" behaviour |

A labelled `XScmTeam` is picked up for an org only when **all three** hold: it carries the label, it is bound to the **same host** as the connector's `scmRef` (compared by
`baseUrl`, since an org name is only unique per host), and its `status.org` is that org. A team that fails any of these is skipped without error, which is how two hosts
that happen to share an org name stay separate. The generated names are then added **after** whatever you listed by hand, and the two are not de-duplicated: a team named in
both places appears twice, which Dex tolerates, so drop the hand-written entry once the `XScmTeam` is labelled.

### The names are slugs on GitHub and plain names on Gitea

The value the broker matches is not the same shape on both hosts, and that is deliberate:

| | Gitea | GitHub |
|---|---|---|
| What `dexTeam` holds | the team name as created, case preserved (`Owners`) | the lowercase slug (`owners`) |
| What the broker is told | the team name | `teamNameField: slug` — always the slug |
| What you type in `orgs[].teams` | the name, matching case | the **slug**, lowercase |

So a hand-listed GitHub team must be written as its slug (`platform-owners`, not `Platform Owners`), and a Gitea one as spelled in Gitea. Core does not normalise case across the
two hosts; if the same word is meant to match on both, keep it consistently cased yourself. The resulting group in the token is `<org>:<team>`, the same string `XScmTeam`
reports as `status.oidcGroup`.

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XOIDCConnector
metadata:
  name: github
spec:
  parameters:
    connectionRef: {name: dex}
    scmRef: {name: github-wxops}          # a GitHub connection
    oauthAppRef: {name: dex-github}
    connectorId: github
    orgs:
      - name: wxops-idp
        teams: [release-managers]         # hand-listed: a GitHub team Core does not manage, as its slug
---
apiVersion: scm.wxops.cloud/v1alpha1
kind: XScmTeam
metadata:
  name: wxops-idp-platform
  labels:
    scm.wxops.cloud/oidc-login: "true"    # generated: joins wxops-idp's list as its slug
spec:
  parameters:
    scmRef: {name: github-wxops}
    vendor: github
    teamName: Platform
```

Here the broker admits members of `wxops-idp` who belong to `release-managers` or `platform`, and `status.teams` reads `{wxops-idp: [release-managers, platform]}`.

### Why this matters for authorization

The `groups` claim is what [RFC-005](../../development-docs/rfc/005-git-mapped-authorization.md) maps one-to-one to ownership: a team in the claim is a team the platform can
authorize on. Choosing teams here therefore decides which Git teams can ever appear in a policy decision, and the slug form is what keeps `<org>:<team>` identical to the
owner label on the resources. A team that is not labelled or listed never reaches the claim, so it cannot be granted anything through login.

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
| `synced` | `boolean` | False while a composed resource's last apply failed — its `Ready` condition can stay True from the earlier success. Absent until the first reconcile. See [Sync state](status-contract.md#sync-state--every-package). |
| `syncMessage` | `string` | The failing resource and the provider's own message, truncated to ~400 characters; present only while something is not synced. |
| `vaultKey` | `string` | Where the record was pushed. |
| `teams` | `map[string][]string` | Per org, the full resolved team list (generated + hand-listed) — what will actually appear in a `groups` claim. |

## Example

[`examples/oidc-connector/xr.yaml`](../../examples/oidc-connector/xr.yaml)
