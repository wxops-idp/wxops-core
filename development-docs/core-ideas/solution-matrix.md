# Solution Matrix — AI Intelligence × Multi-Cluster × Observability

> [!NOTE]
> **Status: summary index, kept current by hand.** One page over the whole doc family: every problem across the three domains, the chosen tool or solution,
> **what W'xOps solves today with existing packages** vs. what must be introduced, the detail doc for each, and the publicly documented industry practice to
> learn from. Read it as a map for brainstorming and prioritising — each row links to the place where the reasoning lives.

**Legend — W'xOps state**

| Symbol | Meaning |
|---|---|
| ✅ | Solved today, shipping in a current package |
| 🔶 | Partially solved — mechanism exists, a piece is missing |
| 📋 | Designed in the docs, not implemented |
| ❌ | Not started — needs the named component |
| ⛔ | Deliberately rejected — do not reopen without new information |

---

**Table of Conents**

- [Solution Matrix — AI Intelligence × Multi-Cluster × Observability](#solution-matrix--ai-intelligence--multi-cluster--observability)
  - [Domain 1 — Observability](#domain-1--observability)
  - [Domain 2 — Multi-Cluster \& Multi-Region](#domain-2--multi-cluster--multi-region)
  - [Domain 3 — AI Intelligence \& Self-Service Operations](#domain-3--ai-intelligence--self-service-operations)
  - [What must be introduced — consolidated](#what-must-be-introduced--consolidated)
  - [How to use this page](#how-to-use-this-page)

---

## Domain 1 — Observability

| # | Problem | Solution / tool | W'xOps state | Detail doc | Industry practice to study |
|---|---|---|---|---|---|
| O1 | Per-app metrics scrape that actually works | `ServiceMonitor`/`PodMonitor` emission, `kind: auto` | ✅ `XTenantApp` `spec.parameters.monitoring` (v0.4.0) | [observability.md](observability.md) | Prometheus Operator model — standard kube-prometheus-stack practice |
| O2 | Portal-pollable readiness per resource | `status.created`/`ready` derived from `ocds`, uniform across packages | ✅ all seven packages (v0.4.0) | [status-contract.md](../../docs/api-reference/status-contract.md) | Kubernetes operator status conventions; conditions done honestly |
| O3 | Partial-health honesty (app up, TLS pending) | `ready` / `dependenciesReady` split | ✅ `XTenantApp` | [status-contract.md](../../docs/api-reference/status-contract.md#tenant-app--the-one-package-that-needs-two-fields-not-one) | — |
| O4 | Cardinality protection in multi-tenant Prometheus | `sampleLimit` set by the composition, not the tenant | ✅ `XTenantApp` monitoring block | [observability.md](observability.md#cardinality) | Multi-tenant Prometheus guardrail practice (limits at ingest) |
| O5 | Status says *which*, should say *why* | `status.notReady` reasons list | ❌ proposed — `safe`-tier KCL change, all packages | [self-service-operations.md](self-service-operations.md#whats-missing) | Operator `reason`/`message` condition discipline |
| O6 | Alerts that carry their runbook | `PrometheusRule` emission + `runbook_url` annotation | ❌ proposed — future `monitoring.alerts` on `XTenantApp` | [self-service-operations.md](self-service-operations.md#pillar-2--runbooks-as-platform-contract) | [Prometheus alerting best practices](https://prometheus.io/docs/practices/alerting/) — `runbook_url` convention |
| O7 | One metrics view across all spokes | **Push (`remote_write`) not pull** — VictoriaMetrics / Mimir / Thanos Receive; **not** Thanos Sidecar fan-out | ❌ platform-infra decision, not a package | [observability.md §the decisive fork](observability.md#the-decisive-fork-push-or-pull) | Thanos (born at Improbable); Grafana Mimir multi-tenancy; VictoriaMetrics ingest efficiency |
| O8 | Central logs (also Guardian's audit sink) | Loki + **Grafana Alloy** (Promtail is EOL since Mar 2026), push outbound | ❌ platform infra — one decision serves two docs | [observability.md §tool options](observability.md#logs-traces-events-profiles) · [guardian.md](guardian.md#phase-2--audit-and-compliance) | Grafana Loki label-first log model; Alloy as the consolidated agent |
| O9 | Traces | OpenTelemetry → Tempo, per-app opt-in, later | ❌ deferred; `darlane.telemetryPort` is the existing hook | [observability.md §signal matrix](observability.md#the-signal-matrix--what-to-collect-per-tier) | OTel as the vendor-neutral default |
| O10 | Observing *edge* fleets | Report up to regional spoke, never query down | 📋 rule stated | [self-service-operations.md](self-service-operations.md#the-edge-caveat) | Edge telemetry downsampling practice (KubeEdge/OpenYurt ecosystems) |
| O11 | Kubernetes events as a signal | Event exporter → log store; named object + reason | ❌ **not collected anywhere** — the best signal-per-effort item on this page | [observability.md §signal matrix](observability.md#the-signal-matrix--what-to-collect-per-tier) | `kubernetes-event-exporter`; OTel `k8sobjects` receiver |
| O12 | Cross-cluster label contract | `externalLabels.cluster` **equal to** `spec.parameters.cluster` | ❌ free today, impossible to retrofit onto stored data | [observability.md §label contract](observability.md#the-label-contract--the-cheap-prerequisite) | Prometheus `external_labels` discipline in federated estates |
| O13 | Network flow visibility (who talks to whom) | **Hubble** — a flag on Cilium **if Cilium is the CNI (unverified — see the doc)**; ship flow *metrics*, ⛔ not central Relay (hub→spoke, same failure as Thanos Sidecar) | ❌ not collected — near-zero cost *conditional on* Cilium, which this repo assumes but has not confirmed; non-uniform on managed spokes (M3b) | [observability.md §the kernel plane](observability.md#the-kernel-plane--flows-and-runtime-security) | Cilium/Hubble in production fleets; Microsoft Retina for CNI-agnostic estates |
| O14 | Declared vs observed dependency graph | Diff the XR tree (declared) against flow data (observed) — undeclared egress, undocumented dependencies | ❌ **the strongest flow argument here** — needs O13 + the existing XR topology | [observability.md §where this pays off](observability.md#where-this-pays-off-for-the-sre-agent-goal) | Service-map drift detection; the ops and security cases coincide |
| O15 | Runtime security signal (kernel) | Falco (detect-only, CNCF-graduated) → `falcosidekick` push; Tetragon/KubeArmor add enforcement | ❌ not started — **detect-only, advisory**, mirroring Guardian Phase 1; *what* to detect is the threat model's call | [security-threat-model.md](security-threat-model.md) · [observability.md §detect vs enforce](observability.md#detect-versus-enforce-is-the-real-axis) | Falco rule-tuning practice — the cost is tuning, not install |

## Domain 2 — Multi-Cluster & Multi-Region

| # | Problem | Solution / tool | W'xOps state | Detail doc | Industry practice to study |
|---|---|---|---|---|---|
| M1 | Target cluster as an XR parameter | `spec.parameters.cluster` → `providerConfigRef` threading | ✅ threaded (30 sites, v0.4.0) — 🔶 inactive until a spoke `ProviderConfig` exists | [multi-cluster-proposal.md](multi-cluster-proposal.md#why-this-shape) | Crossplane multi-cluster `ProviderConfig` pattern |
| M2 | Spoke provisioning & bootstrap | CAPI + `ClusterResourceSet` | ❌ prototype item 1–3 | [multi-cluster-proposal.md](multi-cluster-proposal.md#the-prototype) | Mercedes-Benz's publicly presented CAPI fleet (hundreds of clusters, KubeCon talks) |
| M3 | Machine identity hub→spoke without standing creds | Structured `AuthenticationConfiguration`, projected SA tokens | ❌ prototype; GA in K8s 1.35 | [multi-cluster.md](multi-cluster.md#machine-identity--hub-to-spoke) · [connectivity §Path N](multi-cluster-connectivity.md#path-n--new-clusters-provisioned-by-capi) | K8s structured authn (KEP-3331); Microsoft's practical guide |
| M3b | Joining a spoke you **didn't** provision (managed/opaque) | Cloud workload identity via `ProviderConfig.spec.identity` → managed OIDC association → Vault dynamic SA tokens | ❌ options analysed; `spec.identity` cloud types are a **verified** built-in path | [multi-cluster-connectivity.md](multi-cluster-connectivity.md#path-e--existing-clusters) | EKS external OIDC providers; GKE Identity Service; Vault K8s secrets engine |
| M3c | Hardening *all* hub→spoke doors, not one | Three independent trust paths — Crossplane `ProviderConfig`, ArgoCD cluster Secret, CAPI kubeconfig | ❌ named and separated; ArgoCD and Crossplane **cannot** share one credential mechanism | [multi-cluster-connectivity.md](multi-cluster-connectivity.md#the-three-trust-paths-the-thing-most-designs-miss) | — (the CAPI trust-root discussion is the closest published analogue) |
| M4 | Human identity to any spoke | Pinniped Supervisor (Gitea OIDC) + Concierge | ❌ prototype item 3 | [multi-cluster.md](multi-cluster.md#human-identity--developer-to-spoke) | Pinniped on EKS multi-cluster (AWS open-source blog) |
| M5 | Registration without cluster-admin | ApplicationSet Cluster generator + scoped SA minting; **never** `argocd cluster add` | ❌ prototype item 5 | [multi-cluster.md](multi-cluster.md#option-a2--push-with-brokered-just-in-time-credentials) · [connectivity §anti-patterns](multi-cluster-connectivity.md#anti-patterns-in-the-order-people-hit-them) | argocd-agent (shipped in OpenShift GitOps 1.19) as the evolution |
| M6 | Delivery at fleet scale (100s of spokes) | OCM `ManifestWork` — spokes pull, hub keeps `InjectedIdentity` | 📋 planned second step, deliberately not first | [multi-cluster-proposal.md](multi-cluster-proposal.md#the-join-mechanism-capi--argocd-now-ocm-later--not-karmada-not-fleet) · [scale](multi-cluster-scale.md#hub-scale--where-the-proposals-push-model-runs-out) | OCM (CNCF); Red Hat ACM in production fleets |
| M7 | Fleet API | Crossplane XRs — one XR per cluster, portal does fan-out | ✅ by architecture | [multi-cluster-proposal.md](multi-cluster-proposal.md) | — (Karmada `PropagationPolicy` is the ⛔ counter-example: competes with the XR as fleet API) |
| M8 | Multi-region traffic routing | ExternalDNS + Route 53 policies (field-tested, ~39 s failover) → k8gb → anycast | ❌ infra config; sequencing decided | [multi-cluster-scale.md](multi-cluster-scale.md#gslb-implementations--three-options-one-field-tested) | The author's own field notes (References there); k8gb (ABSA) |
| M9 | Multi-region *data* | Region-pinned default → CNPG replica DR tier → distributed SQL only if RPO≈0 | ❌ decision framework written; `XTenantDatabase`/`XPlatformDatabaseCluster` are the vehicles | [multi-cluster-scale.md](multi-cluster-scale.md#the-data-layer-decides-the-region-strategy-not-the-other-way-round) | CNPG replica clusters; CockroachDB/Yugabyte for the RPO≈0 corner |
| M10 | Tenancy isolation tiers | Capsule → vCluster → Kamaji-via-CAPI → dedicated cluster | 📋 direction — generalises `XTenantDatabase`'s existing `tier: shared\|dedicated` | [multi-cluster-scale.md](multi-cluster-scale.md#axis-2--multi-tenancy-the-isolation-spectrum) | vCluster in AI-cloud tenancy; Kamaji as CAPI control-plane provider |
| M11 | ARM/edge sites (IoT, EV charging) | Node-vs-cluster rule: k3s/Talos per autonomous site, KubeEdge/OpenYurt nodes otherwise | ❌ direction + worked use case | [multi-cluster-scale.md](multi-cluster-scale.md#worked-use-cases) | Chick-fil-A's publicly presented per-restaurant edge clusters; KubeEdge (Huawei origin), OpenYurt (Alibaba origin) |
| M12 | Mixed hardware scheduling | `scheduling:` block (nodeSelector/tolerations/spread) + multi-arch images | ❌ **verified gap** — no scheduling fields in any XRD; `resources` schema also prunes GPU keys | [multi-cluster-scale.md](multi-cluster-scale.md#the-verified-wxops-gaps) | buildx manifest-list practice; `kubernetes.io/arch` labels |
| M13 | Darlane interactive access across clusters | Tunnel (Tailscale incl. laptops; Teleport if audited sessions) | ❌ prototype; identity stays Pinniped | [multi-cluster.md](multi-cluster.md#darlane-across-clusters) | Tailscale K8s operator; Teleport session recording |
| M14 | Composition-emitted RBAC | — | ⛔ rejected permanently — SA published in status, GitOps binds | `development-docs/_archives/ROADMAP.md` §Decided and rejected | — |

## Domain 3 — AI Intelligence & Self-Service Operations

| # | Problem | Solution / tool | W'xOps state | Detail doc | Industry practice to study |
|---|---|---|---|---|---|
| A1 | Machine-readable diagnosis graph | XR tree walk: `resourceRefs` → Objects → events | ✅ structural — exists in every package today | [self-service-operations.md](self-service-operations.md#pillar-1--signals-what-exists-whats-missing) | GraphRAG-over-topology root-cause analysis — W'xOps gets the topology half free |
| A2 | Whose error is it? (dev / user / platform) | Taxonomy + two triage rules off the status contract | 📋 written; portal implements the fork | [self-service-operations.md](self-service-operations.md#the-error-taxonomy--developer-side-user-side-platform-side) | Google SRE workbook — on-call triage discipline |
| A3 | Runbooks reachable from the signal | `trigger` frontmatter keyed to status shapes; docs site as runbook CDN | ❌ format proposed; first three runbooks named | [knowledge-architecture.md](knowledge-architecture.md#runbook-anatomy--the-format-worth-standardizing) | Google SRE playbook culture; `runbook_url` convention |
| A4 | Decisions addressable by humans *and* agents | ADR/RFC **issue templates** + ROADMAP "Decided and rejected" as the accepted-log | 🔶 templates in `.github/ISSUE_TEMPLATE/`; ROADMAP table is the index of accepted decisions | [knowledge-architecture.md](knowledge-architecture.md#what-wxops-already-has-mapped-honestly) | [ADR practice](https://adr.github.io/) |
| A5 | Episodic memory (what happened before) | `docs/incidents/` post-mortem convention | ❌ step 3 of adoption | [knowledge-architecture.md](knowledge-architecture.md) | SRE postmortem culture (blameless, distill-or-it-didn't-happen) |
| A6 | Quick cluster health scan | k8sgpt (analyzers, operator mode) | ❌ read-only pilot, step 6 | [self-service-operations.md](self-service-operations.md#the-landscape-honestly) | k8sgpt (CNCF) |
| A7 | Alert investigation to root cause | HolmesGPT — read-only toolsets, consumes runbooks | ❌ same pilot — the closest existing shape to the target | [self-service-operations.md](self-service-operations.md#the-landscape-honestly) | Robusta HolmesGPT |
| A8 | Agent procedural knowledge | Agent Skills (SKILL.md open standard, progressive disclosure) | ❌ pilot step 4; `CLAUDE.md` is the existing proof of the pattern | [knowledge-architecture.md](knowledge-architecture.md#3-skills--procedural-knowledge-as-the-open-standard) | Cross-vendor Skills adoption (Claude, Codex, Gemini CLI, Copilot) |
| A9 | Suggested patch, safely (L4) | Agent output = PR through pr-validate | 🔶 **the gate exists and runs today**; the agent side doesn't | [self-service-operations.md](self-service-operations.md#the-suggest-patch-loop--why-l4-is-structurally-cheap-here) | "AI investigates, human merges" — the 2026 AI-SRE consensus shape |
| A10 | Validate a fix under real traffic | Darlane SRE-agent flow: twin + fileSync + mirrord, evidence on the PR | 📋 designed in full; needs `XDarlane` + tunnel | [darlane.md](darlane.md#sre-agent--intelligence-injector) | mirrord/Telepresence traffic-mirroring practice |
| A11 | Agent safety, audit, data boundary | Guardian phases; in-cluster inference for payload-touching work; agent-as-principal | 📋 designed | [guardian.md](guardian.md) | In-cluster LLM as exfiltration control |
| A12 | Evaluating agent changes | **Golden incidents** — replay past incidents as eval fixtures | ❌ step 5; the ops analogue of `tests/` golden cases | [knowledge-architecture.md](knowledge-architecture.md#architecture-around-the-agent) | LLM-agent eval-set practice, applied to ops |
| A13 | Auto-remediation (L5) | — | ⛔ gated behind Guardian audit, deliberately not a default | [self-service-operations.md](self-service-operations.md#the-operability-ladder) | — |

---

## What must be introduced — consolidated

The "or more should be introduced" answer, split by where the work lands:

**Changes to existing packages** (all `safe`-tier, all follow the `monitoring` pattern):

| Change | Package | Serves |
|---|---|---|
| `status.notReady` reasons | all seven | O5, A1–A3 — the cheapest, highest-leverage item on this page |
| `monitoring.alerts` (PrometheusRule + `runbook_url`) | `XTenantApp` | O6, A3 |
| `scheduling:` block | `XTenantApp`, `XPlatformDatabaseCluster` | M11–M12 |
| Widen `resources` for extended keys (GPU) | `XTenantApp` | M12 |
| `ingress.gslb` block | `XTenantApp` | M8 — blocked on the Traefik↔k8gb spike |

**New XRDs / packages** (both already named in the docs, neither committed):

| Candidate | Serves | Where argued |
|---|---|---|
| `XDarlane` — standalone workspace claim (per-developer, per-agent, TTL) | A10–A11, Guardian's stated prerequisite | [darlane.md](darlane.md#whats-next-xdarlane-xrd) |
| `XPlatformCluster` — CAPI cluster as a platform API, the cluster-scope `tier: dedicated` | M2, M10 | [multi-cluster-scale.md](multi-cluster-scale.md) (currently out-of-scope in [multi-cluster.md](multi-cluster.md#out-of-scope) — graduates when manual provisioning is stable) |

**Platform infrastructure** (not packages — installed once, per hub or per spoke): spoke `ProviderConfig` + credentials · CAPI + `ClusterResourceSet` · Pinniped
Supervisor/Concierge · tunnel (Tailscale/Teleport) · Thanos-or-equivalent + Loki · event exporter (O11) · ExternalDNS routing policies / k8gb · **kernel plane**
— Hubble (O13), runtime-security DaemonSet (O15).

The kernel plane is the one bucket where cost is wildly uneven, so it does not collapse into a single line:

| Component | Serves | Cost | Note |
|---|---|---|---|
| **Hubble** — enable on existing Cilium | O13, O14 | **~zero, if Cilium** | ⚠️ Confirm the CNI first — Cilium is assumed in a *proposed* spoke bootstrap, never confirmed for the running cluster. Set flow-label granularity (L1b) *before* enabling |
| **Retina** — only for non-Cilium spokes | O13 | Medium, per spoke | Optional. The alternative is accepting a non-uniform signal across the fleet, which is probably the right call |
| **Falco** — detect-only, `falcosidekick` push | O15 | Medium + **ongoing tuning** | A privileged DaemonSet on every node. Budget the tuning or do not start |

**No XRD or composition change is required for any of it** — which is the point of the ownership split in
[observability.md](observability.md#ownership-what-belongs-here-and-what-does-not). The kernel plane is collected like every other signal: same push direction,
same label contract, same cardinality ladder. If it ever needs a field on `XTenantApp`, that is the signal something has gone wrong in the design.

**Ecosystem** (around core, not in it): portal correlation fork (A2) · docs site as runbook CDN · ADR/RFC issue templates + `docs/incidents/` convention ·
SRE-agent skill tree ([knowledge-architecture.md](knowledge-architecture.md#the-darlane-sre-agent-mindmap)) · Guardian sidecars · declared-vs-observed
dependency diff (O14 — the XR tree supplies the declared graph, flow data the observed one; the delta is the artefact).

---

## How to use this page

Brainstorming: pick a row, read its detail doc, then its industry reference — the row is the claim, the doc is the reasoning, the reference is the practiced
version at scale. Prioritising: everything ✅ needed no decision; everything 🔶 has a named missing piece; the ❌ rows are ordered inside their detail docs' own
sequenced-adoption sections, not here. And the two ⛔ rows exist so this page also records what *not* to reopen.

The single thread across all three domains, stated once: **the platform's declarative core is what makes every hard problem cheaper** — status makes diagnosis
walkable (A1), one-XR-per-cluster makes fleets portal-shaped (M7), the declared dependency graph makes drift detectable by subtraction (O14), and
PR-through-the-gate makes even AI-suggested fixes as safe as human ones (A9). Every new component above either feeds that core or consumes it; anything that
competes with it (Karmada's API composition-emitted RBAC, ungated auto-remediation) is where the ⛔ rows come from.
