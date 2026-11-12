# RFC-008: Built-in tools — one login, a tenant workspace per namespace, and a catalog for Argo CD, Grafana and OpenBao

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Draft — rewritten 2026-11-08: one tenant kind, `XWorkspace`, renders each tool's **native** objects for a tenant namespace from a platform-owned
`XWorkspaceClass`, instead of the platform team writing them by hand per team. The 2026-10-24 draft's rule "no W'xOps kind per tool" holds in its intent —
no tool's fields are mirrored on the tenant's claim — and its tool-by-tool facts (logins, defaults, OpenBao bootstrap, the catalog) carry over below. That
draft replaced the first one, "platform tools as APIs" (`XSecret*`, `XMonitoring*`, `XGitOpsProject`). Needs the `tenant.wxops.cloud` group, shared with
[RFC-010](010-namespaced-tenant-kinds.md) Q1, and an ADR for it.

## Summary

The platform ships three built-in tools: **Argo CD** (GitOps), **Grafana** (monitoring) and **OpenBao** (secrets). Each is configured through its own
objects — an `AppProject`, a grafana-operator `GrafanaFolder`, `provider-vault`'s managed resources for OpenBao — and those native objects stay the truth.
What W'xOps adds:

| W'xOps adds | How | Where it is defined |
|---|---|---|
| **One login** | An `XOIDCClient` per tool, against the platform's Dex | [RFC-004](004-dex-identity-and-portal-authentication.md) — built |
| **A workspace per tenant** | An `XWorkspace` in the tenant's namespace renders its slice of each tool — the `AppProject`, the `GrafanaFolder`, the OpenBao policy, group and alias — from a platform `XWorkspaceClass` | this RFC |
| **Persona access, derived** | Each native grant names the SCM groups of the teams that own the namespace, in the role of their persona — read from teams, personas and the owner mapping, never typed | [RFC-009](009-scm-personas.md), [ADR-006](../adr/006-team-owner-mapping.md) |
| **A catalog** | Every rendered object carries `wxops.cloud/owner` and `wxops.cloud/tool`; the catalog reads them from the cluster and from Git | this RFC |
| **A default setup** | Documented bootstrap values per tool — login, default roles — so every installation starts the same way | this RFC, `docs/user-guide/setup.md` |

## Motivation

1. **Hand-written grants drift.** The previous draft had the platform team write one `AppProject`, one `GrafanaFolder` and a set of OpenBao objects per team.
   A persona change was a hand edit in each tool (its first drawback), and three tools held three slightly different ideas of who a team is.
