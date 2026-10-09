# Tests

Offline test suite for the Crossplane Configuration packages. **No cluster
required** — everything runs through `crossplane composition render`, which
executes the real function images in Docker.

```bash
make test-deps      # once: pip install -r tests/requirements.txt
make test           # the merge gate
```

## What is actually under test

The unit is the **composition**: given an XR (plus optionally the observed state
of its composed resources), it must render exactly these resources. That is a
pure function, so it is testable offline and deterministically.

Every case reduces to one command:

```
crossplane composition render \
    tests/cases/<pkg>/<case>/xr.yaml     # input
    package/<pkg>/composition.yaml        # thing under test
    <the three function manifests>        # real function images, in Docker
    --observed-resources=observed.yaml    # optional
    --required-resources=required.yaml    # optional
```

Three input files are the entire authoring surface:

| File | Feeds | Lets you test |
|---|---|---|
| `xr.yaml` | `spec.parameters` | every conditional branch — `darlane.enabled`, `service.enabled`, `tier`, `monitoring.kind`, `cluster` |
| `observed.yaml` | `option("params").ocds` | readiness — `created`, `ready`, `dependenciesReady`, `darlane.replicas` |
| `required.yaml` | extra-resources context | tier resolution — the shared-cluster pool |

XRD **defaults are applied before rendering**, so the input matches what a
cluster's API server would hand the composition. (`crossplane render --xrd` does
*not* do this — verified: output is byte-identical with and without it.) Without
that step the tests would exercise KCL's `_get` fallbacks rather than the real
defaults, and a disagreement between the two would be invisible.

## The five checks

| Command | Strictness | What it catches |
|---|---|---|
| `make test-xrd` | **strict** | XRs violating our own XRD schema; negative cases that are *not* rejected |
| `make test-api-compat` | **strict** | breaking changes to an API that has already been released |
| `make test-golden` | **strict** | any change to rendered output |
| `make test-invariants` | **strict** | rules that must hold everywhere, including in cases nobody wrote |
| `make test-structural` | best-effort, **advisory** | structural mistakes in third-party manifests |

`make test` runs the first four. `test-structural` is deliberately excluded —
see below.

### `test-xrd` — strict, because these are our schemas

Validates every test fixture *and* every published example against
`package/*/xrd.yaml`. This matters because **render does not enforce the XRD**:
remove the required `image` field and render happily produces a Deployment with
no image, where a real cluster would reject the XR at admission.

`tests/cases/<pkg>/_invalid/*.yaml` are XRs that must **fail**. Each declares why
via an `# expect:` comment, so a case cannot pass by failing for an unrelated
reason:

```yaml
# expect: 'image' is a required property
```

It also reports **default parity** — where an XRD default and the corresponding
KCL `_get` fallback disagree. Advisory, since not every field is mirrored in KCL.

Unknown fields are reported too. Kubernetes **silently prunes** them rather than
erroring, which makes a typo'd field name one of the most confusing failures to
debug — the value simply never arrives. This suite is deliberately stricter than
the API server here.

### `test-golden` — full output comparison

Renders each case and diffs against a committed `expected.yaml`.

Render output is not byte-stable: it stamps condition timestamps and does not
guarantee document order. Both are normalised away (timestamps stripped,
documents sorted by composed-ness, kind, name) or every run would show a
spurious diff.

After an **intentional** composition change:

```bash
make test-update    # regenerate goldens
git diff tests/     # then READ IT
```

A golden accepted without reading the diff is not a test.

### `test-invariants` — rules, not snapshots

Golden files catch *changes*. These catch *wrongness*, in cases nobody has
written yet. Two groups:

**Architecture and contract** — no Kubernetes RBAC is ever emitted (compositions
must not mint RBAC; see `development-docs/_archives/ROADMAP.md` → *Decided and rejected*), nothing sensitive
reaches XR status, every `Object` names a `providerConfigRef`, every composed
resource carries a `composition-resource-name`, `ready` never true while
`created` is false.

**Third-party field contracts** — the fields we template into resources we do not
own. These are version-independent and encode decisions already written down:

| Kind | Contract |
|---|---|
| `PushSecret` | `remoteKey` must not repeat the KV mount prefix (`platform/`, `tenants/`) — no schema catches a doubled path; the write succeeds at the wrong location |
| `PushSecret` | store is `ClusterSecretStore`; `deletionPolicy` in {`Delete`, `None`} |
| `ExternalSecret` | `spec.target.name` set, or ESO derives a uid-prefixed name the workload never looks for |
| CNPG `Cluster` | `instances` is an int; `storage.size` carries a unit |
| `IngressRoute` | `entryPoints` non-empty; every route has a `match`; `tls.secretName` matches a composed `Certificate` |
| `ServiceMonitor`/`PodMonitor` | `release: kube-prometheus-stack` label, `component` in the selector, `sampleLimit` set |

### `test-api-compat` — a released API only grows

The other checks compare the tree with itself. This one compares it with **the last release tag**,
because that is what clusters and the portal actually run. Crossplane has no conversion between XRD
versions — "the schema of each version can't change any existing fields" — so a released schema is
additive-only, and a new API version is not a way around that.

