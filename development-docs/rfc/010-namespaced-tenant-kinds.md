# RFC-010: Namespaced tenant kinds — `XApp` and `XDatabase` live in the tenant's namespace, so the namespace decides who owns them

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Draft — 2026-11-05, updated 2026-11-11. Builds on [RFC-009](009-scm-personas.md) (personas, bindings, the policy templates) and takes over what
[RFC-005](005-git-mapped-authorization.md) left for the tenant kinds. Group, scope and field ownership are decided in
[ADR-005](../adr/005-kind-ownership-scope-and-naming.md), and the environment is chosen per app (§2b). **Built in full 2026-11-11, unreleased:** the new kinds (Phases 2 and 3),
the migration runbook (5) and the archive (6) are in the tree; the cluster checks (Phases 1 and 4) are run on the sandbox and the status flips with the release. This RFC draws
the boundaries on the hub alone; multi-cluster and Argo CD across clusters will revisit placement when they arrive.

## Summary

`XTenantApp` and `XTenantDatabase` are cluster-scoped today, so the ownership rules of RFC-009 reach them only half-way: `owner-stamp` cannot label them (it
copies a *namespace's* owner, and they have none), `owner-seal` refuses every person when their label is missing, and nothing ties the label to where their
resources actually land. This RFC adds two **namespaced** kinds, `XApp` and `XDatabase`, created *in the tenant's namespace*. The namespace then
decides everything ownership needs: RBAC reaches the XR through `scope: owned` bindings, `owner-stamp` labels it on CREATE and UPDATE, `owner-seal` checks it on CREATE,
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
change. They are named by [ADR-005](../adr/005-kind-ownership-scope-and-naming.md): `X` plus a noun, never the group's word — `xapps` and `xdatabases` also stay
clear of CNPG's own `databases`. They live in `tenant.wxops.cloud`, by the same ADR's scope rule.
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
    environment: prod           # optional, chosen per app (§2b)
    # no `namespace:` — the XR's own namespace is the target
    # no owner anywhere — the namespace's wxops.cloud/owner is the owner
```

### 2. What the namespace now decides

| Concern | `XTenantApp` / `XTenantDatabase` today | `XApp` / `XDatabase` |
|---|---|---|
| Where workloads land | `spec.parameters.namespace` (any namespace) | The XR's `metadata.namespace` — the field is gone |
| Who owns it | The XR's label, set by hand | The namespace's `wxops.cloud/owner`, guarded by `namespace-guard` |
| OpenBao path and PostgreSQL role scope | `spec.parameters.owner` (free text) | The namespace's owner — the field is gone |
| Target Kubernetes cluster | `spec.parameters.cluster` (any `ProviderConfig`) | The hub — the field is gone; later the platform maps the app's environment to a cluster (§2b) |
| Environment | `spec.parameters.environment`: `dev`, `staging` or `prod`, default `dev` | `spec.parameters.environment`: optional, any name the platform uses (§2b) |
| Secret store for database credentials | `spec.parameters.vaultSecretStoreName` (any store) | Set by the composition — the field is gone |
| Who may write it (layer 2) | Anyone with `wxops:platform-edit`, cluster-wide | A persona with a `RoleBinding` in that namespace (`scope: owned`) |
| Labels on composed resources | User `labels` may carry `wxops.cloud/*` | The composition drops every user `wxops.cloud/*` key and sets `wxops.cloud/owner` itself |

### 2b. Environment — chosen per app, not per namespace

The namespace is the team. The environment is a stage the team picks for each app when it creates it, and it does not change what the namespace means.

- **Optional, and not a fixed set.** A team may run only `dev`, or `dev` and `prod`, or no environment at all. The XRD checks the name's format, not a
  list of three. An app without an environment is a plain app in its team's namespace: no environment label, and no environment rule applies to it.
- **One `XApp` per environment.** Each environment is one overlay in the GitOps repository, and each overlay is one `XApp` — in the `tenants-apps` layout,
  `dev` syncs automatically and `staging` and `production` wait at a manual sync. **Promotion is a Git change between overlays**; teams never see where an
  environment runs.
- **On the hub today, every environment lands in the team's namespace.** Two environments of one app in the same namespace need different names, so the
  XR's name is the app's name on the cluster and the overlay adds a suffix (`checkout-dev`, `checkout-prod`). Core adds no renaming of its own.
- **The composition labels every composed resource `wxops.cloud/environment: <env>`**, as `XTenantApp` does, and Darlane's `productionOverride` reads the
  same field.
- **`env-gate` also guards an app's own environment.** Today it guards namespaces whose `wxops.cloud/environment` is listed. It also matches `XApp` and
  `XDatabase` whose `spec.parameters.environment` is listed: a person creates, updates or deletes one only as a member of the gate's persona, and an update
  is checked on both the old and the new environment, so `prod` cannot be renamed `dev` to slip past. Argo CD is not matched, so Git stays the way to
  change a guarded app. **Built 2026-11-11** as a second Kyverno policy, `wxops-<name>-apps`, matching only `xapps` and `xdatabases` in `tenant.wxops.cloud` — a namespace
  selector cannot do it, because the field can be set in a namespace that is not labelled. Every guarded environment the change touches, before and after, must be in the
  persona's `environments`. API-compat rates it `safe` — the first policy is unchanged and a second composed resource is additive — but it **widens what an existing
  `env-gate` enforces**: once the `app` and `database` packages are installed, every existing `env-gate` XR starts guarding applications declared in its environments, so the
  release notes say so. The old `XTenantApp` and `XTenantDatabase` are not guarded by field: teams cannot write them, and they are archived.
- **Limit on a shared cluster:** the environment is the team's declaration, so the gate protects the apps declared `prod`, not apps that are really
  production. That changes once environments have their own clusters: declaring `dev` then means running on the dev cluster.
- **Later, with multi-cluster:** the platform maps each environment to a cluster (a `ClusterProviderConfig` labelled `wxops.cloud/environment`), and the
  team's namespace exists under the same name on every cluster, created by the `tenants` ApplicationSet. Not built here: multi-cluster and Argo CD across
  clusters will revisit placement.

### 3. The admission lifecycle — mutating, then validating, per operation

The reason for this RFC. Every row below is a scenario row in Phase 4.

| Operation | Writer | Layer 2 — RBAC | Mutating — `owner-stamp` | Validating — `owner-seal` (and `protected`) |
|---|---|---|---|---|
| **CREATE** `XApp` in `payment` | alice (`acme:payment`) | ✅ `RoleBinding` in `payment` | Adds `wxops.cloud/owner: payment` if missing | `newOwner` = label, else namespace → `payment` ∈ alice's teams ✅ |
| CREATE in `billing` | alice | ❌ no `RoleBinding` there — refused before admission | — | — |
| CREATE in `payment` labelled `billing` | alice, also in `acme:billing` | ✅ | Skipped (label present) | ✅ — an explicit label is kept ([ADR-006](../adr/006-team-owner-mapping.md)) |
| **UPDATE** | alice | ✅ | Adds the label if missing | `oldOwner` and `newOwner` ∈ alice's teams; with `immutableOwner`, the label may not change ✅ |
| UPDATE of a `wxops.cloud/protected: "true"` app | alice | ✅ | Adds the label if missing | `protected` refuses unless exempt ❌ |
| **DELETE** | alice | ✅ | — | `oldOwner` ∈ alice's teams ✅ |
| CREATE / UPDATE / DELETE | Argo CD | its own RBAC | Adds the label if missing | Not matched (a `system:` user) — AppProjects and review govern it |
| Composed Deployment, Service, IngressRoute, … | provider-kubernetes | its own RBAC | Skipped — the composition already set the label | Not matched |
| Pods and ReplicaSets from a Deployment | Kubernetes controllers | — | Adds the label if missing | Not matched |
| CREATE / UPDATE an `XApp` with a guarded `environment` | bob, in the gate's persona | ✅ | As above | `owner-seal` ✅, `env-gate` ✅ |
| Same, or UPDATE `prod` → `dev` | dan, same team, not in the persona | ✅ | As above | `env-gate` refuses ❌ |

Two layers now separate teams, each doing what it is good at: **RBAC keeps a team out of other namespaces; admission keeps the owner label honest inside
its own.** `owner-required` is not needed for the tenant kinds — in a tenant namespace the owner always resolves, and outside one it resolves to `''`, which
`owner-seal` refuses.

### 4. Composition changes

| Piece | Today | New |
|---|---|---|
| Composed resource kind | `kubernetes.crossplane.io/v1alpha2` `Object` (cluster-scoped) | `kubernetes.m.crossplane.io/v1alpha1` `Object` (namespaced) — a namespaced XR composes only into its own namespace. Present in provider-kubernetes v1.2.1 |
| Provider config | `ProviderConfig` named by `spec.parameters.cluster` | The hub's `ClusterProviderConfig`, platform-owned and fixed by the composition — a tenant neither creates nor names one |
| Owner | — / `spec.parameters.owner` | `function-extra-resources` reads the XR's `Namespace` (by `metadata.namespace`); no `wxops.cloud/owner` → a new XR renders nothing, `ready: false`, `syncMessage` says the namespace is not a tenant namespace; one that already composed resources **fails the reconcile** instead, so removing a label never deletes a running app or database. Fails closed |
| Labels | `_userLabels \| selector \| wxops.cloud/*` (`kcl/tenant-app/main.k:267`) | User labels minus `wxops.cloud/*`, then `wxops.cloud/owner` from the namespace, on every composed resource and inside every manifest |
| Deletion ordering (`XDatabase`) | `ClusterUsage` | A namespaced `Usage` in the XR's namespace |

Setting the owner label in the composition, rather than leaving it to `owner-stamp`, matters for resources outside a tenant namespace (`XDatabase`'s, below),
which `owner-stamp` cannot reach, and later for spoke clusters, whose Kyverno may not run the template. It also keeps the label in provider-kubernetes's
desired manifest, so the provider never sees a label it did not write.

### 5. `XDatabase` specifics

`XDatabase` is harder than `XApp`, because what it provisions does not live in the tenant's namespace:

- **The PostgreSQL `Role`, the CNPG `Database` and the credentials `ExternalSecret` live in the CNPG cluster's namespace** (`clusterNamespace`) — a CNPG
  `Database` must sit beside its `Cluster`. The namespaced `Object` stays in the tenant's namespace and its manifest targets the CNPG namespace. The
  provider's namespaced `Object` controller applies the manifest's own namespace — **as written**: it does not default a missing one to the Object's (every namespaced
  manifest a tenant composition emits sets `metadata.namespace`, and `tests/invariants.py` enforces it) and does not restrict it — and it wraps cluster-scoped kinds too,
  as its own example does and as the provider-sql `Role` needs. Read in the provider's v1.2.1 code, **not yet run on a cluster** (Phase 1; the API server and the provider's
  RBAC are the parts the code cannot answer). A namespaced `Object` also has no `spec.deletionPolicy` — its CRD lists none — so an `Object` that must outlive its XR
  leaves `Delete` out of `spec.managementPolicies`. These resources are outside any tenant namespace, so the composition's owner label is the only one they get.
- **`clusterRef` and `clusterNamespace` become platform decisions.** Today a person may point a database at any CNPG cluster. On the tenant kind, the
  composition accepts only a pool cluster labelled `shared`, or the dedicated `XDatabaseCluster` named `<owner>-<dbName>-cluster` whose `wxops.cloud/owner` equals the
  namespace's owner and which is `shared: false` — all found through `function-extra-resources`, which the package already uses. `clusterNamespace` is read from the
  chosen cluster, never typed. **Built 2026-11-11.**
- **`tier: dedicated` references a cluster, it does not create one**: a namespaced XR composes only into its own namespace, so the platform team creates the
  `XDatabaseCluster`, labelled with its owner, and `XDatabase` only points at it. `dedicatedCluster` sizing moves there too.
- **Shared-pool placement is a platform decision, and `XDatabase` does not read other teams' databases.** `tenant-database` picked the least-loaded cluster by counting
  every peer `XTenantDatabase`; once namespaced, those peers are in other tenants' namespaces, and `function-extra-resources` does not document listing a namespaced kind
  across them. Decided instead: the first assignment is the cluster an `XTenantDatabase` of the same owner and `dbName` already runs on (the same database, moving kinds —
  adoption needs it), else a stable hash of `<owner>/<dbName>` over the shared clusters of its environment, kept in `status.clusterRef` so a new cluster never moves a
  database. A **stable spread, not least-loaded**; least-loaded returns if the Phase 1 spike shows other namespaces can be read.
- **The PostgreSQL database name is unique by construction.** `dbName` was unique per cluster, so two teams could not both have `app`; names are now unique per namespace,
  so two teams naming a database `app` is normal and would collide on one cluster. The database is named `<owner>-<dbName>` (like its role) unless `databaseName` is set —
  which a migration sets to the old bare `dbName`, since the name of an existing CNPG database cannot change. This also removes the need to see other teams' databases.
- **The OpenBao path** `tenants/<owner>/databases/<dbName>/connection-creds` and the role name take `<owner>` from the namespace — the confused deputy closes.
- **The composition sets the secret store.** `vaultSecretStoreName` could point the `PushSecret` at a store scoped to another mount. Per-owner stores arrive
  with [RFC-008](008-built-in-tools-identity-and-catalog.md).

### 6. RBAC

- A new persona piece in `providers/rbac/aggregate-persona.yaml`, `wxops:piece:persona-write-tenant`, grants create/update/patch/delete on `xapps` and
  `xdatabases`, labelled `aggregate-to-persona-developers` and `aggregate-to-persona-owners`. Bound with `scope: owned`, it reaches only the team's
  namespaces.
- A read piece grants `get`, `list` and `watch` on those kinds to all three team personas, so reading them does not depend on Kubernetes' `view`.
- `wxops:piece:platform-read` adds `tenant.wxops.cloud`.
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
gains one rule: a namespaced tenant kind composes only `kubernetes.m.crossplane.io` `Object`s and namespaced `Usage`s. `platform-policy` gains `env-gate`
cases for an app's own environment, including an update that changes it.

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

- [x] **Phase 0 — decide.** Group, scope and Q1–Q4 are settled in [ADR-005](../adr/005-kind-ownership-scope-and-naming.md). The order is policies, database clusters, apps, then
  databases; the style is handover in place, with one breaking archive at the end.
- [ ] **Phase 1 — spike** on the test cluster, by hand, before any package:
  - a namespaced XR composing `kubernetes.m.crossplane.io` `Object`s through a `ClusterProviderConfig`, on provider-kubernetes v1.2.1 (and v1.4.x, P1 #6);
  - a namespaced `Object` whose manifest targets another namespace (the CNPG one) and a cluster-scoped kind;
  - `function-extra-resources` reading the XR's `Namespace` — Crossplane's own RBAC to get Namespaces;
  - optional: `function-extra-resources` listing `XDatabase`s across namespaces — only to bring least-loaded placement back; nothing depends on it;
  - a namespaced `Usage` ordering the Role after the Database;
  - **adoption**: an old `XTenantApp`'s `Object`s set to orphan, the XR deleted, a `XApp` of the same name taking the Deployment over by server-side
    apply — no Pod restart, no selector change.
- [ ] **Phase 2 — `XApp`.** Package, tests, API page, persona piece, `ClusterProviderConfig` for the hub, and `env-gate` on an app's own environment (§2b).
  Release `safe` for the new package, and for the `platform-policy` change (additive, though it widens what `env-gate` enforces — say so in the release notes). **Built 2026-11-11, unreleased**, `env-gate` on the app's environment included and proven on the sandbox on 2026-11-12
  (`./run.sh env-gate`, 21 of 21 rows); the Phase 1 spike items for `XApp` (the `.m` Objects, the Namespace lookup, adoption with no restart) are still to run on a cluster. The package takes `appName` as an
  optional field, so a migrated application keeps the resource names its `XTenantApp` gave it.
- [ ] **Phase 3 — `XDatabase`.** Package with the pool and dedicated-cluster checks, tests, API page. Release `safe`. `namespace-guard` in `Deny` first.
  **Built 2026-11-11, unreleased.** The cluster spike items for it (the cross-namespace `Object`, the namespaced `Usage`, adoption with no password rotation and no new OpenBao
  version, the dedicated handover) are still to run on a cluster.
- [ ] **Phase 4 — the lifecycle rows** of §3 on the cluster, through real logins: CREATE / UPDATE / DELETE by the owner, by another team, by Argo CD; label
  forging through `labels`; a non-tenant namespace; a guarded environment, written and renamed by someone outside the gate's persona.
- [x] **Phase 5 — migrate** (the runbook — running it is the user's). A migration page in `docs/user-guide/`: per XR, orphan → create the new kind → verify adoption → delete the old XR; in Git,
  sync waves so Argo CD creates the new kind before it prunes the old. Portal switches kinds (`docs/user-guide/portal-integration.md`).
- [x] **Phase 6 — archive** (in the tree, 2026-11-11 — the release is the user's) `XPlatformPolicy`, `XPlatformDatabaseCluster`, `XTenantApp`, `XTenantDatabase` in a breaking release; `wxops:platform-edit` loses the tenant kinds; RFC-005 Phase 2 drops the
  tenant kinds from its "label Core XRs" step.

## Open Questions

Settled 2026-11-10 ([ADR-005](../adr/005-kind-ownership-scope-and-naming.md)):

1. **API group — `tenant.wxops.cloud`, new.** Packages land at `package/tenant/app/` and `package/tenant/database/`.
2. **`spec.parameters.cluster` — not on `XApp` or `XDatabase`.** It would let a team write into a namespace of the same name on another cluster, unchecked.
   Placement later follows the app's environment, mapped by the platform once [multi-cluster](../core-ideas/multi-cluster.md) exists (§2b).
3. **`tier: dedicated` — the platform team creates the cluster,** labelled with its owner, and `XDatabase` only references it.
4. **`owner-stamp` keeps an explicit label** and fills a missing one from the namespace (decided with [ADR-006](../adr/006-team-owner-mapping.md)); `owner-seal`
   still checks an explicit label against the writer's teams.

Settled 2026-11-11:

- **Environment — per app, optional, any name; one `XApp` per environment; promotion through Git; guarded by `env-gate` on the app's own field** (§2b).

Open:

5. **Same manifest names on migration.** Adoption needs the new kind to render the same names inside each manifest (`metadata.name = appName` for the
   Deployment, Service and the rest). The `Object`s themselves change kind, from cluster-scoped `<appName>-deployment` to namespaced
   `payment/<appName>-deployment`, so the two never clash. Confirm in Phase 1 that only the `Object`s change hands.
6. **A database without an environment — settled 2026-11-11: the `dev` pool**, the one every `XTenantDatabase` defaulted to, so a migration is a copy. A team that runs a
   production database says `environment: prod`. Revisit if a default pool that is not `dev` is wanted.
