# XPersonaBinding

Binds an [`XPersona`](persona.md)'s subjects to one `ClusterRole`. Kubernetes RBAC then decides which kinds those subjects can reach; an
[`XPlatformPolicy`](platform-policy.md) narrows which objects. Design: [RFC-009](../../../development-docs/rfc/009-scm-personas.md).

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XPersonaBinding` |
| **Plural** | `xpersonabindings` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/persona-binding/`](../../../package/auth/persona-binding) — see [`VERSIONS.yaml`](../../../VERSIONS.yaml) for the current package version |

> [!IMPORTANT]
> This is the **only** composition that emits RBAC, and only `RoleBinding` and `ClusterRoleBinding` — to the roles in the table below. `cluster-admin` is never
> bindable, a `Role` or `ClusterRole` is never composed, and provider-kubernetes holds `bind` on exactly these names
> ([`providers/rbac/provider-kubernetes.yaml`](../../../providers/rbac/provider-kubernetes.yaml)). Roles are static manifests under
> [`providers/rbac/aggregate-*.yaml`](../../../providers).

## spec.parameters

| Field | Type | Default | Notes |
|---|---|---|---|
| `personaRef.name` | `string` | — (required) | The `XPersona` whose `status.subjects` are bound |
| `role` | `string` | — (required) | One of the roles below |
| `scope` | `owned` \| `namespaces` \| `platform` | `owned` | Where the role is granted |
| `namespaces` | `[string]` | `[]` | For `scope: namespaces` |

### Roles

| Role | Built from | Bind with |
|---|---|---|
| `view` | Kubernetes' own, plus every `ClusterRole` labelled `rbac.authorization.k8s.io/aggregate-to-view` — reads, no Secrets | `owned`, `namespaces` |
| `wxops:persona-viewers` | `view`, plus pieces labelled `auth.wxops.cloud/aggregate-to-persona-viewers` | `owned`, `namespaces` |
| `wxops:persona-developers` | `view`, plus the write pieces: workloads (Deployments, StatefulSets, Jobs, CronJobs, Services, ConfigMaps, PVCs, Ingresses, HPAs, PDBs, `pods` `delete`) and the operator kinds tenants write (`ExternalSecret`, `Certificate`, Traefik `IngressRoute`/`Middleware`, `ServiceMonitor`/`PodMonitor`) | `owned`, `namespaces` |
| `wxops:persona-owners` | as developers, plus `pods/exec`, `pods/attach`, `pods/portforward` — narrowed by the `exec-guard` policy | `owned`, `namespaces` |
| `wxops:persona-platform` | `admin`, plus pieces labelled `auth.wxops.cloud/aggregate-to-persona-platform` | `owned`, `namespaces` |
| `wxops:platform-view` · `-edit` · `-admin` | pieces labelled `auth.wxops.cloud/aggregate-to-platform-<level>` — W'xOps kinds only | `platform` |

**No team persona is built on the built-in `edit` or `admin`, and neither is bindable.** Both grant `impersonate` on ServiceAccounts and
`create serviceaccounts/token`: a person holding them acts as any ServiceAccount in the namespace, holds that account's permissions, and — arriving as
`system:serviceaccount:…` — is matched by no [`XPlatformPolicy`](platform-policy.md). So team personas read through `view` and write only through the
pieces in [`providers/rbac/aggregate-persona.yaml`](../../../providers/rbac/aggregate-persona.yaml): no ServiceAccounts, Secrets, Roles, RoleBindings or Pods
by hand. Only `wxops:persona-platform` keeps `admin`. An invariant in `tests/invariants.py` keeps it that way.

Adding a permission to a persona is one small `ClusterRole` carrying one label; every persona bound to that role gains it. See
[`providers/rbac/examples/`](../../../providers/rbac/examples).

### Scopes

