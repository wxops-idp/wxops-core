# Multi-Cluster Architecture — Hub and Spoke

W'xOps Core today runs as a **single-cluster control plane**. Every composed resource is applied to the same cluster Crossplane itself runs in, via a
`ProviderConfig` that uses the provider pod's own ServiceAccount (`credentials.source: InjectedIdentity`).

This document covers what changes when the platform manages workloads across **multiple clusters** — a hub (control plane) driving one or more spokes (workload
clusters). It presents the full option space with trade-offs so either of two reference architectures can be adopted, rather than prescribing one path.

> **A path has since been chosen.** See [`multi-cluster-proposal.md`](multi-cluster-proposal.md) for the concrete proposal built on this research — Arch 2 +
> CAPI + structured authn, with k8gb/ExternalDNS for multi-region routing. This document remains the reference for the options *not* taken and the reasoning
> behind the choice.
>
> For how the hub→spoke API connection is secured in practice — including the case this document assumes away, a spoke that **already exists** and whose
> apiserver flags you do not control — see [`multi-cluster-connectivity.md`](multi-cluster-connectivity.md).

**Nothing here is implemented.** This is a design document. Since v0.4.0 the compositions do thread `spec.parameters.cluster` through every `providerConfigRef`
(this doc's Phase 0 prerequisite), but no second cluster, spoke `ProviderConfig`, or credential exists.

---

**Table of Contents**
- [The distinction that decides everything](#the-distinction-that-decides-everything)
- [Where W'xOps Core is today](#where-wxops-core-is-today)
- [Layer 1 — Control plane connectivity](#layer-1--control-plane-connectivity)
  - [Option A — Push: hub holds spoke credentials](#option-a--push-hub-holds-spoke-credentials)
  - [Option A2 — Push with brokered, just-in-time credentials](#option-a2--push-with-brokered-just-in-time-credentials)
  - [Option B — Pull: Git as transport](#option-b--pull-git-as-transport)
  - [Option C — Pull: agent-based](#option-c--pull-agent-based)
  - [Option D — Reverse tunnel for live API access](#option-d--reverse-tunnel-for-live-api-access)
- [Layer 2 — Identity and authentication](#layer-2--identity-and-authentication)
  - [Machine identity — hub to spoke](#machine-identity--hub-to-spoke)
  - [Human identity — developer to spoke](#human-identity--developer-to-spoke)
  - [The CAPI trust-root problem](#the-capi-trust-root-problem)
- [Layer 3 — Data plane](#layer-3--data-plane)
- [Cluster lifecycle with CAPI](#cluster-lifecycle-with-capi)
- [Darlane across clusters](#darlane-across-clusters)
- [Reference architecture 1 — Git-centric](#reference-architecture-1--git-centric)
- [Reference architecture 2 — ArgoCD hub-spoke with CAPI](#reference-architecture-2--argocd-hub-spoke-with-capi)
- [Choosing between them](#choosing-between-them)
- [Migration path](#migration-path)
- [Decisions to make before building](#decisions-to-make-before-building)
- [Out of scope](#out-of-scope)
- [References](#references)

---

## The distinction that decides everything

Multi-cluster discussions collapse into confusion because three unrelated problems share the phrase "connect the clusters". They have separate tooling, separate
failure modes, and separate adoption timelines.

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3 — DATA PLANE                                            │
│ Pod in cluster A calls Service in cluster B                      │
│ Tools: Cilium Cluster Mesh, Linkerd, Istio, Submariner, Skupper  │
│ Needed: only when workloads actually talk across clusters        │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2 — IDENTITY                                              │
│ Who is allowed to act on the spoke, and with what scope          │
│ Tools: structured authn (AuthenticationConfiguration), Pinniped, │
│        SPIFFE/SPIRE, cloud workload identity                     │
│ Needed: always — the question is only how well you do it         │
├─────────────────────────────────────────────────────────────────┤
│ Layer 1 — CONTROL PLANE                                         │
│ Hub causes desired state to exist on the spoke                   │
│ Tools: kubeconfig+provider, Git+Flux, argocd-agent, OCM, tunnels │
│ Needed: always — this is the actual hub-spoke problem            │
└─────────────────────────────────────────────────────────────────┘
```

**A service mesh does not solve Layer 1.** Istio, Linkerd, and Cilium Cluster Mesh move *application traffic* between clusters. They have nothing to do with the
hub writing a Deployment into a spoke's API server. Introducing Istio to solve hub-spoke management buys a very large operational tax against a problem it does
not touch.

Layer 1 is the mandatory one. Layer 2 is where most of the security value is. Layer 3 is optional and should be deferred until a concrete workload requires it.

---

## Where W'xOps Core is today

`providers/providerconfig-kubernetes.yaml`:

```yaml
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity   # ← the provider pod's own ServiceAccount
```

Every composed `kubernetes.crossplane.io/v1alpha2` `Object` in every package references it by name. In `kcl/tenant-app/main.k` alone there are **12
occurrences** of:

```python
providerConfigRef = {name = "default"}
```

`providers/archive/providerconfig-terraform.yaml` has the same shape — a Kubernetes state backend with `in_cluster_config = true`.

### What specifically breaks at two clusters

| Concern | Today | At N clusters |
|---|---|---|
| Target cluster selection | Implicit — always local | Must become explicit input |
| `providerConfigRef` | Hardcoded `"default"` ×12 per package | Must be derived from an XR field |
| Credentials | None needed (`InjectedIdentity`) | One credential per spoke, stored somewhere |
| Terraform state | Local cluster Secret | Must not collide across spokes |
| `XTenantDatabase` composed XR | Rendered on hub, applied locally | Which cluster owns the CNPG cluster? |
| Darlane `exec` / `logs` / sync | Local API, trivially reachable | Requires a live network path (see below) |
| Vault / ExternalSecrets | One `ClusterSecretStore` | Per-spoke store, or one store reachable from all |
| Blast radius | Cluster-scoped | Hub compromise is now fleet-wide |

The last row is the one that should drive the architecture choice, not the first.

---

## Layer 1 — Control plane connectivity

Three shapes exist, plus one significant variant of the first.

| Shape | Direction | Hub holds spoke creds? | Spoke needs inbound? | Latency to converge |
|---|---|---|---|---|
| **Push** (A) | hub → spoke API | Yes — standing | Yes | Immediate |
| **Push, brokered** (A2) | hub → spoke API | No — minted just-in-time | Yes | Immediate |
| **Pull (Git)** (B) | spoke → Git | No | No | Poll interval (~1 min) |
| **Pull (agent)** (C) | spoke → hub | No | No | Near-immediate |
| **Tunnel** (D) | spoke → hub, then hub → spoke over the tunnel | Yes (but bounded) | No | Immediate |

---

### Option A — Push: hub holds spoke credentials

The hub stores each spoke's credential and calls the spoke API server directly. This is the smallest delta from the current single-cluster design.

#### Crossplane side

One `ProviderConfig` per spoke:

```yaml
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: spoke-prod-sgn
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: spoke-prod-sgn-kubeconfig
      key: kubeconfig
```

The Secret should arrive from Vault via an `ExternalSecret`, never from Git.

Add a `cluster` parameter to the XRDs and thread it through the KCL. The change is mechanical but touches every composed resource:

```python
# near the top of main.k, with the other parameter reads
targetCluster = _get(params, "cluster", "default")

# then replace every occurrence of the hardcoded form
providerConfigRef = {name = targetCluster}
```

Guard it so a typo cannot silently land resources on the hub. KCL has no `assert` with a friendly message in composition context, so validate at the XRD
boundary instead — an `enum` of known cluster names, or a `x-kubernetes-validations` CEL rule.

Terraform state needs the same treatment: `secret_suffix` must include the cluster name, or two spokes with the same app name will fight over one state Secret.

#### ArgoCD side, and the privilege problem

ArgoCD stores clusters as Secrets labeled `argocd.argoproj.io/secret-type: cluster`. The convenient way to create one is `argocd cluster add`, and it is worth
being precise about what that does:

1. creates ServiceAccount `argocd-manager` in `kube-system` on the spoke
2. binds it to **`cluster-admin`** via a ClusterRoleBinding
3. stores the resulting bearer token in a Secret on the hub

So the default registration path grants the hub unrestricted, long-lived, rarely-rotated control of every spoke. A hub compromise is a full fleet compromise.
This is not a hypothetical concern — it is the documented default behaviour, and it is the single strongest argument for Options B and C.

#### Hardening push

If push is chosen anyway, do not use `argocd cluster add`. Write the cluster Secret explicitly and scope it:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: spoke-prod-sgn
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: spoke-prod-sgn
  server: https://spoke-prod-sgn.internal:6443
  config: |
    {
      "bearerToken": "<scoped SA token>",
      "tlsClientConfig": { "caData": "<base64 CA>" }
    }
  namespaces: "team-alpha,team-beta"
  clusterResources: "false"
```

Three things to understand about this:

- **`clusterResources` only takes effect when `namespaces` is set.** Without a
  namespace restriction it is ignored entirely.
- **`namespaces` and `clusterResources` are enforced hub-side by ArgoCD.** They
  are a guardrail against accident, not a security boundary. The spoke's own
  RBAC is what actually holds. Both must be configured.
- **Each entry in `namespaces` triggers a separate list/watch** on the spoke.
  Long lists have a real memory and API-server cost.

Then create the spoke-side identity with a ClusterRole scoped to the API groups the compositions actually emit — for W'xOps that is:

| API group | Emitted by |
|---|---|
| `apps` (Deployment) | `tenant-app` |
| core (Service, ServiceAccount, Secret, ConfigMap) | `tenant-app` |
| `networking.k8s.io` (Ingress) | `tenant-app` |
| `traefik.io` (IngressRoute, TraefikService, Middleware) | `tenant-app` |
| `cert-manager.io` (Certificate) | `tenant-app` |
| `external-secrets.io` (ExternalSecret, PushSecret) | `tenant-app`, `tenant-database` |
| `postgresql.cnpg.io` (Cluster, Database, Pooler, ScheduledBackup) | `platform-database-clusters` |
| `postgresql.sql.crossplane.io` (ProviderConfig, Role) | `platform-database-clusters`, `tenant-database` |

Not `*`. `providers/rbac-provider-kubernetes.yaml` already enumerates most of this for the single-cluster case and is the natural starting point for the
spoke-side ClusterRole.

If cluster-scoped resources are genuinely needed (CNPG and Traefik CRDs are namespaced, but `postgresql.sql.crossplane.io` `ProviderConfig` and `Role` are
cluster-scoped), `clusterResources: false` will block them. Scope by API group in RBAC rather than relying on that flag alone.

#### Trade-offs

**For**
- Smallest change from current architecture
- Immediate convergence, real-time status back on the hub
- Single pane of glass with no extra components
- Works with entirely unmodified spokes — nothing to install

**Against**
- Spoke API server must be network-reachable from the hub (public LB with IP
  allowlist, VPN, or private interconnect)
- Hub accumulates high-privilege credentials — the dominant risk
- Credential rotation is an operational burden that scales with cluster count
- Hub becomes a hard availability dependency for spoke reconciliation

---

### Option A2 — Push with brokered, just-in-time credentials

Keeps Option A's shape — the hub calls the spoke API directly, status flows back natively — but removes the standing credential. Instead of a stored token,
ArgoCD's cluster Secret declares a **client authentication exec plugin** (`client.authentication.k8s.io/v1`) that mints a short-lived credential on demand.

This is not exotic: it is exactly how `aws eks get-token`, `gke-gcloud-auth-plugin`, and AKS `kubelogin` already work. Connecting clusters via a
client-credentials flow rather than a stored token is an active community ask ([argo-cd#26776](https://github.com/argoproj/argo-cd/discussions/26776)), and AWS
has published a Pinniped-based multi-cluster EKS design with this structure.

```
[ ArgoCD sync triggered ]
        │
        ▼
1. client-go runs the exec plugin named in execProviderConfig
        │
        ▼
2. plugin reads a projected SA token  (audience: portal-api)
        │
        ▼
3. plugin calls the Hub Portal broker with that token + target cluster ID
        │
        ▼
4. Portal authenticates the caller, authorises caller→cluster,
   mints a short-lived spoke credential
        │
        ▼
5. plugin prints ExecCredential JSON to stdout
        │
        ▼
6. client-go caches it in memory until expirationTimestamp,
   authenticates against the spoke
```

#### Cluster Secret

No `bearerToken`, no embedded kubeconfig:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: spoke-prod-sgn
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: spoke-prod-sgn
  server: https://spoke-prod-sgn.internal:6443
  config: |
    {
      "execProviderConfig": {
        "command": "/usr/local/bin/wxops-cli",
        "args": ["get-token",
                 "--cluster-id", "spoke-prod-sgn",
                 "--portal-url", "http://portal-api.hub.svc.cluster.local"],
        "apiVersion": "client.authentication.k8s.io/v1"
      },
      "tlsClientConfig": { "insecure": false, "caData": "<base64 spoke CA>" }
    }
```

The plugin must print an `ExecCredential` to stdout:

```json
{
  "apiVersion": "client.authentication.k8s.io/v1",
  "kind": "ExecCredential",
  "status": {
    "token": "<short-lived spoke JWT>",
    "expirationTimestamp": "2026-08-12T10:30:00Z"
  }
}
```

If Pinniped **Concierge** sits in front of the spoke apiserver, the plugin must additionally call `TokenCredentialRequest` and return `clientCertificateData` /
`clientKeyData` instead of `token`. The shape above is for the direct-to-apiserver case only.

#### The question that decides whether this is worth doing

**What does the broker use to mint the spoke credential?** All of the security lives in step 4, and the three implementations are not equivalent:

| | Broker mechanism | Standing secrets eliminated? |
|---|---|---|
| **a** | Broker holds per-spoke admin credentials, calls `TokenRequest` on the spoke | ❌ **No — relocated.** A network-facing service now holds the fleet instead of a Secret guarded by cluster RBAC. **Net worse than Option A.** |
| **b** | Broker is an OIDC issuer; signs a JWT; spokes trust it via `AuthenticationConfiguration` or Pinniped `JWTAuthenticator` | ⚠️ One signing key remains. Acceptable **only** if held in a KMS/HSM so it never leaves — one key, one rotation story, bounded blast radius. |
| **c** | Broker exchanges hub identity for cloud IAM (STS `AssumeRole` → `eks get-token`, GCP SA impersonation) | ✅ Yes — the cloud provider holds the root. This is what AWS and Azure actually do. |

Implementation **(a) must be explicitly excluded.** It is the path of least resistance and it converts a credential-storage problem into a
single-point-of-total-compromise problem.

#### Why an exec plugin is needed even without a broker

There is an argument that collapses the whole pipeline. If a spoke trusts the hub's ServiceAccount OIDC issuer via `AuthenticationConfiguration` ([Layer
2](#preferred-native-structured-authentication)), then ArgoCD's projected SA token *already is* a valid spoke credential — the token sent to the broker as proof
of identity is the same token the spoke would accept directly:

```
With broker:  ArgoCD SA token → plugin → Portal → mints token → spoke
Collapsed:    ArgoCD SA token ───────────────────────────────→ spoke
```

But a detail rescues `execProviderConfig` regardless. For a spoke to safely accept that token it must be **audience-scoped** (`audience: spoke-prod-sgn`), or a
token minted for the hub API replays against every spoke. ArgoCD cluster Secrets accept `bearerToken` as **inline static text** — there is no `bearerTokenFile`
— so a rotating, per-audience projected token cannot be expressed that way.

So exec is required either way. Without a broker it is trivial — no network call, no new service:

```jsonc
{"execProviderConfig": {
  "command": "/usr/local/bin/wxops-cli",
  "args": ["get-token", "--token-file",
           "/var/run/secrets/spoke-tokens/spoke-prod-sgn/token"],
  "apiVersion": "client.authentication.k8s.io/v1"
}}
```

Read the projected file, emit `ExecCredential`, exit.

#### The scale threshold — the actual decision rule

The brokerless variant needs **one projected volume per audience**, declared in the controller's pod spec. That is fine at ten spokes and untenable at hundreds:
pod-spec bloat, and a controller restart every time a cluster is added or removed. A broker is dynamic; projected volumes are not.

| Situation | Machine credential path |
|---|---|
| Few spokes (≲20), CAPI-provisioned | `execProviderConfig` reading a per-audience projected token. **No broker.** |
| Hundreds of spokes | **Broker** — implementation (b) or (c). Projected volumes do not scale. |
| Managed spokes (EKS/GKE/AKS), any count | **Broker** (c), or the vendor plugin directly (`kubelogin`, `aws eks get-token`) |
| Few spokes, apiserver flags unavailable | Pinniped Concierge `JWTAuthenticator` + brokerless exec |

A broker is justified by fleet size or by managed spokes — not by the desire to avoid stored tokens on its own, which the brokerless variant already achieves.

#### Pinniped's supported CI/CD flow, and what it costs

Pinniped has a documented, supported non-interactive path — the **`cli_password` flow** ([howto/cicd](https://pinniped.dev/docs/howto/cicd/)). A broker (or a CI
job) can use it directly, so "Pinniped cannot do machines" is wrong. What matters is the exact shape of it.

Generate a kubeconfig pinned to the non-interactive flow:

```bash
pinniped get kubeconfig \
  --upstream-identity-provider-flow=cli_password \
  > spoke-prod-sgn.kubeconfig
```

Then supply the service-account credential via environment, which suppresses the interactive prompts:

```bash
export PINNIPED_USERNAME='svc-argocd'
export PINNIPED_PASSWORD="${SPOKE_SVC_PASSWORD}"
kubectl --kubeconfig spoke-prod-sgn.kubeconfig get deploy -n team-alpha
```

Requirements and limits, all load-bearing:

| Aspect | Detail |
|---|---|
| Supported IdP types | `OIDCIdentityProvider`, `LDAPIdentityProvider`, `ActiveDirectoryIdentityProvider` |
| **Not** supported | **`GitHubIdentityProvider`** — excluded by OAuth 2.0 limitations |
| OIDC precondition | `allowPasswordGrant: true` must be set on the `OIDCIdentityProvider` |
| Supervisor | Required — plus a `FederationDomain` and at least one IdentityProvider |
| Concierge | Required on each spoke **unless** the spoke supports native OIDC authentication, in which case the kubeconfig can authenticate directly |
| Credential | A username/password for a **non-human account** in the upstream IdP |

Two consequences for W'xOps:

**1. It is still a standing credential.** `PINNIPED_PASSWORD` is a long-lived service-account password. It is meaningfully better than N spoke tokens — one
credential, centrally revocable, and it yields short-lived cluster credentials downstream — but the "zero static secret" goal is not met, only narrowed to one
secret. Pinniped's own guidance is explicit that these accounts must never be shared with humans and should hold "the least amount of privileges necessary."

**2. Gitea cannot be the machine IdP.** Gitea's OAuth2 provider supports `authorization_code` and `refresh_token`, not resource-owner password credentials
(deprecated in OAuth 2.1). This is the same limitation that causes Pinniped to exclude `GitHubIdentityProvider` from `cli_password` — Gitea's provider is
GitHub-shaped in exactly this respect.

The fix is lighter than a parallel Pinniped deployment, though. Pinniped supports **multiple IdentityProviders on a single FederationDomain**, which is the
documented pattern for precisely this split:

```
FederationDomain (one Supervisor on the hub)
├── GiteaIdentityProvider (OIDC, authorization_code)  → humans
│      └── Darlane exec / logs / port-forward, per-developer audit
└── LDAP or password-grant OIDC provider              → machines
       └── svc-argocd, cli_password flow
```

So the cost is not a second Pinniped stack — it is **one additional identity source that supports password grant** (an LDAP directory, or Keycloak with
`allowPasswordGrant`), registered against the same FederationDomain.

Whether that is worth it depends on the spokes. On CAPI-provisioned spokes it buys nothing that `AuthenticationConfiguration` does not already provide, and adds
an IdP plus a standing password. On managed spokes where apiserver flags are unavailable, it is a genuinely good answer — and note that Concierge can be skipped
entirely where the spoke already does native OIDC, which CAPI spokes do.

#### Mandatory hardening

Nine requirements. The first two are security-critical and easy to get wrong.

1. **Do not read the default SA token path.**
   `/var/run/secrets/kubernetes.io/serviceaccount/token` has audience = the hub
   apiserver. Sending it to the broker is a confused-deputy setup: the broker
   holds a credential valid against the hub, and anything that can read that file
   impersonates the controller. Mount a dedicated projected volume with
   `audience: portal-api` and have the broker reject every other audience.

2. **Authenticate *and* authorise the caller.** `TokenReview` tells you *who* is
   calling. You also need *may this caller request this cluster* — otherwise any
   ServiceAccount that can reach the broker Service obtains credentials for any
   spoke. Required: audience check, SA allowlist, explicit caller→cluster
   authorisation table.

3. **Plan for the broker as a fleet-wide SPOF.** Standing tokens have exactly one
   virtue — they work when everything else is down. Broker unavailable means
   every cache miss fails, and client-go exec has no retry or backoff, so syncs
   fail fleet-wide. Requires HA and a documented break-glass path.

4. **TTL 10–15 minutes — a floor as well as a ceiling.** client-go caches the
   credential in memory per exec config and honours `expirationTimestamp`; 15 min
   is roughly 4 execs/hour/cluster. At 1 min across 300 clusters the controller is
   fork-bombing itself.

5. **The refresh is client-go's, not ArgoCD's.** The exec credential provider
   does the caching and re-invocation. Debug there, not in ArgoCD code.

6. **Verify the `apiVersion` against the vendored client-go.** ArgoCD's own docs
   example uses `client.authentication.k8s.io/v1beta1`, and there is a live
   "exec plugin returning bad version" issue
   ([argo-cd#6749](https://github.com/argoproj/argo-cd/issues/6749)). Test before
   committing to `v1`.

7. **Distinct identities for machine and human paths.** If the Portal serves both,
   machine credentials must carry a different subject and group than human ones.
   Otherwise every spoke audit entry reads as the platform and the audit trail in
   [`development-docs/core-ideas/guardian.md`](guardian.md) is hollow.

8. **Volume-mount the binary; do not rebuild ArgoCD.** The plugin must exist in
   **both** `argocd-server` and `argocd-application-controller`. ArgoCD's docs
   sanction volume mounts as an alternative to custom images — use an init
   container plus a shared `emptyDir` and avoid rebuilding two images on every
   ArgoCD upgrade and every CLI change.

9. **Spoke-side RBAC still applies.** A just-in-time credential that maps to
   `cluster-admin` is a 15-minute cluster-admin. The scoped ClusterRole from
   [Option A](#hardening-push) is still required.

#### Trade-offs

**For**
- No standing spoke credentials on the hub — the dominant risk of Option A is
  removed without changing the delivery model
- Keeps native `Object` status → XR `status.ready`, which Option B sacrifices
- No agent to install on spokes, unlike Option C
- Credential rotation becomes automatic rather than an operational burden
- Scales to hundreds of clusters without per-cluster secret management
- Established pattern with vendor precedent (`kubelogin`, `aws eks get-token`)

**Against**
- Introduces a bespoke broker on the reconcile path — a new SPOF, and a service
  whose compromise is fleet-wide under implementation (b)
- Requires a custom CLI, injected into two ArgoCD workloads, maintained across
  ArgoCD upgrades
- Spoke API server must still be network-reachable from the hub (Option A's
  network constraint is unchanged)
- Under (b), a signing key must be protected at least as well as the tokens it
  replaces — KMS is effectively mandatory, not optional
- More moving parts to debug than a stored token: plugin, broker, token
  audience, spoke trust config
- Under a small fleet with CAPI spokes, most of this machinery is avoidable —
  see the scale threshold above

---

### Option B — Pull: Git as transport

The hub never touches a spoke API server. Crossplane renders manifests and commits them to a Gitea repository; each spoke runs its own reconciler (Flux, or a
spoke-local ArgoCD) that pulls and applies.

```
┌────────────────────── HUB ───────────────────────┐
│  Portal → XTenantApp XR                          │
│      ↓                                           │
│  Crossplane + function-kcl                       │
│      ↓  renders manifests                        │
│  provider-terraform (Gitea provider)             │
│      ↓  git commit                               │
└──────────────────┬───────────────────────────────┘
                   │
              ┌────▼─────┐
              │  Gitea   │  fleet/<cluster>/<ns>/<app>.yaml
              └────┬─────┘
        ┌──────────┼──────────┐
        │          │          │      (outbound HTTPS only)
   ┌────▼───┐ ┌────▼───┐ ┌────▼───┐
   │ spoke1 │ │ spoke2 │ │ spoke3 │  each running Flux
   │  Flux  │ │  Flux  │ │  Flux  │
   └────────┘ └────────┘ └────────┘
```

The credential question disappears rather than being mitigated. Spokes need only egress to Gitea. The hub holds nothing that grants spoke access.

#### What changes in the compositions

This is a more invasive change than Option A, because composed resources stop being `kubernetes.crossplane.io` `Object`s and become file content.

Three viable mechanics:

1. **provider-terraform with the Gitea provider.** W'xOps already uses this
   pattern for `gitea-*` packages, so the provider and credentials exist. The
   composition emits a `Workspace` with inline HCL creating repository files.
   Downside: Terraform state per app, and diffs are opaque.

2. **A git provider for Crossplane** (e.g. `provider-git`). Cleaner semantics —
   a `Repository`/`File` resource per manifest — but adds a provider dependency
   that is not currently in the reference stack.

3. **Hub-local `Object`s consumed by a hub-side Flux `Kustomization` that
   pushes.** Awkward; not recommended.

Option 1 is the pragmatic choice given the existing stack.

Repository layout matters more than the mechanism. A per-cluster directory keeps each spoke's Flux `Kustomization` pointed at exactly one path and makes "what
is running where" answerable with `ls`:

```
fleet/
├── prod-sgn/
│   ├── team-alpha/
│   │   ├── payment-api.yaml
│   │   └── payment-api-darlane.yaml
│   └── team-beta/
└── staging-sgn/
    └── team-alpha/
```

#### Status reporting

The significant loss. With Option A, `Object` status flows back and the XR's `status.ready` reflects reality. With Git-as-transport, the XR becomes ready when
the *commit* succeeds — which says nothing about whether the spoke applied it.

Recovering real status requires one of:

- Flux on the spoke writing status to a shared backend the hub reads
- `function-extra-resources` on the hub reading spoke-reported state (needs a
  read path, i.e. partially back to Option A or D)
- The portal querying spokes directly (needs Option D)
- Accepting eventual, out-of-band status via Flux notifications to a webhook

Note the existing readiness workaround documented for this repo — native `type: Ready` is unreliable on Crossplane v2.3 with function-kcl v0.12.1, and
`status.ready` is derived from `ocds`. That derivation assumes the `Object` pattern. Git-as-transport removes the `ocds` signal entirely, so the readiness story
must be redesigned, not merely ported.

#### Trade-offs

**For**
- No spoke credentials on the hub — the risk class is eliminated
- Spokes need zero inbound connectivity; works behind NAT, in air-gapped-ish
  networks, across clouds
- Spokes keep reconciling if the hub is down
- Full Git audit trail: every change to every cluster is a reviewable commit
- Composes with `scm-repository`, already in this repo

**Against**
- Loses real-time status back to the XR — the biggest cost
- Convergence bounded by Flux poll interval (or requires webhooks)
- Every spoke needs Flux bootstrapped and its Git credential managed
- Darlane's interactive workflows are **not** served by this path at all
- No single pane of glass without additional tooling

---

### Option C — Pull: agent-based

A lightweight agent on each spoke dials outbound to the hub over mTLS and receives desired state. Combines Option B's credential story with Option A's real-time
status.

#### argocd-agent

The official Argo project answer to multi-cluster (`argoproj-labs/argocd-agent`). Agents connect outbound to the control plane over gRPC; no inter-agent links;
the hub holds no spoke kubeconfig.

Two operating modes:

- **Managed** — the hub owns the `Application` spec; the agent receives it. This
  is the closest analogue to classic ArgoCD hub-spoke.
- **Autonomous** — the spoke owns its `Application` specs and reports up. Better
  for teams that own their clusters.

Status: **pre-GA**, but explicitly recommended for adoption by the project, and Red Hat ships it in OpenShift GitOps 1.19 — which is a meaningful maturity
signal. The API may still shift.

#### Open Cluster Management (OCM)

The CNCF fleet-management approach. A `klusterlet` agent on the spoke performs a real registration handshake (CSR-based, hub approves), then pulls work via the
`ManifestWork` API.

```
hub                                spoke
───                                ─────
ManagedCluster (registration)  ←──  klusterlet agent
ManifestWork (desired state)   ──→  applies to spoke
                               ←──  status feedback per resource
```

OCM's `ManifestWork` gives per-resource status back to the hub, which makes it a better fit than argocd-agent if the goal is Crossplane-driven rather than
ArgoCD-driven delivery — a composition could emit `ManifestWork` objects locally on the hub instead of remote `Object`s, keeping the composition shape almost
unchanged:

```python
# instead of a remote Object, a local ManifestWork the klusterlet picks up
apiVersion = "work.open-cluster-management.io/v1"
kind = "ManifestWork"
metadata = {
    name = appName
    namespace = targetCluster        # OCM convention: one ns per managed cluster
}
spec.workload.manifests = [ <the same manifests as today> ]
```

This is arguably the best structural fit for a Crossplane-centric platform: the hub still writes objects with `InjectedIdentity` (no spoke creds), status still
flows back, and the KCL change is smaller than Option B's.

OCM also brings `cluster-proxy` (see Option D) and `Placement` for policy-based cluster selection.

#### Others

| Tool | Notes |
|---|---|
| **Karmada** | Push or pull; aggregated API server; `PropagationPolicy`. Powerful but heavy — it wants to be *the* multi-cluster API. |
| **Rancher Fleet** | `fleet-agent` on downstream clusters. Solid, but Rancher-flavoured. |
| **Sveltos** | Add-on distribution keyed on CAPI `Cluster` objects. Excellent complement to CAPI, less a general delivery mechanism. |

#### Trade-offs

**For**
- No spoke credentials on the hub
- No inbound spoke connectivity required
- Real-time status back to the hub (unlike Option B)
- OCM's `ManifestWork` maps nearly 1:1 onto the existing composition shape

**Against**
- A new component to run and upgrade on every spoke
- argocd-agent is pre-GA — API churn risk
- OCM is a substantial concept surface (`ManagedCluster`, `ManifestWork`,
  `Placement`, `ManagedClusterSet`, addon framework)
- Debugging spans two clusters and an agent

---

### Option D — Reverse tunnel for live API access

Options B and C solve declarative delivery. Neither gives the hub a synchronous API path to a spoke — and some things genuinely need one:

- Darlane `kubectl exec`, `logs -f`, `port-forward`
- `wxops darlane sync` / mutagen streaming files into a pod
- Portal features that read live pod state
- `kubectl debug` ephemeral containers

For these, a reverse tunnel gives hub→spoke API access without spoke inbound.

| Tool | Mechanism | Notes |
|---|---|---|
| **OCM cluster-proxy** | apiserver-network-proxy (ANP); spoke dials hub | Purpose-built, pairs with OCM Option C. Hub gets a virtual kubeconfig per spoke. |
| **Tailscale K8s operator** | WireGuard mesh; spoke API exposed as a tailnet service | Most pragmatic. Stable address per spoke, ACLs for scoping, ~30 min to stand up. |
| **Teleport** | Reverse tunnel + short-lived certs + session recording | Heavier, but gives audited access — valuable for production Darlane sessions. |
| **inlets / frp / Cloudflare Tunnel** | Generic TCP/HTTP reverse tunnel | Works, but you own the entire auth story. Least preferred. |

A tunnel restores hub→spoke reachability but **does not by itself fix authorisation** — whatever identity travels through the tunnel still needs to be scoped.
That is Layer 2.

Pairing note: Teleport and Tailscale both provide identity-aware access, which makes them attractive for the *human* path specifically, where session audit
matters most.

---

## Layer 2 — Identity and authentication

Two distinct paths, and conflating them is the most common design error.

```
MACHINE PATH                      HUMAN PATH
Hub controller → spoke API        Developer → spoke API
Non-interactive, long-running     Interactive, short session
Wants: bounded scope, bounded     Wants: per-user identity, audit,
       TTL, no browser                   revocation, group mapping
Answer: structured authn,         Answer: Pinniped, Teleport,
        SPIFFE, workload identity         cloud IdP integration
```

---

### Machine identity — hub to spoke

#### The default, and why it is bad

A ServiceAccount token bound to `cluster-admin`, stored on the hub, effectively non-expiring. Discussed under Option A. Avoid.

#### Preferred: native structured authentication

Kubernetes `AuthenticationConfiguration` lets a spoke apiserver trust one or more JWT issuers directly, with CEL-based claim mapping and validation. The hub's
own ServiceAccount issuer can be one of them — so ArgoCD or Crossplane on the hub presents its **projected** ServiceAccount token (bounded audience, bounded
TTL) and the spoke authenticates it as a first-class identity. No shared secret, no static token, no plugin.

```yaml
# on the spoke apiserver: --authentication-config=/etc/kubernetes/authn.yaml
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: https://hub.wxops.cloud/.well-known/openid-configuration
      audiences: ["spoke-prod-sgn"]
    claimMappings:
      username:
        expression: '"hub:" + claims.sub'
      groups:
        expression: '["wxops:hub-controllers"]'
    claimValidationRules:
      - expression: 'claims.sub == "system:serviceaccount:crossplane-system:provider-kubernetes"'
        message: only the provider-kubernetes SA may authenticate as a hub controller
```

Then bind `wxops:hub-controllers` on the spoke to the scoped ClusterRole from Option A. The credential is now a short-lived, audience-bound projected token
instead of a permanent cluster-admin bearer token.

**Version status:** beta in Kubernetes 1.30 (enabled by default), still beta through 1.34, **GA in 1.35**. Usable well before GA, but confirm the API version
(`v1beta1` vs `v1`) against the spoke's Kubernetes minor.

Two prerequisites, both real:

- The hub's ServiceAccount issuer must be **OIDC-discoverable from the spoke**
  (`/.well-known/openid-configuration` + JWKS reachable). On a private hub this
  means publishing those two endpoints, or mirroring the JWKS.
- You must be able to set apiserver flags on the spoke — which CAPI gives you.

One consequence worth carrying forward: once a spoke trusts the hub's issuer, the controller's projected token *is* the spoke credential — but it must be
delivered per-audience, and ArgoCD's inline `bearerToken` cannot express a rotating token file. See [Option
A2](#option-a2--push-with-brokered-just-in-time-credentials) for why that makes an exec plugin necessary even with no broker involved.

#### Pinniped, and where it fits

Pinniped has two components with different jobs:

- **Supervisor** — a federated OIDC issuer. Takes an upstream IdP (OIDC, LDAP,
  AD) and issues cluster-scoped tokens.
- **Concierge** — runs on the workload cluster; exchanges a token for
  short-lived mTLS client certs via the `TokenCredentialRequest` API.

Concierge exists primarily for clusters where you **cannot** set apiserver flags — EKS, GKE, AKS, managed TKG. That is its core value proposition.

**Therefore: if spokes are CAPI-provisioned, Pinniped is unnecessary for the machine path.** You control the apiserver, so native structured authentication
achieves the same outcome with fewer moving parts. If spokes are managed cloud clusters, Concierge's `JWTAuthenticator` becomes genuinely valuable — it gives
you structured-authn-like behaviour where the flags are unavailable.

**Pinniped can serve the machine path — that is a supported, documented flow.** A common misreading is that Supervisor is browser-only. It is not: the
[`cli_password` flow](https://pinniped.dev/docs/howto/cicd/) exists specifically for CI/CD and other headless callers, using `PINNIPED_USERNAME` /
`PINNIPED_PASSWORD` for a non-human account. See [Option A2](#pinnipeds-supported-cicd-flow-and-what-it-costs) for the full mechanics, supported IdP types, and
preconditions.

Two costs decide whether to use it here rather than whether it works:

- **A standing IdP password.** `PINNIPED_PASSWORD` is long-lived. One centrally
  revocable secret is much better than N spoke tokens, but it is not zero.
- **An extra identity source for machines.** `cli_password` requires OIDC with
  `allowPasswordGrant`, LDAP, or Active Directory. Gitea cannot supply it — the
  same OAuth 2.0 limitation that makes Pinniped exclude
  `GitHubIdentityProvider`. Mitigated by registering a second IdentityProvider on
  the *same* FederationDomain rather than a second Pinniped stack.

The `pinniped-cli` binary must also be present in both `argocd-server` and `argocd-application-controller` — a real cost, not a blocker, since ArgoCD's docs
sanction volume mounts over custom images.

Net: on a **CAPI-provisioned** spoke, Pinniped on the machine path adds an IdP and a standing password to obtain what `AuthenticationConfiguration` already
gives for free — so prefer native. On a **managed** spoke it is a genuinely good answer, and Concierge can be skipped where the cluster already supports native
OIDC.

Project health, for the record: Pinniped is actively maintained, having moved from the `vmware-tanzu` to the `vmware` GitHub organisation (images now published
to `ghcr.io/vmware/pinniped/pinniped-server`), with recent work extending `JWTAuthenticator` toward parity with upstream structured authentication. Worth
checking commit cadence before committing, given the Broadcom context, but it is not abandoned.

#### Summary

| Situation | Machine identity answer |
|---|---|
| CAPI-provisioned spokes, small fleet (≲20) | **Native `AuthenticationConfiguration`** + brokerless exec plugin reading a per-audience projected token ([A2](#why-an-exec-plugin-is-needed-even-without-a-broker)) |
| CAPI-provisioned spokes, hundreds of them | **Native `AuthenticationConfiguration`** + a broker, because projected volumes do not scale ([A2](#the-scale-threshold--the-actual-decision-rule)) |
| Managed cloud spokes (EKS/GKE/AKS) | **Pinniped Concierge `JWTAuthenticator`**, or the cloud's own IAM mapping via a broker |
| Cloud-specific and staying there | `awsAuthConfig` (IRSA), GKE Workload Identity or AKS `kubelogin` via `execProviderConfig` |
| Nothing else available | Scoped SA token + aggressive rotation. Treat as a stopgap. |

Note that Pinniped appears here only for managed spokes. For CAPI-provisioned spokes it costs a second IdP for machines (see above) and duplicates what
structured authentication already provides.

---

### Human identity — developer to spoke

This is where Pinniped is clearly the right tool, and it matters more for W'xOps than the machine path does — because of Darlane.

Darlane's workflows (`development-docs/core-ideas/darlane.md`) include `exec` into a pod that holds **real production secrets and real database connections**,
plus mirrord steal mode which can put real user traffic through a developer's code. If the portal performs those actions using a shared platform ServiceAccount,
then every audit log entry reads as the platform, not the person, and accountability is gone.

The Pinniped shape fits exactly:

```
Gitea (OAuth2 provider — the platform identity source behind
       scm-connection / scm-oauth-app, and RFC-004's planned Dex integration)
   │
   ▼
Pinniped Supervisor (hub)          federated OIDC issuer
   │                               maps Gitea teams → K8s groups
   ▼
Pinniped Concierge (each spoke)    TokenCredentialRequest
   │                               → short-lived mTLS client cert
   ▼
RoleBinding in the tenant namespace
   → exec / logs / port-forward on <appName>-darlane only
```

A developer clicks "open shell" in the portal, and gets a credential that is theirs, scoped to their team's namespace and their app's Darlane pod, expiring in
minutes.

Gitea's `authorization_code` flow is exactly right for this — a human is present to complete it. If machines also need Pinniped, add a password-grant-capable
IdentityProvider to the **same** `FederationDomain` rather than standing up a second Supervisor; serving humans and service accounts from one FederationDomain
is the documented pattern:

```
FederationDomain (one Supervisor, hub)
├── Gitea OIDC (authorization_code)      → humans, per-developer audit
└── LDAP / Keycloak (allowPasswordGrant) → machines, cli_password flow
```

Keep the two mapped to distinct Kubernetes groups so spoke audit logs distinguish a developer's `exec` from a controller's sync.

#### Current gap in the XRD

`darlane.serviceAccount` exists today (`create`, `name`, `annotations`) and is documented as being for portal or CI authentication, including cloud workload
identity bindings. That is a *workload* identity for the pod — useful, but not the same thing as a *developer* identity for access to the pod.

W'xOps Core deliberately emits **no RBAC at all** — no `Role`, no `RoleBinding`, no `subjects` — and provider-kubernetes is not granted permission to create
any. See development-docs/_archives/ROADMAP.md "Decided and rejected" for the reasoning.

The authorisation surface still has to exist; it is just authored elsewhere. The composition creates the Darlane ServiceAccount and publishes its name in
`status.darlane.serviceAccountName`, and the GitOps repo binds a `Role` to that name. That binding is what Pinniped-issued identities ultimately grant against.

Getting that binding in place is worth doing **before** multi-cluster work, not after — without it there is nothing for federated identity to grant. It is also
strictly useful single-cluster, so it is not speculative work.

Minimum shape:

```yaml
# Role: <appName>-darlane, in the tenant namespace
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/portforward", "pods/log"]
    verbs: ["create", "get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames: ["<appName>-darlane"]
    verbs: ["get", "patch", "update"]
```

Note the `resourceNames` restriction — it is what prevents a Darlane grant from becoming a grant over the production Deployment sitting in the same namespace.

---

### The CAPI trust-root problem

This deserves its own section because it undercuts the value of hardening everything above, and it is easy to miss.

**CAPI writes a `<cluster>-kubeconfig` Secret into the management cluster for every cluster it provisions, and that kubeconfig is cluster-admin**, minted from
the cluster's own CA during bootstrap.

So if the ArgoCD/Crossplane hub *is* the CAPI management cluster, the hub already holds cluster-admin for every spoke **by construction** — before ArgoCD is
involved at all. Scoping the ArgoCD credential while a full-privilege CAPI kubeconfig sits in a Secret in the same cluster is not a meaningful improvement.

Two honest resolutions:

**Accept it — hub as trusted root.** Declare the management cluster a CA-grade asset: no tenant workloads, minimal human access, strong audit, separate
lifecycle, restricted network. This is a legitimate and widely-used posture. The key is that it is *deliberate*, with controls sized accordingly.

**Split it.** The CAPI management cluster is separate from the GitOps hub. It provisions clusters and holds bootstrap kubeconfigs; it does not run the portal,
the tenant-facing Crossplane, or ArgoCD. The GitOps hub never sees a CAPI kubeconfig.

```
Accept                              Split
──────                              ─────
┌──────────────────┐                ┌──────────────┐  ┌──────────────┐
│ hub              │                │ CAPI mgmt    │  │ GitOps hub   │
│  CAPI mgmt       │                │  cluster     │  │  Crossplane  │
│  Crossplane      │                │  (trusted    │  │  ArgoCD      │
│  ArgoCD          │                │   root)      │  │  Portal      │
│  Portal          │                │              │  │  Vault       │
│  ← cluster-admin │                │ ← kubeconfigs│  │ ← scoped or  │
│    for all spokes│                │   only       │  │   no creds   │
└──────────────────┘                └──────────────┘  └──────────────┘
```

Whichever is chosen, choose it explicitly. Ending up in the middle by accident — a hub that is *treated* as low-trust while *holding* root credentials — is the
bad outcome.

CAPI's kubeconfig can also be rotated and its lifetime bounded; `clusterctl` and the CAPI controllers support regeneration. That reduces but does not remove the
concern.

---

## Layer 3 — Data plane

Only relevant when a workload in one cluster must call a workload in another. **Not needed for management.** Defer until a concrete requirement exists.

| Tool | Model | Cost | When to choose |
|---|---|---|---|
| **Cilium Cluster Mesh** | eBPF, global Services, no sidecars | Low, *if already on Cilium* | Default choice when the CNI is Cilium. One flag, native Service semantics. |
| **Linkerd multicluster** | Service mirroring + east-west gateway | Low–medium | Simplest real mesh. Good mTLS story, far less surface than Istio. |
| **Istio multicluster** | multi-primary or primary-remote, east-west gateway | High | Only when Istio's policy/telemetry depth is genuinely required. Significant operational tax. |
| **Submariner** | L3 tunnels + cross-cluster DNS | Medium | Pod-IP-level connectivity without mesh semantics. Useful for stateful/non-HTTP. |
| **Skupper** | L7 application VAN | Low | When you do *not* control cluster networking, or need to span very different networks. |

### The W'xOps-specific consideration

W'xOps routes tenant traffic through **Traefik `IngressRoute`**, with weighted splits via `TraefikService` and header-based routing for Darlane (see
`development-docs/core-ideas/darlane.md`). This is per-cluster north-south routing.

Cross-cluster A/B or Darlane routing — main app in cluster A, Darlane pod in cluster B — would require the split to happen above the cluster boundary. That is a
global load balancer or DNS-level concern, not a mesh concern:

- Global LB (cloud ALB/GLB, Cloudflare) with weighted or header-based rules
  pointing at per-cluster Traefik entrypoints
- Traefik in one cluster with a cross-cluster upstream reachable via Layer 3
  (Submariner / Cluster Mesh / tunnel)

**Recommendation: keep Darlane traffic splitting inside a single cluster.** The existing `priority: 100` header route + `priority: 1` weighted base route design
works because both routes live in one Traefik router table. Spanning that across clusters replaces a well-understood mechanism with a much harder one for no
clear gain — a Darlane pod belongs next to the app it shadows.

---

## Cluster lifecycle with CAPI

CAPI is the right tool for provisioning spokes and is orthogonal to every Layer 1 choice above. Three things it gives that matter here.

### 1. Declarative cluster definitions

`Cluster`, `MachineDeployment`, and infra-provider resources are just Kubernetes objects — so they can be managed by GitOps like anything else, or composed by
Crossplane if cluster creation should be a platform API (`XPlatformCluster`).

### 2. Bootstrap via ClusterResourceSet

`ClusterResourceSet` applies ConfigMaps/Secrets to clusters matching a label selector, at creation. This is the correct place to install everything a spoke
needs to participate:

```yaml
apiVersion: addons.cluster.x-k8s.io/v1beta1
kind: ClusterResourceSet
metadata:
  name: wxops-spoke-bootstrap
spec:
  clusterSelector:
    matchLabels:
      wxops.cloud/role: spoke
  strategy: ApplyOnce
  resources:
    - name: cni-cilium
      kind: ConfigMap
    - name: flux-bootstrap          # Option B
      kind: ConfigMap
    - name: argocd-agent            # Option C
      kind: ConfigMap
    - name: scoped-manager-rbac     # Option A
      kind: ConfigMap
    - name: pinniped-concierge      # human identity path
      kind: ConfigMap
```

Requires the `EXP_CLUSTER_RESOURCE_SET` feature gate. Sveltos is a more capable alternative for ongoing add-on lifecycle (`ApplyOnce` is a real limitation —
`ClusterResourceSet` will not update resources after initial application).

### 3. Apiserver configuration for structured authn

Because CAPI controls `KubeadmControlPlane`, the structured authentication config from Layer 2 can be delivered declaratively:

```yaml
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
spec:
  kubeadmConfigSpec:
    files:
      - path: /etc/kubernetes/authn.yaml
        content: |
          apiVersion: apiserver.config.k8s.io/v1beta1
          kind: AuthenticationConfiguration
          jwt: [...]
    clusterConfiguration:
      apiServer:
        extraArgs:
          authentication-config: /etc/kubernetes/authn.yaml
```

This is the concrete reason CAPI-provisioned spokes do not need Pinniped for the machine path — the capability Concierge substitutes for is directly available.

### 4. Auto-registration

Spokes should register themselves; manual `argocd cluster add` does not scale and reintroduces the cluster-admin default.

| Approach | Fits |
|---|---|
| ArgoCD ApplicationSet **Cluster generator** | Option A/C — generates Applications per registered cluster automatically |
| **Sveltos** reading CAPI `Cluster` objects | Any — add-on distribution keyed on cluster labels |
| Controller minting the ArgoCD cluster Secret from `<cluster>-kubeconfig` | Option A — but propagates the cluster-admin kubeconfig; prefer minting a *scoped* SA token instead |
| Agent self-registration (OCM CSR handshake, argocd-agent enrolment) | Option C — best: the spoke initiates, hub approves |

---

## Darlane across clusters

Darlane is the feature that most constrains the multi-cluster design, because unlike declarative delivery it needs **synchronous, interactive** access to a
spoke pod.

| Darlane capability | Needs | Option A | Option B (Git only) | Option C | +Option D tunnel |
|---|---|---|---|---|---|
| Provision the `-darlane` Deployment | declarative apply | ✅ | ✅ | ✅ | — |
| Scale replicas via XR patch | declarative apply | ✅ | ✅ | ✅ | — |
| `trafficWeight` / header routing | declarative apply (in-cluster Traefik) | ✅ | ✅ | ✅ | — |
| `kubectl exec` into the pod | live API | ✅ | ❌ | ❌ | ✅ |
| `logs -f` | live API | ✅ | ❌ | ❌ | ✅ |
| `port-forward` | live API | ✅ | ❌ | ❌ | ✅ |
| `wxops darlane sync` (mutagen) | live API | ✅ | ❌ | ❌ | ✅ |
| mirrord mirror/steal | live API from the developer's machine | ✅ | ❌ | ❌ | ✅ |
| Telepresence intercept | live API + traffic manager | ✅ | ❌ | ❌ | ✅ |

The pattern is clear: **the declarative half of Darlane works under every option; the interactive half requires Option D regardless of which Layer 1 shape is
chosen.**

Two consequences worth internalising:

1. **Choosing Option B or C does not eliminate the need for spoke access — it
   scopes it.** Instead of a permanent cluster-admin credential used for
   everything, you get a tunnel used only for interactive sessions, ideally with
   per-developer identity and session audit. That is a strictly better security
   posture than Option A, not merely a different one.

2. **mirrord and Telepresence run from the developer's machine, not the hub.**
   The developer needs a path to the spoke API server. A tailnet that includes
   developer laptops handles this naturally; a hub-only tunnel does not. This
   argues specifically for Tailscale or Teleport over OCM cluster-proxy if
   Darlane is a priority — cluster-proxy serves the hub, not laptops.

Combined, the sensible Darlane multi-cluster design is:

```
Declarative (Deployment, routing, TTL)  →  Option B or C  (no hub creds)
Interactive (exec, sync, mirrord)       →  Option D tunnel + Pinniped identity
                                            bound to <appName>-darlane Role
```

---

## Reference architecture 1 — Git-centric

**Thesis:** Git is the only cross-cluster transport for desired state. A tunnel exists solely for interactive developer sessions. The hub holds no standing
spoke credentials.

```
┌─────────────────── HUB ────────────────────┐
│ Portal ── XR ──▶ Crossplane (function-kcl) │
│                     │ renders + commits    │
│ Vault               ▼                      │
│ Gitea ◀────── provider-terraform           │
│   │                                        │
│ Pinniped Supervisor ◀── Gitea OAuth2       │
└───┬────────────────────────┬───────────────┘
    │ git pull (outbound)    │ OIDC
    ▼                        ▼
┌─────────────── SPOKE ──────────────────────┐
│ Flux ──▶ applies manifests                 │
│ Traefik, cert-manager, CNPG, ESO           │
│ Pinniped Concierge ──▶ short-lived certs   │
│ Tailscale operator ──▶ API reachable       │
│                        by portal + laptops │
└────────────────────────────────────────────┘
```

**Components**

| Concern | Choice |
|---|---|
| Cluster lifecycle | CAPI on a separate management cluster (split trust root) |
| Spoke bootstrap | `ClusterResourceSet` → Cilium, Flux, ESO, Concierge, Tailscale |
| Desired state | Crossplane → Gitea → per-spoke Flux |
| Machine identity | None needed for delivery — spokes pull |
| Human identity | Pinniped Supervisor (Gitea OIDC) + Concierge per spoke |
| Interactive access | Tailscale tailnet including developer laptops |
| Status | Flux notifications → webhook → XR status (must be built) |
| Data plane | None initially |

**Adopt when:** security posture is the priority, spokes may be in untrusted or NAT'd networks, teams are comfortable with Git-mediated latency, and you are
willing to build the status-feedback path.

**Main risk:** the status story. XR readiness becomes a project, not a side-effect. Budget for it explicitly.

---

## Reference architecture 2 — ArgoCD hub-spoke with CAPI

**Thesis:** ArgoCD is the fleet control plane. CAPI provisions spokes and configures their apiservers to trust the hub. Privilege is reduced through scoped RBAC
and structured authentication rather than by removing credentials.

```
┌──────────────────── HUB ─────────────────────┐
│ Portal ── XR ──▶ Crossplane                  │
│                  │ providerConfigRef=<spoke> │
│ ArgoCD ◀─────────┘                           │
│   ├─ ApplicationSet (Cluster generator)      │
│   └─ cluster Secrets: scoped, namespaced     │
│ Vault ──▶ spoke credentials via ESO          │
│ Pinniped Supervisor ◀── Gitea OAuth2         │
└───┬──────────────────────────────────────────┘
    │ hub → spoke API (direct, or via tunnel)
    ▼
┌─────────────── SPOKE (CAPI-provisioned) ─────┐
│ apiserver --authentication-config=...        │
│   trusts hub SA issuer → wxops:hub-controllers│
│ ClusterRole: scoped to emitted API groups    │
│ Pinniped Concierge (human path)              │
│ Traefik, cert-manager, CNPG, ESO             │
└──────────────────────────────────────────────┘
```

**Components**

| Concern | Choice |
|---|---|
| Cluster lifecycle | CAPI — accept hub as trusted root, *or* split |
| Spoke bootstrap | `ClusterResourceSet` → CNI, scoped RBAC, authn config, Concierge |
| Desired state | ArgoCD Applications + Crossplane remote `Object`s |
| Registration | ApplicationSet Cluster generator + scoped SA minting (never `argocd cluster add`) |
| Machine identity | Hub projected SA token → spoke `AuthenticationConfiguration` |
| Human identity | Pinniped Supervisor + Concierge |
| Interactive access | Direct if reachable; Tailscale/Teleport if not |
| Status | Native — `Object` status → XR `status.ready` |
| Data plane | Cilium Cluster Mesh when needed |

**Adopt when:** operational visibility and immediate convergence matter most, spoke API servers are reachable over a controlled network, and the team can own
credential and rotation hygiene.

**Migration note:** this is the *incremental* path. It is the current architecture plus a `cluster` parameter plus per-spoke `ProviderConfig`s. Option C
(argocd-agent or OCM) is a natural later evolution that removes the credential question without changing the composition shape much — particularly OCM's
`ManifestWork`, which keeps `InjectedIdentity` on the hub.

---

## Choosing between them

| Dimension | Arch 1 (Git-centric) | Arch 2 (ArgoCD hub-spoke) |
|---|---|---|
| Hub holds spoke credentials | No | Yes, scoped |
| Spoke inbound required | No | Yes (or tunnel) |
| Convergence latency | Poll interval | Immediate |
| XR status fidelity | Must be built | Native |
| Single pane of glass | Weak | Strong |
| Blast radius of hub compromise | Small | Fleet-wide (mitigated) |
| Works across clouds / NAT / air-gap | Yes | Only with tunnel |
| Delta from today's codebase | Large | Small |
| Darlane interactive support | Needs tunnel | Needs tunnel |
| Operational surface | Flux per spoke | Credentials + rotation |

**If forced to pick one for W'xOps:** start with **Arch 2**, because the delta from the current codebase is a `cluster` parameter and per-spoke
`ProviderConfig`s rather than a rewrite of how compositions emit resources — and the XR status mechanism already documented for this repo keeps working. Then
migrate the delivery path to **OCM `ManifestWork`** (Option C) once fleet size or security review makes standing credentials untenable. That migration preserves
both the composition shape and status feedback, which is exactly what Arch 1 sacrifices.

Adopt Arch 1 outright if spokes will live in networks the hub cannot reach, or if "no standing credentials" is a hard compliance requirement rather than a
preference.

---

## Migration path

### Phase 0 — Single-cluster prerequisites

Do these before any multi-cluster work. All are useful on their own.

- Author the Darlane `Role` + `RoleBinding` **in the GitOps repo**, bound to the
  ServiceAccount name the composition publishes at
  `status.darlane.serviceAccountName`. Core does not emit RBAC by design, so this
  step lives outside this repository — but without it there is no authorisation
  surface for federated identity to bind to.

Note `pods/exec` cannot be restricted to a single Deployment by RBAC, so a Darlane shell grant is namespace-wide however it is authored. Size tenant namespaces
accordingly.
- Replace the 12 hardcoded `providerConfigRef = {name = "default"}` in
  `kcl/tenant-app/main.k` with a single `targetCluster` variable, defaulting to
  `"default"`. Behaviour-neutral today; unblocks everything later. Repeat for
  `platform-database-clusters` and `tenant-database`.
- Add `cluster` to the XRDs as an optional string with a CEL validation or enum.
- Audit `providers/rbac-provider-kubernetes.yaml` and extract the minimum
  ClusterRole a spoke actually needs.
- Decide the CAPI trust-root question — accept or split — and write it down.

### Phase 1 — One spoke, push mode

- CAPI management cluster, one spoke provisioned.
- `ClusterResourceSet` installing CNI, ESO, Traefik, cert-manager, scoped RBAC.
- One `ProviderConfig` for the spoke, credential from Vault via ESO.
- Deploy one non-production `XTenantApp` with `cluster: spoke-dev-1`.
- Verify: XR status still reflects reality; Terraform state does not collide.

### Phase 2 — Identity hardening

- Structured `AuthenticationConfiguration` on the spoke via
  `KubeadmControlPlane`, trusting the hub SA issuer.
- Remove the static SA token; hub authenticates with a projected token.
- Pinniped Supervisor on the hub, federated to Gitea; Concierge on the spoke.
- Portal performs Darlane `exec` as the developer, not as the platform.
- Verify: spoke audit log attributes actions to named users.

### Phase 3 — Interactive access and scale-out

- Tailscale operator (or Teleport) on spokes; tailnet includes developer laptops.
- Validate the full Darlane loop cross-cluster: scale up, sync, mirrord mirror,
  header-routed request, scale down.
- Add spokes 2..N via ApplicationSet Cluster generator — no manual registration.

### Phase 4 — Reduce standing credentials (optional)

- Introduce OCM: `klusterlet` on spokes, hub emits `ManifestWork`.
- Compositions switch from remote `Object` to local `ManifestWork`; hub returns
  to `InjectedIdentity`.
- Retire per-spoke `ProviderConfig`s and their credentials.

### Phase 5 — Data plane (only if required)

- Cilium Cluster Mesh, when a concrete cross-cluster service call exists.

---

## Decisions to make before building

These are expensive to reverse. Decide deliberately.

**1. Is the target cluster an XR parameter, or a hub-side boundary?**

`spec.parameters.cluster: prod-sgn` on a single composition, versus a separate hub namespace / `Configuration` / Crossplane instance per spoke.

The parameter is simpler and fits a portal where a tenant picks an environment from a dropdown. The boundary approach gives cleaner RBAC and blast-radius
isolation on the hub, at the cost of N× the hub-side machinery. **Parameter is the likely right answer** given the portal direction — but it means every
composed resource must thread `providerConfigRef`, and a bug there silently lands tenant resources on the hub. Validate at the XRD boundary.

**2. Does an app's database live in the same cluster as the app?**

`tenant-app` can emit a composed `XTenantDatabase`, which `tenant-database` resolves against shared clusters discovered by `function-extra-resources` with a
label selector. Cross-cluster this becomes ambiguous: does the extra-resources lookup search the hub, the app's spoke, or a dedicated data cluster?

Simplest coherent answer: **databases are per-spoke**, `platform-database-clusters` runs on each spoke, and `function-extra-resources` searches the hub for
`XPlatformDatabaseCluster` XRs whose labels record which spoke they live on. Any other answer needs a cross-cluster discovery mechanism that does not exist
today.

**3. One Vault, or one `ClusterSecretStore` per spoke?**

The current path convention (`{owner}/databases/{dbName}/...`, store scoped to the KV mount) has no cluster dimension. Either add one
(`{cluster}/{owner}/databases/...` — a breaking change to every remoteKey) or keep one logical namespace and accept that two spokes could write the same path.
Decide before the first spoke, because migrating Vault paths later is painful.

**4. Hub as CAPI management cluster, or split?**

See [The CAPI trust-root problem](#the-capi-trust-root-problem). This is a security-posture decision that constrains everything else.

**5. Is a single pane of glass a requirement or a preference?**

If it is a requirement, Arch 1 needs a status-feedback project. If it is a preference, Arch 1 becomes much cheaper.

---

## Out of scope

- **Cross-cluster Darlane traffic splitting.** Deliberately excluded — a Darlane
  pod belongs in the same cluster as the app it shadows.
- **`XPlatformCluster` XRD** — composing CAPI clusters as a platform API. Would
  belong in a new package, and only makes sense after cluster provisioning is
  stable manually.
- **Multi-region data replication.** CNPG cross-cluster replication is a distinct
  problem with its own failure modes.
- **Hub high availability / hub failover.** Relevant for Arch 2, where the hub is
  in the reconciliation path.
- **Cost attribution across clusters.** The `wxops.cloud/environment` and
  `wxops.cloud/app-flavor` labels are the hook; the aggregation layer is not
  designed.
- **Tenant-facing cluster selection UX.** Whether tenants choose a cluster or the
  platform places them (OCM `Placement`, or policy) is a portal design question.

---

## References

**Control plane**
- [argoproj-labs/argocd-agent](https://github.com/argoproj-labs/argocd-agent)
- [Argo CD Agent architecture — Red Hat OpenShift GitOps 1.19](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.19/html/argo_cd_agent_architecture/argocd-agent-architecture)
- [Argo CD — Declarative Setup (cluster Secrets)](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
- [Argo CD — ApplicationSet Cluster Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/)
- [Open Cluster Management](https://open-cluster-management.io/)

**Identity**
- [Kubernetes — Authenticating (structured authentication config)](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Kubernetes 1.30: Structured Authentication Configuration Moves to Beta](https://kubernetes.io/blog/2024/04/25/structured-authentication-moves-to-beta/)
- [JWT it like it's hot: a practical guide for Kubernetes Structured Authentication](https://opensource.microsoft.com/blog/2025/05/08/jwt-it-like-its-hot-a-practical-guide-for-kubernetes-structured-authentication/)
- [Structured Authentication Config — KEP-3331](https://github.com/kubernetes/enhancements/issues/3331)
- [Pinniped — Using Pinniped for CI/CD cluster operations](https://pinniped.dev/docs/howto/cicd/) — the `cli_password` non-interactive flow
- [Pinniped — Tokens and credentials](https://pinniped.dev/docs/reference/tokens-and-credentials/)
- [Pinniped releases](https://github.com/vmware/pinniped/releases/)
- [Argo CD — exec plugin returning bad version (#6749)](https://github.com/argoproj/argo-cd/issues/6749)
- [Argo CD — connect clusters via OIDC client credentials flow (#26776)](https://github.com/argoproj/argo-cd/discussions/26776)
- [Simplify Amazon EKS multi-cluster authentication with Pinniped](https://aws.amazon.com/blogs/opensource/simplify-amazon-eks-multi-cluster-authentication-with-open-source-pinniped/)

**Lifecycle**
- [Cluster API — ClusterResourceSet](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-resource-set)
- [Sveltos](https://projectsveltos.github.io/sveltos/)

**Internal**
- [`development-docs/core-ideas/darlane.md`](darlane.md) — the interactive workflows that constrain this design
- [`development-docs/core-ideas/guardian.md`](guardian.md) — safety layer for Darlane sessions
- [`docs/api-reference/tenant-app.md`](../../docs/api-reference/tenant-app.md) — `XTenantApp` API reference
- [`providers/`](../../providers) — current single-cluster `ProviderConfig` and RBAC
