# persona-binding

Binds an [`XPersona`](../persona)'s subjects to one ClusterRole: a `RoleBinding` in every namespace a team owns, or one `ClusterRoleBinding` for the Platform API.
**The only composition in this repository allowed to emit RBAC, and only bindings** — never a `Role` or `ClusterRole`, never `cluster-admin`; provider-kubernetes
holds `bind` on exactly the roles this package accepts. See [RFC-009](../../../development-docs/rfc/009-scm-personas.md).

## Prerequisites

```bash
kubectl apply -k providers/        # includes the static roles: providers/rbac/aggregate-persona.yaml, aggregate-platform.yaml (or just: make providers-rbac)
```

An [`XPersona`](../persona). For `scope: owned`, tenant namespaces labelled `auth.wxops.cloud/tenant-namespace: "true"` and `wxops.cloud/owner: <team>`.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/auth/persona-binding.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/auth/persona-binding
```

## Usage

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersonaBinding
metadata:
  name: developers-edit
spec:
  parameters:
    personaRef:
      name: developers
    role: wxops:persona-developers
```

`wxops-idp:payment` is then bound in `payment`'s namespaces, and only there. Examples: [`examples/persona-binding/`](../../../examples/persona-binding).

## Parameters

See [`docs/api-reference/persona-binding.md`](../../../docs/api-reference/persona-binding.md).

## Build and publish

CI builds and pushes this package on a `release-*` tag; see [`development-docs/development/releasing.md`](../../../development-docs/development/releasing.md).
