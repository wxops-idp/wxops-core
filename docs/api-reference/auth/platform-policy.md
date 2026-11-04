# XPlatformPolicy

Renders **one reviewed Kyverno CEL policy** (`policies.kyverno.io/v1`) per resource. RBAC grants ([`XPersonaBinding`](persona-binding.md)); a policy narrows —
"edit" becomes "edit your own". Policies are **templates with parameters, not free-form CEL**: a new rule is a change to this package, with tests.
Design: [RFC-009](../../../development-docs/rfc/009-scm-personas.md), [RFC-005](../../../development-docs/rfc/005-git-mapped-authorization.md).

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XPlatformPolicy` |
| **Plural** | `xplatformpolicies` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/platform-policy/`](../../../package/auth/platform-policy) — see [`VERSIONS.yaml`](../../../VERSIONS.yaml) for the current package version |

## Who a policy applies to

**SCM users, and nobody else.** A caller is an SCM user when their username does not start with `system:` and they carry a group `<org>:...` for one of `scmOrgs`.
Controllers, Crossplane, External Secrets Operator and Argo CD are never matched — they answer to their own RBAC, and Argo CD to its AppProjects and merge review.
`exemptPersonaRef` additionally exempts a persona (the platform team).

Background scanning is off: these policies read `request.userInfo`, which a background scan does not have. Any PolicyReports come from admission — and only
while Kyverno's reports controller runs.

