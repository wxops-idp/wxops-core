# Releasing — versions, the API rule, and cutting a release

> How W'xOps Core is versioned and released. When to write release notes, and how, is in [`release-notes/README.md`](../../release-notes/README.md).

**Table of Contents**
- [Two axes, never mixed](#two-axes-never-mixed)
- [A released XRD only grows](#a-released-xrd-only-grows)
- [Cutting a release](#cutting-a-release)
- [What CI does on the tag](#what-ci-does-on-the-tag)
- [Changelog](#changelog)
- [Channels](#channels)
- [From release to running tenants](#from-release-to-running-tenants)

---

## Two axes, never mixed

| Axis | Example | Tracked in | When it changes |
|---|---|---|---|
| **XRD API version** — the contract | `platform.wxops.cloud/v1alpha1` | `xrd.yaml` → `spec.versions[].name`, summarised in [`VERSIONS.yaml`](../../VERSIONS.yaml) | Almost never. Dev XRs, prod XRs and the portal all bind to it. |
| **Release** — a dated snapshot | `release-2026-09-11` | Git tag, plus each package's `VERSIONS.yaml` `current` and `package/install/` pin | Every release, for the packages that changed. Written by `make release`, never by hand. |

Core and the portal release independently. A portal build pins an API version, never a core release: any core release that serves that version works with it.
Releases before the switch kept their semver tags (`v0.1.0` … `v0.4.0`).

## A released XRD only grows

Crossplane XRDs can serve several versions, but ["the schema of each version can't change any existing
fields"](https://docs.crossplane.io/latest/composition/composite-resource-definitions/), and breaking changes between versions need conversion webhooks — a
custom server this project does not run. So a new API version is **not** a way around a breaking change:

- **Always fine:** optional fields, status fields, whole new optional objects.
- **Never, on a released XRD:** removing or retyping a field, making a field required on an existing
  object, narrowing an enum or bound, renaming a composed resource, changing a `Deployment` selector.
- **When a change must break,** add a new optional field beside the old one, or a new Kind.

`make test-api-compat` enforces this against the last release tag and classifies every change `safe`, `careful` or `breaking`. A deliberate break goes in
`tests/api-compat-allow.yaml` with a reason, and `make release` then requires release notes.

Promoting a Kind from `v1alpha1` is a stability label over an **identical** schema, not a schema change ([archived ROADMAP → Notes and
warnings](../_archives/ROADMAP.md#notes-and-warnings)).

## Cutting a release

```bash
make release-notes     # only needed for a careful or breaking change — make release tells you
make release           # gate → pin changed packages → CHANGELOG.md → commit + tag release-YYYY-MM-DD
git push origin main && git push origin release-YYYY-MM-DD
```

- **Name.** A release is named by UTC date; a second release on the same day becomes
  `release-YYYY-MM-DD.2`.
- **Rebuild everything.** `make release ALL=1` rebuilds every package. The first date-named release
  needed it, to move every install pin to `ghcr.io/wxops-idp/wxops-core`.
- **Check pins.** `make release-check` verifies that `VERSIONS.yaml` and `package/install/` agree.

## What CI does on the tag

[`.github/workflows/publish-packages.yaml`](../../.github/workflows/publish-packages.yaml):

1. Builds only the packages whose `VERSIONS.yaml` `current` equals the tag.
2. Pushes `<image>:<release>` and `<image>:latest` to `ghcr.io/wxops-idp/wxops-core`.
3. Publishes a GitHub release: your notes, a package table with change tiers, and the git-cliff
   changelog.

Nothing is committed back; the release commit already carries the pins.

## Changelog

Generated from [Conventional Commits](https://www.conventionalcommits.org/) with [`git-cliff`](https://git-cliff.org/):

```bash
make changelog          # regenerate CHANGELOG.md
make changelog-preview  # print to stdout, don't write the file
```

Use package names as scopes, to keep per-package history readable:

```
feat(gitea-team): add includeAllRepositories field to XRD v1alpha1
fix(gitea-user): correct must_change_password terraform variable default
feat(tenant-app): add optional monitoring.alerts block to XRD v1alpha1
chore(ci): pin crossplane CLI to v2.3.1 in publish workflow
```

## Channels

Every `package/<pkg>/composition.yaml` carries `metadata.labels.channel: stable`, committed in Git — `make build`/`make push`/`make release` package it
unchanged, so every release ships labelled `stable`. `package/dev/kustomization.yaml` overrides that to `channel: nightly` for anything applied via `make
install-dev` (a Kustomize `labels:` transformer, not a build — `make install-dev` never produces an OCI package to tag in the first place).

Crossplane copies a `Composition`'s labels onto every `CompositionRevision` it creates ([composition
revisions](https://docs.crossplane.io/v2.4/composition/composition-revisions/)) — that alone is the whole mechanism. No custom tooling, no policy, no
enforcement: an XR opts into a channel with two native fields, or doesn't opt in at all:

```yaml
# today's default, unaffected by any of this — always follows the newest revision, any channel
spec:
  parameters: {...}
```
```yaml
# track stable automatically — recommended for most production XRs
spec:
  parameters: {...}
  crossplane:
    compositionRevisionSelector:
      matchLabels:
        channel: stable
    compositionUpdatePolicy: Automatic
```
```yaml
# fully pinned — never auto-adopts anything, not even within a channel
spec:
  parameters: {...}
  crossplane:
    compositionUpdatePolicy: Manual
    compositionRevisionRef:
      name: xtenantapps.platform.wxops.cloud-<hash>   # from `kubectl get compositionrevisions`
```

**`Manual` is the recommended default for production XRs.** Crossplane records `compositionRevisionRef` at XR creation regardless of policy, so `Manual` costs
nothing at creation — it only stops the XR from silently adopting a *future* revision, including a `careful`-tier one (still real, still classified by
[`test-api-compat`](../../tests/README.md#test-api-compat--a-released-api-only-grows)). Use the `compositionRevisionSelector` + `Automatic` pattern instead only
for XRs where auto-tracking `stable` is worth trading away that control.

One caveat: if a selector matches no revision (picking `nightly` on a cluster where nothing was ever applied via `package/dev/`, for instance), the XR goes
unsynced — `SYNCED: False`, no revision — loud, not silent, but worth expecting the first time.

## From release to running tenants

A published package goes live on every XR that follows its composition the moment it is installed — `revisionActivationPolicy: Automatic` (the default in every
`package/install/*.yaml` manifest) and an XR with no `spec.crossplane.compositionUpdatePolicy` set both mean "adopt the newest revision immediately." See
[Channels](#channels) above for how to opt out of that, scoped or fully pinned.
