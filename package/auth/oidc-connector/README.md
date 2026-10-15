# oidc-connector

An upstream Git vendor connector — this is what lets a Git host's users sign in through the broker.
Its per-org team allow-list is **generated from `XScmTeam`s**, so adding a team to Dex login is
labelling an `XScmTeam`, not hand-editing `orgs[].teams` and restarting the broker.

## Prerequisites

```bash
kubectl apply -k providers/
```

An [`oidc-connection`](../oidc-connection), the [`XScmConnection`](../../scm/connection) to
authenticate against, and an [`XScmOAuthApp`](../../scm/oauth-app) registered at that host for the
broker.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/auth/oidc-connector.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/auth/oidc-connector
```

## Usage

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XOIDCConnector
metadata:
  name: gitea
spec:
  parameters:
    connectionRef:
      name: dex
    connectorId: gitea
    displayName: Gitea
    scmRef:
      name: gitea-platform-team
    oauthAppRef:
      name: dex-gitea
    orgs:
      - name: platform-team
```

Labelling an `XScmTeam` is what admits its members:

```yaml
apiVersion: scm.wxops.cloud/v1alpha1
kind: XScmTeam
metadata:
  name: platform-team-developers
  labels:
    wxops.cloud/owner: platform-team
    scm.wxops.cloud/oidc-login: "true"
spec:
  parameters:
    scmRef: {name: gitea-platform-team}
    vendor: gitea
    teamName: Developers
    # ...
```

See [`examples/oidc-connector/xr.yaml`](../../../examples/oidc-connector/xr.yaml).

## How a team gets into the `groups` claim

Per org, every `XScmTeam` labelled `scm.wxops.cloud/oidc-login: "true"`, bound to the **same**
`XScmConnection` (matched by `baseUrl` — an org name is only unique per host) and in that org
(`status.org`), contributes its `status.dexTeam` — unioned with whatever `orgs[].teams` lists by
hand, for a team the SCM family doesn't model. An org whose `teams` ends up empty is not an error:
both the Gitea and GitHub Dex connectors treat an empty list as "admit the whole org" — their own
documented behaviour, not something this package invents. `status.teams` shows the resolved list
per org, so what will actually appear in a `groups` claim is visible without reading the pushed
record.

**`orgs` itself may not be empty** — that would admit every user the connection's token can see.

## Field names differ per vendor

The Dex connector config key for the host's base URL is not the same name on both vendors:

| | Gitea | GitHub |
|---|---|---|
| Base URL field | `baseURL`, always set | `hostName`, present only for GitHub Enterprise (omitted for github.com) |
| Team name format | the team's own name | `teamNameField: "slug"` — Core always asks for the slug, matching `XScmTeam.status.dexTeam` |

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `connectionRef.name` | string | yes | — | The `XOIDCConnection` this connector belongs to |
| `connectorId` | string | yes | — | Immutable; part of every `sub` the broker issues |
| `displayName` | string | no | `""` | |
| `scmRef.name` | string | yes | — | The `XScmConnection` to authenticate against |
| `oauthAppRef.name` | string | yes | — | The `XScmOAuthApp` whose credentials this connector uses |
| `orgs` | []object | yes | — | `{name, teams}`; at least one entry |

Not XR fields — hard-coded in the pushed record, the same way `teamNameField` already was: `loadAllGroups: false`
and `useLoginAsID: false` (both vendors), `teamNameField: slug` (GitHub only — Gitea's connector has no such field,
confirmed against its `Config` struct; see the package's own comment in `kcl/oidc-connector/main.k`).

GitHub's slug is always lowercase; Gitea has no slug concept, and its own team-name validation
(`AlphaDashDot`) allows uppercase, so `orgs[].teams` can carry two different cases for what's really
the same claim shape. Not normalized here — see [`scm-team`'s README](../../scm/team#dexteam-case-across-vendors)
— left for RFC-005's authorization layer to resolve once it actually matches `groups` against policy.

## Status

| Field | Description |
|---|---|
| `created` / `ready` | Standard contract |
| `vaultKey` | Where the record was pushed |
| `teams` | Per org, the full resolved team list (generated + hand-listed) |

Full reference: [`docs/api-reference/oidc-connector.md`](../../../docs/api-reference/oidc-connector.md).

## Build and publish

```bash
crossplane xpkg build \
  -f package/auth/oidc-connector \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/oidc-connector:release-YYYY-MM-DD \
  -f oidc-connector.xpkg
```
