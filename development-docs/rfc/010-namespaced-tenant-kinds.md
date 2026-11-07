# RFC-010: Namespaced tenant kinds — `XApp` and `XDatabase` live in the tenant's namespace, so the namespace decides who owns them

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Draft — 2026-11-05. Builds on [RFC-009](009-scm-personas.md) (personas, bindings, the eight templates) and narrows [RFC-005](005-git-mapped-authorization.md)
Phase 2 for the tenant kinds. Needs an ADR before Phase 2 (the scope of tenant kinds, and the API group if [Q1](#open-questions) picks a new one).

## Summary

`XTenantApp` and `XTenantDatabase` are cluster-scoped today, so the ownership rules of RFC-009 reach them only half-way: `owner-stamp` cannot label them (it
copies a *namespace's* owner, and they have none), `owner-seal` refuses every person when their label is missing, and nothing ties the label to where their
resources actually land. This RFC adds two **namespaced** kinds, `XApp` and `XDatabase`, created *in the tenant's namespace*. The namespace then
decides everything ownership needs: RBAC reaches the XR through `scope: owned` bindings, `owner-stamp` labels it on CREATE, `owner-seal` checks it on CREATE,
UPDATE and DELETE with the namespace as fallback, and the composition takes the owner from the namespace — never from a field a person types. The cluster-scoped
kinds are deprecated, migrated without downtime, then archived in a breaking release.

## Motivation

The 2026-11-04 release proved the eight templates in `Deny` on a cluster, but the walkthrough after it found that the tenant kinds sit outside the model:

| Gap | Why it exists | Cost today |
|---|---|---|
| **No automatic owner on the XR** | `owner-stamp` is `scope: Namespaced` and copies the namespace's `wxops.cloud/owner`; a cluster-scoped XR has no namespace | Every author (Git, Portal, kubectl) must remember the label; an unlabelled XR is frozen for every person once `owner-seal` runs in `Deny` — hence RFC-005's "label first" inventory |
| **The label and the target can disagree** | `XTenantApp.spec.parameters.namespace` and `XTenantDatabase.spec.parameters.owner` decide where things land; `owner-seal` checks only the label, and provider-kubernetes, which writes the real resources, is never matched | A person labels an app `team-a` and points it at `team-b-prod`, or a database at `tenants/team-b/…` in OpenBao — a confused deputy |
| **`labels` can forge the owner** | `XTenantApp`'s user `labels` are merged onto every composed resource; only `app-flavor` and `environment` take precedence | `labels: {wxops.cloud/owner: team-b}` lands on every resource and `owner-stamp`, which never overwrites, keeps it |
| **RBAC is cluster-wide** | Writes go through `wxops:platform-edit` (`providers/rbac/aggregate-platform.yaml`), a `ClusterRoleBinding` | Layer 2 cannot tell teams apart; layer 3 alone separates them |
| **Names are global** | `XTenantApp` composes cluster-scoped `Object`s named `<appName>-deployment`, `<appName>-service`, … (`kcl/tenant-app/main.k:448`) | Two teams cannot both run an app called `checkout`, even in their own namespaces |
| **A fourth template would be needed** | Closing the above for cluster-scoped kinds means `owner-required`, a shape rule matching *every* caller, Argo CD included | A new exception to "Argo CD is never matched", and a `resource.Get` per write |

With a namespaced kind, four of the six disappear by construction and the other two shrink to a composition rule.

## Detailed Design

### 1. Two new namespaced kinds

| Today (cluster-scoped, `platform.wxops.cloud/v1alpha1`) | New (namespaced) |
|---|---|
| `XTenantApp` | `XApp` |
| `XTenantDatabase` | `XDatabase` |

A CRD's `scope` cannot change, and two kinds in one group cannot share a plural, so these are **new kinds**, added beside the old ones — an additive (`safe`)
change. They are named by [ADR-005](../adr/005-kind-naming-x-prefix.md): `X` plus a noun, never the group's word — `xapps` and `xdatabases` also stay
clear of CNPG's own `databases`. Which API group they live in is [Q1](#open-questions); the sketches below use `tenant.wxops.cloud`, the recommendation.
`XPlatformDatabaseCluster` becomes `XDatabaseCluster` in the same work (ADR-005), since `XDatabase` discovers it by kind.

```yaml
apiVersion: tenant.wxops.cloud/v1alpha1
kind: XApp
metadata:
  name: checkout
  namespace: payment            # a tenant namespace: auth.wxops.cloud/tenant-namespace=true, wxops.cloud/owner=payment
spec:
  parameters:
    image: ghcr.io/acme/checkout:1.4.2
    environment: prod
    # no `namespace:` — the XR's own namespace is the target
    # no owner anywhere — the namespace's wxops.cloud/owner is the owner
```

### 2. What the namespace now decides

| Concern | `XTenantApp` / `XTenantDatabase` today | `XApp` / `XDatabase` |
|---|---|---|
| Where workloads land | `spec.parameters.namespace` (any namespace) | The XR's `metadata.namespace` — the field is gone |
| Who owns it | The XR's label, set by hand | The namespace's `wxops.cloud/owner`, guarded by `namespace-guard` |
| OpenBao path and PostgreSQL role scope | `spec.parameters.owner` (free text) | The namespace's owner — the field is gone |
| Who may write it (layer 2) | Anyone with `wxops:platform-edit`, cluster-wide | A persona with a `RoleBinding` in that namespace (`scope: owned`) |
| Labels on composed resources | User `labels` may carry `wxops.cloud/*` | The composition drops every user `wxops.cloud/*` key and sets `wxops.cloud/owner` itself |

### 3. The admission lifecycle — mutating, then validating, per operation

The reason for this RFC. Every row below is a scenario row in Phase 4.

| Operation | Writer | Layer 2 — RBAC | Mutating — `owner-stamp` | Validating — `owner-seal` (and `protected`) |
|---|---|---|---|---|
| **CREATE** `XApp` in `payment` | alice (`acme:payment`) | ✅ `RoleBinding` in `payment` | Adds `wxops.cloud/owner: payment` if missing | `newOwner` = label, else namespace → `payment` ∈ alice's teams ✅ |
| CREATE in `billing` | alice | ❌ no `RoleBinding` there — refused before admission | — | — |
| CREATE in `payment` labelled `billing` | alice, also in `acme:billing` | ✅ | Skipped (label present) | ✅ by `owner-seal` today — see [Q4](#open-questions) |
| **UPDATE** | alice | ✅ | — (CREATE only) | `oldOwner` and `newOwner` ∈ alice's teams; with `immutableOwner`, the label may not change ✅ |
| UPDATE of a `wxops.cloud/protected: "true"` app | alice | ✅ | — | `protected` refuses unless exempt ❌ |
| **DELETE** | alice | ✅ | — | `oldOwner` ∈ alice's teams ✅ |
| CREATE / UPDATE / DELETE | Argo CD | its own RBAC | Adds the label if missing | Not matched (a `system:` user) — AppProjects and review govern it |
| Composed Deployment, Service, IngressRoute, … | provider-kubernetes | its own RBAC | Skipped — the composition already set the label | Not matched |
| Pods and ReplicaSets from a Deployment | Kubernetes controllers | — | Adds the label if missing | Not matched |

Two layers now separate teams, each doing what it is good at: **RBAC keeps a team out of other namespaces; admission keeps the owner label honest inside
its own.** `owner-required` is not needed for the tenant kinds — in a tenant namespace the owner always resolves, and outside one it resolves to `''`, which
`owner-seal` refuses.

### 4. Composition changes

| Piece | Today | New |
|---|---|---|
| Composed resource kind | `kubernetes.crossplane.io/v1alpha2` `Object` (cluster-scoped) | `kubernetes.m.crossplane.io/v1alpha1` `Object` (namespaced) — a namespaced XR composes only into its own namespace. Present in provider-kubernetes v1.2.1 |
| Provider config | `ProviderConfig` named by `spec.parameters.cluster` | A `ClusterProviderConfig` per target cluster, platform-owned — a tenant cannot create one |
| Owner | — / `spec.parameters.owner` | `function-extra-resources` reads the XR's `Namespace` (by `metadata.namespace`); no `wxops.cloud/owner` → render nothing, `ready: false`, `syncMessage` says the namespace is not a tenant namespace. Fails closed |
| Labels | `_userLabels \| selector \| wxops.cloud/*` (`kcl/tenant-app/main.k:267`) | User labels minus `wxops.cloud/*`, then `wxops.cloud/owner` from the namespace, on every composed resource and inside every manifest |
| Deletion ordering (`XDatabase`) | `ClusterUsage` | A namespaced `Usage` in the XR's namespace |

Setting the owner label in the composition, rather than leaving it to `owner-stamp`, matters for two cases `owner-stamp` cannot reach: resources applied to
a **spoke cluster** (`cluster:` → another `ClusterProviderConfig`, whose Kyverno may not run the template), and resources outside a tenant namespace
(`XDatabase`'s, below). It also keeps the label in provider-kubernetes's desired manifest, so the provider never sees a label it did not write.

### 5. `XDatabase` specifics

`XDatabase` is harder than `XApp`, because what it provisions does not live in the tenant's namespace:

- **The PostgreSQL `Role`, the CNPG `Database` and the credentials `ExternalSecret` live in the CNPG cluster's namespace** (`clusterNamespace`) — a CNPG
  `Database` must sit beside its `Cluster`. The namespaced `Object` stays in the tenant's namespace and its manifest targets the CNPG namespace. The
  provider's namespaced `Object` controller applies the manifest's own namespace, and its own example manages a cluster-scoped `Namespace` — read in the code,
  **not yet tested** (Phase 1). These resources are outside any tenant namespace, so the composition's owner label is the only one they get.
- **`clusterRef` and `clusterNamespace` become platform decisions.** Today a person may point a database at any CNPG cluster. On the tenant kind, the
  composition accepts only a pool cluster labelled `shared`, or a dedicated `XDatabaseCluster` whose `wxops.cloud/owner` equals the namespace's
  owner — both found through `function-extra-resources`, which the package already uses. `clusterNamespace` is read from the chosen cluster, never typed.
- **`tier: dedicated` cannot compose a child `XDatabaseCluster`**: it is cluster-scoped, and a namespaced XR composes only into its own namespace.
  See [Q3](#open-questions).
- **The OpenBao path** `tenants/<owner>/databases/<dbName>/connection-creds` and the role name take `<owner>` from the namespace — the confused deputy closes.

### 6. RBAC

- A new persona piece in `providers/rbac/aggregate-persona.yaml`, `wxops:piece:persona-write-tenant`, grants create/update/patch/delete on `xapps` and
  `xdatabases`, labelled `aggregate-to-persona-developers` and `aggregate-to-persona-owners`. Bound with `scope: owned`, it reaches only the team's
  namespaces. `view` already lets every persona read them in namespaces it is bound in.
- `wxops:platform-edit` keeps `xtenantapps`/`xtenantdatabases` until the old kinds are archived, then loses them. The Platform API roles go back to what
  RFC-005 meant them for: platform-run, cluster-scoped kinds.
- No change to `provider-kubernetes`'s `bind` list or to the persona-binding invariant.

### 7. Change tier and packages

| Step | Tier |
|---|---|
| Add `XApp`, `XDatabase` (new XRDs, new packages) | `safe` — additive |
| Persona piece, `ClusterProviderConfig`s | `safe` |
| Deprecate `XTenantApp`, `XTenantDatabase` (docs and release notes only) | `safe` |
| Remove them (archive per the repo convention: `package/platform/archives/`, `tests/cases/_archives/`, `docs/api-reference/_archives/`) | **`breaking`** — an allow-list entry and breaking release notes |

Test cases per new package: one per conditional branch as usual, plus `not-tenant-namespace` (renders nothing, fails closed), `user-labels-owner-dropped`
(a user `wxops.cloud/owner` never reaches a resource), and for `XDatabase` `cluster-of-another-team` (refused) and `shared-pool`. `tests/invariants.py`
gains one rule: a namespaced tenant kind composes only `kubernetes.m.crossplane.io` `Object`s and namespaced `Usage`s.

## Drawbacks

- **Two kinds for the same thing during migration**: the Portal, docs and Git must know both until the old ones are archived.
- **A breaking release at the end.** Unavoidable: Crossplane has no conversion between scopes, and `test-api-compat` cannot make it additive.
- **Every app is touched once.** The migration is per XR, and each needs the adoption check in Phase 5.
- **`XDatabase` crosses namespaces by design** (§5), so it relies on the composition, not on Kubernetes scoping, for its CNPG-side resources.
- **Namespace labels become load-bearing for more.** They already were for `scope: owned`; now they also set OpenBao paths. `namespace-guard` must run in
  `Deny` before Phase 3.

## Alternatives

- **Keep the kinds cluster-scoped and add `owner-required`** (a shape rule for every caller, the label must equal `spec.owner` or the target namespace's
  owner). No migration, but it matches Argo CD, adds a `resource.Get` per write, keeps writes on a cluster-wide binding, and leaves the "label first"
  inventory. Kept as the fallback if Phase 1 fails.
- **`scope: LegacyCluster` with namespaced claims.** The v1 model: a claim in the tenant namespace, an XR at cluster scope. Crossplane v2 keeps it only for
  compatibility, and it doubles every object. Rejected.
- **Same kind names in a new version.** Not possible: scope is per CRD, not per version.
- **`NamespacedValidatingPolicy` per tenant namespace** instead of moving the kinds. It cannot see cluster-scoped XRs at all, so it does not help.
- **Only `XApp`, leave `XDatabase` cluster-scoped.** Possible if Phase 1 shows the cross-namespace `Object` does not work; the database then
  needs `owner-required`'s `spec.owner` rule.

## Rollout Plan

- [ ] **Phase 0 — decide.** Accept this RFC; answer Q1–Q3; write the ADR (tenant kinds are namespaced; the API group if new).
- [ ] **Phase 1 — spike** on the test cluster, by hand, before any package:
  - a namespaced XR composing `kubernetes.m.crossplane.io` `Object`s through a `ClusterProviderConfig`, on provider-kubernetes v1.2.1 (and v1.4.x, P1 #6);
  - a namespaced `Object` whose manifest targets another namespace (the CNPG one) and a cluster-scoped kind;
  - `function-extra-resources` reading the XR's `Namespace` — Crossplane's own RBAC to get Namespaces;
  - a namespaced `Usage` ordering the Role after the Database;
  - **adoption**: an old `XTenantApp`'s `Object`s set to orphan, the XR deleted, a `XApp` of the same name taking the Deployment over by server-side
    apply — no Pod restart, no selector change.
- [ ] **Phase 2 — `XApp`.** Package, tests, API page, persona piece, `ClusterProviderConfig` for the hub. Release `safe`.
- [ ] **Phase 3 — `XDatabase`.** Package with the pool and dedicated-cluster checks, tests, API page. Release `safe`. `namespace-guard` in `Deny` first.
- [ ] **Phase 4 — the lifecycle rows** of §3 on the cluster, through real logins: CREATE / UPDATE / DELETE by the owner, by another team, by Argo CD; label
  forging through `labels`; a non-tenant namespace; a spoke if one exists.
- [ ] **Phase 5 — migrate.** A migration page in `docs/user-guide/`: per XR, orphan → create the new kind → verify adoption → delete the old XR; in Git,
  sync waves so Argo CD creates the new kind before it prunes the old. Portal switches kinds (`docs/user-guide/portal-integration.md`).
- [ ] **Phase 6 — archive** `XTenantApp`, `XTenantDatabase` in a breaking release; `wxops:platform-edit` loses the tenant kinds; RFC-005 Phase 2 drops the
  tenant kinds from its "label Core XRs" step.

## Open Questions

1. **Which API group?**
   - **A. `tenant.wxops.cloud`, new** (recommended) — tenant-owned, namespaced kinds in one group: RBAC pieces and Kyverno rules can name the group,
     packages land at `package/tenant/app/` and `package/tenant/database/` without a name clash, and `platform.wxops.cloud` stays platform-run. Needs an ADR
     beside [ADR-002](../adr/002-three-api-groups.md) (three groups → four).
   - **B. `platform.wxops.cloud`, new kinds** — no new group or ADR-002 change, but the group then mixes namespaced tenant kinds with cluster-scoped platform
     ones, and the packages need names other than `tenant-app`/`tenant-database` until the old ones are archived.
2. **Does `spec.parameters.cluster` stay on `XApp`?** It picks a spoke through a `ClusterProviderConfig`. Keep it, or derive it from the namespace
   (`wxops.cloud/cluster`) once the multi-cluster identity exists ([multi-cluster](../core-ideas/multi-cluster.md))?
3. **`tier: dedicated`.** A namespaced XR cannot compose the cluster-scoped `XDatabaseCluster`. Options: (a) the platform team creates dedicated
   clusters, labelled with their owner, and `XDatabase` only references them (lean: it keeps dedicated capacity a platform decision); (b) wrap the child
   XR in a namespaced `Object`, losing XR-to-XR readiness.
4. **Should `owner-stamp` always set the namespace's owner** (drop `object-has-no-owner`), so the label inside a tenant namespace is always the namespace's?
   It closes the third CREATE row of §3 for every writer at once, and owner mapping (P1 #3) maps teams to owners rather than labelling objects differently.
   A change to `platform-policy`, independent of this RFC.
5. **Same manifest names on migration.** Adoption needs the new kind to render the same names inside each manifest (`metadata.name = appName` for the
   Deployment, Service and the rest). The `Object`s themselves change kind, from cluster-scoped `<appName>-deployment` to namespaced
   `payment/<appName>-deployment`, so the two never clash. Confirm in Phase 1 that only the `Object`s change hands.
