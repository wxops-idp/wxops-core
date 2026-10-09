# Self-Service Operations — observability, runbooks, and intelligence for debugging without the infra team

> **Status: research + direction, not implemented.** This document connects five existing docs into one operational story:
> [`observability.md`](observability.md) (signals), [`status-contract.md`](../../docs/api-reference/status-contract.md) (the first diagnostic surface),
> [`darlane.md`](darlane.md) (the reproduction/validation environment), [`guardian.md`](guardian.md) (the safety layer), and the multi-cluster family
> ([research](multi-cluster.md) · [proposal](multi-cluster-proposal.md) · [scale](multi-cluster-scale.md)) — and asks: what must exist so that **most incidents
> are diagnosed, and patches proposed, without a ticket to the infra team?**

---

## The bottleneck, named precisely

The failure mode this document exists to break:

```
tenant sees an error
  → opens a ticket to the infra team
    → infra engineer context-switches, reproduces (or fails to),
      greps dashboards the tenant cannot see,
      runs kubectl the tenant is not allowed to run
        → finds it was an expired cert / a full PVC / a bad env var
          → tells the tenant, who could have fixed it in minutes
```

Every step is a queue. The infra team becomes the serial bottleneck for a parallel problem, and — the quiet cost — **the diagnosis knowledge never leaves their
heads.** An IDP that provisions apps in seconds but troubleshoots them through tickets has only moved the bottleneck, not removed it.

The thesis: self-service operations is not one tool. It is **three pillars that must reference each other** — signals a tenant can see, runbooks keyed to those
signals, and an intelligence layer that walks both faster than a human — with the platform's existing safety machinery (RBAC seams, Guardian, the test suite)
deciding what the intelligence may *do* about what it finds.

---

## The operability ladder

Where a platform sits on this ladder determines who gets paged:

| Level | Capability | Who troubleshoots |
|---|---|---|
| **L0** | Logs exist somewhere; infra team has kubectl | Infra team, always |
| **L1** | Dashboards per app; tenant can *see* | Infra team, with the tenant watching |
| **L2** | Alerts link to runbooks; runbooks use only commands the reader's RBAC allows | Tenant, for known failure modes |
| **L3** | Correlated diagnosis — a tool walks status → resources → events → logs and names the probable cause | Tenant, for most failure modes |
| **L4** | **Suggested patch** — the diagnosis arrives as a reviewable change (an XR field bump, a values PR), pre-validated | Tenant approves; nobody "troubleshoots" |
| **L5** | Auto-remediation — the change applies itself | Nobody (and nobody *chose* — which is why this is gated, below) |

**W'xOps should target L4 and treat L5 as Guardian-gated, not default.** The platform's own architecture makes L4 unusually reachable — and makes L5 cheap to
gate — for reasons the rest of this document develops. The one-line version: *every fix on this platform is a declarative change, so "suggest a patch" means
"open a PR that the existing test suite validates" — the safety harness for machine-suggested fixes is already built and already gating humans.*

---

## Pillar 1 — Signals: what exists, what's missing

### What exists, and why it matters more than it looks

**The XR status contract is the top of the diagnostic funnel.** Phase 0's status parity work means every one of the seven packages exposes `created`/`ready`
(plus `dependenciesReady` and `darlane.*` on `tenant-app`) — see [`status-contract.md`](../../docs/api-reference/status-contract.md). Before any dashboard is
opened, the portal can already narrow an incident to *which composed thing is unhealthy*:

```
ready: true, dependenciesReady: false   → it's the Certificate, not the app
darlane.ready: false                    → the twin, not production
created: false                          → provisioning never completed — look
                                          at the Objects, not the pods
```

**The composition tree is a machine-readable diagnosis graph.** This is the platform's structural advantage over a generic cluster, and it deserves to be stated
plainly: every app is an XR whose `spec.crossplane.resourceRefs` lists its composed `Object`s, each `Object` wraps exactly one resource and carries its observed
status, and each wrapped resource has events and pods beneath it. Diagnosis is a **tree walk with no guesswork about what belongs to what**:

