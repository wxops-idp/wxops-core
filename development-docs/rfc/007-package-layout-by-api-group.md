# RFC-007: Package layout by API group, with a Kustomization per category

## Status
<!-- Draft | In review | Accepted | Declined | Withdrawn | Implemented — and the GitHub issue that carries the discussion, e.g. "Draft · #42" -->
Accepted

> [!NOTE]
> Implemented for both groups now in use: the eight original packages moved to `package/platform/<name>/`, `VERSIONS.yaml` gained
> `group`/`path`, `tests/lib/packages.py` is the one resolver (the five hand-maintained package lists are gone), and `package/scm/`
> landed with its first three real packages (`scm-connection`, `scm-repository`, `scm-oauth-app`, RFC-003 Phase 1). `auth/` still
> awaits its first package (RFC-004). See [ADR-002](../adr/002-three-api-groups.md) for the group split this layout serves.

## Summary

`package/` holds every package in one flat list, so a newcomer cannot tell which packages belong to Git hosting, to authentication, or to the
workload platform — the three API groups of [ADR-002](../adr/002-three-api-groups.md). Group the directory the same way
(`package/scm/`, `package/auth/`, `package/platform/`), give each group its own Kustomization for both development and production installs,
and record the group of each package in `VERSIONS.yaml`. The move is a behaviour-neutral change made once, before the first `scm` package
lands, so new packages are never written in the old layout. It also lets a contributor, or an adopter who only wants one category, install and
work on that category alone.

## Motivation

1. **The structure does not say what a package is for.** Today `package/` lists `gitea-*`, `platform-database-clusters`, `tenant-*` and
   `random-password` side by side. With `scm` and `auth` coming, a flat list of fifteen or more packages stops being readable.
2. **Installs are all or nothing.** `package/dev/` and `package/install/` each apply every package. Someone who wants only the Git-hosting
   category, or only identity, cannot say so; and that is exactly who the first adopters are (a cluster turning on its Git ecosystem).
3. **The group is now a first-class idea with nowhere to live.** [ADR-002](../adr/002-three-api-groups.md) splits the API by trust boundary,
   and `VERSIONS.yaml`, the install pins, RBAC and the docs each need to know a package's group.
4. **Contributors need a clear place to start.** A category with its own packages, examples, tests and Kustomization is a unit someone can
   own and extend, whether that is a new SCM host or a new storage backend.

## Detailed Design

### Target layout

```
package/
├── scm/
│   ├── kustomization.yaml          # the category: lists its packages
│   ├── connection/                 # xrd.yaml, composition.yaml, crossplane.yaml, kustomization.yaml, README.md
│   ├── repository/                 # package `scm-repository`
│   └── org/ · team/ · user/ · oauth-app/
├── auth/
│   ├── kustomization.yaml
│   ├── dex-connector/
│   └── oidc-client/
├── platform/
│   ├── kustomization.yaml
│   ├── tenant-app/ · tenant-database/ · platform-database-clusters/ · random-password/
│   └── gitea-user/ · gitea-org/ · gitea-team/ · gitea-repository/   # until removed, see RFC-003
├── dev/
│   └── kustomization.yaml          # ../scm ../auth ../platform, plus the channel: nightly label
└── install/
    ├── scm/ · auth/ · platform/    # one Configuration per package, pinned by `make release`
    └── kustomization.yaml          # all categories
```

- **Package names do not change; directories drop the group prefix.** The directory says the group, so `scm-connection` lives at
  `package/scm/connection/`. The OCI path stays `ghcr.io/wxops-idp/wxops-core/scm-connection`, which is why a package moving directories is
  invisible to anyone who installs from the registry. Packages with no group prefix keep their name (`package/auth/dex-connector/`).
- **A category is a Kustomization.** `kubectl apply -k package/dev/scm` installs only Git hosting from source; `kubectl apply -k
  package/install/auth` installs only identity from the registry; the top-level ones install everything, as today. Each package keeps its own
  `kustomization.yaml` listing just `xrd.yaml` and `composition.yaml`, so Kustomize's root-only load restriction is still satisfied.
- **The `channel` label stays one transformer** at the `dev` level, over all categories ([ADR-001](../adr/001-package-channel-label.md)),
  not repeated in each.
- **`VERSIONS.yaml` records `group` and `path`** per package, so the package name, the directory and the group are each stated once and no
  script derives one from another by string rules (stripping a prefix would mangle `platform-database-clusters`, for one).
