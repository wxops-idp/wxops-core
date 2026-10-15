# oidc-client

A downstream OAuth client — an application that logs in through the broker, such as Pinniped, the
Portal, or oauth2-proxy. `platform` only in this release — see
[RFC-004](../../../development-docs/rfc/004-dex-identity-and-portal-authentication.md)'s open
question on tenant-owned clients.

## Prerequisites

```bash
kubectl apply -k providers/
```

An [`oidc-connection`](../oidc-connection) whose vendor names the remote-key prefix.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/auth/oidc-client.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/auth/oidc-client
```

## Usage

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XOIDCClient
metadata:
  name: portal
spec:
  parameters:
    connectionRef:
      name: dex
    clientId: wxops-portal
    displayName: W'xOps Portal
    redirectUris: [https://portal.example.com/auth/callback]
    public: false
    secret:
      source: generate
```

See [`examples/oidc-client/xr.yaml`](../../../examples/oidc-client/xr.yaml).

## `public` vs confidential

| | `public: true` | `public: false` (default) |
|---|---|---|
| Use for | a browser-only client (SPA, native app) — PKCE instead of a secret | a server-side client that can keep one |
| Record carries | `"public": true`, no `secret` field | `secret`, from `secret.source` |
| `secret.source` | ignored | `generate` (ESO `Password` generator) or `static` (reads `<vendor>/clients-def/<clientId>`, property `secret` — same convention as `oidc-static-password`'s `users-def`) |

## Editing a client vs rotating its secret

| You want to… | Do this |
|---|---|
| Change `redirectUris`, `displayName`, `trustedPeers` | Edit the XR — syncs on its own, no bump. The secret is untouched. |
| **`generate`:** a new secret | Bump `rotation.generation` — the only thing that re-runs the generator. |
| **`static`:** a new secret | Write it to `<vendor>/clients-def/<clientId>` (property `secret`), **then** bump `rotation.generation`. |

In `generate` mode Core writes `{secret, generation}` to `<vendor>/clients-def/<clientId>` itself (ESO1: generator → `clients-def`), and the
record (ESO2, `OnChange`) reads it from there — so an edit never touches the generator, and a bump never settles on the previous secret
(the record's render waits until `clients-def` carries the requested generation). Same split as
[`oidc-static-password`](../oidc-static-password/README.md#how-it-is-built), without the hash.

**Not zero-downtime**: a Dex client has exactly one secret, so the old value stops working the moment the new one is pushed, and every
consumer needs to pick up the new value (its own `ExternalSecret` refresh) before it can authenticate again.

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `connectionRef.name` | string | yes | — | The `XOIDCConnection` this client belongs to |
| `clientId` | string | yes | — | The OAuth client id and this resource's own identifier |
| `displayName` | string | no | `""` | |
| `redirectUris` | []string | yes | — | Accepted redirect URIs |
| `public` | bool | no | `false` | See above |
| `trustedPeers` | []string | no | `[]` | Other client ids allowed to exchange tokens |
| `owner` | string | no | `platform` | `platform` only |
| `secret.source` | string | no | `generate` | `generate` or `static`; ignored when `public`. `static` reads `<vendor>/clients-def/<clientId>` (property `secret`) |
| `secret.generator` | object | no | `{length: 32, digits: 8, symbols: 0}` | `generate` only |
| `rotation.generation` | int | no | `1` | Bump to rotate |

## Status

| Field | Description |
|---|---|
| `created` / `ready` | Standard contract |
| `clientId` | Echoed from spec |
| `vaultKey` | Where the record (not the secret) was pushed |

Full reference: [`docs/api-reference/oidc-client.md`](../../../docs/api-reference/oidc-client.md).

## Build and publish

```bash
crossplane xpkg build \
  -f package/auth/oidc-client \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/oidc-client:release-YYYY-MM-DD \
  -f oidc-client.xpkg
```
