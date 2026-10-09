# Multi-Cluster Proposal — the chosen path

> **Status: proposal, not implemented.** [`multi-cluster.md`](multi-cluster.md) presents the full option space without prescribing; this document is the
> prescription — one concrete architecture, one prototype, and the decisions locked (or explicitly left open) to build it. Where the two documents disagree,
> this one is newer and wins; where this one is silent, the research doc is the reference.

The shape in one paragraph: **CAPI provisions spokes, ArgoCD hub-spoke delivers to them, structured authentication replaces standing credentials on the machine
path, Pinniped serves the human path only, a tunnel serves Darlane, and k8gb + ExternalDNS provide multi-region DNS-based routing on top.** OCM `ManifestWork`
is the planned second step, not the first.

```
                         ┌────────────── DNS (delegated zone) ──────────────┐
                         │  apps.wxops.cloud → k8gb CoreDNS per region      │
                         │  strategy: failover | roundRobin | geoip         │
                         └───────┬──────────────────────────┬───────────────┘
                                 │                          │
┌──────────────── HUB ───────────┼──┐      ┌────────────────┼────────────────┐
│ Portal ── XR (cluster: sgn) ─▶ │  │      │                │                │
│ Crossplane ── providerConfigRef┼──┼──┐   │                │                │
│ ArgoCD ApplicationSet          │  │  │   │                │                │
│   (Cluster generator)          │  │  │   │                │                │
│ CAPI (management)              │  │  │   │                │                │
│ Pinniped Supervisor ◀─ Gitea   │  │  │   │                │                │
│ Vault ── ESO                   │  │  │   │                │                │
└────────────────────────────────┘  │  │   │                │                │
                                    │  ▼   ▼                ▼                │
                          ┌─────── SPOKE sgn ──────┐ ┌─── SPOKE hcm ────────┐
                          │ apiserver:              │ │ (same shape)         │
                          │  --authentication-config│ │                      │
                          │  trusts hub SA issuer   │ │                      │
                          │ scoped ClusterRole      │ │                      │
                          │ Traefik · cert-manager  │ │                      │
                          │ CNPG · ESO · Concierge  │ │                      │
                          │ k8gb + CoreDNS          │ │                      │
                          │ Tailscale (Darlane)     │ │                      │
                          └─────────────────────────┘ └──────────────────────┘
```

---

## Why this shape

**Reference architecture 2, for the reason the research doc already gives:** the delta from today's codebase is a `cluster` parameter plus per-spoke
`ProviderConfig`s, and XR status keeps working natively — the two things Arch 1 (Git-centric) sacrifices. Arch 1's triggers (spokes the hub cannot reach, hard
no-standing-credentials compliance) do not currently apply.

**And the delta is smaller than the research doc says**, because that doc predates the v0.4.0 API freeze. Its Phase 0 prerequisites are mostly done:

| Prerequisite (multi-cluster.md §Migration path) | State |
|---|---|
| `targetCluster` variable replacing hardcoded `providerConfigRef` | ✅ Done — 30 sites across all three KCL packages |
| `spec.parameters.cluster` XRD field | ✅ Done — `tenant-app`, `tenant-database`, `platform-database-clusters` |
| XR status the portal can trust | ✅ Done — `created`/`ready` on all seven packages ([status-contract.md](../../docs/api-reference/status-contract.md)) |
| Darlane RBAC binding target | ✅ Done — `status.darlane.serviceAccountName`; binding authored in GitOps |
| Per-spoke `ProviderConfig` + credential | ❌ The actual remaining gap |
| Spoke exists at all | ❌ The prototype |

What remains is genuinely small: stand up a spoke, mint one scoped credential, create one `ProviderConfig` named after the cluster, and set `cluster: <name>` on
an XR.

### The join mechanism: CAPI + ArgoCD now, OCM later — not Karmada, not Fleet

