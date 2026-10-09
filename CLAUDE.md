# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

W'xOps Core is the control-plane "brain" of W'xOps, built on **Crossplane v2** combined with **provider-opentofu** and **provider-kubernetes** — not on hand-written controllers. `provider-terraform` is archived in `providers/archive/`, kept for the record only: the `gitea-*` packages it ran are themselves archived (see Packages below), never released, no cluster depends on them. Every active package runs on OpenTofu (`opentofu.upbound.io`), and `tests/invariants.py` enforces it. A prior `kubebuilder` Go controller was **rejected and removed**. Do not reintroduce a from-scratch Go controller.

### Two composition engines

| Engine | Used by | When to use |
|---|---|---|
| `function-patch-and-transform` | `scm-*` (`gitea-*`, `random-password` archived) | Single composed resource: an inline-HCL `Workspace`, or one wrapped `Object`. The `scm-*` packages keep **all** vendor logic in HCL — no KCL, no direct API calls |
| `function-kcl` | `platform-database-clusters`, `tenant-database`, `tenant-app` | Multi-resource, conditional branching, list comprehensions |

`tenant-database` additionally uses `function-extra-resources` as a first pipeline step to discover shared clusters via label selector before the KCL step renders resources.

### KCL source management

`kcl/{pkg}/main.k` is the **single source of truth**. It is embedded into `package/{pkg}/composition.yaml` via `make kcl-sync` because `crossplane xpkg build` only packages the Configuration directory. A pre-commit hook (`kcl-drift-check`) enforces sync — always commit both `kcl/{pkg}/main.k` and `package/{pkg}/composition.yaml` together.

```bash
make kcl-sync    # re-embed main.k into composition.yaml (run after editing KCL)
make kcl-check   # fail if composition.yaml has drifted from kcl/{pkg}/main.k
```

### KCL conventions

