# XGiteaOrg

Manages a Gitea organisation with visibility and metadata.

| | |
|---|---|
| **Group** | `platform.wxops.cloud` |
| **Kind** | `XGiteaOrg` |
| **Plural** | `xgiteaorgs` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/platform/archives/gitea-org/`](../../../package/platform/archives/gitea-org/) — see [`VERSIONS.yaml`](../../../VERSIONS.yaml) for the current package version |

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `giteaUrl` | `string` | yes | | Base URL of the Gitea instance (e.g. `https://gitea.example.com`). |
| `insecure` | `boolean` | | `false` | Skip TLS verification. True only for local/dev instances. |
| `orgName` | `string` | yes | | Gitea organization login name (immutable after creation). |
| `fullName` | `string` | | `""` | Display name shown in the Gitea UI. |
| `description` | `string` | | `""` | Organization description. |
| `website` | `string` | | `""` | Organization website URL. |
| `location` | `string` | | `""` | Organization location. |
| `visibility` | `string` (`public`, `limited`, `private`) | | `public` | Organization visibility. |
| `repoAdminChangeTeamAccess` | `boolean` | | `false` | Allow repository admins to add and remove teams from repositories, even if they are not organization admins. |
| `credentialsSecretRef` | `object` | yes | | Secret holding the Gitea admin token in tfvars format: `gitea_token = "admin-token"`. |
| `credentialsSecretRef.name` | `string` | yes | | Secret name. |
| `credentialsSecretRef.namespace` | `string` | yes | | Secret namespace. |

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the Terraform apply has completed and written state, derived from the presence of the `org_id` output. **Absent** — not `false` — until the first successful apply, since the patch is skipped while its source path doesn't exist. This is the one package group where the contract differs from the KCL-based ones, which emit an explicit `false`. |
| `ready` | `boolean` | True when the organisation exists. Equal to `created` by construction (no rollout phase), exposed under the same name as every other package so consumers have one field to poll. Reflects the *last successful* apply — if a later apply fails, `ready` stays `true` while the Workspace's `Synced` condition goes `False`; check `Synced` alongside this field to detect drift. |
| `orgId` | `string` | Gitea's internal numeric organisation ID. |
| `orgName` | `string` | Resolved organisation name (echoed from the Terraform output). |

## Example

See [`examples/gitea-org/xr.yaml`](../../../examples/_archives/gitea-org/xr.yaml).
