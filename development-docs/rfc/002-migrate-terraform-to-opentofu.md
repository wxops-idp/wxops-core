# RFC-002: Migrate the Workspace engine from Terraform to OpenTofu

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Implemented

> [!NOTE]
> `provider-opentofu` is the engine for every active package; every `scm-*` package (RFC-003) is written on it directly, never on `provider-terraform`.
> `random-password`'s own migration (Phase 1) landed first, but the package was archived outright in the same pass that retired `gitea-*` (see RFC-003 §Removing
> the old kinds) rather than carried forward — so Phase 2's gradual migration window and Phase 3's removal never applied; both are moot once the packages they'd
> apply to are archived, not running. `provider-terraform` itself stays in `providers/archive/` for the record rather than being deleted outright. The
> engine-choice ADR this RFC's Rollout Plan reserved as "ADR-003" is now [ADR-003](../adr/003-opentofu-workspace-engine.md) — written after this Status note, so
> it also records that Phase 2/3 are moot rather than completed.

## Summary

Replace `provider-terraform` (which runs the `terraform` binary) with `provider-opentofu` (which runs `tofu`) as the engine behind every inline-HCL `Workspace`
in Core, so the whole runtime stack — Crossplane, providers, functions and now the infrastructure engine — carries an OSI-approved open-source licence
consistent with this repository's Apache-2.0. The HCL in the compositions stays; the composed resource's API group, the provider install, the state hand-over
and the documentation change. New packages ([RFC-003](003-scm-connections-and-resources.md)) are written against the final engine from the start, so they need
no migration at all; what is left to migrate is `random-password`, and the `gitea-*` packages are retired by RFC-003 rather than migrated.

## Motivation

This repository is Apache-2.0 and is being prepared for outside contributors ([`LICENSE`](../../LICENSE), [`NOTICE`](../../NOTICE)). Every component in `NOTICE`
is Apache-2.0, MIT or MPL-2.0 except one gap: the engine that executes the HCL. Terraform moved to the Business Source License 1.1 from version 1.6 onward;
OpenTofu is the Linux Foundation fork of the last MPL-2.0 release and stays MPL-2.0.

Stated precisely, because it decides how urgent this is: **this repository ships HCL text, not a Terraform binary**, so the repo itself is not in breach of
anything. The exposure is in what an operator installs to run it — the `provider-terraform` runtime image contains a `terraform` binary, and which licence that
binary carries depends on the version the image pins (a point to verify, below). Moving to OpenTofu makes "every layer is open source" a statement that holds
without that footnote, which is the position an Apache-2.0 project wants to be in when others adopt or redistribute it.

Doing it now is also cheap. Five compositions use a `Workspace` today, no more; every RFC after this one that provisions through a vendor API (RFC-003, then the
Dex integration) would otherwise add to the number that has to be migrated later.

## Detailed Design

### The provider

`upbound/provider-opentofu` is the Upbound-maintained Crossplane provider for OpenTofu, Apache-2.0, serving `opentofu.upbound.io/v1beta1`. It exposes the same
`Workspace` model as `provider-terraform` (inline or remote module, `tofu init/plan/apply` in the provider pod, connection secret from outputs), so the
compositions' structure does not change.

| | Today | After |
|---|---|---|
| Provider package | `xpkg.upbound.io/upbound/provider-terraform:v1.1.5` | `xpkg.upbound.io/upbound/provider-opentofu:v1.1.9` |
| Workspace | `tf.upbound.io/v1beta1` `Workspace` | `opentofu.upbound.io/v1beta1` `Workspace` |
| ProviderConfig | `tf.upbound.io/v1beta1` `ProviderConfig` named `default`, Kubernetes state backend | the `opentofu.upbound.io` equivalent, same backend — exact kind and fields to confirm. `provider-opentofu` keeps no state of its own, so the Kubernetes backend (or a preserved `/tf` directory) is required, not optional |
| Binary | `terraform` | `tofu` |

### What changes in this repo

| Area | Files | Change |
|---|---|---|
| Provider install | `providers/provider-opentofu.yaml`, `providers/providerconfig-opentofu.yaml` (new) | added; the Terraform files moved to `providers/archive/` (still required by `gitea-*`, applied by hand) until the `gitea-*` packages are removed |
| Compositions | `package/platform/random-password/composition.yaml` | `apiVersion` on the composed `Workspace`; the HCL and its `terraform {}` block are unchanged. The four `gitea-*` packages are **not** migrated: RFC-003 retires them, and they keep `provider-terraform` until then |
| Goldens | `tests/cases/random-password/…` (new) | `random-password` had no test cases; two were added and their goldens read. A new invariant, `workspace-uses-opentofu`, rejects any `tf.upbound.io` Workspace outside the four `gitea-*` packages |
| Docs | `README.md`, `docs/learn/02-opentofu-here.md`, `docs/api-reference/`, `docs/user-guide/setup.md`, `development-docs/core-ideas/security-threat-model.md`, `development-docs/development/releasing.md`, `CLAUDE.md`, `development-docs/ROADMAP.md` | terminology and the reference stack table |
| Attribution | `NOTICE` | OpenTofu (MPL-2.0) and `provider-opentofu` (Apache-2.0) added; the `provider-terraform` row stays, marked legacy, until removal |
| Diagram | `images/w'xops-core-crossplane.png` | may name Terraform in its labels — it needs a manual check, since it is an image |

