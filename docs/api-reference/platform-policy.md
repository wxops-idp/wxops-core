# XPlatformPolicy

Renders **one reviewed Kyverno CEL policy** (`policies.kyverno.io/v1`) per resource. RBAC grants ([`XPersonaBinding`](persona-binding.md)); a policy narrows —
"edit" becomes "edit your own". Policies are **templates with parameters, not free-form CEL**: a new rule is a change to this package, with tests.
Design: [RFC-009](../../development-docs/rfc/009-scm-personas.md), [RFC-005](../../development-docs/rfc/005-git-mapped-authorization.md).

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XPlatformPolicy` |
| **Plural** | `xplatformpolicies` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/platform-policy/`](../../package/auth/platform-policy) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

## Who a policy applies to

**SCM users, and nobody else.** A caller is an SCM user when their username does not start with `system:` and they carry a group `<org>:...` for one of `scmOrgs`.
Controllers, Crossplane, External Secrets Operator and Argo CD are never matched — they answer to their own RBAC, and Argo CD to its AppProjects and merge review.
`exemptPersonaRef` additionally exempts a persona (the platform team).

Background scanning is off: these policies read `request.userInfo`, which a background scan does not have. PolicyReports come from admission.

## Templates

| `template` | Kyverno kind | Rule |
|---|---|---|
| `owner-stamp` | `MutatingPolicy` | A new object in a tenant namespace (`auth.wxops.cloud/tenant-namespace: "true"`) gets that namespace's `wxops.cloud/owner` label if it has none. Copies a fact, never decides one; never blocks |
| `owner-seal` | `ValidatingPolicy` | Create, update and delete only where the object's owner is one of the caller's teams. The owner is the object's `wxops.cloud/owner` label, or — for an unlabelled **namespaced** object — its namespace's. On update, **both** the old and the new owner must be the caller's, so nothing can be relabelled away from its team. Options: `ownerPattern`, `immutableOwner` |
| `secret-readonly` | `ValidatingPolicy` | No create, update or delete of a `Secret`. Values come from OpenBao through External Secrets Operator. Reading is RBAC's — admission never sees a read |
| `exec-guard` | `ValidatingPolicy` | `exec`, `attach` and `port-forward` (`CONNECT`) only for the members of `personaRef`, and only in a namespace one of their teams owns |
| `protected` | `ValidatingPolicy` | No update or delete of an object labelled `wxops.cloud/protected: "true"` |
| `rbac-guard` | `ValidatingPolicy` | No write to a `Role`, `RoleBinding`, `ClusterRole`, `ClusterRoleBinding` or any `auth.wxops.cloud` kind. A team `admin` may create RoleBindings in its namespace and could otherwise bind around `XPersonaBinding`. **Ship it in `Deny` before the first `admin` binding exists** |

Access reviews, events and leases are never sealed (`excludeResourceRules`) — `kubectl auth can-i` must keep working.

### What each policy does in practice

The same small cast in every example. **alice** is in team `payment`, persona `developers`. **carol** is in team `checkout`, persona `owners`. The namespace `payment-api` is owned by
`payment`, `checkout-web` by `checkout`. ✓ goes through, ✗ is refused (in `Audit` it goes through too, and a PolicyReport records the same message). RBAC has already said yes to the
kind in every case — a policy only narrows.

**`owner-stamp`** — copies the namespace's owner onto what is created in it, so the label is there to compare later. Never refuses anything.
- alice creates a ConfigMap in `payment-api` with no labels → stored with `wxops.cloud/owner: payment`.

**`owner-seal`** — "edit" means "edit your own". Compares the object's owner with the caller's teams.
- ✓ alice updates a Deployment in `payment-api`.
- ✗ alice deletes a Deployment in `checkout-web` → `authz.wxops.cloud: owner checkout is not one of your teams [payment]`.
- ✗ alice relabels her own Deployment `wxops.cloud/owner: checkout` — handing it to another team is refused, because the new *and* the old owner must both be hers.
- With `ownerPattern` and `immutableOwner` (Core XRs, which have no namespace): ✗ creating an `XTenantApp` with no owner label, ✗ changing its owner later.

