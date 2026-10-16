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
| `ready` | `boolean` | True when the Secret is in sync. Equal to `created` by construction. It does **not** say the token works — `org` below does, for an org connection. |
| `synced` | `boolean` | False while a composed resource's last apply failed — its `Ready` condition can stay True from the earlier success. Absent until the first reconcile. See [Sync state](status-contract.md#sync-state--every-package). |
| `syncMessage` | `string` | The failing resource and the provider's own message, truncated to ~400 characters; present only while something is not synced. |
| `secretName` | `string` | The Secret consumers read, published so the name is discoverable rather than conventional. |
| `org` | `object` | `exists`, `name`, `id`, `url` — the org as the host reports it. See [What the connection reports](#what-the-connection-reports-about-the-org). |
| `repositories` | `object` | `count` and `names` of the org's repositories. |
| `teams` | `object` | `count` and `names` of the org's teams. |

## What the connection reports about the org

For a connection with an `org`, a second composed resource — an `inspect` OpenTofu `Workspace` — reads the org through the same token and writes a
summary into status. It exists so you can tell, from the connection alone, whether the token reaches the org it is meant to and what is in there before
you provision `XScmRepository` or `XScmTeam` on it. It is **read-only** (data sources only, never a resource) and never touches `ready`: the connection
stays usable when the inspection cannot run.

```yaml
status:
  created: true
  ready: true
  org:
    exists: true
    name: wxops-idp
    id: "7"
    url: https://gitea.example.com/wxops-idp
  repositories:
    count: 2
    names: [payment-api, web]
  teams:
    count: 3
    names: [Developers, Owners, Reviewers]
```

| Behaviour | Detail |
|---|---|
| **Names and counts only** | The detail of one repository or team is on its own `XScmRepository` / `XScmTeam` status. `names` is sorted and capped at 50; `count` is always exact. |
| **No org — user layer** | Nothing is inspected, so `org`, `repositories` and `teams` are absent. |
| **Missing org, or no access** | The read fails, so the fields stay absent — never `exists: false`. Gitea and GitHub both fail the read outright and the two causes are not distinguishable. The reason is on the `inspect` `Workspace`'s conditions. |
| **What the token sees** | A token with less scope returns less, silently: private repositories it cannot read are not counted. Archived repositories are counted. |
| **Gitea teams** | Gitea lists an org's teams only to a token whose user is a **member** of the org; for anyone else the whole inspection fails. |
| **GitHub teams** | Named by slug — the form `XScmTeam` reports as `dexTeam`. |
| **Members** | Deliberately not reported: the Gitea provider has no org-members data source, so there is no uniform field. Members are on `XScmTeam`. |
| **Cost** | One extra `Workspace`, re-read on its poll interval. On GitHub the organisation read also lists members as a side effect of listing repositories. |

The `exists`, `name`, `id` and `url` literals are vendor-neutral; the module that fills them is chosen by `vendor`, as in every `scm-*` package (ADR-004).

## Example

- [`examples/scm-connection/xr.yaml`](../../examples/scm-connection/xr.yaml)
- [`examples/scm-connection/token-secret.md`](../../examples/scm-connection/token-secret.md) — how the operator seeds the token