CAPI and the delivery tools are not competitors — **CAPI is lifecycle, the others are delivery** — so "CAPI or Karmada or Fleet" is really "CAPI, plus which
delivery mechanism":

| Candidate | Verdict | Why |
|---|---|---|
| **CAPI** (lifecycle) | ✅ Adopt | Declarative clusters, `ClusterResourceSet` bootstrap, and — decisively — control of apiserver flags, which is what makes structured authn possible |
| **ArgoCD hub-spoke** (delivery) | ✅ Adopt for the prototype | Already in the stack; smallest delta; native status |
| **OCM `ManifestWork`** (delivery) | ⏭ Planned evolution, not step 1 | Best structural end-state for a Crossplane platform — compositions emit `ManifestWork` locally under `InjectedIdentity`, no spoke credentials on the hub, per-resource status flows back. Deferred because its concept surface (`ManagedCluster`, `Placement`, addon framework) is too much for a first prototype |
| **Karmada** | ❌ Rejected | Its `PropagationPolicy` wants to be the fleet API. W'xOps's fleet API is Crossplane XRs — two "one API to rule them all" systems fight, and ours is already built |
| **Rancher Fleet** | ❌ Rejected | Solid but Rancher-flavoured; adopts a second GitOps engine alongside ArgoCD for no capability we lack |
| **Sveltos** | ⚪ Optional later | Not a delivery mechanism; a better `ClusterResourceSet` (which is `ApplyOnce`-only). Adopt if spoke add-on lifecycle becomes painful |

**Fan-out stays out of the compositions.** One XR targets one cluster; running an app in two regions is two XRs (portal- or GitOps-driven). Rebuilding
Karmada-style propagation inside KCL is exactly the trap the Karmada rejection avoids.

---

## Identity — who does what

The stack was described as "ArgoCD (GitOps), Pinniped (Authen and Identity)" — this proposal deliberately narrows Pinniped's job, per the research doc's
analysis:

| Path | Mechanism | Pinniped involved? |
|---|---|---|
| **Machine: hub → spoke** (Crossplane, ArgoCD) | Spoke apiserver `AuthenticationConfiguration` trusts the hub's SA issuer; hub controllers present **projected** SA tokens (audience- and TTL-bound). Bound to a scoped ClusterRole covering only the API groups compositions emit. | **No** — CAPI-provisioned spokes have apiserver flag control, which is precisely the case where Concierge adds nothing |
| **Human: developer → spoke** (Darlane, kubectl) | Pinniped Supervisor on the hub federates Gitea OIDC → Concierge per spoke exchanges tokens for short-lived mTLS certs → RBAC binds to the developer, targeting `status.darlane.serviceAccountName`'s namespace | **Yes** — this is Pinniped's whole job here |
| **Interactive transport** (exec, logs, sync, mirrord) | Tailscale tailnet including developer laptops (Teleport if session recording becomes a requirement) | Identity still Pinniped; the tunnel is only reachability |

Machine-path notes that will bite if forgotten:

- Structured authn is **GA in Kubernetes 1.35**, beta (on by default) since
  1.30 — check the spoke's minor for `v1` vs `v1beta1`.
- The hub's SA issuer must be **OIDC-discoverable from the spoke**
  (`/.well-known/openid-configuration` + JWKS). Private hub ⇒ publish or
  mirror those two endpoints.
- ArgoCD's inline `bearerToken` cannot express a rotating projected-token
  file — the ArgoCD cluster Secret needs the `execProviderConfig` form (the
  brokerless variant from multi-cluster.md §Option A2). Crossplane's
  `ProviderConfig` has the same constraint on credential source.
- If a **managed** spoke (EKS/GKE/AKS) ever joins the fleet, that spoke can't
  do structured authn — Concierge then serves its machine path too. The
  design degrades gracefully; nothing to pre-build.

**Never `argocd cluster add`** — registration is ApplicationSet Cluster generator over declaratively minted, scoped cluster Secrets.

---

