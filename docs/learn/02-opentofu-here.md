# OpenTofu and HCL, the Way This Repo Uses Them

> This is not an OpenTofu tutorial — for the language itself, see [OpenTofu's own docs](https://opentofu.org/docs/language/). This page covers only the one
> pattern this repo uses, walking the real file `package/scm/repository/composition.yaml`. The language is HCL, the same one Terraform reads; what differs
> between the two engines is covered in the first section — and it's less than it sounds: OpenTofu is a drop-in-compatible fork, so nothing about the HCL itself
> changes.

**Table of Contents**
- [The pattern: one Workspace, inline HCL](#the-pattern-one-workspace-inline-hcl)
- [Reading the module](#reading-the-module)
- [How XR fields reach OpenTofu variables](#how-xr-fields-reach-opentofu-variables)
- [How OpenTofu outputs become status](#how-opentofu-outputs-become-status)
- [Where credentials come from](#where-credentials-come-from)
- [Next](#next)

---

## The pattern: one Workspace, inline HCL

Every package of this kind composes exactly one object: a `Workspace`. Its `spec.forProvider.module` field holds an **entire module as a YAML string literal**.
There's no separate `.tf` file and no `init` you run yourself: the provider runs the whole plan/apply cycle inside the cluster, against the module text in that
field.

Every active package uses one engine — **OpenTofu** (`provider-opentofu`, `opentofu.upbound.io/v1beta1 Workspace`). The HCL itself is unaffected: OpenTofu is a
drop-in syntax-compatible fork of Terraform (forked at the last MPL-2.0 release, kept a superset since), so migrating a module between the two engines is an
`apiVersion` change on the Workspace, nothing in the HCL body — see [ADR-003](../../development-docs/adr/003-opentofu-workspace-engine.md) for why this repo
runs OpenTofu rather than Terraform, and [RFC-002](../../development-docs/rfc/002-migrate-terraform-to-opentofu.md) for how the migration went.
`provider-terraform` and the `tf.upbound.io/v1beta1 Workspace` kind still exist in this repo's history — `providers/archive/` — but nothing active runs on them
any more.

That's the whole pattern. No package in this repo runs a real CLI outside the cluster, and none references an external module registry.

## Reading the module

Open `package/scm/repository/composition.yaml`. Inside `spec.forProvider.module`, it's ordinary HCL (trimmed here to the shape — the real module also handles
`observed` mode and a second vendor; see [ADR-004](../../development-docs/adr/004-scm-repository-vendor-field.md) for why there are two full module variants
rather than one with both vendors in it):

```hcl
terraform {
  required_providers {
    gitea = {
      source  = "go-gitea/gitea"
      version = "~> 0.8"
    }
  }
}

variable "repo_name" { type = string }
variable "visibility" {
  type    = string
  default = "private"
}

provider "gitea" {
  base_url = var.base_url
  token    = var.token
}

resource "gitea_repository" "this" {
  name    = var.repo_name
  private = var.visibility == "private"
}

output "repo_id" { value = gitea_repository.this.id }
```

Four sections, always in this order in every package here: `terraform { required_providers }`, `variable` declarations, one `provider` block, then `resource`
blocks and `output`s. If you know HCL at all, this is unsurprising — the only repo-specific thing is that it lives inside a Kubernetes manifest instead of a
`.tf` file.

## How XR fields reach OpenTofu variables

The module's `variable`s get their values from `spec.forProvider.vars` — a list of `{key, value}` pairs, positioned in the same order the composition's
`patches` list expects:

```yaml
vars:
  - key: repo_name
    value: placeholder   # overwritten by the patch below

patches:
  - type: FromCompositeFieldPath
    fromFieldPath: spec.parameters.repoName
    toFieldPath: spec.forProvider.vars[1].value   # index into the vars list
```

**This is the one fragile spot in the whole pattern.** The patch targets `vars[1]` by numeric index — add or reorder a `vars` entry without checking every
patch's index, and a value silently lands on the wrong variable. When you add a field, add its `vars` entry at the **end** of the list, so every existing index
stays correct.

## How OpenTofu outputs become status

An `output` block becomes readable at `status.atProvider.outputs.<name>` once `tofu apply` succeeds. A `ToCompositeFieldPath` patch copies it up onto the XR:

```yaml
- type: ToCompositeFieldPath
  fromFieldPath: status.atProvider.outputs.repo_id
  toFieldPath: status.repoId
  policy:
    fromFieldPath: Optional   # not present yet on the first reconcile — don't fail on that
```

`status.created`/`status.ready` are derived the same way: a regex match against that same output — present and non-empty means the resource was created. Every
package in this repo derives readiness this way, for the reason explained in [Reading status](../api-reference/README.md#reading-status).

An output marked `sensitive = true` in the module (like `scm-oauth-app`'s `client_secret`) **never appears under `status.atProvider.outputs`** — it's routed to
a Kubernetes Secret instead, via `writeConnectionSecretToRef`. Never write a patch trying to read a sensitive output from status; it won't be there.

## Where credentials come from

`scmRef` on the XR names an `XScmConnection`, and the composition derives that connection's rendered Secret name itself (`scm-connection-<name>`) — there's no
`credentialsSecretRef` field for a tenant to set. That Secret is tfvars-formatted, which is what `varFiles: [{source: SecretKey, ...}]` in the module expects.
See [setup — seed a connection token](../user-guide/setup.md#2--seed-a-connection-token) for the exact format.

## Next

- [Crossplane in five minutes](01-crossplane-in-5-minutes.md), if you haven't yet
- [Your first change](04-your-first-change.md) — a guided edit to `scm-oauth-app`, using exactly this
  pattern
