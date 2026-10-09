# Your First Change

> A guided edit to `scm-oauth-app`, start to finish: schema, template, test, PR. The field this adds (`notes`) is a deliberately trivial teaching example — it
> wires through every mechanical step without touching Gitea's real API. Don't merge it as-is; it's here so you make the *real* first edit on a copy you
> understand, then apply the same steps to a change that matters.

**Table of Contents**
- [What we're adding](#what-were-adding)
- [1 — Add the field to the schema](#1--add-the-field-to-the-schema)
- [2 — Wire it through the Composition](#2--wire-it-through-the-composition)
- [3 — Update the example and test cases](#3--update-the-example-and-test-cases)
- [4 — Run the suite](#4--run-the-suite)
- [5 — Regenerate goldens, and read the diff](#5--regenerate-goldens-and-read-the-diff)
- [6 — Commit and open a PR](#6--commit-and-open-a-pr)
- [What you just practiced](#what-you-just-practiced)

---

## What we're adding

An optional `notes` string on `XScmOAuthApp`, round-tripped to `status.notes` — no real host behavior, just so you can see a field travel: **schema → patch →
Terraform variable → Terraform output → patch → status**, the same six hops every real field in this repo takes.

`scm-oauth-app` is the simplest package with real HCL to practice on: unlike `scm-repository`, it declares only one Terraform provider (`gitea`) in its module —
GitHub's path is pure variable passthrough, no second provider to keep straight (see [ADR-004](../../development-docs/adr/004-scm-repository-vendor-field.md)
for why `scm-repository` itself needs two full module variants instead of one).

## 1 — Add the field to the schema

`package/scm/oauth-app/xrd.yaml`, alongside the other optional fields under `spec.parameters.properties`:

```yaml
notes:
  type: string
  default: ""
  description: Free-text note. Teaching field — not sent to the host.
```

New optional field, with a default: this is a `safe`-tier change — nothing existing can break. See
[`tests/README.md`](../../tests/README.md#test-api-compat--a-released-api-only-grows) for the full `breaking`/`careful` classification `test-api-compat`
enforces.

## 2 — Wire it through the Composition

`package/scm/oauth-app/composition.yaml`. Three edits, all inside the inline HCL module:

**a. Declare the Terraform variable**, next to the others:
```hcl
variable "notes" {
  type    = string
  default = ""
}
```

**b. Add an output** so it round-trips back out (nothing consumes it — this alone proves the wiring without touching the real `gitea_oauth2_app` resource):
```hcl
output "notes" { value = var.notes }
```

**c. Two patches** — one `FromCompositeFieldPath` into a **new, last** entry in `vars` (append, per [the vars-index
warning](02-opentofu-here.md#how-xr-fields-reach-opentofu-variables) — never insert in the middle), one `ToCompositeFieldPath` back out:

```yaml
# in forProvider.vars, appended after the existing entries:
- key: notes
  value: ""
```
```yaml
# in patches, appended after the existing entries:
- type: FromCompositeFieldPath
  fromFieldPath: spec.parameters.notes
  toFieldPath: spec.forProvider.vars[5].value   # whatever index this new entry landed at

- type: ToCompositeFieldPath
  fromFieldPath: status.atProvider.outputs.notes
  toFieldPath: status.notes
  policy:
    fromFieldPath: Optional
```

This package uses inline HCL, not KCL, so there's no `make kcl-sync` step here. If you were editing `platform-database-clusters`, `tenant-database` or
`tenant-app` instead, you'd edit `kcl/<pkg>/main.k` and run `make kcl-sync` before continuing — see [the sync
step](03-kcl-here.md#the-sync-step--never-forget-this).

## 3 — Update the example and test cases

Optional fields with defaults don't strictly need new cases, but exercise the one you added:

```bash
# examples/scm-oauth-app/xr.yaml — add one line under spec.parameters:
notes: "onboarding cohort 3"
```

Test cases live under `tests/cases/scm-oauth-app/` (`gitea-managed`, `gitea-tenant-path`, `github-observed`); see [Adding a
case](../../tests/README.md#adding-a-case) if you're adding a new one rather than editing `examples/`.

## 4 — Run the suite

```bash
make test-xrd          # your new field validates; nothing existing breaks
make test-api-compat   # confirms this is classified `safe` against the last release
```

## 5 — Regenerate goldens, and read the diff

```bash
make test-update
git diff tests/cases/scm-oauth-app/
```

You should see exactly one new line per affected case: the `notes` variable and output now appear in the rendered `Workspace`. **Read this diff before staging
it — an accepted golden you haven't read is not a test.** If anything *besides* your field changed, stop and find out why before continuing.

```bash
make test    # the full merge gate, green
```

## 6 — Commit and open a PR

```bash
git add package/scm/oauth-app/ examples/scm-oauth-app/ tests/cases/scm-oauth-app/
git commit -m "feat(scm-oauth-app): add optional notes field to XRD v1alpha1"
```

Commit message format and the full PR checklist: [`CONTRIBUTING.md`](../../CONTRIBUTING.md#commit-messages). `pre-commit` runs the same checks locally that CI
runs on the PR — see [pre-commit hooks](../../development-docs/development/README.md#pre-commit-hooks).

**Now revert this teaching change** (`git checkout -- package/scm/oauth-app/ examples/scm-oauth-app/ tests/cases/scm-oauth-app/`) and apply the same six steps
to something real.

## What you just practiced

| Step | The general shape, for any future change |
|---|---|
| 1 | Schema first, in the XRD — optional fields with defaults are always `safe` |
| 2 | Wire it through the template — HCL variable/output + patches, or KCL for the three packages that use it |
| 3–4 | Exercise it in a case, run the fast checks |
| 5 | Regenerate goldens and **read the diff** — this is the step people skip and shouldn't |
| 6 | Conventional commit, `pre-commit`, PR |

This is the loop for every change in this repo, described in full at [the development guide](../../development-docs/development/README.md#the-change-loop).
