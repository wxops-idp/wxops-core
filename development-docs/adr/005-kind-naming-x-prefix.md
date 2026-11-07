# ADR-005: Kind naming — `X` plus a noun, never repeating the API group

## Status
<!-- Matches spec.docStatus — single source of truth is the YAML, this is for readers -->
Accepted — 2026-11-06. The renames it schedules are not done yet; each lands in the release named in [When names change](#when-names-change).

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

## Decision

1. **Every W'xOps kind starts with `X`.**
2. **After `X`, a noun for the thing — never a word the API group already says.** A qualifier stays only when it adds meaning the group does not: `OIDC`
   in `XOIDCClient` (the group is `auth`, not `oidc`), `Persona` in `XPersonaBinding`.
3. **No plural collides with the reference stack.** A new kind's plural must not equal the plural of any kind on the pinned reference stack (`CLAUDE.md`,
   *Reference stack*) or of another W'xOps kind in any group. `tests/invariants.py` gains that check, against a list kept beside the pinned versions.
4. **Every XRD carries `categories: [wxops]`**, so `kubectl get wxops -A` lists every W'xOps object on a cluster. A short name is optional; when given, it
   starts with `x` too.
5. **A package follows its kind's noun, in kebab case.** A group prefix is added only where the noun alone would repeat across groups, as the `scm-*`
   packages already do (`scm-connection` beside `oidc-connection`). The directory stays `package/<group>/<noun>/` (RFC-007).
6. **Names change only by replacement.** A kind name is part of its CRD, so a rename is a new XRD, a migration and an archived old kind — never an edit.
   New kinds take the convention at once; an existing kind is renamed only in a release that replaces it anyway, or in one deliberate, announced batch.

### When names change

| Today | New name | Package | When |
|---|---|---|---|
| `XPlatformPolicy` | `XPolicy` | `policy` | **Next release**, beside the `Deny` default — one cluster runs it today |
| RFC-010's namespaced tenant kinds | `XApp`, `XDatabase` | per RFC-010 Q1 (the API group) | With RFC-010 — new kinds, no rename cost |
| `XPlatformDatabaseCluster` | `XDatabaseCluster` | `database-cluster` | With RFC-010 — `tenant-database` discovers it by kind and is reworked there anyway |
| `XTenantApp`, `XTenantDatabase` | — (replaced by `XApp`, `XDatabase`) | archived | RFC-010 Phase 6 |
| `XScmConnection`, `XScmRepository`, `XScmOAuthApp`, `XScmTeam` | `XConnection`, `XRepository`, `XOAuthApp`, `XTeam` | unchanged (`scm-*`) | One batch, scheduled on its own — `persona` and `oidc-connector` read them by kind, and the Portal and the `dexidp` chart's docs name them |
| `XPersona`, `XPersonaBinding`, `XOIDC*` | — | — | Already conform |

## Consequences

- **Each rename is a breaking release** with an `api-compat` allow-list entry, breaking release notes, and a migration: the old kind's composed objects are
  orphaned, the new kind adopts them under the same names, then the old XRs and XRD are archived (`package/<group>/archives/`, `tests/cases/_archives/`,
  `docs/api-reference/_archives/`). For `XPolicy` that means the Kyverno policy keeps its name, `wxops-<xr-name>`, so enforcement never lapses during the
  switch — to be proven on the cluster before the release.
- **Cross-package references move with the kind.** `function-extra-resources` selectors name kinds: `persona` and `oidc-connector` read `XScm*`,
  `tenant-database` reads `XPlatformDatabaseCluster`, `persona-binding` and `platform-policy` read `XPersona`. A rename updates every reader in the same
  release.
- **Two names are served for a while** for each renamed kind, from the release that adds the new one to the one that archives the old.
- **Docs, examples and RBAC follow:** the API pages, `examples/<group>/<noun>/`, the `wxops:platform-*` and persona pieces (`resources:` lists name
  plurals), `VERSIONS.yaml`, `CLAUDE.md`'s package table, and the Portal client.
- **`categories: [wxops]`** is additive and can land on every existing XRD without a rename. The first XRD to carry it confirms Crossplane passes it
  through to the composite's CRD.
- New kinds stop needing a naming discussion: `X`, the noun, the collision check.

## Alternatives Considered

- **Drop `X` as well** (`Policy`, `App`, `Database`, `DatabaseCluster`). Shortest, and Crossplane v2's own examples do it, but it loses the W'xOps mark and
  collides on the reference stack exactly where it matters: `policies` with Kyverno, `databases` with CNPG.
- **Pick collision-free plain nouns** (`Guardrail` for the policy kind, `PostgresDatabase` for the database). Works, but every name becomes a one-off search
  for a word nothing else uses, with no rule a newcomer can follow.
- **Keep today's names.** No migration, but the three styles stay, every new kind adds a guess, and the cost of fixing it rises with each cluster that
  adopts the current names.
- **Rename everything in one release.** One break instead of several, but it lands the `scm` and auth renames, which touch the Dex chart and the Portal, on
  top of the policy and tenant work, with nothing gained from waiting for those two.
