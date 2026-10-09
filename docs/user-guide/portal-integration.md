# Portal Integration Guide — the consumer side of the API

> **Status: reference for the portal team, current as of v0.4.0.** The producer-side contract lives in
> [`status-contract.md`](../api-reference/status-contract.md) and the per-package docs; this is the same surface read from the portal's chair: what to write per
> screen, what to poll, how to render errors, and the rules that prevent the integration bugs the contract was designed against. When this guide and an XRD
> disagree, the XRD wins — file the discrepancy.

## Ground rules

1. **Pin `v1alpha1`.** All seven kinds serve only `v1alpha1` and will until
   the OSS release (decision recorded in [`VERSIONS.yaml`](../../VERSIONS.yaml) and [status-contract.md](../api-reference/status-contract.md#api-version)).
   Build the client against it without apology.
2. **Write XRs only — never composed resources.** The portal creates/patches
   `XTenantApp`, `XTenantDatabase`, etc. It must never touch the
   `kubernetes.crossplane.io` `Object`s beneath them: Crossplane owns those,
   and any portal write there is overwritten on the next reconcile.
   Read-only access to composed resources *is* useful (drill-down below).
3. **Use server-side apply with a portal field manager** (e.g.
   `--field-manager=wxops-portal`) so portal writes, GitOps writes, and
   `kubectl` edits stay attributable and conflict-detectable.
4. **Watch, don't poll, where possible.** All XRDs are cluster-scoped; a
   watch on each kind is seven streams total. If polling, honour the
   convergence reality: seconds for status flips, longer for provisioning.
5. **Unknown fields are silently pruned by the API server.** A typo'd portal
   field name doesn't error — the value just never arrives. Validate the
   request body against the XRD schema client-side (the offline test suite's
   `tests/lib/xrdschema.py` shows exactly how, including default
   application).

## Screen-by-screen field map

### Create / edit app (`XTenantApp`)

| Portal control | Writes | Notes |
|---|---|---|
| Name, namespace, image | `spec.parameters.{appName,namespace,image}` | The only three required fields |
| Environment selector | `parameters.environment` | enum `dev\|staging\|prod`; prod gates Darlane behind `productionOverride` |
| Replicas / resources | `parameters.replicas`, `parameters.resources` | `resources` accepts only `cpu`/`memory` today — GPU keys are pruned (backlog item) |
| Ingress toggle + host | `parameters.ingress.*` | `host` required when enabled; TLS via `tls.clusterIssuer` auto-issues a Certificate |
| **Monitoring toggle** | `parameters.monitoring.enabled` | **Repoint the existing toggle here** — the old `prometheus.io/*` annotations never worked ([observability.md](../../development-docs/core-ideas/observability.md)). `kind: auto` is the right default; only surface the explicit choice when `service.enabled` is known, since `ServiceMonitor` without a Service is a render-time error |
| Target cluster (future) | `parameters.cluster` | Exists and validates today; behaviour-neutral until a spoke `ProviderConfig` exists — safe to hide until then |

### App status card

Render **three-state health, not a boolean** — this is the whole reason the split exists:

| State | Condition | Card |
|---|---|---|
| Provisioning | `created: false` (or fields absent) | spinner + "creating resources" |
| Degraded-dependencies | `ready: true && dependenciesReady: false` | **green app + amber badge** — "running; TLS still issuing". Do not render this as failure |
| Ready | both true | green |
| Not ready | `created: true && ready: false` | red → drill-down |

Also read: `status.url` (empty = no ingress — hide the link), `namespace`, `image` (what's *actually* configured, echo for drift display).

**Drill-down on red:** walk `spec.crossplane.resourceRefs` → fetch each `Object` → show the ones whose `Ready` condition is false, with their events. This is
read-only and is the diagnosis tree from [`self-service-operations.md`](../../development-docs/core-ideas/self-service-operations.md) — when `status.notReady`
ships (backlog), the walk collapses to a field read; build the card so that swap is easy.

### Darlane panel

Present only when `status.darlane` exists (absent ⇒ twin disabled — hide the panel entirely, don't show zeros):

| Element | Reads / writes |
|---|---|
| Twin on/off, replicas | writes `parameters.darlane.{enabled,replicas}`; reads `status.darlane.{ready,replicas}` — **status replicas are observed, spec are desired; show both when they differ** |
| Traffic mode badge | `status.darlane.trafficMode` (`none\|weighted\|header\|both`) |
| TTL countdown | `status.darlane.ttl` is a **duration** (`"4h"`), not a timestamp — compute expiry client-side from the twin Deployment's `creationTimestamp` |
| "Open shell" | requires an RBAC binding to `status.darlane.serviceAccountName` — the portal *displays* the SA name and links the runbook; it does not grant access (the RBAC seam — [tenant-app.md](../api-reference/tenant-app.md#developer-access-and-rbac)) |
| Prod toggle | `darlane.productionOverride` — surface as an explicit double-confirm, that's its purpose |

### Databases (`XTenantDatabase`)

Reads: `status.{ready,created}` for health; `status.clusterRef` / `clusterNamespace` / `tier` for placement display; `status.dbName` for collision hints.
Writes: `parameters.{dbName,owner,tier,environment,extensions}`. The connection secret is **not** in status by design — point users at the Vault path
convention, never render credentials.

### Gitea resources (`XGiteaUser/Org/Team/Repository`)

The one contract asymmetry, worth a dedicated code path: `status.created`/`ready` are **absent — not false — until the first successful Terraform apply**. Treat
absent as "provisioning". And because outputs persist across later failures, pair `ready` with the native `Synced` condition: `ready: true` + `Synced: False` ⇒
render "exists, but drifting / update failing", not green. Useful facts to display: `userId`, `orgName`, `repoId`, `cloneUrl`/`sshUrl`/`htmlUrl`.

## Error UX → runbooks

Wire the error card to the runbook index by status shape (the `trigger` frontmatter convention in
[`knowledge-architecture.md`](../../development-docs/core-ideas/knowledge-architecture.md#runbook-anatomy--the-format-worth-standardizing)): the card's "what do
I do?" link resolves mechanically, no search. Until runbooks exist, link the per-package doc's failure-modes section. And implement the **correlation fork**
from the error taxonomy: if the same failure shape spans many tenants' XRs, switch the card from "here's your runbook" to "platform incident — already
escalated", with the evidence bundle attached
([self-service-operations.md](../../development-docs/core-ideas/self-service-operations.md#the-error-taxonomy--developer-side-user-side-platform-side)).

## What the portal must NOT do

- Grant or modify RBAC (rejected permanently — `development-docs/_archives/ROADMAP.md` §Decided and rejected) —
  display binding targets, link the process.
- Fan an XR out to multiple clusters itself by mutating one XR — multi-region
  is *N* XRs, one per cluster
  ([multi-cluster-proposal.md](../../development-docs/core-ideas/multi-cluster-proposal.md)); the portal owns
  the fan-out UX, one claim per target.
- Render secrets or connection strings from any source.
- Trust `metadata` it wrote to survive — labels on XRs are portal-owned, but
  status is composition-owned; never write into `status`.

## See also

[`status-contract.md`](../api-reference/status-contract.md) — the producer contract · [`tenant-app.md`](../api-reference/tenant-app.md) /
[`tenant-database.md`](../api-reference/tenant-database.md) — full field reference ·
[`solution-matrix.md`](../../development-docs/core-ideas/solution-matrix.md) — what's shipped vs. designed before you build UI against it.
