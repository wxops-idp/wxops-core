# Access Model — one SCM login, an SCM Persona, and everything it can reach

> [!NOTE]
> **Status: direction, not implemented.** The map that RFC-005, RFC-008 and a personas RFC (not yet written) each point at, so no single RFC has to
> restate the whole model. The identity half is built ([RFC-003](../rfc/003-scm-connections-and-resources.md),
> [RFC-004](../rfc/004-dex-identity-and-portal-authentication.md)); everything from *personas* down is design. Written 2026-10-20 from a design
> discussion; refine it here before the RFCs change.

---

## The principle

> **One login through your SCM. What its token says — who you are, which teams you are in — decides your SCM Persona. Your persona decides what you can
> reach: in Kubernetes, in every cluster, and in every platform tool.**

Nobody is granted access one person at a time. A person is in a Git team; the team has a persona; the persona has a fixed, reviewed meaning in every system.
Leaving the team in Git removes the access everywhere, at the next token.

### One login, not one token

"One token" means **one login, one identity, one set of claims** — not one bearer token replayed against every system. Dex issues a token per client
(audience), and Pinniped exchanges it for a credential valid for one cluster only, so a token leaked from Grafana does not open OpenBao or a cluster. Every
system sees the same `username` and `groups`; each in its own token.

---

## The layers

```text
 WHERE YOU ARE    SCM org + team                    XScmConnection, XScmTeam                         built — RFC-003
       │
 WHO YOU ARE      Dex: username + groups "org:team"  XOIDCConnector (teams generated from labelled     built — RFC-004
       │          short-lived tokens                 XScmTeams), XOIDCClient per tool
       │
 YOUR PERSONA     team × persona × scope             persona file (Git) + wxops.cloud/persona label    design — personas RFC
       │
 COMPILE          KCL in CI: persona file → ClusterRoles, Kyverno policies, tool objects,              design — personas RFC
       │          and the effective-access diff for the pull request
       │
 PROJECT          OpenBao · Grafana · Argo CD · Kubernetes                                             design — RFC-008 (broadened)
       │          Crossplane: Workspace (OpenTofu) for API-only tools, Object for CR-based tools;
       │          Kubernetes RBAC through GitOps
       │
 ENFORCE          each system natively; in Kubernetes: Pinniped → RBAC grants → Kyverno narrows      design — RFC-005 (narrowed)
       │
 SEE              Dex/Pinniped · API server audit · OpenBao audit · Argo/Grafana → Loki; PolicyReports  design
```

| Layer | Decides | Where it is written | Mechanism |
|---|---|---|---|
| Where you are | org and team | `XScmTeam` | OpenTofu Workspace against the SCM |
| Who you are | `username`, `groups` | the SCM itself, read at login | Dex connector |
| Your persona | what the team may reach | the persona file + a label on `XScmTeam` | Git review |
| Compile | the native form of every grant | generated in CI, shown in the PR | KCL |
| Project | the grant inside each tool | XRs | Crossplane, GitOps |
| Enforce | every request | each tool's own model | RBAC, OpenBao policy, Argo `policy.csv`, Grafana roles, Kyverno |
| See | what happened | logs and reports | Loki, `PolicyReport` |

---

## The SCM Persona

```text
SCM Persona = the Git team you are in  ×  the persona that team was given  ×  the team's scope (owner, environments, clusters)
```

Personas are defined **once**, as data, in one file the platform owns:

```yaml
personas:
  developer:      {k8s: edit, envs: [dev, staging],       openbao: read,       argocd: sync,     grafana: Editor}
  operator:       {k8s: edit, envs: [dev, staging, prod], openbao: read-write, argocd: sync,     grafana: Editor}
  viewer:         {k8s: view, envs: ["*"],                openbao: none,       argocd: readonly, grafana: Viewer}
  agent-auditor:  {k8s: view-no-secrets, envs: ["*"],     openbao: none,       argocd: readonly, grafana: Viewer, extra: [policyreports, audit-logs]}
  agent-debugger: {k8s: view-no-secrets, envs: ["*"],     openbao: none,       argocd: readonly, grafana: Viewer, extra: [events, pods/log]}
```