**Terminology:** say *OpenTofu* for the engine and *HCL* for the language, and keep the upstream names where they are simply correct — "the Gitea Terraform
provider" (`go-gitea/gitea`) is still what that plugin is called. The README section "Why Crossplane + Terraform" becomes "Why Crossplane + OpenTofu", and the
learn page is now `02-opentofu-here.md` (renamed) with its five inbound links fixed in the same change.

### The dangerous part: swapping the Workspace kind

Changing a composed resource's `apiVersion` is not an in-place edit. Crossplane sees the old `tf.upbound.io` Workspace as no longer desired and deletes it, and
**deleting a Workspace runs a destroy** — the Gitea org, team, user or repository it manages is deleted with it. This is the one way this migration can lose
real data, so the procedure orders it out:

1. On every existing `tf.upbound.io` Workspace, set `deletionPolicy: Orphan`, so removing the object leaves the vendor
   resource alone. Verify with `kubectl get workspaces.tf.upbound.io -o custom-columns=…` before any next step.
2. Install `provider-opentofu` alongside `provider-terraform` (both can be present).
3. Roll out the new compositions. New `opentofu.upbound.io` Workspaces are created; the orphaned old ones are removed
   without touching Gitea.
4. Reconcile state (next section).
5. Only after a full green reconcile, uninstall `provider-terraform`.

### State

The Kubernetes backend keeps each Workspace's state in a Secret in `crossplane-system`. The new Workspaces must see the resources that already exist rather than
try to create them again (a duplicate org or user fails with "already exists"). OpenTofu was forked from Terraform 1.5.x and reads state written by it, but
state written by Terraform 1.6 and later is not guaranteed to be readable — so the first task is to record which Terraform version the current provider image
ships, since it decides whether the existing state can be reused as-is.

Two ways to reconcile, chosen at implementation after that check:

- **Reuse state**: point the new ProviderConfig at the same backend secrets, so `tofu plan` reports no changes.
- **Import**: start from empty state and declare each existing resource with an HCL `import` block, so the first apply adopts
  rather than creates.

Nothing in this repository records more than one deployment: the maintainer's own cluster, against a Gitea instance that is now archived and read-only. The
state hand-over is therefore a one-time, hand-run procedure written into the release notes, not a feature to automate. If external users have appeared by the
time this is implemented, that assumption needs re-checking.

### Compatibility and change tier

No XRD changes, so no API break for a consumer: `XGiteaUser` and the others keep their schema. (They are themselves on a path to removal —
[RFC-003](003-scm-connections-and-resources.md) replaces them with `XScm*` kinds in `scm.wxops.cloud` — so their engine swap is only for the window until that
migration is done.) The offline classifier watches for *renamed composed resources*, so it may still flag this as `careful` because each composed resource's
identity changes; if it does, the release notes with the procedure above are required, and no allowlist entry is needed unless it says `breaking`.
`VERSIONS.yaml` moves the five affected packages.

### Testing

- Goldens: regenerated and **read**, expecting only the `apiVersion` line to differ.
- An invariant that no composition emits `tf.upbound.io`, so a stray old Workspace cannot come back.
- A compile-time check that each inline HCL module is valid for OpenTofu (`tofu validate` against the module) is possible but
  needs provider plugins downloaded; whether it is worth a network-dependent CI step is an open question.

The offline suite cannot show that `tofu` actually applies this HCL against Gitea, and it never could — Gitea acceptance has always been manual. That needs a
cluster and a **live Gitea that accepts writes**. The maintainer's own instance is archived and read-only, so it cannot be the target; a throwaway Gitea
(MIT-licensed, one container) in the same kind cluster is the acceptance environment. The smoke test is manual until the kind-based e2e tier exists: one
`XGiteaOrg`, one `XGiteaTeam`, one `XGiteaRepository`, one `XGiteaUser` and one `XRandomPassword` reconciled end to end against it, then deleted to confirm
cleanup.

Nothing about the Gitea integration itself changes: the plugin is still `go-gitea/gitea ~> 0.7.0` and the API calls are the same. What is being validated is the
engine and the Workspace API group, not Gitea's behaviour.

## Drawbacks

