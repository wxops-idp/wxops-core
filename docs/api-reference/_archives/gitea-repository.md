# XGiteaRepository

Manages a Gitea repository owned by an organisation.

| | |
|---|---|
| **Group** | `platform.wxops.cloud` |
| **Kind** | `XGiteaRepository` |
| **Plural** | `xgitearepos` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/platform/archives/gitea-repository/`](../../../package/platform/archives/gitea-repository/) — see [`VERSIONS.yaml`](../../../VERSIONS.yaml) for the current package version |

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `giteaUrl` | `string` | yes | | Base URL of the Gitea instance. |
| `insecure` | `boolean` | | `false` | Skip TLS verification. |
| `orgName` | `string` | yes | | Organization that owns the repository. |
| `repoName` | `string` | yes | | Repository name (immutable after creation). |
| `description` | `string` | | `""` | Repository description. |
| `private` | `boolean` | | `false` | Make the repository private. |
| `autoInit` | `boolean` | | `true` | Initialize the repository with a README. |
| `defaultBranch` | `string` | | `main` | Default branch name. |
| `hasIssues` | `boolean` | | `true` | Enable the issue tracker. |
| `hasWiki` | `boolean` | | `false` | Enable the wiki. |
| `hasProjects` | `boolean` | | `false` | Enable projects. |
| `hasPullRequests` | `boolean` | | `true` | Enable pull requests. |
| `credentialsSecretRef` | `object` | yes | | Secret holding the Gitea admin token in tfvars format: `gitea_token = "admin-token"`. |
| `credentialsSecretRef.name` | `string` | yes | | Secret name. |
| `credentialsSecretRef.namespace` | `string` | yes | | Secret namespace. |

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the Terraform apply has completed and written state, derived from the presence of the `repo_id` output. **Absent** — not `false` — until the first successful apply, since the patch is skipped while its source path doesn't exist. This is the one package group where the contract differs from the KCL-based ones, which emit an explicit `false`. |
| `ready` | `boolean` | True when the repository exists. Equal to `created` by construction (no rollout phase), exposed under the same name as every other package so consumers have one field to poll. Reflects the *last successful* apply — if a later apply fails, `ready` stays `true` while the Workspace's `Synced` condition goes `False`; check `Synced` alongside this field to detect drift. |
| `repoId` | `string` | Gitea's internal numeric repository ID. |
| `cloneUrl` | `string` | HTTPS clone URL for the repository. |
| `sshUrl` | `string` | SSH clone URL for the repository. |
| `htmlUrl` | `string` | Browser URL for the repository. |

## Example

See [`examples/gitea-repository/xr.yaml`](../../../examples/_archives/gitea-repository/xr.yaml).
