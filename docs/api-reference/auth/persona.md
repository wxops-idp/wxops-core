# XPersona

A persona is a title that collects who it applies to: **SCM teams, hand-listed groups and users, and in-cluster agents**, plus the environments it applies on.
It grants nothing. It resolves its members into `status.subjects` — RBAC subjects, ready to copy — which [`XPersonaBinding`](persona-binding.md) turns into
`RoleBinding`s and [`XPolicy`](policy.md) into Kyverno policies. Design: [RFC-009](../../../development-docs/rfc/009-scm-personas.md).

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XPersona` |
| **Plural** | `xpersonas` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/persona/`](../../../package/auth/persona) — see [`VERSIONS.yaml`](../../../VERSIONS.yaml) for the current package version |

## How a team joins a persona

Label its [`XScmTeam`](../scm/team.md) — one label per persona, so a team may be in several. Only the platform should be able to set it.

```yaml
labels:
  scm.wxops.cloud/oidc-login: "true"
  auth.wxops.cloud/persona-<persona name>: "true"
```

The team must also be able to sign in (`scm.wxops.cloud/oidc-login`), and must have published `status.oidcGroup` — a team whose `XScmTeam` has not been applied
yet is skipped, not an error. The label's key holds the persona's name, so a persona's name is at most 55 characters.

Team names reach RBAC exactly as the claim carries them, with no case folding: use slug-form team names (`a-z0-9-`) on every vendor
([RFC-005](../../../development-docs/rfc/005-git-mapped-authorization.md#open-questions), question 11).

### A second team on one owner

A team owns its own slug — group `<org>:payment` owns `payment`. A team that should also own another team's objects carries that owner as a label on its
`XScmTeam` ([ADR-006](../../../development-docs/adr/006-team-owner-mapping.md)):

```yaml
metadata:
  name: payment-maintainers
  labels:
    scm.wxops.cloud/oidc-login: "true"
    auth.wxops.cloud/persona-owners: "true"
    wxops.cloud/owner: payment            # also owns what payment owns
```

The persona publishes the mapping as `status.owners`; [`XPersonaBinding`](persona-binding.md) (`scope: owned`) and every
[`XPolicy`](policy.md) read the same label. One label, one extra owner. Only the platform team writes `XScmTeam`s, so only it can map a team.

**Why it helps with many teams.** Owners stay plain team slugs, and team names never have to collide or be renamed to share a namespace: `payment` and
`payment-maintainers` keep their own groups, members and SCM permissions, and the label says the second one also stands for the first. The mapping is in
one place — the team's own manifest, reviewed — and every layer reads it: the RoleBindings it gets, the objects `owner-seal` lets it write, the namespaces
`exec-guard` lets it exec in, the ServiceAccounts `sa-guard` lets its workloads run as. Removing the label removes all of it at the next reconcile. It is
also how a team that crosses several products is given each one's slice — one team per crossing, each labelled with the owner it serves.

**It converges, it does not switch:** a new or removed mapping reaches the persona, the bindings and the policies at their next reconcile. To see it
sooner, nudge a policy: `kubectl annotate xpolicy <name> wxops.test/nudge="$(date +%s)" --overwrite`. The sandbox plays it end to end with
`./run.sh mapping` ([trying the templates](policy.md#trying-the-templates-on-a-cluster)).

## spec.parameters

| Field | Type | Default | Notes |
|---|---|---|---|
| `description` | `string` | — (required) | What the persona may do, in one line |
| `environments` | `[string]` | `[]` | Environments the persona applies on; echoed to status. Enforced per namespace by the optional [`env-gate`](policy.md) template — its members change a guarded namespace only if its `wxops.cloud/environment` is listed here — and on an `XApp` or `XDatabase`'s own `environment`, which must be listed here too. The per-cluster gate arrives with the multi-cluster feature |
| `members.teams` | `boolean` | `true` | Generate members from labelled `XScmTeam`s |
| `members.groups` | `[string]` | `[]` | Groups by hand, `<org>:<team>`. A `system:` group is refused |
| `members.users` | `[string]` | `[]` | Dex usernames by hand. A `system:` username is refused |
| `members.serviceAccounts` | `[{namespace, name}]` | `[]` | In-cluster identities; agents first. Bound as `ServiceAccount` subjects |

**A persona holds SCM identities only.** `system:` groups and usernames — `system:authenticated`, `system:serviceaccounts`, `system:masters`, … — belong to
Kubernetes, and the XRD refuses them in `members.groups` and `members.users`. One typo there would bind a persona's role to every identity in the cluster, or
exempt everyone from a policy. Kubernetes' own identities are left alone otherwise: no policy matches them, and a pod's ServiceAccount joins a persona only by
name, through `members.serviceAccounts`.

## status

| Field | Meaning |
|---|---|
| `created`, `ready`, `synced` | `true` once the members are resolved. A persona composes nothing, so nothing can fail to apply |
| `subjects` | Every member as an RBAC subject (`Group`, `User` or `ServiceAccount`), sorted and de-duplicated |
| `groups` | The `Group` names alone — what a policy matches on |
| `teams` | The `XScmTeam`s that contributed a group |
| `owners` | `[{group, owner}]` — member teams mapped to a second owner by `wxops.cloud/owner` ([above](#a-second-team-on-one-owner)); empty when none is |
| `environments` | As declared |

## Example

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersona
metadata:
  name: platform
spec:
  parameters:
    description: Takes responsibility across every org, team and cluster
    environments: [dev, staging, prod]
    members:
      teams: false                    # nobody joins by labelling an XScmTeam
      groups: [wxops-idp:platform]
```

The other three default personas ([RFC-009](../../../development-docs/rfc/009-scm-personas.md#default-personas)), applied and adjusted per installation:

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersona
metadata:
  name: viewers
spec:
  parameters:
    description: Reads its own team's resources
    environments: [dev, staging, prod]
```

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersona
metadata:
  name: owners
spec:
  parameters:
    description: As developers, and production — a team's maintainers
    environments: [dev, staging, prod]
```

```yaml
# The platform team: takes responsibility across every org, team and cluster. Its members are listed by hand — a group, not a team label —
# so nobody can join it by labelling an XScmTeam.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersona
metadata:
  name: platform
spec:
  parameters:
    description: Takes responsibility across every org, team and cluster
    environments: [dev, staging, prod]
    members:
      teams: false
      groups: [wxops-idp:platform]
```
