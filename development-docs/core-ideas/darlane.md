# Darlane — a production-context twin for debugging, validation and agents

> [!NOTE]
> **Status: shipped inside `XTenantApp`** (`spec.parameters.darlane`); the standalone `XDarlane` is the future. Every field is in the
> [API reference](../../docs/api-reference/_archives/tenant-app.md#darlane-debug-twin-deployment). This page is the why, what ships, and what comes next — the
> [detailed edition](../_archives/darlane-detailed.md) keeps every workflow pattern, scenario playbook and trade-off for anyone diving deeper.

---

## The problem it solves

Debugging and validating a change needs **production context** — the real secrets, the real database, the real network, real traffic shapes. The usual ways
to get it are all bad:

- **`kubectl exec` / `kubectl debug` into production** puts you inside the blast radius: an expensive command can OOM the pod serving real users, every call is
  made with the production identity, every write lands in a production container.
- **A sandbox** duplicates secrets, clones the database and rewires monitoring — and is still not production.
- **The CI/CD loop** takes 8–15 minutes to test a one-line change, which is far too slow for prompt templates, agent logic or a hotfix under pressure.
- **An AI agent** needs a safe, reproducible place to run its change against real infrastructure before anyone merges it.

Darlane's answer: **a second Deployment beside the app, wired to the same infrastructure, isolated by default, and given production traffic only when that is
declared in the XR.** It costs one Deployment at `replicas: 0` when nobody is using it.

### Darlane or `kubectl debug`?

| | `kubectl debug` / ephemeral container | Darlane |
|---|---|---|
| Where it runs | Inside the production pod | A separate `<appName>-darlane` Deployment |
| Production impact | Shares the pod's limits and namespaces | None — own resources, own lifecycle |
| Production context | Yes | Yes — inherits `env`, `envFrom`, `secretsFrom` |
| Code changes | Image fixed at injection | `fileSync` + a hot-reload command |
| Real traffic | No | Weighted, cookie-pinned or header-routed, opt-in |
| Declared and reviewed | An ad-hoc command | Fields in the XR, in Git |
| **Inspect the live process** (`strace`, `/proc`) **or a crashed pod** (`--copy-to`) | **Yes — use `kubectl debug` for this** | No, by design |

---

## What ships today

`darlane.enabled: true` composes `<appName>-darlane` in the app's namespace.

| Capability | Fields | Notes |
|---|---|---|
| Twin, scale-to-zero | `enabled`, `replicas` (default `0`), `image`, `command`, `args`, `containerPort`, `resources`, `securityContext`, `volumes` | No `Service` or route unless traffic is configured |
| Production context | inherited `env` / `envFrom` / `secretsFrom`; `darlane.env` layered on top | The twin's value wins on a key collision — feature flags without a flag service |
| Code into the pod | `fileSync` (writable `emptyDir` at `mountPath`, `initFromImage`) | Works under `readOnlyRootFilesystem`; pair with `--reload`, `nodemon`, `air`. Sync with `kubectl cp`, mutagen or the `wxops` CLI |
| Real traffic | `trafficWeight`, `stickySession`, `headerRouting` | A Traefik `TraefikService` weighted split and/or a higher-priority header route — see [below](#combining-traffic-modes) |
| Telemetry | `telemetryPort` | A `ClusterIP` Service for OTel/Prometheus scraping |
| Identity | `serviceAccount` (`create`, `name`, `annotations`) | The composition creates the ServiceAccount and publishes its name; **RBAC is never composed** — GitOps binds it |
| Production guard | `productionOverride` | Required when `environment: prod`; enforced in the composition, visible in the PR |
| Lifetime | `ttl` | **Not enforced** — expiry was dropped 2026-10-22; the field and `status.darlane.ttl` stay (the API is additive-only). See [Safety](#safety) |
| Status | `status.darlane.{ready, replicas, trafficMode, ttl, serviceAccountName}` | `trafficMode`: `none`, `weighted`, `header` or `both` |

**Scale through the XR, not `kubectl scale`.** The Deployment is Crossplane-managed; a direct scale is reverted on the next reconcile.

```bash
kubectl patch xtenantapp <xr> --type=merge -p '{"spec":{"parameters":{"darlane":{"replicas":1}}}}'
kubectl -n <ns> exec -it deploy/<appName>-darlane -- bash     # real secrets, real database, not production
kubectl patch xtenantapp <xr> --type=merge -p '{"spec":{"parameters":{"darlane":{"replicas":0}}}}'
```

### Combining traffic modes

`trafficWeight`, `stickySession` and `headerRouting` are independent. `headerRouting` adds a higher-priority route; `trafficWeight` decides where the
catch-all route sends everything else.

| `trafficWeight` | `stickySession` | `headerRouting` | Behaviour |
|---|---|---|---|
| `0` | — | off | Debug only — no external traffic reaches the twin |
| `0` | — | on | **Explicit opt-in** — only requests carrying the header reach the twin; good for internal QA |
| `20` | off | off | Raw split — each request independently 80/20 |
| `20` | on | off | **Cohort A/B** — a cookie pins each browser session to one variant |
| `20` | on | on | Cohort A/B, plus the header as a developer escape hatch |
| `100` | — | off | Full canary — all traffic to the twin |

**mirrord layers on top** without touching the XR. It runs on the developer's machine and mirrors (read-only copy) or steals (serves) traffic at the pod:

| Traffic config | mirrord | What you get |
|---|---|---|
| `trafficWeight: 0` | `mirror` on the twin or the app | Real request shapes, locally, with production untouched |
| `headerRouting` on | `steal --filter <header>` | Only opted-in requests reach local code — two independent guards |
| `trafficWeight: 20` + sticky | `steal` | The twin's cohort is served by the developer's process |

```bash
# The safest steal: the header gates at the route, --filter gates again at the pod.
mirrord exec --target deployment/<appName>-darlane --target-namespace <ns> \
  --steal --filter "X-Target-Env: darlane" -- uvicorn main:app --reload
```

Prefer **mirrord** (no cluster footprint, per-session, single-pod scope); **Telepresence** is the fallback for teams already on it. Neither is installed by
the composition. The detailed edition walks through
[every pattern](../_archives/darlane-detailed.md#combined-workflow-patterns) and [scenario playbook](../_archives/darlane-detailed.md#scenario-playbooks).

### What it is not

| Need | Use instead |
|---|---|
| Per-user targeting, instant flag flips, experiment statistics | A flag service — Unleash, Flagsmith, GrowthBook |
| A canary that runs for days, with automated analysis and rollback | Argo Rollouts |
| A large share of production traffic | The app itself — the twin is one pod with no autoscaler |
| The live process's memory, or a crashed pod's state | `kubectl debug` |

Darlane is for the **inner loop**: pre-PR validation, QA opt-in, hotfixes, canaries measured in hours.

---

## Safety

| Scenario | Risk | Guardrail |
|---|---|---|
| Mirror, staging | Low — read-only | — |
| Steal, staging | Medium — local code answers real requests | Header filter |
| Mirror, prod | Medium — real user data is visible | `productionOverride: true` |
| Steal, prod | High — local code serves production users | `productionOverride` + mirrord `--steal` + session audit |
| Abandoned session | Medium — a stale twin keeps running | Scale it back to `replicas: 0` in the XR — nothing expires it today |

**Expiry is not enforced** — dropped 2026-10-22. The old policy deleted the twin's Deployment, which Crossplane recreated from the XR, so it needed a second
action to stick (and it never fired: it selected the wrong label). It has been removed. Expiry returns with the
`XTenantApp` redesign below, done properly: the twin is its own claim, a Kyverno `DeletingPolicy` deletes the claim once `ttl` has passed, and Crossplane
removes what it composed — one action, nothing fighting back. Until then, a twin runs until someone sets `replicas: 0`.

### Access

The composition creates the ServiceAccount and publishes it as `status.darlane.serviceAccountName`; it never emits a `Role` or `RoleBinding` (a
[rejected design](../_archives/ROADMAP.md#decided-and-rejected)). Who may exec into, port-forward to and scale a twin is decided in GitOps — under the
[access model](access-model.md), by the team's persona: a developer persona reads `pods/log` and scales Deployments in its own namespaces;
the owners persona adds `pods/exec` and `pods/portforward`; an agent persona reads logs and events only. Kyverno then narrows `exec` to the owners persona,
in namespaces its team owns (`exec-guard`).

## Session safety — tools, audit, data boundary

A Darlane session can see real secrets, real database connections and — in steal mode — real user traffic. These rules make that access defensible. They
come from the [archived Guardian design](../_archives/guardian.md); the sidecar framework itself is not planned, and what remains is owned by the Darlane
composition, not by a separate layer.

1. **The composition owns the pod spec.** Anything beside the developer's container — a tools mount, an audit container — is composed by the Darlane
   composition, deterministic and testable with the golden tests. No controller or mutating webhook injects containers after the fact; Kyverno may *require* a
   setting by validation, never add it.
2. **Debug tooling is platform-owned.** One versioned, scanned tools image per ecosystem (general: `curl`, `jq`, `strace`, `tcpdump`, `grpcurl`; Python:
   `debugpy`, `py-spy`; Node: inspector, `clinic`; Go: `dlv`, `pprof`; databases: `psql`, `redis-cli`), copied by an init container into an `emptyDir` and
   mounted read-only. The root filesystem stays read-only; nobody runs `apt install` in a session.
3. **Production steal mode needs an audit record.** Shell commands, file changes, network connections and mirrord session events, plus the API server's own
   audit log for `exec`, shipped to Loki and joined with every other identity-keyed log ([access model — Audit](access-model.md#audit)). A Kyverno rule
   rejects a production steal-mode session without audit. Until audit exists, production steal mode is the open residual in the
   [threat model](security-threat-model.md).
4. **Scanning is advisory.** CVE (Trivy/Grype) and SAST (Semgrep) findings on changed files are surfaced, never block the inner loop. Enforcement lives in the
   pull-request gate.
5. **Payloads never leave the cluster boundary.** Anything that reads a session's payloads — an AI reviewer, an SRE agent — runs on in-cluster inference, for
   example a model on the fleet's GPU cluster reached over the [backbone](multi-cluster.md). An external model API would be an exfiltration path.

---

## Agents

The twin is the safe execution target the agent model needs: real context, no production blast radius, and a pull request as the only way out.

```text
Coding agent                                   SRE agent
  writes a change                                alert fires → reads logs, metrics, status (agent persona, read-only)
  syncs it into the twin (fileSync)              forms a hypothesis, writes a fix
  twin hot-reloads; agent calls it               fix into the twin; mirrord mirrors real traffic onto it
  reads the result against real infrastructure   compares error rate and latency on the twin
  iterates, or opens a PR                        opens a PR with the fix and the evidence
                                                 a human reviews a validated fix, not a hypothesis
```

What the agent never gets: write access to the app, a path to production other than a merged PR, or an external model API for anything that reads payloads —
the rules in [the access model](access-model.md#data-boundary-and-audit).

---

## What comes next

### `XDarlane` — a workspace claim of its own

Today Darlane is a field of an all-in-one `XTenantApp`, so its lifecycle is the app's: one twin per app, every session is an edit to the app's XR, and a
developer, a hotfix and an agent cannot hold workspaces at the same time — and nothing can expire it without touching the app. `XDarlane` belongs to the
**`XTenantApp` redesign**: smaller packages with their own maturity instead of one all-in-one kind, the twin among them as a claim of its own.

**The redesign is namespace-scoped.** The new tenant kinds — the app, its database (`XTenantDatabase`'s successor), a future monitoring kind, and `XDarlane` —
are namespaced XRs, the shape Crossplane v2 defaults to. The namespace is the owner: a persona's `RoleBinding` per owned namespace grants them, and another
team cannot even read them — which cluster scope cannot give. Most of [RFC-005](../rfc/005-git-mapped-authorization.md)'s owner rules then reduce to plain
RBAC. Platform kinds (`XPlatformDatabaseCluster`, `XScm*`, `XOIDC*`, `auth.wxops.cloud`) stay cluster-scoped. Two things to settle first:

- **Namespaced managed resources in every provider a tenant kind uses** — a namespaced XR composes only namespaced resources in its own namespace. All three
  installed providers ship them (checked on the cluster 2026-10-26): `objects.kubernetes.m.crossplane.io`, `workspaces.opentofu.m.upbound.io`, and the
  `postgresql.sql.m.crossplane.io` family — and `provider-vault` v4 does too. What is left is writing the compositions against the `.m` kinds and their
  namespaced `ProviderConfig`s.
- **Migration** — a scope change is a new kind with no conversion from the old one, so existing `XTenantApp` and `XTenantDatabase` XRs move over, not
  upgrade in place.

| Today (`darlane.*` on `XTenantApp`) | `XDarlane` |
|---|---|
| One twin per app | Several concurrent claims per app |
| Lifecycle tied to the app XR | Its own lifecycle; `ttl` mandatory |
| The app team edits the app to start a session | Portal, agent or developer creates and deletes a claim |
| Nested under `darlane.*` | Flat schema |
| Session audit wired by hand | `audit`, required by policy for production steal mode |

```yaml
apiVersion: tenant.wxops.cloud/v1alpha1
kind: XDarlane
metadata:
  name: payment-api-dev-alice
  namespace: payment                    # owner = this namespace's wxops.cloud/owner (ADR-005)
spec:
  parameters:
    appRef: {name: payment-api}         # the XApp this workspace mirrors, in the same namespace
    ttl: "8h"                           # mandatory
    fileSync: {enabled: true, mountPath: /app}
    debugPort: {enabled: true, protocol: dap, port: 5678, language: python}
    env:                                # feature flags as an env overlay
      - {name: NEW_CHECKOUT_FLOW, value: "true"}
    traffic: {weight: 20, stickySession: {enabled: true, cookieName: darlane-alice}}
    tools: python                       # platform debug-tools image, read-only
    audit: true                         # session log → Loki
```

Each consumer holds its own claim — `payment-api-dev-alice` (8h), `payment-api-sre-hotfix` (2h, `productionOverride`), `payment-api-agent-branch` (4h, no
traffic) — and the app's XR never changes. Migration is additive: `darlane.*` keeps working. The app kind it mirrors is
[RFC-010](../rfc/010-namespaced-tenant-kinds.md)'s namespaced `XApp`, named by [ADR-005](../adr/005-kind-ownership-scope-and-naming.md).

### Built as a Crossplane function — not a provider, not an operator

*Decided 2026-11-06.* `XDarlane` is a Configuration package whose pipeline ends in a composition function: `function-kcl` while the logic is small (today's
~150 lines in `kcl/app/main.k`), then **`function-darlane`**, written in Go with `function-sdk-go`, once twin inheritance, flags and test wiring
outgrow KCL. Crossplane's own reconciler does the watching, retries and drift; Darlane writes only the step that turns an app into its twin. This is the
escape hatch the [no-controller decision](../_archives/ROADMAP.md) names — "the answer is a new Crossplane *function*, not a bespoke operator".

| | Function (chosen) | Provider | kubebuilder operator |
|---|---|---|---|
| Reconcile loop | Crossplane's | Our own Observe/Create/Update/Delete, finalizers, credentials | Our own, plus CRD versions, conversion, leader election, HA |
| Fits the `XApp` pipeline | The same pipeline: `function-extra-resources` reads the `XApp`, `function-darlane` renders | A second control plane beside it | A second control plane beside it |
| Tests | Offline goldens (`crossplane render` runs the function image) plus Go unit tests | envtest or a cluster | envtest or a cluster |
| Writes into tenant namespaces | provider-kubernetes, under the RBAC RFC-009 designed | Its own ServiceAccount | Its own ServiceAccount, plus an admission webhook in the request path |

**One pipeline, three uses:**

```text
XDarlane claim ──► function-extra-resources (read the XApp) ──► function-darlane
                                                                  ├─ twin Deployment / Service               → feature debugging
                                                                  ├─ OpenFeature flags + TraefikService split → feature-flag experiments
                                                                  └─ a test Job against the twin              → integration tests
AI agents ──► create and delete XDarlane claims as an agent persona — never write workloads directly
```

- **Feature-flag experiments** compose in-cluster CRDs through provider-kubernetes — the OpenFeature Operator's `FeatureFlag` and `FeatureFlagSource`
  beside the traffic split Darlane already ships. An experiment is a flag variant, a traffic share and a cohort cookie, declared in the claim. The `env`
  overlay stays for the simple case.
- **Integration tests** are a composed `Job` (or a Testkube `TestWorkflow`) against the twin, its result in the claim's status and the pull request. What
  starts a run — a new image on the twin, or a claim an agent creates per run — is decided with the test work; a `WatchOperation` is one option.
- **What a function must respect:** it runs on every reconcile, so it stays fast and free of side effects — no external API calls, no waiting. Anything
  one-shot or slow (a test run, an agent step) is a composed `Job`, a Crossplane `Operation` (alpha in v2 — spike first), or runtime tooling.
- **A provider only for an outside API** that has no Kubernetes CRD and no Terraform provider — a hosted flag or test service called directly. With a
  Terraform provider, provider-opentofu runs it, as the `scm-*` packages do; with CRDs, provider-kubernetes composes them. `provider-darlane` is decided
  only when such a system appears.
- **Darlane's Go code beyond the function is runtime, not reconcile logic:** the CLI, fileSync, mirrord integration, the session-audit sidecar, the tools
  image and agent tooling — released from the Darlane repository on its own cadence, once it splits from `wxops-core`.

### Agent access — open, decided with the agent work

How an agent reads the cluster and drives a twin is **not decided**. It depends on how agents are built when `XDarlane` splits out — a modern agent framework
that brings its own control, or W'xOps's own skills and MCP servers — so the choice waits for that work. The options on the table:

| Option | Shape | Trade-off |
|---|---|---|
| `wxops:persona-viewers` + `wxops:platform-view` | Persona roles, through an agent persona's `XPersonaBinding` | Simplest. `view`, which it aggregates, grows with every CRD that aggregates into it, and reads every ConfigMap |
| `wxops:persona-agents` | An aggregated allowlist: pods, `pods/log`, events, workloads, services, policy reports, ESO status, XR status | Nothing added silently; one more role in the binding enum and in provider-kubernetes's `bind` list |
| A read proxy (MCP or tool server) | The agent holds no Kubernetes token; the server answers and redacts | Strongest boundary; a new component, worth it once agents act across many clusters |

Whichever is chosen, these hold — they come from the rules above, not from the option:

- **No `exec` or port-forward into a twin** — it carries production `env`, so exec reads its secrets. A coding agent works through `fileSync` and the twin's
  own endpoint, and leaves only by pull request.
- **Logs are payloads** — anything reading `pods/log` runs on in-cluster inference ([data boundary](access-model.md#data-boundary-and-audit)).
- **Agents are ServiceAccounts** — `XPersonaBinding`'s `scope: owned` binds only groups, so an agent persona needs `scope: namespaces` today, unless `owned`
  later learns to match a ServiceAccount's namespace owner.
- **Kyverno matches SCM groups only** — `XPlatformPolicy` templates do not cover agents yet, so RBAC alone guards them until agents join policy matching.

### Also ahead

- **Expiry, as deleting the claim** — `ttl` mandatory on `XDarlane`, capped per persona, ended by a `DeletingPolicy`; the portal reads `startedAt` and `ttl`
  from status instead of a warning label.
- **Session audit and the tools image** — the two [session-safety](#session-safety--tools-audit-data-boundary) items not yet built; audit unblocks
  production steal mode.
- **Access by persona** — the twin's bindings rendered by an `XPersonaBinding` for its owner's persona instead of written per app ([RFC-009](../rfc/009-scm-personas.md)).
- **Across clusters** — a twin runs in its app's cluster. `kubectl` and mirrord reach it through Pinniped like any other access; in-cluster agents and
  inference reach it over the [backbone](multi-cluster.md). No tunnel product is needed.
- **A debug port** (`debugPort`, DAP) so an editor attaches without hand-written port-forward commands.

---

## Prerequisites

- Traefik with the `TraefikService` CRD — for any traffic mode.
- The Kyverno controller — a bootstrap prerequisite, not installed by W'xOps. No Darlane policy is applied today.
- Cluster access as yourself — Pinniped, per the [access model](access-model.md#kubernetes-pinniped--rbac--kyverno).
- Optional, on the developer's machine: the `mirrord` CLI; Telepresence (needs its Traffic Manager in the cluster); a sync tool for `fileSync`.