```
XTenantApp payment-api            status.ready=false
 ├─ resourceRefs → Object payment-api-deployment    Ready=False  ← descend here
 │    └─ Deployment → ReplicaSet → Pod              ImagePullBackOff
 │         └─ events: "manifest for arm64 not found"
 ├─ Object payment-api-certificate                  Ready=True   (skip)
 └─ Object payment-api-service                      Ready=True   (skip)
```

A human does this with four kubectl commands. A tool does it in one loop. On a generic cluster, step one ("what belongs to this app?") is label archaeology;
here it is a field read. Every later pillar leans on this property.

**Per-app scrape is one field away.** The `monitoring` block ([`observability.md`](observability.md)) emits a real ServiceMonitor/PodMonitor with a
composition-enforced `sampleLimit` — the metrics side of self-service is a toggle, not a project.

### What's missing

**1. Status says *which*, not *why* — and the composition already knows why.** `ready: false` tells the portal something composed is unhealthy but forces the
next actor to walk the tree to learn what. Yet the KCL that computes `_appReady` evaluates `_isReady()` per resource — the information exists at render time and
is then thrown away. The single highest-leverage core change this document proposes:

```yaml
status:
  ready: false
  notReady:                     # only present when ready=false
    - resource: app-deployment
      kind: Deployment
    - resource: app-certificate
      kind: Certificate
```

A `safe`-tier additive change in every package (the dxr already exists), a golden case per package, and suddenly the portal's error card, the runbook index,
*and* the diagnosis agent all key off the same field. This is the cheapest rung of the entire ladder.

**2. No global query layer across spokes.** The multi-cluster proposal gives the hub XR *status* from every spoke natively — but metrics, logs, and events stay
per-spoke. On-call across a fleet needs one query surface:

| Option | Shape | Fit |
|---|---|---|
| **Thanos Receive** | Spokes `remote_write`; object-store model | The ecosystem-familiar choice |
| **Grafana Mimir** | Central multi-tenant backend; spokes `remote_write` | The multi-*tenant* choice — per-tenant isolation maps onto the tenancy tiers in [`multi-cluster-scale.md`](multi-cluster-scale.md) |
| **VictoriaMetrics** | Near-drop-in, lightest ops; spokes `remote_write` to vmcluster | The pragmatic choice when metrics-only and ops-light matters most |

