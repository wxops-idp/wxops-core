# RFC-008: Platform tools as APIs — secrets, monitoring and GitOps configured through one pattern

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Draft

## Summary

W'xOps depends on configuration inside the platform's own tools that **nothing in this repository converges on**: OpenBao's mounts, policies and auth roles;
Grafana's folders, teams and permissions; Argo CD's projects and roles. Today they are a `bao` session, a Helm `postStart` hook, or a click in a UI.

This RFC makes that configuration part of the platform API, with **one pattern for every tool**: per concept, a connection kind and one or two resource kinds,
a `vendor` field choosing the module, and the engine that fits the tool — an OpenTofu `Workspace` for tools reachable only through their own API, a
`provider-kubernetes` `Object` for tools already configured by Kubernetes resources. It is delivered concept by concept: **secrets first** (the design this RFC
originally held, extended for human access), then monitoring, then GitOps.

These kinds are also where the [access model](../core-ideas/access-model.md) lands: its persona compiler renders them, so a team's access to every tool is a
set of reviewed XRs rather than hand-made grants in four syntaxes.

## Motivation

1. **The contract is implicit, so it breaks late and quietly.** `XScmConnection` names a store called `vault-platform`; the
   [Vault path convention](../../CLAUDE.md#vault-path-convention) assumes `platform/` and `tenants/` mounts; [RFC-004](004-dex-identity-and-portal-authentication.md)
   and [RFC-006](006-cloudflare-r2-object-storage-and-backup.md) add paths under both. If the store is missing, scoped to the wrong mount, or its policy omits a
   path, nothing fails at admission: it fails as a 403 inside a provider pod, and the XR never becomes ready.
2. **Access is hand-written in every tool, in every tool's own syntax.** OpenBao policy HCL, Grafana folder permissions, Argo CD's `policy.csv`. None of it is
   reviewed as a diff, and each drifts on its own.
3. **The access model needs somewhere to land.** A persona means "this team reads `tenants/payment/*`, views the `payment` folder, syncs the `payment` project".
   Without kinds for those, the compiler has no target and each grant stays manual.
4. **A `postStart` hook is not GitOps.** It runs once, corrects no drift, and leaves nothing in a diff. Two clusters configured by hand are two different
   clusters.
5. **One mechanism per tool would multiply what a contributor must learn.** The SCM family already proved a shape — connection, resources, `vendor`, one
   Workspace per scope. Reusing it means a contributor who understands `XScmTeam` understands `XSecretAccess` at a glance.

## Detailed Design

### Scope

| In this RFC | Not in this RFC |
|---|---|
| The platform-tool pattern: connection + resource kinds, `vendor`, engine per tool | Who gets which grant — personas and the compiler are the personas RFC's |
| Secrets: `XSecretConnection`, `XSecretStore`, `XSecretAccess` | Secret **values** — ESO's alone, as today |
| Monitoring: `XMonitoringConnection`, `XMonitoringFolder` | Dashboards, alert rules, datasources |
| GitOps: `XGitOpsProject` | `Application`s — the GitOps repository's |
| Mirroring tool facts into XR status, for policy lookups | Kyverno policies — [RFC-005](005-git-mapped-authorization.md)'s |
| | Tool installation, and each tool's static login configuration (its OIDC client, default role) — Helm values in GitOps |

### The pattern

| Rule | Why |
|---|---|
| **Kinds are named by concept, not product** — `XSecretAccess`, not `XOpenBaoPolicy` | A second vendor is a new module, not a new API |
| **A `vendor` field selects the module**, exactly as `scm-*` do ([ADR-004](../adr/004-scm-repository-vendor-field.md)) | One kind, vendor-exclusive inline modules, no provider loaded that the vendor does not need |
| **Per concept: one connection kind, one or two resource kinds** | The connection owns the tool's address, admin credential and tool-wide settings; resources reference it, like `scmRef` |
| **A kind exists only when a W'xOps workflow needs it** — tenant onboarding, persona projection, an agent's read access | Never to mirror a tool's API. A concept growing past the cap needs its own RFC |
| **The engine follows the tool** | See below |
| **One Workspace per scope** | Removing a resource from a module destroys it on the next apply; a shared module would let one mistake take a whole tool's configuration with it |
| **Configuration, never values** | ESO already does Kubernetes → store; two writers of the same records is worse than one |
| **Tool facts are mirrored into status** by read-only data sources, as `XScmConnection`'s `inspect` Workspace does | Policies look facts up in-cluster instead of calling a third party at admission |
| **Every kind keeps the status contract** — `created`, `ready`, `synced`, `syncMessage`, through the shared `status` step | The Portal and agents read one shape for every package |

#### The engine follows the tool

| The tool is configured through | Engine | Examples |
|---|---|---|
| Its own HTTP API only | OpenTofu `Workspace` running the tool's Terraform provider | OpenBao (`hashicorp/vault`), Grafana (`grafana/grafana`) |
| Kubernetes resources it already defines | `provider-kubernetes` `Object` | Argo CD (`AppProject`) |

A Workspace in front of a tool that already speaks Kubernetes would add state and a plan step for nothing, and hide the object from admission. The XR the user
writes looks the same either way.

#### Relation to RFC-006's third-party pattern

[RFC-006](006-cloudflare-r2-object-storage-and-backup.md#the-third-party-pattern) sets six rules for external *services* that cost money. Platform *tools* are
self-hosted, so they share three — provisioning through the Workspace engine, ownership by the `wxops.cloud/owner` label, deletion that never destroys data by
default — and differ on the rest: the admin credential is per tool instance rather than per account, access grants mint no credential of their own, and cost
is not an attribute.

#### Ordering follows the credentials

Every tool's admin credential — the OpenBao configuration token, a Grafana service-account token — lives in the secret store and reaches its Workspace through
ESO, the way `XScmConnection` reads its SCM token. So secrets come first, and every later concept depends on them. Argo CD needs none: it is in-cluster, and
`provider-kubernetes` already reaches it.

### Concept 1 — Secrets (`vendor: openbao`)

#### What the user gets

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XSecretConnection            # one per OpenBao instance: address, configuration token, instance-wide auth backends
metadata:
  name: openbao
spec:
  parameters:
    vendor: openbao
    address: https://openbao.platform.svc:8200
    tokenSecretRef: {name: openbao-config-token, namespace: crossplane-system}
    kubernetesAuth: {path: kubernetes}           # enabled and configured here, once
    oidcAuth:                                    # human login through Dex
      path: oidc
      clientRef: {name: openbao}                 # an XOIDCClient — issuer, client id and secret come from it
      groupsClaim: groups
status:
  ready: true
  kubernetesAuthAccessor: auth_kubernetes_1a2b
  oidcAuthAccessor: auth_oidc_3c4d
---
apiVersion: platform.wxops.cloud/v1alpha1
kind: XSecretStore                 # a KV mount, the ESO store scoped to it, and ESO's way in
metadata:
  name: platform
spec:
  parameters:
    connectionRef: {name: openbao}
    mountPath: platform                 # KV v2. The ESO store is scoped here, which is why every
    storeName: vault-platform           # remoteKey in this repo is mount-relative.
    esoServiceAccount: {name: external-secrets, namespace: external-secrets}
    retain: true                        # default: deleting the XR never deletes a mount and its data
status:
  ready: true
  storeName: vault-platform             # what XScmConnection.secretStoreRef points at
  mountPath: platform
---
apiVersion: platform.wxops.cloud/v1alpha1
kind: XSecretAccess                # one consumer set, one slice of one mount
metadata:
  name: payment-read-tenants
  labels:
    wxops.cloud/owner: payment
spec:
  parameters:
    storeRef: {name: tenants}
    pathPrefix: payment/                # relative to the mount
    capabilities: read                  # read | read-write
    serviceAccounts:                    # machines, through Kubernetes auth
      - {name: "*", namespace: payment-api}
    groups:                             # people and agents, through OIDC — the Dex group string, exactly
      - wxops-idp:payment
status:
  ready: true
  policyName: wxops-payment-read-tenants
  roleName: wxops-payment-read-tenants
```

`XSecretAccess` never retains: deleting it revokes the access, which is what makes a time-bound grant end (see [Temporary access](#temporary-access)).

#### Which OpenBao APIs this drives

| Kind | Terraform resource | OpenBao API |
|---|---|---|
| `XSecretConnection` | `vault_auth_backend` (`kubernetes`), `vault_kubernetes_auth_backend_config` | `POST /v1/sys/auth/<path>`, `POST /v1/auth/<path>/config` |
| `XSecretConnection` | `vault_jwt_auth_backend` (`type = "oidc"`), `vault_jwt_auth_backend_role` | `POST /v1/sys/auth/<path>`, `POST /v1/auth/<path>/config`, `…/role/<name>` |
| `XSecretStore` | `vault_mount`, `vault_policy`, `vault_kubernetes_auth_backend_role` | `PUT /v1/sys/mounts/<path>`, `PUT /v1/sys/policies/acl/<name>`, `PUT /v1/auth/<path>/role/<name>` |
| `XSecretAccess` | `vault_policy`, `vault_kubernetes_auth_backend_role` | as above |
| `XSecretAccess` (`groups`) | `vault_identity_group` (`type = "external"`), `vault_identity_group_alias` | `POST /v1/identity/group`, `POST /v1/identity/group-alias` — alias `name` = the Dex group, `mount_accessor` = the OIDC backend's |

**The instance-wide auth backends live on the connection.** An earlier draft left enabling `auth/kubernetes` to bootstrap, because two `XSecretStore`s both
trying to enable it would fight over one object. Owning it on the one connection per instance removes the fight: stores and accesses only create *roles* and
*groups* under backends the connection enabled, and read their accessors from its status.

#### Human access, end to end

A person logs in to OpenBao with OIDC through Dex; the OIDC role reads `groups` from the token. OpenBao matches each group string against the aliases of its
external groups, and the person receives the policies attached to every group that matched. `XSecretAccess.groups: [wxops-idp:payment]` is therefore the whole
grant — the group, its alias and the policy are one Workspace — and leaving the Git team removes the access at the next login, with nothing to revoke by hand.

#### The token this needs, and what stays out of band

The connection's Workspace authenticates with a token from a Secret, in the same tfvars shape the SCM connection uses. **Not a root token.** A periodic token
whose policy allows only:

```hcl
path "sys/auth/*"              { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/mounts/*"            { capabilities = ["create", "read", "update", "delete"] }
path "sys/policies/acl/*"      { capabilities = ["create", "read", "update", "delete"] }
path "auth/+/config"           { capabilities = ["create", "read", "update"] }
path "auth/+/role/*"           { capabilities = ["create", "read", "update", "delete"] }
path "identity/group*"         { capabilities = ["create", "read", "update", "delete"] }
```

It can reconfigure the store but **cannot read a single KV value**. Out of band, and documented as such: `operator init`, the unseal keys, and creating this
token. The first credential of a secret store cannot come from the store. There is no cycle: the Workspaces use the bootstrap token, while ESO uses the role
they create.

#### Adopting what already exists

The platform already has mounts and a `vault-platform` store, and a fresh `vault_mount` would fail with "path is already in use". These objects are few and
platform-level, so a **static `import` block** in the module is enough — written once in Phase 1 for the known mounts and auth backends, not a per-resource
feature.

### Concept 2 — Monitoring (`vendor: grafana`)

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XMonitoringConnection
metadata:
  name: grafana
spec:
  parameters:
    vendor: grafana
    url: https://grafana.platform.example
    tokenSecretRef: {name: grafana-admin-token, namespace: crossplane-system}   # a Grafana service-account token, synced from OpenBao by ESO
    orgId: 1
status:
  ready: true
  version: "12.2.0"                   # mirrored, for policies and agents
---
apiVersion: platform.wxops.cloud/v1alpha1
kind: XMonitoringFolder              # a folder, the team that owns it, and who may do what in it
metadata:
  name: payment
  labels:
    wxops.cloud/owner: payment
spec:
  parameters:
    connectionRef: {name: grafana}
    title: Payment
    access:
      - {group: wxops-idp:payment, permission: Edit}     # View | Edit | Admin
      - {group: wxops-idp:platform, permission: Admin}
status:
  ready: true
  folderUid: payment
```

The Workspace drives `grafana_folder`, one `grafana_team` per listed group, and `grafana_folder_permission` granting each team its level. Grafana's static OAuth configuration — the Dex client and
`role_attribute_path`, which maps groups to an org-wide role — is Grafana's Helm values, not this kind.

**The open part is team membership.** Grafana's Team Sync, which fills a team from the login's groups, is listed as Enterprise for at least some login
providers. Without it, Core must manage members itself — from the `XScmTeam`'s `members`, which only works if the Grafana login is the Git username. That is
a spike before this phase, not an assumption.

### Concept 3 — GitOps (`vendor: argocd`)

```yaml
apiVersion: platform.wxops.cloud/v1alpha1
kind: XGitOpsProject                 # an Argo CD AppProject: where a team may deploy, from where, and who may act on it
metadata:
  name: payment
  labels:
    wxops.cloud/owner: payment
spec:
  parameters:
    vendor: argocd
    sourceRepos: ["https://github.com/wxops-idp/payment-*"]
    destinations:
      - {cluster: staging-*, namespace: payment-*}
    roles:
      - {name: sync,     groups: [wxops-idp:payment],            actions: [get, sync]}
      - {name: readonly, groups: [wxops-idp:agent-debugger],     actions: [get]}
status:
  ready: true
  projectName: payment
```

The composition emits one `Object` wrapping the `AppProject`; no connection kind, because Argo CD is in-cluster. `provider-kubernetes` needs `appprojects` in
`argoproj.io` added to `providers/rbac-provider-kubernetes.yaml` — the one provider RBAC change in this RFC. A tenant project never gets a cluster-wide
resource whitelist: a team that could deploy RBAC through Argo CD would step around every Kubernetes rule. Argo CD's own `argocd-cm` and `argocd-rbac-cm` —
the Dex client, `policy.default`, `policy.matchMode` — stay in its Helm values.

### How the access model uses these kinds

| Writer | Writes | Example |
|---|---|---|
| The persona compiler (personas RFC), in a reviewed pull request | `XSecretAccess` with `groups`, `XMonitoringFolder`, `XGitOpsProject` per team | team `payment` with persona `developer` |
| Kyverno, a **derived** grant from a validated label | `XSecretAccess` with `serviceAccounts` only, scoped to the namespace's own prefix | every namespace with an owner reads `tenants/<owner>/<namespace>/` |
| Platform engineers | connections, stores | `XSecretConnection`, `XSecretStore`, `XMonitoringConnection` |

Tenants never write these kinds. RFC-005's policies make that enforceable: platform-only kinds, owner checks on the rest, and Kyverno's own generated
`XSecretAccess` validated like any other write.

#### Temporary access

A time-bound grant is an `XSecretAccess` (or folder, or project) carrying a `wxops.cloud/expires-at` annotation. A Kyverno `DeletingPolicy` deletes it once
`time.now()` passes it, and the Workspace revokes the grant in the tool. Nothing in these kinds knows about time; expiry is the policy's job, and revocation
is what deleting any of these XRs already does — which is why access kinds never retain. See the
[access model](../core-ideas/access-model.md#temporary-access-generated-checked-terminated).

### Composition shape

Every kind follows the SCM packages: `function-patch-and-transform`, inline HCL or one `Object`, `vars[]` from the XR, outputs into status, the shared
`status` step last. `XSecretStore` additionally emits an `Object` wrapping the ESO `ClusterSecretStore` scoped to its mount; `provider-kubernetes` is already
granted `clustersecretstores`. Ordering is self-healing rather than gated: ESO retries a store whose role does not exist yet, so the visible effect is a failing
`ClusterSecretStore` for a few seconds — worth knowing when reading events, not worth a dependency mechanism.

### Compatibility and change tier

New packages, `group: platform` ([ADR-002](../adr/002-three-api-groups.md)), under `package/platform/<name>/`, `current: unreleased` — `safe`, since adding a
package is additive: `secret-connection`, `secret-store`, `secret-access`, `monitoring-connection`, `monitoring-folder`, `gitops-project`. No new Crossplane
provider. One provider RBAC addition (`appprojects`), in the GitOps phase. Each Terraform provider's licence is checked when it is pinned, as
[RFC-002](002-migrate-terraform-to-opentofu.md) requires of the runtime stack.

### Testing

- Goldens per kind: a platform store; a read access by ServiceAccount; a read-write access by group; an access naming both; a folder with two groups; a project
  with two roles.
- `_invalid/` cases: unknown `capabilities`, an absolute `pathPrefix` (it is mount-relative), a missing `storeRef`/`connectionRef`, an unknown `vendor`, a
  folder `permission` outside the enum.
- **Invariants:** no value-writing resource in any module (`vault_kv_secret`, `vault_kv_secret_v2`, `vault_generic_secret`); no policy text in status;
  `remoteKey`-shaped paths stay mount-relative; access kinds never set `retain`; each module declares only its vendor's provider.
- `tofu validate` on each extracted module, against the pinned provider.
- Offline tests prove the rendered Workspace or `Object` only. Whether OpenBao, Grafana and Argo CD accept it — and the Vault-versus-OpenBao parity — needs a
  cluster.

## Drawbacks

- **Coarser status than a native provider**, and one bad resource fails its Workspace. Mitigated by one Workspace per scope; not eliminated.
- **A state Secret per Workspace**, holding policy text. It must survive, and it is one more object under RBAC review.
- **OpenBao is a fork of Vault.** The provider targets Vault's API; `vault_mount` (the KV v2 form), `vault_policy`, the auth backends and the identity resources
  are verified against OpenBao, not assumed.
- **Grafana open source may not map groups to teams.** Phase 4 may have to manage team members from `XScmTeam`, which ties the Grafana login to the Git username.
- **The pattern invites scope creep.** Every tool has hundreds of API objects. The inclusion rule and the per-concept cap are the mitigation, and they are
  promises to keep, not mechanisms.
- **Some steps remain manual** — OpenBao init, unseal, the configuration token, and the first Grafana admin token — so "all of it is GitOps" would be false.
- **Drift is corrected in batches**, on the provider's re-plan interval, not per object.
- **Policy layout becomes public** to anyone who can read the repository. That is the trade for reviewability; path *contents* stay out of the repository.

## Alternatives

- **`upbound/provider-vault`.** The same Terraform provider, generated by upjet, with per-object status — at **259 CRDs** for a handful of mounts and
  policies. Revisit if per-tenant policies grow into the hundreds.
- **`redhat-cop/vault-config-operator`.** About a hundred CRDs, per-object status and a good idea — each resource authenticates to Vault as a ServiceAccount
  of its own namespace, so the operator holds no Vault permission. But it is another controller in a control plane that has chosen Crossplane as its only one,
  it also writes secret values (overlapping ESO), and OpenBao is not mentioned. Its per-namespace credential idea is an open question below.
- **`grafana-operator`.** Grafana configuration as CRDs, so every folder and permission is Kubernetes-visible. Another operator for one tool; revisit if
  dashboards-as-CRDs become a requirement of their own.
- **`crossplane-contrib/provider-http`, or jobs calling each tool's CLI.** The same as a Workspace on day 1. From day 2 a script has to check before creating,
  diff, delete what was removed and correct drift — a worse Terraform. Untyped bodies, errors as HTTP codes.
- **Crossplane Operations** (`Operation`, `WatchOperation`, `CronOperation`). Alpha, behind a flag, and unable to delete what they created — and revocation is
  the path that matters most for access. Useful later for read-only checks beside these kinds, never as their owner.
- **Kyverno calling tool APIs.** An admission check must be free of side effects; Kyverno decides and Crossplane writes
  ([access model](../core-ideas/access-model.md#temporary-access-generated-checked-terminated)).
- **Role mapping in the identity provider** (Keycloak, Zitadel). Moves the mapping into a database instead of Git, and replaces Dex.
- **Do nothing but document the commands.** Honest, and still the right first step — see the plan.

## Rollout Plan

- [ ] **Now: document the bootstrap.** The `bao` commands for init, unseal, the auth backends, the mounts, the ESO store and the configuration token, in
  `docs/user-guide/setup.md`, labelled plainly as the part of the platform that is not GitOps yet.
- [ ] **Spikes.** The KV v2 resource form against OpenBao; OIDC login through Dex with an external group alias matching `org:team`; whether the Vault provider
  can log in through Kubernetes auth instead of a token; `provider-opentofu`'s re-plan interval; Grafana open source group-to-team mapping.
- [ ] **Phase 1 — `XSecretConnection` and `XSecretStore`** for the platform mount, with the static `import` for what exists, replacing the hand-made store.
- [ ] **Phase 2 — `XSecretAccess`**, ServiceAccounts first, then `groups`; point `XScmConnection.secretStoreRef` and RFC-004's records at the published outputs.
- [ ] **Phase 3 — the tenant mount**, per-tenant access in onboarding, and the persona compiler's first target (personas RFC).
- [ ] **Phase 4 — Monitoring:** `XMonitoringConnection`, `XMonitoringFolder`.
- [ ] **Phase 5 — GitOps:** `XGitOpsProject`, and the `appprojects` grant for `provider-kubernetes`.
- [ ] **Later** — OpenBao audit devices, transit auto-unseal for a second cluster.

On acceptance, ADRs for: platform-tool configuration is a platform API on the Workspace and `Object` engines, with values remaining ESO's alone; and kinds
named by concept with a `vendor` field, as the SCM family does.

## Open Questions

1. **Token or Kubernetes auth** for the connection's Workspace (spike). It decides whether a long-lived credential exists at all, and who rotates it.
2. **A narrower credential per tenant?** One configuration token can configure everything. For the tenant mount, each tenant's `XSecretAccess` could log in
   with a credential scoped to its own prefix — the idea `vault-config-operator` is built on — so one tenant's module cannot touch another's paths.
3. **One mount with prefixes, or a mount per environment?** RFC-006 chose one Cloudflare account per environment; the symmetric answer here would change every
   `remoteKey` in the repository.
4. **Vault as well as OpenBao?** The same provider drives both. Is an adopter running HashiCorp Vault supported, or is OpenBao the only store this repository
   claims?
5. **`vendor` or `provider`?** RFC-006's `XObjectBucket` names the same idea `provider`. One word across the platform; `vendor` is what shipped in `scm-*`.
6. **Grafana team membership** — Team Sync, or Core-managed members from `XScmTeam` (spike).
7. **Argo CD on a different cluster than Core.** No connection kind is needed while Argo CD runs beside Core; a remote Argo CD would need one, or a
   `ProviderConfig` per cluster.
