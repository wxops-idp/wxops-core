# Darlane — a production-context twin for debugging, validation and agents

> [!NOTE]
> **Status: shipped inside `XTenantApp`** (`spec.parameters.darlane`); the standalone `XDarlane` is the future. Every field is in the
> [API reference](../../docs/api-reference/tenant-app.md#darlane-debug-twin-deployment). This page is the why, what ships, and what comes next — the
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
| Lifetime | `ttl` | Annotation enforced by `providers/policies/darlane-ttl.yaml` (Kyverno) — see [Safety](#safety) |
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
| Abandoned session | Medium — a stale twin keeps running | `ttl` |

**A TTL needs two actions.** The Kyverno policy adds `wxops.cloud/darlane-ttl-warning: expiring-soon` 30 minutes before expiry and deletes the Deployment once
the TTL has passed — but Crossplane re-creates it from `darlane.replicas`. The portal (or whoever scaled it up) must also set `replicas: 0` in the XR; that is
what makes the scale-down stick. The warning label is what the portal watches to show "expiring soon".

### Access

The composition creates the ServiceAccount and publishes it as `status.darlane.serviceAccountName`; it never emits a `Role` or `RoleBinding` (a
[rejected design](../_archives/ROADMAP.md#decided-and-rejected)). Who may exec into, port-forward to and scale a twin is decided in GitOps — under the
[access model](access-model.md), by the team's persona: a developer persona includes `pods/exec`, `pods/portforward`, `pods/log` and
`deployments/scale` in its own namespaces; an agent persona reads logs and events only. Kyverno then narrows `exec` to pods whose `wxops.cloud/owner`
matches the caller's team.

## Session safety — tools, audit, data boundary

A Darlane session can see real secrets, real database connections and — in steal mode — real user traffic. These rules make that access defensible. They
come from the [archived Guardian design](../_archives/guardian.md); the sidecar framework itself is not planned, and what remains is owned by the Darlane
composition, not by a separate layer.

1. **The composition owns the pod spec.** Anything beside the developer's container — a tools mount, an audit container — is composed by the Darlane
   composition, deterministic and testable with `make render`. No controller or mutating webhook injects containers after the fact; Kyverno may *require* a
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

Today Darlane is a field of the app, so its lifecycle is the app's: one twin per app, every session is an edit to the app's XR, and a developer, a hotfix
and an agent cannot hold workspaces at the same time.

| Today (`darlane.*` on `XTenantApp`) | `XDarlane` |
|---|---|
| One twin per app | Several concurrent claims per app |
| Lifecycle tied to the app XR | Its own lifecycle; `ttl` mandatory |
| The app team edits the app to start a session | Portal, agent or developer creates and deletes a claim |
| Nested under `darlane.*` | Flat schema |
| Session audit wired by hand | `audit`, required by policy for production steal mode |

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XDarlane
metadata:
  name: payment-api-dev-alice
  labels:
    wxops.cloud/owner: payment          # who may use it — resolved by the access model, never by RBAC in the claim
spec:
  parameters:
    appRef: {name: payment-api}         # the XTenantApp this workspace mirrors
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
traffic) — and the app's XR never changes. Migration is additive: `darlane.*` keeps working.

### Also ahead

- **Session audit and the tools image** — the two [session-safety](#session-safety--tools-audit-data-boundary) items not yet built; audit unblocks
  production steal mode.
- **Access by persona** — the twin's bindings rendered from the persona file instead of written per app ([access model](access-model.md)).
- **Across clusters** — a twin runs in its app's cluster. `kubectl` and mirrord reach it through Pinniped like any other access; in-cluster agents and
  inference reach it over the [backbone](multi-cluster.md). No tunnel product is needed.
- **A debug port** (`debugPort`, DAP) so an editor attaches without hand-written port-forward commands.

---

## Prerequisites

- Traefik with the `TraefikService` CRD — for any traffic mode.
- Kyverno — for `ttl` (`kubectl apply -f providers/policies/darlane-ttl.yaml`).
- Cluster access as yourself — Pinniped, per the [access model](access-model.md#kubernetes-pinniped--rbac--kyverno).
- Optional, on the developer's machine: the `mirrord` CLI; Telepresence (needs its Traffic Manager in the cluster); a sync tool for `fileSync`.
