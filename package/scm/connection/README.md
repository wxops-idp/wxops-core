# scm-connection

Registers one Git hosting service — vendor, base URL, default organisation and credential — and
renders that credential into the Secret every other `scm.wxops.cloud` resource reads.

A connection is **platform-owned**. It carries the host token, so tenants name it and never see the
credential; being its own Kind is what lets plain RBAC withhold `create` on it. One connection per
host: an in-cluster Gitea, a GitHub org, and later a GitLab instance are three connections.

## Prerequisites

Install these once per cluster:

```bash
kubectl apply -k providers/
```

That brings `provider-kubernetes` and its ProviderConfig. External Secrets Operator and a
`ClusterSecretStore` (named `vault-platform` by default) are platform infrastructure this package
expects to exist — Core does not install them.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/scm/scm-connection.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/scm/connection
```

## The token

The token is the one secret Core cannot create: it is what Core authenticates *with*. An operator
writes it to the store at `platform/scm/<name>/credentials`, property `token`:

```bash
export BAO_ADDR=https://openbao.example.com
bao kv put platform/scm/github-wxops/credentials token="$GITHUB_TOKEN"
```

The composition then renders `crossplane-system/scm-connection-<name>`, key `credentials`, in tfvars
form (`vendor`, `base_url`, `default_org`, `access`, `token`) — which is exactly what a consumer's
`Workspace` reads as `varFiles`. Full detail, including the token scopes each host needs, is in
[`examples/scm-connection/token-secret.md`](../../../examples/scm-connection/token-secret.md).

## What it reports

For a connection with an `org`, a read-only `inspect` Workspace writes the org's summary into status — `org` (`exists`, `name`, `id`, `url`), `repositories`
and `teams` (`count` and `names`, names capped at 50). Names only; the detail is on each `XScmRepository` / `XScmTeam`. It never gates `ready`: a missing
org, a token without access, or (Gitea) a token whose user is not an org member leaves these fields absent and the reason on the Workspace. The user layer
(no `org`) reports nothing. See
[`docs/api-reference/scm-connection.md`](../../../docs/api-reference/scm-connection.md#what-the-connection-reports-about-the-org).

## Usage

```yaml
apiVersion: scm.wxops.cloud/v1alpha1
kind: XScmConnection
metadata:
  name: github-wxops
  labels:
    wxops.cloud/owner: platform
spec:
  parameters:
    vendor: github
    org: wxops
    access: write
```

See [`examples/scm-connection/xr.yaml`](../../../examples/scm-connection/xr.yaml).

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `vendor` | string | yes | — | `gitea` or `github` |
| `org` | string | no | `""` | The organisation every resource acts against. Unset is the user layer: the token's own account, with nothing to inspect. No per-resource override |
| `baseUrl` | string | no | `""` | Required for a self-hosted host; unset for github.com |
| `access` | string | no | `write` | `write`, or `read` to allow observation only |
| `secretStoreRef.name` | string | no | `vault-platform` | ESO `ClusterSecretStore` holding the token |
| `tokenKey` | string | no | `token` | Property to read at the remote path |

Full reference: [`docs/api-reference/scm-connection.md`](../../../docs/api-reference/scm-connection.md).

## Status

| Field | Description |
|---|---|
| `created` | True once the credential Secret has been rendered from the store. |
| `ready` | True when the credential Secret is in sync: `created` and `synced`. |
| `secretName` | The Secret every consumer's Workspace reads as `varFiles`. |
| `org` | What the token can see of the connection's `org`, read-only. |
| `repositories` | The org's repositories as this token sees them (archived ones included). |
| `teams` | The org's teams as this token sees them. |
| `synced` / `syncMessage` | `synced` is false while a composed resource's last apply failed (its `Ready` can stay True from the earlier success); `syncMessage` is the provider's message, truncated. Absent until the first reconcile |

Full reference: [`docs/api-reference/scm-connection.md`](../../../docs/api-reference/scm-connection.md#status).

## Build and publish

```bash
crossplane xpkg build \
  -f package/scm/connection \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/scm-connection:release-YYYY-MM-DD \
  -f scm-connection.xpkg
```
