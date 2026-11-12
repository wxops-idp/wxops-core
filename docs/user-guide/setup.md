# Setup — installing W'xOps Core on a cluster (Detailing)

> Install the shared providers once, seed a connection token, install the packages, then apply a first resource. For what each resource does once it exists, see
> the [API reference](../api-reference/README.md).

**Table of Contents**
- [Setup — installing W'xOps Core on a cluster (Detailing)](#setup--installing-wxops-core-on-a-cluster-detailing)
  - [Prerequisites](#prerequisites)
    - [CLI (Command Line Interface)](#cli-command-line-interface)
    - [Platform \& Kubernetes Controller](#platform--kubernetes-controller)
  - [Platform dependencies, per package](#platform-dependencies-per-package)
  - [0 - Install W'xOps Ecosystem Prerequisites \& Bootstrap](#0---install-wxops-ecosystem-prerequisites--bootstrap)
  - [1 - Install providers once per cluster](#1---install-providers-once-per-cluster)
  - [2 - Seed a connection token](#2---seed-a-connection-token)
  - [3 - Install packages](#3---install-packages)
  - [(Optional) Kyverno-required guard — before any platform policy](#optional-kyverno-required-guard--before-any-platform-policy)
  - [4 - Apply a first resource](#4---apply-a-first-resource)
  - [5 - Make `Pinniped` available to use `Impersonate Proxy`](#5---make-pinniped-available-to-use-impersonate-proxy)
  - [Uninstalling](#uninstalling)
    - [Removing one category](#removing-one-category)
  - [Next](#next)

---

## Prerequisites

![W'xOps IDP Landscape](../../images/w'xops-idp-landscape.png)

### CLI (Command Line Interface)

- The [`crossplane` CLI](https://docs.crossplane.io/latest/cli/), v2.3 or later (**NOTE:** Should match between `crossplane` Client and Server)
- `kubectl` pointed at a Kubernetes cluster, v1.34 or later (v1.36 recommended) — step 0 installs Crossplane on it
- [`helm`](https://helm.sh/docs/intro/install/) v3, for every install in step 0
- [`jq`](https://jqlang.org/download/), read by step 5
- The [`pinniped` CLI](https://pinniped.dev/docs/howto/install-cli/), to get a kubeconfig in step 5
- `pre-commit`, only if you will change this repository (see the [development guide](../../development-docs/development/README.md))
- [`bao-cli`](https://openbao.org/docs/install/) to interact and bootstrap system secret variables as Secret Management, e.g: [OpenBao](https://openbao.org/) or [Hashicorp Vault](https://developer.hashicorp.com/vault)

### Platform & Kubernetes Controller

- Crossplane and Controller: **(Supported)** [`Crossplane Runtime`](https://www.crossplane.io/), [`Crossplane Functions & Providers`](https://docs.crossplane.io/v2.4/learn/community-extension-projects/) (Explore more at [Upbound Marketplace](https://marketplace.upbound.io/))
- SCM: **(Supported)** `Github`, or [`Gitea (Self-hosted)`](https://about.gitea.com/). **(Future)** `GitLab`, [`GitLab CE (Self-hosted)`](https://docs.gitlab.com/topics/offline/quick_start_guide/)
- Identity (Authentication): **(Supported)** [`DexiDP`](https://dexidp.io/) (Explore and install with [Charts](https://github.com/wxops-idp/charts/tree/main/dexidp)), [`Pinniped`](https://pinniped.dev/) (Explore and install with [Charts](https://github.com/wxops-idp/charts/tree/main/pinniped))
- Secrets Management: **(Supported)** `OpenBao` (Recommended) or `Hashicorp Vault`
- Supply Chain Utilities: **(Supported)** [`CertManager`](https://cert-manager.io/), [`Stakater Reloader`](https://github.com/stakater/reloader), and [`External Secrets Operator`](https://external-secrets.io/latest/)
- Policies Management (Policies as Code): **(Supported)** [`Kyverno`](https://kyverno.io/docs/introduction/) v1.19 or later, in
  [high availability](https://kyverno.io/docs/guides/high-availability/) — see the [optional Kyverno-required guard](#optional-kyverno-required-guard--before-any-platform-policy)
- DataStorage: **(Simple)** [`rancher-local-path-provisioner`](https://github.com/rancher/local-path-provisioner) or **(Complete)** [`longhorn`](https://github.com/longhorn/longhorn)
- Database Management (Created and Migration): **(Supported)** [`CNPG`](https://cloudnative-pg.io/)
- **(Option)** Gitops: **(Supported)** [`ArgoCD`](https://argo-cd.readthedocs.io/en/stable/)
- **(Option)** Observability: **(Supported)** `Grafana-CE Ecosystem (Grafana, Prometheus, Loki, Tempo, Pyroscope, and Alloy)`

## Platform dependencies, per package

W'xOps Core composes resources that other operators reconcile. Install what the packages you use need:

| Package | Needs in the cluster |
|---|---|
| `scm-connection`, `scm-repository`, `scm-oauth-app` | A reachable Gitea or GitHub host and an admin/API token, written to the secret store (step 2) |
| `database-cluster` | CloudNativePG operator; External Secrets Operator with the `ClusterSecretStore` `vault-platform` (step 0); provider-sql (installed by step 1) |
| `database` | Everything `database-cluster` needs, plus the `ClusterSecretStore` `vault-tenant` (step 0), a namespace labelled `wxops.cloud/owner`, and an `XDatabaseCluster` labelled for discovery; see [Required discovery labels](../api-reference/tenant/database.md#required-discovery-labels) |
| `app` | A namespace labelled `wxops.cloud/owner` and the hub's `ClusterProviderConfig` (step 1); `vault-tenant` for the Secrets it reads with `secretsFrom`; then only what the XR enables: cert-manager for `ingress.tls`, Traefik CRDs for `ingress`, Prometheus Operator CRDs for `monitoring`, Stakater Reloader for `reloader` |
| Darlane TTL enforcement **(Not Enforced)** | ~~Kyverno, plus `providers/policies/darlane-ttl.yaml`~~ |

## 0 - Install W'xOps Ecosystem Prerequisites & Bootstrap

In first step, we will use `helm` to install setup prerequisites of Kubernetes cluster, and bootstrap certificate to help you deployed system tools with TLS, and easier to setup secure Kubernetes authentication with **Impersonate Proxy**

```bash
# Helm apply Rancher local-path-provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl annotate storageclasses.storage.k8s.io local-path storageclass.kubernetes.io/is-default-class=true

# Helm apply for deploy OpenBao
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
helm upgrade --install -n openbao openbao openbao/openbao --create-namespace --version 0.30.2 \
    --set server.dev.enabled=true \
    --set server.dev.devRootToken="root" \
    --set injector.enabled=false

# Helm apply for deploy ESO (External Secrets Operator)
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install -n external-secrets external-secrets external-secrets/external-secrets --create-namespace --version 1.2.1 \
    --set installCRDs=true

# Helm apply for Crossplane Runtime
helm repo add crossplane https://charts.crossplane.io/stable
helm repo update
helm upgrade --install -n crossplane-system crossplane crossplane/crossplane --create-namespace --version 2.3.1

# Helm apply for cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version v1.19.2 \
  --set crds.enabled=true

# Helm apply for reloader
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update
helm upgrade --install reloader stakater/reloader \
  --namespace kube-extensions --create-namespace --version 2.2.7 \
  --set fullnameOverride="reloader"

# Helm Install kyverno controller
#
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno --namespace kyverno --create-namespace --version 3.9.2 \
 --reuse-values \
 --set reportsController.resources.limits.memory=256Mi

# Helm Install CNPG to deploy PostgreSQL Cluster
#
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm upgrade --install cnpg --namespace cnpg-system --create-namespace cnpg/cloudnative-pg --version 0.29.1

# Get the LoadBalancer IP for DexiDP issuer
until LB_IP=$(kubectl get svc -A -o jsonpath='{.items[?(@.status.loadBalancer.ingress)].status.loadBalancer.ingress[0].ip}' | grep -E '^[0-9.]+$'); do echo "Waiting for LB IP..." && sleep 5; done; echo "Found: $LB_IP";

# Setup the self-ca with cert-manager for DexiDP and create the ingressRoute by traefik with cert and service for dexidp
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-wxops-idp
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wxops-idp-selfsigned-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: wxops-idp-selfsigned-ca
  secretName: wxops-idp-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-wxops-idp
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: wxops-idp-ca-issuer
spec:
  ca:
    secretName: wxops-idp-ca-secret
EOF
```

> [!NOTE]
> A few things this block assumes — check them before the next step:
>
> - **Kyverno runs as a single replica here**, which is fine to try W'xOps out. Every `XPolicy` runs in `Deny` with `failurePolicy: Fail`, so on a cluster people
>   use, run it in high availability — `admissionController.replicas: 3` and the other values in
>   [the Kyverno-required guard section](#optional-kyverno-required-guard--before-any-platform-policy). The chart turns its PodDisruptionBudget on by itself
>   once replicas are above 1.
> - **Each controller must be ready before its resources are applied.** The `ClusterIssuer`s above need cert-manager's webhook to be serving: add `--wait` to
>   the `helm` commands, or re-run the `kubectl apply` if it answers `failed calling webhook`.
> - **Traefik and a LoadBalancer IP are expected.** The `IngressRoute`s, and the `LB_IP` lookup (the first LoadBalancer Service that has an IP), assume
>   Traefik is the cluster's ingress — k3s ships it. With another ingress controller, set `LB_IP` yourself and translate the `IngressRoute`s.
> - **CNPG takes its volumes from the default StorageClass** — W'xOps names none. The block above makes local-path the default; with Longhorn, mark its
>   StorageClass default instead, and only one.

You need to set up the two `ClusterSecretStore`s the packages write through — `vault-platform` (OpenBao's `platform/` mount) and `vault-tenant` (its `tenants/`
mount) — with the default credentials of the OpenBao you created, `BAO_ADDR` and `BAO_TOKEN`.

> [!NOTE]
> we will replace this bootstrap soon when the GitOps available and using [`provider-vault`](https://marketplace.upbound.io/providers/upbound/provider-vault/v4.1.0) with supporting various APIs to help you interact with secret management easily.

> [!NOTE]
> **Reach OpenBao through a port-forward.** The install above gives it no ingress, on purpose — `bao` talks to it from your machine:
>
> ```bash
> kubectl -n openbao port-forward svc/openbao 8200:8200 &
> export BAO_ADDR=http://127.0.0.1:8200
> export BAO_TOKEN=root          # the dev root token set by the Helm install above
> ```
>
> Exposing OpenBao through an ingress is your decision. It puts the secret store on the network, so give it TLS and real authentication first — not the
> dev-mode root token.

```bash
# Bootstrap the openbao
# Enable the kubernetes
bao auth enable -path kubernetes/ kubernetes

# update the kubernetes configuration
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# enable kv method and put the scm for connection
bao secrets enable -path platform/ -version=2 kv
bao secrets enable -path tenants/ -version=2 kv

# create role for secretStore for Kubernetes auth method
bao policy write eso-platform-rw - <<EOF
path "platform/data/*" {
capabilities = ["read", "list", "create", "update", "delete"]
}
path "platform/metadata/*" {
capabilities = ["read", "list", "create", "update", "delete"]
}
EOF
bao write auth/kubernetes/role/eso-platform-rw \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-platform-rw \
  ttl=1m

bao policy write eso-tenant-rw - <<EOF
path "tenants/data/*" {
capabilities = ["read", "list", "create", "update", "delete"]
}
path "tenants/metadata/*" {
capabilities = ["read", "list", "create", "update", "delete"]
}
EOF
bao write auth/kubernetes/role/eso-tenant-rw \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-tenant-rw \
  ttl=1m

# create secretStore
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-platform
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc.cluster.local:8200"
      # The path within Vault where the secrets are stored. This is used as a prefix for all secret lookups.
      path: "platform"
      # Version is the Vault KV secret engine version.
      # This can be either "v1" or "v2", defaults to "v2"
      version: "v2"
      # The authentication method to authenticate to Vault, e.g: AppRole, Kubernetes, ...
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-platform-rw"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-tenant
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc.cluster.local:8200"
      # The path within Vault where the secrets are stored. This is used as a prefix for all secret lookups.
      path: "tenants"
      # Version is the Vault KV secret engine version.
      # This can be either "v1" or "v2", defaults to "v2"
      version: "v2"
      # The authentication method to authenticate to Vault, e.g: AppRole, Kubernetes, ...
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-tenant-rw"
EOF
```

After that, you will setup the core Authentication of W'xOps IDP to support OIDC/OAuth2 for both Kubernetes and Ecosystem with `DexiDP` and `Pinniped`

```bash
# Get the LoadBalancer IP for DexiDP issuer
until LB_IP=$(kubectl get svc -A -o jsonpath='{.items[?(@.status.loadBalancer.ingress)].status.loadBalancer.ingress[0].ip}' | grep -E '^[0-9.]+$'); do echo "Waiting for LB IP..." && sleep 5; done; echo "Found: $LB_IP";

# Helm apply for DexiDP
helm repo add wxops https://charts.wxops.cloud
helm repo update
helm upgrade --install -n wxops-platform dex wxops/dexidp --create-namespace --version 0.1.1 \
    --set externalSecretDefaults.refreshInterval=1m \
    --set externalSecretDefaults.secretStoreRef.name=vault-platform \
    --set externalSecretDefaults.secretStoreRef.kind=ClusterSecretStore \
    --set dynamicConfig.base.issuer=https://dex.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io

# create certificate for TLS DexiDP with self-signed CA
cat<<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dex
  namespace: wxops-platform
spec:
  secretName: dex-tls-secret
  dnsNames:
    - "dex.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io"
  issuerRef:
    name: wxops-idp-ca-issuer
    kind: ClusterIssuer
EOF

cat<<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: dex
  namespace: wxops-platform
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  entryPoints:
    - websecure
  routes:
  - kind: Rule
    match: Host(\`dex.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io\`)
    services:
    - kind: Service
      name: dex
      port: 5556
  tls:
    secretName: dex-tls-secret
EOF
```

> [!NOTE]
> By default, DexiDP will run with `enablePasswordDB: true` to allow you authentication by password, and also support default method for let dexIDP run, before any Client and Connectors setup via dex configuration, which managed and easy to setup with [`auth.wxops.cloud`](../api-reference/auth/) group API. To explore more about the role of DexiDP inside W'xOps IDP at [Link](https://github.com/wxops-idp/charts/blob/main/dexidp/README.md)

Now install `pinniped` for `impersonate-proxy` feature in Kubernetes Cluster

```bash
# setup pinniped for hub, include both supervisor and concierge
helm upgrade --install pinniped wxops/pinniped --namespace wxops-platform --create-namespace --version 0.2.0 \
 -f https://raw.githubusercontent.com/wxops-idp/charts/refs/heads/main/pinniped/values.yaml \
 --set global.domain="wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io" \
 --set global.certManager.enabled=true \
 --set global.certManager.issuerRef.name="wxops-idp-ca-issuer" \
 --set global.certManager.issuerRef.kind="ClusterIssuer" \
 --set global.ingress.enabled=true \
 --set concierge.credentialIssuer.impersonationProxy.mode=enabled \
 --set concierge.credentialIssuer.impersonationProxy.externalEndpoint="hub-cp.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io" \
 --set concierge.tls.certManager.certificate.secretName="concierge-tls-secret" \
 --set concierge.tls.certManager.certificate.dnsNames=\["hub-cp.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io"\] \
 --set concierge.ingress.hostPrefix="hub-cp" \
 --set concierge.ingress.annotations."kubernetes\.io/ingress\.class"="traefik" \
 --set concierge.jwtAuthenticator.create=true \
 --set concierge.jwtAuthenticator.name="dex-jwt-authenticator" \
 --set concierge.jwtAuthenticator.issuer="https://supervisor.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io" \
 --set concierge.jwtAuthenticator.audience="hub-cluster" \
 --set concierge.jwtAuthenticator.certificateAuthorityDataSource.kind="Secret" \
 --set concierge.jwtAuthenticator.certificateAuthorityDataSource.name="concierge-tls-secret" \
 --set concierge.jwtAuthenticator.certificateAuthorityDataSource.key="ca.crt" \
 --set supervisor.tls.certManager.certificate.secretName="supervisor-tls-secret" \
 --set supervisor.tls.certManager.certificate.dnsNames=\["supervisor.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io"\] \
 --set supervisor.ingress.hostPrefix="supervisor" \
 --set supervisor.ingress.annotations."kubernetes\.io/ingress\.class"="traefik" \
 --set supervisor.ingress.traefik.tlsPassthrough=true \
 --set supervisor.ingress.traefik.tlsSecretName="supervisor-tls-secret" \
 --set supervisor.federationDomain.create=true \
 --set supervisor.federationDomain.issuer="https://supervisor.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io" \
 --set supervisor.identityProviders.dex.create=false
```

Recently, `pinniped` can run healthy but can't work permanently inside Kubernetes, before [`XOIDCClient`](../api-reference/auth/oidc-client.md) is set up and wired up with `DexiDP`. To generate a `kubeconfig` with `pinniped`, you should download and install its [CLI](https://pinniped.dev/docs/howto/install-cli/). Anyway, if you want to delve deeper into W'xOps Pinniped Helm Chart, there are more information for answering your question at [Link](https://github.com/wxops-idp/charts/blob/main/pinniped/README.md)

## 1 - Install providers once per cluster

```bash
make providers
```

It runs four stages in order and waits where it must — each is also a target of its own:

```bash
make providers-functions   # function-patch-and-transform, function-kcl, function-extra-resources — waits until Healthy
make providers-packages    # provider-kubernetes, provider-sql, provider-opentofu, provider-vault — waits until Installed and Healthy
make providers-rbac        # provider-kubernetes's grants, and the persona and Platform API roles
make providers-config      # the ProviderConfigs, once each provider's API is served
```

A ProviderConfig cannot exist before its provider's CRDs are served, which is why it comes last. Override the wait with `WAIT_TIMEOUT=600s` if image pulls
are slow. A GitOps engine needs none of this: `providers/kustomization.yaml` is the all-at-once view, and Argo CD or Flux retry until the CRDs appear.

The ProviderConfigs are `provider-kubernetes`'s `ProviderConfig` and its namespaced twin — the `ClusterProviderConfig` `default` that `XApp` and `XDatabase`
compose through — and the OpenTofu and Vault ones. The Vault `ProviderConfig` reads a `vault-credentials` Secret in `crossplane-system` that this guide does not
create; no package uses `provider-vault` yet ([RFC-008](../../development-docs/rfc/008-built-in-tools-identity-and-catalog.md)), so it can wait.
**`provider-terraform` is archived**
(`providers/archive/`) and not applied: the only packages that ran on it (`gitea-*`) are themselves archived — see
[`providers/archive/README.md`](../../providers/archive/README.md).

> [!NOTE]
> **`make providers` is required before `make install`.**
> - **Dependency names.** Crossplane's `dependsOn` in `crossplane.yaml` can auto-install missing
>   dependencies, but under long names derived from the OCI path (for example
>   `crossplane-contrib-function-kcl` instead of `function-kcl`). Compositions reference the short
>   names set by `providers/*.yaml`, so auto-installed dependencies are not found.
> - **Provider configuration.** Providers like `provider-kubernetes` also need a `RuntimeConfig`, RBAC
>   and a `ProviderConfig`, which `dependsOn` cannot provide.
>
> `dependsOn` is a **version-constraint safety net**, not an installer.

## 2 - Seed a connection token

Every `scm-*` resource reads its vendor/token through one `XScmConnection`; the host token is the one secret Core cannot create itself. Write it to the secret
store `XScmConnection` renders from (`vault-platform` by default), property `token`, at `platform/scm/<connection-name>/credentials`:

```bash
export BAO_ADDR=http://127.0.0.1:8200           # the port-forward from step 0, or your OpenBao's address
bao login                                       # however your operators authenticate — step 0's dev install uses BAO_TOKEN=root
bao kv put platform/scm/github-wxops-idp/credentials token="your-admin-or-pat-token"
```

See [Seeding a connection's token](../../examples/scm/connection/token-secret.md) for the full walkthrough, including what scope the token needs per vendor.

## 3 - Install packages

**Production** — pulls the Configuration packages pinned in `package/install/` from the OCI registry:

```bash
make install
```

**Development** — applies XRDs and Compositions straight from this checkout, with no registry:

```bash
make install-dev
```

`make install-dev` is for a disposable development cluster only. Against a cluster that already runs the packages, it overwrites package-managed XRDs and
Compositions and skips every release gate. Everything it applies carries `channel: nightly` (production packages ship `channel: stable`) — see
[Channels](../../development-docs/development/releasing.md#channels) for how an XR opts into either.

## (Optional) Kyverno-required guard — before any platform policy

> [!NOTE]
> **Optional — not required, and not shipped by W'xOps.** No package installs it or depends on it, and W'xOps does not test it. Apply it only if you want
> the extra assurance described below; every platform policy works without it.

Platform policies (`XPolicy`) run inside Kyverno, in `Deny` with `failurePolicy: Fail`. While Kyverno serves, a write that
breaks a rule is refused, and a write Kyverno cannot check is refused too. One case slips through: when Kyverno shuts down **gracefully** — scaled to zero,
uninstalled, or its last admission replica stopped — it **deletes its own webhook configurations**, and until it serves again people's writes pass
unchecked (about two minutes in the [failure spike](../../development-docs/rfc/009-scm-personas.md#spike-and-acceptance-results-2026-11-04)).

**The first answer is Kyverno in high availability**, following Kyverno's [High Availability guide](https://kyverno.io/docs/guides/high-availability/) —
at least three admission-controller replicas, plus a PodDisruptionBudget so a drain never takes the last one:

```yaml
# Kyverno Helm values
admissionController:
  replicas: 3          # the minimum the HA guide supports; every platform policy runs here
backgroundController:
  replicas: 2
cleanupController:
  replicas: 2
reportsController:
  replicas: 0          # PolicyReports are not supported by W'xOps yet, so `mode: Audit` is not either
```

**The guard covers what HA cannot:** a deliberate scale-down or uninstall. It is one native `ValidatingAdmissionPolicy` — run by the API server itself, not
by Kyverno — whose parameter is Kyverno's own webhook configuration. While that configuration exists, the guard allows everything. When it disappears,
`parameterNotFoundAction: Deny` refuses **people's** writes until Kyverno is back: they pause instead of passing unchecked. Controllers, Crossplane, Argo
CD, Helm and cluster-admin are never matched — the same `scm-user` rule the platform policies use — so Kyverno can always be reinstalled.

Apply it **after Kyverno is running and before the first platform policy**:

```yaml
# Optional: pause SCM users' writes while Kyverno's webhooks are gone. Not shipped or required by W'xOps.
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: wxops-kyverno-required
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: admissionregistration.k8s.io/v1
    kind: ValidatingWebhookConfiguration
  matchConstraints:
    resourceRules:
      - apiGroups: ["*"]
        apiVersions: ["*"]
        operations: ["CREATE", "UPDATE", "DELETE", "CONNECT"]
        resources: ["*", "*/*"]
  matchConditions:
    # SCM users only — the same rule as the platform policies; list every org in your XPolicy `scmOrgs`
    - name: scm-user
      expression: "!request.userInfo.username.startsWith('system:') && request.userInfo.groups.exists(g, g.startsWith('<org>:'))"
    # never on access reviews, Pinniped's login APIs, events or leases — the platform policies' exclusions
    - name: not-excluded
      expression: >-
        !(request.resource.group in ['authentication.k8s.io', 'authorization.k8s.io', 'login.concierge.pinniped.dev', 'identity.concierge.pinniped.dev'])
        && !(request.resource.resource in ['events', 'leases'])
  validations:
    - expression: "true"
      message: "Kyverno is unavailable: writes by people are paused until it serves again"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: wxops-kyverno-required
spec:
  policyName: wxops-kyverno-required
  validationActions: [Deny]
  paramRef:
    name: <kyverno-validating-webhook-configuration>   # the one that serves policies.kyverno.io ValidatingPolicies
    parameterNotFoundAction: Deny
```

Before you rely on it, on a test cluster:

1. **Fill in `paramRef.name`.** List `kubectl get validatingwebhookconfigurations` and pick Kyverno's configuration that serves the `policies.kyverno.io`
   ValidatingPolicies; scale Kyverno's admission controller to zero and confirm that exact one disappears.
2. **Check that the API server accepts a `ValidatingWebhookConfiguration` as `paramKind`** — this guard is not yet verified on a cluster.
3. **Try both sides.** With Kyverno scaled to zero, an SCM user's write is refused with the guard's message, while a controller's or cluster-admin's write
   passes. Scale Kyverno back and the same user's write is decided by the platform policies again.

To remove it: `kubectl delete validatingadmissionpolicybinding wxops-kyverno-required` and `kubectl delete validatingadmissionpolicy wxops-kyverno-required`.

## 4 - Apply a first resource

```bash
kubectl apply -f examples/scm/connection/xr.yaml
kubectl apply -f examples/scm/repository/xr.yaml
kubectl get xscmrepositories
kubectl describe xscmrepository <name>
crossplane resource trace xscmrepository <name>   # the XR and everything it composed
```

Wait for `status.created` and `status.ready`; see [Reading status](../api-reference/README.md#reading-status).

## 5 - Make `Pinniped` available to use `Impersonate Proxy`

Now you can setup and reconfigure DexiDP with `XOIDCClient`

> [!NOTE]
> This step reuses `$LB_IP` from step 0. In a new shell it is empty, and the issuer and redirect URIs below silently become `dex.wxops..nip.io` — run the
> lookup again first.

```bash
# Get the LoadBalancer IP again, if this is a new shell
until LB_IP=$(kubectl get svc -A -o jsonpath='{.items[?(@.status.loadBalancer.ingress)].status.loadBalancer.ingress[0].ip}' | grep -E '^[0-9.]+$'); do echo "Waiting for LB IP..." && sleep 5; done; echo "Found: $LB_IP";

# create the oidc-connection
cat <<EOF | kubectl apply -f -
apiVersion: auth.wxops.cloud/v1alpha1
kind: XOIDCConnection
metadata:
  name: dex
spec:
  crossplane:
    compositionRevisionSelector:
      matchLabels:
        channel: nightly
    compositionUpdatePolicy: Automatic
  parameters:
    issuer: "https://dex.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io"
    config:
      externalSecretName: dex-config
      namespace: wxops-platform
    secretStoreRef:
      name: vault-platform
    vendor: dex
EOF

# create client-id for pinniped supervisor in dex (generated)
cat <<EOF | kubectl apply -f -
# A confidential client, secret ESO-generated. The Pinniped Supervisor.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XOIDCClient
metadata:
  name: pinniped-supervisor
spec:
  crossplane:
    compositionRevisionSelector:
      matchLabels:
        channel: nightly
    compositionUpdatePolicy: Automatic
  parameters:
    connectionRef:
      name: dex
    clientId: pinniped-supervisor
    displayName: W'xOps IDP Pinniped
    redirectUris:
      - "https://supervisor.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io/callback"
    public: false
    secret:
      source: generate # generate mode, but you can use static to easier setup
EOF

# create the secret hold the generated secrets name to map it with pinniped supervisor.
# In generate mode Core also writes the client secret to <vendor>/clients-def/<clientId> — here platform/dex/clients-def/pinniped-supervisor,
# through vault-platform (needs the OpenBao port-forward from step 0). The Secret goes where the Supervisor runs; find its namespace with:
#   kubectl get deploy -A | grep -i supervisor
SUPERVISOR_NS=<supervisor-namespace>
kubectl create secret generic pinniped-supervisor-client-credentials -n "$SUPERVISOR_NS" \
 --from-literal=clientID="pinniped-supervisor" \
 --from-literal=clientSecret="$(bao kv get -field=secret platform/dex/clients-def/pinniped-supervisor)" \
 --type secrets.pinniped.dev/oidc-client

# enable identity provider for DexiDP for OIDC connection
helm upgrade --install pinniped wxops/pinniped --namespace wxops-platform --create-namespace --version 0.2.0 \
 --reuse-values \
 --set supervisor.identityProviders.dex.create=true \
 --set supervisor.identityProviders.dex.issuer="https://dex.wxops.$(echo $LB_IP | sed 's/\./-/g').nip.io" \
 --set supervisor.identityProviders.dex.certificateAuthorityData="$(kubectl get secrets -n cert-manager wxops-idp-ca-secret -o json | jq -r '.data."ca.crt"')" \
 --set supervisor.identityProviders.dex.allowPasswordGrant=true \
 --set supervisor.identityProviders.dex.clientSecretName="pinniped-supervisor-client-credentials"
```

Now you can easier to use `pinniped` command to generate kubeconfig and export with `KUBECONFIG` to use the customization

```bash
pinniped get kubeconfig > ~/.kube/oidc-user.yaml

export KUBECONFIG=~/.kube/oidc-user.yaml

# use kube auth to execute session login with browser and show you auth information
kubectl auth whoami
```

## Uninstalling

```bash
make uninstall       # remove registry-installed Configuration packages
make uninstall-dev   # remove XRDs and Compositions applied by make install-dev
```

Delete XRs first, and read each Kind's deletion notes before you do. Kinds that hold data, like `XDatabase`, keep it by default.

### Removing one category

`kubectl delete -k` works on a category the same way `kubectl apply -k` installs it (`package/scm/`, `package/auth/`, or `package/install/<group>/` for the registry
install). Order matters, because a Composition or XRD removed while XRs still use it leaves them with nothing to reconcile them:

1. **Delete the XRs of the category first**, and wait until they are gone (`kubectl get composite`). Their composed resources go with them: a `PushSecret` deletes its
   OpenBao record, while an `XScmTeam` or `XScmRepository` keeps the host object unless `retain: false` is set.
2. **Then delete the packages** — the Compositions and XRDs — with `kubectl delete -k package/<group>/` (or `make uninstall-dev`).
3. **Last, clear what is left over.** Crossplane never garbage-collects `CompositionRevision`s, so old ones remain; delete them by composition with
   `kubectl delete compositionrevision -l crossplane.io/composition-name=<composition>`.

Remove in dependency order across categories: `auth` reads `scm` (an `XOIDCConnector` reads its `XScmConnection` and `XScmTeam`s), so take `auth` out before `scm`;
`tenant` reads `platform` (an `XDatabase` reads its `XDatabaseCluster`), so take `tenant` out before `platform`. `platform` and `tenant` have no category
Kustomization — delete their packages one directory at a time, e.g. `kubectl delete -k package/tenant/database/`.

## Next

- Ship an application end to end: [app onboarding](app-onboarding.md)
- Every Kind and what the reconcile loop does for it: [API reference](../api-reference/README.md)
- Build a portal on top: [portal integration](portal-integration.md)