Three checks per package:

| Check | `breaking` — fails | `careful` — passes, needs release notes |
|---|---|---|
| **Schema diff** — every version, `spec` and `status` | field removed or retyped, `required` added to an existing object, enum or bound narrowed, pruning enabled, version removed or unserved, `group`/`names`/`scope` changed | default changed, enum widened |
| **Replay** — every XR valid at the tag, validated again now | now invalid, or a field would be silently pruned | — |
| **Golden baseline** — goldens at the tag vs now, for cases whose inputs did not change | composed resource removed or renamed (deleted in-cluster), immutable field changed (`Deployment` selector, PVC storage class) | any other content change |

A deliberate break goes in `tests/api-compat-allow.yaml` with a reason, where the reviewer sees it;
`make release` then requires release notes and clears the list.

The classifier is itself tested. Each `tests/cases/_api_compat/<fixture>/` holds `before.yaml` and
`after.yaml` — XRDs or rendered documents — and an `# expect: <tier> <rule>` comment. `--self-test`
fails if an expectation is not produced *or* anything more severe appears, so a `safe` fixture cannot
quietly turn breaking.

```bash
python3 tests/api_compat.py                   # vs the last release tag
python3 tests/api_compat.py --baseline v0.4.0
python3 tests/api_compat.py --self-test
```

With no release tag reachable — a shallow clone — it skips rather than fails. CI checks out full
history for that reason.

### `test-structural` — best-effort, and not a gate

Runs kubeconform over the manifests *inside* composed `Object`s — which
`make lint` never sees, since they are templated into
`spec.forProvider.manifest`.

**Read a pass here as "structurally sane", not "correct".** The schemas come from
the public datreeio CRDs-catalog, not from the operator versions pinned in
`CLAUDE.md`. The catalogue tracks upstream latest, effectively a superset of your
pinned versions, so the realistic failure is a **false pass**: you template a
field that exists upstream but not in your pinned CNPG, this reports valid, and
the cluster rejects it.

Kinds the catalogue does not cover — provider-sql's `Role` and `ProviderConfig` —
are reported as a coverage gap and **never fail the build**. A permanently-red
check is one people learn to ignore.

The catalogue ref is **pinned** in both `Makefile` (`CRDS_CATALOG_REF`) and
`tests/structural.py` (`CATALOG_REF`). Tracking a moving branch would let
upstream change what CI accepts with no commit in this repo. Bump both together,
alongside the reference stack.

## Adding a case

```bash
mkdir -p tests/cases/tenant-app/my-case
$EDITOR tests/cases/tenant-app/my-case/xr.yaml

# optional: mock observed state so readiness derivation is exercised
python3 tests/lib/mkobserved.py tenant-app my-case
python3 tests/lib/mkobserved.py tenant-app my-case --unready certificate

make test-update && git diff tests/ && make test
```

`mkobserved.py` exists because the fixture has two easy-to-get-wrong details:
`ocds` is keyed by the `Object`'s `metadata.name` and Crossplane rewrites
`composition-resource-name` to match, so a mismatched annotation is silently
dropped; and observed replica counts live at
`Object.status.atProvider.manifest.status`, not `Object.status`.

## What this suite cannot catch

Worth knowing so a green check is not over-trusted. Anything needing an API
server or a running provider is out of reach:

- whether provider-kubernetes has **RBAC** to apply what was rendered — this is
  exactly the `monitoring.coreos.com` gap found in the observability work, and
  render would never have surfaced it
- whether a wrapped manifest is valid against the **actually installed** CRD
  version
- whether anything **reconciles** — CNPG accepting a Cluster, Gitea accepting a
  user, Vault accepting a write
- ordering, retries, and eventual-consistency behaviour between composed
  resources

Those need a real cluster. A kind-based e2e tier (chainsaw or kuttl) is the
follow-up; tracked, archived, in `development-docs/_archives/ROADMAP.md` (not an open RFC yet).

## Layout

```
tests/
├── README.md
├── requirements.txt
├── xrd.py              strict — our XRD schemas + negative cases
├── api_compat.py       strict — released API stays additive, vs the last release tag
├── api-compat-allow.yaml  deliberate breaks for the next release, each with a reason
├── golden.py           strict — rendered output vs committed goldens
├── invariants.py       strict — cross-cutting rules + field contracts
├── structural.py       advisory — third-party schema filter (pinned)
├── lib/
│   ├── render.py       render, normalise, XRD defaulting
│   ├── xrdschema.py    schema load, validate, defaults, unknown fields
│   ├── releases.py     release-tag lookup, file content at a tag
│   └── mkobserved.py   generate observed.yaml fixtures
└── cases/
    ├── <package>/
    │   ├── <case>/     xr.yaml [+ observed.yaml] [+ required.yaml] + expected.yaml
    │   └── _invalid/   XRs that must be rejected, with `# expect:` comments
    └── _api_compat/    before.yaml + after.yaml pairs the classifier must tier correctly
```
