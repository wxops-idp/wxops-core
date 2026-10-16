# XScmTeam

Creates a team on Gitea or GitHub, or observes one that already exists, through a single OpenTofu module — the same vendor-exclusive-module pattern
[`XScmRepository`](scm-repository.md) uses (see [ADR-004](../../development-docs/adr/004-scm-repository-vendor-field.md)). The successor to the archived
[`gitea-team`](_archives/gitea-team.md).

| | |
|---|---|
| **Group** | `scm.wxops.cloud` |
| **Kind** | `XScmTeam` |
| **Plural** | `xscmteams` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/scm/team/`](../../package/scm/team) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

## The permission matrix

**Gitea has no roles; GitHub has no per-unit grants.** `permission` is the one field both hosts honour: on GitHub it is a repository role
(`read`→`pull`, `write`→`push`, `admin`→`admin`); on Gitea it is the base level of a per-unit matrix (see *Units* below).

| `permission` | GitHub repository role | Gitea |
|---|---|---|
| `read` | `pull` | every unit in `units` at `read` |
| `write` | `push` | every unit in `units` at `write` |
| `admin` | `admin` | **rejected** — Gitea access is a matrix of `read`/`write`/`none`; use `write` and lower what should differ |

`unitPermissions` lays per-unit overrides over that base — e.g. write everywhere but only read `actions`. **`units` and `unitPermissions` are Gitea only** — either set to a non-default value fails the apply on GitHub, a
`precondition`, never a silent drop (RFC-003's field-matrix rule): GitHub grants one role per repository, not a per-unit matrix.

**`permission` itself applies at a different scope per host.** On Gitea it is a team-wide grant (the per-unit matrix), in force as soon as the team
exists, independent of `repositories`. On GitHub it is per repository (`github_team_repository`) — **an empty `repositories` list means `permission`
has no effect on GitHub at all**, with no error to say so; the team exists but grants access to nothing.

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

Core renders **one matrix with a record for each of the ten units** — `read`, `write` or `none` — and sends it as the team's `units_map`:

1. every unit in **`units`** gets **`permission`** (`read` or `write`); `units: [all]` is shorthand for all ten;
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

The `unitPermissions` keys are validated at admission (a CEL rule on the XRD), so a typo is rejected by `kubectl apply` instead of reaching Gitea.
There is no separate `*ReadOnly` flag. The whole matrix is sent every time, so going back to fewer overrides — or none — clears what an earlier
apply set.

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `scmRef.name` | `string` | yes | — | The `XScmConnection` to act through. Also the sole source of the org — there is no `org` field here. |
| `vendor` | `string` (`gitea`, `github`) | yes | — | Must match the connection's own — see ADR-004. |
| `teamName` | `string` | yes | — | Team name within the connection's org. |
| `mode` | `string` (`managed`, `observed`) | | `managed` | `observed` reads a host's built-in team (e.g. Gitea's `Owners`) without writing it. **Immutable** — switching `managed` → `observed` would make OpenTofu destroy the host object, so the API server rejects any change; delete and recreate the XR instead. |
| `description` | `string` | | `""` | |
| `permission` | `string` (`read`, `write`, `admin`) | | `write` | Both hosts — see the permission matrix for the scope difference. `admin` is rejected on Gitea. |
| `units` | `[]string` | | `[code, issues, pulls]` | Gitea only. Any of the ten unit names, or `all` for every one — see [Units](#units--what-a-gitea-team-can-be-given-access-to). |
| `unitPermissions` | `map[string]string` (`none`\|`read`\|`write`) | | `{}` | Gitea only; per-unit overrides on top of `units`/`permission`; `none` is only valid here. Keys are unit names without `repo.` — all ten, `actions`/`packages` included. |
| `includeAllRepositories` | `boolean` | | `false` | Gitea only; the provider's own flag, passed through. |
| `canCreateRepos` | `boolean` | | `false` | Gitea only; the provider's own flag, passed through. |
| `privacy` | `string` (`closed`, `secret`) | | `closed` | GitHub only. |
| `parentTeamId` | `string` | | `""` | GitHub only; id or slug of the parent team, for a nested (child) team. |
| `notificationSetting` | `string` (`notifications_enabled`, `notifications_disabled`) | | `notifications_enabled` | GitHub only; the provider's own two literal values, not abstracted to a boolean. |
| `repositories` | `[]string` | | `[]` | Repository names in the connection's org. |
| `members[].username` | `string` | yes (per entry) | — | Existing host username; on GitHub it must already be in the org — see [Members and the org](#members-and-the-org). Authoritative — removing an entry removes that member from the team. |
| `members[].role` | `string` (`member`, `maintainer`) | | `member` | GitHub only; a `maintainer` can edit most team settings and membership from GitHub's own UI. Fails the apply on Gitea if not `member`. |
| `retain` | `boolean` | | `true` | Keep the team when the XR is deleted (orphans the `Workspace`). |

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
| Resource / data source | `gitea_team` / `data.gitea_teams` (filtered client-side by name) | `github_team` / `data.github_team` (by slug) |
| Membership | `gitea_team_membership` per member, no per-member role | `github_team_membership` per member, `role` from `members[].role` |
| Repository access | `gitea_team.repositories` | `github_team_repository` per repository |
| `permission: admin` | rejected — `read`/`write` plus per-unit overrides | the `admin` repository role |
| `includeAllRepositories` / `canCreateRepos` | native `gitea_team` attributes | not supported — fails the apply if set |
| `privacy` / `parentTeamId` / `notificationSetting` | not supported — fails the apply if set | native `github_team` attributes |

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the apply has completed, derived from the `id` output. **Absent** — not `false` — until then. |
| `ready` | `boolean` | `created` **and** `synced`: true only while the team exists and the last apply succeeded. |
| `synced` | `boolean` | False while the provisioning Workspace's last apply failed (e.g. Gitea rejected a member). Absent until the first reconcile. |
| `syncMessage` | `string` | The failing resource and the provider's own message, truncated to ~400 characters; present only while something is not synced. The full error is on the Workspace's `Synced` condition. |
| `exists` | `boolean` | Present on the host. The whole point of `observed` mode. |
| `id` | `string` | The host's own identifier. |
| `org` | `string` | The connection's org, echoed. |
| `baseUrl` | `string` | The connection's base URL, echoed — lets `XOIDCConnector` match a team to the right host. |
| `dexTeam` | `string` | The team name a connector would see — the Gitea name, or the GitHub slug. |
| `oidcGroup` | `string` | `<org>:<dexTeam>` — what a connector emits in the `groups` claim once this team is in scope (see [`oidc-connector`](oidc-connector.md)). |

## Example

[`examples/scm-team/xr.yaml`](../../examples/scm-team/xr.yaml)
