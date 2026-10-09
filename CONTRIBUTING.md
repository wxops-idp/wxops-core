# Contributing to W'xOps Core

W'xOps Core is a library of Crossplane v2 Configuration packages. There is no
Go controller and no runtime — every package is an `XRD` plus a `Composition`,
and the "logic" lives in KCL or in patch-and-transform patches.

That shape decides how you contribute: **you change a schema or a template, and
you prove the rendered output is what you intended.** This document covers the
workflow, and in particular what a new package owes the test suite.

**New to Crossplane, Terraform or KCL?** This document assumes you can already read a
`Composition`. [`docs/learn/`](docs/learn/README.md) is four short pages that get you there first,
each against a real file in this repo.

- Architecture, conventions and the reference stack → [`CLAUDE.md`](CLAUDE.md)
- Test harness internals → [`tests/README.md`](tests/README.md)
- What is planned and what is next → [RFC index](development-docs/rfc/README.md); a rejection lives in the RFC or ADR it belongs to
- Per-XRD API reference → [`docs/api-reference/`](docs/api-reference/README.md)
- The platform's own documentation → [`docs/README.md`](docs/README.md); the development matrix, decisions and process → [`development-docs/README.md`](development-docs/README.md)
- Hooks, make targets and releasing, in one place → [`development-docs/development/`](development-docs/development/README.md)
- Recording *why* for a breaking or architectural decision → [`development-docs/adr/`](development-docs/adr/README.md)
- Proposing a design before it is built → [`development-docs/rfc/`](development-docs/rfc/README.md)

---

## Setup

```bash
# Required on PATH
crossplane   # https://docs.crossplane.io/latest/cli/
kubeconform  # https://github.com/yannh/kubeconform
docker       # crossplane render runs functions as containers

python3 -m venv ~/.python3-venv && . ~/.python3-venv/bin/activate
pip install pre-commit yamllint
make test-deps          # PyYAML + jsonschema for the test suite
pre-commit install --install-hooks
pre-commit install --hook-type pre-push --hook-type commit-msg
```

The first `make test` pulls ~800MB of function images. After that they are
cached.

---

## The loop

```bash
git switch -c feat/short-description

# ... edit ...

make kcl-sync           # if you touched kcl/<pkg>/main.k — REQUIRED
make test               # the gate
make lint
```

Then open a PR against `main`. CI
([`.gitea/workflows/pr-validate.yaml`](.gitea/workflows/pr-validate.yaml)) runs
the same gates. Pre-commit is local and `--no-verify` bypasses it; CI does not.

### Commit messages

Conventional Commits, enforced at commit-msg. Allowed types: `feat`, `fix`,
`perf`, `refactor`, `docs`, `test`, `chore`, `revert`.

There is **no `ci` type** — use `chore(ci):`. Scope with the package name where
it applies: `feat(tenant-app): ...`.

### Three rules that bite

**`kcl/<pkg>/main.k` and `package/<pkg>/composition.yaml` must be committed
together.** The KCL is embedded into the composition by `make kcl-sync`, because
`crossplane xpkg build` only packages the Configuration directory. A drift hook
rejects a split commit.

**A released XRD only grows.** `make test` includes `test-api-compat`, which compares every XRD,
every XR and every golden against the last release tag. Removing or retyping a field, making a
field required on an existing object, narrowing an enum, renaming a composed resource or changing
a `Deployment` selector all fail it. A new API version does not get around this — Crossplane has no
conversion between XRD versions — so a breaking need becomes a new optional field beside the old
one. If a break is truly deliberate, list it in `tests/api-compat-allow.yaml` with a reason, where
the reviewer sees it.

**There is no version to bump.** Releases are named by date, and `make release` pins changed
packages in `VERSIONS.yaml` and `package/install/` itself; a hand edit to either fails the
`release-state-check` hook. See [`release-notes/README.md`](release-notes/README.md).

---

## Changing an existing composition

