# persona

A persona is a title that collects who it applies to — SCM teams, hand-listed groups and users, and in-cluster agents — and the environments it applies on. It
**grants nothing** and composes no resource: it resolves its members into `status.subjects`, in the exact shape of an RBAC subject, for
[`persona-binding`](../persona-binding) and [`platform-policy`](../archives/platform-policy) to read. See [RFC-009](../../../development-docs/rfc/009-scm-personas.md).

## Prerequisites

```bash
kubectl apply -k providers/
```

Only if members come from teams: `XScmTeam`s ([`scm-team`](../../scm/team)) labelled `scm.wxops.cloud/oidc-login: "true"`, so they can sign in.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/auth/persona.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/auth/persona
```

## Usage

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XPersona
metadata:
  name: developers
spec:
  parameters:
    description: Builds and deploys outside production
    environments: [dev, staging]
```

A team joins by a label on its `XScmTeam` — one label per persona, so a team can be in several:

```yaml
labels:
  scm.wxops.cloud/oidc-login: "true"
  auth.wxops.cloud/persona-developers: "true"
```

`status.subjects` then lists the team's `oidcGroup`. Examples: [`examples/auth/persona/`](../../../examples/auth/persona).

## Parameters

See [`docs/api-reference/auth/persona.md`](../../../docs/api-reference/auth/persona.md).

## Build and publish

CI builds and pushes this package on a `release-*` tag; see [`development-docs/development/releasing.md`](../../../development-docs/development/releasing.md).