> [!IMPORTANT]
> **`mode: Audit` reports only if Kyverno's reports controller runs.** Without it, an `Audit` policy neither blocks nor visibly records anything — use `Deny`,
> as every template was proven in. Whether the reports controller runs at all is an open question ([RFC-009 question 9](../../../development-docs/rfc/009-scm-personas.md#open-questions)).

## Templates

| `template` | Kyverno kind | Rule |
|---|---|---|
| `owner-stamp` | `MutatingPolicy` | A new object in a tenant namespace (`auth.wxops.cloud/tenant-namespace: "true"`) gets that namespace's `wxops.cloud/owner` label if it has none. Copies a fact, never decides one; never blocks |
| `owner-seal` | `ValidatingPolicy` | Create, update and delete only where the object's owner is one of the caller's teams. The owner is the object's `wxops.cloud/owner` label, or — for an unlabelled **namespaced** object — its namespace's. On update, **both** the old and the new owner must be the caller's, so nothing can be relabelled away from its team. Options: `ownerPattern`, `immutableOwner` |
| `secret-readonly` | `ValidatingPolicy` | No create, update or delete of a `Secret`. Values come from OpenBao through External Secrets Operator. Reading is RBAC's — admission never sees a read |
| `exec-guard` | `ValidatingPolicy` | `exec`, `attach` and `port-forward` (`CONNECT`) only for the members of `personaRef`, and only in a namespace one of their teams owns |
| `protected` | `ValidatingPolicy` | No update or delete of an object labelled `wxops.cloud/protected: "true"` |
| `rbac-guard` | `ValidatingPolicy` | No write to a `Role`, `RoleBinding`, `ClusterRole`, `ClusterRoleBinding` or any `auth.wxops.cloud` kind. Team persona roles grant no RBAC writes; this is the second layer, for anyone holding `admin` (the platform persona, unless exempt) or a role added later |
| `sa-guard` | `ValidatingPolicy` | A `Pod`, or a workload's pod template (Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob), runs only as `default` or a ServiceAccount whose `wxops.cloud/owner` is one of the caller's teams. Reads the namespace's ServiceAccounts at admission (Kyverno's `resource.List`), so it stays a Kyverno webhook policy |
| `namespace-guard` | `ValidatingPolicy` | No create or delete of a `Namespace`, and no change to its `wxops.cloud/owner` or `auth.wxops.cloud/tenant-namespace` label — the labels every other template trusts. Team roles cannot write Namespaces at all; this holds against any wider grant |

Access and token reviews, Pinniped's login APIs, events and leases are never sealed — `kubectl auth can-i` and every login must keep working, so they are
excluded twice: `excludeResourceRules`, and the `not-excluded` match condition the API server evaluates before calling Kyverno.

### What each policy does in practice

The same small cast in every example. **alice** is in team `payment`, persona `developers`. **carol** is in team `checkout`, persona `owners`. The namespace `payment-api` is owned by
`payment`, `checkout-web` by `checkout`. ✓ goes through, ✗ is refused by the policy (in `Audit` it goes through too, and a PolicyReport records the same
message while Kyverno's reports controller runs), ✗ (RBAC) is refused before any policy runs — the persona roles ([`XPersonaBinding`](persona-binding.md#roles)) do not grant it at all. A policy only
narrows what RBAC allowed.

**`owner-stamp`** — copies the namespace's owner onto what is created in it, so the label is there to compare later. Never refuses anything.
- alice creates a ConfigMap in `payment-api` with no labels → stored with `wxops.cloud/owner: payment`.

**`owner-seal`** — "edit" means "edit your own". Compares the object's owner with the caller's teams.
- ✓ alice updates a Deployment in `payment-api`.
- ✗ alice deletes a Deployment in `checkout-web` → `auth.wxops.cloud: owner checkout is not one of your teams [payment]`.
- ✗ alice relabels her own Deployment `wxops.cloud/owner: checkout` — handing it to another team is refused, because the new *and* the old owner must both be hers.
- With `ownerPattern` and `immutableOwner` (Core XRs, which have no namespace): ✗ creating an `XTenantApp` with no owner label, ✗ changing its owner later.

**`secret-readonly`** — people do not write Secrets; External Secrets Operator does, from OpenBao.
- ✗ alice runs `kubectl create secret generic db --from-literal=password=…` → `Secrets are written by External Secrets Operator from OpenBao, not by hand`.
- ✓ alice creates an `ExternalSecret` that pulls it. ✗ (RBAC) alice reads a Secret: team personas read through `view`, which has none.
- With the persona roles, no team role writes Secrets anyway — this policy is the second layer, for `admin` (the platform persona) and any role added later.

**`exec-guard`** — a shell in a pod is the most powerful thing a person can do in a namespace, so it is for a named persona, in its own namespaces only.
- ✗ (RBAC) alice runs `kubectl exec` in `payment-api` — `wxops:persona-developers` has no `exec` at all; only `owners` does.
- ✓ carol runs `kubectl exec` in `checkout-web`; ✗ carol in `payment-api` — not her team's namespace. Same for `attach` and `port-forward`.

**`protected`** — locks one object against edits by people, wherever it sits, by a label.
- The platform team labels a shared NetworkPolicy in `payment-api` `wxops.cloud/protected: "true"`.
- ✗ alice edits or deletes it — including removing the label. ✓ the platform team (exempt) can.

**`rbac-guard`** — bindings come only from [`XPersonaBinding`](persona-binding.md). Team roles already cannot write them; this closes the door for whoever holds
`admin` without the exemption, and for any role added later.
- ✗ (RBAC) carol runs `kubectl create rolebinding …` in `checkout-web` — `wxops:persona-owners` has no RBAC writes.
- ✗ someone holding `admin` in `checkout-web` but outside the platform persona creates one — `admin` would allow it; this policy does not.
- ✓ `XPersonaBinding` still creates its RoleBindings — the provider is a controller, not an SCM user.

**`sa-guard`** — a workload runs as its own team's ServiceAccount, never someone else's.
- ✓ alice creates a Deployment in `payment-api` with no `serviceAccountName` (it runs as `default`), or as `payment-worker`, a ServiceAccount labelled
  `wxops.cloud/owner: payment`.
- ✗ alice sets `serviceAccountName: platform-sync`, a ServiceAccount the platform team owns in the same namespace →
  `ServiceAccount platform-sync is not owned by one of your teams [payment]`. Same for a Pod, StatefulSet, Job or CronJob.
- With the persona roles, alice also cannot impersonate a ServiceAccount or request its token (RBAC) — the two together close acting as another identity.

**`namespace-guard`** — the labels every rule trusts stay the platform team's.
- ✗ (RBAC) alice creates a Namespace or relabels one — team roles are bound per namespace and cannot touch Namespaces.
- ✗ anyone given Namespace rights outside the platform persona changes `payment-api`'s `wxops.cloud/owner`, removes its `auth.wxops.cloud/tenant-namespace`, or
  creates or deletes a Namespace. ✓ the same person adds an unrelated label.

### What each template generates

Every policy below is the composition's real output for the XR shown above it, rendered 2026-10-30 (`sa-guard`, `namespace-guard`: 2026-11-03)
with persona `platform` as the group `wxops-idp:platform` and persona `owners` as `wxops-idp:owners`. Only the Kyverno policy is shown — not the `Object`
wrapping it, nor its three labels (`wxops.cloud/managed-by`, `auth.wxops.cloud/policy`, `auth.wxops.cloud/template`) — and the parts every policy shares
are printed once, then marked `# …`. After a change to `kcl/platform-policy/main.k`, the goldens under `tests/cases/platform-policy/` show the new output first.

#### The parts every policy shares

```yaml
spec:
  evaluation:
    background: {enabled: false}       # policies read request.userInfo, which a background scan does not have
  failurePolicy: Ignore                # mode: Audit → Ignore and validationActions [Audit]; mode: Deny → Fail and [Deny]
  validationActions: [Audit]
  matchConditions:
    - name: not-excluded               # on templates matching every kind (owner-stamp, owner-seal, protected) — see below
      expression: |-
        !(request.resource.group in ['authentication.k8s.io', 'authorization.k8s.io', 'login.concierge.pinniped.dev', 'identity.concierge.pinniped.dev']) && !(request.resource.resource in ['events', 'leases'])
    - name: scm-user                   # from scmOrgs: a person with an "<org>:<team>" group, never a system: user
      expression: |-
        !request.userInfo.username.startsWith('system:') && request.userInfo.groups.exists(g, ['wxops-idp:'].exists(p, g.startsWith(p)))
    - name: not-exempt                 # only with exemptPersonaRef: the persona's groups and users, resolved from its status.subjects
      expression: |-
        !(request.userInfo.groups.exists(g, g in ['wxops-idp:platform']) || request.userInfo.username in [])
  matchConstraints:
    excludeResourceRules:              # on templates matching every kind: what a person's own client creates, never owned
      - {apiGroups: [authentication.k8s.io, authorization.k8s.io, login.concierge.pinniped.dev, identity.concierge.pinniped.dev], apiVersions: ['*'], operations: ['*'], resources: ['*']}  # access reviews, logins
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

**Why the exclusions appear twice.** Kyverno copies a policy's match conditions into the webhook it registers with the API server, but not its
`excludeResourceRules` — those it applies only after it has been called. So the exclusions are also a match condition (`not-excluded`), evaluated by the API
server before any call to Kyverno. Without it, every SubjectAccessReview and TokenReview — every authorization check Pinniped's impersonation proxy and the
aggregated APIs make — first waited on Kyverno, and a slow Kyverno timed logins out (found 2026-11-04).

#### `owner-stamp`

The only `MutatingPolicy`, and the only template that matches every caller — the stamp is wanted on what controllers create too. Never refuses
(`failurePolicy: Ignore`, whatever `mode` says).

The XR:

```yaml
# The one Kyverno mutation: a new object in a tenant namespace (labelled auth.wxops.cloud/tenant-namespace) gets that namespace's wxops.cloud/owner label if it has none.
# It copies a fact, never decides one, and never blocks a request.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: owner-stamp
spec:
  parameters:
    template: owner-stamp
    scmOrgs: [wxops-idp]
```

Renders:

```yaml
apiVersion: policies.kyverno.io/v1
kind: MutatingPolicy
metadata: {name: wxops-owner-stamp}
spec:
  # … evaluation, failurePolicy: Ignore
  matchConditions:
    # … not-excluded
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
    resourceRules:                     # namespaced only — a namespace selector does not apply to cluster-scoped objects
      - {apiGroups: ['*'], apiVersions: ['*'], operations: [CREATE], resources: ['*'], scope: Namespaced}
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: |-
          Object{metadata: Object.metadata{labels: {'wxops.cloud/owner': namespaceObject.metadata.labels['wxops.cloud/owner']}}}
```

#### `owner-seal`

No exemption, no variables: every write to a Secret by an SCM user is refused.

The XR — [`examples/auth/platform-policy/xr.yaml`](../../../examples/auth/platform-policy/xr.yaml), the package's example:

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: owner-seal
spec:
  parameters:
    template: owner-seal
    scmOrgs: [wxops-idp]
    exemptPersonaRef:
      name: platform
```

Renders:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-owner-seal}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (not-excluded, scm-user, not-exempt)
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
        'auth.wxops.cloud: owner ' + (request.operation == 'DELETE' ? variables.oldOwner : variables.newOwner) + ' is not one of your teams [' + variables.teams.join(', ') + ']'
```

Reads as: a create needs the new owner to be yours, a delete the old one, an update both — so handing an object to another team, or taking one, fails.

**With `ownerPattern` and `immutableOwner`**, for cluster-scoped Core XRs:

```yaml
# Core XRs (RFC-005): cluster-scoped, so they must carry the owner label, may never change owner, and the label must be a team slug. Move to Deny after the audit.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: owner-seal-core
spec:
  parameters:
    template: owner-seal
    scmOrgs: [wxops-idp]
    ownerPattern: '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
    immutableOwner: true
    exemptPersonaRef:
      name: platform
```

the same policy gains two validations:

```yaml
    - expression: |-
        request.operation == 'DELETE' || variables.newOwner.matches('^[a-z0-9](../[-a-z0-9]*[a-z0-9])?$')
      message: |-
        auth.wxops.cloud: the wxops.cloud/owner label must match ^[a-z0-9](../[-a-z0-9]*[a-z0-9])?$
    - expression: request.operation != 'UPDATE' || variables.newOwner == variables.oldOwner
      message: |-
        auth.wxops.cloud: the wxops.cloud/owner label is immutable
```

#### `secret-readonly`

The XR:

```yaml
# People do not write Secrets: values come from OpenBao through External Secrets Operator, whose controller is the writer.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: secret-readonly
spec:
  parameters:
    template: secret-readonly
    scmOrgs: [wxops-idp]
```

Renders:

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
      message: 'auth.wxops.cloud: Secrets are written by External Secrets Operator from OpenBao, not by hand'
```

#### `exec-guard`

The persona's groups are written into the validation, so a team joining `owners` re-renders the policy.

The XR:

```yaml
# exec, attach and port-forward only for the owners persona, and only in a namespace one of their teams owns.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: exec-guard
spec:
  parameters:
    template: exec-guard
    scmOrgs: [wxops-idp]
    personaRef:
      name: owners
    exemptPersonaRef:
      name: platform
```

Renders:

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
        auth.wxops.cloud: exec, attach and port-forward are for the members of persona 'owners', in a namespace one of their teams owns
```

#### `protected`

Checks `oldObject`, so removing the label is itself refused — the object is judged as it was.

The XR:

```yaml
# An object labelled wxops.cloud/protected: "true" cannot be updated or deleted by an SCM user — shared or platform objects inside a team's namespace.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: protected
spec:
  parameters:
    template: protected
    scmOrgs: [wxops-idp]
    exemptPersonaRef:
      name: platform
```

Renders:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-protected}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (not-excluded, scm-user, not-exempt)
  matchConstraints:
    # … excludeResourceRules
    resourceRules:
      - {apiGroups: ['*'], apiVersions: ['*'], operations: [UPDATE, DELETE], resources: ['*']}
  validations:
    - expression: |-
        !(has(oldObject.metadata.labels) && 'wxops.cloud/protected' in oldObject.metadata.labels && oldObject.metadata.labels['wxops.cloud/protected'] == 'true')
      message: |-
        auth.wxops.cloud: this object is protected (wxops.cloud/protected) — the platform team changes it
```

#### `rbac-guard`

The one example in `Deny`, so it shows the other side of `mode`: `failurePolicy: Fail` and `validationActions: [Deny]`.

The XR:

```yaml
# Bindings come only from XPersonaBinding: team roles cannot write them, and this refuses anyone holding `admin` outside the platform persona.
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

Renders:

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
        auth.wxops.cloud: bindings are written by XPersonaBinding and personas and policies by the platform team, not by hand
```

#### `sa-guard`

The only template reading another object at admission: Kyverno's `resource.List` fetches the namespace's ServiceAccounts (`dyn(…)` because Kyverno types the
list as `any`). That is why it cannot become a native `ValidatingAdmissionPolicy`.

The XR:

```yaml
# A workload runs only as `default` or a ServiceAccount its creator's team owns (wxops.cloud/owner) — closes running as another team's or the platform's.
# Pair with the persona roles, which no longer let a team impersonate a ServiceAccount or request its token (RFC-009, Phase 2b).
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: sa-guard
spec:
  parameters:
    template: sa-guard
    scmOrgs: [wxops-idp]
    exemptPersonaRef:
      name: platform
```

Renders:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-sa-guard}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (scm-user, not-exempt)
  matchConstraints:
    resourceRules:
      - {apiGroups: [''], apiVersions: ['*'], operations: [CREATE, UPDATE], resources: [pods]}
      - {apiGroups: [apps], apiVersions: ['*'], operations: [CREATE, UPDATE], resources: [deployments, statefulsets, daemonsets, replicasets]}
      - {apiGroups: [batch], apiVersions: ['*'], operations: [CREATE, UPDATE], resources: [jobs, cronjobs]}
  variables:
    # … teams
    - name: podSpec                    # wherever the kind keeps it
      expression: |-
        object.kind == 'Pod' ? object.spec : object.kind == 'CronJob' ? object.spec.jobTemplate.spec.template.spec : object.spec.template.spec
    - name: serviceAccount             # serviceAccountName, else the deprecated serviceAccount, else default
      expression: |-
        has(variables.podSpec.serviceAccountName) && variables.podSpec.serviceAccountName != '' ? variables.podSpec.serviceAccountName : has(variables.podSpec.serviceAccount) && variables.podSpec.serviceAccount != '' ? variables.podSpec.serviceAccount : 'default'
  validations:
    - expression: |-
        variables.serviceAccount == 'default' || dyn(resource.List('v1', 'serviceaccounts', request.namespace).items).exists(s, s.metadata.name == variables.serviceAccount && has(s.metadata.labels) && 'wxops.cloud/owner' in s.metadata.labels && s.metadata.labels['wxops.cloud/owner'] in variables.teams)
      messageExpression: |-
        'auth.wxops.cloud: ServiceAccount ' + variables.serviceAccount + ' is not owned by one of your teams [' + variables.teams.join(', ') + '] — run as default or your own'
