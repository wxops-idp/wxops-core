# oidc-connection

Points at one broker install and publishes the facts every other `oidc-*` record kind needs: which
remote-key prefix to write under, and whether the broker's own config render is currently
succeeding. Dex is the only broker in this release — see
[RFC-004](../../../development-docs/rfc/004-dex-identity-and-portal-authentication.md).

**Core renders no broker config.** The W'xOps [`dexidp` chart](https://github.com/wxops-idp/charts/tree/main/dexidp)
owns that: one `ExternalSecret` scans `<vendor>/connectors`, `<vendor>/clients` and `<vendor>/users`
in OpenBao, merges them with its own `dynamicConfig.base` (issuer, storage, web, expiry — chart
values, never written by Core), and writes the broker's config Secret. Reloader restarts the broker.
This package only **observes** that `ExternalSecret` — `managementPolicies: ["Observe"]` on a
`provider-kubernetes` `Object` — so Core's only window into "did the broker get every record" is its
Ready condition.

## Prerequisites

```bash
kubectl apply -k providers/
```

An install of the `dexidp` chart, in the namespace named by `config.namespace`, pointed at the same
OpenBao mount `secretStoreRef` writes to.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/auth/oidc-connection.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/auth/oidc-connection
```

## Usage

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XOIDCConnection
metadata:
  name: dex
spec:
  parameters:
    issuer: https://idp.wxops.local
    config:
      namespace: dex
```

See [`examples/oidc-connection/xr.yaml`](../../../examples/oidc-connection/xr.yaml).

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `vendor` | string | no | `dex` | The remote-key prefix every `oidc-*` kind writes under |
| `issuer` | string | yes | — | Must equal the chart's own `dynamicConfig.base.issuer` |
| `secretStoreRef.name` | string | no | `vault-platform` | Must read the same OpenBao mount the chart's `SecretStore` reads |
| `config.namespace` | string | yes | — | Namespace the chart installed Dex (and its `ExternalSecret`) into |
| `config.externalSecretName` | string | no | `dex-config` | The chart's `dynamicConfig.secretName` |

## Status

| Field | Description |
|---|---|
| `created` / `ready` | The chart's config `ExternalSecret` reports `Ready: "True"` — **never** that the broker has actually reloaded; Core cannot observe that |
| `message` | The `ExternalSecret`'s own condition message when not ready — a malformed record, a duplicate id, or a missing store, straight from the chart's fail-closed template |
| `callbackUrl` | `<issuer>/callback` — what every `XOIDCConnector`'s upstream OAuth application redirect URI must contain |

Full reference: [`docs/api-reference/oidc-connection.md`](../../../docs/api-reference/oidc-connection.md).

## Build and publish

```bash
crossplane xpkg build \
  -f package/auth/oidc-connection \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/oidc-connection:release-YYYY-MM-DD \
  -f oidc-connection.xpkg
```