## Multi-region routing — k8gb and ExternalDNS together

They solve different problems and the k8gb docs themselves recommend running both:

| Tool | Job here |
|---|---|
| **k8gb** | The actual GSLB. Each region runs k8gb + CoreDNS serving a delegated zone (e.g. `apps.wxops.cloud`); each answers only with its region's *healthy* endpoints; cross-region health via DNS between the k8gb CoreDNS instances. Strategies: `failover`, `roundRobin`, `geoip`. |
| **ExternalDNS** | Ordinary record management: per-cluster infra hostnames (`argocd.hub…`, `grafana.sgn…`) and maintaining the parent-zone NS delegation that points at the k8gb CoreDNS services. One `--txt-owner-id` per cluster so two clusters never fight over a record. |

Why this fits the platform's constraints: DNS-layer routing needs **no service mesh and no cross-cluster pod networking** — Layer 3 stays deferred, exactly as
the research doc argues. The only new network requirement is that each region's k8gb CoreDNS is reachable (LoadBalancer) for zone queries and cross-cluster
health checks.

**Platform default: `failover`, not `roundRobin`.** Two reasons:

1. **TTL honesty.** DNS failover converges in seconds-to-minutes (TTL +
   resolver behaviour), which is fine for region failover and wrong to sell as
   instant traffic steering.
2. **Darlane sticky sessions.** `darlane.stickySession` pins A/B assignment
   with a per-cluster cookie. Under `roundRobin`, a client can resolve to the
   other region mid-session and lose its assignment — the weighted-split
   guarantees only hold within one cluster. `failover` keeps all traffic in
   one region until it is unhealthy, sidestepping this entirely. Apps that
   genuinely want active-active opt in per-app.

### ⚠ The Traefik wrinkle — spike before committing

k8gb's integration model keys off standard `Ingress` objects, and **v0.3.0 migrated `tenant-app` from `Ingress` to Traefik `IngressRoute`** — so the default
k8gb path does not line up 1:1 with what the composition emits today. Whether current k8gb versions can reference Traefik CRDs (or need a standalone `Gslb` CR
with its own service health reference) is **unverified — this is the prototype's first spike**, and the outcome decides the shape of the composition work below.
Do not design past this unknown.

### Future composition work (after the spike)

An `ingress.gslb` block on `tenant-app`, following exactly the pattern the `monitoring` block established in v0.4.0 — optional object, `enabled` toggle,
conditional emission of one more wrapped CR, provider RBAC extended with k8gb's API group (`k8gb.absa.oss`):

```yaml
ingress:
  host: payment-api.apps.wxops.cloud   # same host on every region's XR
  gslb:
    enabled: true
    strategy: failover        # failover | roundRobin | geoip
    primaryGeoTag: sgn        # failover only
```

Same host + one XR per region + per-region `Gslb` health = the multi-region story, with zero new concepts in the XRD beyond one nested block. Remember the
lesson the monitoring work taught: a new emitted kind means a provider RBAC grant (`k8gb.absa.oss`) applied manually per cluster, and a golden test case per
branch.

---

## The prototype

**Scope: one hub + two spokes (two regions), one demo app served under the delegated zone, one Darlane session against a spoke.** Everything below exists
already except the items marked ❌.