A team is given one with a label on its `XScmTeam` — `wxops.cloud/persona: developer` — that only the platform may set. The team's slug is the scope: it is the
`wxops.cloud/owner` value, the namespace, the OpenBao prefix, the Argo project and the Grafana folder, so one string ties every system together and the
matrix cannot explode — it is *personas × systems*, written once, not *teams × systems × levels*.

Two of [RFC-005](../rfc/005-git-mapped-authorization.md)'s open questions close here:

- **The maintainer tier** — a `payment-maintainers` team is simply given the `operator` persona. No role has to travel in the claim, which matters because
  neither Dex connector puts one there.
- **The group format** — `<org>:<team>`, already what `XScmTeam.status.oidcGroup` publishes and `XOIDCConnector` emits.

**Keep the list short** — about three human personas and the agent ones. Per-team exceptions are how the matrix comes back; a new persona is a reviewed change,
not a convenience.

---

## Changing access is a pull request that explains itself

```text
PR: payment team  developer → operator
  │
  CI (KCL) renders  ClusterRoles · Kyverno policies · RoleBindings · XSecretAccess / XGitOpsProject / XMonitoringFolder
  │
  CI computes the effective-access diff:
  │   "7 members of wxops-idp:payment gain: edit in prod (payment-*), read-write tenants/payment/*"
  │
  review → merge → Argo applies RBAC and policies, Crossplane applies the tool configuration
```

The relationship graph — teams, personas, persona inheritance, scopes, clusters — is walked **at compile time only**: a breadth-first walk answers *who can reach
X*, *why can alice do Y*, and *what does this PR change, for whom*. It is never on the request path; each system enforces its own projection.

---

## Three verbs: generate, modify, check

| Verb | Who | Rule |
|---|---|---|
| **Generate** | Crossplane — Workspaces for API-only tools, `Object`s for CR-based ones; GitOps for Kubernetes RBAC; Kyverno for restrictions and derived grants (below) | Declarative and convergent: it retries, and it can revoke |
| **Modify** | the compositions — KCL and patch-and-transform stamp `owner` and `environment` onto what they compose; user input cannot override them | Not Kyverno mutate: defaulting in Kyverno would be a second source of truth beside the compositions |
| **Check** | RBAC grants; Kyverno narrows | Kyverno only ever denies. It cannot give access RBAC did not |

### What Kyverno may generate

| Kyverno generates | Allowed | Why |
|---|---|---|
| NetworkPolicy, ResourceQuota, LimitRange, Pod Security labels | **yes** | They only **narrow**; a bug makes a namespace stricter, not wider |
| A grant **derived** mechanically from a validated label, scoped to that object's own owner, with no free field | **yes** | Nobody chooses who gets what — the decision was made when the label was admitted |
| A **free** grant — a RoleBinding or a tool policy for whoever asked | **no** | That is a decision; it belongs in Git as a reviewed diff |

Everything Kyverno generates passes through admission again, its own validating policies included — so a mistake in a generating policy is rejected by a
validating one.

---

## Kubernetes: Pinniped → RBAC → Kyverno

The API server authenticates the request (Pinniped, trusting Dex) and fills `userInfo` — `username` and `groups` — before anything else runs. RBAC then grants
or refuses; only then does admission run, and every `AdmissionReview` Kyverno receives already carries `request.userInfo`. Nothing is passed from Dex to
Kyverno. `kubectl auth whoami` prints the exact strings a policy will match, prefix included.

| Request | Reaches admission (Kyverno)? | Who can restrict it |
|---|---|---|
| `get` / `list` / `watch` — including `kubectl logs` | **no** | RBAC only: namespace, resource, exact name |
| `create` / `update` / `patch` / `delete` | yes | RBAC + Kyverno |
| `connect` — `exec`, `attach`, `port-forward` | yes | RBAC + Kyverno |

So **reads stop at the namespace boundary**: a team reads its own namespaces. Writes, `exec` and `delete` can be narrowed further, per object, by comparing
the object's `wxops.cloud/owner` with `request.userInfo.groups`.

