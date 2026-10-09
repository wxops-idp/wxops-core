# scm-oauth-app

Registers an OAuth application on a Git host and publishes its credentials to the secret store, so a
login system — Dex, OAuth2 Proxy — has one tracked place to read them from.

This is the **upstream** half of OAuth: an application registered *at a host*, used to authenticate
people against it. The downstream half, a client registered *in* Dex, is RFC-004.

## What each host allows

| Host | `managed` | `observed` |
|---|---|---|
| Gitea | ✅ `gitea_oauth2_app`; Core owns the secret | ✅ |
| GitHub | ❌ no creation API — refused before any write | ✅ the only mode |

An application created on Gitea belongs to the **token's own user**: the provider has no owner
field, so use a connection whose token is the identity the application should belong to.

## Prerequisites

```bash
kubectl apply -k providers/
```

That brings `provider-opentofu` and `provider-kubernetes`. You also need External Secrets Operator, a
`ClusterSecretStore`, and an [`scm-connection`](../connection) whose credential Secret exists.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/scm/scm-oauth-app.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/scm/oauth-app
```

## Usage

```yaml
apiVersion: scm.wxops.cloud/v1alpha1
kind: XScmOAuthApp
metadata:
  name: dex-gitea
  labels:
    wxops.cloud/owner: platform
spec:
  parameters:
    scmRef:
      name: gitea-internal
    mode: managed
    appName: dex
    redirectUris:
      - https://dex.example.com/callback
    confidential: true
    rotation:
      generation: 1
```

For GitHub, register the application by hand, put the pair in a Secret as tfvars, and point at it:

```bash
kubectl create secret generic dex-github-oauth \
  --from-literal=credentials='existing_client_id     = "Iv1.0123456789abcdef"
existing_client_secret = "the-secret-github-issued"' \
  -n crossplane-system
```

```yaml
    mode: observed
    credentialsSecretRef:
      name: dex-github-oauth
      namespace: crossplane-system
```

See [`examples/scm-oauth-app/`](../../../examples/scm-oauth-app).

## Where the credentials go

The client secret is a **sensitive** OpenTofu output, so `provider-opentofu` routes it to the
`Workspace`'s connection Secret (`crossplane-system/tf-scm-oauth-app-<uid>`) and it never reaches the
XR's status. A `PushSecret` then mirrors that whole Secret to the store in one write — one version
per rotation, not one per key.

Default key: `oauth/<resource name>/credentials`, without the KV mount prefix (the store is already
scoped to it). Keyed on the resource name rather than `appName`, so two hosts can each carry an
application called `dex`. A tenant-owned application sets `vaultKey` and a tenant store explicitly.

> **To confirm in a cluster:** whether `provider-opentofu` writes *non-sensitive* outputs
> (`client_id`) into the connection Secret as well as the sensitive one. If it does not, the pushed
> record holds only `client_secret`, and the fix is a second, sensitive `client_id` output. The XR's
> `status.clientId` is unaffected either way — it comes from the Workspace's outputs.

## Rotation, and what it costs

Bump `rotation.generation`. The application is replaced, the host issues a new secret, and the
store's version history keeps the old one.

It is **not seamless**: an OAuth application has exactly one secret, so logins through it fail
between the new pair landing and every consumer refreshing. Consumers that read the secret at
start-up need a restart. Rotate deliberately, in a quiet window.

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `scmRef.name` | string | yes | — | The `XScmConnection` to act through |
| `appName` | string | yes | — | Application name on the host |
| `mode` | string | no | `managed` | `managed` (Gitea) or `observed` (any host) |
| `redirectUris` | []string | no | `[]` | At least one required for `managed` |
| `confidential` | bool | no | `true` | False for a browser-only client (PKCE) |
| `credentialsSecretRef` | object | no | — | `observed` only: the operator's tfvars Secret |
| `rotation.generation` | integer | no | `1` | Bump to rotate; `managed` only |
| `secretStoreRef.name` | string | no | `vault-platform` | Store the pair is pushed to |
| `vaultKey` | string | no | `oauth/<name>/credentials` | Key inside that store |

Full reference: [`docs/api-reference/scm-oauth-app.md`](../../../docs/api-reference/scm-oauth-app.md).

## Build and publish

```bash
crossplane xpkg build \
  -f package/scm/oauth-app \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/scm-oauth-app:release-YYYY-MM-DD \
  -f scm-oauth-app.xpkg
```
