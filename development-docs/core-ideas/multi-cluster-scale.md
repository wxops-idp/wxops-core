# Multi-Cluster at Scale — regions, tenants, and heterogeneous hardware

> **Status: research, not implemented.** Third document in the multi-cluster family: [`multi-cluster.md`](multi-cluster.md) is the option space,
> [`multi-cluster-proposal.md`](multi-cluster-proposal.md) is the chosen path and prototype, and this document is what lies *beyond* the prototype — the three
> axes a platform grows along when it serves a genuinely large project, the tooling landscape for each, and what each axis concretely demands from W'xOps Core.
> Nothing here changes the proposal; it maps the territory the proposal grows into.

Scale is not one axis. Three independent dimensions get conflated under "multi-cluster at scale", and each has its own tools, failure modes, and breaking
points:

```
                        WHERE does it run?
                        Axis 1 — Regions
                        k8gb · ExternalDNS · CNPG replicas · Vault topology
                              │
                              │
   WHO shares it? ────────────┼──────────── WHAT does it run on?
   Axis 2 — Tenancy           │             Axis 3 — Hardware
   namespace → vcluster →     │             amd64 core · arm64 edge
   hosted CP → dedicated      │             k3s · KubeEdge · Talos
   Capsule · vCluster ·       │             multi-arch images ·
   Kamaji · kcp               │             kubernetes.io/arch
```

A platform can be large on one axis and small on the others — 40 regions with one tenant each, or one region with 400 tenants, or 3 regions with 2,000 ARM edge
sites. The architecture that serves each corner is different, which is why "how do we scale multi-cluster" has no single answer.

---

## Axis 1 — Multi-region beyond the prototype

The proposal's k8gb + ExternalDNS layer handles the *stateless* half of multi-region: same app in N regions, DNS steers clients to a healthy one. What it
deliberately does not touch is state — and **state is where multi-region actually gets hard.**

### The data layer decides the region strategy, not the other way round

