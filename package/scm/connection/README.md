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
| `org` | string | yes | — | Default organisation; a resource may override it |
| `baseUrl` | string | no | `""` | Required for a self-hosted host; unset for github.com |
| `access` | string | no | `write` | `write`, or `read` to allow observation only |
| `secretStoreRef.name` | string | no | `vault-platform` | ESO `ClusterSecretStore` holding the token |
| `tokenKey` | string | no | `token` | Property to read at the remote path |

Full reference: [`docs/api-reference/scm-connection.md`](../../../docs/api-reference/scm-connection.md).

## Build and publish

```bash
crossplane xpkg build \
  -f package/scm/connection \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/scm-connection:release-YYYY-MM-DD \
  -f scm-connection.xpkg
```