**`secret-readonly`** — people do not write Secrets; External Secrets Operator does, from OpenBao.
- ✗ alice runs `kubectl create secret generic db --from-literal=password=…` → `Secrets are written by External Secrets Operator from OpenBao, not by hand`.
- ✓ alice creates an `ExternalSecret` that pulls it; ✓ alice reads a Secret (reading is RBAC's, not this policy's).

**`exec-guard`** — a shell in a pod is the most powerful thing a person can do in a namespace, so it is for a named persona, in its own namespaces only.
- ✗ alice runs `kubectl exec` in `payment-api` — `developers` is not the persona (`owners`).
- ✓ carol runs `kubectl exec` in `checkout-web`; ✗ carol in `payment-api` — not her team's namespace. Same for `attach` and `port-forward`.

**`protected`** — locks one object against edits by people, wherever it sits, by a label.
- The platform team labels a shared NetworkPolicy in `payment-api` `wxops.cloud/protected: "true"`.
- ✗ alice edits or deletes it — including removing the label. ✓ the platform team (exempt) can.

**`rbac-guard`** — closes the door `admin` leaves open: a team admin may create RoleBindings in its namespace and could bind around [`XPersonaBinding`](persona-binding.md).
- ✗ carol runs `kubectl create rolebinding …` in `checkout-web` — her `admin` role would allow it; this policy does not.
- ✓ `XPersonaBinding` still creates its RoleBindings — the provider is a controller, not an SCM user.

### What each template generates

Every policy below is the composition's real output for the example of the same name in [`examples/platform-policy/`](../../examples/platform-policy), rendered
2026-10-30 against its [`required-resources.yaml`](../../examples/platform-policy/required-resources.yaml): persona `platform` is the group
`wxops-idp:platform`, persona `owners` the group `wxops-idp:owners`. Only the Kyverno policy is shown — not the `Object` wrapping it, nor its three labels
(`wxops.cloud/managed-by`, `auth.wxops.cloud/policy`, `auth.wxops.cloud/template`) — and the parts every policy shares are printed once, then marked `# …`.
After a change to `kcl/platform-policy/main.k`, the goldens under `tests/cases/platform-policy/` show the new output first.

#### The parts every policy shares

```yaml
spec:
  evaluation:
    background: {enabled: false}       # policies read request.userInfo, which a background scan does not have
  failurePolicy: Ignore                # mode: Audit → Ignore and validationActions [Audit]; mode: Deny → Fail and [Deny]
  validationActions: [Audit]
  matchConditions:
    - name: scm-user                   # from scmOrgs: a person with an "<org>:<team>" group, never a system: user
      expression: |-
        !request.userInfo.username.startsWith('system:') && request.userInfo.groups.exists(g, ['wxops-idp:'].exists(p, g.startsWith(p)))
    - name: not-exempt                 # only with exemptPersonaRef: the persona's groups and users, resolved from its status.subjects
      expression: |-
        !(request.userInfo.groups.exists(g, g in ['wxops-idp:platform']) || request.userInfo.username in [])
  matchConstraints:
    excludeResourceRules:              # on templates matching every kind: what a person's own client creates, never owned
      - {apiGroups: [authentication.k8s.io, authorization.k8s.io], apiVersions: ['*'], operations: ['*'], resources: ['*']}  # access reviews
      - {apiGroups: ['', events.k8s.io], apiVersions: ['*'], operations: ['*'], resources: [events]}
      - {apiGroups: [coordination.k8s.io], apiVersions: ['*'], operations: ['*'], resources: [leases]}
  variables:                           # on the templates that compare owners
    - name: teams                      # the caller's teams: "<org>:<team>" groups of a listed org, org removed
      expression: |-
        request.userInfo.groups.filter(g, ['wxops-idp:'].exists(p, g.startsWith(p))).map(g, g.substring(g.indexOf(':') + 1))
    - name: nsOwner                    # the request's namespace's owner; empty for a cluster-scoped object
      expression: |-
        namespaceObject != null && has(namespaceObject.metadata.labels) && 'wxops.cloud/owner' in namespaceObject.metadata.labels ? namespaceObject.metadata.labels['wxops.cloud/owner'] : ''
```