> **The full option space — six signal classes, the push-vs-pull topology fork and why it is really a security decision, a detailed tool matrix, the label
> contract, and the cardinality ladder — now lives in [`observability.md` Part
> 2](observability.md#part-2--collection-architecture-single-cluster-fleet-multi-cluster).** Note one correction it makes to the shape below: **Thanos Sidecar
> query fan-out is the wrong variant here**, because it requires the hub to dial each spoke. Only the `remote_write` variants preserve the outbound-only
> posture.

Plus **Loki** for logs (same agent-per-spoke, central store shape — and already named as Guardian's Phase 2 SIEM sink, so one decision serves two docs) and
**OpenTelemetry → Tempo** for traces *later, per-app opt-in* — the `darlane.telemetryPort` field is the existing hook. Spokes push outbound (`remote_write`),
which preserves the proposal's connectivity posture: no new inbound paths to spokes, no observability credentials on the hub.

**3. Alert routing exists; alert *definitions* don't.** kube-prometheus-stack ships Alertmanager, but the platform emits no `PrometheusRule` per app — see
Pillar 2, because rules without runbooks are pages without instructions.

### The edge caveat

The scale doc's node-vs-cluster rule reaches here too: **edge sites are reported up, never queried down.** An EV-charging depot's k3s ships downsampled metrics
to its regional spoke; the hub's global query layer sees regions, not lamp-posts. Designing the on-call surface around querying thousands of edge sites directly
is the observability version of the full-spoke-per-lamp-post mistake.

---

## Pillar 2 — Runbooks as platform contract

The tenant-facing rule that makes runbooks work: **a runbook is reachable from the signal that fired it, and every command in it is executable by the reader.**
Both halves are usually violated — runbooks live in a wiki nobody finds during an incident, and step three is a kubectl command the tenant's RBAC denies (which
is precisely where the ticket to the infra team gets opened, i.e. the bottleneck reasserting itself).

What that means concretely for W'xOps:

**Runbooks are keyed to XR kind + status shape, not to symptoms.** The status contract gives every failure a stable address — that address is the runbook index:

| Signal | Runbook |
|---|---|
| `XTenantApp` `ready=true, dependenciesReady=false` | Certificate not issuing: check ClusterIssuer, DNS01/HTTP01 path, rate limits |
| `XTenantApp` `created=false` > 5 min | Provisioning stuck: read `notReady`, check provider RBAC (`forbidden` events on Objects — the known silent failure), check package health |
| `XTenantDatabase` `ready=false`, `tier: shared` | Pool resolution: does a shared `XPlatformDatabaseCluster` for this environment exist and carry the discovery label? |
| `XGitea* ` `ready` absent, `Synced=False` | Terraform apply failing: Workspace conditions hold the plan error verbatim |
| Monitor emitted but no targets | The four silent-failure modes already tabled in [`observability.md`](observability.md) — release label, component selector, port, provider RBAC |

Each package doc grows a **"Failure modes"** section in exactly the way each grew a `status` section in Phase 0 — same table discipline, worst failures first,
every diagnostic command annotated with the RBAC it needs (namespace read? XR read? nothing above what Pinniped grants a tenant developer).

**Alerts carry their runbook.** When the `monitoring` block grows a sibling `alerts:` (a future `PrometheusRule` emission — same pattern, same tier), the
composition stamps `annotations.runbook_url` pointing into the published docs site. This is also the concrete reason the docs-site decision (mkdocs + Pages,
from the OSS-release discussion) is an *operational* feature and not just marketing: **the docs site is the runbook CDN.** Unpublished runbooks are L2 for the
infra team only — which is L0 with extra steps.

**Escalation is the last step of every runbook, not the first.** Each ends with: what to hand the infra team *if* the tenant-visible layer is exhausted — the XR
name, the `notReady` list, the Object events — so the ticket that does get opened arrives pre-diagnosed. The bottleneck isn't only broken by tickets not opened;
it's broken by tickets that take minutes instead of meetings.

---

## Pillar 3 — Intelligence: from diagnosis to suggested patch

### The landscape, honestly

| Tool | What it is | Where it fits here |
|---|---|---|
| **k8sgpt** (CNCF) | Analyzer-based cluster scan: known failure signatures (CrashLoop, pending pods, misconfigured services) explained in English; operator mode; anonymization; custom analyzers | The quick-check layer — cheap to pilot read-only on hub + spokes. Custom analyzers could encode the XR tree walk |
| **HolmesGPT** (Robusta) | Alert *investigator*: takes a fired alert, runs read-only toolsets (kubectl, Prometheus, Loki, runbooks), returns root-cause narrative | The closest existing shape to Pillar 3 — notably, it consumes **runbooks as input**, which is exactly what Pillar 2 produces |
| **kagent** (CNCF sandbox) | Agentic framework: long-running agents as CRDs in-cluster, tools + model wiring declarative | The framework option if the platform builds its *own* agent rather than adopting an investigator |
| **kubectl-ai / general MCP agents** (Claude etc. with read-only kube + docs access) | Conversational diagnosis over the same surfaces | The flexible option; the grounding corpus below matters more than the harness |
| **Commercial AI-SRE** (Datadog, Komodor, Metoro…) | Hosted investigation over their own telemetry | Conflicts with the in-cluster data-boundary rule below; noted for completeness |

The differentiation is less in the tools than in **what they are grounded on** — and this is where W'xOps is unusually well-positioned, because the grounding
corpus already exists as maintained artifacts:

1. **The status contract** — a stable, documented, machine-readable "where
   does it hurt" for every kind ([`status-contract.md`](../../docs/api-reference/status-contract.md)).
2. **The composition tree** — the diagnosis graph from Pillar 1; no label
   archaeology.
3. **The runbooks** — Pillar 2's failure-mode tables, in the same repo the
   agent can read.
4. **The golden tests and invariants** — `tests/` is a *behavioural
   specification* of what rendered output must look like. An agent that can
   read `expected.yaml` knows what healthy looks like, byte for byte.

### The suggest-patch loop — why L4 is structurally cheap here

On this platform, **every fix is a declarative change**: an XR field, a composition edit, a values bump in the GitOps repo. Which means "suggest a patch" has an
exact, safe implementation — *the agent's output is a PR*:

```
alert / tenant report
  → agent walks: XR status → notReady → Object events → logs/metrics
  → diagnosis with evidence (the L3 artifact)
  → proposed change:
      tenant-scope fix   → PR to the tenant's GitOps repo (XR field change)
      platform-scope fix → PR to wxops-core (composition/XRD change)
  → pr-validate runs: XRD conformance, 19 golden cases, 18 invariants,
      xpkg build, KCL drift — THE SAME GATE HUMANS PASS
  → human merges → ArgoCD/Crossplane reconciles → agent verifies status flipped
```

The line worth internalizing: **the test suite built to gate human contributions is, unchanged, the safety harness for machine-suggested patches.** An agent
cannot merge a composition change that drops the Prometheus release label, emits RBAC, or breaks a golden case — the gate neither knows nor cares that the
author was a model. This is the payoff of having made the merge gate strict *before* pointing intelligence at it, and it is why L4 here does not require
trusting the model: it requires trusting the gate, which is already the posture for people.

**And the validation environment already has a name: Darlane.** The [SRE-agent flow in `darlane.md`](darlane.md) — inject fix into the twin, mirror real
traffic, attach validation evidence to the PR — is the *empirical* leg of the same loop: pr-validate proves the change is well-formed; the Darlane run proves it
fixes the incident. A PR carrying both is reviewable in minutes. Under the `XDarlane` agent model, the agent holds its own claim (`payment-api-sre-hotfix`,
ttl-bounded) with its own auditable SA identity — the RBAC seam decided in Phase 0 (`status.darlane.serviceAccountName`, GitOps-authored binding) is exactly
what makes an agent identity scopeable without touching core.

### The guardrails — Guardian's job, stated from this side

[`guardian.md`](guardian.md) already carries the principles; this document inherits four of them as hard constraints on any intelligence layer:

- **Read-only by default; the only write path is a PR.** No agent holds
  kubectl write on any cluster. (L5 — an agent applying its own change — is
  not "more automation", it is a *different trust decision*, and it waits for
  Guardian's audit phase to exist.)
- **In-cluster inference for anything that sees production data.** Guardian's
  exfiltration argument — a sidecar that forwards live user payloads to an
  external LLM API is a data-leak path the audit layer itself would flag —
  applies with equal force to a diagnosis agent reading production logs.
  Diagnosis over *metadata* (statuses, events, manifests) is a lighter
  boundary than diagnosis over *payloads*; the corpus an agent may read
  should be tiered accordingly.
- **The agent is a principal.** Pinniped identity or a dedicated SA per
  agent, scoped by the same GitOps-authored RBAC as humans, sessions
  TTL-bounded (the `XDarlane` claim model), all activity through the audit
  stack. "The AI did it" must resolve to a name in a log.
- **Advisory posture** — Guardian's findings do not block the inner loop, and
  neither does the diagnosis layer: it accelerates the human decision, it is
  not the decision.

### Multi-cluster on-call, assembled

Across the fleet, the pieces land where the proposal already put them: **the hub is the single pane** (XR status arrives natively cross-cluster; the global
query layer adds metrics/logs), **spokes push signals outbound** (no new credentials, no inbound paths), **humans reach spokes through Pinniped + the tunnel**
(Option D — and the tunnel serves the *agent's* Darlane sessions identically), and **edge reports up** (the intelligence layer's writ, like GitOps's, ends at
the regional spoke).

---

## The error taxonomy — developer-side, user-side, platform-side

Everything above treats "an incident" as one thing. In practice the first triage question — and the one the tooling should answer *for* the person, not ask of
them — is **whose error is this?** Three classes, three owners, three different fix paths:

| Class | Typical errors | First signal | Owner | Fix lands as |
|---|---|---|---|---|
| **Developer-side** — the tenant's own app or config | Bad image tag / single-arch image on the wrong pool · crashing code · missing env or `secretsFrom` reference wired to a Secret that doesn't exist · resource limits too low (OOMKill) · wrong `monitoring.port` · probe path 404 | XR `created: true, ready: false`; pod state (`CrashLoopBackOff`, `ImagePullBackOff`); app logs | Tenant developer | PR to the tenant's repo, or an XR field change |
| **User-side** — end users are hurt while everything looks green | 5xx spikes · latency degradation · one region unhealthy behind GSLB · session loss across regions · errors only under real traffic patterns | Alerts from the `monitoring` block (`PrometheusRule`, once built); GSLB health flips; traces — **not** XR status, which stays `ready: true` throughout | Tenant developer first, escalating by evidence | Hotfix validated in Darlane against mirrored traffic → PR |
| **Platform-side** — the machinery under the app | Provider RBAC `forbidden` on an Object (the known silent class) · composition bug after a package bump · cert `ClusterIssuer` broken · shared DB pool exhausted or discovery label missing · spoke credential/`ProviderConfig` broken · Vault path collision | XR `created: false` or `notReady` pointing at an Object whose events show reconcile errors; the same failure across *many* tenants at once | Infra team | PR to wxops-core or the platform GitOps repo — through the same gate |

Two triage rules fall straight out of the status contract:

1. **`ready: true` + users hurting ⇒ user-side.** The declarative layer has
   converged; the problem lives in runtime behaviour. Skip the tree walk, go
   to metrics/traces — this is HolmesGPT territory, not k8sgpt territory.
2. **Many tenants' XRs degrading at once ⇒ platform-side, stop self-serving.**
   One tenant's `notReady` is their runbook; twenty tenants' identical
   `notReady` is an infra page. The portal (or the diagnosis agent) should
   make this fork automatically — correlation across XRs is exactly what the
   hub's single-pane position is for, and it is the difference between twenty
   confused tickets and one pre-diagnosed page.

The taxonomy is also an honesty mechanism in the escalation path: a runbook's final "hand to infra" step is legitimate **only** for the third column.
Developer-side errors escalated to infra are the bottleneck reasserting itself; platform-side errors left with the tenant are the platform hiding behind
self-service.

### The tools, mapped together

Every tool named in this document, placed: which error class it serves, which pillar it belongs to, and which build step (from the sequence below) makes it
real. This is the "which plan makes these work together" view:

| Tool / artifact | Dev-side | User-side | Platform-side | Pillar | Build step |
|---|:-:|:-:|:-:|---|---|
| XR status contract + `notReady` reasons | ● primary | ○ rules it out | ● primary | 1 — Signals | 1 |
| Composition tree walk (`resourceRefs` → Objects → events) | ● | — | ● | 1 | exists |
| `monitoring` block (ServiceMonitor/PodMonitor) | ○ | ● primary | — | 1 | exists (v0.4.0) |
| `monitoring.alerts` + `runbook_url` | ○ | ● | ○ | 1→2 bridge | 4 |
| Global metrics (Thanos/Mimir/VM) + Loki | ○ | ● | ● cross-tenant correlation | 1 | 5 |
| Failure-mode runbooks, RBAC-annotated | ● | ● | ● (escalation evidence) | 2 | 2–3 |
| k8sgpt (analyzer scan) | ● quick check | — | ● fleet sweep | 3 | 6 |
| HolmesGPT (alert investigation) | ○ | ● primary | ○ | 3 | 6 |
| Darlane (fileSync, exec, twin) | ● reproduce & fix | — | — | 3 (validation) | exists |
| Darlane + mirrord (SRE-agent flow) | — | ● validate under real traffic | — | 3 | 7 |
| pr-validate gate (tests, invariants) | ● gates the fix | ● gates the fix | ● gates the fix | 3 (safety) | exists |
| Guardian (tools/scan/audit/ai) | ○ session tooling | ● audits hotfix sessions | — | 3 (guardrail) | 8 |
| Pinniped + tunnel (Option D) | ● reach the spoke | ● | ● | cross-cutting | proposal |
| Portal (status cards, correlation fork) | ● entry point | ● entry point | ● auto-escalate | consumer of all | portal project |

● = primary instrument for that class · ○ = supporting · — = not its job

Read as three lanes converging on one gate:

```
DEV-SIDE          status/notReady → runbook → Darlane repro ──┐
USER-SIDE         alert → HolmesGPT → Darlane + mirrord ──────┤→ PR → pr-validate
PLATFORM-SIDE     XR correlation → infra + evidence ──────────┘      → merge
                                                                     → reconcile
                                                                     → status verifies
```

The three lanes differ in everything — signal, tool, owner — except the ending: **every class of fix, from a tenant's env-var typo to an infra composition patch
to an agent's validated hotfix, exits through the same PR gate and re-verifies through the same status contract.** That convergence is the plan; the tools are
interchangeable parts within their lane.

---

## What to build — sequenced

Ordered so each step pays for itself before the next; the first three need no new components at all.

| # | Step | Kind | Advances |
|---|---|---|---|
| 1 | **`status.notReady` reasons** in all KCL packages (+ gitea equivalents from Workspace conditions where expressible) | Core, `safe`, small KCL + golden cases | The single field every later step keys off |
| 2 | **"Failure modes" section per package doc**, RBAC-annotated commands, escalation-with-evidence as the last step | Docs only | L2 for humans; grounding corpus for L3 |
| 3 | **Publish the docs site** (mkdocs + Pages — already an open Phase 4 item; this is the operational argument for it) | Docs infra | Runbook URLs become real |
| 4 | **`monitoring.alerts`** — `PrometheusRule` emission with `runbook_url` stamped, same pattern/tier as the monitor emission | Core, `safe` (+ provider RBAC for `prometheusrules`) | Signals → runbooks wiring |
| 5 | **Global query layer decision** (Thanos as default candidate; Mimir if tenancy tiers win; VM if ops-light wins) + Loki (double-serves Guardian Phase 2) | Platform infra | Multi-cluster L1 |
| 6 | **Read-only diagnosis pilot** — HolmesGPT (or k8sgpt) on the hub, grounded on items 1–3, metadata-tier corpus only | Pilot, no core change | L3 |
| 7 | **Agent→PR loop** — diagnosis output lands as a PR through pr-validate; Darlane validation evidence attached per the SRE-agent flow | Ecosystem | L4 — the target |
| 8 | **Guardian Phase 1→2** (tools, scan, then audit) | Per guardian.md | The precondition for ever discussing L5 |

Items 1–4 are core-repo work in existing patterns. Items 5–8 are the ecosystem: they belong to the platform around wxops-core (GitOps repo, portal, agent
infra), with core contributing only fields, docs, and the gate it already runs.

---

## References

**Internal — the docs this one connects**
- [`knowledge-architecture.md`](knowledge-architecture.md) — the knowledge substrate under Pillar 3: taxonomy, representations, and the SRE-agent skill mindmap
- [`status-contract.md`](../../docs/api-reference/status-contract.md) · [`observability.md`](observability.md) — Pillar 1's foundations
- [`darlane.md`](darlane.md) — the AI-agent and SRE-agent flows; the validation environment
- [`guardian.md`](guardian.md) — the safety principles Pillar 3 inherits
- [`multi-cluster.md`](multi-cluster.md) · [`multi-cluster-proposal.md`](multi-cluster-proposal.md) · [`multi-cluster-scale.md`](multi-cluster-scale.md) — the fleet topology on-call runs across

**Diagnosis / intelligence**
- [k8sgpt](https://k8sgpt.ai/) — analyzer-based cluster diagnosis (CNCF)
- [HolmesGPT](https://github.com/robusta-dev/holmesgpt) — alert investigation over read-only toolsets and runbooks
- [kagent](https://kagent.dev/) — in-cluster agent framework (CNCF sandbox)

**Signals at fleet scale**
- [Thanos](https://thanos.io/) · [Grafana Mimir](https://grafana.com/oss/mimir/) · [VictoriaMetrics](https://victoriametrics.com/) — the global-metrics options
- [Loki](https://grafana.com/oss/loki/) — logs; also Guardian's Phase 2 sink
- [OpenTelemetry](https://opentelemetry.io/) · [Tempo](https://grafana.com/oss/tempo/) — traces, later and opt-in

**Runbook practice**
- [Prometheus alerting annotations (`runbook_url`) convention](https://prometheus.io/docs/practices/alerting/)
- [Google SRE workbook — on-call and playbooks](https://sre.google/workbook/on-call/)