| Posture | Mechanism | RPO/RTO shape | Fit |
|---|---|---|---|
| **Region-pinned data** (each tenant's data lives in exactly one region) | CNPG per spoke, exactly as today; region is a tenant attribute | No cross-region RPO at all — a region loss takes its tenants down until restore | The default. Also what data-residency law usually *requires* |
| **Primary + cross-region replica** | CNPG replica clusters — a designated primary in one region, async replicas in others, promotion on failure | RPO = replication lag (seconds), RTO = detection + promote (minutes, and promotion is an operational act, not automatic) | DR for tenants who pay for it — maps onto the existing `tier:` concept |
| **Active-active distributed SQL** | CockroachDB, YugabyteDB — consensus-replicated across regions | RPO ≈ 0, but write latency includes cross-region consensus, and it is **not PostgreSQL-compatible enough to be a drop-in** for CNPG-shaped workloads | Only when a workload genuinely needs multi-region writes. A different platform service, not a CNPG replacement |

The honest default for W'xOps: **region-pinned, with replica-cluster DR as a paid tier.** This is the least architecture and it matches the most common real
constraint — data residency (a German tenant's data must stay in a German region) is a stronger multi-region driver in practice than latency is.

### The supporting decision that arrives with region three

**Vault topology.** One Vault reachable from all spokes (single point of failure and a latency tax), or one Vault per region with ESO per cluster (operational
N×, path-collision question from the proposal's open decision
#1 becomes mandatory). Vault Enterprise performance replicas solve this
cleanly but are paid; the OSS answer is per-region Vault with the `{cluster}/` path dimension decided *before* region two.

### GSLB implementations — three options, one field-tested

The proposal picks k8gb, but it is one of three shapes, and the second has already been run in production on this platform's own infrastructure (see the field
notes in References):

| Option | How | Trade |
|---|---|---|
| **k8gb** (self-hosted) | Per-cluster CoreDNS serving a delegated zone, health-aware answers | Provider-neutral, no cloud dependency; you run the DNS infra; the Traefik-integration spike from the proposal still applies |
| **ExternalDNS + cloud DNS routing policies** — *field-tested* | ExternalDNS annotations drive Route 53 (or Alibaba DNS/GTM) native policies: `aws-region` for latency-based, `aws-failover` PRIMARY/SECONDARY, `aws-weight` for splits, plus Route 53 health checks | No extra runtime component at all — the cloud DNS *is* the GSLB. Measured on this platform's own fleet: ~39 s average failover recovery, ~1 ms proximate-region responses. Cost: provider lock-in, and the pitfalls below |
| **Anycast / global LB** (Cloudflare, AWS Global Accelerator, GCP GLB) | Steering above DNS entirely | The answer when TTL-bounded failover stops being acceptable; a CDN/network decision, not a Kubernetes one — flag it, don't pre-build it |

The field-tested pitfalls from option 2, so they aren't relearned: `external-dns.alpha.kubernetes.io/access: public` is required or ExternalDNS publishes
private node IPs; Route 53 RRSETs cannot mix CNAME and A records, so health checks must target IPs; and per-cluster `txtOwnerId`/`txtPrefix` is what stops two
clusters fighting over one hostname — the same ownership rule the proposal states, confirmed the hard way.

For W'xOps the sequencing writes itself: **option 2 first** (ExternalDNS is already in the proposal for NS delegation — using its routing annotations costs
nothing new and is proven on this stack), **k8gb when provider neutrality matters**, anycast when a real traffic requirement forces it.

### Hub scale — where the proposal's push model runs out

The proposal is honest that ArgoCD hub-spoke is chosen for its small delta, not its ceiling. The ceiling is real: one hub reconciling every XR for every spoke
puts the hub in the availability path of the whole fleet, per-spoke credentials multiply, and a single ArgoCD instance needs controller sharding well before the
fleet reaches three digits. The doc family already names the exit: **OCM `ManifestWork`** — spokes pull, hub holds no credentials, compositions change
minimally. The scale point reinforces the sequencing: *push to start, pull to scale.* Karmada re-enters conversations at this size too, and the rejection holds
for the same reason as before — its propagation API competes with the XR as the fleet API.

---

## Axis 2 — Multi-tenancy: the isolation spectrum

W'xOps today is **namespace-as-tenant**: `tenant-app` deploys into a tenant namespace on a shared cluster, Kyverno policies fence it, and `tenant-database`
already expresses the key idea this axis generalises — **`tier: shared | dedicated` is a tenancy spectrum in miniature.** Scaling tenancy is extending that same
spectrum upward from the database to the whole compute environment:

| Isolation tier | What the tenant gets | Tooling | Cost per tenant | W'xOps mapping |
|---|---|---|---|---|
| **Namespace** (today) | Namespace(s) + quotas + NetworkPolicy + Kyverno fencing | **Capsule** formalises exactly this — a `Tenant` CRD spanning namespaces with shared RBAC/quota/policy | ~zero | Current model; Capsule would replace hand-rolled fencing, not the compositions |
| **Virtual control plane** | Own API server, own CRDs, own RBAC universe — as a pod on the shared cluster | **vCluster** (CNCF-certified virtual clusters; the 2026 platform adds dedicated "private nodes"), **k3k** (k3s-in-k3s) | One control-plane pod | The interesting middle: a tenant who needs to install their *own* operators/CRDs without touching the shared cluster's API surface |
| **Hosted control plane + dedicated nodes** | Real control plane (as pods on a management cluster) + worker pool that is theirs alone | **Kamaji** — and decisively, Kamaji is a **CAPI control-plane provider**, so it slots into the proposal's CAPI machinery instead of adding a parallel system | Control-plane pods + N workers | The "dedicated" tier grown up: cheap control planes (no 3-VM etcd tax per tenant), physical worker isolation |
| **Dedicated cluster** | A whole spoke | CAPI, exactly as the proposal provisions spokes | Full cluster | `XPlatformCluster` (already named as out-of-scope in the research doc) becomes the tenancy API: `tier: dedicated` at cluster scope |
| **API-only workspace** | A Kubernetes-style API surface with no nodes at all | **kcp** — workspaces as logical clusters. Note: kcp dropped workload scheduling in its 2023 restructure; it is an API control plane, not a workload platform | API server share | Niche for W'xOps; relevant only if the portal ever needs per-tenant *API* isolation without compute |

Three observations that matter more than the table:

1. **The spectrum is a product decision wearing an architecture costume.** Each
   tier is a price point. The platform work is making tier movement cheap —
   which is exactly what the XR-parameter pattern already does for databases
   (`tier: shared → dedicated` is a field change). The end-state worth aiming
   at: the same move at compute scope, `XTenantApp` unchanged, only *where* it
   lands differing.
2. **Kamaji + CAPI is the standout combination for this stack.** The proposal
   already commits to CAPI; Kamaji turning tenant control planes into pods on
   the hub means "dedicated-ish" tenants and small edge-site clusters stop
   costing three control-plane VMs each. Same lifecycle API, same
   `ClusterResourceSet` bootstrap, same structured-authn story.
3. **vCluster's sweet spot is CRD freedom, not security.** A tenant wanting to
   install their own operators is the real trigger. If the driver is security
   isolation, the honest answers are dedicated nodes (Kamaji tier) or a
   dedicated cluster — a virtual control plane still shares the host kernel
   and kubelet.

---

## Axis 3 — Heterogeneous hardware: amd64 core, arm64 edge

The axis the current docs don't touch at all, and the one with three already-verified gaps in this repo.

### The two rules of mixed-architecture fleets

1. **If every image is a multi-arch manifest list, scheduling needs nothing
   special.** `docker buildx` (or ko/BuildKit equivalents) publishes one tag
   referencing per-arch variants; each node pulls its own. This is the state
   to drive toward, because it makes architecture disappear as a scheduling
   concern.
2. **Any single-arch image in a mixed cluster is a landmine.** The failure
   mode is `ImagePullBackOff`-adjacent (or worse, `exec format error` at
   runtime) on the wrong-arch node — and it fails *per-pod, per-schedule*,
   i.e. intermittently. The mitigation while any single-arch image exists is
   explicit `nodeSelector: kubernetes.io/arch: amd64` (or affinity) on those
   workloads, plus tainting minority-arch node pools so nothing lands there by
   accident.

### The verified W'xOps gaps

| Gap | State (checked 2026-08-22) | Fix shape |
|---|---|---|
| **No scheduling fields in any XRD.** `tenant-app` and `platform-database-clusters` expose no `nodeSelector`, `tolerations`, or `affinity` — a tenant cannot target an arm64 pool, avoid one, or tolerate an edge taint | Verified: zero matches in both XRDs | Additive `scheduling:` block (`nodeSelector`, `tolerations`, `topologySpreadConstraints`) threaded to the Deployment / CNPG `Cluster` — `safe`-tier change, same pattern as `monitoring`; CNPG natively accepts affinity so the DB package threads it too |
| **No stated multi-arch posture.** Nothing in CI or docs says whether tenant images or the platform's own components are expected to be multi-arch | Verified: no arch handling in either publish workflow | Configuration `.xpkg` content is YAML — arch-neutral, nothing to do. The real requirements are (a) tenant images multi-arch or explicitly pinned via the new `scheduling` block, and (b) if a hub or spoke ever runs on arm64, the provider/function pods must have arm64 variants — upstream crossplane-contrib images generally do, but **verify per pinned version** before an ARM spoke exists |

### GPU pools — the third architecture, already field-tested here

Heterogeneity is not only CPU ISA. A GPU node pool behaves like a third architecture — scarce, expensive, taint-fenced, and with its own sharing mechanics — and
this platform has already run it multi-region (VNG Cloud A40s
+ Alibaba Cloud L20s; field notes in References). What that experience
established:

- **Sharing mechanics are provider-specific.** Alibaba's native cGPU memory
  isolation outperformed the generic GPU Operator path for inference; on VNG,
  GPU Operator + HAMi vGPU sharing was the workable combination. There is no
  provider-neutral answer worth pretending exists — the `scheduling:` block
  below plus per-pool taints is the portable part; the sharing layer is
  chosen per provider.
- **Replicated-per-cluster beats service-splitting for stateful GPU
  workloads** — each region runs the full inference stack, GSLB steers. This
  is the same region-pinned posture as Axis 1's data default, arrived at
  independently.
- **Custom orchestration was evaluated and rejected twice** — a
  CRD-plus-SSH-tunnel operator (months of build, permanent maintenance) and
  Virtual Kubelet (production-stability concerns). Managed, provider-native
  paths won. This is the same conclusion as this repo's founding
  "no hand-written controllers" rule, reached independently on different
  ground — worth noting because it is now a twice-validated instinct.

For the XRD, GPU adds a **third verified gap** alongside the two below: `tenant-app`'s `resources` schema permits only `cpu` and `memory` — an extended resource
like `nvidia.com/gpu` in `limits` would be **silently pruned** by the API server as an unknown field (checked 2026-08-22; the description says "passed through
verbatim", but the schema closes it). Widening `requests`/`limits` to accept extended-resource keys is a `safe` additive change, and a prerequisite for any GPU
tenant.

### Edge distributions — what actually runs at an ARM site

| Distribution | Footprint | Model | When |
|---|---|---|---|
| **k3s** | single binary < 100 MB, runs in ~512 MB RAM | Full conformant cluster per site | The default for "a real cluster, but small" — depot/site autonomy, works offline, has a CAPI bootstrap/control-plane provider so the proposal's lifecycle story extends to it |
| **Talos** | minimal immutable OS, API-managed (no SSH) | Full cluster per site, OS included | When fleet *OS* management is the pain — immutability and declarative upgrades across hundreds of sites; CAPI providers exist (Sidero) |
| **KubeEdge** | ~70 MB edge agent, scales to thousands of nodes | **Node-level edge**: devices join a cloud control plane as autonomous edge nodes; local operation continues through WAN loss | When sites are too small/numerous to each be a cluster — the device fleet pattern |
| **OpenYurt** | non-intrusive add-on to vanilla K8s | Node-level edge, upstream-K8s flavoured | Same niche as KubeEdge, different trade: stock API surface vs. KubeEdge's richer device twins/MQTT integration |

**The decision rule that picks between them:** *does the site need to be a cluster?* If a site must keep scheduling, admission, and local services alive
autonomously (a factory, a depot), it is a cluster — k3s/Talos, joined to the fleet as a (lightweight) spoke. If a site is one or three boxes reporting to a
regional brain, it is a **node** — KubeEdge/OpenYurt edge nodes of a regional spoke, and it never appears in the hub's cluster inventory at all. Getting this
wrong in the expensive direction (a full spoke per lamp-post) is how edge fleets drown their hub; the proposal's ArgoCD push model in particular cannot carry
thousands of registrations, which is one more argument already banked for the OCM evolution.

---

## Worked use cases

### 1 — EV charging network (arm64 edge + amd64 regional core)

The topology OCPP itself dictates: charge points are WebSocket **clients** dialing out over TLS to a CSMS (Central System Management Software); OCPP 1.6
dominates deployed hardware, 2.0.1 adds certificate-based auth and ISO 15118. Charging must continue when the WAN doesn't — offline autonomy is a protocol
expectation, not a nice-to-have.

```
Charge points (embedded ARM, not K8s)
    │  OCPP over WebSocket/TLS (outbound dial)
    ▼
Depot / site gateway — arm64 SBCs
    k3s (site = cluster: local queueing, local auth cache, OTA staging)
    or KubeEdge nodes of the regional spoke (site = nodes)
    │  MQTT/NATS uplink, store-and-forward through WAN loss
    ▼
Regional spoke — amd64 (the proposal's spoke, unchanged)
    CSMS (stateful WebSocket sessions) · CNPG (sessions, billing) · NATS/MQTT broker
    │
    ▼
Hub — CAPI + ArgoCD + Pinniped, exactly per the proposal
```

W'xOps mapping and the three lessons it surfaces:

- **Regional CSMS clusters are ordinary spokes**; `tenant-app` deploys the
  CSMS with the future `scheduling:` block pinning it to amd64 pools. Depots
  are *not* spokes — they're the node-vs-cluster rule above, resolved per
  fleet size.
- **GSLB strategy is forced, not chosen**: OCPP WebSockets are long-lived and
  stateful — `roundRobin` across regions would shear connections. `failover`
  (the proposal's default) is the only correct mode, and charge points
  reconnect on failover as the protocol expects.
- **The persistent-connection tier needs what HTTP apps don't**: connection
  draining on rollout and per-region session state in CNPG. This is the use
  case that would eventually justify the CNPG replica-cluster DR tier.

### 2 — Multi-region SaaS (the common case)

The proposal's architecture used as-is, with both other axes layered on: region is a **tenant attribute** (`cluster: eu-fra` chosen at onboarding, driven by
data residency more often than latency), tenancy tiers price isolation (namespace → Kamaji-hosted → dedicated spoke), and hardware stays homogeneous amd64 until
a cost review introduces arm64 node pools — at which point the multi-arch image rule and the `scheduling` block are the entire migration story. Nothing new to
build beyond the gaps already tabled.

### 3 — IoT telemetry fleet (thousands of sites)

The corner that breaks the prototype's assumptions hardest: sites are KubeEdge/OpenYurt **nodes** (never spokes), telemetry is MQTT with edge-side downsampling
before uplink, and the hub manages only the regional aggregation spokes. Fleet-wide delivery to the edge tier happens through the edge platform's own channel
(KubeEdge's cloud-edge tunnel), not through ArgoCD — the hub's GitOps writ ends at the regional spoke. Accepting that boundary early avoids the worst outcome on
this axis: trying to make one delivery mechanism span both worlds.

### 4 — Cross-provider GPU inference (field-tested, see References)

The one case here that has actually been run: AI inference replicated across **two providers in two countries** — VNG Cloud (Vietnam, A40s, GPU Operator + HAMi)
and Alibaba Cloud (China, L20s, native cGPU) — with Alibaba DNS/GTM geo-routing on top and ArgoCD as the single GitOps control plane across both. What it adds
to the axes above: *provider* heterogeneity is its own hardware axis (GPU sharing mechanics differed per cloud and could not be abstracted), cross-border DNS is
a real routing constraint, and the replicated-full-stack posture held up in practice. Its conclusion — managed, provider-native paths over custom orchestration
(Virtual Kubelet and a tunnel-CRD operator were both evaluated and rejected) — is the same rule this repo's architecture already enforces.

---

## What this means for W'xOps Core — consolidated

Near-term, concrete (all additive, all following existing patterns):

1. **`scheduling:` block** on `tenant-app` (and threaded to CNPG in
   `platform-database-clusters`) — `nodeSelector`, `tolerations`,
   `topologySpreadConstraints`. The prerequisite for *any* mixed-arch or
   edge-tainted node pool. `safe` tier; golden cases per branch as usual.
2. **Widen `resources.requests`/`limits`** to accept extended-resource keys
   (`nvidia.com/gpu`, vendor vGPU resources) — today's schema silently prunes
   them, despite the field's "passed through verbatim" description.
3. **Multi-arch statement in docs** — tenant images should be manifest lists;
   single-arch images must pin via `scheduling`; verify provider/function
   arm64 variants against pinned versions before any ARM control plane.
4. **Vault `{cluster}/` path dimension** — already the proposal's open
   decision #1; this document only raises its priority: it gates region two,
   and region-pinned data is the default posture that makes everything else
   tractable.

Direction-setting, not yet work:

5. **Tenancy tiers generalise `tier: shared|dedicated`** — Capsule to
   formalise today's namespace tier; **Kamaji-via-CAPI** as the standout
   candidate for a hosted-control-plane tier; `XPlatformCluster` as the
   eventual dedicated tier API. No commitment implied — the point is that the
   spectrum reuses the platform's existing tier concept rather than importing
   a foreign model.
6. **The node-vs-cluster edge rule** decides how any future edge/IoT/EV work
   joins the fleet — and its fleet-size implications are one more reason the
   OCM evolution is sequenced after the push prototype, not skipped.

---

## References

**Field notes — this platform's own prior runs** (the source of every "field-tested" claim above)
- [The Story of Mine about Multi-Region Architecture](https://wiki.xeusnguyen.xyz/Tech-Second-Brain/Personal/DevSecOps/The-Story-of-Mine-about-Multi-Region-Architecture)
  — replicated multi-cluster across VNG Cloud (Vietnam) + Alibaba Cloud
  (China): GPU sharing (cGPU vs GPU Operator + HAMi), Alibaba DNS/GTM for
  geo-routing, and the rejected custom paths (CRD + SSH tunnels, Virtual
  Kubelet)
- [To Cloud-Native Multi-Cluster with ExternalDNS](https://wiki.xeusnguyen.xyz/Tech-Second-Brain/Personal/DevSecOps/To-Cloud-Native-Multi-Cluster-with-ExternalDNS)
  — ExternalDNS + Route 53 routing policies across RKE2 + K3s: latency /
  failover / weighted annotations, per-cluster `txtOwnerId` ownership, the
  private-IP and CNAME/A pitfalls, and the measured ~39 s failover

**Tenancy**
- [Capsule](https://capsule.clastix.io/) — `Tenant` CRD over namespaces
- [vCluster](https://www.vcluster.com/) · [comparison of multi-tenancy options](https://www.vcluster.com/blog/comparing-multi-tenancy-options-in-kubernetes)
- [Kamaji](https://kamaji.clastix.io/) — hosted control planes, CAPI control-plane provider
- [kcp](https://github.com/kcp-dev/kcp) — API-only workspaces (workload scheduling removed 2023)

**Edge / hardware**
- [k3s](https://k3s.io/) · [KubeEdge](https://kubeedge.io/) · [OpenYurt](https://openyurt.io/) · [Talos](https://www.talos.dev/)
- [Docker buildx multi-platform builds](https://docs.docker.com/build/building/multi-platform/)
- [Kubernetes — well-known label `kubernetes.io/arch`](https://kubernetes.io/docs/reference/labels-annotations-taints/#kubernetes-io-arch)

**Multi-region data**
- [CNPG replica clusters](https://cloudnative-pg.io/documentation/current/replica_cluster/)
- [CockroachDB](https://www.cockroachlabs.com/) · [YugabyteDB](https://www.yugabyte.com/) — distributed SQL, when RPO≈0 across regions is a hard requirement

**Use-case grounding**
- [Open Charge Alliance — OCPP](https://openchargealliance.org/protocols/open-charge-point-protocol/)
- [AMPECO — the OCPP handbook](https://www.ampeco.com/guides/complete-ocpp-guide/)

**Internal**
- [`multi-cluster.md`](multi-cluster.md) — the option space this builds on
- [`multi-cluster-proposal.md`](multi-cluster-proposal.md) — the chosen path this extends
- [`tenant-database.md`](../../docs/api-reference/tenant-database.md) — the `tier:` concept this generalises
