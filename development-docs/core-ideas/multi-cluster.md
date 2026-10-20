# Multi-Cluster — manage what you are given, connect it by name

> [!NOTE]
> **Status: direction, not implemented.** Replaces the CAPI-era family — [`multi-cluster.md`](../_archives/multi-cluster.md),
> [`multi-cluster-proposal.md`](../_archives/multi-cluster-proposal.md), [`multi-cluster-connectivity.md`](../_archives/multi-cluster-connectivity.md),
> [`multi-cluster-scale.md`](../_archives/multi-cluster-scale.md) — archived 2026-10-20. Written from a design discussion and the KubeCon EU 2020 talk
> [*CoreDNS for Hybrid and Multi-cloud*](https://static.sched.com/hosted_files/kccnceu20/6b/KubeCon%20-%20Amsterdam%20-%20CoreDNS.pdf); refine it here
> before an RFC is written.

---

## The idea

W'xOps **manages clusters it is given; it does not provision them**. A cluster — k3s, Talos, RKE2, kubeadm, EKS, AKS, GKE — joins a fleet by being
registered. Every management channel between the hub and a spoke is **opened by the spoke**, and the clusters reach each other's workloads through a
**name-based L7 backbone**: CoreDNS answers `<service>.<namespace>.<cluster>.wxops.internal`, a gateway in each cluster terminates mTLS and routes by name.
No pod IP ever crosses a cluster, so no CNI, no cloud and no overlay product is a dependency — and the hub is not on the path between two spokes, so a hub
outage does not stop them talking.

### What changed, and why

The archived design had **CAPI provision spokes** and the hub hold every spoke's credentials. That pulled W'xOps into node lifecycle and cloud credentials,
and made the hub a trust root whose compromise was a fleet compromise — most of the archived connectivity analysis existed to contain that. The main reason
to want CAPI was controlling a spoke's apiserver flags so it would trust the hub's identity; once every channel is spoke-initiated, the hub needs no
credential for a spoke's API at all, and the reason disappears.

The talk the backbone comes from is candid about the other half: CoreDNS multi-cluster discovery assumes **non-overlapping pod CIDRs, every IP routable from
every cluster, headless services only, no ClusterIP**. That flat network is what CNI meshes (Cilium ClusterMesh, Submariner, Kilo) provide, and what ties a
fleet to one CNI. This design keeps CoreDNS for **names** and drops the flat network: names resolve to a **gateway**, never to a pod.

---

## Principles

1. **Manage, don't provision.** Bring your own cluster. Creating, upgrading and repairing clusters is out of scope.
2. **The spoke dials out.** Delivery, telemetry, identity and secrets are spoke-initiated; the hub holds no spoke kubeconfig, and `:6443` is never exposed.
3. **The hub is a control-plane dependency, never a runtime one.** Spoke-to-spoke traffic does not transit it.
4. **Route by name at L7, not by IP at L3.** Overlapping CIDRs, different CNIs and different clouds are all fine.
5. **One shape on every cluster, generated, never hand-written.** The same resolver, the same gateway, the same policies; the per-cluster differences are
   rendered from the fleet's membership list.

---

## The shape

```text
                                   HUB — management only
     Argo CD principal · Pinniped Supervisor · OpenBao · Core (Crossplane) · fleet membership
          ▲ gRPC+mTLS            ▲ JWKS / login           ▲ ESO (mTLS)
          │ spoke dials out      │                         │
 ┌────────┴──────────────────────┴─────────────────────────┴───────────────┐      ┌──────────────────────────────┐
 │ SPOKE a                                                                 │      │ OBSERVABILITY cluster        │
 │  argocd-agent · Pinniped Concierge · ESO · Kyverno · Alloy ─────────────┼─────▶│  Mimir · Loki · Tempo        │
 │  mesh resolver (CoreDNS): a.wxops.internal ─ authoritative               │ mTLS │  gateway: *.obs.wxops.internal│
 │                           b, gpu, obs … ─ forward over DoT, direct       │      └──────────────────────────────┘
 │  gateway (mTLS, routes by name) ◀══════════ east-west ══════════▶ SPOKE b / GPU cluster (vLLM) / …   │
 └─────────────────────────────────────────────────────────────────────────┘
```

Three planes, each with its own rule:

| Plane | What travels | Mechanism | Direction |
|---|---|---|---|
| **Management** | desired state, policies, identity, secrets | Argo CD Agent (gRPC, mTLS); Pinniped Concierge; ESO | spoke → hub, outbound only |
| **Naming** | "where is `<svc>.<ns>.<cluster>`?" | a W'xOps CoreDNS **mesh resolver** per cluster; DNS-over-TLS between resolvers | resolver → the owning cluster's resolver, directly |
| **Data** | requests between workloads | one **gateway** per cluster: mTLS, routes by host name / SNI | caller's cluster → callee's gateway, directly |

---

## The management plane

| Need | Tool | Notes |
|---|---|---|
| Deliver to many clusters without the hub holding their credentials | [**Argo CD Agent**](https://argocd-agent.readthedocs.io/stable/features/) — principal on the hub, agent on each spoke | gRPC over mutual TLS. **Autonomous** mode (Applications defined on the spoke, status synced up) for prod; **managed** mode (defined on the hub, pushed down) for dev. Still in active development upstream |
| Human access to any cluster, managed ones included | **Pinniped** — Supervisor on the hub trusting Dex, Concierge on each spoke | See the [access model](access-model.md#kubernetes-pinniped--rbac--kyverno) |
| Secrets on each spoke | **ESO** on the spoke, against OpenBao by name over the backbone | ESO keeps the last synced Secret if OpenBao is unreachable |
| Telemetry | **Alloy** on each spoke, pushing to the observability cluster | Write-ahead buffering covers a collector outage up to its size |
| The same rules everywhere | Kyverno policies delivered by Argo, parameterised by a per-cluster `wxops-cluster-info` ConfigMap (`env`, `cluster-name`, `role`) | One policy set; `role` is `hub`, `spoke`, `observability`, `gpu`, … |

---

## The naming plane — CoreDNS as the backbone

### Names

```text
<service>.<namespace>.<cluster>.wxops.internal          payment-api.payment.b.wxops.internal
```

`.internal` is reserved by ICANN for private use, so it can never collide with a public name. Each cluster is **authoritative for its own sub-zone**
(`b.wxops.internal`) and answers every name in it with **its own gateway's address**. Which services actually answer is the gateway's business, not DNS's —
DNS stays a trivial wildcard.

### A W'xOps resolver, not the distribution's DNS

The cluster DNS is configured differently on every distribution — the `coredns-custom` ConfigMap with `*.server`/`*.override` keys is a k3s and AKS
convention, EKS ships CoreDNS as an add-on with its own Corefile, RKE2 configures it through chart values, and **GKE runs kube-dns** by default. So W'xOps
runs **its own CoreDNS** — a small Deployment in `wxops-system`, the same image and Corefile shape on every cluster — and touches the distribution's DNS with
exactly **one stub-domain forward**:

| Distribution | The one line: `wxops.internal` → the mesh resolver's Service IP |
|---|---|
| k3s, AKS | a `wxops.server` key in the `coredns-custom` ConfigMap |
| EKS | a server block in the add-on's Corefile |
| RKE2 | the CoreDNS chart's values |
| GKE (kube-dns) | `stubDomains` in the `kube-dns` ConfigMap |
| kubeadm, Talos | a server block in the `coredns` ConfigMap |

The distribution's DNS keeps doing in-cluster resolution untouched; a mistake in mesh configuration cannot break `cluster.local`.

### The resolver's Corefile

A sketch for cluster `a` — not yet run:

```text
a.wxops.internal:53 {                       # own zone, for this cluster's pods
    template IN A a.wxops.internal {
        answer "{{ .Name }} 60 IN A 198.51.100.10"      # a's gateway
    }
}
tls://a.wxops.internal:853 {                # the same zone, served to peers over DoT
    tls /certs/tls.crt /certs/tls.key /certs/ca.crt {
        client_auth require_and_verify      # peers present a fleet certificate; answers reveal topology
    }
    template IN A a.wxops.internal {
        answer "{{ .Name }} 60 IN A 198.51.100.10"
    }
}
b.wxops.internal:53 {                       # one block per peer — straight to that peer, never via the hub
    forward . tls://203.0.113.20:853 {
        tls_servername dns.b.wxops.internal
        tls /certs/tls.crt /certs/tls.key /certs/ca.crt
    }
    cache 30
}
# gpu.wxops.internal, obs.wxops.internal, hub.wxops.internal … — same shape
reload
```

`reload` applies a changed Corefile without a restart; the change reaches the file only when the kubelet refreshes the mounted ConfigMap, typically within
a minute or two (and never through a `subPath` mount).

### The peer list is generated

With N clusters, every resolver lists N−1 peers. Written by hand, those N files drift. Instead each cluster's membership XR publishes its gateway and DNS
endpoint in status, and every resolver's peer blocks are **rendered from the membership list** — the same pattern as `XOIDCConnector` generating its team
list from labelled `XScmTeam`s. Joining a cluster is one XR; Argo carries the result to every other cluster; leaving reverses it.

---

## The data plane — one gateway per cluster

- **Reachable from peers.** The gateway listens on 443 (and 853 for the resolver) at an address peers can reach — a public IP or a private interconnect;
  the design does not care which, but gateway addresses must not overlap. This is the one inbound path on a spoke; the management plane stays outbound-only
  and `:6443` stays closed.
- **mTLS both ways.** The gateway accepts only client certificates from the fleet's CA and routes by host name or SNI to a local Service.
- **Exporting a service is creating a route.** A service is reachable from other clusters only if a route for `<svc>.<ns>.<cluster>.wxops.internal` exists
  on its gateway — an explicit, reviewable object. Kyverno checks it against the [access model](access-model.md)'s owner label: only `payment` exports
  `payment-*`, and the route's allowed callers are owners the policy permits.
- **What crosses:** HTTP, gRPC and TLS-wrapped TCP. **What does not:** anything that needs the peer's pod IP — multicast, gossip protocols that advertise pod
  addresses, replication that dials pod IPs. Those stay inside one cluster, or get a protocol-specific route.

---

## Problems the backbone solves

The point of the backbone is that clusters can **specialise** — one holds the GPUs, one holds the observability stack, one holds the hub — and every other
cluster reaches them by name:

| Need | Name a spoke calls | Served by | Why it matters |
|---|---|---|---|
| **Secrets** — ESO and workloads reading OpenBao | `openbao.openbao.hub.wxops.internal` | the hub's gateway | One OpenBao for the fleet without exposing it publicly or running one per cluster |
| **AI inference on GPUs** | `vllm.ai-suite.gpu-01.wxops.internal` | a GPU cluster | GPUs are expensive and few; one GPU cluster serves every spoke. A second GPU cluster is a second name, and moving a model is a DNS change |
| **Centralised monitoring in a large cluster** | `mimir.monitoring.obs.wxops.internal`, `loki…`, `tempo…` | an observability cluster | The LGTM stack is the heaviest workload in the fleet; it gets its own cluster instead of weighing on the hub, and Alloy on every spoke pushes to it over mTLS |
| **Identity** | `dex.dex.hub.wxops.internal`, Pinniped Supervisor | the hub | Login and token validation from every cluster |
| **Delivery** | the Argo CD principal | the hub | The agent's one outbound connection |
| **Shared data services** | `pg-shared.databases.data-01.wxops.internal` (TLS TCP route) | a data cluster | A shared CNPG pool used from several clusters |
| **North-south** — users to the nearest healthy cluster | public names | [k8gb](https://www.k8gb.io/) — per-cluster CoreDNS serving a delegated zone | Same toolbox, other direction; carried over from the [archived scale study](../_archives/multi-cluster-scale.md) |

---

## When something fails

| Down | Effect |
|---|---|
| **The hub** | Spoke ↔ spoke traffic and running workloads continue. Argo agents keep what is deployed; whether an autonomous agent keeps syncing from Git during the outage is a spike item. New human logins fail (Supervisor), existing sessions run to expiry. ESO keeps last-synced Secrets. New certificate issuance pauses |
| **A peer cluster** | Only names under that peer's zone fail; nothing else does |
| **A peer's resolver** | Its names stop resolving for others; cached answers last their TTL |
| **The observability cluster** | Alloy buffers and sends later; nothing else is affected |
| **A GPU cluster** | Inference calls fail; with two GPU clusters, a name change moves traffic |

The hub can be rebuilt without touching a spoke: the membership XRs, the policies and the generated configuration are all in Git.

---

## Where Core fits

### Membership, not provisioning

One XR per registered cluster — name to be decided — whose composition produces the **join kit**:

- the Argo agent's registration on the principal;
- the cluster's mesh certificates (resolver, gateway, Alloy client);
- its `wxops-cluster-info`;
- its Pinniped Concierge configuration;
- its sub-zone, published in status (gateway and DNS endpoint) for every other cluster's resolver to render.

Removing the XR removes the cluster from the fleet. Declarative, and no hand-written controller.

### Where compositions run

`spec.parameters.cluster` exists on `XTenantApp`, `XTenantDatabase` and `XPlatformDatabaseCluster` today, threaded to a `provider-kubernetes`
`ProviderConfig` — the hub applying resources **into** a spoke's API. That is exactly the hub → spoke credential this design removes. Two ways forward:

| | Crossplane on each spoke (recommended) | Hub `ProviderConfig` per spoke |
|---|---|---|
| How | Argo delivers the Core packages and the XRs to the spoke; the spoke's own Crossplane composes locally | The hub's provider applies into each spoke |
| Hub → spoke credential | **none** | one per spoke, plus an inbound `:6443` or a tunnel |
| Blast radius | one cluster | the fleet |
| Cost | N Crossplane installs to keep at the same version | none extra |

With Crossplane on each spoke, `cluster` keeps its default (`"default"`, the local cluster) everywhere. The field stays — a released XRD is additive-only —
but becomes the single-cluster case rather than the fleet mechanism. Hub-scoped kinds (SCM, OIDC, platform-tool configuration, membership) stay on the hub.

---

## Identity across clusters

- **People:** Pinniped, per the [access model](access-model.md). One login, groups `<org>:<team>`, per-cluster credentials.
- **Workloads calling across clusters:** the fleet CA's certificates at the gateway. The certificate identifies the calling cluster and, if issued per
  ServiceAccount, the calling workload — which is what an owner-based export rule needs.
- **The resolvers and Alloy:** fleet certificates too, so DoT and telemetry are authenticated, not just encrypted.

---

## What W'xOps does not do

- Provision, upgrade or repair clusters — CAPI and its trust root are dropped.
- Hold a kubeconfig for any spoke, or expose any spoke's `:6443`.
- Require a CNI, a flat pod network, non-overlapping CIDRs, or an overlay product.
- Route spoke-to-spoke traffic through the hub.
- Edit a distribution's DNS beyond one stub-domain forward.

---

## Known limits

- **One inbound path per spoke** — the gateway. "Zero inbound ports" holds for the management plane only; a spoke that serves others must be reachable.
- **L7 and TLS-wrapped TCP only.** Protocols that need peer pod IPs stay in one cluster.
- **Failover is as fast as DNS caching allows** — keep TTLs short on mesh names.
- **The distribution hook differs** per distribution — one line, but one line per distribution to know.
- **Certificate issuance depends on the hub**; certificate lifetimes are how long a spoke tolerates a hub outage.
- **Argo CD Agent is young** upstream; its outage behaviour is unverified here.

---

## Decisions taken

1. W'xOps manages clusters it is given; provisioning is out of scope.
2. Management plane outbound-only; one inbound mTLS gateway per spoke for the data plane; `:6443` never exposed.
3. Names: `<svc>.<ns>.<cluster>.wxops.internal`; each cluster authoritative for its own zone; peers forward directly over DoT with client certificates.
4. A dedicated W'xOps mesh resolver, hooked into the distribution's DNS by one stub-domain forward.
5. Peer configuration generated from fleet membership, never hand-written.
6. Exporting a service is a gateway route, checked by policy against the owner label.

## Open decisions

1. **The fleet CA** — OpenBao PKI, or cert-manager with a shared CA; per cluster or per ServiceAccount (SPIFFE-shaped) certificates.
2. **The gateway** — Traefik, already in the stack (`XTenantApp` routes through it) and able to require client certificates; or Envoy Gateway, for
   authorisation per calling identity.
3. **Location-transparent names later?** CoreDNS ≥ 1.12.2 serves the Multi-Cluster Services `clusterset.local` names from its `kubernetes` plugin, but
   something must create the `ServiceImport`s. Start with explicit per-cluster names.
4. **Crossplane per spoke** — confirm, and decide how its version is kept in step with the hub's.
5. **The membership kind** — name, group (`platform`), and exactly what the join kit contains.
6. **Underlay per environment** — public addresses with source allow-lists, or a private interconnect. The design works over either.

## Carried over from the archived family

Still valid and not repeated here — read them in the archive: the multi-region data strategy (region-pinned by default, CNPG replicas for DR), tenancy
isolation tiers, edge and ARM sites (k3s/Talos per autonomous site), GPU pools and the missing `scheduling:` block, and the k8gb GSLB comparison — all in
[`multi-cluster-scale.md`](../_archives/multi-cluster-scale.md).

## Sources

- [CoreDNS for Hybrid and Multi-cloud — KubeCon EU 2020 slides](https://static.sched.com/hosted_files/kccnceu20/6b/KubeCon%20-%20Amsterdam%20-%20CoreDNS.pdf)
- [Argo CD Agent — features](https://argocd-agent.readthedocs.io/stable/features/) ·
  [agent configuration](https://argocd-agent.readthedocs.io/stable/configuration/reference/agent/)
- [CoreDNS `multicluster` plugin](https://coredns.io/explugins/multicluster/) · [coredns/multicluster](https://github.com/coredns/multicluster)
- [k8gb](https://www.k8gb.io/)
