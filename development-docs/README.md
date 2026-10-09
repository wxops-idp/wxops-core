# W'xOps Core — Development docs

Everything about **building, deciding and releasing** W'xOps Core: the decisions that shaped it (ADRs), the proposals still being argued
(RFCs), the roadmap, the development guide and the release process. The product documentation a platform engineer, a developer or an
agent reads to *use* the platform is in [`docs/`](../docs/README.md).

**Table of Contents**
- [Find your way](#find-your-way)
- [Development guide](#development)
- [ADR](#adr)
- [RFC](#rfc)
- [Roadmap](#roadmap)
- [Development matrix](#development-matrix)
- [Where new docs go](#where-new-docs-go)

---

## Find your way

| I want to… | Start here |
|---|---|
| Change a composition or add a package | [Development guide](development/README.md) |
| Cut a release | [Releasing](development/releasing.md) |
| See what is built, what is planned, and what is next | [Development matrix](#development-matrix) · [RFC index](rfc/README.md) |
| Find or record the reasoning behind a decision | [ADR](adr/README.md) |
| Propose a design or a new capability before it is built | [RFC](rfc/README.md) |
| Read what the platform is for and how it is used | [`docs/`](../docs/README.md) |

---

## The development docs

### Development

Changing, testing and releasing W'xOps Core. The canonical detail stays next to the code it
describes; these pages put it in order.

| Doc | What it covers |
|---|---|
| [**Development guide**](development/README.md) | Where every piece of contributor detail lives, the change loop, hooks and make targets, and the rules that bite |
| [releasing](development/releasing.md) | The two version axes, why a released XRD only grows, `make release`, CI publishing, and the changelog |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | Setup, the change loop, commit messages, and the checklist for a new package |
| [`tests/README.md`](../tests/README.md) | The offline test suite: what each check catches, how to add a case, what it cannot catch |
| [`kcl/README.md`](../kcl/README.md) | Why KCL, the sync workflow, and wiring a KCL module into a package |
| [`release-notes/README.md`](../release-notes/README.md) | When release notes are required and how to write them |
| [`CLAUDE.md`](../CLAUDE.md) | Architecture, KCL conventions, the working model, and the reference stack |


### Roadmap

`ROADMAP.md` is archived — [`_archives/ROADMAP.md`](_archives/ROADMAP.md), frozen as of the release it describes, kept for the
sections below that still link into its decided-and-rejected and backlog content. What's next now lives in the
[RFC index](rfc/README.md)'s `Status` column and each RFC's own body; a new rejection is recorded in the RFC or ADR it belongs to,
not a separate roadmap document.

### ADR

One committed file per decision of lasting consequence — context, decision, consequences,
alternatives considered. Breaking or architectural changes get one, so the reasoning stays
discoverable without depending on anyone's memory of the conversation that produced it.

| Doc | What it covers |
|---|---|
| [**ADR index**](adr/README.md) | The lifecycle (proposed → accepted → superseded) and every ADR so far |
| [`TEMPLATE.md`](adr/TEMPLATE.md) | Copy this to start a new one |
| [001 — Package channel label](adr/001-package-channel-label.md) | `stable`/`nightly` over a guardrailed rollout system, and why |
| [002 — Three API groups](adr/002-three-api-groups.md) | `scm`, `auth`, `platform` by trust boundary, and replacing rather than converting `gitea-*` |
| [004 — `scm-repository`'s vendor field](adr/004-scm-repository-vendor-field.md) | Why one kind in the `scm` family repeats `vendor` from its connection — a Terraform provider can't be made conditional |

### RFC

One committed file per proposal — a design argued before it is built. Community intake is the RFC issue; the file
is what tracks the proposal through review, acceptance and rollout, and links to the ADRs it produces.

| Doc | What it covers |
|---|---|
| [**RFC index**](rfc/README.md) | When to write one, the lifecycle (draft → in review → accepted → implemented), and every RFC so far |
| [`TEMPLATE.md`](rfc/TEMPLATE.md) | Copy this to start a new one |
| [002 — Terraform → OpenTofu](rfc/002-migrate-terraform-to-opentofu.md) | Swap the Workspace engine so the whole runtime stack is open source, and the orphan-first procedure that keeps existing Gitea resources safe — *implemented* |
| [003 — SCM connections and resources](rfc/003-scm-connections-and-resources.md) | `XScmConnection` + `scmRef`, `XScmRepository`/`OAuthApp` across Gitea/GitHub with `managed \| observed` modes and Vault-tracked credentials; `gitea-*` is archived, not migrated, since no cluster ever ran it — *implemented (Phase 1)* |
| [004 — Dex identity and Portal authentication](rfc/004-dex-identity-and-portal-authentication.md) | Dex configured entirely through Core (`XDexConnector`, `XOIDCClient` → OpenBao → rendered config → Reloader), and the claim contract the authorization RFC keys on — *accepted* |
| [005 — Git-mapped authorization](rfc/005-git-mapped-authorization.md) | RBAC for who may act, Kyverno ABAC keyed on a `wxops.cloud/owner` label mapped one-to-one to Git teams, and the namespaced-XR alternative — *draft* |
| [006 — Cloudflare R2](rfc/006-cloudflare-r2-object-storage-and-backup.md) | The first third-party service: R2 buckets and scoped credentials for backup and tenant object storage, and the pattern a second service follows — *draft* |
| [007 — Package layout by API group](rfc/007-package-layout-by-api-group.md) | `package/{scm,auth,platform}/`, a Kustomization per category, and `group`/`path` in `VERSIONS.yaml` — *accepted* |
| [008 — OpenBao as a platform API](rfc/008-openbao-as-a-platform-api.md) | `XSecretStore` and `XSecretAccess` — mounts, policies and ESO access as resources, on the same Workspace engine as the SCM packages — *draft* |

---

## Development matrix

One page for developing the project: every package, core idea and delivery mechanism, where it
stands, where to read about it, and what is next. **Kept current by hand:** update the row in the
same pull request that changes its state. Where this table and an [RFC](rfc/README.md)'s own
`Status` disagree, the RFC wins.

| Symbol | Meaning |
|---|---|
| ✅ | Shipped |
| 🔶 | Partial — the mechanism exists, a named piece is missing |
| 📋 | Designed or planned, not built |
| ❌ | Not started |
| ⛔ | Deliberately rejected |
| 🗄️ | Archived — built, superseded, kept for the record (not released, not tested, not built) |

### Platform APIs

| Package | Kind | You get | State | Reference | Related | Next |
|---|---|---|---|---|---|---|
| `gitea-user` | `XGiteaUser` | A Gitea user and generated password, via Terraform | 🗄️ archived, not released | [ref](../docs/api-reference/_archives/gitea-user.md) | superseded by `scm-repository` | — |
| `gitea-org` | `XGiteaOrg` | A Gitea organisation | 🗄️ archived, not released | [ref](../docs/api-reference/_archives/gitea-org.md) | superseded by `scm-repository` | — |
| `gitea-team` | `XGiteaTeam` | A team and its membership | 🗄️ archived, not released | [ref](../docs/api-reference/_archives/gitea-team.md) | — | — |
| `gitea-repository` | `XGiteaRepository` | A repository | 🗄️ archived, not released | [ref](../docs/api-reference/_archives/gitea-repository.md) | superseded by `scm-repository` | — |
| `platform-database-clusters` | `XPlatformDatabaseCluster` | A CNPG cluster, poolers, backups, Vault-seeded credentials | ✅ | [ref](../docs/api-reference/platform-database-clusters.md) | [Multi-cluster data](../docs/core-ideas/multi-cluster-scale.md#the-data-layer-decides-the-region-strategy-not-the-other-way-round) | `scheduling:` block; `status.notReady` reasons |
| `tenant-database` | `XTenantDatabase` | A database and role on a shared or dedicated cluster, credentials in Vault | ✅ | [ref](../docs/api-reference/tenant-database.md) | [App onboarding §9](../docs/user-guide/app-onboarding.md#9-optional-wire-database-secrets) | `status.notReady` reasons; Vault path cluster dimension ([open decision 5](_archives/ROADMAP.md#open-decisions)) |
| `tenant-app` | `XTenantApp` | Workload, ingress with TLS and SSO, monitors, the Darlane twin | ✅ | [ref](../docs/api-reference/tenant-app.md) | [Darlane](../docs/core-ideas/darlane.md) · [Observability](../docs/core-ideas/observability.md) · [Portal](../docs/user-guide/portal-integration.md) | `monitoring.alerts`, `scheduling:`, GPU `resources` keys, `ingress.gslb` (blocked on a spike) |
| `random-password` | `XRandomPassword` | A random password, via OpenTofu | 🗄️ archived, not released | [ref](../docs/api-reference/_archives/random-password.md) | — | — |
| `scm-connection` | `XScmConnection` | One Git hosting service and its credential, rendered as tfvars for every `scm` resource | 🔶 built, unreleased | [ref](../docs/api-reference/scm-connection.md) | [RFC-003](rfc/003-scm-connections-and-resources.md) · [ADR-002](adr/002-three-api-groups.md) | Cluster proof against a real host; namespaced twin |
| `scm-repository` | `XScmRepository` | A repository on Gitea or GitHub, `managed` or `observed`, one OpenTofu module | 🔶 built, unreleased | [ref](../docs/api-reference/scm-repository.md) | [RFC-003](rfc/003-scm-connections-and-resources.md) · [ADR-004](adr/004-scm-repository-vendor-field.md) | `scm-oauth-app`, then org/team/user; GitLab; `import` adoption |
| `scm-oauth-app` | `XScmOAuthApp` | A host-side OAuth application and its credentials in the store | 🔶 built, unreleased | [ref](../docs/api-reference/scm-oauth-app.md) | [RFC-003](rfc/003-scm-connections-and-resources.md) · [RFC-004](rfc/004-dex-identity-and-portal-authentication.md) | Cluster proof; whether the connection Secret carries client_id; scheduled rotation |
| *API contract* | all | `status.created`/`ready` on every package; `v1alpha1`, additive-only | ✅ | [Status contract](../docs/api-reference/status-contract.md) | [A released XRD only grows](development/releasing.md#a-released-xrd-only-grows) | Promotion is an identical-schema stability label, at the OSS release ([Notes and warnings](_archives/ROADMAP.md#notes-and-warnings)) |

### Core ideas

| Idea | What it is | State | Concept doc | Lives in today | Next |
|---|---|---|---|---|---|
| **Darlane** | A debug twin beside a running app: file sync, traffic mirroring, weighted and header routing | ✅ inside `XTenantApp` · 📋 standalone `XDarlane` | [darlane](../docs/core-ideas/darlane.md) | `XTenantApp.spec.parameters.darlane` | `XDarlane` XRD — [Where Darlane belongs](_archives/ROADMAP.md#where-darlane-belongs) |
| **Guardian** | Platform-injected scanning, audit and AI-review sidecars for Darlane sessions | 📋 vision | [guardian](../docs/core-ideas/guardian.md) | — (needs `XDarlane`) | Guardian Phase 1 — [Backlog](_archives/ROADMAP.md#deferred-core-post-release) |
| **Multi-cluster** | Hub and spokes: CAPI provisions, ArgoCD delivers, structured authn joins | 🔶 `cluster` threaded through three KCL packages; no spoke yet | [multi-cluster](../docs/core-ideas/multi-cluster.md) → [proposal](../docs/core-ideas/multi-cluster-proposal.md) → [connectivity](../docs/core-ideas/multi-cluster-connectivity.md) → [scale](../docs/core-ideas/multi-cluster-scale.md) | `spec.parameters.cluster` | Prototype — [Backlog](_archives/ROADMAP.md#deferred-core-post-release); [open decisions 4–5](_archives/ROADMAP.md#open-decisions) |
| **Observability** | Metrics emission from the app, then collection across clusters | ✅ Part 1 (monitors) · ❌ Part 2 (collection is platform infrastructure) | [observability](../docs/core-ideas/observability.md) | `XTenantApp.spec.parameters.monitoring` | `monitoring.alerts`; push-based collection and event export ([matrix O7, O11](../docs/core-ideas/solution-matrix.md#domain-1--observability)) |
| **Self-service operations** | Status as a diagnosis graph, runbooks keyed to status, agent-suggested PRs through the gate | 🔶 the diagnosis graph and the PR gate exist; the agent side is 📋 | [self-service-operations](../docs/core-ideas/self-service-operations.md) | Status contract, `pr-validate` | `status.notReady` reasons — [Backlog](_archives/ROADMAP.md#core-follow-ups-from-the-architecture-docs-2026-08) |
| **Knowledge architecture** | ADRs, runbooks, Agent Skills and golden incidents for humans and agents | 🔶 issue templates and `docs/adr/` exist; the decisions table moved to each RFC/ADR | [knowledge-architecture](../docs/core-ideas/knowledge-architecture.md) | `.github/ISSUE_TEMPLATE/`, [`docs/adr/`](adr/README.md) | Runbooks and `docs/incidents/` — [Backlog](_archives/ROADMAP.md#core-follow-ups-from-the-architecture-docs-2026-08) |
| **Security** | Threat model, mitigations and gaps | ✅ threat model · ✅ `SECURITY.md` | [security-threat-model](../docs/core-ideas/security-threat-model.md) | Invariants (no RBAC in compositions) | Image digests + signing — [Release readiness gaps](../docs/core-ideas/security-threat-model.md#gaps--ordered-honest) |
| *Composition-emitted RBAC* | Roles and bindings created by a composition | ⛔ rejected | [`ROADMAP.md`](_archives/ROADMAP.md#decided-and-rejected) | — | The composition publishes the ServiceAccount; GitOps binds it |

### Delivery and development

| Mechanism | What it guarantees | State | Doc | Enforced by | Next |
|---|---|---|---|---|---|
| **Offline test suite** | Compositions render what you expect; XRs conform to their XRDs | ✅ 19 cases, 18 invariants, 9 negative cases | [`tests/README.md`](../tests/README.md) | `make test`, pre-commit, `pr-validate` | — |
| **API-compat gate** | A released XRD only grows | ✅ | [Releasing](development/releasing.md#a-released-xrd-only-grows) | `make test-api-compat`, `make release` | — |
| **Date-named releases** | A dated snapshot; only changed packages rebuilt; notes required when not `safe` | ✅ `release-2026-09-15` cut, tag not yet pushed | [Releasing](development/releasing.md) | `make release`, `publish-packages` workflow | `git push origin release-2026-09-15` — lets CI build and push the `ghcr.io/wxops-idp/wxops-core/*` images |
| **In-cluster tests** | Provider RBAC, installed CRD versions, real reconciliation | ❌ | [What the suite cannot catch](../tests/README.md#what-this-suite-cannot-catch) | — | No plan yet |
| **GitOps contract** | Who writes tenant XRs, and where they live | ❌ undecided | [`ROADMAP.md` Backlog](_archives/ROADMAP.md#portal-and-gitops-contract) | — | [Open decision 3](_archives/ROADMAP.md#open-decisions) |
| **Portal** | The product surface over these APIs (lives outside this repo) | 📋 | [Portal integration](../docs/user-guide/portal-integration.md) | — | [Backlog](_archives/ROADMAP.md#portal-and-gitops-contract) |
| **OSS release** | The repository is ready for outside contributors | 🔶 licence, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, GitHub CI, package naming, README all done | [`ROADMAP.md` Release readiness](_archives/ROADMAP.md#release-readiness) | — | `make release ALL=1` — the one remaining, user-triggered action |

---

## Where new docs go

Two homes, split by reader: **`docs/`** explains the platform to anyone who uses it, builds on it or learns from it; **`development-docs/`**
records how it is built, decided, proposed and released. Ask "does this help someone *use* or *understand* W'xOps Core, or does it help
someone *change* it?"

| You are writing… | Put it in | Also update |
|---|---|---|
| A concept newcomers need before they can read this repo | `docs/learn/` | The table in [`learn/README.md`](../docs/learn/README.md) and the hub's *Learn* table |
| Reference for a new Kind | `docs/api-reference/<package>.md` | The Kind catalogue in [`api-reference/README.md`](../docs/api-reference/README.md), the [status contract](../docs/api-reference/status-contract.md), and a *Platform APIs* row in the matrix below |
| A design, proposal or piece of research about the platform itself | `docs/core-ideas/` | A `> **Status: …**` banner, the *Core ideas* table in the matrix below, and [solution-matrix](../docs/core-ideas/solution-matrix.md) rows if it adds problems |
| A how-to for people running or consuming the platform | `docs/user-guide/` | The hub's *User guide* table |
| How to build, test or release | `development-docs/development/` | The *Development* table above, and a *Delivery and development* row if it adds a mechanism |
| A decision of lasting consequence — breaking, architectural, a rejection | `development-docs/adr/` | Copy [`TEMPLATE.md`](adr/TEMPLATE.md), add a row to [`adr/README.md`](adr/README.md)'s index and the *ADR* table above |
| A proposal to argue before building — a new capability, package, schema or tooling change | `development-docs/rfc/` | Copy [`TEMPLATE.md`](rfc/TEMPLATE.md), add a row to [`rfc/README.md`](rfc/README.md)'s index |
| A planned or deferred piece of work | `development-docs/rfc/` | An RFC, or a bullet in an existing one's own *Rollout Plan*/*Drawbacks*, if it belongs to that RFC |
| A rejection to record | `development-docs/adr/` or the RFC it belongs to | A small decision folds into the RFC's own body (see RFC-003 §What ships next for the pattern); one of lasting consequence gets an ADR |

Two homes, no others: do not add a third top-level docs folder. Prose wraps at about 160 characters
(see [`CLAUDE.md`](../CLAUDE.md#documentation-conventions)).
