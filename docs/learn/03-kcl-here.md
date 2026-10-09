# KCL, the Way This Repo Uses It

> This is not a KCL tutorial — for the language itself, see the
> [KCL introduction](https://www.kcl-lang.io/docs/user_docs/getting-started/intro). This page covers
> the idioms this repo actually leans on, walking real slices of
> `kcl/platform-database-clusters/main.k` — not the whole 800-line file.

**Table of Contents**
- [Why KCL exists here at all](#why-kcl-exists-here-at-all)
- [Reading the inputs](#reading-the-inputs)
- [The `_get` helper, and why `.get()` doesn't work](#the-_get-helper-and-why-get-doesnt-work)
- [Conditionals: no if/elif/else for values](#conditionals-no-ifelifelse-for-values)
- [Composing a resource conditionally](#composing-a-resource-conditionally)
- [The output: a plain list of items](#the-output-a-plain-list-of-items)
- [The sync step — never forget this](#the-sync-step--never-forget-this)
- [Next](#next)

---

## Why KCL exists here at all

`platform-database-clusters`, `tenant-database` and `tenant-app` need real logic: compose a
`Pooler` only if pooling is on, a `ScheduledBackup` only if backups are configured, a variable-length
list of Secrets for a variable-length list of managed roles. `function-patch-and-transform` (the
Terraform packages' technique — [see here](02-opentofu-here.md)) has no branching or looping;
`function-kcl` does. That's the entire reason two techniques coexist in this repo — not a
preference, a capability gap. Full reasoning: [`kcl/README.md`](../../kcl/README.md).

## Reading the inputs

Every KCL file starts the same way:

```python
oxr = option("params").oxr
params = oxr.spec.parameters
```

`oxr` is the XR as Crossplane observed it — `oxr.spec.parameters` is exactly what the XRD schema
under `spec.parameters` describes, and `oxr.metadata` carries name, labels, and so on.

## The `_get` helper, and why `.get()` doesn't work

Every KCL file in this repo defines the same small helper near the top:

```python
_get = lambda d: any, k: str, default: any -> any {
    _safe = d or {}
    _safe[k] if k in _safe else default
}
```

**Use it instead of `params.get("key", default)`.** The reason is specific to this pipeline: for a
field the XRD *declares* but the XR leaves *unset*, `function-kcl` hands you `Undefined`, not
`None` — and `dict.get()` does not fall back to its default for that. `_get(d, "key", default)`
does, because `k in _safe` is checked explicitly. This bites hardest on nested objects: if a whole
block like `spec.parameters.monitoring` is optional and the XR omits it, `oxr.spec.parameters` still
has a `monitoring` key, but the value is `Undefined`, not `{}` — so `_get(monitoring, "enabled",
False)` needs the `d or {}` guard too, which is why the helper has it.

## Conditionals: no if/elif/else for values

KCL has no `if/elif/else` statement for assigning a value — only a ternary, chained:

```python
poolMode = "session" if params.poolMode == "session" else "transaction" if params.poolMode == "transaction" else "transaction"
```

You'll see this shape constantly. It reads oddly at first; it's the only tool KCL gives you here.

## Composing a resource conditionally

This is the core idiom — a real slice from `platform-database-clusters`, composing a `ScheduledBackup`
only when backups are enabled:

```python
backupEnabled = _get(_bkp, "enabled", False)

_scheduled_backup = {
    apiVersion = "kubernetes.crossplane.io/v1alpha2"
    kind = "Object"
    metadata.annotations = {
        "crossplane.io/composition-resource-name" = c + "-scheduled-backup"
    }
    spec.forProvider.manifest = {
        apiVersion = "postgresql.cnpg.io/v1"
        kind = "ScheduledBackup"
        metadata = {name = c + "-backup", namespace = ns}
        spec = {
            schedule = _bkpSchedule
            backupOwnerReference = "self"
            cluster = {name = c}
            method = "barmanObjectStore"
        }
    }
}
```

Then, in the final items list (see below), this whole object is only included with
`+ ([_scheduled_backup] if backupEnabled else [])` — an empty list contributes nothing, so the
resource simply doesn't exist unless the condition holds. **Every conditional resource in this repo
follows this exact shape:** define the object unconditionally, then gate its presence in the list
with `if … else []`.

Two details that matter operationally:
- **Every composed resource wraps as a `kubernetes.crossplane.io/v1alpha2 Object`**, with the real
  manifest nested under `spec.forProvider.manifest`. That's `provider-kubernetes`'s CRD — it's how
  KCL compositions create anything that isn't itself a nested XR.
- **`crossplane.io/composition-resource-name` is the identity Crossplane tracks.** Change this
  string on a resource that already exists in production, and Crossplane sees a delete-and-recreate,
  not a rename — `test-api-compat` catches this before it ships; see
  [`tests/README.md`](../../tests/README.md#test-api-compat--a-released-api-only-grows).

## The output: a plain list of items

KCL's composition functions expect the file to evaluate to a list of these wrapped objects, built
with the same `[...] if cond else []` pattern all the way down:

```python
[_cnpg_cluster] + _managed_role_gens
  + ([_cnpg_rw_pooler] if poolerEnabled else [])
  + ([_cnpg_ro_pooler] if roPoolerEnabled else [])
  + ([_scheduled_backup] if backupEnabled else [])
```

That's the entire file's job: build every possible resource, then concatenate only the ones whose
condition holds.

## The sync step — never forget this

`kcl/<pkg>/main.k` is what you edit. `package/<pkg>/composition.yaml` embeds a **copy** of it inline,
because `crossplane xpkg build` only packages the `package/` directory. After editing `main.k`:

```bash
make kcl-sync     # re-embed main.k into composition.yaml
make kcl-check    # fail if they've drifted — this also runs as a pre-commit hook
```

Commit both files together, always. Full detail: [`kcl/README.md`](../../kcl/README.md).

## Next

- [Crossplane in five minutes](01-crossplane-in-5-minutes.md), if you haven't yet
- [Your first change](04-your-first-change.md) walks the Terraform side end to end; the KCL loop is
  identical except for this sync step
