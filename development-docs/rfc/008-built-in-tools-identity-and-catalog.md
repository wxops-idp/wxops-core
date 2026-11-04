# RFC-008: Built-in tools — one login, persona access and a catalog for Argo CD, Grafana and OpenBao, on their own native objects

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Draft — rewritten 2026-10-24: W'xOps no longer defines a kind per tool. Each tool is configured with its own objects; W'xOps adds identity, persona access
and a catalog. Replaces the "platform tools as APIs" draft (`XSecret*`, `XMonitoring*`, `XGitOpsProject`).

## Summary

The platform ships three built-in tools: **Argo CD** (GitOps), **Grafana** (monitoring) and **OpenBao** (secrets). Each already has a way to be configured
declaratively: Argo CD's `AppProject` and `argocd-rbac-cm`, Grafana's `grafana.ini` and the grafana-operator's resources, and OpenBao through Crossplane's
`provider-vault`. W'xOps does **not** wrap any of them in a kind of its own. Mirroring a tool's concepts doubles the API, lags upstream, and hides the
documentation people already know.

What W'xOps adds is what no single tool can:

| W'xOps adds | How | Where it is defined |
|---|---|---|
| **One login** | An `XOIDCClient` per tool, against the platform's Dex | [RFC-004](004-dex-identity-and-portal-authentication.md) — built |
| **Persona access** | Each tool's native grant names the SCM groups (`<org>:<team>`) of the persona that should reach it | [RFC-009](009-scm-personas.md) |
| **A catalog** | Native objects carry `wxops.cloud/owner` and `wxops.cloud/tool`; the catalog reads them from the cluster and from Git | this RFC |
| **A default setup** | Documented, tested bootstrap values per tool, so every installation starts the same way | this RFC, `docs/user-guide/setup.md` |

## Motivation

1. **Reproducing a tool's concepts is a second API to keep in step.** The first draft wrapped `AppProject` in an `XGitOpsProject` and Grafana folders in an
   `XMonitoringFolder`. Every new upstream field would need a new W'xOps field, and users would learn two shapes for one thing.
2. **The platform team owns each tool from bootstrap to provisioning anyway.** Grafana's `generic_oauth`, Argo CD's OIDC and RBAC config, OpenBao's init and
   auth backends are installation decisions, made once by the people who run the platform. A W'xOps kind in front of them adds a layer, not a capability.
3. **What is actually missing is identity, authorization and visibility.** One login exists (RFC-004). Who may do what is the persona (RFC-009). What does not
   exist yet is a single view of *what was created in each tool, who owns it and which persona reaches it* — whether it came from GitOps or straight from the
   cluster.
4. **OpenBao is the one tool without native objects.** It is configured only through its HTTP API. Crossplane's `provider-vault` already gives it managed
   resources. Its 200-odd CRDs are a cost paid once, on the hub only — spokes never configure OpenBao, they only read secrets through ESO.

## Detailed Design

### Scope

| In this RFC | Not in this RFC |
|---|---|
| Each tool's login, default roles and default grants, as a documented setup | A W'xOps kind per tool — none |
| How persona groups reach each tool's native grant | Who is in which persona — [RFC-009](009-scm-personas.md) |
| The catalog: labels and what it reads | The Portal's UI — [portal integration](../../docs/user-guide/portal-integration.md) |
| OpenBao through `provider-vault`, on the hub | Secret **values** — External Secrets Operator's alone, as today |

### Principles

| Rule | Why |
|---|---|
| **Native first.** A tool is configured with its own objects; W'xOps adds no kind that mirrors one | Upstream documentation stays the documentation; no W'xOps field lags an upstream one |
| **One login.** Every tool logs in through Dex with an `XOIDCClient`; the `groups` claim is `<org>:<team>` | One identity, the same strings in every tool |
| **Personas decide who.** A native grant lists the SCM groups of the persona that reaches it, never a person | Leaving a Git team removes the access in every tool at the next login |
| **No access by default.** A new login sees nothing until a persona's groups are granted | The safe failure for a missing grant is "cannot see", not "can see everything" |
| **Capture, don't wrap.** Native objects carry two labels; the catalog reads them | Nothing to keep in sync, and objects created outside GitOps still show up |
| **The platform team owns each tool's bootstrap.** Login, default roles and admin credentials are installation values in GitOps | One owner for the decisions that shape every tenant's access |

### Argo CD

| Concern | Native object | Default setup |
|---|---|---|
| Login | `argocd-cm` `oidc.config` → Dex | an `XOIDCClient` named `argocd`; `requestedScopes` include `groups` |
| Default access | `argocd-rbac-cm` | `policy.default: ""` — no role on login; `scopes: "[groups]"`; `g, <org>:platform, role:admin` for the `platform` persona |
| A team's deployments | one `AppProject` per team | `sourceRepos` limited to the team's repositories; `destinations` to its namespaces; **no cluster-resource allow-list** — a team that could deploy RBAC through Argo CD would step around every Kubernetes rule; never the `argocd` namespace |
| Who may act on them | the project's `spec.roles[]` | one role per persona — `owners`, `developers`, `viewers` — each with project-scoped `policies` (`proj:<team>:<role>`) and `groups: [<org>:<team>]` on the role matching the team's persona |
| Shared defaults | `argocd-cm` `globalProjects` | sync windows and resource deny-lists inherited by label selector, so team projects stay short |