| `scope` | Renders | Subjects |
|---|---|---|
| `owned` | a `RoleBinding` in every namespace labelled `auth.wxops.cloud/tenant-namespace: "true"` | only the persona's **groups whose team is that namespace's `wxops.cloud/owner`** — group `<org>:payment` in `payment`'s namespaces, never in `checkout`'s. Users and ServiceAccounts have no team, so they are not bound here |
| `namespaces` | a `RoleBinding` in each listed namespace | every subject |
| `platform` | one `ClusterRoleBinding` | every subject; only with a `wxops:platform-*` role |

The XRD rejects an invalid combination (a `wxops:platform-*` role without `scope: platform`, `scope: platform` with any other role, `namespaces` without
`scope: namespaces`). The composition refuses it too — nothing rendered, `synced: false`, the reason in `syncMessage` — so a bypassed rule never reaches the API
server.

Owner matching is exact, with no case folding: use slug-form team names (`a-z0-9-`) on every vendor
([RFC-005](../../../development-docs/rfc/005-git-mapped-authorization.md#open-questions), question 11).

## status

| Field | Meaning |
|---|---|
| `created` | `true` once every binding has been applied at least once; absent until then |
| `ready` | `true` when every binding is applied and in sync |
| `synced`, `syncMessage` | `false` with the reason while a binding failed to apply, or the persona or parameters cannot be resolved |
| `bindings` | Every binding rendered — kind, name, namespace, and how many subjects it carries |

A `RoleBinding`'s `roleRef` cannot change, so the role is part of every binding's name: changing `role` replaces the binding rather than failing to update it.

### Many namespaces, and the "Circuit breaker is open" log

Every namespace is one composed `Object`, and each `Object` changes status a few times while it is first applied. Crossplane keeps a per-XR circuit breaker against
reconciliation thrashing (defaults: burst 100, refill 1 event/s, cooldown 5m), and a binding that fans out to many namespaces can briefly exceed that burst at
creation. Crossplane then logs `Circuit breaker is open` for the XR about once a minute and stops reacting to each event, falling back to its normal poll.

This is a log line, not a failure. `status.ready`, `status.synced` and `status.bindings` are derived from the observed composed resources on every reconcile, so they
stay accurate while the native `Ready` condition lags, and the bindings are applied as usual. Nothing needs changing unless the XR's `Responsive` condition is
`False` with reason `WatchCircuitOpen` and stays that way. Then watch the `Object` its message names (`kubectl get object <name> --output-watch-events --watch-only`)
to find what keeps changing it. Raising `--circuit-breaker-burst`, `--circuit-breaker-refill-rate` or `--circuit-breaker-cooldown` on Crossplane
([troubleshooting guide](https://docs.crossplane.io/latest/guides/troubleshoot-crossplane/#circuit-breaker-for-reconciliation-thrashing)) is the last resort.

## Example

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersonaBinding
metadata:
  name: viewers-platform-view
spec:
  parameters:
    personaRef:
      name: viewers
    role: wxops:platform-view
    scope: platform
```

More bindings — one per default persona, and each scope:

```yaml
# The Platform API, cluster-wide: read every W'xOps kind. Core kinds are cluster-scoped today, so this is a ClusterRoleBinding — which is why it accepts
# wxops:platform-* roles only; ownership of each XR is sealed by an XPlatformPolicy, not by this binding.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersonaBinding
metadata:
  name: viewers-platform-view
spec:
  parameters:
    personaRef:
      name: viewers
    role: wxops:platform-view
    scope: platform
```

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersonaBinding
metadata:
  name: owners-admin
spec:
  parameters:
    personaRef:
      name: owners
    role: wxops:persona-owners
```

```yaml
# The platform team: the whole Platform API, and admin in the namespaces it supports.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersonaBinding
metadata:
  name: platform-admin
spec:
  parameters:
    personaRef:
      name: platform
    role: wxops:platform-admin
    scope: platform
```

```yaml
# The platform team in the namespaces it supports — admin there, by RoleBinding, not cluster-wide.
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersonaBinding
metadata:
  name: platform-namespaces
spec:
  parameters:
    personaRef:
      name: platform
    role: wxops:persona-platform
    scope: namespaces
    namespaces: [shared-tools, observability]
```
