# policy

`XPolicy` replaces [`XPlatformPolicy`](../archives/platform-policy) (ADR-005): the same rules, the same templates, a name that does not repeat the group. `XPlatformPolicy` is archived: every XR moved by the handover in [migrating to the new kinds](../../../docs/user-guide/migrating-to-new-kinds.md), kept for the record.

Renders **one reviewed Kyverno CEL policy per resource** — `owner-stamp`, `owner-seal`, `secret-guard`, `exec-guard`, `protected`, `rbac-guard`, `sa-guard`, `namespace-guard` or `env-gate` — that narrows what
RBAC already grants. A policy matches **SCM users only** (a caller with a `<org>:<team>` group, never a `system:` username), so controllers, Crossplane, External Secrets
Operator and Argo CD are never matched. Kyverno refuses; it never grants. Policies run in `Deny` by default, failing closed; `Audit` is not supported yet. See [RFC-009](../../../development-docs/rfc/009-scm-personas.md)
and [RFC-005](../../../development-docs/rfc/005-git-mapped-authorization.md).

## Prerequisites

```bash
kubectl apply -k providers/        # includes provider-kubernetes's grant on policies.kyverno.io
```

The Kyverno controller (v1.19+), installed with the cluster — a bootstrap prerequisite, not installed by W'xOps. An [`XPersona`](../persona) for the templates that name one
(`exec-guard`, and `exemptPersonaRef` on any).

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/auth/policy.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/auth/policy
```

## Usage

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPolicy
metadata:
  name: owner-seal
spec:
  parameters:
    template: owner-seal
    scmOrgs: [wxops-idp]
    exemptPersonaRef:
      name: platform
```

Check what it rendered: `kubectl get xpolicy owner-seal` shows `READY` and, if it could not render, `syncMessage`.

Examples, one per template: [`examples/auth/policy/`](../../../examples/auth/policy).

## Parameters

See [`docs/api-reference/auth/policy.md`](../../../docs/api-reference/auth/policy.md).

## Build and publish

CI builds and pushes this package on a `release-*` tag; see [`development-docs/development/releasing.md`](../../../development-docs/development/releasing.md).
