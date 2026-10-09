# Crossplane in Five Minutes

> Four concepts, walked through one real package — `scm-connection`, the smallest in this repo. By the
> end you'll be able to point at any file in `package/scm/connection/` and say what it's for.

**Table of Contents**
- [The four pieces](#the-four-pieces)
- [Walking scm-connection](#walking-scm-connection)
- [What actually runs this](#what-actually-runs-this)
- [Next](#next)

---

## The four pieces

Crossplane lets you define your own Kubernetes API, then wire it to real infrastructure. Four
things make that up:

| Piece | What it is | In this repo |
|---|---|---|
| **XRD** (`CompositeResourceDefinition`) | The schema — what fields your API accepts | `package/<group>/<name>/xrd.yaml` |
| **XR** (composite resource) | An instance of that API — the thing a user creates | `examples/<name>/xr.yaml` |
| **Composition** | The template that says what to build for a given XR | `package/<group>/<name>/composition.yaml` |
| **Composed resource** | What the Composition actually creates — a real object in the cluster | Not a file; it exists only at runtime |

You write the first three. Crossplane's reconcile loop produces the fourth, continuously, for as
long as the XR exists.

## Walking scm-connection

**1. The XRD defines the shape.** Open `package/scm/connection/xrd.yaml`. It declares a `Kind`
(`XScmConnection`) and a schema under `spec.parameters` — `vendor`, `baseUrl`, `org`, `access`, and so
on. This is a real Kubernetes CRD once installed; `kubectl explain xscmconnections.spec.parameters`
reads straight from it.

**2. An XR is one instance of that shape.** `examples/scm-connection/xr.yaml` is about a dozen lines: a
`kind: XScmConnection` with values for the fields the XRD declared. Applying it is exactly like
applying any other Kubernetes object — `kubectl apply -f examples/scm-connection/xr.yaml`.

**3. The Composition says what to build.** Open `package/scm/connection/composition.yaml`. Strip away
the YAML wrapper and it says, in effect: *"for an `XScmConnection`, create one `Object` wrapping an
ESO `ExternalSecret`, with these fields patched in from the XR."* That's it — one composed
resource, one patch list. Bigger packages (`tenant-app`) compose a dozen resources conditionally;
the mechanism is identical, just longer.

**4. Crossplane keeps it that way.** Once you apply the XR, Crossplane doesn't just run this once —
it reconciles continuously. Change the XR, and the Composition re-renders and patches the
`ExternalSecret` in place. Delete the XR, and the rendered Secret is deleted too.

```mermaid
flowchart LR
    XRD["xrd.yaml<br/>defines the schema"] -.->|"validates"| XR["xr.yaml<br/>an instance"]
    XR --> COMP["composition.yaml<br/>the template"]
    COMP --> OBJ["ExternalSecret<br/>(the composed resource)"]
    OBJ --> REAL["ESO renders it<br/>→ a real Secret, tfvars-shaped"]
```

## What actually runs this

Two more names worth knowing:

- **Provider** — the thing that talks to the outside world. `provider-kubernetes` creates the plain
  Kubernetes object here (the `ExternalSecret` itself); `provider-opentofu` runs an HCL module for
  packages that need one (`scm-repository`, `scm-oauth-app`); `provider-sql` runs SQL against a
  database. This repo's packages use one or more of these; see each package's `crossplane.yaml`
  `dependsOn` list.
- **Function** — the thing that decides what to compose, for a given XR. `scm-connection` uses
  `function-patch-and-transform` — a static list of resources plus field patches, no real logic.
  Bigger packages use `function-kcl` — a real language, for when the resource list depends on
  conditions. That's the whole reason two techniques exist in this repo; see
  [KCL, the way this repo uses it](03-kcl-here.md).

## Next

- Touching a `scm-*` package? → [OpenTofu and HCL, the way this repo uses them](02-opentofu-here.md)
- Touching `platform-database-clusters`, `tenant-database` or `tenant-app`? →
  [KCL, the way this repo uses it](03-kcl-here.md)
- Ready to make a real edit? → [Your first change](04-your-first-change.md)