#### `owner-stamp` — [`owner-stamp.yaml`](../../examples/platform-policy/owner-stamp.yaml): `scmOrgs: [wxops-idp]`

The only `MutatingPolicy`, and the only template that matches every caller — the stamp is wanted on what controllers create too. Never refuses
(`failurePolicy: Ignore`, whatever `mode` says).

```yaml
apiVersion: policies.kyverno.io/v1
kind: MutatingPolicy
metadata: {name: wxops-owner-stamp}
spec:
  # … evaluation, failurePolicy: Ignore
  matchConditions:
    - name: namespace-has-owner
      expression: |-
        namespaceObject != null && has(namespaceObject.metadata.labels) && 'wxops.cloud/owner' in namespaceObject.metadata.labels
    - name: object-has-no-owner
      expression: |-
        !(has(object.metadata.labels) && 'wxops.cloud/owner' in object.metadata.labels)
  matchConstraints:
    # … excludeResourceRules
    namespaceSelector:
      matchLabels: {auth.wxops.cloud/tenant-namespace: 'true'}
    resourceRules:
      - {apiGroups: ['*'], apiVersions: ['*'], operations: [CREATE], resources: ['*']}
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: |-
          Object{metadata: Object.metadata{labels: {'wxops.cloud/owner': namespaceObject.metadata.labels['wxops.cloud/owner']}}}
```

#### `owner-seal` — [`xr.yaml`](../../examples/platform-policy/xr.yaml): `scmOrgs: [wxops-idp]`, `exemptPersonaRef: platform`

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-owner-seal}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (scm-user, not-exempt)
  matchConstraints:
    # … excludeResourceRules
    resourceRules:
      - {apiGroups: ['*'], apiVersions: ['*'], operations: [CREATE, UPDATE, DELETE], resources: ['*']}
  variables:
    # … teams, nsOwner
    - name: newOwner                   # the object's own label, else its namespace's
      expression: |-
        (object != null ? (has(object.metadata.labels) && 'wxops.cloud/owner' in object.metadata.labels ? object.metadata.labels['wxops.cloud/owner'] : variables.nsOwner) : '')
    - name: oldOwner
      expression: |-
        (oldObject != null ? (has(oldObject.metadata.labels) && 'wxops.cloud/owner' in oldObject.metadata.labels ? oldObject.metadata.labels['wxops.cloud/owner'] : variables.nsOwner) : '')
  validations:
    - expression: |-
        (request.operation == 'DELETE' || variables.newOwner in variables.teams) && (request.operation == 'CREATE' || variables.oldOwner in variables.teams)
      messageExpression: |-
        'authz.wxops.cloud: owner ' + (request.operation == 'DELETE' ? variables.oldOwner : variables.newOwner) + ' is not one of your teams [' + variables.teams.join(', ') + ']'
```

Reads as: a create needs the new owner to be yours, a delete the old one, an update both — so handing an object to another team, or taking one, fails.

**With `ownerPattern` and `immutableOwner`** ([`owner-seal-core.yaml`](../../examples/platform-policy/owner-seal-core.yaml), for cluster-scoped Core XRs)
the same policy gains two validations:

```yaml
    - expression: |-
        request.operation == 'DELETE' || variables.newOwner.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')
      message: |-
        authz.wxops.cloud: the wxops.cloud/owner label must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$
    - expression: request.operation != 'UPDATE' || variables.newOwner == variables.oldOwner
      message: |-
        authz.wxops.cloud: the wxops.cloud/owner label is immutable
