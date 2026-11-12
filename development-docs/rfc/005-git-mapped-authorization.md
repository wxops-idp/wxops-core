# RFC-005: Authorization mapped one-to-one to Git — who owns each Core XR, and the rules that seal it

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Implemented (Phase 1) — closed 2026-11-11. The Platform API roles shipped in `release-2026-11-04`, and the spike ran with `owner-seal`'s Core options built.
The other phases moved to the RFCs that deliver them ([Rollout Plan](#rollout-plan)). [RFC-010](010-namespaced-tenant-kinds.md) and
[ADR-005](../adr/005-kind-ownership-scope-and-naming.md) make the tenant kinds namespaced, superseding this RFC's "cluster scope kept" for them. The Argo
path and redirect domains go to [RFC-008](008-built-in-tools-identity-and-catalog.md). Phase 3 is not needed, because the Portal never writes to Kubernetes.
Aligned 2026-10-24 with [RFC-009](009-scm-personas.md): personas, bindings and the policy package are RFC-009's; this RFC is what is specific to Core's own kinds.

## Summary

[RFC-009](009-scm-personas.md) gives the platform its access layers: `XPersona` (who), `XPersonaBinding` (which kinds), `XPlatformPolicy` (which objects).
This RFC applies them to **Core's own XRs** — `XTenantApp`, `XTenantDatabase`, the `XScm*` and `XOIDC*` kinds — which are cluster-scoped, so RBAC alone cannot
say whose they are.

| Layer | For Core XRs | Defined in |
|---|---|---|
| Who | the persona a team is in — `owners`, `developers`, `viewers`, `platform` | RFC-009 |
| Which kinds | `wxops:platform-view` / `-edit` / `-admin`, bound by `XPersonaBinding` with `scope: platform` | RFC-009, roles below |
| Which objects | the **`wxops.cloud/owner` label** on every Core XR, and **five rules** rendered as `XPlatformPolicy` templates | **this RFC** |

A person may write a Core XR only if its owner is one of their SCM teams, may never move it to another owner, and may target `prod` only through a persona
that reaches `prod`. The link between a Git team and an owner is the team's slug — no mapping table, nothing to drift.

## Motivation

[RFC-004](004-dex-identity-and-portal-authentication.md) makes a person's identity and Git memberships available, and RFC-009 decides what each persona may
reach. Core's kinds still need three things of their own:

1. **Every Core kind is cluster-scoped** (`scope: Cluster` on all fourteen XRDs), so there is no namespace to scope a binding to. `wxops:platform-edit` can grant
   "create `XTenantApp`", but not "only for `team-alpha`'s apps" — `resourceNames` does not help when the name is chosen at creation.
2. **Ownership is not a uniform field.** Only `XTenantDatabase` has an `owner` parameter (it drives the Vault path); the other kinds express ownership as
   `orgName`, a namespace, or not at all. A rule about "whose resource is this" needs one place to look.
3. **Authorization drifts unless it has one source.** If team membership is copied into a cluster-side mapping, the copy goes stale the first time someone
   leaves a team. Authorization has to *be* Git state.

The Kyverno controller is a bootstrap prerequisite of every W'xOps cluster, installed with the cluster like Pinniped — nothing in W'xOps installs it — and it
is the settled choice for validation and guardrails ([`_archives/ROADMAP.md`](../_archives/ROADMAP.md)).

## Detailed Design

### Principles

- **Git is the only place authorization is written.** Personas, bindings and policies are XRs in the GitOps repository, reviewed as diffs (RFC-009).
- **No parallel mapping table.** A Git team's slug *is* the owner value, checked by policy.
- **Kyverno guards people, not the system.** Rules match SCM users today and AI agents later; Argo CD, Crossplane and every controller answer to their own
  permissions ([RFC-009](009-scm-personas.md#xplatformpolicy--on-which-objects)).
- **Kyverno validates; it never generates RBAC.** RFC-009's one mutation, `owner-stamp`, copies a namespace's owner and so never touches a cluster-scoped
  Core XR — its owner is set by the writer and checked here.
- **Small on purpose.** [ADR-001](../adr/001-package-channel-label.md) records why a heavier guardrail system was rejected as something one maintainer cannot
  operate or explain. Five rules; growth beyond that needs its own RFC.

### Attributes

| | Attribute | Source |
|---|---|---|
| **Subject** | `username`, `groups` (`<org>:<team>`) | Dex, through Pinniped or the Portal's impersonation — `request.userInfo` |
| **Subject** | persona | membership of an `XPersona`, inlined into a rule only where the rule differs per persona |
| **Resource** | owner | a **required label** `wxops.cloud/owner` on every Core XR |
| **Resource** | environment | `spec.parameters.environment` where the kind has it (`XTenantApp`) |
| **Resource** | kind, target cluster | the XR itself |

The `wxops.cloud/owner` label is the trust anchor. It is added to every kind by policy, not by an XRD change, so it is `safe`-tier. It is required at creation
and **immutable** on Core XRs, so a resource cannot be reassigned to escape a rule. Its value is the Git team's slug — the same string a namespaced XR's
namespace would carry, so a later namespaced kind is not ruled out. A label value cannot contain `/`, so the owner is a **flat** slug; GitLab subgroup paths
are not supported in v1 ([RFC-003](003-scm-connections-and-resources.md#vendor-alignment)).

### The one-to-one rule

A subject may write a Core XR whose `wxops.cloud/owner` is `X` only if their `groups` contain `<org>:X`, as `XScmTeam.status.oidcGroup` publishes it. There is
no table: team `team-alpha` is owner `team-alpha`, and leaving the team in Git removes the ability at the next token.

**What a team may do is its persona's**, not a naming convention:

| Persona ([RFC-009](009-scm-personas.md#default-personas)) | On its own Core XRs |
|---|---|
| `viewers` | read (`wxops:platform-view`) |
| `developers` | create and update, `dev` and `staging` |
| `owners` | as `developers`, and `prod` — the maintainer tier: a team's `-maintainers` team joins `owners` |
| `platform` | any owner, and the platform-only kinds — onboarding and break-glass, audited |

### What the connector guarantees today

[`XOIDCConnector`](../../docs/api-reference/auth/oidc-connector.md#choosing-which-teams-can-sign-in) already decides which Git teams reach the `groups` claim at all:
a team is in the claim only if an `XScmTeam` labelled `scm.wxops.cloud/oidc-login` generates it, or an operator lists it by hand, for an org the connector
admits. Each entry is the team's `status.dexTeam` — the lowercase **slug on GitHub**, the team name as created on Gitea — and the resulting group is
`<org>:<team>`. Groups reach RBAC exactly as the claim carries them — nothing transforms them — so a Gitea team named `Owners` is `wxops:Owners` while the
same team on GitHub is `wxops:owners`. Only slug-form names are the same on every vendor. How the owner label and the rules handle a team that is not in slug
form is [open question 11](#open-questions).

### Three writers, two enforcement models

| Writer | Requesting user Kyverno sees | Who is authorized, and where |
|---|---|---|
| **A person directly** (`kubectl`) | the person, through Pinniped (bootstrap; the impersonation proxy where in use) | the five rules |
| **Portal** on a person's behalf | the person — the Portal impersonates them and their groups | the five rules. The Portal's own account holds only `impersonate`, restricted by `resourceNames` to Dex-shaped group names |
| **AI agent** (later) | its ServiceAccount, listed in its persona | the rules, once [RFC-009 Phase 7](009-scm-personas.md#rollout-plan) matches agents |
| **Argo CD** applying a commit | its controller — **not matched by any rule** | Argo CD's own model ([RFC-008](008-built-in-tools-identity-and-catalog.md#what-renders-per-tool)): `AppProject` sources, destinations and roles bound to SCM groups. The person was authorized when the commit was **merged** (branch protection, CODEOWNERS on `tenants/<owner>/`) |

This is deliberate: on the GitOps path the strongest "1-to-1 with Git" is the Git vendor's own permission on the merge, enforced by Argo CD's projects. A
second check of Argo's writes in Kyverno would duplicate Argo's model and couple every sync to Kyverno's availability. The cost is that an owner label inside
a merged manifest is only as safe as the review of its path.

### Policy set

Five rules, rendered as `XPlatformPolicy` templates — Kyverno CEL `ValidatingPolicy` resources, not the deprecated `ClusterPolicy` (removal scheduled for
v1.20). Three are RFC-009's `owner-seal` with Core options; two are templates this RFC adds to the package.

| # | Rule | Template | Applies to |
|---|---|---|---|
| 1 | `wxops.cloud/owner` is present and matches the team-slug pattern | `owner-seal`, option `ownerPattern` | create, Core kinds |
| 2 | `wxops.cloud/owner` never changes — not even between two of the caller's own teams | `owner-seal`, option `immutableOwner: true` | update, Core kinds |
| 3 | The owner is one of the caller's teams ([case: open question 11](#open-questions)) | `owner-seal` | create, update, delete, Core kinds |
| 4 | `environment: prod` requires a persona whose environments include `prod` | **`environment-gate`** — names personas, so it inlines their subjects | create, update, `XTenantApp` |
| 5 | An `XOIDCClient`'s `redirectUris` sit under a domain its owner may use | **`oidc-redirect-domains`** — option: allowed domain patterns with an `{owner}` placeholder | create, update, `XOIDCClient` — closes [RFC-004](004-dex-identity-and-portal-authentication.md) open question 6 |

Rule 4 reads the XR's own `environment` field, not a cluster label, so it does not wait for the multi-cluster feature. The `platform` persona is exempt from
rules 1–3 — it onboards every team — and every one of its writes is in the audit log.

### RBAC — the coarse layer

Three aggregated Platform API roles, defined in [RFC-009](009-scm-personas.md#extending-the-standard-roles-by-aggregation) and built from one piece per package
in `providers/rbac/aggregate-*.yaml`:

| Role | Core kinds |
|---|---|
| `wxops:platform-view` | read every kind |
| `wxops:platform-edit` | create and update the tenant kinds (`XTenantApp`, `XTenantDatabase`, …) |
| `wxops:platform-admin` | as edit, plus the platform-only kinds (`XScmConnection`, `XOIDCConnection`, `XPlatformDatabaseCluster`, `auth.wxops.cloud`) |

They are bound by `XPersonaBinding` with `scope: platform`. Platform-only kinds sit only in `wxops:platform-admin`, which plain RBAC can express because they
are distinct kinds. Cluster-wide reads under `wxops:platform-view` are accepted for now: admission cannot seal reads, and an XR carries references, not secret
values. A kind that moves to namespace scope (the `XTenantApp` redesign) keeps its piece and is then bound per owned namespace, so other teams can no longer
read it.

### Rollout safety

- **Label first.** Existing XRs carry no owner label; label them — a one-time change — before a rule moves to `Deny`.
- **No audit phase — 2026-11-09.** This RFC's rollout was "audit first": run a rule in `Audit`, read the PolicyReports, then enforce. W'xOps runs no
  PolicyReports and `Audit` is not supported ([RFC-009 decision](009-scm-personas.md#deny-by-default-audit-by-choice--decided-2026-11-06)), so that step
  shows nothing. It is replaced by an **inventory**: list what a rule would refuse before enabling it — for the owner label,
  `kubectl get xtenantapps,xtenantdatabases -L wxops.cloud/owner` shows every Core XR still unlabelled — label at the source (Git or the Portal), and only
  then apply the rule, in `Deny`. A namespace selector cannot stage it either: Core XRs are cluster-scoped, and a selector never skips a cluster-scoped
  object. For one person who must keep working meanwhile, a `temporaryExemptPersonaRef` on the rule, with `until`, is the bridge.
- **`failurePolicy: Fail`** for rules 1–4: if Kyverno is down, people's writes to Core kinds are refused — the correct failure for an authorization control.
  System writes stay unaffected, proven by RFC-009's failure spike; a graceful Kyverno shutdown deletes its webhooks instead, so Kyverno runs in high
  availability ([results](009-scm-personas.md#spike-and-acceptance-results-2026-11-04)).
- **Break-glass** is the `platform` persona, visible in the audit log; it is not a bypass of the policy engine.

### Compatibility and change tier

No XRD changes. The required label is a behaviour change to how existing XRs are admitted, so it ships with hand-written release notes and the
label-first rollout above. The rules ship in RFC-009's `platform-policy` package; `environment-gate` and `oidc-redirect-domains` are added to its template set.

### Testing

The Kyverno CLI's `test` command runs each rendered rule against fixture XRs **with a supplied requesting user**: an allowed and a denied case per rule, and a
case proving an Argo CD or controller request passes untouched. Negative cases carry an `# expect:` reason like the existing ones. These rows join RFC-009's
[acceptance matrix](009-scm-personas.md#acceptance-matrix):

| Test | Expect |
|---|---|
| team-a creates an `XTenantApp` owned by `team-a` · by `team-b` · with no owner | ✓ · ✗ · ✗ |
| a member of `team-a` and `team-b` moves a `team-a` XR to `team-b` | ✗ (rule 2) |
| `developers` set `environment: prod` · `owners` do | ✗ · ✓ |
| an `XOIDCClient` redirect to another owner's domain | ✗ |
| Argo CD syncs an XR owned by `team-b` | ✓ (not matched) |

What the offline tier cannot show is what the API server presents as `userInfo` through Pinniped or the Portal's impersonation — a spike.

## Drawbacks

- **This is the machinery the ROADMAP once rejected.** ADR-001 records a guardrail system cancelled for this shape. The five-rule cap is the mitigation — a
  promise to keep, not a mechanism.
- **A label is the trust anchor.** Anyone who can write an XR can write a label; the rules are what make that safe, so a gap in them is a gap in tenancy.
- **Claims are a login-time snapshot.** Leaving a Git team takes effect at the next token (RFC-004).
- **The Argo path is not sealed by owner.** It rests on Argo CD's projects and merge review; a wrong owner label in a merged manifest is caught by review or
  not at all.
- **Ownership is coupled to Git team slugs.** Renaming a team changes its slug, and its XRs keep the old owner until moved by the `platform` persona.
- **Kyverno is an availability dependency** for every person's write to a Core kind.
- **Kyverno's CEL policy types are newer.** A reported issue concerns `request.userInfo` resolving to null in some contexts of `ValidatingPolicy`
  ([kyverno#15588](https://github.com/kyverno/kyverno/issues/15588)). Every rule reads `userInfo`, so that is a first-order spike item.

## Alternatives

- **Namespaced XRs.** With a namespace per tenant, plain RBAC binds a group to a namespace and most of rules 1–3 disappear. It is not additive: all fourteen XRDs
  are `scope: Cluster`, and a scope change is a new kind. **Decided 2026-10-24:** Core kinds stay cluster-scoped, bound through `wxops:platform-*` and sealed
  by owner; the `XTenantApp` and `XTenantDatabase` redesign is the moment to make the tenant kinds namespaced
  ([Darlane — what comes next](../core-ideas/darlane.md#xdarlane--a-workspace-claim-of-its-own)).
- **`resourceNames` RBAC per XR.** Works only when names are known at grant time, which is exactly what self-service does not have.
- **Kyverno `generate` policies for per-tenant RBAC.** Kyverno's controller would need RBAC-writing permissions and the bindings would skip review. Bindings
  are `XPersonaBinding`'s ([RFC-009](009-scm-personas.md)).
- **Kyverno also sealing Argo CD's writes** (this RFC's first draft), through Argo's tracking annotation. Dropped 2026-10-24: Argo CD has its own permission
  model, and the check depended on an annotation at admission.
- **A `-maintainers` naming convention carrying authority** (this RFC's first draft). Replaced by persona membership: the convention names a team, the
  persona decides what it may do.
- **OPA Gatekeeper or Cedar** in place of Kyverno. Kyverno is installed with every cluster; a second engine for the same job is cost without a new capability.
- **Authorization only in the Portal.** It protects only the path through the Portal; a direct write bypasses it.
- **Do nothing.** Any authenticated person can write any tenant's resources.

## Rollout Plan

Each phase rides on an [RFC-009 phase](009-scm-personas.md#rollout-plan):

- [x] **Spike, before acceptance — run 2026-11-04**, shared with RFC-009 ([results](009-scm-personas.md#spike-and-acceptance-results-2026-11-04)):
  `request.userInfo` reaches a `ValidatingPolicy` unchanged through Pinniped's impersonation proxy, by real logins; an unavailable Kyverno never blocks
  system writes, and a graceful Kyverno shutdown leaves people's writes unchecked for a short window — answered by Kyverno in high availability. Not yet
  exercised: `owner-seal` on a cluster-scoped Core XR itself — the run sealed namespaced objects.
- [x] **Decision on namespaced XRs** — cluster scope kept, 2026-10-24. Reversed for the tenant kinds 2026-11-10 by RFC-010 and ADR-005.
- [x] **Phase 1 — the Platform API roles.** Built 2026-10-26: `wxops:platform-view`, `-edit` and `-admin`, aggregated from one piece per level over the
  three W'xOps groups (`providers/rbac/aggregate-platform.yaml`) — read every kind, write the tenant kinds, write the platform-only kinds — and bound by
  `XPersonaBinding` with `scope: platform` (RFC-009 Phase 2). Live on the hub as the `platform` persona's `wxops:platform-admin` binding.
- [x] **Phase 2 — the label — resolved 2026-11-11 by RFC-010 and ADR-005.** `owner-seal`'s Core options are built — `ownerPattern` and `immutableOwner`,
  with a golden case (`owner-seal-core`) and an example on the [API page](../../docs/api-reference/auth/policy.md#owner-seal) (RFC-009 Phase 3).
  The labelling is not needed: RFC-010's namespaced `XApp` and `XDatabase` take their owner from the namespace, and the platform-run kinds are written only
  by `wxops:platform-admin` (ADR-005 decision 11), so a seal on them adds nothing RBAC does not already do.
- [x] **Phase 3 — the Portal — not needed (2026-11-11).** The Portal reads as the person, through Pinniped, and writes nothing to Kubernetes: every change
  is a commit to the GitOps repository, made with the person's own Git identity. There is no Portal write to impersonate.
- [x] **Phase 4 — environments and OIDC redirects — moved 2026-11-11.** A namespace's environment is gated by `env-gate` (RFC-009, `release-2026-11-09`).
  An app's environment is chosen per app, not per namespace, so the gate on it moves to RFC-010. `oidc-redirect-domains` moves to RFC-008: `XOIDCClient` is
  platform-written today, and once a tenant may request a login client, the allowed domains belong in its `XWorkspaceClass` (open question 10 goes with it).
- [x] **The Argo path, outside Kyverno — moved to [RFC-008](008-built-in-tools-identity-and-catalog.md) Phase 3:** the `AppProject` per workspace.
  CODEOWNERS stays in the GitOps repository.

Open questions after closing: 9 is settled by RFC-010 §5 (`XDatabase` reaches only the shared pool or a cluster labelled with its owner). 11 is enforced by
a composition check on `XScmTeam`, since the `XScm*` kinds keep their names (ADR-005) and a new pattern on a released XRD would be breaking. 8 stays open
in the [access model](../core-ideas/access-model.md#open-decisions).

The two ADRs planned for acceptance were not written: the team slug as the owner is recorded in [ADR-006](../adr/006-team-owner-mapping.md)'s context, and
cluster-scoped tenant kinds are superseded by ADR-005.

## Open Questions

Settled:

1. **Namespaced XRs first? — settled.** No: cluster scope, sealed by owner (Alternatives).
2. **The maintainer tier — settled** by [RFC-009](009-scm-personas.md): a team's `-maintainers` team joins `owners`.
3. **Group format — settled:** `<org>:<team>`.
4. **Who may label? — settled.** Rule 3 makes the first write safe: a person can only label with one of their own teams. Onboarding — creating a team's
   `XScmTeam` and its first XRs — is the `platform` persona's.
5. **`gitea-*` kinds — settled.** Archived, never run; they take no label.
6. **Audit — settled** by [RFC-009](009-scm-personas.md#audit): the API server audit log, shipped to Loki, is the record; PolicyReports are not
   supported yet, so rules are rolled out by inventory and labelling, never by an `Audit` phase
   ([RFC-009 open question 9](009-scm-personas.md#open-questions)).
7. **Tenant = org or team? — settled.** A tenant is a **team inside** the platform's org, so the owner label is a team slug
   ([RFC-003](003-scm-connections-and-resources.md)); `XScmTeam` is created by platform onboarding, not by the tenant it names.

Still open:

8. **Token lifetime.** How stale may a Git membership be? A short access token with refresh lowers the lag and raises load on Dex and the vendor.
9. **Cross-owner references.** A `tenant-app` referencing a shared database cluster, or an `XTenantDatabase` targeting another owner's cluster, crosses
   ownership by design. A sixth rule, or handled by the shared-cluster tiering already in place?
10. **Where rule 5's domains come from** — a pattern on the policy (`{owner}.apps.example.com`), or a list per team on its `XScmTeam`?
11. **Team-name case across vendors — settled in concept (2026-10-24).** RBAC matches groups exactly and nothing transforms them: GitHub's group is always
    the slug (`wxops:owners`), Gitea's keeps the name as created (`wxops:Owners`), and Gitea cannot be configured to force slug names. So **every team that
    takes part in authorization is named in url-slug form** (`a-z0-9-`), and a Gitea group then reads exactly like a GitHub one:
    - **Teams W'xOps creates** (`XScmTeam`, `mode: managed`) accept only slug-form names.
    - **Teams made elsewhere** (`mode: observed`, or the Gitea UI) carry a documented warning: Gitea keeps the case typed. A non-slug team errors visibly and
      reaches nothing — fails closed — until it is renamed.
    - **How it is enforced** (a composition check, or an XRD rule — the latter breaking for released `scm-team`) is decided once the
      SCM → Persona → RBAC → Kyverno chain works end to end.

    Not chosen: carrying the case-preserved name as the owner (namespaces and paths need lowercase anyway), lowercasing only in comparisons (merges `Owners`
    and `owners`), a `XScmTeam` lookup at admission (a lookup on every write), normalising in Dex (no such transform for Gitea).
