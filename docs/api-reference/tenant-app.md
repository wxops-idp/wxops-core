# XTenantApp

Tenant application scaffold — provisions a `Deployment` + `Service` + optional `IngressRoute` + optional `ServiceAccount` for an application workload, following
the `app.kubernetes.io/*` label conventions used by the Kubewekend and Bitnami Helm "common" libraries (`app.kubernetes.io/name`, `app.kubernetes.io/instance`,
`app.kubernetes.io/managed-by: crossplane`).

This XR deliberately stops at the application workload. Vault-backed secrets (`ExternalSecret`/`PushSecret`) and databases
([`XTenantDatabase`](tenant-database.md)) are platform-level concerns wired up separately — point `envFrom` at the Secret(s) they produce.

| | |
|---|---|
| **Group** | `platform.wxops.cloud` |
| **Kind** | `XTenantApp` |
| **Plural** | `xtenantapps` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/platform/tenant-app/`](../../package/platform/tenant-app) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |
| **Composition function** | [`function-kcl`](https://github.com/crossplane-contrib/function-kcl) — see [`kcl/tenant-app/main.k`](../../kcl/tenant-app/main.k) |

## `spec.parameters`

### Core

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `appName` | `string` | yes | | Application name. Used as the name of the `Deployment`/`Service`/`IngressRoute` and as the value of the `app.kubernetes.io/name` and `app.kubernetes.io/instance` labels. |
| `namespace` | `string` | yes | | Target namespace for all resources created by this XR. |
| `cluster` | `string` | | `"default"` | Name of the provider-kubernetes `ProviderConfig` to apply composed resources through. `default` is the local (hub) cluster — the only one wired up today, so leaving this unset is behaviour-neutral. See [multi-cluster.md](../../development-docs/core-ideas/multi-cluster.md). |
| `environment` | `string` | | `"dev"` | One of `dev`, `staging`, `prod`. Applied as the `wxops.cloud/environment` label on created resources — purely metadata for dashboards, cost reports, and Kyverno generate-policies. Pairs with an ArgoCD ApplicationSet matrix generator (apps × environments). |
| `appFlavor` | `string` | | `"webapp"` | One of `webapp`, `ai`, `ai-webapp`, `geo-webapp`, `search-webapp`. Applied as the `wxops.cloud/app-flavor` label on created resources — purely metadata for platform-level automation (e.g. a separate `XTenantDatabase` claim choosing `pgvector`/`postgis` extensions, or Kyverno generate-policies) to key off. Does not affect any resource composed by this XR. |
| `templateId` | `string` | | | Backstage/IDP software-template identifier this app was scaffolded from. Applied as the `wxops.cloud/template-id` annotation on all composed resources — catalog-linking metadata only. |
| `repository.url` | `string` | | | URL of the application's source repository (e.g. a Gitea repo created or imported by the platform/portal — `tenant-app` doesn't manage repositories). Applied as the `wxops.cloud/repo-url` annotation on all composed resources. |
| `image` | `string` | yes | | Container image reference (`repository:tag`). e.g. `ghcr.io/org/app:1.0.0`. Use this single-string form so Kustomize image-updater can target it directly. |
| `imagePullPolicy` | `string` | | `"IfNotPresent"` | One of `Always`, `IfNotPresent`, `Never`. |
| `imagePullSecrets` | `array<string>` | | `[]` | Names of existing Secrets (type `kubernetes.io/dockerconfigjson`) for pulling from private registries. Added to `spec.imagePullSecrets` on both the main Deployment and darlane. The Secrets must already exist in the target namespace — this XR does not create them. |
| `replicas` | `integer` | | `1` | |
| `containerPort` | `integer` | | `8080` | |
| `terminationGracePeriodSeconds` | `integer` | | `30` | Seconds to wait for graceful shutdown after SIGTERM before SIGKILL. Increase for apps with long-running requests, connection draining, or batch processing. |
| `resources` | `object` | | | Passed through verbatim to the container's `resources` field (`requests`/`limits` × `cpu`/`memory`). |
| `env` | `array<{name, value}>` | | `[]` | Plain (non-secret) environment variables. |
| `envFrom` | `array<{secretRef\|configMapRef: {name}}>` | | `[]` | Additional `envFrom` sources, merged after the `secretsFrom.{app,database}`-managed `secretRef`s (if enabled). |
| `podAnnotations` | `object<string, string>` | | `{}` | Annotations applied to the pod template (e.g. for Prometheus scraping). |
| `deploymentAnnotations` | `object<string, string>` | | `{}` | Extra annotations merged onto the main `Deployment`'s `metadata.annotations`, alongside `wxops.cloud/template-id`, `wxops.cloud/repo-url`, and (if `reloader.enabled`) `reloader.stakater.com/auto`. |
| `labels` | `object<string, string>` | | `{}` | Extra labels merged onto all composed resources (`Deployment`, `darlane`, `Service`, `IngressRoute`, `ServiceAccount`). The standard `app.kubernetes.io/*` and `wxops.cloud/*` labels always take precedence — they cannot be overridden, since selectors depend on them. |
| `command` | `array<string>` | — | image default | Overrides the container `ENTRYPOINT`. Omit to use the image's built-in entrypoint. Set independently of `args` — Kubernetes applies the same override semantics as a pod spec `command` field. |
| `args` | `array<string>` | — | image default | Overrides the container `CMD`. Can be set without `command` (passes args to the image's own entrypoint). Combined with `command`, both are required to fully replace entrypoint + args. |

### `rolloutStrategy`

`Deployment.spec.strategy` — how Pods are replaced on update, relevant when `replicas > 1`.

| Field | Type | Default | Description |
|---|---|---|---|
| `rolloutStrategy.type` | `string` | `"RollingUpdate"` | One of `RollingUpdate`, `Recreate`. |
| `rolloutStrategy.rollingUpdate.maxSurge` | `string\|integer` | `"25%"` | Only used when `type` is `RollingUpdate`. |
| `rolloutStrategy.rollingUpdate.maxUnavailable` | `string\|integer` | `"25%"` | Only used when `type` is `RollingUpdate`. |

### `serviceAccount`

| Field | Type | Default | Description |
|---|---|---|---|
| `serviceAccount.create` | `boolean` | `false` | If true, compose a new `ServiceAccount` in the target namespace. |
| `serviceAccount.name` | `string` | `appName` (when `create: true`) | ServiceAccount name. When `create: false`, must reference an existing SA in the target namespace. If the entire `serviceAccount` section is omitted, the namespace default SA is used. |
| `serviceAccount.annotations` | `object<string, string>` | `{}` | Annotations on the created SA (ignored when `create: false`). Use for workload identity bindings — e.g. `eks.amazonaws.com/role-arn` (IRSA), `iam.gke.io/gcp-service-account` (GCP WI). |

### `securityContext`

Pod-level and container-level security settings. Pod-level fields apply to all containers; container-level fields apply to the main app container (and darlane
container if enabled).

| Field | Type | Default | Description |
|---|---|---|---|
| `securityContext.runAsNonRoot` | `boolean` | | Pod-level. Require all containers to run as non-root. Many clusters enforce this via admission policies. |
| `securityContext.runAsUser` | `integer` | | Pod-level. UID to run all containers as. |
| `securityContext.runAsGroup` | `integer` | | Pod-level. Primary GID for all containers. |
| `securityContext.fsGroup` | `integer` | | Pod-level. GID applied to all mounted volumes. |
| `securityContext.readOnlyRootFilesystem` | `boolean` | | Container-level. Mount the root filesystem as read-only. |
| `securityContext.allowPrivilegeEscalation` | `boolean` | | Container-level. Whether the process can gain more privileges than its parent. Set to `false` for hardened workloads. |
| `securityContext.capabilities.drop` | `array<string>` | `[]` | Container-level. Capabilities to drop. Use `["ALL"]` to drop all (recommended baseline). |
| `securityContext.capabilities.add` | `array<string>` | `[]` | Container-level. Capabilities to add back (e.g. `["NET_BIND_SERVICE"]`). |

### `secretsFrom`

Toggles for `envFrom.secretRef` entries pointing at Secrets provisioned out-of-band by the platform/GitOps. This XR only wires the reference by name — it does
not provision or wait for the Secret to exist (the Deployment will fail to start until it's created).

| Field | Type | Default | Description |
|---|---|---|---|
| `secretsFrom.app.enabled` | `boolean` | `false` | If true, adds a `secretRef` to `secretsFrom.app.secretName` — e.g. the Secret a platform-managed `ExternalSecret`/`PushSecret` writes app secrets from Vault into. |
| `secretsFrom.app.secretName` | `string` | `"{appName}-env"` | |
| `secretsFrom.database.enabled` | `boolean` | `false` | If true, adds a `secretRef` to `secretsFrom.database.secretName` — e.g. a platform-provisioned [`XTenantDatabase`](tenant-database.md)'s connection-creds Secret. |
| `secretsFrom.database.secretName` | `string` | `"{appName}-db-creds"` | |

### `reloader` ([Stakater Reloader](https://github.com/stakater/Reloader))

| Field | Type | Default | Description |
|---|---|---|---|
| `reloader.enabled` | `boolean` | `false` | If true, adds `reloader.stakater.com/auto: "true"` to the `Deployment`'s annotations, triggering a rolling restart via the Reloader controller when referenced ConfigMaps/Secrets change. Requires Reloader installed in-cluster. |

### `volumes` — storage

Mount volumes into the main app container. Volume source is determined by which discriminator field is set — supply exactly one per entry:

| Discriminator | Volume source |
|---|---|
| `claimName` | `PersistentVolumeClaim` — reference existing, or create one (`create: true`) |
| `configMapName` | `ConfigMap` — mounts the named ConfigMap |
| `secretName` | `Secret` — mounts the named Secret |

For ConfigMap and Secret volumes, `items[]` allows key-to-path projections: only the listed keys are mounted, at the given relative paths inside `mountPath`.

| Field | Type | Default | Description |
|---|---|---|---|
| `volumes[].name` | `string` | required | Volume name (used in pod spec and `volumeMount`). |
| `volumes[].mountPath` | `string` | required | Absolute mount path inside the container. |
| `volumes[].subPath` | `string` | — | Optional subpath within the volume. |
| `volumes[].readOnly` | `boolean` | `false` | |
| `volumes[].claimName` | `string` | — | PVC name — reference existing, or name the PVC to create. Mutually exclusive with `configMapName`/`secretName`. |
| `volumes[].create` | `boolean` | `false` | If true, compose a new `PersistentVolumeClaim` named `claimName`. |
| `volumes[].storageClass` | `string` | — | StorageClass for the new PVC. Required when `create: true`. |
| `volumes[].size` | `string` | — | PVC capacity (e.g. `"10Gi"`). Required when `create: true`. |
| `volumes[].accessModes` | `array<string>` | `["ReadWriteOnce"]` | PVC access modes. Only used when `create: true`. |
| `volumes[].configMapName` | `string` | — | Name of an existing ConfigMap to mount. Mutually exclusive with `claimName`/`secretName`. |
| `volumes[].secretName` | `string` | — | Name of an existing Secret to mount. Mutually exclusive with `claimName`/`configMapName`. |
| `volumes[].items[]` | `array` | — | Key-to-path projections for configMap/secret volumes. Each entry: `{key, path}`. |
| `volumes[].items[].key` | `string` | required | Key in the ConfigMap or Secret. |
| `volumes[].items[].path` | `string` | required | Relative path inside `mountPath` where this key is mounted. |

### `darlane` (debug "twin" Deployment)

If enabled, a second `<appName>-dev` Deployment is created alongside the main one — same `image`/`env`/`envFrom`/secrets, scaled to `0` by default and with **no
`Service`/`IngressRoute` of its own** (zero external exposure). Scale it up on-demand, sync code with `wxops darlane sync`, or route real traffic via
`trafficWeight` for A/B testing and feature flags. Use `mirrord` CLI directly against the darlane pod for local development with real cluster env and secrets.
See [darlane.md](../../development-docs/core-ideas/darlane.md) for the full developer guide.

#### Core

| Field | Type | Default | Description |
|---|---|---|---|
| `darlane.enabled` | `boolean` | `false` | |
| `darlane.replicas` | `integer` | `0` | Scale to `1` on-demand to start the debug pod. |
| `darlane.image` | `string` | main `image` | Optional image override (`repository:tag`). |
| `darlane.command` | `array<string>` | `["sleep", "infinity"]` | Container command. Keeps the pod alive for `kubectl exec`/port-forward. |
| `darlane.args` | `array<string>` | — | Container args override (parallel to `darlane.command`). |
| `darlane.containerPort` | `integer` | main `containerPort` | Port the darlane process listens on. Override when the dev server starts on a different port than the main app (e.g. hot-reload on `3000` vs. production on `8080`). Used as `targetPort` in the darlane Service when `trafficWeight > 0`. |
| `darlane.env` | `array<{name,value}>` | `[]` | Extra env vars layered on top of main app env. darlane values win on key collision. |
| `darlane.resources` | `object` | — | Resource requests/limits for the darlane pod, independent of the main app. Omit to inherit main app resources. |
| `darlane.securityContext` | `object` | — | Security context overrides (`runAsUser`, `runAsGroup`, `readOnlyRootFilesystem`, etc). Applied on top of main app `securityContext`. `readOnlyRootFilesystem` defaults to `false` for darlane so `apt`/`pip` installs work without a custom image. |
| `darlane.productionOverride` | `boolean` | `false` | Required when `environment: prod` to enable darlane. Double opt-in — visible in XR diffs and PRs. |
| `darlane.ttl` | `string` | — | Adds `wxops.cloud/darlane-ttl` annotation to the dev Deployment (e.g. `"4h"`). Enforcement is a separate Kyverno policy. |


#### Traffic routing

Route a slice of real `IngressRoute` traffic to the darlane pod for A/B testing, feature flags, or explicit developer opt-in. Three independent controls compose
freely — see [Combining traffic modes](../../development-docs/core-ideas/darlane.md#combining-traffic-modes) in the Darlane guide for the full interaction table
and Traefik rule details.

| Field | Type | Default | Description |
|---|---|---|---|
| `darlane.trafficWeight` | `integer` | `0` | Percentage of real traffic routed to the darlane pod (`0` = debug only, `1–99` = A/B split, `100` = full canary). Emits a `ClusterIP` Service and a Traefik `TraefikService` weighted split. Zero-downtime — the `IngressRoute` Object is updated in-place. Requires `ingress.enabled: true`. |
| `darlane.stickySession.enabled` | `boolean` | `false` | Pin browser clients to the same backend for their session lifetime via a Traefik cookie. Requires `trafficWeight > 0`. Without this, a single user may hit both variants per-request. Browser only — API clients that don't forward cookies remain per-request. |
| `darlane.stickySession.cookieName` | `string` | `"darlane-ab"` | Session cookie name Traefik sets. Override if multiple apps share the same domain. |
| `darlane.stickySession.secure` | `boolean` | `true` | Set the `Secure` flag on the cookie (HTTPS only). |
| `darlane.stickySession.sameSite` | `string` | `"lax"` | `lax` · `strict` · `none` (requires `secure: true`). |
| `darlane.headerRouting.enabled` | `boolean` | `false` | Add a higher-priority `IngressRoute` rule that pins requests carrying a specific header directly to the darlane pod — bypasses `trafficWeight` and cookie assignment entirely. Works with or without `trafficWeight`. Requires `ingress.enabled: true`. |
| `darlane.headerRouting.header` | `string` | — | HTTP header name to match (e.g. `X-Target-Env`). Case-sensitive. Required when `enabled: true`. |
| `darlane.headerRouting.value` | `string` | — | Header value to match (e.g. `darlane`). Case-sensitive. Required when `enabled: true`. |
| `darlane.telemetryPort` | `integer` | — | Emits a `ClusterIP` Service named `{appName}-darlane-telemetry` on this port for OTEL/Prometheus scraping. Common values: `4317` (OTEL gRPC), `4318` (OTEL HTTP), `9090` (Prometheus). |

#### `darlane.volumes` — volumes

Mount volumes into the darlane pod. Same discriminator pattern as main app `volumes[]` — set exactly one of `claimName`, `configMapName`, or `secretName`.
Unlike main app volumes, PVC creation (`create: true`) is not supported here — reference existing claims only. Useful for persistent caches (pip/npm/go module
downloads), shared datasets, config overlays, or Secret mounts that survive pod restarts.

| Field | Type | Default | Description |
|---|---|---|---|
| `darlane.volumes[].name` | `string` | required | Volume name. |
| `darlane.volumes[].mountPath` | `string` | required | Absolute mount path inside the container. |
| `darlane.volumes[].subPath` | `string` | — | Optional subpath within the volume. |
| `darlane.volumes[].readOnly` | `boolean` | `false` | |
| `darlane.volumes[].claimName` | `string` | — | Name of an existing PVC in the target namespace. |
| `darlane.volumes[].configMapName` | `string` | — | Name of an existing ConfigMap to mount. |
| `darlane.volumes[].secretName` | `string` | — | Name of an existing Secret to mount. |
| `darlane.volumes[].items[]` | `array` | — | Key-to-path projections for configMap/secret volumes. Each entry: `{key, path}`. |

#### `darlane.serviceAccount` — pod identity for portal/CI access

When `create: true`, the composition emits a dedicated `ServiceAccount` named `{appName}-darlane` (or the value of `name`). Use the SA token in the portal or CI
pipeline to authenticate against the cluster — combine with workload identity annotations (IRSA, GCP WI) for credential-less access to cloud APIs. When `create:
false` and `name` is set, the darlane pod runs as that existing SA.

| Field | Type | Default | Description |
|---|---|---|---|
| `darlane.serviceAccount.create` | `boolean` | `false` | If true, emit a `ServiceAccount` named `{appName}-darlane` (or `name`) in the target namespace. |
| `darlane.serviceAccount.name` | `string` | `{appName}-darlane` (when `create: true`) | SA name. When `create: false`, must reference an existing SA in the target namespace. |
| `darlane.serviceAccount.annotations` | `object<string,string>` | `{}` | Annotations on the created SA (ignored when `create: false`). Use for workload identity bindings (`eks.amazonaws.com/role-arn`, `iam.gke.io/gcp-service-account`). |

### `service`

| Field | Type | Default | Description |
|---|---|---|---|
| `service.enabled` | `boolean` | `true` | |
| `service.type` | `string` | `"ClusterIP"` | One of `ClusterIP`, `NodePort`, `LoadBalancer`. |
| `service.port` | `integer` | `80` | Service port. `targetPort` is always `containerPort`. |

### `probes`

HTTP GET liveness/readiness/startup probes against `containerPort`. `liveness`/`readiness` default to **enabled**, mirroring `service.enabled` — apps without a
`Service` (e.g. background workers) default to no probes but can opt in explicitly.

| Field | Type | Default | Description |
|---|---|---|---|
| `probes.liveness.enabled` | `boolean` | `service.enabled` | |
| `probes.liveness.path` | `string` | `"/healthz"` | |
| `probes.liveness.port` | `integer` | `containerPort` | |
| `probes.liveness.initialDelaySeconds` | `integer` | `10` | |
| `probes.liveness.periodSeconds` | `integer` | `10` | |
| `probes.liveness.timeoutSeconds` | `integer` | `1` | |
| `probes.liveness.failureThreshold` | `integer` | `3` | |
| `probes.readiness.enabled` | `boolean` | `service.enabled` | |
| `probes.readiness.path` | `string` | `"/readyz"` | |
| `probes.readiness.port` | `integer` | `containerPort` | |
| `probes.readiness.initialDelaySeconds` | `integer` | `5` | |
| `probes.readiness.periodSeconds` | `integer` | `10` | |
| `probes.readiness.timeoutSeconds` | `integer` | `1` | |
| `probes.readiness.failureThreshold` | `integer` | `3` | |
| `probes.startup.enabled` | `boolean` | `false` | If enabled, gates liveness/readiness until the first successful check — useful for slow-starting apps. |
| `probes.startup.path` | `string` | `"/healthz"` | |
| `probes.startup.port` | `integer` | `containerPort` | |
| `probes.startup.periodSeconds` | `integer` | `10` | |
| `probes.startup.failureThreshold` | `integer` | `30` | |

### `ingress`

`ingress.enabled: true` always emits a Traefik `IngressRoute` (`traefik.io/v1alpha1`) — never a standard Kubernetes `Ingress`. This allows
`darlane.trafficWeight` to switch between a plain `Service` backend and a `TraefikService` weighted split as a live in-place field update, with zero downtime.

> **Migration note:** existing clusters that have a `networking.k8s.io/v1 Ingress` managed by the old composition will experience a one-time gap when upgrading
> — the old `Ingress` is orphaned and the new `IngressRoute` is created. After that, all subsequent `trafficWeight` changes are zero-downtime.

| Field | Type | Default | Description |
|---|---|---|---|
| `ingress.enabled` | `boolean` | `false` | Emits a Traefik `IngressRoute`. |
| `ingress.className` | `string` | `"traefik"` | Not used by `IngressRoute` — kept for schema compatibility. |
| `ingress.host` | `string` | | **Required if `ingress.enabled`** (validated by the Composition, not the XRD schema). Rendered as `Host(\`{host}\`)` in the route match expression. |
| `ingress.path` | `string` | `"/"` | Rendered as `PathPrefix(\`{path}\`)` in the route match expression. |
| `ingress.pathType` | `string` | `"Prefix"` | Not used by `IngressRoute` — kept for schema compatibility. |
| `ingress.annotations` | `object<string, string>` | `{}` | Merged onto the `IngressRoute` metadata annotations. |
| `ingress.tls.enabled` | `boolean` | `false` | Sets `entryPoints: [websecure]` and `spec.tls.secretName` on the `IngressRoute`. |
| `ingress.tls.secretName` | `string` | `"{appName}-tls"` | Name of the TLS Secret. When `clusterIssuer` is set, cert-manager writes into this name. Otherwise the Secret must already exist. |
| `ingress.tls.clusterIssuer` | `string` | | If set (and `tls.enabled`), the composition emits a cert-manager `Certificate` CR referencing this `ClusterIssuer`. cert-manager auto-provisions the TLS Secret into `tls.secretName`; the `IngressRoute` references the same name. Requires [cert-manager](https://cert-manager.io/) and the named `ClusterIssuer` in-cluster. Without this field, `tls.secretName` must already exist (e.g. a pre-existing wildcard Secret). |
| `ingress.auth.enabled` | `boolean` | `false` | If true, adds `auth-errors` and `forward-auth-redirect` Traefik `Middleware` references to `spec.routes[].middlewares` on the `IngressRoute` — SSO via oauth2-proxy's ForwardAuth, redirecting unauthenticated users (`401`) to the login page. See [SSO via oauth2-proxy](#sso-via-oauth2-proxy) below. |

#### TLS auto-provisioning (cert-manager)

When `ingress.tls.clusterIssuer` is set, the composition emits a `cert-manager.io/v1 Certificate` CR alongside the `IngressRoute`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: "{appName}-tls"        # same as tls.secretName
  namespace: "{namespace}"
spec:
  secretName: "{appName}-tls"
  issuerRef:
    name: letsencrypt-prod      # value of tls.clusterIssuer
    kind: ClusterIssuer
  dnsNames:
    - payment-api.example.com   # value of ingress.host
```

cert-manager requests the certificate via the named `ClusterIssuer` and writes the resulting TLS key + chain into `tls.secretName`. The `IngressRoute`'s
`spec.tls.secretName` references the same Secret — no manual certificate management required.

**Prerequisites:** cert-manager installed in-cluster (`kubectl get crd certificates.cert-manager.io`), and the named `ClusterIssuer` exists and is ready
(`kubectl get clusterissuer letsencrypt-prod`).

**RBAC:** provider-kubernetes requires `cert-manager.io/certificates` in its ClusterRole — this is included in `providers/rbac-provider-kubernetes.yaml`.

#### SSO via oauth2-proxy

When `ingress.auth.enabled: true`, Traefik runs the `auth-errors` and `forward-auth-redirect` middlewares before routing to this app — they call oauth2-proxy's
ForwardAuth endpoint and redirect unauthenticated users (`401`) to the login page. References are added to `spec.routes[].middlewares` on the `IngressRoute`
(not via annotation, as `IngressRoute` uses native Middleware CRD references).

Both `Middleware` CRDs are expected to exist in the `kube-system` namespace. Requires Traefik configured with
`--providers.kubernetescrd.allowCrossNamespace=true`. `tenant-app` does not provision or manage these `Middleware` CRDs.

### `monitoring`

Emits a real Prometheus Operator CRD. **Do not use `prometheus.io/*` pod annotations** — they are a convention read only by a `kubernetes_sd_config` job with
matching relabel rules, and kube-prometheus-stack's `additionalScrapeConfigs` is empty here, so they scrape nothing. Full rationale in
[observability.md](../../development-docs/core-ideas/observability.md).

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `boolean` | `false` | Master toggle. No monitor is emitted when false. |
| `kind` | `string` | `auto` | `auto` \| `ServiceMonitor` \| `PodMonitor`. `auto` resolves on `service.enabled`. |
| `port` | `integer` | `containerPort` | Port to scrape. No schema default — falls back in KCL. |
| `path` | `string` | `/metrics` | HTTP path exposing the metrics. |
| `interval` | `string` | `30s` | Scrape interval. |
| `scrapeTimeout` | `string` | `10s` | Per-scrape timeout. Must be `<=` `interval`. |
| `sampleLimit` | `integer` | `5000` | Max samples per scrape. Prometheus runs with no global limits, so this is the only guardrail. |
| `honorLabels` | `boolean` | `false` | Target labels win over Prometheus-attached labels. |
| `metricRelabelings` | `array` | `[]` | `metric_relabel_configs` applied at ingest — the escape hatch for a high-cardinality series. |

**ServiceMonitor vs PodMonitor.** A `ServiceMonitor` only scrapes endpoints the Service considers `Ready`, so a pod failing its readiness probe drops out of the
endpoint list and **stops being scraped — exactly when its metrics matter most**. A `PodMonitor` keeps scraping it, and is the only option when
`service.enabled: false`. Setting `kind: ServiceMonitor` without a Service is a hard error rather than a silent no-op.

The emitted monitor carries `release: kube-prometheus-stack`, which the Operator filters on (`serviceMonitorSelectorNilUsesHelmValues: true`), and selects on
`app.kubernetes.io/component: app` so the Darlane twin's metrics never merge into the app's own series.

> Requires `monitoring.coreos.com` in `providers/rbac-provider-kubernetes.yaml`. Without it every emitted monitor fails `forbidden` at reconcile.

## Developer access and RBAC

**This composition emits no RBAC.** There is no `Role`, `ClusterRole`, `RoleBinding`, or `ClusterRoleBinding`, and provider-kubernetes is deliberately not
granted permission to create them.

| Concern | Owner | Mechanism |
|---|---|---|
| Create the ServiceAccount | **core** | `darlane.serviceAccount.create: true` |
| Publish the SA name | **core** | `status.darlane.serviceAccountName` |
| Define `Role` / `ClusterRole` | GitOps repo | plain manifests, reviewed as RBAC |
| Bind role → ServiceAccount | GitOps repo | `RoleBinding` / `ClusterRoleBinding` |

A composition that mints RBAC turns provider-kubernetes into a privilege-escalation vector — Kubernetes' escalation check only blocks granting permissions the
creator lacks, and that ServiceAccount already holds broad grants. RBAC also deserves human review on a diff, which it gets in a GitOps repo.

Read the ServiceAccount name from the XR, then bind to it:

```yaml
# authored in the GitOps repo, not composed by this XR
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payment-api-darlane-debug
  namespace: rocket-team-production
subjects:
  - kind: User
    name: alice@example.com          # or a Group from your IdP
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: payment-api-darlane          # defined alongside this binding
  apiGroup: rbac.authorization.k8s.io
```

> **`pods/exec` cannot be name-restricted by RBAC.** A grant that allows a shell into the Darlane pod allows a shell into *every* pod in that namespace,
> including the production Deployment. No authoring style changes this — size tenant namespaces accordingly.

## Channels

Every release labels its Composition `channel: stable`; `make install-dev` overrides it to `channel: nightly` via Kustomize. Track a channel with
`spec.crossplane`, a sibling of `spec.parameters`, not a field inside it:

```yaml
spec:
  parameters: {...}
  crossplane:
    compositionRevisionSelector:
      matchLabels:
        channel: stable          # or nightly
    compositionUpdatePolicy: Automatic
```

Full mechanism, the `Manual`-pin alternative, and why: [Channels](../../development-docs/development/releasing.md#channels).

## `status`

| Field | Type | Description |
|---|---|---|
| `created` | `boolean` | All core resources (Deployment, Service, IngressRoute) observed at least once. |
| `ready` | `boolean` | All core resources report Ready. **Scoped to the workload** — see below. |
| `dependenciesReady` | `boolean` | Non-workload composed resources are Ready. Today: the cert-manager `Certificate`. |
| `url` | `string` | Derived from `ingress.host`. Empty when ingress is disabled. |
| `namespace` | `string` | Namespace the app is deployed to. |
| `image` | `string` | Container image currently configured. |
| `darlane` | `object` | Twin state. Absent entirely when `darlane.enabled` is false. |
| `darlane.ready` | `boolean` | The `<appName>-darlane` Deployment reports Ready. |
| `darlane.replicas` | `integer` | **Observed** ready replicas, not the desired count from spec. |
| `darlane.trafficMode` | `string` | `none` \| `weighted` \| `header` \| `both`. |
| `darlane.ttl` | `string` | The configured `darlane.ttl` duration, echoed as-is. |
| `darlane.serviceAccountName` | `string` | The RBAC binding target — see above. |

**Why `ready` and `dependenciesReady` are separate.** `ready` covers only the core workload, so a consumer can render "app is up, TLS still issuing" instead of
a blanket "not ready" for an app that is already serving. Check both before declaring the app healthy.

`darlane.ttl` is a duration (`"4h"`), not an expiry timestamp — the composition has no clock. Combine it with the Deployment's `creationTimestamp` to compute
one.

This XR does **not** compose an `XTenantDatabase`; `secretsFrom.database` only wires an existing Secret in by name and is never waited on, so database
provisioning is not reflected in either field.

> Poll these fields rather than the native `type: Ready` condition, which is unreliable on Crossplane v2.3 with function-kcl v0.12.1.

## Vault secrets & databases

`tenant-app` does not provision Vault-backed secrets or databases itself. Environment variables sourced from Vault (`ExternalSecret`/`PushSecret`) and tenant
databases ([`XTenantDatabase`](tenant-database.md)) are provisioned separately at the platform level. Reference the resulting Kubernetes `Secret`(s) via
[`secretsFrom`](#secretsfrom) (simple enable + default naming convention):

```yaml
secretsFrom:
  app:
    enabled: true        # adds envFrom.secretRef: payment-api-env
  database:
    enabled: true        # adds envFrom.secretRef: payment-api-db-creds
```

or via `envFrom` directly for any other Secret/ConfigMap name.

> **Go-live ordering contract**: `tenant-app` does not wait for or validate that `secretsFrom.{app,database}.secretName` exist — it only adds
> `envFrom.secretRef` entries by name. The referenced Secret(s) **must be created before (or alongside) this XR**, or the Deployment's Pods will fail to start
> (`CreateContainerConfigError: secret "..." not found`). This is the platform/GitOps's responsibility — when enabling `secretsFrom`, make sure the
> corresponding `ExternalSecret`/`PushSecret`/ `XTenantDatabase` is applied first.

`appFlavor` remains purely a label (`wxops.cloud/app-flavor`) for portal filtering and platform automation — e.g. the portal/platform layer can use it to pick
`pgvector`/`postgis`/etc. extensions when provisioning a database for this app, without `tenant-app` itself knowing anything about databases.

## Golden Path Contract

`tenant-app` defaults `probes.liveness` and `probes.readiness` to **enabled** whenever `service.enabled` is true (the default), targeting:

- `GET /healthz` — liveness
- `GET /readyz` — readiness

This is a *contract*, not something the Composition can enforce: if your application doesn't expose these two HTTP endpoints on `containerPort`, the Deployment
will fail to become ready (`readinessProbe` failures) or be restarted in a loop (`livenessProbe` failures).

Two ways to satisfy the contract:

1. **Implement `/healthz` and `/readyz`** in your app (recommended — most
   frameworks provide this for free, e.g. Spring Boot Actuator
   `/actuator/health/liveness|readiness`, FastAPI/Express health-check
   middleware). This is expected to be baked into the language/framework
   scaffolds used to bootstrap new services (Backstage software templates),
   so a service created from a golden-path template already satisfies this
   out of the box.
2. **Override the paths** via `probes.liveness.path` /
   `probes.readiness.path` (or `probes.<liveness|readiness>.enabled: false`
   to disable a probe entirely) if your app uses different conventions or
   doesn't serve HTTP at all (e.g. `service.enabled: false` workers default
   to no probes).

`probes.startup` remains opt-in (`enabled: false` by default) for slow-starting apps that need extra grace before liveness/readiness probes begin counting
failures.

## Example

See [`examples/tenant-app/xr.yaml`](../../examples/tenant-app/xr.yaml).

## See also

- [Darlane — In-Cluster Developer Environment](../../development-docs/core-ideas/darlane.md) —
  exec, file sync, traffic mirroring, A/B testing, AI agent workflow,
  and SRE Agent with the darlane debug twin.
