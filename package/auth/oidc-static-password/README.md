# oidc-static-password

A local broker user — a bootstrap admin, or a break-glass account — with no Git membership behind
it. The password is never written in Git or an XR field: it is either ESO-generated or read once
from an operator-written OpenBao key, and the bcrypt hash the broker needs is computed inside the
same render that reads it.

## Prerequisites

```bash
kubectl apply -k providers/
```

An [`oidc-connection`](../oidc-connection) whose vendor names the remote-key prefix.

## Install

### From a registry (GitOps)

```bash
kubectl apply -f package/install/auth/oidc-static-password.yaml
```

### For development (direct apply)

```bash
kubectl apply -k package/auth/oidc-static-password
```

## Usage — the bootstrap admin

```yaml
apiVersion: auth.wxops.cloud/v1alpha1
kind: XOIDCStaticPassword
metadata:
  name: admin
spec:
  parameters:
    connectionRef:
      name: dex
    email: admin@wxops.local
    username: admin
    displayName: Platform admin
    groups: ["platform-team:Owners"]
    secret:
      source: static
```

Write the initial password **before** applying the XR — it is the bootstrap secret, so Core never
mints it. Write the **plaintext**, not a hash — Core computes the bcrypt hash itself, so a
pre-hashed value here gets hashed a second time and silently never matches:

```bash
bao kv put -mount=platform dex/users-def/admin password='admin@wxops'
```

Change it (write a new value to the same key, bump `rotation.generation`) once the real identity
providers are in place. See [`examples/oidc-static-password/xr.yaml`](../../../examples/oidc-static-password/xr.yaml).

## `secret.source`

| | `generate` | `static` |
|---|---|---|
| Password comes from | an ESO `Password` generator | an operator-written `<vendor>/users-def/<username>` key, property `password` — **plaintext**, never a hash |
| Plaintext ends up at | `<vendor>/users-def/<username>` — Core pushes `{password, generation}` there for the human to read | already there — the operator wrote it |
| Use for | a break-glass account nobody needs to choose | the first bootstrap admin, or any password you want to set yourself |

Either way, `<vendor>/users/<username>` holds the **record** the broker reads (never the plaintext):
`email`, `username`, `name`, `userID`, `groups`, and a bcrypt `hash`.

## Editing a user vs rotating its password

Two different actions, deliberately kept apart — the password only ever changes when you bump `rotation.generation`:

| You want to… | Do this | What happens |
|---|---|---|
| Change `groups`, `email`, `displayName`, `userId` | edit the XR | Syncs on its own, no bump. The password is untouched; the hash is re-salted (below). |
| **`generate`:** get a new random password | bump `rotation.generation` | The generator runs once; the new password and generation land in `<vendor>/users-def/<username>`, then the record. |
| **`static`:** set a new password | write it to `<vendor>/users-def/<username>`, **then** bump `rotation.generation`, in that order | The record is re-read and re-hashed. |

> [!IMPORTANT]
> **Writing `users-def` by itself changes nothing in `static` mode** — ESO does not poll OpenBao; the bump is what makes the record re-read
> it. In `generate` mode you never write `users-def`: Core does, as `{password, generation}`, so the human copy and the record stay in step.

> [!NOTE]
> **Editing an unrelated field restarts the broker once.** The hash is `bcrypt`, which re-salts on every render, so the record's `hash`
> string differs after any edit even though the password is identical — `dex-config` changes and Dex restarts. Logins are unaffected.

### How it is built

Two `ExternalSecret`s, because ESO refreshes one atomically (every source, the whole template) and a generator or `bcrypt` salt redraws on every
refresh:

- **ESO1 (`generate` only)** owns the secret: `Password` generator → `{password, generation}` → `users-def`. `refreshPolicy: Periodic` with a
  `99999h` interval, refreshed only when its top-level `force-sync` annotation (carrying `rotation.generation`) changes.
- **ESO2 (both modes)** owns the record: reads `password` from `users-def` through a plain `remoteRef`, computes the hash, pushes
  `<vendor>/users/<username>`. `refreshPolicy: OnChange`. In `generate` mode its render fails until `users-def` carries the generation
  the XR asks for, so a bump never settles on the previous password.

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `connectionRef.name` | string | yes | — | The `XOIDCConnection` this user belongs to |
| `email` | string | yes | — | Sign-in identifier |
| `username` | string | yes | — | Display login and this resource's own identifier |
| `displayName` | string | no | `""` | |
| `userId` | string | no | `username` | The broker's stable identifier for this user |
| `groups` | []string | no | `[]` | Claim groups — independent of any `XScmTeam` |
| `secret.source` | string | yes | — | `generate` or `static` |
| `secret.generator` | object | no | `{length: 32, digits: 8, symbols: 0}` | `generate` only |
| `rotation.generation` | int | no | `1` | Bump to rotate |

## Status

| Field | Description |
|---|---|
| `created` / `ready` | Standard contract |
| `synced` / `syncMessage` | `synced` is false while a composed resource's last apply failed (its `Ready` can stay True from the earlier success); `syncMessage` is the provider's message, truncated. Absent until the first reconcile |
| `userId` | The resolved userId |
| `vaultKey` | Where the record (not the password) was pushed |

Full reference: [`docs/api-reference/oidc-static-password.md`](../../../docs/api-reference/oidc-static-password.md).

## Build and publish

```bash
crossplane xpkg build \
  -f package/auth/oidc-static-password \
  --ignore kustomization.yaml

crossplane xpkg push \
  ghcr.io/wxops-idp/wxops-core/oidc-static-password:release-YYYY-MM-DD \
  -f oidc-static-password.xpkg
```