- Read inputs: `oxr = option("params").oxr`, `params = oxr.spec.parameters`.
- Extra resources (tenant-database): `option("params").extraResources`.
- Use `_get(d, "key", default)` helper instead of `params.get("key", default)` — the latter returns `Undefined` for unset XRD fields in function-kcl.
- KCL has no `if/elif/else` variable assignment — use chained ternary: `x = a if cond1 else b if cond2 else c`.
- KCL `sorted()` does not support `key=` parameter — use `min()` + list filter instead.
- Each composed resource wraps as a `kubernetes.crossplane.io/v1alpha2 Object` with `spec.forProvider.manifest`.
- Use dxr update (emit item with XR's own apiVersion/kind) to write labels and status back to the XR.

### Vault path convention

KCL `remoteKey` values omit the KV mount prefix because the `ClusterSecretStore` is already scoped to it:
- Platform store scoped to `platform/` → code writes `database-clusters/{clusterName}/...` (not `platform/database-clusters/...`)
- Tenant store scoped to `tenants/` → code writes `{owner}/databases/{dbName}/...` (not `tenants/{owner}/...`)

Documentation shows the full logical path (e.g. `tenants/{owner}/databases/{dbName}/connection-creds`).

## Packages

Six Crossplane Configuration packages:

| Package | Kind | Composition |
|---|---|---|
| `platform-database-clusters` | `XPlatformDatabaseCluster` | function-kcl |
| `tenant-database` | `XTenantDatabase` | function-extra-resources + function-kcl |
| `tenant-app` | `XTenantApp` | function-kcl |
| `scm-connection` | `XScmConnection` | patch-and-transform + ESO `ExternalSecret` (no Workspace) |
| `scm-repository` | `XScmRepository` | patch-and-transform + inline HCL, one module for every vendor |
| `scm-oauth-app` | `XScmOAuthApp` | patch-and-transform + inline HCL + ESO `PushSecret` |

**Archived, not deleted** — `gitea-user`/`-org`/`-team`/`-repository` (`XGiteaUser`/`XGiteaOrg`/`XGiteaTeam`/`XGiteaRepository`, all
patch-and-transform + inline HCL) and the `random-password` utility (`XRandomPassword`): no cluster ever ran them, every active
package now runs on OpenTofu, and `scm-*` replaces what they did. Source lives on at `package/platform/archives/<name>/`, tests at
`tests/cases/_archives/<name>/`, docs at `docs/api-reference/_archives/<name>.md` — none of it runs in `make test`/`build`/`release`.
See `VERSIONS.yaml`'s comment above `packages:` and [RFC-003](development-docs/rfc/003-scm-connections-and-resources.md).

Served XRD API versions, and the release each package last changed in, are tracked in
`VERSIONS.yaml`. Releases are named by date (`release-YYYY-MM-DD`); compatibility is the API
version, not the release name — see [`release-notes/README.md`](release-notes/README.md).

## Directory layout

- `package/<group>/<name>/` — `xrd.yaml`, `composition.yaml`, `crossplane.yaml`, `kustomization.yaml`, `README.md`.
  The group is the API group the package's kinds serve (`platform`, and `scm`/`auth` as they land) — see
  [ADR-002](development-docs/adr/002-three-api-groups.md) and [RFC-007](development-docs/rfc/007-package-layout-by-api-group.md).
  **`VERSIONS.yaml` is the only package list**: each entry carries `group` and `path`, and `tests/lib/packages.py`
  is the one resolver. Adding a package is a `VERSIONS.yaml` entry plus an entry in `package/dev/kustomization.yaml`;
  no Makefile, script, workflow or test list needs editing.
- `package/install/<group>/` — production OCI registry-based install (`Configuration` resources, auto-bumped by CI)
- `package/dev/` — development install (applies XRDs + Compositions directly)
- `providers/` — shared provider/function installs and `ProviderConfig` (apply once per cluster)
- `kcl/<name>/` — KCL composition source (`kcl.mod`, `main.k`)
- `examples/<name>/` — minimal XR YAML to exercise each package
- `tests/cases/<name>/` — test cases; `tests/lib/` shared harness (see [Testing](#testing))
- `docs/` — **generic documentation** for anyone who uses, operates or builds on the platform — usage, delivery, and
  guideline material, not where the platform is headed. Hub: `docs/README.md`. The sections:
  - `docs/learn/` — contributor onboarding for Crossplane/OpenTofu/KCL newcomers, each page against
    a real file in this repo; prerequisite reading for `development-docs/development/`, not part of it
  - `docs/api-reference/` — the reconcile loop from a user's side (`README.md`), one page per Kind,
    `status-contract.md`
  - `docs/user-guide/` — `setup.md`, `app-onboarding.md`, `portal-integration.md`
- `development-docs/` — **everything about building, deciding, releasing and where Core is headed**. Hub:
  `development-docs/README.md`, which holds the development matrix and the *Where new docs go* table. Before
  proposing work, check the matrix, which records what's shipped, designed and rejected, and
  `development-docs/core-ideas/solution-matrix.md`:
  - `development-docs/development/` — the development guide (`README.md`), `releasing.md`
  - `development-docs/core-ideas/` — design, proposal and research docs about the platform's own future —
    `solution-matrix.md` (the idea map), `darlane.md`, `guardian.md`,
    `multi-cluster{,-proposal,-connectivity,-scale}.md`, `observability.md`,
    `self-service-operations.md`, `knowledge-architecture.md`, `security-threat-model.md`
  - `development-docs/adr/` — one committed file per decision of lasting consequence (`TEMPLATE.md`, `README.md`
    for the lifecycle); breaking or architectural changes get one, so the reasoning survives
    independent of any single conversation — see [ADR-001](development-docs/adr/001-package-channel-label.md)
  - `development-docs/rfc/` — one committed file per proposal, argued before it is built (`TEMPLATE.md`, `README.md`
    for the lifecycle); community intake is the RFC issue template, the file is the tracked plan. **What's next** is
    the RFC index's `Status` column and each RFC's own body, not a separate roadmap document.
  - `development-docs/_archives/` — frozen, no-longer-live docs, kept for the record (e.g. `ROADMAP.md`, the planning
    doc the RFC index replaced)

  The rule for which home a doc belongs in: does it help someone *use, operate or deliver on* the platform as it is
  today (`docs/`), or does it help someone *build, decide or plan* what it becomes (`development-docs/`)? No other
  top-level folder holds documentation.
- `release-notes/` — hand-written release notes; required when a change is `careful`/`breaking` (CI adds the package table and git-cliff output)

When adding new work, place it in the matching directory. Do not create new top-level folders; the two documentation homes
(`docs/` and `development-docs/`) are the only documentation folders.

## Commands

```bash
# Tests (see Testing below) — offline, no cluster
make test-deps                         # once: pip install -r tests/requirements.txt
make test                              # merge gate: XRD conformance + API compat + golden + invariants
make test-api-compat                   # released XRDs stay additive (vs last release tag)
make test-update                       # regenerate goldens after an intentional change
make test-structural                   # advisory third-party schema filter, never gates

# KCL workflow (run after editing any kcl/{pkg}/main.k)
make kcl-sync                          # embed KCL into composition.yaml
make kcl-check                         # verify sync without modifying

# Build & publish
make build                             # build all OCI packages locally
make push REGISTRY=ghcr.io/wxops-idp/wxops-core VERSION=release-2026-09-11  # build + push (CI does this on tag)
make validate                          # crossplane xpkg build (no push)

# Lint & render
make lint                              # yamllint + kubeconform
make render                            # offline dry-run of example XRs
pre-commit run --all-files             # all hooks (yaml, kubeconform, xpkg build, kcl drift, versions)

# Cluster install
make providers                         # install providers/functions once per cluster
make install                           # install from OCI registry (production)
make install-dev                       # apply XRDs + Compositions directly (development)

# Release — named by date, release-YYYY-MM-DD[.N] (UTC); see release-notes/README.md
make release                           # API gate + pin changed packages + changelog + tag (no push)
make release ALL=1                     # rebuild every package (registry move, first date-named release)
make release-notes                     # scaffold notes; required for careful/breaking changes
make release-check                     # VERSIONS.yaml and package/install/ agree
make changelog                          # regenerate CHANGELOG.md (requires git-cliff)
```

**Python venv**: activate `~/.python3-venv/bin/activate` before running `git-cliff`, `pre-commit`, or other pip-installed CLIs.

## Pre-commit hooks

Commits are validated by:
1. **Conventional commit** format (commit-msg stage) — types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `chore`, `revert` (note: no `ci` — use `chore(ci)`)
2. **YAML lint** + **kubeconform** schema validation
3. **Crossplane xpkg build** for all packages
4. **KCL drift check** — composition.yaml must match kcl/{pkg}/main.k
5. **Package pins** — `VERSIONS.yaml` `current` agrees with `package/install/` (both written by `make release`)
6. **README packages table** in sync with VERSIONS.yaml
7. **XRD conformance** + **API compatibility** + **composition invariants** (fast, every commit)
8. **Golden render tests** — `pre-push` stage only, ~90s

CI enforces the same gates on every pull request via
`.gitea/workflows/pr-validate.yaml`. Pre-commit runs locally and is bypassable
with `--no-verify`; CI is not.

## Working model

When adding new capabilities:

1. Define an `XRD` under `package/<name>/xrd.yaml` — schema-first, keep it minimal.
2. Write a `Composition` under `package/<name>/composition.yaml` — inline HCL for single-resource, KCL function for multi-resource.
3. If using KCL, write `kcl/<name>/main.k` and run `make kcl-sync`.
4. Add `crossplane.yaml` (package metadata) to the same package directory.
5. Add a minimal `examples/<name>/xr.yaml` that exercises the XRD.
6. **Add test cases under `tests/cases/<name>/`** — see [Testing](#testing) below. A new package is not done until it has them.
7. Add a `VERSIONS.yaml` entry with `current: unreleased` and run `make readme-sync`. Never
   hand-edit `current` on an existing package — `make release` pins it. A change to a released
   XRD must stay additive; `make test-api-compat` classifies it.

Start simple before reaching for advanced patterns.

Every XRD must expose `status.created` and `status.ready`. The portal polls
those; the native `type: Ready` condition is unreliable on Crossplane v2.3 with
function-kcl v0.12.1, so readiness is derived from `ocds` instead. Compositions
must never emit Kubernetes RBAC — see [`development-docs/_archives/ROADMAP.md`](development-docs/_archives/ROADMAP.md) *Decided and
rejected*; the composition creates the ServiceAccount and publishes its name in
status, and the GitOps repo binds a `Role` to it.

## Testing

Offline suite, no cluster. `crossplane composition render` runs the real function
images in Docker; the unit under test is the composition itself. Full detail in
[`tests/README.md`](tests/README.md); contributor workflow in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

```bash
make test-deps        # once — pip install -r tests/requirements.txt
make test             # the merge gate: XRD conformance + API compat + golden + invariants
make test-update      # regenerate goldens after an INTENTIONAL change, then read the diff
make test-structural  # advisory only, never gates
```

| Check | Cost | Gates | What it catches |
|---|---|---|---|
| `test-xrd` | 0.3s | yes | XRs violating our XRD; negative cases that are *not* rejected |
| `test-golden` | ~90s | yes | any change to rendered output |
| `test-invariants` | 0.2s | yes | cross-cutting rules + third-party field contracts |
| `test-api-compat` | <1s | yes | breaking changes vs the last release tag: removed/retyped/newly-required fields, narrowed enums, renamed composed resources, changed selectors |
| `test-structural` | ~5s | **no** | third-party structural smoke, best-effort |

A test case is a directory holding up to three inputs:

```
tests/cases/<package>/<case>/
├── xr.yaml         input — drives every conditional branch
├── observed.yaml   optional — mocked ocds, drives readiness derivation
├── required.yaml   optional — extra-resources context (tier resolution)
└── expected.yaml   GENERATED golden — never hand-edit
```

### Rules that matter

- **XRD defaults are applied before rendering.** `crossplane render --xrd` is a
  no-op (verified), so `tests/lib/render.py` applies them itself. Without this,
  tests exercise KCL's `_get` fallbacks instead of the defaults a cluster
  supplies, and a disagreement between the two is invisible.
- **Never hand-write `expected.yaml`.** Run `make test-update`, then **read the
  diff**. A golden accepted without reading it is not a test.
- **Never hand-write `observed.yaml`** for KCL packages — use
  `python3 tests/lib/mkobserved.py <pkg> <case> [--unready <substring>]`. Two
  details are easy to get wrong: `ocds` is keyed by the `Object`'s
  `metadata.name` and Crossplane rewrites `composition-resource-name` to match,
  so a mismatched annotation is silently dropped; and observed replica counts
  live at `Object.status.atProvider.manifest.status`, not `Object.status`.
- **Negative cases live in `tests/cases/<pkg>/_invalid/`** and must carry an
  `# expect: <substring>` comment so a case cannot pass by failing for an
  unrelated reason.
- **`test-structural` never gates.** Its schemas come from the public
  datreeio catalogue, not the operator versions pinned below, so a pass is
  "structurally sane", not "correct". Version-independent guarantees belong in
  `tests/invariants.py` as field contracts instead.
- **A released XRD is additive-only.** `test-api-compat` diffs every XRD, replays every XR and
  compares goldens against the last release tag. Crossplane has no conversion between XRD
  versions, so a new API version is not a way around a breaking change. A deliberate break goes
  in `tests/api-compat-allow.yaml` with a reason; `make release` then requires release notes.
- **The catalogue ref is pinned in three places** — `Makefile`
  (`CRDS_CATALOG_REF`), `tests/structural.py` (`CATALOG_REF`), and
  `.pre-commit-config.yaml`. Bump all three together with the reference stack.

### What the suite cannot catch

Anything needing an API server or a running provider: **provider RBAC gaps**,
validity against the *actually installed* CRD version, and whether anything
reconciles. Those need a cluster; a kind-based e2e tier was tracked in
[`development-docs/_archives/ROADMAP.md`](development-docs/_archives/ROADMAP.md) (archived — not an open RFC yet).
A green `make test` means the compositions render what you expect and the API contract holds — not that it will
work in-cluster.

## Documentation Conventions

Applies to prose paragraphs in `release-notes/`, `development-docs/`, `README.md`, and `docs/` —
markdown renders paragraphs as continuous regardless of source line breaks,
so this is purely about the raw file being comfortable to read in an editor
or terminal, not about rendered output.

- **Wrap prose around ~160 characters per line, not ~100.** The tighter
  wrap breaks lines too often and makes the source choppier to read than
  necessary; a wider column reads more naturally without becoming a single
  giant unwrapped line.
- Applies to prose only — tables, code blocks, and list items keep their
  natural length (a table row or a link-heavy bullet is often long regardless
  of column target; don't force-wrap those).
- When editing an existing doc, match this width for the paragraphs you
  touch — no need to reflow an entire file just to fix one section.

## CI

`.github/workflows/publish-packages.yaml` triggers on a `release-*` tag push. It rebuilds only
the packages whose `VERSIONS.yaml` `current` equals the tag, pushes `:<release>` and `:latest`,
and publishes a GitHub release (notes + package table + git-cliff). It commits nothing back:
`make release` already wrote `VERSIONS.yaml`, `package/install/` and `CHANGELOG.md` into the
release commit. Gitea no longer publishes.

## Reference stack

| Component | Version |
|---|---|
| Crossplane | v2.3 |
| provider-opentofu | v1.1.9 |
| provider-terraform (archived, `providers/archive/`) | v1.1.5 |
| provider-kubernetes | v1.2.1 |
| provider-sql | v0.15.0 |
| function-kcl | v0.12.1 |
| function-extra-resources | v0.3.0 |
| function-patch-and-transform | v0.10.7 |
| function-go-templating (archived, unused) | v0.12.2 |
| Gitea Terraform provider | ~> 0.7.0 |