1. Edit `kcl/<pkg>/main.k` (or the composition's patches).
2. `make kcl-sync`
3. `make test` — golden tests will fail, showing exactly what changed.
4. **Read that diff.** It is the review. If it contains anything you did not
   intend, you have found a bug before it shipped.
5. `make test-update` to accept, then `git diff tests/` once more.
6. Add a case if you added a branch — see below.

`make test-api-compat` classifies the change against the taxonomy in [`release-notes/README.md`](release-notes/README.md)
(`safe` / `careful` / `breaking`) for you. Sequence `careful` edits into their own commit so they
can be reverted alone, and expect to explain them in release notes — `make release` requires notes
for anything not `safe`. Renaming a composed resource, or changing an immutable field like a
`Deployment` selector or a PVC's `storageClassName`, is never `safe` and fails the check — read the
hazard sections before doing either.

---

## Adding a new package

Follow the working model in [`CLAUDE.md`](CLAUDE.md), then the test work below.
The checklist:

A package lives at `package/<group>/<name>/`, where the group is the API group its kinds serve
(`platform`, `scm`, `auth` — see [ADR-002](development-docs/adr/002-three-api-groups.md)).
**`VERSIONS.yaml` is the only package list**, so there is no Makefile, workflow or test list to edit:

- [ ] `VERSIONS.yaml` entry: `group`, `path`, `api.served`/`api.storage`, `description`, and
      `package.current: unreleased`. No `package/install/` manifest — `make release` writes it on the first
      release — then `make readme-sync`
- [ ] `package/<group>/<name>/xrd.yaml` — schema-first, minimal, **with `status.created` and `status.ready`**
- [ ] `package/<group>/<name>/composition.yaml`
- [ ] `kcl/<name>/main.k` + `kcl.mod` if using function-kcl, then `make kcl-sync` (and add the name to
      `KCL_PACKAGES` in [`.gitea/scripts/kcl-sync.py`](.gitea/scripts/kcl-sync.py))
- [ ] `package/<group>/<name>/crossplane.yaml`, `kustomization.yaml` (just `xrd.yaml` + `composition.yaml`), `README.md`
- [ ] `package/dev/kustomization.yaml` — add `../<group>/<name>`; nothing generates this file
- [ ] `examples/<name>/xr.yaml`
- [ ] `docs/api-reference/<name>.md` + a row in [`docs/api-reference/README.md`](docs/api-reference/README.md)
- [ ] **`tests/cases/<name>/` — see below**
- [ ] A commit scope in [`cliff.toml`](cliff.toml)
- [ ] Any new API group the composition targets → `providers/rbac-provider-kubernetes.yaml`

That last one has no offline test. provider-kubernetes runs with
`InjectedIdentity` and Crossplane's RBAC manager grants it nothing on
third-party CRDs, so a composed `Object` for an ungranted group fails
`forbidden` at reconcile — and **the test suite cannot catch it**. Check it by
hand.

### Writing the test cases

A case is a directory of inputs. `expected.yaml` is generated, never written by
hand.

```
tests/cases/<package>/<case>/
├── xr.yaml         input — the spec.parameters under test
├── observed.yaml   optional — mocked ocds, drives readiness
├── required.yaml   optional — extra-resources context
└── expected.yaml   GENERATED golden
```

**Minimum for a new package — three cases:**

```bash
mkdir -p tests/cases/<pkg>/baseline
cp examples/<pkg>/xr.yaml tests/cases/<pkg>/baseline/xr.yaml
```

1. **`baseline`** — the published example, no `observed.yaml`. Pins the
   first-reconcile shape: what gets emitted before anything exists, with
   `created: false` and `ready: false`.

2. **`<something>-ready`** — the same input with observed state, proving
   readiness actually flips:

   ```bash
   cp -r tests/cases/<pkg>/baseline tests/cases/<pkg>/provisioned
   python3 tests/lib/mkobserved.py <pkg> provisioned
   ```

3. **A degraded case** — one dependency not Ready, proving `ready` discriminates
   rather than being vacuously true:

   ```bash
   cp -r tests/cases/<pkg>/baseline tests/cases/<pkg>/degraded
   python3 tests/lib/mkobserved.py <pkg> degraded --unready <name-substring>
   ```

Then add **one case per conditional branch** the composition has — every
`if <toggle>` in the KCL is an untested path until a case exercises it.

Finally, **negative cases** in `tests/cases/<pkg>/_invalid/`, one per constraint
worth defending — required fields, enums, min/max. Each needs an `# expect:`
comment naming the error substring, so it cannot pass by failing for an
unrelated reason:

```yaml
# expect: 'owner' is a required property
#
# owner scopes both the PostgreSQL role name and the Vault path. Missing, it
# would produce a role and secret path with an empty segment.
apiVersion: platform.wxops.cloud/v1alpha1
kind: XTenantDatabase
metadata:
  name: no-owner
spec:
  parameters:
    dbName: payments
```

Generate and review:

```bash
make test-update
git diff tests/          # READ IT — this is where you catch your own mistakes
make test
```

### Do not

- **Do not hand-write `expected.yaml`.** Generate it and read the diff.
- **Do not hand-write `observed.yaml` for KCL packages.** Use `mkobserved.py`.
  Two details are easy to get wrong: `ocds` is keyed by the `Object`'s
  `metadata.name` and Crossplane rewrites `composition-resource-name` to match,
  so a mismatched annotation is *silently ignored* and your case tests nothing;
  and observed replica counts live at
  `Object.status.atProvider.manifest.status`, not `Object.status`.
- **Do not accept a golden you have not read.** A golden file is only a test if
  someone looked at it.

### Adding an invariant

[`tests/invariants.py`](tests/invariants.py) holds rules that must be true for
every package and case, including ones nobody has written yet. Add one when you
find a failure mode that is **silent** — no error, no event, just wrong
behaviour. Examples already there: a monitor missing the `release` label the
Prometheus Operator filters on; a Vault `remoteKey` repeating the KV mount
prefix and writing to `tenants/tenants/...`.

```python
@rule("short-kebab-name",
      "Why this matters — specifically, how it fails silently in a real cluster.")
def my_rule(docs, ctx):
    return [f"{name}: ..." for name, m in _of_kind(docs, "SomeKind") if bad(m)]
```

**Then prove it bites.** Break a golden file deliberately, confirm the rule
fires, and restore it. A rule that has never failed has not been tested.

---

## What the tests cannot tell you

A green `make test` means the compositions render what you expect and the API
contract holds. It does **not** mean it works in a cluster. Out of reach
offline:

- **provider RBAC gaps** — the most common real failure, and completely
  invisible here
- validity against the *actually installed* CRD version, as opposed to the
  public catalogue the advisory structural check uses
- whether anything reconciles — CNPG accepting a `Cluster`, Gitea accepting a
  user, Vault accepting a write
- ordering, retries, eventual consistency between composed resources

Before a release, exercise the change on a real cluster. A kind-based e2e tier
was tracked in [`development-docs/_archives/ROADMAP.md`](development-docs/_archives/ROADMAP.md) (archived — not an open RFC yet).

---

## Boundaries

Some things are settled. Check [`development-docs/_archives/ROADMAP.md`](development-docs/_archives/ROADMAP.md) *Out of scope* and
*Decided and rejected* before proposing them — the list exists so contributors
do not spend a weekend on something that will be declined.

The two most likely to catch you out:

- **No hand-written controllers.** A `kubebuilder` Go controller was built,
  rejected and removed. Crossplane v2 with provider-opentofu and
  provider-kubernetes is the architecture.
- **Compositions never emit Kubernetes RBAC.** No `Role`, `ClusterRole`,
  `RoleBinding`, `ClusterRoleBinding` — provider-kubernetes is deliberately not
  granted `rbac.authorization.k8s.io`, and granting it would make the provider a
  privilege-escalation vector. The composition creates the ServiceAccount and
  publishes its name in status; the GitOps repo binds a role to it. An invariant
  enforces this, so a PR that tries will fail.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Contributions are
accepted under the same terms, per §5 of the licence.