```

#### `namespace-guard`

Two validations: the first refuses any create or delete, the second compares the two guarded labels before and after an update — a missing label counts as
`''`, so removing one is a change too.

The XR:

```yaml
# Namespaces and their owner and tenant labels are the platform team's — every other rule trusts those labels.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPlatformPolicy
metadata:
  name: namespace-guard
spec:
  parameters:
    template: namespace-guard
    scmOrgs: [wxops-idp]
    exemptPersonaRef:
      name: platform
```

Renders:

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata: {name: wxops-namespace-guard}
spec:
  # … evaluation, failurePolicy, validationActions, matchConditions (scm-user, not-exempt)
  matchConstraints:
    resourceRules:
      - {apiGroups: [''], apiVersions: ['*'], operations: [CREATE, UPDATE, DELETE], resources: [namespaces]}
  validations:
    - expression: request.operation == 'UPDATE'
      message: 'auth.wxops.cloud: Namespaces are created and deleted by the platform team'
    - expression: |-
        request.operation != 'UPDATE' || ['wxops.cloud/owner', 'auth.wxops.cloud/tenant-namespace'].all(k, (has(object.metadata.labels) && k in object.metadata.labels ? object.metadata.labels[k] : '') == (has(oldObject.metadata.labels) && k in oldObject.metadata.labels ? oldObject.metadata.labels[k] : ''))
      message: |-
        auth.wxops.cloud: a Namespace's wxops.cloud/owner and auth.wxops.cloud/tenant-namespace labels change only by the platform team
```

