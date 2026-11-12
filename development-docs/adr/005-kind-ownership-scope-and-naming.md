# ADR-005: Kind ownership, scope and naming — the owner decides namespace or cluster and the API group; the name is `X` plus a noun

## Status
<!-- Matches spec.docStatus — single source of truth is the YAML, this is for readers -->
Accepted — 2026-11-06. Amended 2026-11-10: each kind's group and scope are decided beside its name (decisions 7–11), and `XPolicy` moves to RFC-010's work.
Amended 2026-11-11: the `XScm*` kinds keep their names (decision 2), so there is no `scm` rename batch. Later the same day: all four renames are built and the old kinds archived
(see [When names change](#when-names-change)).
Amended 2026-11-12: `categories: [wxops]` goes on **new namespaced tenant kinds only** (decision 4) — `XApp` and `XDatabase` today. Crossplane holds an XRD's whole
`spec.names` immutable, so a released XRD can never gain it, and the platform's cluster-scoped kinds stay out of it on purpose. All four renames and the archive ship in
`release-2026-11-12`; a cluster takes the archive only after its XRs are handed over.

## Context

Fourteen kinds, three naming styles grown up side by side:

| Style | Kinds |
|---|---|
| `X` + the group's word + noun | `XScmConnection`, `XScmRepository`, `XScmOAuthApp`, `XScmTeam` (group `scm`); `XPlatformDatabaseCluster` (group `platform`) |
| `X` + a word from another context + noun | `XPlatformPolicy` (group `auth`) |
| `X` + noun, or a qualifier the group does not carry | `XPersona`, `XPersonaBinding`, `XTenantApp`, `XTenantDatabase`, `XOIDCConnection`, `XOIDCClient`, `XOIDCConnector`, `XOIDCStaticPassword` |

The group already says where a kind belongs ([ADR-002](002-three-api-groups.md)), so `scm.wxops.cloud/XScmTeam` says `scm` twice, and `XPlatformPolicy`
names a group it does not live in. The names are long to type and read, and every new kind adds one more guess at the pattern. The next kinds are close:
[RFC-010](../rfc/010-namespaced-tenant-kinds.md) adds namespaced tenant kinds, and `XPlatformPolicy` runs on one cluster since `release-2026-11-04`, so a
rename now is cheaper than at any later release. Left alone, the mismatch only grows.

Crossplane v2 dropped claims, so `X` no longer separates a composite from its claim, and dropping it was considered (see Alternatives). Two things argue for
keeping it:

- **It marks what W'xOps defines.** On a cluster that also runs Kyverno, CNPG, External Secrets Operator, Argo CD and Crossplane itself, `X` says "this
  comes from the W'xOps IDP" — the X of W'xOps, everything in Ops.
- **It keeps names clear of the stack.** kubectl resolves a kind by its plural. A bare `Policy` would share `policies` with Kyverno's own `Policy`, a bare
  `Database` would share `databases` with the CNPG `Database` that the tenant database kind itself creates. `xpolicies` and `xdatabases` clash with nothing.

A kind's name, group and scope are all fixed in its CRD, so changing any of them is the same replacement. Deciding them apart would migrate the same kinds
twice, and three problems show that the scope is wrong today:

- **`platform.wxops.cloud` holds both sides of the boundary.** `XPlatformDatabaseCluster` is capacity the platform team runs, while `XTenantApp` and
  `XTenantDatabase` belong to one team yet are cluster-scoped, so their ownership rests on a label ([RFC-010](../rfc/010-namespaced-tenant-kinds.md)).
- **Tenant kinds carry choices that are the platform's.** `XTenantDatabase.vaultSecretStoreName` picks the store its `PushSecret` writes through, so a person
  could name a store scoped to another mount. `cluster` picks where an app lands, and nothing checks that the team owns that namespace on that cluster.
- **[ADR-002](002-three-api-groups.md) lists tenants as the audience of `scm`, but RBAC does not.** `providers/rbac/aggregate-platform.yaml` grants `scm` writes
  to `wxops:platform-admin` only, and [ADR-006](006-team-owner-mapping.md) depends on it: the `wxops.cloud/owner` label on an `XScmTeam` grants ownership.

## Decision

1. **Every W'xOps kind starts with `X`.**
2. **After `X`, a noun for the thing, qualified by the external system it manages — never by a side.** `Scm` in `XScmTeam` (a team on a Git host) and
   `OIDC` in `XOIDCClient` (a client of the login broker) stay, even where the group repeats them. Side by side, `XScmConnection` and `XOIDCConnection` say
   what they connect to, while a bare `XConnection` would be ambiguous and take a plural every later connection kind would want. A word that names a side,
   `Platform` or `Tenant`, never appears, because group and scope say that (decisions 7–8). `Persona` in `XPersonaBinding` stays: it is the thing bound.
3. **No plural collides with the reference stack.** A new kind's plural must not equal the plural of any kind on the pinned reference stack (`CLAUDE.md`,
   *Reference stack*) or of another W'xOps kind in any group. `tests/invariants.py` gains that check, against a list kept beside the pinned versions.
4. **Every new namespaced tenant kind carries `categories: [wxops]`, and no cluster-scoped kind does**, so `kubectl get wxops -A` answers one question: what
   the teams run, across every namespace. The platform's cluster-scoped kinds stay out of it — they are a handful of platform-team objects, and mixing them in
   would blur that list. A short name is optional; when given, it starts with `x` too. Both live in `spec.names`, which Crossplane holds immutable, so they are
   chosen when the kind is created and never added later: a released XRD that gains a category or short name is refused ("spec.names: Invalid value: Value is
   immutable"). No patch gets around it: the rule is CEL on the
   XRD (`self == oldSelf`), checked on every update whatever the patch type, and Crossplane re-renders the composite CRD from the XRD on every reconcile. To list
   every composite on a cluster, `kubectl get composite -A` works today — Crossplane adds that category to every composite CRD itself.
5. **A package follows its kind's noun, in kebab case.** A group prefix is added only where the noun alone would repeat across groups, as the `scm-*`
   packages already do (`scm-connection` beside `oidc-connection`). The directory stays `package/<group>/<noun>/` (RFC-007).
6. **Names change only by replacement.** A kind name is part of its CRD, so a rename is a new XRD, a migration and an archived old kind — never an edit.
   New kinds take the convention at once; an existing kind is renamed only in a release that replaces it anyway, or in one deliberate, announced batch.
7. **Scope follows the owner.** A kind that serves one owner is tenant-owned, namespaced, and lives in that owner's namespace. A kind that decides for many
   owners is platform-owned and cluster-scoped.
8. **Four API groups**, extending ADR-002:

   | Group | Scope | Owner |
   |---|---|---|
   | `tenant.wxops.cloud` (new) | Namespaced | One owner: its namespace's `wxops.cloud/owner` |
   | `platform.wxops.cloud` | Cluster | Platform: capacity and templates |
   | `scm.wxops.cloud` | Cluster | Platform: Git hosting |
   | `auth.wxops.cloud` | Cluster | Platform: identity and rules |

   Outside any group, the namespace, its owner and environment labels and its defaults are the platform team's, through GitOps. What runs inside a namespace
   is the tenant's, within its persona roles.
9. **Group and scope say where a kind lives and whose it is; persona roles say who may write it.** `XWorkspace` belongs in `tenant` because it serves one owner,
   though the platform team writes it until tenants may ([RFC-008 question 8](../rfc/008-built-in-tools-identity-and-catalog.md#open-questions)).
10. **A tenant kind never carries its owner, its target or a platform choice:**

    | Not a field on a tenant kind | Decided by |
    |---|---|
    | Target namespace, owner | The XR's namespace and that namespace's `wxops.cloud/owner` |
    | CNPG cluster and its namespace | Platform: a shared pool, or a dedicated `XDatabaseCluster` labelled with the owner |
    | Dedicated cluster sizing | Platform: on the `XDatabaseCluster` |
    | Secret store | The composition; per-owner stores arrive with RFC-008 |
    | Target Kubernetes cluster | Platform: the hub today; later mapped from the app's chosen environment, once [multi-cluster](../core-ideas/multi-cluster.md) exists (RFC-010 §2b) |
    | `wxops.cloud/*` labels on composed resources | The composition: user-supplied keys under that prefix are dropped |

11. **`scm` is platform-written.** `XScmConnection`, `XScmOAuthApp` and `XScmTeam` stay so for good, and `XScmTeam` must, because of ADR-006.
    `XScmRepository` serves one owner, but it stays in `scm`, platform-written. Whether a team may request a repository is decided with RFC-008's
    tenant-writable workspaces, not by moving the kind.

### What the scope rule makes easier

| | Namespaced tenant kind | Why it matters |
|---|---|---|
| **Migration** | Name, group and scope change in one replacement | A scope cannot change on an existing CRD, so this is the only time to do it |
| **Development** | One question places a new kind. A namespaced XR composes only into its own namespace, so the namespace is the composition's input | No owner or target logic per package, and one failure to test: a namespace with no owner renders nothing |
| **Use** | `XApp` is created where it runs, with no owner or namespace to type | Names only need to be unique per namespace, so two teams can both run `checkout` |
| **Policies** | RBAC reaches it through `scope: owned`; `owner-stamp` labels it; `owner-seal` falls back to the namespace; `namespaceSelector` and `env-gate` apply | None of these work fully on a cluster-scoped kind: `owner-stamp` needs a namespace, and a selector never skips a cluster-scoped object |

### When names change

| Today | New name | Group, scope | Package | When |
|---|---|---|---|---|
| `XPlatformPolicy` | `XPolicy` | `auth`, cluster | `policy` | **Done** — `release-2026-11-12`; the old kind archived in the same release |
| RFC-010's tenant kinds | `XApp`, `XDatabase` | `tenant`, namespaced | `package/tenant/app`, `package/tenant/database` | **Done** — `release-2026-11-12`, new kinds |
| `XPlatformDatabaseCluster` | `XDatabaseCluster` | `platform`, cluster | `database-cluster` | **Done** — `release-2026-11-12`, archived with the others |
| `XTenantApp`, `XTenantDatabase` | — (replaced by `XApp`, `XDatabase`) | — | archived | **Done** — `release-2026-11-12` (RFC-010 Phase 6) |
| Planned | `XWorkspace`; `XWorkspaceClass` | `tenant`, namespaced; `platform`, cluster | per RFC-008 | With RFC-008 |
| Planned | `XDarlane` | `tenant`, namespaced | per `darlane.md` | With the Darlane split |
| `XScmConnection`, `XScmRepository`, `XScmOAuthApp`, `XScmTeam` | — | `scm`, cluster | — | Already conform (decision 2) |
| `XPersona`, `XPersonaBinding`, `XOIDC*` | — | `auth`, cluster | — | Already conform |

## Consequences

- **Each rename is a breaking release** with an `api-compat` allow-list entry, breaking release notes, and a migration: the old kind's composed objects are
  orphaned, the new kind adopts them under the same names, then the old XRs and XRD are archived (`package/<group>/archives/`, `tests/cases/_archives/`,
  `docs/api-reference/_archives/`). For `XPolicy` that means the Kyverno policy keeps its name, `wxops-<xr-name>`, so enforcement never lapses during the
  switch — to be proven on the cluster before the release.
- **Cross-package references move with the kind.** `function-extra-resources` selectors name kinds: `tenant-database` reads `XPlatformDatabaseCluster`,
  so it changes with that rename. A rename updates every reader in the same release.
- **Only names that say a side are renamed.** The `XScm*`, `XOIDC*` and `XPersona*` kinds keep theirs, so `persona`, `oidc-connector`, the Portal and the
  `dexidp` chart are not touched.
- **Two names are served for a while** for each renamed kind, from the release that adds the new one to the one that archives the old.
- **Docs, examples and RBAC follow:** the API pages, `examples/<group>/<noun>/`, the `wxops:platform-*` and persona pieces (`resources:` lists name
  plurals), `VERSIONS.yaml`, `CLAUDE.md`'s package table, and the Portal client.
- **`categories: [wxops]` is not additive.** It is part of `spec.names`, which an XRD cannot change, so it is decided when a kind is created: `XApp` and
  `XDatabase` carry it, and `kubectl get wxops -A` lists what teams run. `tests/api_compat.py` refuses any change to a released XRD's `spec.names`, and
  `tests/invariants.py` asks every new namespaced XRD for the category and refuses it on a cluster-scoped one.
- New kinds stop needing a naming discussion: `X`, the noun, the collision check, and who owns it.
- **Everything that knows three groups learns a fourth:** `wxops:piece:platform-read`, a new persona piece, `VERSIONS.yaml`, `package/tenant/`, the tests and
  docs that name groups, and the Portal client.
- **Tenant reads are granted explicitly.** The persona piece for tenant kinds includes `get`, `list` and `watch`, so access does not depend on whether a kind
  is aggregated into Kubernetes' `view`.
- **`XApp` and `XDatabase` start on the hub only.** `XTenantApp`'s `cluster` field has no successor: the team chooses an environment and, with
  multi-cluster, the platform maps it to a cluster. An app on a spoke stays on `XTenantApp` until then.
- **Shared-pool placement does not read other teams' databases.** `tenant-database` picked the least-loaded cluster by counting every peer database; once those are
  namespaced, that would mean reading other tenants' namespaces. `XDatabase` places a database by a stable hash of owner and name instead, and names the PostgreSQL
  database `<owner>-<dbName>` so nothing needs to see its peers (RFC-010 §5).

## Alternatives Considered

- **Drop `X` as well** (`Policy`, `App`, `Database`, `DatabaseCluster`). Shortest, and Crossplane v2's own examples do it, but it loses the W'xOps mark and
  collides on the reference stack exactly where it matters: `policies` with Kyverno, `databases` with CNPG.
- **Pick collision-free plain nouns** (`Guardrail` for the policy kind, `PostgresDatabase` for the database). Works, but every name becomes a one-off search
  for a word nothing else uses, with no rule a newcomer can follow.
- **Keep today's names.** No migration, but the three styles stay, every new kind adds a guess, and the cost of fixing it rises with each cluster that
  adopts the current names.
- **Drop `Scm` from the `XScm*` kinds** (`XConnection`, `XRepository`, `XOAuthApp`, `XTeam`) — planned until 2026-11-11. Shorter, but it hides which system
  each kind manages, makes `XConnection` ambiguous beside `XOIDCConnection`, takes plurals later kinds would want, and costs a breaking migration that
  touches the Dex chart and the Portal for no gain in meaning.
- **Rename everything in one release.** One break instead of several, but it would land on top of the policy and tenant work with nothing gained.
- **Keep the tenant kinds in `platform.wxops.cloud`.** No new group, but it mixes namespaced tenant kinds with cluster-scoped platform ones, and RBAC and
  policies cannot name either side by group.
- **`tenant` means "tenants write it".** Simple to explain, but `XWorkspace` would start in `platform` and need replacing the day tenants may write it.
- **Keep the owner and target fields and check them by policy.** Needs a rule that matches every caller, Argo CD included, and a lookup on each write. The
  namespace answers the same question by construction.
- **Keep `cluster` on `XApp`.** Matches `XTenantApp`, but leaves a team able to write into a namespace of the same name on another cluster, unchecked, for a
  capability only the hub uses today.
- **Move `XScmRepository` to `tenant`.** Right by the scope rule, but a plural cannot be served by two groups at once, so it would need a new name and a
  Git-hosting migration in the middle of the tenant work.
