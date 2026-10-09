# XScmOAuthApp

Registers an OAuth application on a Git host and publishes its credentials to the secret store, so a login system has one tracked place to read them from.

| | |
|---|---|
| **Group** | `scm.wxops.cloud` |
| **Kind** | `XScmOAuthApp` |
| **Plural** | `xscmoauthapps` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/scm/oauth-app/`](../../package/scm/oauth-app) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

This is the **upstream** half of OAuth: an application registered *at a Git host*, so something can authenticate people against that host — what a Dex connector
needs. The downstream half, a client registered *in* Dex, is [RFC-004](../../development-docs/rfc/004-dex-identity-and-portal-authentication.md). Both end as a
`client_id`/`client_secret` pair in the store, at the same path convention, so a consumer reads one shape either way.

## What each host allows

| Host | `managed` | `observed` |
|---|---|---|
| Gitea | ✅ `gitea_oauth2_app` creates it, and Core owns the secret | ✅ |
| GitHub | ❌ **no creation API** — the module refuses before writing | ✅ the only mode |

An application created on Gitea belongs to the **token's own user** (the provider has no owner field), so use a connection whose token is the identity the
application should belong to.

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `scmRef.name` | `string` | yes | — | The `XScmConnection` to act through. Carries the vendor, base URL and token. |
| `appName` | `string` | yes | — | The application name as it appears on the host. |
| `mode` | `string` (`managed`, `observed`) | | `managed` | `managed` registers it and owns the secret (Gitea only). `observed` publishes an operator-registered pair. |
| `redirectUris` | `[]string` | | `[]` | Accepted redirect URIs. At least one is required for `managed`. |
| `confidential` | `boolean` | | `true` | True for a server-side client that can keep a secret, such as Dex. False for a browser-only client, which must use PKCE. |
| `credentialsSecretRef` | `object` (`name`, `namespace`) | | `{namespace: crossplane-system}` | `observed` only: a Secret whose `credentials` key sets `existing_client_id` and `existing_client_secret` in tfvars form. Ignored for `managed`. |
| `rotation.generation` | `integer` (≥1) | | `1` | `managed` only. Bumping it replaces the application, so the host issues a new secret. |
| `secretStoreRef.name` | `string` | | `vault-platform` | The ESO `ClusterSecretStore` the pair is pushed to. |
| `vaultKey` | `string` | | `oauth/<resource name>/credentials` | Where the pair lands inside that store, without the KV mount prefix. Keyed on the **resource name**, not `appName`, so two hosts can each carry an application called `dex`. A tenant-owned application sets it explicitly — `<team>/oauth/<app>/credentials` — with a tenant-scoped store. |

## Where the credentials go

```
Workspace (OpenTofu)              ── client_secret is a sensitive output ──┐
  gitea_oauth2_app, or the                                                 ▼
  operator's pair passed through        crossplane-system/tf-scm-oauth-app-<uid>
                                                                           │ PushSecret
                                                                           ▼
                                          <store>/<vaultKey>  — one write, one version
```

The secret half never appears in `status`, and never in Git. It is a sensitive OpenTofu output, so `provider-opentofu` routes it to the `Workspace`'s connection
Secret; a `PushSecret` then mirrors that whole Secret to the store as a single write, which is why the store records one version per rotation rather than one
per key. `deletionPolicy: Delete` removes the record when the resource goes.

## Rotation, and what it costs

Bump `rotation.generation`. The application is replaced, the host issues a new secret, and the store's version history keeps the old one — the commit is the
audit trail.

It is **not seamless**: an OAuth application has exactly one secret, so between the new pair landing and every consumer refreshing, logins through that
application fail. Consumers that read the secret at start-up also need a restart. Rotate deliberately, in a quiet window.

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | True once the application exists and its credentials were read, derived from the `client_id` output. **Absent** — not `false` — until the first successful apply. |
| `ready` | `boolean` | True when the credentials are available. Equal to `created` by construction. |
| `clientId` | `string` | The public half of the pair. |
| `vaultKey` | `string` | The key the pair was pushed to inside the store, published so a consumer reads the location rather than reconstructing it. |
| `generation` | `integer` | The rotation generation the published credentials belong to. |

## Example

- [`examples/scm-oauth-app/xr.yaml`](../../examples/scm-oauth-app/xr.yaml) — Gitea, `managed`
- [`examples/scm-oauth-app/github-observed.yaml`](../../examples/scm-oauth-app/github-observed.yaml) — GitHub, `observed`
