# W'xOps Core - KCL Module

`platform-database-clusters`, `tenant-database`, and `tenant-app` use [`function-kcl`](https://github.com/crossplane-contrib/function-kcl) instead of `function-go-templating`. The other packages (`gitea-*`, `random-password`) are simple enough that inline HCL / Go templating is sufficient.

## Why KCL instead of Go templating

Go templating is a good fit when a Composition is "render this one manifest from these fields" — straightforward substitution with light `if`/`range`. It gets painful once a Composition needs to:

- **Conditionally assemble a variable-length list of resources** (e.g. only add a `ScheduledBackup`, RO `Pooler`, or per-role ESO bundle when a feature flag/array is set).
- **Merge maps conditionally** without clobbering keys — KCL's `|` dict-merge operator (`base | ({"managed": {...}} if managedRoles else {})`) replaces a tangle of `{{- if }}`/`{{- with }}` blocks.
- **Derive many names/values from a few inputs** and reuse them across several resources (e.g. `c`, `pwdSecretName`, `endpoint`, `vaultPath` all derived from `clusterName` once, then referenced everywhere).
- **Generate per-item resource sets from an array** via list comprehensions (`[... for r in managedRoles]`) — each `managedRoles[]` entry fans out into a Generator + ExternalSecret + PushSecret + a `spec.managed.roles[]` entry.
- **Apply typed defaults** with `params.get("key", default)` instead of template `default` functions scattered everywhere.

In short: reach for `function-go-templating` for small, mostly-static manifests; reach for `function-kcl` once a Composition has real branching/looping logic across multiple resources, as `platform-database-clusters` and `tenant-database` do.

## Directory layout & sync workflow (current — inline embedding)

```
kcl/{pkg}/
  kcl.mod      ← KCL module metadata (name, version, dependencies)
  main.k       ← authoritative composition source
package/{pkg}/
  composition.yaml  ← spec.source: | block is a generated copy of kcl/{pkg}/main.k
```

`kcl/{pkg}/main.k` is the **single source of truth**. `package/{pkg}/composition.yaml` embeds a copy of it inline inside the `function-kcl` pipeline step's `KCLInput.spec.source` block, because `crossplane xpkg build` only packages the Configuration directory — it can't reach outside into `kcl/`.

To pick up changes after editing `main.k`:

```bash
make kcl-sync     # re-embed kcl/{pkg}/main.k into package/{pkg}/composition.yaml
make kcl-check    # fail if composition.yaml has drifted from kcl/{pkg}/main.k
```

`.gitea/scripts/kcl-sync.py` does the splicing (splits `composition.yaml` on the `source: |` marker, re-indents `main.k`, and replaces everything after it). A pre-commit hook (`kcl-drift-check`) runs `make kcl-check` automatically, so always run `make kcl-sync` and commit **both** `kcl/{pkg}/main.k` and `package/{pkg}/composition.yaml` together.

## Wiring a KCL module into an XRD

1. **Define the schema** in `package/{pkg}/xrd.yaml` under `spec.versions[].schema.openAPIV3Schema.properties.spec.properties.parameters` — this becomes `option("params").oxr.spec.parameters` inside KCL.
2. **Write `kcl/{pkg}/main.k`**:
   - Read inputs: `oxr = option("params").oxr`, `params = oxr.spec.parameters`.
   - Derive names/flags, build one variable per desired resource (each wrapped as a `kubernetes.crossplane.io/v1alpha2 Object` with `spec.forProvider.manifest`).
   - Assemble the final `items = [...]` list (the resources the Composition produces).
3. **Wire the pipeline** in `package/{pkg}/composition.yaml`:
   ```yaml
   spec:
     mode: Pipeline
     pipeline:
       - step: render
         functionRef:
           name: function-kcl
         input:
           apiVersion: krm.kcl.dev/v1alpha1
           kind: KCLInput
           metadata:
             name: render
           spec:
             source: |
               # contents of kcl/{pkg}/main.k go here (kept in sync via kcl-sync)
   ```
   If the KCL code reads extra resources (e.g. `tenant-database` discovers shared clusters), add a `function-extra-resources` step **before** the `function-kcl` step — the fetched resources appear in `option("params").extraResources` inside KCL. See `package/platform/tenant-database/composition.yaml` for an example.
4. **Run `make kcl-sync`** to embed the source, then `make kcl-check` (or `pre-commit run --all-files`) to confirm it's in sync.
5. **Validate** with `make render` against an example XR in `examples/{pkg}/xr.yaml`, and `make build` to confirm the package still packages cleanly.

## Future: KCL OCI modules (deferred)

> **Status: future.** Revisit when there are 3+ KCL packages sharing helper functions, or when a single `main.k` exceeds ~300 lines and becomes hard to navigate inside `composition.yaml`.

The inline-embedding approach above (kcl-sync) works well for independent per-package logic, but breaks down when:

- Multiple packages share helper functions (e.g. "build an ESO PushSecret manifest" or "build a provider-kubernetes `Object` wrapper").
- You want to `import` a shared schema/type across packages without copy-pasting.
- The inline `source:` block in `composition.yaml` becomes too large to navigate in the Crossplane CR view.

`function-kcl` (v0.10+) supports loading KCL source from an OCI artifact instead of an inline string:

```yaml
spec:
  source: "oci://ghcr.io/wxops-idp/kcl-platform-database-clusters:v0.2.0"
```

The function pulls the OCI artifact at reconcile time (or from its local cache) and runs it. The artifact is a standard KCL module packaged with `kcl mod push`.

**Layout after migration:**

```
kcl/
  lib/                          ← shared library module (new)
    kcl.mod
    eso.k                       ← helper fns: eso_password(), push_secret(), ...
    k8s_object.k                ← helper fn: k8s_object(manifest) wrapper
  platform-database-clusters/
    kcl.mod                     ← adds lib as a dependency
    main.k                      ← imports lib, much shorter
  tenant-database/
    kcl.mod
    main.k
```

`kcl/lib/kcl.mod`:
```toml
[package]
name = "wxops-kcl-lib"
version = "0.1.0"
edition = "v0.10.0"
```

`kcl/platform-database-clusters/kcl.mod` after adding the dependency:
```toml
[package]
name = "platform-database-clusters"
version = "0.2.0"
edition = "v0.10.0"

[dependencies]
wxops_lib = { oci = "oci://ghcr.io/wxops-idp/kcl-lib", tag = "v0.1.0" }
```

`kcl/platform-database-clusters/main.k` after migration:
```python
import wxops_lib.eso as eso
import wxops_lib.k8s as k8s

params = option("params").oxr.spec.parameters
# ... 30 lines instead of 250
items = [
    k8s.object(eso.password_generator(...)),
    k8s.object(eso.external_secret(...)),
    ...
]
```

**Build pipeline changes required** — a second publish pipeline alongside the existing Crossplane xpkg one, e.g. `.gitea/workflows/publish-kcl-modules.yaml` triggered on `kcl/**` changes / `kcl/v*` tags, running `kcl mod push` for `lib` and each package module. After this, `composition.yaml`'s `source:` field points at the OCI reference instead of inline source, and `kcl-sync` / `kcl-drift-check` become unused and can be removed.

**Version coordination** — three axes once on OCI modules:
1. **Crossplane package version** — `VERSIONS.yaml`, governs the `.xpkg` OCI image.
2. **KCL module version** — `kcl/{pkg}/kcl.mod`, governs the `.k` OCI artifact.
3. **KCL lib version** — `kcl/lib/kcl.mod`, shared dependency version.

A Composition references a specific KCL module tag; if the module changes but the Composition isn't updated, the cluster keeps using the old module. This decoupling is a feature (hot-patch KCL logic without rebuilding the Crossplane package) but needs tagging discipline — **bump the KCL module tag and the Composition's `source:` reference in the same commit**, and have CI validate the referenced tag exists before merging.

**When NOT to migrate** — fewer than ~4 KCL packages (no reuse benefit yet), Compositions still under ~200 lines of KCL (inline is readable), or no bandwidth to run a second build pipeline. The current inline + `kcl-sync` setup is stable and correct; there's no urgency.

## Reference

- [KCL Introduction](https://www.kcl-lang.io/docs/user_docs/getting-started/intro)
- [Function KCL](https://github.com/crossplane-contrib/function-kcl)