## spec.parameters

| Field | Type | Default | Notes |
|---|---|---|---|
| `template` | enum | — (required) | One of the eight above |
| `mode` | `Audit` \| `Deny` | `Audit` | `Deny` refuses. `Audit` lets the request through and records a PolicyReport — only while Kyverno's reports controller runs. Ignored by `owner-stamp` |
| `scmOrgs` | `[string]` | — (required, non-empty) | The orgs whose groups make a caller an SCM user — the same as the `XOIDCConnector`'s |
| `personaRef.name` | `string` | `""` | `exec-guard` only, and required there: the persona that may exec |
| `exemptPersonaRef.name` | `string` | `""` | A persona the policy does not apply to. Empty: nobody is exempt |
| `ownerPattern` | `string` | — | `owner-seal` only: the owner label must match this RE2 pattern — the team-slug pattern for Core XRs |
| `immutableOwner` | `boolean` | `false` | `owner-seal` only: the owner may not change on update, not even between the caller's own teams |

`failurePolicy` is `Fail` in `Deny` mode and `Ignore` in `Audit`, so a Kyverno outage never blocks anything while a policy is only being watched.

A **missing persona makes a policy stricter, never looser**: `exec-guard` then allows nobody and an exemption disappears. The policy is still rendered, with `synced: false`
and the reason in `syncMessage`.