```

#### `secret-readonly` — [`secret-readonly.yaml`](../../examples/platform-policy/secret-readonly.yaml): `scmOrgs: [wxops-idp]`

No exemption, no variables: every write to a Secret by an SCM user is refused.

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-secret-readonly}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (scm-user)
  matchConstraints:
    resourceRules:
      - {apiGroups: [''], apiVersions: ['*'], operations: [CREATE, UPDATE, DELETE], resources: [secrets]}
  validations:
    - expression: 'false'
      message: 'authz.wxops.cloud: Secrets are written by External Secrets Operator from OpenBao, not by hand'
```

#### `exec-guard` — [`exec-guard.yaml`](../../examples/platform-policy/exec-guard.yaml): `personaRef: owners`, `exemptPersonaRef: platform`

The persona's groups are written into the validation, so a team joining `owners` re-renders the policy.

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-exec-guard}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (scm-user, not-exempt), variables (teams, nsOwner)
  matchConstraints:
    resourceRules:
      - {apiGroups: [''], apiVersions: ['*'], operations: [CONNECT], resources: [pods/exec, pods/attach, pods/portforward]}
  validations:
    - expression: |-
        (request.userInfo.groups.exists(g, g in ['wxops-idp:owners']) || request.userInfo.username in []) && variables.nsOwner in variables.teams
      message: |-
        authz.wxops.cloud: exec, attach and port-forward are for the members of persona 'owners', in a namespace one of their teams owns
```

#### `protected` — [`protected.yaml`](../../examples/platform-policy/protected.yaml): `exemptPersonaRef: platform`

Checks `oldObject`, so removing the label is itself refused — the object is judged as it was.

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-protected}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (scm-user, not-exempt)
  matchConstraints:
    # … excludeResourceRules
    resourceRules:
      - {apiGroups: ['*'], apiVersions: ['*'], operations: [UPDATE, DELETE], resources: ['*']}
  validations:
    - expression: |-
        !(has(oldObject.metadata.labels) && 'wxops.cloud/protected' in oldObject.metadata.labels && oldObject.metadata.labels['wxops.cloud/protected'] == 'true')
      message: |-
        authz.wxops.cloud: this object is protected (wxops.cloud/protected) — the platform team changes it
```

#### `rbac-guard` — [`rbac-guard.yaml`](../../examples/platform-policy/rbac-guard.yaml): `mode: Deny`, `exemptPersonaRef: platform`

The one example in `Deny`, so it shows the other side of `mode`: `failurePolicy: Fail` and `validationActions: [Deny]`.

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-rbac-guard}
spec:
  evaluation:
    background: {enabled: false}
  failurePolicy: Fail
  validationActions: [Deny]
  # … matchConditions (scm-user, not-exempt)
  matchConstraints:
    resourceRules:
      - {apiGroups: [rbac.authorization.k8s.io], apiVersions: ['*'], operations: [CREATE, UPDATE, DELETE], resources: [roles, rolebindings, clusterroles, clusterrolebindings]}
      - {apiGroups: [auth.wxops.cloud], apiVersions: ['*'], operations: [CREATE, UPDATE, DELETE], resources: ['*']}
  validations:
    - expression: 'false'
      message: |-
        authz.wxops.cloud: bindings are written by XPersonaBinding and personas and policies by the platform team, not by hand
```

## spec.parameters

| Field | Type | Default | Notes |
|---|---|---|---|
| `template` | enum | — (required) | One of the six above |
| `mode` | `Audit` \| `Deny` | `Audit` | `Audit` records a PolicyReport and lets the request through. Ignored by `owner-stamp` |
| `scmOrgs` | `[string]` | — (required, non-empty) | The orgs whose groups make a caller an SCM user — the same as the `XOIDCConnector`'s |
| `personaRef.name` | `string` | `""` | `exec-guard` only, and required there: the persona that may exec |
| `exemptPersonaRef.name` | `string` | `""` | A persona the policy does not apply to. Empty: nobody is exempt |
| `ownerPattern` | `string` | — | `owner-seal` only: the owner label must match this RE2 pattern — the team-slug pattern for Core XRs |
| `immutableOwner` | `boolean` | `false` | `owner-seal` only: the owner may not change on update, not even between the caller's own teams |

`failurePolicy` is `Fail` in `Deny` mode and `Ignore` in `Audit`, so a Kyverno outage never blocks anything while a policy is only being watched.

A **missing persona makes a policy stricter, never looser**: `exec-guard` then allows nobody and an exemption disappears. The policy is still rendered, with `synced: false`
and the reason in `syncMessage`.

Owner matching is exact, with no case folding: use slug-form team names (`a-z0-9-`) on every vendor
([RFC-005](../../development-docs/rfc/005-git-mapped-authorization.md#open-questions), question 11).

## status

| Field | Meaning |
|---|---|
| `created` | `true` once the policy has been applied at least once; absent until then |
| `ready` | `true` when the policy is applied, in sync, and every persona it names exists |
| `synced`, `syncMessage` | `false` with the reason while the policy failed to apply or a named persona is missing |
| `policyName`, `policyKind` | The Kyverno policy this resource renders |

## Example

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: rbac-guard
spec:
  parameters:
    template: rbac-guard
    scmOrgs: [wxops-idp]
    mode: Deny
    exemptPersonaRef:
      name: platform
```

