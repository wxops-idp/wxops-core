# tenant-app

Crossplane Configuration package that provisions a tenant application
scaffold — `Deployment` + `Service` + optional `Ingress` + optional
`ServiceAccount` (+ optional debug `darlane` twin), following
`app.kubernetes.io/*` label conventions.

This package deliberately stops at the application workload: Vault-backed
secrets and databases are platform-level concerns, wired in via
`secretsFrom.{app,database}` (Secrets provisioned out-of-band by GitOps or a
[`tenant-database`](../tenant-database) claim). Composition logic is written
in KCL — see [`kcl/tenant-app/main.k`](../../../kcl/tenant-app/main.k).

## Prerequisites

Install once per cluster (`make providers`):

```bash
kubectl apply -f providers/provider-kubernetes.yaml
kubectl apply -f providers/rbac-provider-kubernetes.yaml
kubectl apply -f providers/runtimeconfig-provider-kubernetes.yaml
kubectl apply -f providers/providerconfig-kubernetes.yaml
kubectl apply -f providers/function-kcl.yaml
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

See [`examples/tenant-app/xr.yaml`](../../../examples/tenant-app/xr.yaml) for the
full set of optional fields (`serviceAccount`, `securityContext`,
`terminationGracePeriodSeconds`, `imagePullSecrets`, `secretsFrom`,
`rolloutStrategy`, `darlane`, `probes`, `ingress.tls`/`ingress.auth`,
`labels`/`deploymentAnnotations`, `templateId`/`repository.url`), and
[`docs/api-reference/tenant-app.md`](../../../docs/api-reference/tenant-app.md) for the complete
`spec.parameters` reference and the Golden Path Contract.

## Relation to other packages

```
XGiteaRepository (rocket-team / payment-api)   ← source code
XTenantDatabase (rocket-team / payment-db)     ← secretsFrom.database
└── XTenantApp (payment-api)                   ← secretsFrom.{app,database}
```

For the full scaffold-to-running-app golden path (pick a template, create or
import a repo, push the skeleton, deploy), see
[`docs/user-guide/app-onboarding.md`](../../../docs/user-guide/app-onboarding.md).