Owner matching is exact, with no case folding: use slug-form team names (`a-z0-9-`) on every vendor
([RFC-005](../../../development-docs/rfc/005-git-mapped-authorization.md#open-questions), question 11).

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

More: one XR per template, each with the policy it renders, under [What each template generates](#what-each-template-generates).

## Trying the templates on a cluster

[`examples/auth/platform-policy/scenarios/`](../../../examples/auth/platform-policy/scenarios) plays every template against a sandbox and checks each result. It needs a
kubeconfig that may impersonate (cluster-admin does), the three `auth` packages installed (`make install-dev`), and `curl` for the port-forward rows.

```bash
cd examples/auth/platform-policy/scenarios
./run.sh setup      # in stages: namespaces + personas, bindings, then each template in Deny one at a time — then nginx in each namespace
./run.sh test       # 50 rows: allow, refused by a policy, or refused by RBAC first
./run.sh compare    # your platform persona vs your own kubeconfig, by `kubectl auth can-i` — writes nothing
./run.sh teardown   # the sandbox, the Dex users and any open session

# The same rows through real logins — one user per session, through the browser
./run.sh users                    # Dex static users in the sandbox groups
./run.sh session alice            # a kubeconfig with its own Pinniped caches; log in as alice@sbx.wxops.local
SESSION=alice ./run.sh test       # alice's rows only
./run.sh session-end              # forget the login, then the same for bob and paula
```

- **Who plays.** `alice` (team-a), `bob` (team-b) and `paula` (the exempt platform persona) are impersonated with `--as`/`--as-group`, so the API server
  and Kyverno see exactly those groups. *you* is your own kubeconfig: a `system:` user, never an SCM user, so no policy matches it — the cluster-admin column.
- **Real logins, one session at a time.** The sandbox groups have no Git team behind them, so `users` creates three `XOIDCStaticPassword`s
  ([`users.yaml`](../../../examples/auth/platform-policy/scenarios/users.yaml)) carrying them, with generated passwords. Once Dex has re-rendered its config,
  `session <user>` writes a kubeconfig with its own Pinniped session and credential caches outside the repository (`$XDG_RUNTIME_DIR`), and you log in
  through the browser — the same authorization-code flow as any person; the password grant is never used, so it can stay disabled. `SESSION=<user>` runs
  that user's rows only, after checking the login carries the user's group; `session-end` deletes the caches. This proves what impersonation cannot: that
  Dex and Pinniped deliver `wxops-sbx:team-a` to the API server and Kyverno unchanged. The *you* rows run in impersonation mode, which plays everyone.
- **Why a made-up org.** Every sandbox policy lists only `scmOrgs: [wxops-sbx]`, so it runs in `Deny` without touching a real login, and your real
  `platform` persona is never matched by it. `compare` covers the real persona instead, read-only, in `wxops-platform`.
- **Why both teams get `wxops:persona-owners` in both namespaces.** A policy only runs after RBAC says yes. Giving each team RBAC on the other's namespace
  leaves the policy as the only thing that stops a cross-team write or exec — the cases `owner-seal` and `exec-guard` exist for. For the same reason
  [`namespace-editor.yaml`](../../../examples/auth/platform-policy/scenarios/namespace-editor.yaml) gives team-b Namespace writes (test-only RBAC, created and removed
  as you), so `namespace-guard` is what stops bob. Other rows check what the persona roles no longer grant: impersonating a ServiceAccount, requesting its
  token, creating ServiceAccounts, Pods, RoleBindings or Secrets, reading Secrets.
- **A row that fails is a finding**, not a script error: it prints the first line of what the API server answered. `exec-guard`'s rows are the ones to
  watch: they exec into nginx and port-forward to its Service, fetching the page through the tunnel, and whether Kyverno sees `CONNECT` for
  `pods/exec` and `pods/portforward` is still an [RFC-009 spike](../../../development-docs/rfc/009-scm-personas.md#acceptance-matrix).
- **While it runs,** seven policies are in `Deny` with `failurePolicy: Fail`. They match only `wxops-sbx` users, but Kyverno is in the request path for
  their resources until `teardown`.