- **A one-off migration with a data-loss path** (the Workspace-deletion trap above) for a benefit that is legal and
  positioning rather than functional. The procedure removes the risk; it does not remove the work.
- **State hand-over depends on a version fact not yet checked**, and may force the import route.
- **The provider registry story changes.** `tofu init` resolves providers through the OpenTofu registry. `go-gitea/gitea` is listed there
  at v0.6.0 and v0.7.0, so the pinned `~> 0.7.0` should resolve; `hashicorp/random` and RFC-003's `integrations/github` and
  `gitlabhq/gitlab` are still to be confirmed at their pinned versions.
- **A slower default poll.** The `provider-opentofu` documentation notes a default polling interval of 10 minutes rather than 1, which
  would slow drift detection on existing Workspaces (not first apply). Whether that describes this provider and this version is to be
  confirmed, and the interval is configurable if it matters.
- **Two upstreams to follow instead of one** while both providers coexist during the cut-over, and a permanent dependency on
  `provider-opentofu` staying maintained. It is an Upbound project like `provider-terraform`, but its cadence should be read
  before committing.
- **Vocabulary churn** across docs and the diagram for a change consumers of the XRDs will never see.

## Alternatives

- **Stay on Terraform** and pin to the last MPL-2.0 release (1.5.x). Legally fine and zero work now, but it is a version that
  receives no further releases, and it leaves the "runtime dependency is not open source" question for every future upgrade.
- **Keep `provider-terraform` and swap the binary.** If that provider can be told to run `tofu` (a command or image override),
  the migration would be an image change with no API-group change and none of the Workspace-deletion risk. This RFC did not
  confirm that it can; if it can, it is the better first step and would shrink the RFC to almost nothing. **Check this before
  anything else.**
- **Replace Workspaces with native providers** for Gitea and the others. No Gitea Crossplane provider exists, which is why the
  Workspace pattern was chosen; it stays the pragmatic path.
- **Do nothing.** Accept the footnote. Cheap today, more expensive with every package that adds a Workspace.

## Rollout Plan

- [x] **Spike — answered from documentation.** `provider-opentofu` is at `v1.1.9` (2026-09-27); its `ProviderConfig` takes `configuration`, `credentials`,
  `backendFile` and `pluginCache`, with the Kubernetes backend in `configuration`; `go-gitea/gitea` is on the OpenTofu registry at v0.7.0.
- [ ] **Spike — still to confirm in a cluster:** `hashicorp/random ~> 3.6` resolves from the OpenTofu registry; the state Secret is named per
  Workspace so the distinct `secret_suffix` (`tofu-state`) cannot collide with Terraform state; the default poll interval; and whether
  `provider-terraform` can run `tofu` directly (expected no). A throwaway kind cluster is enough.
- [x] **Phase 1, repository side — provider and `random-password`.** `provider-opentofu` installed beside `provider-terraform`;
  `random-password` migrated; test cases and the guard invariant added; docs, `NOTICE` and the reference stack updated. `make test`, `lint`
  and `readme-check` pass.
- [x] **Phase 1, cluster side — moot, not done.** `random-password` was archived (see RFC-003 §Removing the old kinds) before this
  verification ran; there is no servable XRD left to apply `examples/random-password/xr.yaml` against. Not a gap: nothing depends on
  this package existing any more.
- [x] **Phase 2 — the four `gitea-*` packages: archived, not migrated.** The planned deprecation window never ran — real testing found
  no cluster depended on any of them, so they were archived outright in the same pass instead (RFC-003 §Removing the old kinds). An
  adopter who must move one early still has the orphan-first procedure above; the repository itself skipped straight to archiving.
- [x] **Phase 3 — `provider-terraform` archived, not removed.** It stays in `providers/archive/` for the record, same treatment as the
  packages that ran on it, rather than being deleted. `make providers` no longer installs it; its `NOTICE` row and docs mentions were
  updated to say archived, not deleted.
- [x] **ADR-003**, written: [OpenTofu as the Workspace engine, not Terraform](../adr/003-opentofu-workspace-engine.md).

The ADR records the engine choice and the licence reasoning so they survive independent of this proposal.

## Open Questions

1. **Can `provider-terraform` run the `tofu` binary directly?** If so, does that make this RFC an image swap instead of a
   provider swap? (The first item of the spike.)
2. **Reuse state or import?** Decided by the Terraform version the current image ships.
3. **How much of the wording changes?** Full rename to OpenTofu everywhere, or only where the engine is named and "Terraform"
   kept where it means the language or an upstream provider's own name?
4. **Should each package's `crossplane.yaml` dependency list change**, and does the provider need a stated minimum version
   there so a consumer cannot install a Configuration onto a cluster that lacks `provider-opentofu`?
5. **Validate HCL in CI?** Is a `tofu validate` step that needs provider downloads acceptable, or does the manual smoke test
   suffice until the e2e tier exists?