- **`random-password` stays in `platform`**, as a utility; the `gitea-*` packages stay there too until [RFC-003](003-scm-connections-and-resources.md)
  removes them, because a released kind cannot change group.

### What has to learn the new paths

The move touches everything that resolves `package/<name>`: the `Makefile` (build, validate, kubeconform, kcl-sync, install and release
targets), `.gitea/scripts/{kcl-sync.py,validate-packages.sh,release-state.py,gen-readme-packages.py}`, both `pr-validate.yaml` workflows and
`publish-packages.yaml`, `.pre-commit-config.yaml`, `tests/api_compat.py`, `tests/structural.py`, `tests/lib/xrdschema.py`, and `kcl/README.md`.
`tests/cases/` and `kcl/` are keyed by package name rather than by path, so they are untouched in the first step.

### Done as one behaviour-neutral change

The move is a single pull request with no functional edits: `git mv` for the directories, a path lookup through `VERSIONS.yaml` in the scripts,
the Kustomizations, and the docs. Its acceptance test is that nothing observable changes — `make test`, `make validate`, `make lint`, `make render`
and `make release-check` all pass unchanged, `make build` produces byte-identical packages for every existing package, and
`kubectl kustomize package/install` and `package/dev` render the same resources as before. Because the API group of each *kind* is a separate,
later change (ADR-002), this RFC does not edit any XRD.

### Docs and contributor guidance

`CLAUDE.md`, `CONTRIBUTING.md`, `development-docs/development/` and the hub's *Where new docs go* table gain a "which category does this belong to" answer. The
category is also where Crossplane's operational features would be organised if adopted later (for example a scheduled rotation or a
reactive check per category) — an option, not a dependency; they are alpha in the current Crossplane documentation.

## Drawbacks

- **A wide, mechanical change.** About a dozen files resolve package paths, and a missed one fails CI rather than breaking silently, but it is
  still churn for no new capability, and it competes with RFC-002 and RFC-003 for review attention.
- **History is harder to follow across the move.** `git mv` preserves it, and `git log --follow` works, but blame across the boundary is noisier.
- **Docs and examples go stale.** Every `package/<name>/` path written in a doc, README or release note changes; the link checker catches
  most.
- **The group is one more thing to keep consistent** between `VERSIONS.yaml`, the XRD and the directory.
- **`gitea-*` sits in `platform` for now**, which looks wrong beside a new `scm` category until they are removed.

## Alternatives

- **Keep `package/` flat and add category Kustomizations only** (for example `package/categories/scm/kustomization.yaml` pointing at
  `../../scm-*`). No path churn, and it delivers per-category installs, but it does not make the structure self-describing and every new
  package must be added to a list by hand.
- **Directory per category for everything** (`kcl/`, `examples/`, `tests/cases/`, `docs/api-reference/` as well). Maximum clarity, and a much
  larger change, since the test harness addresses cases by `<package>/<case>`. A possible second step once the first has settled.
- **Separate repositories per category.** Strongest ownership boundaries, but it splits releases and the shared test and release
  tooling that this repo's date-named release depends on.
- **Do nothing.** Cheap now; the flat list gets worse with every package added by the next RFCs.

## Rollout Plan

- [ ] **Order (decided):** this layout move first, then `scm` packages written directly on OpenTofu ([RFC-002](002-migrate-terraform-to-opentofu.md),
  [RFC-003](003-scm-connections-and-resources.md)), then the `random-password` engine swap, then the Dex integration.
- [ ] **Step 1 — the move.** One behaviour-neutral pull request, accepted only if every unchanged check above stays green.
- [ ] **Step 2 — `VERSIONS.yaml` `group`** and the release scripts reading it.
- [ ] **Step 3 — category Kustomizations**, dev and install, with `make install-dev` and `make install` able to take a category.
- [ ] **Step 4 — docs and contributor guidance**, including a short "adding a package to a category" page.
- [ ] **Later, if wanted:** `kcl/`, `examples/` and `tests/cases/` follow the same grouping.

On acceptance, one ADR is optional: the layout is a convention more than a decision with lasting architectural consequence. ADR-002 already
records the groups it follows.

## Open Questions

1. **One category per package, or can one package serve two?** For example a package that composes both an SCM resource and a Dex client.
2. **Does `random-password` belong in `platform`**, or in a shared category of utilities that every group may use?
3. **Second step.** Should `kcl/`, `examples/` and `tests/cases/` follow in the same change, accepting a harness update, or wait?
