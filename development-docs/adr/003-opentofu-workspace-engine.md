# ADR-003: OpenTofu as the Workspace engine, not Terraform

## Status
<!-- Matches spec.docStatus — single source of truth is the YAML, this is for readers -->
Accepted

## Context

Every inline-HCL package runs its module through a Crossplane `Workspace` composed resource. Until now that meant
`provider-terraform`, which shells out to the real `terraform` binary. HashiCorp relicensed `terraform` from MPL-2.0 to the Business
Source License (BSL) in 2023 — a source-available licence with use restrictions, not an open-source one. Shipping an open-source
Configuration package whose every composed Workspace runs a BSL-licensed binary underneath it is a real inconsistency: the packages
are open source, but the engine they depend on at runtime is not.

`provider-opentofu` runs `tofu`, the Linux Foundation's MPL-2.0-licensed fork of Terraform, forked at the last MPL release and kept a
drop-in-compatible superset since. [RFC-002](../rfc/002-migrate-terraform-to-opentofu.md) is where the migration was designed and
tried: `random-password` first, as the Phase 1 proof, with the four `gitea-*` packages deliberately left on `provider-terraform` for a
later, gradual migration window (Phase 2) once real usage made an orphan-first procedure necessary.

That gradual window never happened, for a reason RFC-002 didn't originally anticipate: `gitea-*` turned out to have no cluster running
it anywhere, so there was nothing to migrate carefully around. It was archived outright in the same pass instead (see
[RFC-003](../rfc/003-scm-connections-and-resources.md) §Removing the old kinds) — which makes this ADR's job simpler than RFC-002's
Phase 2/3 planned for, not harder: there is no in-place migration to record, because the only packages still on `provider-terraform`
are retired, not running.

## Decision

`provider-opentofu` (`opentofu.upbound.io/v1beta1 Workspace`) is the Workspace engine for every actively-served package, with no
exception. `tests/invariants.py`'s `workspace-uses-opentofu` rule enforces this for every package `tests/lib/render.py` discovers —
which, since archived packages moved out of `tests/cases/` into `tests/cases/_archives/` (skipped by discovery), already excludes
`gitea-*` without the invariant needing a vendor-specific allowlist.

`provider-terraform` is not deleted. It moves to `providers/archive/`, kept for the record and for the one scenario that would need
it again: if an archived `gitea-*` package is ever resurrected, its Workspace kind and this provider go with it, unchanged — resurrecting
a package is not an opportunity to also silently re-license its engine out from under it.

## Consequences

- Every Workspace a `make render`/`crossplane render` produces today is `opentofu.upbound.io/v1beta1`; none is `tf.upbound.io`.
- The module HCL itself needed no changes to migrate — OpenTofu parses the same `.tf` syntax, so `random-password`'s Phase 1 migration
  was a `apiVersion` change on the composed resource plus a `terraform { required_providers {} }` block update, nothing in the HCL body.
- `make providers` no longer installs `provider-terraform` or its `ProviderConfig`; a cluster that wants to resurrect an archived
  `gitea-*` package has to apply `providers/archive/provider-terraform.yaml` and its `ProviderConfig` by hand first.
- The repo's own runtime dependency graph — Crossplane, every provider and function it installs, every module it ships — is now free
  of BSL-licensed components end to end.
- RFC-002's Phase 2 (gradual `gitea-*` migration) and Phase 3 (removing `provider-terraform` alongside it) are moot, not completed:
  there was nothing running to migrate off of, and the provider is kept archived rather than removed.

## Alternatives Considered

- **Keep `provider-terraform`.** Rejected outright: it ships a BSL-licensed binary as part of every Workspace an open-source project's
  packages create, which is the whole problem this ADR exists to fix.
- **Pin an old, pre-BSL Terraform release through `provider-terraform` indefinitely.** Defers the same problem onto an increasingly
  unpatched CLI version rather than resolving it, and still depends on a provider that itself may stop receiving updates.
- **Migrate `gitea-*` in place before writing this ADR**, as RFC-002 Phase 2/3 originally planned. Overtaken by events: the packages
  were archived, not migrated, once it was clear nothing depended on them — see RFC-002's own Status note.