Persona access in Argo CD is the role a team's group sits in. A project role's `groups` is a static list — Argo CD has no selector for it — so a team that
changes persona has its group moved to another role in its `AppProject`: a one-line change in GitOps, reviewed like any other.

Argo CD stays out of Kyverno ([RFC-009](009-scm-personas.md#xplatformpolicy--on-which-objects)): what it deploys is bounded by its projects and by review on
merge.

### Grafana

| Concern | Native object | Default setup |
|---|---|---|
| Login | `grafana.ini` `[auth.generic_oauth]` → Dex | an `XOIDCClient` named `grafana`; the `groups` scope requested |
| Org role | `role_attribute_path` | the `platform` group maps to `Admin`; everyone else to the lowest role, so nothing beyond what a folder grants |
| Folders and their permissions | grafana-operator `GrafanaFolder` (`spec.permissions`) | one folder per team, permissions by role |
| Dashboards, data sources, alerting | grafana-operator `GrafanaDashboard`, `GrafanaDatasource`, `GrafanaAlertRuleGroup`, … | as the team or platform writes them |

- **The login is bootstrap, not grafana-operator.** For an operator-deployed Grafana, `[auth.generic_oauth]` can go into the `Grafana` resource's `spec.config`;
  for an external Grafana the operator cannot write `grafana.ini`, so it stays in the Helm values. Either way it is set once by the platform team.
- **Per-team permissions are the open part.** grafana-operator has no team kind, and `GrafanaFolder.spec.permissions` is raw JSON the Grafana API interprets.
  Filling Grafana teams from the `groups` claim (Team Sync) is listed as an Enterprise feature. Whether open source Grafana can give `wxops-idp:payment` edit on
  the `payment` folder and nothing else — by teams managed some other way, or by one org per team — is a spike before the Grafana phase.

### OpenBao

OpenBao has no Kubernetes objects of its own, so it is configured through **`provider-vault`'s managed resources**, written directly in GitOps by the platform
team — not composed by a W'xOps package.

| Concern | Managed resource (`provider-vault`) | Default setup |
|---|---|---|
| Human login | JWT/OIDC auth backend + role | `groups_claim: groups`, through an `XOIDCClient` named `openbao` |
| Machine login | Kubernetes auth backend per cluster + roles | `auth/kubernetes-<cluster>`, created when a cluster joins; token reviews reach the spoke's API by mesh name over mTLS ([multi-cluster](../core-ideas/multi-cluster.md#secrets-across-clusters--eso-to-openbao-over-the-mesh)); one role per consumer ServiceAccount, ESO's first. JWT/OIDC is for people only |
| Stores | KV v2 mounts | `platform/` and `tenants/` — the [Vault path convention](../../CLAUDE.md#vault-path-convention) |
| Persona access | ACL policy + identity group (`external`) + group alias | alias name = the SCM group string; verified by hand on 2026-10-21 |
| ESO's way in | `ClusterSecretStore`, one per mount | written beside the mount, as today |

- **On the hub only.** OpenBao's configuration is written once, where the platform runs. Spokes install no `provider-vault`; workloads there read secrets
  through ESO, which needs only a `ClusterSecretStore`.
- **Only the needed kinds are used** — auth, mount, policy and identity resources, a handful of the provider's 200-odd. Installing fewer is an optimisation, not
  a prerequisite: Crossplane v2 can keep unused managed resources inactive (managed resource definitions with an activation policy) where a provider supports
  it.
- **Configuration, never values.** No KV-writing managed resource is used; values stay ESO's.
- **Examples** that validate against the installed v4.1.0 CRDs: [`providers/config/examples/openbao/`](../../providers/config/examples/openbao) — mounts and a policy, OIDC login with an external group and its
  alias, and Kubernetes auth per cluster. The provider installs all 129 of its CRDs without trouble; keeping unused ones inactive stays an optimisation.
- **Adopting what exists.** The mounts, auth backends, groups and aliases made by hand are imported by external name, observed first, then managed.
- **Out of band, documented as such:** `operator init`, unsealing, and the configuration credential the provider uses. The first credential of a secret store
  cannot come from the store.

### The catalog

Every native object a tool's grant lives in carries two labels:

| Label | Value | Example |
|---|---|---|
| `wxops.cloud/owner` | the owning team's slug, or `platform` | `payment` |
| `wxops.cloud/tool` | `argocd`, `grafana`, `openbao` | `argocd` |

The catalog lists them **straight from the Kubernetes API** (live state, each object's own status) and **from the GitOps repository** (desired state), joined
on kind, name and owner. It shows, per team: what exists in each tool, whether it is in Git, in the cluster or both, its health from the object's own status,
and which persona's groups reach it. It writes nothing back: nothing to keep in sync, and an object created by hand still appears — as one that is not in Git.

### Who writes what

| Writer | Writes |
|---|---|
| Platform team, at bootstrap | each tool's login and default access; `provider-vault`'s credential; Argo CD's global projects |
| Platform team, in GitOps | team `AppProject`s, `GrafanaFolder`s, OpenBao policies and groups — naming persona groups |
| Teams, in their own repositories | dashboards, alert rules and Argo CD `Application`s, inside what their project and folder allow |
| W'xOps Core | `XOIDCClient`s (built), personas (RFC-009) |

### Compatibility and change tier

No Core package and no XRD. One new Crossplane provider, `provider-vault`, installed on the hub from `providers/` — added to the reference stack, with its licence checked when pinned, as [RFC-002](002-migrate-terraform-to-opentofu.md) requires. The `appprojects` grant the first draft
needed for `provider-kubernetes` is no longer needed.

### Testing

- **The default setup is tested as manifests:** the example `AppProject`, `argocd-rbac-cm`, `GrafanaFolder` and `provider-vault` resources are linted and
  schema-checked like the rest of `examples/`.
- **Not covered offline:** whether OpenBao accepts each `provider-vault` resource (it targets Vault's API), and Grafana open source's per-team permissions —
  spikes.

## Drawbacks

- **A persona change is a hand edit in Argo CD.** Project roles take a static `groups` list, so moving a team between personas moves its group in its
  `AppProject`. Reviewed, but not generated.
- **Grafana's per-team permissions may need Enterprise** or a workaround; until the spike settles it, folder permissions are by role.
- **`provider-vault` targets Vault.** OpenBao is a fork; each resource used is verified against it, not assumed.
- **One more provider to upgrade**, with 200-odd CRDs on the hub of which a handful are used.
- **The catalog sees only labelled objects.** An unlabelled grant made by hand in a tool's UI is invisible to it.
- **Some steps remain manual** — OpenBao init and unseal, the first admin credentials — so "all of it is GitOps" would be false.

## Alternatives

- **A W'xOps kind per tool** — `XSecret*`, `XMonitoring*`, `XGitOpsProject` (this RFC's first draft). Uniform status and one pattern, but a second API for
  concepts every tool already has.
- **OpenBao through OpenTofu Workspaces** (the first draft's engine). The same Terraform provider without new CRDs, but every grant is a module behind a W'xOps
  kind, and status is per Workspace, not per object.
- **`redhat-cop/vault-config-operator`.** About a hundred CRDs and per-namespace credentials, but another controller, it also writes secret values, and OpenBao
  is not named.
- **Grafana's Terraform provider** instead of grafana-operator. Covers teams, but brings back the Workspace layer for a tool that has Kubernetes resources.
- **Role mapping in the identity provider** (Keycloak, Zitadel). Moves the mapping into a database instead of Git, and replaces Dex.

## Rollout Plan

- [x] **Spike — OpenBao OIDC login through Dex with an external group alias.** Verified 2026-10-21: the `groups` claim binds to the external group's alias.
- [ ] **Now: document the default setup** per tool in `docs/user-guide/setup.md` — login, default access, the bootstrap steps that stay manual.
- [ ] **Spikes.** `provider-vault`: each needed resource against OpenBao, and whether unused resources can stay inactive. Grafana's per-team folder access
  is tried when the Grafana phase starts.
- [ ] **Phase 1 — OpenBao** on `provider-vault`: adopt the existing mounts, auth backends, groups and aliases; replace the hand-made setup.
- [ ] **Phase 2 — Argo CD:** `argocd-rbac-cm` defaults; the team `AppProject` template with persona roles.
- [ ] **Phase 3 — Grafana:** `generic_oauth` defaults; grafana-operator folders per team.
- [ ] **Phase 4 — the catalog:** the two labels on every object above; the Portal lists them from the cluster and the GitOps repository.
- [ ] **Later** — OpenBao audit devices; OpenBao namespaces per environment, if the multi-cluster feature needs them.

On acceptance, an ADR: built-in tools are configured on their own native objects (and `provider-vault` for OpenBao), with no W'xOps kind per tool; W'xOps
provides login, persona access and the catalog.

## Open Questions

Settled 2026-10-24:

1. **OpenBao namespaces — settled:** one root namespace, with the `platform/` and `tenants/` mounts and per-team prefixes. One login, one alias per group,
   one ESO store per mount, and the Vault path convention unchanged. A namespace per environment or cluster is revisited with the multi-cluster feature, not
   per team.
2. **`provider-vault` — settled:** installed on the hub only; spokes read secrets through ESO. Keeping unused resources inactive is an optimisation to learn,
   not a blocker.
3. **Argo CD — settled:** its own `AppProject` roles and `argocd-rbac-cm`, one role per persona; no W'xOps layer over them.

Still open:

4. **Grafana per-team access** in open source — folder permissions are the goal; how far the free edition goes (teams managed outside the operator, one org
   per team, or permissions by role only) is tried when the Grafana phase starts.
5. **Vault as well as OpenBao?** `provider-vault` drives both. Is an adopter on HashiCorp Vault supported, or is OpenBao the only store this repository claims?
6. **Argo CD on another cluster** than its projects' targets — covered by the multi-cluster feature (Argo CD Agent), not here.
