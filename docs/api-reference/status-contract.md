# Status contract — what the portal can poll today

One page, cross-package: every field a portal (or any external consumer) can read from an XR's `status` right now, as of the Phase 0 API-freeze batch, shipped
as `v0.4.0` (see [`development-docs/_archives/ROADMAP.md`](../../development-docs/_archives/ROADMAP.md#shipped)). Each package's own doc has the full
field-by-field detail with rationale; this page exists so a portal engineer doesn't have to open every one to answer "what can I poll?"

## The one rule that applies everywhere

**Poll `status.ready` / `status.created`, never the native `type: Ready` condition.** Crossplane v2.3 with function-kcl v0.12.1 leaves that condition unreliable
(see [`CLAUDE.md`](../../CLAUDE.md) — Testing) — every KCL-based package derives its own `ready`/`created` from observed composed-resource state instead; each
package's status section below has the exact derivation. All seven packages now expose the same two field names, so the polling logic is identical across
packages — only the extra fields differ.

## API version

**All seven XRDs serve `v1alpha1` only.** This is a decision, not an oversight — recorded in [`VERSIONS.yaml`](../../VERSIONS.yaml). Every Phase 0 change is
additive, so nothing forced a bump; promotion to `v1beta1` is deferred to [release readiness](../../development-docs/_archives/ROADMAP.md#release-readiness),
the natural point to make a stability commitment. **The portal should expect to pin `v1alpha1` for its first integration** — that is accepted, not a temporary
gap to work around.

## Per-package status contract

| Package | Kind | `created` | `ready` | Extra fields | Contract note |
|---|---|---|---|---|---|
| [`gitea-user`](_archives/gitea-user.md#status) (archived) | `XGiteaUser` | bool, **absent** until first apply | bool, **absent** until first apply | `userId`, `username` | Absent ≠ `false` — this package's only deviation from the rest. Treat absent as not-ready. |
| [`gitea-org`](_archives/gitea-org.md#status) (archived) | `XGiteaOrg` | bool, absent-until-apply | bool, absent-until-apply | `orgId`, `orgName` | Same absent-not-false caveat. |
| [`gitea-team`](_archives/gitea-team.md#status) (archived) | `XGiteaTeam` | bool, absent-until-apply | bool, absent-until-apply | `teamId`, `teamName` | Same absent-not-false caveat. |
| [`gitea-repository`](_archives/gitea-repository.md#status) (archived) | `XGiteaRepository` | bool, absent-until-apply | bool, absent-until-apply | `repoId`, `cloneUrl`, `sshUrl`, `htmlUrl` | Same absent-not-false caveat. |
| [`platform-database-clusters`](platform-database-clusters.md#status) | `XPlatformDatabaseCluster` | bool, explicit `false` | bool, explicit `false` | `clusterName`, `namespace`, `shared`, `environment` | `ready` excludes Vault seeding and scheduled backups on purpose — neither stops a running cluster serving. |
| [`tenant-database`](tenant-database.md#status) | `XTenantDatabase` | bool, explicit `false` | bool, explicit `false` | `clusterRef`, `clusterNamespace`, `tier`, `dbName` | `ready` excludes the Vault credential push — a lagging push doesn't stop the app connecting. |
| [`scm-connection`](scm-connection.md#status) | `XScmConnection` | bool, absent-until-synced | bool, absent-until-synced | `secretName` | Same absent-not-false caveat. `ready` means the credential Secret exists — never that the token works against the host. |
| [`scm-repository`](scm-repository.md#status) | `XScmRepository` | bool, absent-until-apply | bool, absent-until-apply | `exists`, `repoId`, `cloneUrl`, `sshUrl`, `htmlUrl`, `fullName` | Same absent-not-false caveat. In `observed` mode `exists` is the field that matters. |
| [`scm-oauth-app`](scm-oauth-app.md#status) | `XScmOAuthApp` | bool, absent-until-apply | bool, absent-until-apply | `clientId`, `vaultKey`, `generation` | Same absent-not-false caveat. The client secret is never in status — it goes to the store and to a Secret. |
| [`tenant-app`](tenant-app.md#status) | `XTenantApp` | bool, explicit `false` | bool, explicit `false`, **workload-scoped** | `dependenciesReady`, `darlane.*`, `url`, `namespace`, `image` | See the split below — `ready` alone is not the full health picture for this package. |

The **absent-vs-`false`** split is real and package-group-wide: the four `gitea-*` packages use `function-patch-and-transform`, patching values out of Terraform
outputs via `ToCompositeFieldPath` with an `Optional` policy — the patch simply doesn't run before the first successful apply, so the field is missing from the
object rather than present-and-`false`. The three function-kcl packages compute an explicit boolean every reconcile, so they're always present. **A portal
client should treat a missing field the same as `false`, not as an error.**

## `tenant-app` — the one package that needs two fields, not one

`ready` on `XTenantApp` is deliberately **scoped to the core workload** (Deployment, Service, Ingress) and excludes the cert-manager `Certificate`. Polling
`ready` alone means the portal can render "Ready ✅" while TLS is still issuing.

```yaml
status:
  created: true
  ready: true              # core workload only
  dependenciesReady: false  # e.g. Certificate not yet issued
  url: "https://payment-api.rocket-team.example.com"
  namespace: rocket-team-production
  image: ghcr.io/rocket-team/payment-api:1.4.0
```

**Render both fields, not one.** The honest UI state is three-valued in practice: not ready / ready but dependencies pending / fully ready — collapsing to a
single boolean loses the middle state, which is a real and common one (a freshly-applied XR with `ingress.tls.clusterIssuer` set spends real time in it).

`XTenantApp` does **not** compose an `XTenantDatabase`. `secretsFrom.database` only wires an existing Secret in by name and is never waited on, so database
readiness is not — and cannot be — reflected in either field. If the portal needs combined app+database health, it polls `XTenantDatabase.status.ready`
separately and combines client-side.

### Darlane sub-status

Present only when `darlane.enabled: true` — **absent entirely**, not an empty object, when the twin isn't in use:

```yaml
status:
  darlane:
    ready: true
    replicas: 1                              # OBSERVED, not desired — read from
                                               # the Deployment manifest provider-
                                               # kubernetes writes back
    trafficMode: weighted                     # none | weighted | header | both
    ttl: "4h"                                 # a DURATION, not an expiry timestamp —
                                               # combine with the Deployment's
                                               # creationTimestamp to compute one
    serviceAccountName: payment-api-darlane   # the RBAC binding target, not a grant —
                                               # this repo's compositions never emit
                                               # RBAC; see development-docs/_archives/ROADMAP.md "Decided and
                                               # rejected"
```

If the portal offers an "open shell into Darlane" action, `serviceAccountName` is what a GitOps-authored `RoleBinding` targets — the composition itself grants
nothing.

## Monitoring — `tenant-app` only, input not status

`spec.parameters.monitoring` is a **write path**, not something the portal polls — flagged here because it's the field most likely to be confused with a status
field, and because the portal's own toggle for it was previously wired to a mechanism that never worked.

```yaml
monitoring:
  enabled: true
  kind: auto           # auto | ServiceMonitor | PodMonitor — auto resolves on service.enabled
  port: 9090            # no schema default — falls back to containerPort
  path: /metrics
  interval: 30s
  scrapeTimeout: 10s
  sampleLimit: 5000
  honorLabels: false
  metricRelabelings: []
```

**If the portal's UI already has a "Monitoring" toggle, it was wired to `prometheus.io/*` pod annotations — those do nothing on this platform** (see
[observability.md](../../development-docs/core-ideas/observability.md) for why). Repoint that toggle at `spec.parameters.monitoring.enabled` instead; nothing
else about the toggle's UX needs to change.

There is no status-side confirmation that a `ServiceMonitor`/`PodMonitor` was actually created and is scraping successfully — that lives in Prometheus's own
`/targets` page, outside this API. The portal can infer "the field was accepted" from the XR's `Synced` condition, but not "metrics are flowing."

## `cluster` — every package, input not status

`spec.parameters.cluster` (all seven packages via `platform-database-clusters`, `tenant-database`, `tenant-app` — the four `gitea-*` packages don't have it,
since a Gitea `Workspace` targets a Gitea server over HTTP, not a Kubernetes cluster). Defaults to `"default"`, the local hub. **Behaviour-neutral until a spoke
`ProviderConfig` exists** — see [multi-cluster.md](../../development-docs/core-ideas/multi-cluster.md). Not yet consumed anywhere; safe for the portal to ignore
until multi-cluster work lands, at which point it becomes the field that selects a target cluster per XR.

## See also

- [`development-docs/_archives/ROADMAP.md`](../../development-docs/_archives/ROADMAP.md#shipped) — the work that produced this contract, shipped as `v0.4.0`
- [`CONTRIBUTING.md`](../../CONTRIBUTING.md) — the checklist a new package owes, including status parity
- [`tests/README.md`](../../tests/README.md) — how these contracts are tested offline
