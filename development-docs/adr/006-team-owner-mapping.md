# ADR-006: Owner mapping — a team owns its slug, plus the owner its `XScmTeam`'s `wxops.cloud/owner` label names

## Status
<!-- Matches spec.docStatus — single source of truth is the YAML, this is for readers -->
Accepted — 2026-11-07. **Shipped in `release-2026-11-09`.** Built and covered offline (the `persona/with-owner-mapping`, `persona-binding/owned-mapped` and `platform-policy/owner-seal-mapped`
cases). **Proven on the cluster 2026-11-09** in the sandbox, by impersonation: the persona's `status.owners`, the mapped team's RoleBinding in the owner's
namespace only, `owner-seal` allowing it there, and — the mapping removed, RBAC kept — `owner-seal` refusing it. Replayable as `./run.sh mapping`
(`examples/auth/policy/scenarios/mapping.yaml`). Through a real login it is still to run. The check found one defect, fixed before release: a new
persona lookup without `fromFieldPathPolicy: Optional` stopped every existing `XPlatformPolicy` from re-rendering.

## Context

Ownership in W'xOps is a team slug, matched exactly ([RFC-005 question 11](../rfc/005-git-mapped-authorization.md#open-questions)): an object's owner is its
`wxops.cloud/owner` label, or its namespace's, and group `<org>:<team>` owns `<team>` — the text after `:`. Every decision that names an owner reads it that way:

- `XPersonaBinding` with `scope: owned` binds a persona's group in the namespaces whose owner is that group's team;
- `owner-seal` lets a caller write only objects whose owner is one of their teams;
- `exec-guard` lets a persona exec only in namespaces one of their teams owns; `sa-guard` lets a workload run only as a ServiceAccount one of their teams owns.

That leaves no way for a second team to stand for the same owner. `payment-maintainers`, an on-call or maintainer team beside `payment`, owns only
`payment-maintainers` — not `payment`'s namespaces, objects or ServiceAccounts ([access-model open decision 6](../core-ideas/access-model.md#open-decisions)).
Renaming teams to share a slug is not possible across one host, and listing the second team's people in the first team defeats the point of teams. The
`scm/team` package's README already showed the intended shape — a `wxops.cloud/owner` label on an `XScmTeam` — but nothing read it.

## Decision

1. **A team owns its own slug, plus the owner its `XScmTeam` names in a `wxops.cloud/owner` label.** `payment-maintainers` labelled `payment` owns what
   `payment` owns, and still owns `payment-maintainers`. One label, so one extra owner per team; a label equal to the team's own slug maps nothing.
2. **The label lives on the team, and only the platform team writes it.** `XScmTeam`s are platform-written (no persona role grants them), so a mapping is
   a reviewed change in the platform's GitOps repository, like the team itself — never something a team can grant itself.
3. **Only teams that can log in count** — those labelled `scm.wxops.cloud/oidc-login: "true"`, the set `XPersona` and `XOIDCConnector` already draw on —
   and, for policies, only groups of an org in the policy's `scmOrgs`.
4. **Every decision reads the same mapping, by the path that fits it:**

   | Reader | How it gets the mapping |
   |---|---|
   | `XPersona` | Already reads its member teams' objects; publishes `status.owners: [{group, owner}]` beside `status.subjects` — not inside them, because `XPersonaBinding` copies subjects into RoleBindings verbatim |
   | `XPersonaBinding` (`scope: owned`) | A group belongs in a namespace when the namespace's owner is its team slug **or** its mapped owner from `status.owners` |
   | `XPlatformPolicy` (every template) | Reads every team that can log in (`function-extra-resources`, up to 500) and adds the mapped owners to the CEL `teams` variable: `+ groups.filter(g, g in [<mapped groups>]).map(g, {<group>: <owner>}[g])`. No mapping, no change to the rendered policy |

5. **Owner labels on objects keep their precedence** (decided with this): `owner-stamp` keeps an explicit `wxops.cloud/owner` from any writer — a person,
   Argo CD, Crossplane — and fills a missing one from the namespace on create and update. A person's explicit label is still checked by `owner-seal` against
   their teams, mapped owners included.

## Consequences

- **A mapping is a reviewed `XScmTeam` change** — added, moved or removed in Git, visible in the team's own manifest.
- **It converges, it does not switch.** A new mapping reaches bindings at the persona's and the binding's next reconcile, and policies at the policy's;
  removing it takes the same path. A person's group list itself comes from their next token.
- **The policy composition reads every team that can log in**, up to 500, on every reconcile — a read Crossplane already makes for personas.
- **The rendered policy grows** with one map entry per mapped team; it stays a static expression, evaluated in admission without any lookup.
- **Additive everywhere:** a new `XPersona` status field, no new parameter; the `XPersona`, `XPersonaBinding` and `XPlatformPolicy` APIs stay
  `v1alpha1`, and without a mapping their output is unchanged.
- **A team cannot map itself away from its own slug,** and one team cannot stand for two other owners. If that is ever needed, it is a new decision.

## Alternatives Considered

- **A mapping field on `XPersona`** (`ownerMap: {payment-maintainers: payment}`). Puts ownership on the access title instead of the team, so the same team
  would need the mapping repeated in every persona it joins — and a policy would still need to read every persona.
- **A separate mapping kind** (`XOwnerMapping`). One more API and package for what one label on an existing object says; a second place to look.
- **A Kyverno `GlobalContextEntry` listing teams**, read at admission. Live and shared by every policy, but an admission-time dependency on a cached
  entry whose failure behaviour under `failurePolicy: Fail` is not yet known (access-model D4); the composition already has the teams at render time.
- **Rename teams to share a slug,** or list the second team's members in the first. Not possible across one host, and it erases what the second team is for.
