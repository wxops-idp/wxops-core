# XGiteaTeam

Manages a team inside a Gitea organisation, including membership.

| | |
|---|---|
| **Group** | `platform.wxops.cloud` |
| **Kind** | `XGiteaTeam` |
| **Plural** | `xgiteateams` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/platform/archives/gitea-team/`](../../../package/platform/archives/gitea-team/) — see [`VERSIONS.yaml`](../../../VERSIONS.yaml) for the current package version |

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `giteaUrl` | `string` | yes | | Base URL of the Gitea instance. |
| `insecure` | `boolean` | | `false` | Skip TLS verification. |
| `orgName` | `string` | yes | | Name of the organization this team belongs to. |
| `teamName` | `string` | yes | | Team name within the organization. |
| `description` | `string` | | `""` | Team description. |
| `permission` | `string` (`none`, `read`, `write`, `admin`, `owner`) | | `read` | Base permission level for all team members. |
| `units` | `string` | | `"repo.code,repo.issues,repo.pulls"` | Comma-separated repository feature units the team has access to. Valid values: `repo.code`, `repo.issues`, `repo.ext_issues`, `repo.wiki`, `repo.pulls`, `repo.releases`, `repo.projects`, `repo.ext_wiki`. Do not include `repo.actions` or `repo.packages` here — use `enableActions` / `enablePackages` instead. |
| `enableActions` | `boolean` | | `false` | Grant the team access to the Actions (CI/CD) unit. Applied via direct Gitea API call because the Terraform provider does not support this unit. |
| `actionsReadOnly` | `boolean` | | `false` | Force `repo.actions` to `read` permission, overriding the base `permission`. Only effective when `enableActions` is `true`. Triggers a `units_map` PATCH so base units keep their configured level and only `repo.actions` is capped at read. |
| `enablePackages` | `boolean` | | `false` | Grant the team access to the Packages (container/artifact registry) unit. Applied via direct Gitea API call because the Terraform provider does not support this unit. |
| `packagesReadOnly` | `boolean` | | `false` | Force `repo.packages` to `read` permission, overriding the base `permission`. Only effective when `enablePackages` is `true`. Triggers a `units_map` PATCH so base units keep their configured level and only `repo.packages` is capped at read. |
| `includeAllRepositories` | `boolean` | | `false` | Automatically grant access to all org repositories. |
| `canCreateRepos` | `boolean` | | `false` | Allow team members to create repositories in the org. |
| `members` | `string` | | `""` | Comma-separated list of Gitea usernames to add as team members. Membership is reconciled on every sync — removing a name removes the user from the team. Works for both managed and pre-existing users. |
| `credentialsSecretRef` | `object` | yes | | Secret holding the Gitea admin token in tfvars format: `gitea_token = "admin-token"`. |
| `credentialsSecretRef.name` | `string` | yes | | Secret name. |
| `credentialsSecretRef.namespace` | `string` | yes | | Secret namespace. |

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the Terraform apply has completed and written state, derived from the presence of the `team_id` output. **Absent** — not `false` — until the first successful apply, since the patch is skipped while its source path doesn't exist. This is the one package group where the contract differs from the KCL-based ones, which emit an explicit `false`. |
| `ready` | `boolean` | True when the team exists. Equal to `created` by construction (no rollout phase), exposed under the same name as every other package so consumers have one field to poll. Reflects the *last successful* apply — if a later apply fails, `ready` stays `true` while the Workspace's `Synced` condition goes `False`; check `Synced` alongside this field to detect drift. |
| `teamId` | `string` | Gitea's internal numeric team ID. |
| `teamName` | `string` | Resolved team name (echoed from the Terraform output). |

## Example

See [`examples/gitea-team/xr.yaml`](../../../examples/_archives/gitea-team/xr.yaml).
