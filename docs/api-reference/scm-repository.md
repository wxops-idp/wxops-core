# XScmRepository

Creates a repository on Gitea or GitHub, or observes one that already exists, through one of two Terraform provider modules — picked by `vendor` below, which
must agree with the [`XScmConnection`](scm-connection.md) this resource names. `vendor` is repeated here rather than read only from the connection because
Crossplane has to choose which provider's module to run before the connection's Secret is even rendered, and Terraform has no way to make a provider conditional
from inside a module — see [RFC-003](../../development-docs/rfc/003-scm-connections-and-resources.md) for how that was found. A mismatch between this field and
the connection's own `vendor` fails loudly, at the module's `variable "vendor"` validation, rather than letting the wrong provider fail first with a confusing
credentials error.

| | |
|---|---|
| **Group** | `scm.wxops.cloud` |
| **Kind** | `XScmRepository` |
| **Plural** | `xscmrepositories` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/scm/repository/`](../../package/scm/repository) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `scmRef.name` | `string` | yes | — | The `XScmConnection` to act through. Carries the base URL, org and token. There is no per-resource `org` override — the connection is the single source, and a `/` in its `org` is rejected there (nested GitLab groups are not v1, and RFC-005's owner label cannot carry one). |
| `vendor` | `string` (`gitea`, `github`) | yes | — | Must match `scmRef`'s own `vendor` — picks which Terraform provider's module runs, before the connection is even read. See the note above. |
| `repoName` | `string` | yes | — | Repository name. Renaming creates a new repository, so treat it as immutable. |
| `mode` | `string` (`managed`, `observed`) | | `managed` | `managed` creates and owns the repository; `observed` only reads it, through a data source, and never writes or deletes it. |
| `description` | `string` | | `""` | |
| `visibility` | `string` (`private`, `public`) | | `private` | Deliberately the opposite of `XGiteaRepository`, whose default was public. `internal` exists on GitHub Enterprise and GitLab but not Gitea, so it is not offered. |
| `defaultBranch` | `string` | | `main` | On GitHub this needs the branch to exist, so it is applied only when `autoInit` is true. |
| `autoInit` | `boolean` | | `true` | Create an initial commit, so the default branch exists. |
| `hasIssues` | `boolean` | | `true` | |
| `hasWiki` | `boolean` | | `false` | |
| `topics` | `[]string` | | `[]` | **GitHub only.** The `go-gitea/gitea` provider has no topics attribute, so a non-empty list on a Gitea connection fails the apply rather than being silently dropped. |
| `retain` | `boolean` | | `true` | Keep the repository when the XR is deleted — the `Workspace` is orphaned instead of destroyed. `false` deletes the repository with the XR. |

### What `observed` mode does, and does not, do

`observed` reads the repository and never writes it, so a tenant can point at a repository that already exists — on an external host, or on a connection Core
does not manage — and still get its identifiers in `status`. If the repository is absent the apply fails, and the XR stays not-ready with the host's own
message, rather than the repository being created silently.

The creation fields (`description`, `visibility`, `defaultBranch`, `autoInit`, `hasIssues`, `hasWiki`, `topics`) are **not applied** in `observed` mode. They
are not rejected either: they carry XRD defaults, so a schema cannot tell "left unset" from "set to the default". Setting them on an observed repository
therefore has no effect.

### Where the vendors differ

Every difference is absorbed inside the module, which declares both providers and gates each block on the vendor, so the API stays the same shape:

| Concern | Gitea (`go-gitea/gitea`) | GitHub (`integrations/github`) |
|---|---|---|
| Resource / data source | `gitea_repository` / `data.gitea_repo` | `github_repository` / `data.github_repository` |
| Owner | `username` on the resource | `owner` on the provider |
| Visibility | a `private` boolean | a `visibility` string |
| Default branch | an attribute on the repository | a separate `github_branch_default` resource, which needs the branch to exist |
| Topics | **unsupported by the provider** | `topics` |

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the apply has written state, derived from the `repo_id` output. **Absent** — not `false` — until the first successful apply. |
| `ready` | `boolean` | True when the repository exists. Equal to `created` by construction. |
| `exists` | `boolean` | True when the repository is present on the host — the point of `observed` mode; equals `created` in `managed` mode. |
| `repoId` | `string` | The host's own identifier. |
| `cloneUrl` | `string` | HTTPS clone URL. |
| `sshUrl` | `string` | SSH clone URL. |
| `htmlUrl` | `string` | Browser URL. |
| `fullName` | `string` | `<org>/<repo>` as the host reports it. |

## Example

- [`examples/scm-repository/xr.yaml`](../../examples/scm-repository/xr.yaml)
