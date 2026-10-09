<!--
This template exists so a reviewer (human or agent) can tell what changed and why without having
to reconstruct it from the diff. Fill in every section that applies, delete the ones that don't,
and delete all HTML comments — they're scaffolding, not part of the PR.

Before opening: `make test && make lint` locally, and read `make test-update`'s diff if goldens
changed — an accepted golden you haven't read is not a test. See CONTRIBUTING.md.
-->

## Summary

<!-- One or two sentences: what changed and for whom. Not a commit-by-commit log — the full
story belongs in the commits themselves; this is the one-paragraph version a reviewer reads first. -->

## Related

<!-- Link what this PR implements or closes. Delete lines that don't apply. -->

- RFC: <!-- development-docs/rfc/NNN-....md, or "none" -->
- ADR: <!-- development-docs/adr/NNN-....md, or "none" -->
- Issue:

## Type of change

<!-- Check all that apply. -->

- [ ] New package (`feat(<package>): ...`)
- [ ] Composition / schema change to an existing package
- [ ] Bug fix
- [ ] Docs only (`docs: ...`)
- [ ] CI / tooling (`chore(ci): ...`)
- [ ] Other:

## Packages touched

<!-- Every package this PR's commits carry as a scope, e.g. tenant-app, scm-repository.
Matters for release-notes' package table and for a reviewer scoping their read. -->

## Change tier

<!-- Only for a change to a RELEASED XRD. `make test-api-compat` classifies this for you —
paste what it reported. Taxonomy: release-notes/README.md. -->

- [ ] `safe` — new optional field, new status field, new conditional resource; no release notes needed
- [ ] `careful` — changed default, changed content of a composed resource; **release notes required**
- [ ] `breaking` — removed field, renamed composed resource, selector change; **release notes required**,
      and only mergeable with a reasoned entry in `tests/api-compat-allow.yaml`
- [ ] N/A — no released XRD touched (new package, docs, CI, internal tooling)

## Testing

<!-- What you ran, not just "tests pass." Check what applies and fill in anything make test-update
or test-structural reported, even if it's "nothing." -->

- [ ] `make test` — green (XRD conformance, golden render, invariants, API compat)
- [ ] `make lint` — green
- [ ] New or changed composition path → `make test-update` run, **diff read**, no unintended changes
- [ ] New package → test cases added under `tests/cases/<name>/`, including a `_invalid/` case per
      schema rule that isn't purely additive
- [ ] Verified on a real cluster (describe below) — required for anything `tests/README.md`
      "What the tests cannot tell you" lists: provider RBAC, in-cluster reconciliation, a real host

<!-- Cluster verification detail, if you checked the box above: -->

## Release notes

- [ ] Not needed (`safe` tier, or no released XRD touched)
- [ ] Added at `release-notes/<next-release>.md` — required for `careful`/`breaking`

## Breaking changes / migration

<!-- Only if "breaking" is checked above. What existing XRs or consumers does this affect, and what
do they need to do. Delete this section if nothing breaks. -->

## Checklist

- [ ] Commit messages are Conventional Commits (`feat`, `fix`, `perf`, `refactor`, `docs`, `test`,
      `chore`, `revert` — no `ci`, use `chore(ci)`), scoped to the package where it applies
- [ ] `kcl/<pkg>/main.k` and `package/<group>/<pkg>/composition.yaml` committed together (`make kcl-sync` run)
- [ ] `make readme-sync` run if a package or its API version changed
- [ ] No hand-edits to `VERSIONS.yaml` `current` or `package/install/` — those are `make release`'s job
- [ ] Compositions emit no Kubernetes RBAC (`no-rbac-emitted` invariant — see `CLAUDE.md`)
