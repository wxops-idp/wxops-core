# ADR-004: `XScmRepository` repeats `vendor` — a Terraform provider cannot be made conditional

## Status
<!-- Matches spec.docStatus — single source of truth is the YAML, this is for readers -->
Accepted

## Context

[RFC-003](../rfc/003-scm-connections-and-resources.md) states a principle for the whole `XScm*` family: a tenant XR never learns the vendor.
`XScmRepository`/`XScmOAuthApp` carry only `scmRef.name`; vendor, base URL, org and token are read once, at apply time, from the `XScmConnection`'s Secret via
`varFiles` — never patched onto the XR, never branched on by the composition.

`scm-repository`'s module followed that principle literally: one `Workspace` declaring both `go-gitea/gitea` and `integrations/github` as `required_providers`,
with every resource gated by `count` on `var.vendor` (read from the connection's Secret, same as everything else). Real testing against both hosts found this
does not work. Reproduced directly: with `vendor = "github"`, `tofu plan` still tries to configure the **unused** `gitea` provider and fails —

```
Error: Get "https://gitea.invalid/api/v1/version": dial tcp: lookup gitea.invalid on 127.0.0.53:53: no such host
  with provider["registry.opentofu.org/go-gitea/gitea"]
```

— because Terraform configures every provider a module declares as soon as a resource of its type exists in the configuration, independent of whether that
resource's `count` evaluates to zero. Both vendor SDKs make a real, authenticated call inside `Configure()` itself: `go-gitea/gitea`'s client does an eager `GET
/api/v1/version` against `base_url`; `integrations/github`'s provider does an eager owner lookup via `Users.Get`. Three fixes were tried and disproved
empirically before this one:

- `count = 0` on the resource — proven insufficient (above).
- `configuration_aliases` + explicit `providers = {}` passed into a child module invoked with `count = 0` — the exact pattern
  Terraform's own docs recommend for passing providers into modules — fails identically.
- Giving the unused provider `null`/default values instead of a placeholder host — changes the error from a DNS failure to an auth
  failure, because the shared token is always real for whichever vendor is actually in use, never valid for the other.

There is no Terraform or OpenTofu mechanism that makes a provider's configuration conditional. The only thing that stops a provider from being configured is
removing every resource/data block of its type from the rendered module text — a decision that has to be made before Terraform ever sees the file, i.e. by
Crossplane, not by HCL.

## Decision

Repeat `vendor` (`gitea | github`) on `XScmRepository.spec.parameters`, required — the one exception to "vendor lives only on the connection." Crossplane's
`function-patch-and-transform` picks the **entire module string** via a `match` transform keyed on this field: one literal module declares only `go-gitea/gitea`
and gitea's resources, the other only `integrations/github` and github's. Neither variant's rendered HCL ever contains the other vendor's provider, so Terraform
never configures it.

The connection's own `vendor` (still read via `varFiles`, unchanged) is kept as a `variable "vendor"` validation inside each module — not for module selection,
only as a mismatch guard: if the XR's `vendor` and the `scmRef` connection's actual vendor disagree, the validation fails with a clear message (`"...vendor is
gitea, but scmRef's XScmConnection resolves to a different vendor"`) instead of the wrong provider failing first with a cryptic one.

## Consequences

- `XScmRepository` is the one kind in the family where a tenant's own XR names the vendor, duplicating what `scmRef` already implies.
  It is documented as a cross-checked repeat, not a second source of truth: the module refuses to run at all if the two disagree.
- `scm-oauth-app` does not need this and was not changed: its GitHub path is `observed`-only passthrough (GitHub has no OAuth-app
  creation API), so its module only ever declares the `gitea` provider — the conflict this ADR fixes cannot occur there.
- Any future package that needs two *real, creatable* resource types from two different Terraform providers in one Workspace inherits
  this same pattern — the fix is not specific to repositories.
- `tests/xrd.py` was hardened alongside this (applies XRD defaults before validating, matching API-server order) after a related bug
  surfaced the same way — by running against a real cluster, not caught by the offline suite as it stood.

## Alternatives Considered

- **`count`/`if` gating inside one shared module.** What RFC-003 originally specified. Disproved empirically — see Context.
- **`configuration_aliases` + per-module `count`.** Terraform's own documented pattern for passing providers into child modules.
  Tested directly against this exact module; fails the same way, because aliasing changes *which* provider configuration a resource
  uses, not *whether* Terraform configures it.
- **`function-go-templating` + `function-extra-resources`**, fetching the `XScmConnection` directly so `vendor` stays sole-sourced on
  the connection and no field is duplicated. Rejected for now: it adds a second function to a pipeline this package family deliberately
  keeps to `function-patch-and-transform` + inline HCL only (RFC-003), and the pinned `function-go-templating` version's `ExtraResources`
  support wasn't confirmed before this simpler fix was chosen. Worth revisiting if a future package needs this exact shape.
- **Per-vendor kinds** (`XScmGitHubRepository`, `XScmGiteaRepository`). The option RFC-003 already rejected for the whole family — the
  portal and Dex need one shape and would branch per vendor themselves. Reopening it for one package would contradict that call.