**Multi-cluster** — every spoke runs the same Kyverno policy set, delivered by Argo, parameterised by a small per-cluster `wxops-cluster-info` ConfigMap
(`env`, `cluster-name`, `role: hub|spoke`). The hub additionally runs the policies guarding Core XRs.

---

## Kyverno CEL — how far it reaches

Kyverno's CEL policy types (`policies.kyverno.io/v1`, all marked stable in Kyverno v1.19) replace `ClusterPolicy`, which is scheduled for removal in v1.20:
`ValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy` and `DeletingPolicy` (each with a namespaced twin). On top of Kubernetes' own CEL they add
[libraries](https://kyverno.io/docs/policy-types/cel-libraries/) that let a policy reach beyond the object it is looking at:

| Library | Functions | What it opens up here |
|---|---|---|
| `resource` | `resource.Get`, `resource.List`, `resource.Post` | Read any in-cluster object — the `XScmTeam` behind a group, the `XScmConnection`'s mirrored org members. `resource.Post` can run a live `SubjectAccessReview` |
| `http` | `http.Get`, `http.Post`, `http.Client(caBundle)` | Ask a third party for a fact at decision time: is this incident active, who is on call |
| `globalContext` | `globalContext.Get` | Read a `GlobalContextEntry` — an in-cluster or HTTP result Kyverno refreshes on an interval, so a slow third party makes data older, not admission slower |
| `time` | `time.now`, `time.truncate`, `time.toCron` + CEL `timestamp`/`duration` | Give any grant a lifetime and compare it to now |
| `x509`, `json`, `yaml`, `hash`, `random` | decoding and helpers | Certificates, structured annotations |

This is what keeps the model from being locked to one concept: any fact a third party holds can take part in a decision, and any derived grant can be given a
start and an end.

### Temporary access: generated, checked, terminated

```text
request (reviewed object, carries wxops.cloud/expires-at)
   │
   ├─ ValidatingPolicy   http.Get → incident active and assigned to the owner?   expires-at ≤ the persona's maximum?
   │
   ├─ GeneratingPolicy   derives the grant object (XSecretAccess, …) — no free fields
   │                         └─ Crossplane makes the tool-side change (OpenBao policy, …)
   │
   └─ DeletingPolicy     on a schedule: timestamp(expires-at) < time.now()  →  delete
                             └─ Crossplane revokes it in the tool
```

**The split that keeps it safe: Kyverno decides, generates and terminates the Kubernetes object; Crossplane makes every third-party write.** An admission
check must be free of side effects — the same request can arrive several times (retries, server-side dry-run, background scans), and another webhook can
still deny it after Kyverno allowed it — so a third-party write made from admission could belong to a request that never happened, with nothing to undo it.
`http.Post` exists; here it is not used to create anything.

Sketches — not yet run through `kyverno test`:

```yaml
# Derived grant: every namespace with an owner gets read access to its own OpenBao prefix, for its own workloads only.
apiVersion: policies.kyverno.io/v1
kind: GeneratingPolicy
metadata:
  name: wxops-namespace-secret-access
spec:
  evaluation:
    synchronize: {enabled: true}          # namespace deleted → XSecretAccess deleted → OpenBao policy destroyed
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [namespaces]
  matchConditions:
    - name: has-owner
      expression: "has(object.metadata.labels) && 'wxops.cloud/owner' in object.metadata.labels"
  variables:
    - name: owner
      expression: "object.metadata.labels['wxops.cloud/owner']"
  generate:
    - expression: >-
        generator.Apply("", [{
          "apiVersion": "platform.wxops.cloud/v1alpha1", "kind": "XSecretAccess",
          "metadata": {"name": object.metadata.name + "-secrets", "labels": {"wxops.cloud/owner": variables.owner}},
          "spec": {"parameters": {
            "storeRef": {"name": "tenants"},
            "pathPrefix": variables.owner + "/" + object.metadata.name + "/",
            "capabilities": "read",
            "serviceAccounts": [{"name": "*", "namespace": object.metadata.name}]}}}])
---
# Termination: anything carrying an expiry is deleted once it has passed.
apiVersion: policies.kyverno.io/v1
kind: DeletingPolicy
metadata:
  name: wxops-expire-grants
spec:
  schedule: "* * * * *"                   # one minute is the finest granularity
  matchConstraints:
    resourceRules:
      - apiGroups: [platform.wxops.cloud]
        apiVersions: [v1alpha1]
        operations: ["*"]
        resources: [xsecretaccesses]
  conditions:
    - name: expired
      expression: >-
        has(object.metadata.annotations) && 'wxops.cloud/expires-at' in object.metadata.annotations &&
        timestamp(object.metadata.annotations['wxops.cloud/expires-at']) < time.now()
```

What to hold to:

- **HTTP is allow-listed.** Start Kyverno with `--httpAllowlist` naming the few endpoints a policy may call, and leave HTTP in namespaced policies disabled
  (the default). A reported SSRF issue in the HTTP library concerned exactly the unrestricted case.
- **A third-party fact is a dependency.** With `failurePolicy: Fail` an outage of that party blocks the writes it guards; prefer a `GlobalContextEntry` for
  anything that changes slowly.
- **A lifetime ends twice.** Expiry is precise to the `DeletingPolicy` schedule, then to the Workspace's apply — a few minutes, not seconds. A time-bound grant
  must not set `retain: true`, or deleting it would leave the tool-side grant in place.
- **Kyverno's controllers need permissions** to create and delete what they generate and terminate — `XSecretAccess`, NetworkPolicies. That is why
  generated grants have no free fields and are validated like any other write.

---

## Third-party tools

Login is the same everywhere — one `XOIDCClient` per tool, the same Dex, the same `groups` claim. Authorization differs per tool, and is projected:

| Tool | Login (static, once) | Group → permission | Projected by |
|---|---|---|---|
| **Kubernetes** | Pinniped trusts Dex | `RoleBinding` to a `Group`, to a persona `ClusterRole` | GitOps |
| **OpenBao** | `auth/oidc`, `groups_claim: groups` | external group + group alias (the Dex group string) + policy | Workspace, `vault` provider — RFC-008 `XSecretAccess` with `groups:` |
| **Argo CD** | `oidc.config` pointing at the platform Dex | `AppProject.spec.roles[].groups`; `policy.csv` with `policy.matchMode: regex` | `Object` — RFC-008 `XGitOpsProject` |
| **Grafana** | `[auth.generic_oauth]` | org role through `role_attribute_path`; folder and team permissions | Workspace, `grafana` provider — RFC-008 `XMonitoringFolder` |

Each concept follows the SCM family's shape — a connection kind, one or two resource kinds, a `vendor` field picking the module — and kinds are named by
concept, not product. A kind exists only when a W'xOps workflow needs it, never to mirror a tool's API. Facts from the outside world are mirrored into XR
status by read-only Workspaces (as `XScmConnection`'s `inspect` does), so most policies look up in-cluster objects, not third parties.

---

## AI agents

Agents are personas in the same file, never a special case:

| Task | Persona | Rule |
|---|---|---|
| Audit | `agent-auditor` | Policy reports, audit logs, the effective-access graph; no secret values |
| Debug | `agent-debugger` | Events, logs and status across clusters; no `secrets`, no `exec`, no writes |
| Deploy | **no Kubernetes write at all** | An SCM bot identity, a member of an `XScmTeam`, that opens pull requests — the same gate, review and audit trail as a person |

Kyverno policies pinning agent bindings to the agent persona roles are generated from the persona file like everything else, so widening an agent is a
reviewed change to that file, not a binding slipped in beside it.

### Data boundary and audit

- **An agent is a principal.** Its own identity, its own persona, every action in the same audit pipeline as a person's — "the AI did it" resolves to a name
  in a log.
- **Metadata and payloads are different boundaries.** Statuses, events, manifests and docs may reach any model the platform approves. Payloads — logs with
  user data, traffic, a [Darlane session](darlane.md#session-safety--tools-audit-data-boundary)'s contents — are read only by **in-cluster inference**; an
  external model API is an exfiltration path.
- **Advisory by default.** Findings and diagnoses accelerate a human decision; they are not the decision.
- **Auto-remediation stays gated.** An agent applying its own change is a different trust decision from an agent opening a pull request, and it is not on the
  table until session and agent audit exist.

---

## Audit

Every layer already records the identity; ship them to one place and join on `username` and `groups`:

- Dex and Pinniped — who logged in, with which groups, when;
- the Kubernetes API server audit log — what they did, in which cluster;
- the OpenBao audit device — which paths they read;
- Argo CD and Grafana — syncs and changes;
- Kyverno `PolicyReport`s — every rule result, every concept, one API. Also what an agent reads to explain why something was blocked.

---

## The label foundation

Every Kyverno rule above trusts a label. Today ([inventory](#appendix--labels-and-annotations-in-the-packages-today)) only `wxops.cloud/owner` carries
authorization meaning, and it is not yet trustworthy:

1. **`owner` is a convention.** Required by nothing, immutable by nothing, read by no composition.
2. **It never reaches workloads.** `tenant-app` stamps `environment` and `app-flavor` onto what it composes, not `owner`, so there is nothing on a pod to compare
   with the caller's groups.
3. **It can be forged.** `XTenantApp.spec.parameters.labels` flows into pod labels; the composition's own `wxops.cloud/*` keys win only where it sets them.
   The KCL must set `owner` itself, and a policy must reject any `wxops.cloud/*` key in `spec.parameters.labels`.
4. **`scm.wxops.cloud/oidc-login` is a login gate** writable by anyone who can write an `XScmTeam`. It, and `wxops.cloud/persona`, are platform-only.

Fixing these comes **first** — before any policy enforces.

| Label | Kyverno checks | Reaches |
|---|---|---|
| `wxops.cloud/owner` | required, immutable, the writer is in `<org>:<owner>`, present on workloads | namespace, OpenBao `tenants/<owner>/`, Argo project, Grafana folder |
| `wxops.cloud/environment` | prod changes need a persona that includes prod | Argo destinations, OpenBao capabilities |
| `scm.wxops.cloud/oidc-login` | platform-only | which teams reach the `groups` claim — every tool's login |
| `wxops.cloud/persona` | platform-only; a value from the persona file | the persona table |
| `wxops.cloud/expires-at` | a valid timestamp within the persona's maximum | the `DeletingPolicy` that ends it |

---

## Mediated or projected

[OpenChoreo](https://openchoreo.dev/docs/next/platform-engineer-guide/authorization/overview/) answers the same question the other way: roles and bindings as
CRDs, evaluated by its own API with Apache Casbin, in front of everything users reach. W'xOps projects one definition into each tool's own enforcement.

| | Mediated (OpenChoreo) | Projected (W'xOps) |
|---|---|---|
| Enforcement | one decision point, its API | every system's own |
| How people reach tools | through that API, UI, CLI and MCP | directly: `kubectl`, Grafana, `bao`, Argo |
| Filtering reads | yes, at component level | Kubernetes reads stop at the namespace |
| "Can X do Y?" | ask the enforcer | the compile-time graph |
| Revocation | at once | after convergence |
| A tool's full feature set | only what the API exposes | all of it |

W'xOps's users and agents work in the Kubernetes ecosystem directly, across clusters, so projection fits. The two are not exclusive: Argo CD's `policy.csv`
already *is* Casbin, and the Portal can later be a mediated door for developers — its policy one more output of the same persona compiler.

---

## What W'xOps does not build

- No authorization engine on the request path — the graph is compiled, not queried at runtime.
- No grants created per login — there is no login hook to drive it, and short-lived tokens already make access temporary.
- No third-party writes from admission — Kyverno decides, Crossplane writes.
- No Crossplane Operations as owners of tool configuration while they are alpha and cannot delete.
- No second engine for OpenBao configuration (`provider-vault`, `vault-config-operator`) — the Workspace already runs the same Terraform provider.
- No role mapping inside the identity provider — Dex stays thin; the mapping is Git.
- No composition-emitted Kubernetes RBAC unless an ADR supersedes the [decided rejection](../_archives/ROADMAP.md#decided-and-rejected) — see open decisions.

---

## Known limits

- **Claims are a login-time snapshot.** Leaving a Git team takes effect at the next token; token lifetimes are the lever.
- **Kubernetes reads stop at the namespace.** Admission never sees `get`, `list`, `watch` or `logs`.
- **Projection converges, it is not instant** — Argo sync, Workspace re-plan, `DeletingPolicy` schedule.
- **Gitea team names keep their case** while the owner label is a lowercase slug; the comparison must normalise one side
  ([RFC-005](../rfc/005-git-mapped-authorization.md#what-the-connector-guarantees-today)).

---

## Open decisions

1. **Kubernetes RBAC: GitOps or Crossplane?** GitOps keeps the decided rejection. The alternative is an ADR superseding it: persona `ClusterRole`s stay in
   GitOps, and provider-kubernetes may create **bindings only**, with the `bind` verb restricted by `resourceNames` to the persona roles and no `escalate`.
2. **Namespaced XRs** — [RFC-005](../rfc/005-git-mapped-authorization.md#open-questions) question 1, unchanged.
3. **Token lifetimes** — Dex expiry, Pinniped session length, OpenBao `token_ttl`.
4. **Grafana open source per-team mapping** — Team Sync is listed as Enterprise for some providers; without it, Core manages teams and members itself.
5. **Elevation** — a persona's maximum lifetime, who approves, and whether the request is an XR or a Git file.

---

## Where it lands

| Part | Document | State |
|---|---|---|
| This map | `core-ideas/access-model.md` | this file |
| Where you are | [RFC-003](../rfc/003-scm-connections-and-resources.md) | implemented |
| Who you are | [RFC-004](../rfc/004-dex-identity-and-portal-authentication.md) | implemented |
| Tool configuration engine | [RFC-008](../rfc/008-platform-tools-as-apis.md), broadened to *platform tools as APIs* — secrets, then monitoring, then GitOps | draft, rewritten |
| Personas | a new RFC — the persona file, the compiler, agents, elevation | to write |
| Kubernetes enforcement | [RFC-005](../rfc/005-git-mapped-authorization.md), narrowed — Pinniped, persona roles, Kyverno CEL policies, the label foundation | draft → trim |

**Spikes first**, each able to change the design: Pinniped trusting Dex on one cluster (`kubectl auth whoami`); OpenBao OIDC login with an external group alias
matching `org:team`; `request.userInfo` in a Kyverno CEL `ValidatingPolicy`
([kyverno#15588](https://github.com/kyverno/kyverno/issues/15588)); Grafana open source group-to-team mapping.

**Then:** the label foundation → `XSecretStore` → `XSecretAccess` with `groups:` → the persona compiler with OpenBao as its first target → Pinniped, persona
roles and Kyverno in audit mode → Grafana → Argo CD.

---

## Appendix — labels and annotations in the packages today

| Key | On | Purpose |
|---|---|---|
| `wxops.cloud/owner` | XRs (examples, READMEs) | ownership — convention only, see [the label foundation](#the-label-foundation) |
| `scm.wxops.cloud/oidc-login` | `XScmTeam` | opt the team into `XOIDCConnector`'s generated allow-list |
| `wxops.cloud/managed-by: platform-database-clusters` | `XPlatformDatabaseCluster` | `tenant-database` pool discovery |
| `wxops.cloud/tenant-database` | `XTenantDatabase` (stamped by its KCL) | per-pool database count |
| `crossplane.io/composite` | every XR (stamped by Crossplane) | `oidc-*` packages look up a referenced XR by name |
| `wxops.cloud/environment`, `wxops.cloud/app-flavor` | `tenant-app` workloads | classification |
| `app.kubernetes.io/{name,instance,component,managed-by}` | `tenant-app` workloads | selectors and conventions |
| `wxops.cloud/darlane-ttl` (annotation), `wxops.cloud/darlane-ttl-warning` | Darlane Deployment | lifetime, enforced by `providers/policies/darlane-ttl.yaml` |
| `wxops.cloud/template-id`, `wxops.cloud/repo-url` (annotations) | `tenant-app` resources | catalog links |
| `auth.wxops.cloud/generation`, `auth.wxops.cloud/callback-url` | `oidc-*` internals | rotation trigger; status round-trip — not for policy |
| `crossplane.io/composition-resource-name`, `krm.kcl.dev/ready`, `channel` | compositions | Crossplane plumbing — not for policy |
