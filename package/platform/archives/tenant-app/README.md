# tenant-app

> Being replaced by [`app`](../../../tenant/app) (`XApp`, ADR-005, RFC-010): the same scaffold, created in the team's own namespace. This kind stays served until every XR has moved — see [migrating to the new kinds](../../../../docs/user-guide/migrating-to-new-kinds.md#xtenantapp--xapp).

Crossplane Configuration package that provisions a tenant application
scaffold — `Deployment` + `Service` + optional `Ingress` + optional
`ServiceAccount` (+ optional debug `darlane` twin), following
`app.kubernetes.io/*` label conventions.

This package deliberately stops at the application workload: Vault-backed
secrets and databases are platform-level concerns, wired in via
`secretsFrom.{app,database}` (Secrets provisioned out-of-band by GitOps or a
[`tenant-database`](../tenant-database) claim). Composition logic is written
in KCL — see [`kcl/tenant-app/main.k`](../../../../kcl/_archives/tenant-app/main.k).

## Prerequisites

Install once per cluster (`make providers`):

```bash
kubectl apply -f providers/packages/provider-kubernetes.yaml
kubectl apply -f providers/rbac/provider-kubernetes.yaml
kubectl apply -f providers/packages/runtimeconfig-provider-kubernetes.yaml
kubectl apply -f providers/config/providerconfig-kubernetes.yaml
kubectl apply -f providers/functions/function-kcl.yaml
```

Optional, depending on which fields are enabled:

- [cert-manager](https://cert-manager.io/) + a `ClusterIssuer` — for
  `ingress.tls.clusterIssuer`.
- [Stakater Reloader](https://github.com/stakater/Reloader) — for
  `reloader.enabled`.
- oauth2-proxy + the `auth-errors`/`forward-auth-redirect` Traefik
  `Middleware` CRDs in `kube-system`, and Traefik configured with
  `--providers.kubernetescrd.allowCrossNamespace=true` — for
  `ingress.auth.enabled`.

## Install

**Production** (registry):

```bash
kubectl apply -f package/install/platform/tenant-app.yaml
```

**Development** (direct apply):

```bash
kubectl apply -k package/platform/tenant-app/
```

## Usage

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XTenantApp
metadata:
  name: rocket-team-payment-api
spec:
  parameters:
    appName: payment-api
    namespace: rocket-team-production
    image: ghcr.io/rocket-team/payment-api:1.4.0
    imagePullSecrets:
      - my-registry-creds
    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/payment-api
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    ingress:
      enabled: true
      host: payment-api.rocket-team.example.com
```

See [`examples/platform/tenant-app/xr.yaml`](../../../../examples/_archives/tenant-app/xr.yaml) for the
full set of optional fields (`serviceAccount`, `securityContext`,
`terminationGracePeriodSeconds`, `imagePullSecrets`, `secretsFrom`,
`rolloutStrategy`, `darlane`, `probes`, `ingress.tls`/`ingress.auth`,
`labels`/`deploymentAnnotations`, `templateId`/`repository.url`), and
[`docs/api-reference/platform/tenant-app.md`](../../../../docs/api-reference/_archives/tenant-app.md) for the complete
`spec.parameters` reference and the Golden Path Contract.

## Status

| Field | Description |
|---|---|
| `created` | True when all expected cluster resources (Deployment, Service, Ingress) have been observed in the cluster at least once. |
| `ready` | True when all core cluster resources (Deployment, Service, Ingress) report Ready. |
| `dependenciesReady` | True when composed resources that do not gate the workload itself, but do gate the app being usable end-to-end, report Ready. |
| `darlane` | Observed state of the Darlane debug twin. |
| `url` | Application URL derived from ingress.host (https:// when tls.enabled, http:// otherwise). |
| `namespace` | Kubernetes namespace where the app is deployed. |
| `image` | Container image currently configured for the deployment. |
| `synced` / `syncMessage` | `synced` is false while a composed resource's last apply failed (its `Ready` can stay True from the earlier success); `syncMessage` is the provider's message, truncated. Absent until the first reconcile |

Full reference: [`docs/api-reference/platform/tenant-app.md`](../../../../docs/api-reference/_archives/tenant-app.md#status).

## Relation to other packages

```
XGiteaRepository (rocket-team / payment-api)   ← source code
XTenantDatabase (rocket-team / payment-db)     ← secretsFrom.database
└── XTenantApp (payment-api)                   ← secretsFrom.{app,database}
```

For the full scaffold-to-running-app golden path (pick a template, create or
import a repo, push the skeleton, deploy), see
[`docs/user-guide/app-onboarding.md`](../../../../docs/user-guide/app-onboarding.md).
