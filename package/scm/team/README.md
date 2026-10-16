# scm-team

Creates a team on Gitea or GitHub, or observes one that already exists, through a single OpenTofu
module — the `scm-repository` pattern applied to teams. The vendor is **not** in this resource's
spec beyond a repeated selector: it is read from the [`scm-connection`](../connection) named in
`scmRef`, with `vendor` repeated per [ADR-004](../../../development-docs/adr/004-scm-repository-vendor-field.md).

This is the successor to the archived [`gitea-team`](../../platform/archives/gitea-team) package —
see [What differs from `gitea-team`](#what-differs-from-gitea-team) below.

## Prerequisites

```bash
kubectl apply -k providers/
```

That brings `provider-opentofu` and its ProviderConfig. You also need an `XScmConnection` whose
credential Secret exists — see [`package/scm/connection`](../connection).

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/scm/scm-team.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/scm/team
```

## Usage

```yaml
apiVersion: scm.wxops.cloud/v1alpha1
kind: XScmTeam
metadata:
  name: rocket-team-developers
  labels:
    wxops.cloud/owner: rocket-team
    # Admits this team's members through Dex once an XOIDCConnector lists the connection's org —
    # see package/auth/oidc-connector. Optional; has no effect without one.
    scm.wxops.cloud/oidc-login: "true"
spec:
  parameters:
    scmRef:
      name: gitea-rocket-team
    vendor: gitea
    teamName: Developers
    permission: write
    repositories: [rocket-api]
    members:
      - username: alice
        role: maintainer   # GitHub only — can edit team settings/membership from GitHub's own UI
      - username: bob
```

See [`examples/scm-team/xr.yaml`](../../../examples/scm-team/xr.yaml).

## Modes

| Mode | What Core does |
|---|---|
| `managed` | Creates and owns the team (a `resource` in the module) |
| `observed` | Only reads it (a `data` source); never writes or deletes. Use this for a host's built-in team (e.g. Gitea's `Owners`) |

Deleting the XR **keeps** the team by default (`retain: true` orphans the `Workspace`). Set
`retain: false` to delete the team with the XR.

## The permission matrix

**Gitea has no roles; GitHub has no per-unit grants.** `permission` is the one field both hosts
honour: on GitHub it is a repository role (`read`→`pull`, `write`→`push`, `admin`→`admin`); on
Gitea it is the base level of a per-unit matrix (see *Units* below). For units at *different* levels, use
`unitPermissions`.

| `permission` | GitHub repository role | Gitea |
|---|---|---|
| `read` | `pull` | every unit in `units` at `read` |
| `write` | `push` | every unit in `units` at `write` |
| `admin` | `admin` | **rejected** — Gitea access is a matrix of `read`/`write`/`none`; use `write` and lower what should differ |

`unitPermissions` lays per-unit overrides over that base (`unit: none|read|write`) — e.g. write
everywhere but only read `actions`.
**`units` and `unitPermissions` are Gitea only — either set to a non-default value fails the apply
on GitHub**, a `precondition` with a clear message, never a
silent drop (per RFC-003's field-matrix rule): GitHub's grant is one role per repository, not a
per-unit matrix.

**`permission` itself applies at a different scope per host, and that changes what it takes to have
any effect.** On Gitea it's a **team-wide** grant (`units`/`units_map`) — in force as soon as the
team exists, independent of `repositories`. On GitHub it's **per repository**
(`github_team_repository`), so **an empty `repositories` list means `permission` does nothing on
GitHub** — the team exists but grants access to nothing, with no error to say so.

## Units — what a Gitea team can be given access to

`units` and `unitPermissions` use Gitea's repository units. In the XR you write the name without the `repo.` prefix; Core adds it
(`code` → `repo.code`). The full list the provider accepts is on the
[`gitea_team` resource page](https://registry.terraform.io/providers/go-gitea/gitea/latest/docs/resources/team).

| Unit | Provider name | What it covers | Set it with |
|---|---|---|---|
| `code` | `repo.code` | the source: `read` browses/clones, `write` pushes | `units` (default) |
| `issues` | `repo.issues` | the built-in issue tracker | `units` (default) |
| `pulls` | `repo.pulls` | pull requests | `units` (default) |
| `wiki` | `repo.wiki` | the built-in wiki | `units` |
| `releases` | `repo.releases` | releases and tags | `units` |
| `projects` | `repo.projects` | project boards | `units` |
| `ext_issues` | `repo.ext_issues` | the link to an external issue tracker (only meaningful if the repo has one configured) | `units` |
| `ext_wiki` | `repo.ext_wiki` | the link to an external wiki (same caveat) | `units` |
| `actions` | `repo.actions` | Gitea Actions (CI/CD) | `units` |
| `packages` | `repo.packages` | the package registry | `units` |

Core renders **one matrix with a record for each of the ten units** — `read`, `write` or `none` — and sends it as the team's `units_map`. Nothing else
reaches Gitea for units, so there is one path whatever you set:

1. every unit in **`units`** gets **`permission`** (`read` or `write`); `units: [all]` is shorthand for all ten, and anything listed next to
   `all` is already covered;
2. every **`unitPermissions`** entry then takes its own level — a different level for a unit already in `units`, or a unit added to it;
3. every unit still unset is `none`. `none` can also be asked for explicitly, but only in `unitPermissions`.

```yaml
# write everywhere, but only read Actions and packages
permission: write
units: [all]
unitPermissions:
  actions: read
  packages: read
```

```yaml
# read-only on three units, wiki added at write, nothing else
permission: read
units: [code, issues, pulls]
unitPermissions:
  wiki: write
```

The `unitPermissions` keys are validated at admission (a CEL rule on the XRD), so a typo is rejected by `kubectl apply` instead of reaching Gitea.
There is no separate `*ReadOnly` flag — a read-only unit is just a `read` entry in `unitPermissions`.

Because the whole matrix is sent every time, going back to fewer overrides — or to none — reliably clears what an earlier apply set; the provider's
`units_map` would otherwise keep a previous grant when it is left unset.

## Members and the org

`members[]` places existing host users in this team. The two hosts differ on what that does to a user who is not in the org yet:

| | A user outside the org added to a team | `XScmTeam` |
|---|---|---|
| **GitHub** | an email invitation, and the membership stays `pending` | **refuses the whole apply**, naming each username — nothing is written |
| **Gitea** | team membership *is* org membership, so they join the org | no check; this is how people get in |

The GitHub gate reads the org's member list (logins match case-insensitively); an invitee who has not accepted is not a member yet and is rejected until they do. The
token's user must itself be an org member, or only public members are visible. Gitea has no equivalent, and the other direction applies there: dropping someone from
the only team they belong to also removes them from the org. An email address is not a username on either host.

## What differs per vendor

| Concern | Gitea | GitHub |
|---|---|---|
| Resource / data source | `gitea_team` / `data.gitea_teams` (filtered by name — no by-name lookup exists) | `github_team` / `data.github_team` (by slug) |
| Membership | `gitea_team_membership` per member, no per-member role | `github_team_membership` per member, `role` from `members[].role` (`member` or `maintainer`) |
| Repository access | `gitea_team.repositories` (on the team itself) | `github_team_repository` per repository, `permission` from the role table above |
| Per-unit grants | `units` / `units_map` | not supported — see the permission matrix |
| Team-level admin | not supported — `permission` is `read` or `write` | `admin` as a repository role |
| `includeAllRepositories` / `canCreateRepos` | `gitea_team` attributes, passed through | not supported — fails the apply if set |
| `privacy` / `parentTeamId` / `notificationSetting` | not supported — fails the apply if set | `github_team` attributes, passed through |

## What differs from `gitea-team`

The archived [`gitea-team`](../../platform/archives/gitea-team) pushed `enableActions`/
`enablePackages`/the two `*ReadOnly` caps through a `null_resource` + `local-exec` + `curl` PATCH
call, because the Terraform provider it was pinned to (`~> 0.7.0`) had no `repo.actions`/
`repo.packages` units and no `units_map` attribute. `go-gitea/gitea` `~> 0.8` has both natively, so
those four flags are gone from `scm-team` rather than ported: `actions` and `packages` are ordinary
entries in `units`, and a read-only cap is `unitPermissions` (`actions: read`) — no direct API call, no
`null_resource`, consistent with the rest of the `scm-*` family (RFC-003 §Composition). The other
`gitea-team` fields carry over, including `includeAllRepositories` and `canCreateRepos` (both
Gitea-only here, as they were there), except `orgName` (now the connection's `org` — RFC-003: no
per-resource override) and `owner` as a `permission` value (Gitea's built-in `Owners` team — bring it
in with `mode: observed` instead).

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `scmRef.name` | string | yes | — | The `XScmConnection` to act through. Also the sole source of the org — there is no `org` field here |
| `vendor` | string | yes | — | `gitea` or `github`; must match the connection's own |
| `teamName` | string | yes | — | Team name within the connection's org |
| `mode` | string | no | `managed` | `managed` or `observed`. **Immutable** — switching `managed` → `observed` would make OpenTofu destroy the host object, so the API server rejects any change; delete and recreate the XR instead. |
| `description` | string | no | `""` | |
| `permission` | string | no | `write` | `read`, `write` or `admin` — see the permission matrix. **Both hosts**, but only takes effect on GitHub when `repositories` is non-empty |
| `units` | []string | no | `[code, issues, pulls]` | **Gitea only**; the ten unit names or `all` — see [Units](#units--what-a-gitea-team-can-be-given-access-to) |
| `unitPermissions` | map[string]string | no | `{}` | **Gitea only**; per-unit overrides on top of `units`/`permission`, `none` only here; keys are unit names without `repo.`, all ten valid |
| `includeAllRepositories` | bool | no | `false` | **Gitea only** |
| `canCreateRepos` | bool | no | `false` | **Gitea only** |
| `privacy` | string | no | `closed` | **GitHub only**; `closed` or `secret` |
| `parentTeamId` | string | no | `""` | **GitHub only**; id or slug of the parent team, for a nested (child) team |
| `notificationSetting` | string | no | `notifications_enabled` | **GitHub only**; the provider's own two literal values |
| `repositories` | []string | no | `[]` | Repository names in the connection's org |
| `members[].username` | string | yes (per entry) | — | Existing host username; on GitHub it must already be in the org — see [Members and the org](#members-and-the-org); authoritative — removing an entry removes that member from the team |
| `members[].role` | string | no | `member` | **GitHub only**; `member` or `maintainer` — a maintainer can edit most team settings and membership from GitHub's own UI |
| `retain` | bool | no | `true` | Keep the team when the XR is deleted |

## Status

| Field | Description |
|---|---|
| `created` / `ready` | Standard contract — absent until the first successful apply. `ready` is also false while the last apply failed |
| `synced` | False while the Workspace's last apply failed; `syncMessage` carries the provider's message (truncated) |
| `exists` | Present on the host |
| `id` | The host's own identifier |
| `org` | The connection's org, echoed |
| `dexTeam` | The team name a connector would see — the Gitea name, or the GitHub slug |
| `oidcGroup` | `<org>:<dexTeam>` — what a connector emits in the `groups` claim once this team is in scope |

Full reference: [`docs/api-reference/scm-team.md`](../../../docs/api-reference/scm-team.md).

## Open items

- `data.gitea_teams` filters by name client-side — confirm against a real Gitea org (no by-name
  Gitea data source exists).
- GitHub's team slug is derived (`lower(replace(teamName, " ", "-"))`) for the `observed` lookup —
  confirm it matches GitHub's own slugify rule for every `teamName` you use.
- `parentTeamId` (nested teams) and `privacy: secret` are not yet verified against a real GitHub
  org — confirm the id/slug form `parent_team_id` accepts, and that a `secret` team behaves as
  documented for non-members.

## `dexTeam` case, across vendors

Gitea's own `teamName` validation (`AlphaDashDot`) already restricts a team name to the same charset
this kind's own `teamName` pattern does — alphanumeric, `-`, `.`, no spaces — so a Gitea `dexTeam`
never needs the kind of cleanup GitHub's slug exists for. The one real difference: Gitea does not
lowercase it, so `dexTeam` (and `oidcGroup`) preserves whatever case the team was created with,
while GitHub's is always lowercase (its own computed slug). If a `groups`/ABAC policy ([RFC-005])
needs to match the same team name across both vendors, keep `teamName` consistently cased yourself —
Core does not normalize it.

[RFC-005]: ../../../development-docs/rfc/005-git-mapped-authorization.md

## Build and publish

```bash
crossplane xpkg build \
  -f package/scm/team \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/scm-team:release-YYYY-MM-DD \
  -f scm-team.xpkg
```
