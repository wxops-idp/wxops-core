# XScmConnection

Registers one Git hosting service — its vendor, base URL, default organisation and credential — and renders that credential into the Secret every other
`scm.wxops.cloud` resource reads.

| | |
|---|---|
| **Group** | `scm.wxops.cloud` |
| **Kind** | `XScmConnection` |
| **Plural** | `xscmconnections` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/scm/connection/`](../../package/scm/connection) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

A connection is **platform-owned**: it carries the host token, so tenants reference it by name and never see the credential. That is why it is a distinct
cluster-scoped Kind — plain RBAC can withhold `create` on it while granting the resources that use it.

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `vendor` | `string` (`gitea`, `github`) | yes | — | Which hosting service. Every other resource learns the vendor from the connection, never from its own spec. GitLab is designed in [RFC-003](../../development-docs/rfc/003-scm-connections-and-resources.md) but not served yet. |
| `org` | `string` | yes | — | The default organisation resources are created in. A resource may name a different `org`; its own field wins. No `/` — see the pattern. |
| `baseUrl` | `string` | | `""` | API base URL. Required for a self-hosted Gitea (an in-cluster service URL is fine); leave unset for github.com. |
| `access` | `string` (`write`, `read`) | | `write` | What the token may do. A `read` connection serves `mode: observed` only; a `managed` resource on it fails before any write. |
| `secretStoreRef.name` | `string` | | `vault-platform` | The ESO `ClusterSecretStore` holding the token. |
| `tokenKey` | `string` | | `token` | Property to read at the remote path. |

## The credential

The token is the **bootstrap secret**: an operator writes it to the secret store, and Core never mints it. The composition emits an `ExternalSecret` that
renders it, next to the connection's non-secret fields, into one Secret in tfvars form:

| | |
|---|---|
| **Remote path** | `platform/scm/<name>/credentials`, property `token` (the `remoteKey` omits the KV mount prefix, per the [Vault path convention](../../CLAUDE.md#vault-path-convention)) |
| **Secret** | `crossplane-system/scm-connection-<name>`, key `credentials` |
| **Contents** | `vendor`, `base_url`, `default_org`, `access`, `token` |

A consumer never reads the connection object: it turns `scmRef.name` into that Secret name with the same `Format` transform and hands it to its `Workspace` as
`varFiles`. The vendor therefore reaches the OpenTofu module as a variable, which is why no composition contains vendor logic.

`default_org` is deliberately not called `org`: a consumer's own `org` is a separate variable, so neither source can silently override the other.

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the credential Secret has been rendered. **Absent** — not `false` — until then; treat absent as false. |
| `ready` | `boolean` | True when the Secret is in sync. Equal to `created` by construction. **The token is never verified against the host** — only a resource using the connection can prove it works. |
| `secretName` | `string` | The Secret consumers read, published so the name is discoverable rather than conventional. |

## Example

- [`examples/scm-connection/xr.yaml`](../../examples/scm-connection/xr.yaml)
- [`examples/scm-connection/token-secret.md`](../../examples/scm-connection/token-secret.md) — how the operator seeds the token
