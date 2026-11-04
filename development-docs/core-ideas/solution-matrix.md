# Solution Matrix — where every idea stands

> [!NOTE]
> **Status: index, kept current by hand.** One row per problem: the chosen answer, where W'xOps is today, and the doc that holds the reasoning. Read a row,
> then its doc — the row is the claim, the doc is the argument. Row IDs are stable; a retired ID is never reused.

| | Meaning |
|---|---|
| ✅ | Shipping in a current package |
| 🔶 | Mechanism exists, a named piece is missing |
| 📋 | Designed in a doc or RFC, not built |
| ❌ | Not started |
| ⛔ | Rejected — do not reopen without new information |

**Contents:** [Next up](#next-up) · [Identity & access](#identity--access) · [Multi-cluster](#multi-cluster) · [Observability](#observability) ·
[AI & self-service](#ai--self-service) · [Rejected](#rejected) · [Where the work lands](#where-the-work-lands)

---

## Next up

The current focus, in order. Everything else on this page waits behind it.

1. **The label foundation** — `wxops.cloud/owner` required, immutable, stamped onto workloads, not forgeable ([access model](access-model.md#the-label-foundation)).
2. **[RFC-008](../rfc/008-built-in-tools-identity-and-catalog.md) Phase 1** — OpenBao on `provider-vault` (hub only), adopting the hand-made setup (I4).
3. **[RFC-009](../rfc/009-scm-personas.md)** — `XPersona`, `XPersonaBinding`, `XPlatformPolicy`, after the Pinniped/Kyverno `userInfo` spike (I3, I5, I6);
   RFC-005's owner rules ride on its `XPlatformPolicy` templates.

---

## Identity & access

| # | Problem | Answer | State | Where |
|---|---|---|---|---|
| I1 | One login for every tool | SCM → Dex; `groups: <org>:<team>`; one `XOIDCClient` per tool | ✅ | [RFC-004](../rfc/004-dex-identity-and-portal-authentication.md) |
| I2 | Which teams reach the `groups` claim | Generated from `XScmTeam`s labelled `scm.wxops.cloud/oidc-login` | ✅ | [oidc-connector](../../docs/api-reference/auth/oidc-connector.md#choosing-which-teams-can-sign-in) |
| I3 | What a team may reach, in every tool | **Personas** — `XPersona` collects teams; `XPersonaBinding` binds the persona roles (`view` plus W'xOps write pieces, by aggregation) per owned namespace; `XPlatformPolicy` renders eight Kyverno guardrail templates | ✅ in Kubernetes (RFC-009); 📋 in the platform tools (RFC-008) | [RFC-009](../rfc/009-scm-personas.md) · [access model](access-model.md#the-scm-persona) |
| I4 | Tool configuration nobody converges on | Built-in tools on their own native objects — OpenBao (`provider-vault`), Argo CD (`AppProject`), Grafana (grafana-operator) — one login, persona groups, a catalog; no W'xOps kind per tool | 📋 Phase 1 next | [RFC-008](../rfc/008-built-in-tools-identity-and-catalog.md) |
| I5 | Who may write which XR | Core kinds stay cluster-scoped: `wxops:platform-*` bound by `XPersonaBinding`, sealed by the `wxops.cloud/owner` label (`owner-seal`) | 📋 label gaps first | [RFC-005](../rfc/005-git-mapped-authorization.md) · [access model](access-model.md#the-label-foundation) |
| I6 | `kubectl` on any cluster, as yourself | Pinniped (Supervisor trusts Dex, Concierge per cluster, bootstrap) → RBAC → Kyverno | 🔶 Pinniped installed; `userInfo` in Kyverno to spike | [access model](access-model.md#kubernetes-pinniped--rbac--kyverno) |
| I7 | Access that ends on its own | A time-bound `XPersonaBinding` with `expires-at`; a Kyverno `DeletingPolicy` deletes it and Crossplane removes its RoleBindings | 📋 | [access model](access-model.md#temporary-access-checked-then-terminated) |
| I8 | Explaining access — who can reach X, what a PR changes | Kubernetes answers it (`kubectl auth can-i --list --as-group`); a PR report built on it later; the API server audit log for what happened, PolicyReports optional | 📋 | [RFC-009](../rfc/009-scm-personas.md#audit) · [access model](access-model.md#changing-access-is-a-pull-request) |
| I9 | Tenant kinds other teams cannot even read | Namespaced tenant kinds in the `XTenantApp` / `XTenantDatabase` redesign; the namespace is the owner, bound per owned namespace | 📋 direction — namespaced managed resources exist in every installed provider (`.m` kinds) | [darlane](darlane.md#xdarlane--a-workspace-claim-of-its-own) · [RFC-005](../rfc/005-git-mapped-authorization.md#alternatives) |

## Multi-cluster

Direction since 2026-10-20: W'xOps **manages clusters it is given**, spokes dial out, a CoreDNS-named L7 backbone connects them. IDs M2–M6 and M13 belonged to
the archived CAPI-era design and are retired.

| # | Problem | Answer | State | Where |
|---|---|---|---|---|
| M1 | Target cluster as an XR parameter | `spec.parameters.cluster` → `providerConfigRef` | 🔶 threaded, unused; becomes the single-cluster case if Crossplane runs per spoke (M18) | [multi-cluster](multi-cluster.md#where-compositions-run) |
| M7 | Fleet API | One XR per cluster; the portal fans out | ✅ by architecture | [multi-cluster](multi-cluster.md#where-core-fits) |
| M15 | Join a cluster without holding its credentials | Argo CD Agent (spoke dials out, gRPC + mTLS) + one membership XR per cluster | 📋 | [multi-cluster](multi-cluster.md#the-management-plane) |
| M16 | Reach another cluster's service without CNI lock-in | W'xOps CoreDNS resolver per cluster, DoT between peers, one mTLS gateway per cluster | 📋 | [multi-cluster](multi-cluster.md#the-naming-plane--coredns-as-the-backbone) |
| M17 | Specialised clusters — OpenBao, GPU inference, the LGTM stack — used fleet-wide | Reached by name over the backbone | 📋 | [multi-cluster](multi-cluster.md#problems-the-backbone-solves) |
| M18 | Where compositions run | Crossplane on each spoke, packages and XRs delivered by Argo | 📋 open decision | [multi-cluster](multi-cluster.md#where-compositions-run) |
| M8 | Users routed to the nearest healthy cluster | k8gb (CoreDNS) or DNS-provider routing policies | ❌ | [archived scale study](../_archives/multi-cluster-scale.md#gslb-implementations--three-options-one-field-tested) |
| M9 | Multi-region data | Region-pinned by default → CNPG replicas for DR → distributed SQL only if RPO≈0 | ❌ framework written | [archived scale study](../_archives/multi-cluster-scale.md#the-data-layer-decides-the-region-strategy-not-the-other-way-round) |
| M10 | Tenancy isolation tiers | Namespace → vCluster → dedicated cluster | 📋 direction | [archived scale study](../_archives/multi-cluster-scale.md#axis-2--multi-tenancy-the-isolation-spectrum) |
| M11 | Edge and ARM sites | k3s or Talos per autonomous site, joined like any cluster | ❌ direction | [archived scale study](../_archives/multi-cluster-scale.md#worked-use-cases) |
| M12 | Mixed hardware (GPU, ARM) | `scheduling:` block + widened `resources` keys + multi-arch images | ❌ verified gap | [archived scale study](../_archives/multi-cluster-scale.md#the-verified-wxops-gaps) |

## Observability

| # | Problem | Answer | State | Where |
|---|---|---|---|---|
| O1 | Per-app metrics scrape | `ServiceMonitor`/`PodMonitor` emission | ✅ `XTenantApp` `monitoring` | [observability](observability.md) |
| O2 | Readiness the portal can poll | `created`/`ready`/`synced`/`syncMessage` on every package | ✅ all fourteen | [status contract](../../docs/api-reference/status-contract.md) |
| O3 | Partial health (app up, TLS pending) | `ready` / `dependenciesReady` split | ✅ `XTenantApp` | [status contract](../../docs/api-reference/status-contract.md) |
| O4 | Cardinality in a shared Prometheus | `sampleLimit` set by the composition | ✅ | [observability](observability.md#cardinality) |
| O5 | Status says *which*, not *why* | `status.notReady` reasons | ❌ `safe`, all packages | [self-service](self-service-operations.md#whats-missing) |
| O6 | Alerts that carry their runbook | `PrometheusRule` + `runbook_url` | ❌ future `monitoring.alerts` | [self-service](self-service-operations.md#pillar-2--runbooks-as-platform-contract) |
| O7 | One metrics view across clusters | Push, not pull — Alloy `remote_write` to the LGTM stack on the hub (or a dedicated observability cluster) over the backbone | ❌ platform infra | [observability](observability.md#the-decisive-fork-push-or-pull) · [multi-cluster](multi-cluster.md#problems-the-backbone-solves) |
| O8 | Central logs (also the Darlane session-audit sink) | Loki + Alloy | ❌ platform infra | [observability](observability.md#logs-traces-events-profiles) |
| O9 | Traces | OpenTelemetry → Tempo, per-app opt-in | ❌ deferred | [observability](observability.md#the-signal-matrix--what-to-collect-per-tier) |
| O10 | Edge fleets | Report up, never query down | 📋 rule stated | [self-service](self-service-operations.md#the-edge-caveat) |
| O11 | Kubernetes events | Event exporter → log store | ❌ — best signal per effort on this page | [observability](observability.md#the-signal-matrix--what-to-collect-per-tier) |
| O12 | Cross-cluster label contract | `externalLabels.cluster` = the cluster's name | ❌ free now, impossible to retrofit | [observability](observability.md#the-label-contract--the-cheap-prerequisite) |
| O13 | Network flows | Hubble where a cluster runs Cilium; nothing assumed elsewhere | ❌ per cluster — W'xOps does not choose the CNI | [observability](observability.md#the-kernel-plane--flows-and-runtime-security) |
| O14 | Declared vs observed dependencies | Diff the XR tree against flow data | ❌ needs O13 | [observability](observability.md#where-this-pays-off-for-the-sre-agent-goal) |
| O15 | Runtime security signal | Falco, detect-only | ❌ the cost is rule tuning | [threat model](security-threat-model.md) · [observability](observability.md#detect-versus-enforce-is-the-real-axis) |

## AI & self-service

| # | Problem | Answer | State | Where |
|---|---|---|---|---|
| A1 | Machine-readable diagnosis graph | XR tree: `resourceRefs` → Objects → events | ✅ every package | [self-service](self-service-operations.md#pillar-1--signals-what-exists-whats-missing) |
| A2 | Whose error is it? | Taxonomy + two triage rules off the status contract | 📋 the portal implements it | [self-service](self-service-operations.md#the-error-taxonomy--developer-side-user-side-platform-side) |
| A3 | Runbooks reachable from the signal | `trigger` frontmatter keyed to status shapes | ❌ format proposed | [knowledge](knowledge-architecture.md#runbook-anatomy--the-format-worth-standardizing) |
| A4 | Decisions addressable by humans and agents | RFC and ADR files + their indexes; issue templates for intake | 🔶 indexes exist; not machine-tagged | [RFC index](../rfc/README.md) · [ADR index](../adr/README.md) |
| A5 | What happened before | `docs/incidents/` post-mortems | ❌ | [knowledge](knowledge-architecture.md) |
| A6 | Quick cluster health scan | k8sgpt, read-only | ❌ pilot | [self-service](self-service-operations.md#the-landscape-honestly) |
| A7 | Alert investigation to root cause | HolmesGPT, read-only, consuming runbooks | ❌ pilot | [self-service](self-service-operations.md#the-landscape-honestly) |
| A8 | Agent procedural knowledge | Agent Skills; `CLAUDE.md` is the existing proof | ❌ pilot | [knowledge](knowledge-architecture.md#3-skills--procedural-knowledge-as-the-open-standard) |
| A9 | A suggested fix, safely | Agent output = a PR through `pr-validate` | 🔶 the gate runs today; the agent side does not | [self-service](self-service-operations.md#the-suggest-patch-loop--why-l4-is-structurally-cheap-here) |
| A10 | Validate a fix under real traffic | Darlane twin + mirrord, evidence on the PR | 📋 needs `XDarlane` | [darlane](darlane.md#agents) |
| A11 | Agent safety and data boundary | Agents as principals with personas; in-cluster inference for payloads; session audit | 📋 | [access model](access-model.md#data-boundary-and-audit) · [darlane](darlane.md#session-safety--tools-audit-data-boundary) |
| A12 | Evaluating agent changes | Golden incidents replayed as fixtures | ❌ | [knowledge](knowledge-architecture.md#architecture-around-the-agent) |

## Rejected

| # | What | Why | Where |
|---|---|---|---|
| M14 | Composition-emitted RBAC | The provider would become a privilege-escalation path, and RBAC belongs in a reviewed diff | [ROADMAP](../_archives/ROADMAP.md#decided-and-rejected) · [access model](access-model.md#open-decisions) (a bind-only exception would need an ADR) |
| A13 | Auto-remediation by default | A different trust decision from a PR; gated until session and agent audit exist | [self-service](self-service-operations.md#the-operability-ladder) |
| — | Cluster provisioning (CAPI) inside W'xOps | Pulls in node lifecycle and makes the hub a fleet trust root | [multi-cluster](multi-cluster.md#what-changed-and-why) |
| — | A CNI-level flat network between clusters | Ties the fleet to one CNI; names at L7 do the job | [multi-cluster](multi-cluster.md#the-idea) |
| — | A runtime authorization engine, or grants generated per login | No login hook, cleanup on every session, worse audit | [access model](access-model.md#what-wxops-does-not-build) |
| — | Third-party writes from Kyverno admission | Admission must be side-effect free; Crossplane writes | [access model](access-model.md#temporary-access-checked-then-terminated) |
| — | A competing fleet API (Karmada `PropagationPolicy`) | The XR is the fleet API | M7 |

---

## Where the work lands

**Existing packages** (all `safe`): `status.notReady` (O5) · `monitoring.alerts` (O6) · `scheduling:` and wider `resources` (M12) · `wxops.cloud/owner`
stamped onto workloads (I5).

**New packages:** a cluster membership kind (M15) · `XDarlane` (A10, A11) · `persona`, `persona-binding`, `platform-policy` in `package/auth/`, with `aggregate-*` roles in `providers/rbac/` (I3, I5).

**Platform infrastructure** (installed, not composed): Pinniped and the Kyverno controller, at bootstrap · grafana-operator and `provider-vault` on the hub (RFC-008) · Argo CD Agent principal and agents · the W'xOps mesh resolver and
gateways · Alloy and the LGTM stack · an event exporter (O11) · k8gb (M8) · Hubble or Falco where chosen (O13, O15).

**Around core:** the portal's triage fork (A2) · a docs site serving runbooks (A3) · `docs/incidents/` (A5) · the SRE-agent
skill tree (A8).