| # | Piece | Exists? |
|---|---|---|
| 1 | CAPI on the hub (accepting the hub-as-trust-root posture for the prototype; revisit split per multi-cluster.md §CAPI trust-root before production) | ❌ install |
| 2 | Two `Cluster` + `KubeadmControlPlane` definitions with the structured-authn `AuthenticationConfiguration` file and `--authentication-config` flag baked in via `kubeadmConfigSpec.files` | ❌ write |
| 3 | `ClusterResourceSet` (label `wxops.cloud/role: spoke`): CNI, Traefik, cert-manager, ESO, Pinniped Concierge, k8gb, Tailscale operator, and the scoped ClusterRole + `ClusterRoleBinding` for `wxops:hub-controllers` | ❌ write (contents are all standard installs) |
| 4 | Per-spoke `ProviderConfig` named after the cluster, credentials via projected-token exec form | ❌ write — the one true code gap |
| 5 | ArgoCD ApplicationSet Cluster generator + declaratively minted scoped cluster Secrets | ❌ write |
| 6 | `spec.parameters.cluster` on the XR | ✅ v0.4.0 |
| 7 | `providerConfigRef` threading in compositions | ✅ v0.4.0 |
| 8 | XR status the portal can poll cross-cluster | ✅ v0.4.0 (`Object` status flows back regardless of target cluster) |
| 9 | Delegated DNS zone + parent NS records via ExternalDNS | ❌ configure |
| 10 | k8gb ↔ Traefik spike (see above) | ❌ **do first** |

**Exit criteria** — the prototype is done when:

1. `kubectl apply` of a `tenant-app` XR with `cluster: spoke-sgn` on the hub
   produces a running app **on the spoke**, and `status.ready` flips true **on
   the hub** with no hub-side static spoke credential involved.
2. The same app applied to both spokes resolves via `apps.wxops.cloud`, and
   killing the primary region's app flips DNS answers to the second region
   within TTL.
3. A developer authenticates through Pinniped (Gitea identity), reaches the
   spoke over the tailnet, and can `exec` into the Darlane pod — but cannot
   touch the production Deployment's namespace beyond what the GitOps-authored
   Role grants.
4. `argocd cluster add` was never run.

---

## Decisions — locked and open

Locked by this proposal (rationale in [`multi-cluster.md`](multi-cluster.md) §Decisions unless noted):

| Decision | Locked answer |
|---|---|
| Target cluster: XR parameter vs hub boundary | **Parameter** — already shipped in v0.4.0 |
| Databases per spoke or centralized | **Per-spoke**; `function-extra-resources` keeps searching the hub for `XPlatformDatabaseCluster` XRs labelled with their spoke |
| Delivery mechanism | **ArgoCD hub-spoke now, OCM `ManifestWork` when fleet size or security review demands credential removal** |
| Machine identity | **Structured authn**; Pinniped machine-path only for managed spokes if any join |
| Interactive access | **Tailscale** (laptops included); Teleport if session audit becomes a requirement |
| GSLB default strategy | **`failover`**; active-active per-app opt-in |
| Fan-out | **Portal/GitOps concern, one XR per cluster** — never composition-side propagation |

Open — decide before the first *production* spoke, not before the prototype:

1. **Vault path cluster dimension.** Current remoteKeys have no cluster
   segment; two spokes could collide. Adding `{cluster}/` is a breaking change
   to every remoteKey — cheapest now, painful later. (The prototype can defer
   it only because demo data is disposable.)
2. **CAPI trust root** — hub-as-management-cluster is accepted for the
   prototype; production needs the deliberate accept-or-split decision.
3. **Delegated zone name** and who owns the parent zone's NS records.
4. **`ingress.gslb` schema** — blocked on the Traefik spike.

---

## See also

- [`multi-cluster.md`](multi-cluster.md) — the full option space and the
  reasoning this proposal selects from
- [`multi-cluster-connectivity.md`](multi-cluster-connectivity.md) — how the
  hub→spoke API connection is actually secured: the three trust paths this
  proposal opens, the enrollment order for item 4, and the fallback path for
  spokes CAPI did **not** provision
- [`multi-cluster-scale.md`](multi-cluster-scale.md) — what lies beyond this
  prototype: regions at scale, tenancy tiers, arm64/GPU hardware, edge fleets
- [`status-contract.md`](../../docs/api-reference/status-contract.md) — the status fields that make
  cross-cluster XRs observable from the hub
- [`darlane.md`](darlane.md) — the interactive workflows that force the tunnel
- [k8gb](https://www.k8gb.io/) · [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) — the multi-region layer