More: [`examples/platform-policy/`](../../examples/platform-policy) — one per template.

## Trying the templates on a cluster

[`examples/platform-policy/scenarios/`](../../examples/platform-policy/scenarios) plays every template against a sandbox and checks each result. It needs a
kubeconfig that may impersonate (cluster-admin does), the three `auth` packages installed (`make install-dev`), and `curl` for the port-forward rows.

```bash
cd examples/platform-policy/scenarios
./run.sh setup      # in stages: namespaces + personas, bindings, then each template in Deny one at a time — then nginx in each namespace
./run.sh test       # 37 rows: allow, refused by a policy, or refused by RBAC first
./run.sh compare    # your platform persona vs your own kubeconfig, by `kubectl auth can-i` — writes nothing
./run.sh teardown   # the sandbox, the Dex users and their logins

# The same rows through real logins: Dex static users in the sandbox groups, each with its own Pinniped kubeconfig
./run.sh users && ./run.sh login && IDENTITY=dex ./run.sh test
```

- **Who plays.** `alice` (team-a), `bob` (team-b) and `paula` (the exempt platform persona) are impersonated with `--as`/`--as-group`, so the API server
  and Kyverno see exactly those groups. *you* is your own kubeconfig: a `system:` user, never an SCM user, so no policy matches it — the cluster-admin column.
- **Real logins, `IDENTITY=dex`.** The sandbox groups have no Git team behind them, so `users` creates three `XOIDCStaticPassword`s
  ([`users.yaml`](../../examples/platform-policy/scenarios/users.yaml)) carrying them, with generated passwords. Once Dex has re-rendered its config,
  `login` writes one kubeconfig per user under `.logins/` (git-ignored), each with its own Pinniped session cache, and logs in through the password flow
  — reading each password from OpenBao with `bao` if it is on your path, or prompting. This proves what impersonation cannot: that Dex and Pinniped
  deliver `wxops-sbx:team-a` to the API server and Kyverno unchanged.
- **Why a made-up org.** Every sandbox policy lists only `scmOrgs: [wxops-sbx]`, so it runs in `Deny` without touching a real login, and your real
  `platform` persona is never matched by it. `compare` covers the real persona instead, read-only, in `wxops-platform`.
- **Why both teams get `edit` in both namespaces.** A policy only runs after RBAC says yes. Giving each team RBAC on the other's namespace leaves the
  policy as the only thing that stops a cross-team write — the case `owner-seal` exists for.
- **A row that fails is a finding**, not a script error: it prints the first line of what the API server answered. `exec-guard`'s rows are the ones to
  watch: they exec into nginx and port-forward to its Service, fetching the page through the tunnel, and whether Kyverno sees `CONNECT` for
  `pods/exec` and `pods/portforward` is still an [RFC-009 spike](../../development-docs/rfc/009-scm-personas.md#acceptance-matrix).
- **While it runs,** five policies are in `Deny` with `failurePolicy: Fail`. They match only `wxops-sbx` users, but Kyverno is in the request path for
  their resources until `teardown`.