2. **Access is already decided elsewhere.** Who owns a namespace (`wxops.cloud/owner`, guarded by `namespace-guard`), which teams stand for that owner (the
   team slug, plus ADR-006's mapping) and which persona each team is in (`auth.wxops.cloud/persona-<name>`) are all in the cluster. The tool grants should
   follow from them, the way `XPersonaBinding` follows from them for Kubernetes.
3. **A tenant needs an isolated workspace in each tool,** and teams that cross — a maintainer team beside its product team — need the same slice without a
   second set of hand edits.
4. **Tenants are bootstrapped from GitOps already.** A team's `tenants/<name>/` directory holds its namespace and defaults
   ([access model](../core-ideas/access-model.md#namespace-defaults-come-from-gitops--decided-2026-11-08)); one more object there gives it its tools.

## Detailed Design

### Scope

| In this RFC | Not in this RFC |
|---|---|
| `XWorkspaceClass` and `XWorkspace`, and the native objects they render | Who is in which persona — [RFC-009](009-scm-personas.md) |
| Each tool's login, default roles and bootstrap, as a documented setup | A tool's own API surface — never mirrored |
| The catalog: labels and what it reads | The Portal's UI — [portal integration](../../docs/user-guide/portal-integration.md) |
| OpenBao configuration through `provider-vault`, on the hub | Secret **values** — External Secrets Operator's alone, as today |

### Principles

| Rule | Why |
|---|---|
| **Native objects are the truth.** W'xOps renders them; it adds no kind that mirrors a tool | Upstream documentation stays the documentation |
| **The tenant's claim carries no tool fields.** Tool configuration — roles, permission levels, capabilities — lives in the platform's class | The claim cannot drift into a second API, and cannot ask for more than the class offers |
| **Groups are derived, never typed.** From the namespace's owner, the teams that stand for it (slug or ADR-006 mapping) and their personas | A tenant cannot name another team's group; leaving a Git team removes the access in every tool |
| **No access by default.** A new login sees nothing until a workspace or the platform's defaults grant it | The safe failure for a missing grant is "cannot see" |
| **Capture, don't wrap.** Rendered objects carry two labels; the catalog reads them | Objects made outside W'xOps still show up, as not in Git |
| **The platform team owns each tool's bootstrap** — login, default roles, admin credentials | One owner for the decisions that shape every tenant's access |

### `XWorkspaceClass` — the platform's template configuration

Cluster-scoped, in `platform.wxops.cloud`, written by the platform team only. One class per way of serving tenants (`standard`, `regulated`, …); the
`platform` persona's own access is not here — it is each tool's bootstrap default.

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XWorkspaceClass
metadata:
  name: standard
spec:
  parameters:
    argocd:
      namespace: argocd                                   # where Argo CD runs — every tenant's AppProject is rendered here
      sourceRepos: ["https://git.example.com/wxops-idp/{owner}-*"]   # {owner} is the workspace's owner
      roles:                                              # per persona: project-scoped actions on applications
        owners:     [get, sync, override, delete]
        developers: [get, sync]
        viewers:    [get]
    grafana:
      instanceSelector: {matchLabels: {dashboards: grafana}}
      permissions: {owners: Admin, developers: Edit, viewers: View}
    openbao:
      mount: tenants                                      # the Vault path convention's tenant mount
      capabilities: {owners: [read, list], developers: [read]}
```

### `XWorkspace` — the tenant's claim

Namespaced, in `tenant.wxops.cloud`, one per tenant namespace, committed in the team's `tenants/<name>/` directory beside the namespace defaults. Written by
the platform team today; tenant-writable later, bounded by the class ([open question 2](#open-questions)).

```yaml
apiVersion: tenant.wxops.cloud/v1alpha1
kind: XWorkspace
metadata:
  name: payment
  namespace: payment            # owner = this namespace's wxops.cloud/owner
spec:
  parameters:
    classRef: {name: standard}
    tools: [openbao, grafana, argocd]   # opt in per tool
    # no owner, no groups, no roles: all derived
```

**Who the workspace is for.** Its owner is its namespace's `wxops.cloud/owner`. The teams that count are every `XScmTeam` that can log in
(`scm.wxops.cloud/oidc-login: "true"`) whose slug is that owner, or whose `wxops.cloud/owner` label maps it there (ADR-006). Each team takes the role of its
persona (`auth.wxops.cloud/persona-<name>`) as the class names it; a team in a persona the class does not list gets nothing. The owner's namespaces are every
namespace labelled `auth.wxops.cloud/tenant-namespace: "true"` with the same owner. A namespace with no owner renders nothing and says so.

### What renders, per tool

All objects carry `wxops.cloud/owner: <owner>` and `wxops.cloud/tool: <tool>`, and are named after the owner.

| Tool | Native object | Where it lives | Content |
|---|---|---|---|
| **OpenBao** | `provider-vault` `Policy` per persona; external `Group` and `GroupAlias` per team | the tenant namespace — `provider-vault` v4's namespaced managed resources, through the hub's `ClusterProviderConfig` | `path "<mount>/data/<owner>/*"` and `metadata/` with the class's capabilities; the alias is the team's group string, exactly |
| **Grafana** | grafana-operator `GrafanaFolder` `<owner>` | the tenant namespace, reaching the Grafana instance with `allowCrossNamespaceImport` | folder permissions per persona, from the class |
| **Argo CD** | `AppProject` `<owner>` | **the class's `argocd.namespace`** — where Argo CD is deployed | `sourceRepos` from the class pattern; `destinations` = the owner's namespaces; `clusterResourceWhitelist: []`; one role per persona with its teams' groups and the class's actions as `proj:<owner>:<persona>` policies |

The `AppProject` is the one object outside the tenant namespace. A namespaced XR composes only into its own namespace, so it is rendered as a namespaced
provider-kubernetes `Object` in the tenant namespace whose manifest targets Argo CD's — the same cross-namespace write [RFC-010](010-namespaced-tenant-kinds.md)
needs for `XDatabase`: the provider's v1.2.1 code applies a manifest's namespace as written and does not restrict it, but it is **not yet run on a cluster** (Phase 0). If it does not hold, only this piece moves to a small cluster-scoped
kind; OpenBao and Grafana stay in the tenant namespace.

### Persona → tool access

What the `standard` class gives; another class may differ. The `platform` persona is each tool's bootstrap default, not part of any workspace.

| Persona | Kubernetes ([RFC-009](009-scm-personas.md)) | Argo CD (`AppProject` role) | Grafana (folder) | OpenBao (`<mount>/<owner>/`) |
|---|---|---|---|---|
| `viewers` | `wxops:persona-viewers` | `get` | View | — |
| `developers` | `wxops:persona-developers` | `get`, `sync` | Edit | `read` |
| `owners` | `wxops:persona-owners` | `get`, `sync`, `override`, `delete` | Admin | `read`, `list` |
| `platform` | `wxops:persona-platform` | `role:admin` in `argocd-rbac-cm` | org `Admin` | admin policy |

Values stay External Secrets Operator's: no rendered policy writes a secret, and the persona roles never read Secrets in Kubernetes.

### Logins and bootstrap — unchanged from the previous draft

| Tool | Login | Default access | Bootstrap that stays the platform team's |
|---|---|---|---|
| **Argo CD** | `argocd-cm` `oidc.config` → Dex; an `XOIDCClient` named `argocd`, `requestedScopes` with `groups` | `argocd-rbac-cm`: `policy.default: ""` (no role on login), `scopes: "[groups]"`, `g, <org>:platform, role:admin`; `globalProjects` for sync windows and deny-lists shared by every project | Argo CD's install and its `argocd-rbac-cm` |
| **Grafana** | `grafana.ini` `[auth.generic_oauth]` → Dex; an `XOIDCClient` named `grafana`, the `groups` scope | `role_attribute_path`: the `platform` group → `Admin`, everyone else the lowest role — nothing beyond what a folder grants | `generic_oauth` in the `Grafana` resource's `spec.config` (operator-deployed) or Helm values (external) |
| **OpenBao** | JWT/OIDC auth backend + role, `groups_claim: groups`, an `XOIDCClient` named `openbao`; Kubernetes auth per cluster for machines, ESO's role first | KV v2 mounts `platform/` and `tenants/` (the [Vault path convention](../../CLAUDE.md#vault-path-convention)); one `ClusterSecretStore` per mount for ESO | `operator init`, unsealing, and the configuration credential `provider-vault` uses — the first credential of a store cannot come from the store |

OpenBao is configured **on the hub only**: spokes install no `provider-vault` and read secrets through ESO. Only the needed `provider-vault` kinds are used —
auth, mount, policy and identity — and the hand-made mounts, backends, groups and aliases are adopted by external name, observed first, then managed. The
validated examples are in [`providers/config/examples/openbao/`](../../providers/config/examples/openbao).

### The catalog

Every rendered object — and any native object made by hand that should show up — carries two labels:

| Label | Value | Example |
|---|---|---|
| `wxops.cloud/owner` | the owning team's slug, or `platform` | `payment` |
| `wxops.cloud/tool` | `argocd`, `grafana`, `openbao` | `argocd` |

The catalog lists them **straight from the Kubernetes API** (live state, each object's own status) and **from the GitOps repository** (desired state), joined
on kind, name and owner. Per team it shows what exists in each tool, whether it is in Git, in the cluster or both, its health, and which persona's groups
reach it. It writes nothing back; an object made by hand still appears — as one that is not in Git.

### Who writes what

| Writer | Writes |
|---|---|
| Platform team, at bootstrap | each tool's login and default access; `provider-vault`'s credential; Argo CD's global projects |
| Platform team, in GitOps | `XWorkspaceClass`es; each tenant's `XWorkspace` in `tenants/<name>/`, with its namespace and defaults |
| W'xOps Core | the rendered `AppProject`s, `GrafanaFolder`s and OpenBao objects; `XOIDCClient`s (built); personas and bindings (RFC-009) |
| Teams, in their own repositories | Argo CD `Application`s, dashboards and alert rules, inside what their project and folder allow |

### RBAC

- **provider-kubernetes** gains write on `appprojects` in Argo CD's namespace only, and on `grafanafolders` — named narrowly in
  `providers/rbac/provider-kubernetes.yaml`. These are tool grants, not Kubernetes RBAC: the rule that compositions never emit RBAC stands.
- **provider-vault** keeps its hub `ProviderConfig` and gains the namespaced `ClusterProviderConfig` its namespaced resources reference.
- **Nobody but the platform** writes `XWorkspaceClass` (cluster-scoped, platform group). `XWorkspace` is not in any persona role until tenants may write it.

### Compatibility and change tier

Two new packages — `workspace-class` (`XWorkspaceClass`, `platform.wxops.cloud`) and `workspace` (`XWorkspace`, `tenant.wxops.cloud`) — at `v1alpha1`:
additive, `safe`. Names, the new `tenant.wxops.cloud` group and each kind's scope follow [ADR-005](../adr/005-kind-ownership-scope-and-naming.md).
`provider-vault` stays on the reference stack as today.

### Testing

- **Golden renders** per tool and per persona mix: owners, developers and viewers teams; a team mapped by ADR-006; a team in a persona the class does not
  list (nothing); a tool not opted in (nothing); a namespace with no owner, or a missing class (nothing rendered, `syncMessage` says why).
- **Invariants:** every rendered object carries both catalog labels; no rendered object names a group that is not one of the owner's teams.
- **Not covered offline:** whether OpenBao accepts each `provider-vault` resource, Grafana open source's per-team permissions, and the cross-namespace
  `AppProject` write — the Phase 0 spikes.

## Drawbacks

- **It partly reverses "no W'xOps kind per tool".** Bounded — the claim has no tool fields and one kind serves every tool — but the class's schema grows
  with every tool and every role it can express.
- **One cross-namespace write** (`AppProject` into Argo CD's namespace), resting on a spike.
- **Grafana's per-team permissions may need Enterprise** or a workaround; until the spike settles it, folder permissions are by role.
- **`provider-vault` targets Vault.** OpenBao is a fork; each resource used is verified against it, not assumed.
- **Access converges, it does not switch** — a team or persona change reaches the tools at the workspace's next reconcile.
- **Some steps stay manual** — OpenBao init and unseal, the first admin credentials.

## Alternatives

- **The platform team writes the native objects by hand** (the 2026-10-24 draft). Nothing new to build, but every persona change is an edit in three tools,
  and nothing keeps the three consistent.
- **A GitOps team template** (a Kustomize component or Helm chart rendering the same objects from values). No new kind, but persona membership is written
  twice — once on the `XScmTeam`, once in the values — and nothing reconciles them.
- **A kind per tool** (`XGitOpsProject`, `XMonitoringFolder`, `XSecret*` — the first draft). Rejected again: each mirrors its tool's fields.
- **A cluster-scoped `XWorkspace`.** Avoids the cross-namespace write, but the claim no longer sits in the namespace it is for, and its owner must be typed
  instead of read from the namespace. Kept as the fallback for the Argo CD piece only.

## Rollout Plan

- [x] **Spike — OpenBao OIDC login through Dex with an external group alias.** Verified 2026-10-21: the `groups` claim binds to the external group's alias.
- [ ] **Now: document the default setup** per tool in `docs/user-guide/setup.md` — login, default access, the bootstrap steps that stay manual.
- [ ] **Phase 0 — decide and spike.** The `tenant.wxops.cloud` group is decided ([ADR-005](../adr/005-kind-ownership-scope-and-naming.md)). Spikes: each `provider-vault` namespaced resource against OpenBao;
  `GrafanaFolder` with `allowCrossNamespaceImport`; a namespaced provider-kubernetes `Object` writing an `AppProject` into Argo CD's namespace; Grafana
  open source per-team folder access.
- [ ] **Phase 1 — `XWorkspaceClass` and `XWorkspace` with OpenBao:** adopt the existing mounts and backends; render each tenant's policy, groups and aliases.
- [ ] **Phase 2 — Grafana:** `generic_oauth` defaults; the `GrafanaFolder` per workspace.
- [ ] **Phase 3 — Argo CD:** `argocd-rbac-cm` defaults; the `AppProject` per workspace, in Argo CD's namespace.
- [ ] **Phase 4 — the catalog:** the two labels on every object; the Portal lists them from the cluster and the GitOps repository.
- [ ] **Later** — tenant-writable workspaces; OpenBao audit devices; OpenBao namespaces per environment, if the multi-cluster feature needs them.

On acceptance, an ADR: built-in tools are configured on their own native objects, rendered per tenant by one workspace kind from a platform class — no
kind mirrors a tool.

## Open Questions

Settled 2026-10-24, still holding:

1. **OpenBao namespaces — settled:** one root namespace, with the `platform/` and `tenants/` mounts and per-team prefixes. One login, one alias per group,
   one ESO store per mount, and the Vault path convention unchanged. A namespace per environment or cluster is revisited with the multi-cluster feature.
2. **`provider-vault` — settled:** installed on the hub only; spokes read secrets through ESO.

Superseded 2026-11-08:

3. **Argo CD — was "its own `AppProject` roles and `argocd-rbac-cm`, one role per persona; no W'xOps layer over them".** The roles stay one per persona, but
   the `AppProject` is now rendered by `XWorkspace`; `argocd-rbac-cm` stays the platform's bootstrap.

Open:

4. **Grafana per-team access** in open source — folder permissions are the goal; how far the free edition goes (teams managed outside the operator, one org
   per team, or permissions by role only) is the Phase 0 spike.
5. **Vault as well as OpenBao?** `provider-vault` drives both. Is an adopter on HashiCorp Vault supported, or is OpenBao the only store this repository claims?
6. **Argo CD on another cluster** than its projects' targets — covered by the multi-cluster feature (Argo CD Agent), not here.
7. **One OpenBao group per team, many workspaces.** An external group's alias is unique per auth mount, so a team that counts in two workspaces (its own and
   a mapped one) needs one group with policies from both. Lean: the team's own workspace creates its group and alias; any other attaches policies through a
   non-exclusive group-policies resource — to verify in Phase 0.
8. **Tenant-writable workspaces** — when teams may write their own `XWorkspace`, bounded by the class, and which persona role grants it.
9. **How a class change rolls out** — every workspace on the class re-renders at its next reconcile; whether a class needs versions (`standard-v2`) so a
   change can be staged.
