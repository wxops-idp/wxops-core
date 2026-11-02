# XPersonaBinding

Binds an [`XPersona`](persona.md)'s subjects to one `ClusterRole`. Kubernetes RBAC then decides which kinds those subjects can reach; an
[`XPlatformPolicy`](platform-policy.md) narrows which objects. Design: [RFC-009](../../development-docs/rfc/009-scm-personas.md).

| | |
|---|---|
| **Group** | `auth.wxops.cloud` |
| **Kind** | `XPersonaBinding` |
| **Plural** | `xpersonabindings` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/auth/persona-binding/`](../../package/auth/persona-binding) — see [`VERSIONS.yaml`](../../VERSIONS.yaml) for the current package version |

> [!IMPORTANT]
> This is the **only** composition that emits RBAC, and only `RoleBinding` and `ClusterRoleBinding` — to the roles in the table below. `cluster-admin` is never
> bindable, a `Role` or `ClusterRole` is never composed, and provider-kubernetes holds `bind` on exactly these names
> ([`providers/rbac/provider-kubernetes.yaml`](../../providers/rbac/provider-kubernetes.yaml)). Roles are static manifests under
> [`providers/rbac/aggregate-*.yaml`](../../providers).

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
| `view`, `edit`, `admin` | Kubernetes' own, plus every `ClusterRole` labelled `rbac.authorization.k8s.io/aggregate-to-*` | `owned`, `namespaces` |
| `wxops:persona-viewers` · `-developers` · `-owners` · `-platform` | the same standard pieces, plus pieces labelled `auth.wxops.cloud/aggregate-to-persona-<name>` | `owned`, `namespaces` |
| `wxops:platform-view` · `-edit` · `-admin` | pieces labelled `auth.wxops.cloud/aggregate-to-platform-<level>` — W'xOps kinds only | `platform` |

Adding a permission to a persona is one small `ClusterRole` carrying one label; every persona bound to that role gains it. See
[`examples/rbac-aggregate/`](../../examples/rbac-aggregate).

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
([RFC-005](../../development-docs/rfc/005-git-mapped-authorization.md#open-questions), question 11).

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

More: [`examples/persona-binding/`](../../examples/persona-binding).
