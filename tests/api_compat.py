#!/usr/bin/env python3
"""
API compatibility — the gate between a change in development and production.

Every XR already in a cluster, and every XR the portal writes, was accepted by
an XRD schema that has been released. This compares the working tree against
the last release tag and fails when a change would break that.

Why a gate rather than a version bump: Crossplane lets an XRD serve several
versions, but "the schema of each version can't change any existing fields",
and breaking changes between versions need conversion webhooks — a custom
server, which this repo's no-controllers rule excludes. A new API version
therefore cannot absorb a breaking change here. Schemas are additive-only, and
this check is what holds them to it.
https://docs.crossplane.io/latest/composition/composite-resource-definitions/

Three checks per package, each against the baseline tag:

  schema  — XRD diff over every version, spec AND status (the portal reads
            status, so removing a status field breaks it as surely as a spec
            field breaks an XR)
  replay  — every XR that was valid at the baseline still validates, with
            nothing silently pruned
  golden  — the committed goldens: a composed resource that disappears is
            deleted in-cluster, and a changed immutable field (Deployment
            selector, PVC storageClassName) strands the XR with no self-heal

Every finding carries a tier from release-notes/README.md's change taxonomy:

  breaking — fails, unless allowed in tests/api-compat-allow.yaml
  careful  — passes, recorded; `make release` requires release notes for it
  safe     — additive

Usage:
    python3 tests/api_compat.py                   # all packages vs last release tag
    python3 tests/api_compat.py tenant-app
    python3 tests/api_compat.py --baseline v0.4.0
    python3 tests/api_compat.py --json            # for the release tooling
    python3 tests/api_compat.py --self-test       # tests/cases/_api_compat fixtures
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import packages as P  # noqa: E402
import releases as REL  # noqa: E402
import render as R  # noqa: E402
import xrdschema as X  # noqa: E402
import yaml  # noqa: E402

ALLOWLIST = R.ROOT / "tests" / "api-compat-allow.yaml"
FIXTURES = R.CASES / "_api_compat"

SEVERITY = {"safe": 0, "careful": 1, "breaking": 2}

# Tightening any of these rejects values an existing XR may already hold.
RAISED_IS_NARROWER = ("minimum", "exclusiveMinimum", "minLength", "minItems", "minProperties")
LOWERED_IS_NARROWER = ("maximum", "exclusiveMaximum", "maxLength", "maxItems", "maxProperties")

# Fields Kubernetes rejects in-place updates to. A composition that changes one
# leaves the Object in a permanent reconcile error — see development-docs/ROADMAP.md
# "The immutable-field hazard".
IMMUTABLE = {
    "Deployment": ("spec.selector",),
    "DaemonSet": ("spec.selector",),
    "StatefulSet": ("spec.selector", "spec.serviceName", "spec.volumeClaimTemplates"),
    "Job": ("spec.selector", "spec.template"),
    "PersistentVolumeClaim": ("spec.accessModes", "spec.storageClassName", "spec.volumeName"),
}

# A golden changes for one of two reasons: the composition, or the case's own
# inputs. Only the first says anything about compatibility.
CASE_INPUTS = ("xr.yaml", "observed.yaml", "required.yaml")


@dataclass
class Finding:
    tier: str
    rule: str
    path: str
    detail: str = ""
    allowed: bool = False


def _join(path: str, key: str) -> str:
    return f"{path}.{key}" if path else key


# ── Schema diff ─────────────────────────────────────────────────────────────

def diff_schema(old, new, path: str, out: list[Finding]) -> None:
    """Classify every difference between two openAPIV3Schema nodes."""
    if not isinstance(old, dict) or not isinstance(new, dict):
        return

    ot, nt = old.get("type"), new.get("type")
    if ot and nt and ot != nt:
        out.append(Finding("breaking", "type-changed", path, f"{ot} → {nt}"))
        return  # children of a retyped node are not comparable

    if "enum" in new:
        if "enum" not in old:
            out.append(Finding("breaking", "enum-narrowed", path, "enum constraint added"))
        else:
            removed = [v for v in old["enum"] if v not in new["enum"]]
            added = [v for v in new["enum"] if v not in old["enum"]]
            if removed:
                out.append(Finding("breaking", "enum-narrowed", path, f"removed {removed}"))
            if added:
                # Writers are fine; a reader (the portal) may not know the value.
                out.append(Finding("careful", "enum-widened", path, f"added {added}"))

    if ("default" in old or "default" in new) and old.get("default") != new.get("default"):
        # The API server applies defaults on read, so every XR that omitted the
        # field silently takes the new value on its next reconcile.
        out.append(Finding("careful", "default-changed", path,
                           f"{old.get('default')!r} → {new.get('default')!r}"))

    for key in RAISED_IS_NARROWER + LOWERED_IS_NARROWER:
        if key not in new:
            continue
        raised = key in RAISED_IS_NARROWER
        try:
            narrower = key not in old or (new[key] > old[key] if raised else new[key] < old[key])
        except TypeError:
            narrower = new[key] != old.get(key)
        if narrower:
            out.append(Finding("breaking", "bounds-narrowed", path,
                               f"{key}: {old.get(key)!r} → {new[key]!r}"))
    if new.get("pattern") and new.get("pattern") != old.get("pattern"):
        out.append(Finding("breaking", "bounds-narrowed", path,
                           f"pattern: {old.get('pattern')!r} → {new['pattern']!r}"))

    if old.get("nullable") and not new.get("nullable"):
        out.append(Finding("breaking", "nullable-removed", path))

    # Pruning: a structural schema drops fields it does not describe, on write,
    # with no error. Turning that on deletes data an existing XR already holds.
    if old.get("x-kubernetes-preserve-unknown-fields") and \
            not new.get("x-kubernetes-preserve-unknown-fields"):
        out.append(Finding("breaking", "pruning-enabled", path,
                           "x-kubernetes-preserve-unknown-fields removed"))
    oa, na = old.get("additionalProperties"), new.get("additionalProperties")
    if oa not in (None, False) and na in (None, False):
        out.append(Finding("breaking", "pruning-enabled", path, "additionalProperties removed"))
    if isinstance(oa, dict) and isinstance(na, dict):
        diff_schema(oa, na, _join(path, "*"), out)

    oprops, nprops = old.get("properties") or {}, new.get("properties") or {}
    for key, sub in oprops.items():
        if key not in nprops:
            out.append(Finding("breaking", "property-removed", _join(path, key)))
        else:
            diff_schema(sub, nprops[key], _join(path, key), out)
    for key in nprops:
        if key not in oprops:
            out.append(Finding("safe", "property-added", _join(path, key)))

    # Only reached for objects that existed at the baseline — a new object is
    # never recursed into, so `required` inside it is correctly left alone.
    old_req = set(old.get("required") or [])
    for key in new.get("required") or []:
        if key not in old_req:
            out.append(Finding("breaking", "required-added", _join(path, key),
                               "existing XRs do not set it and fail validation"))

    if isinstance(old.get("items"), dict) and isinstance(new.get("items"), dict):
        diff_schema(old["items"], new["items"], f"{path}[]", out)


def _versions(doc: dict) -> dict[str, dict]:
    return {v.get("name"): v for v in ((doc.get("spec") or {}).get("versions") or [])}


def _schema(version: dict) -> dict:
    return ((version.get("schema") or {}).get("openAPIV3Schema")) or {}


def diff_xrd(old_doc: dict, new_doc: dict) -> list[Finding]:
    out: list[Finding] = []
    os_, ns = old_doc.get("spec") or {}, new_doc.get("spec") or {}

    # Crossplane: "You can't change the XRD group or names."
    for field in ("group", "scope"):
        if os_.get(field) != ns.get(field):
            out.append(Finding("breaking", "immutable-changed", field,
                               f"{os_.get(field)!r} → {ns.get(field)!r}"))
    for field in ("kind", "plural"):
        o, n = (os_.get("names") or {}).get(field), (ns.get("names") or {}).get(field)
        if o != n:
            out.append(Finding("breaking", "immutable-changed", f"names.{field}", f"{o!r} → {n!r}"))

    oldv, newv = _versions(old_doc), _versions(new_doc)
    old_ref = next((n for n, v in oldv.items() if v.get("referenceable")), None)
    new_ref = next((n for n, v in newv.items() if v.get("referenceable")), None)
    if old_ref and new_ref != old_ref:
        # Compositions name the referenceable version in compositeTypeRef.
        out.append(Finding("breaking", "referenceable-moved", "versions",
                           f"{old_ref} → {new_ref}"))

    for name, ov in oldv.items():
        nv = newv.get(name)
        if nv is None:
            out.append(Finding("breaking", "version-removed", name,
                               "every XR stored at this version becomes unreadable"))
            continue
        if ov.get("served") and not nv.get("served"):
            out.append(Finding("breaking", "version-unserved", name))
        diff_schema(_schema(ov), _schema(nv), name, out)

    for name, nv in newv.items():
        if name in oldv:
            continue
        out.append(Finding("safe", "version-added", name))
        # Crossplane requires every version to keep the existing fields — there
        # is no conversion between them — so a new version is held to the same
        # rules as an edit to the one it sits beside.
        if old_ref:
            diff_schema(_schema(oldv[old_ref]), _schema(nv), name, out)
    return out


# ── Replay ──────────────────────────────────────────────────────────────────

def _spec_schema(doc: dict, version: str | None, label: str) -> dict | None:
    try:
        _, schema = X.load_doc(doc, version, label)
    except ValueError:
        return None
    return (schema.get("properties") or {}).get("spec") or {}


def replay(package: str, baseline: str, old_doc: dict, new_doc: dict) -> list[Finding]:
    """Every XR the baseline accepted must still be accepted, unpruned."""
    out: list[Finding] = []
    paths = [p for p in REL.ls(baseline, f"tests/cases/{package}")
             if p.endswith("/xr.yaml") and "/_" not in p]
    paths += [p for p in REL.ls(baseline, f"examples/{package}")
              if p.endswith(".yaml") and not Path(p).name.startswith("required")]

    for p in paths:
        try:
            xr = yaml.safe_load(REL.show(baseline, p) or "")
        except yaml.YAMLError:
            continue
        if not isinstance(xr, dict) or "spec" not in xr:
            continue
        version = str(xr.get("apiVersion", "")).rpartition("/")[2] or None
        old_spec = _spec_schema(old_doc, version, package)
        if old_spec is None or X.validate(old_spec, xr["spec"]) \
                or X.unknown_fields(old_spec, xr["spec"]):
            continue  # not valid at the baseline, so nothing was promised

        new_spec = _spec_schema(new_doc, version, package)
        if new_spec is None:
            out.append(Finding("breaking", "replay-invalid", p, f"version {version} no longer exists"))
            continue
        for err in X.validate(new_spec, xr["spec"]):
            out.append(Finding("breaking", "replay-invalid", p, err))
        for field in X.unknown_fields(new_spec, xr["spec"]):
            out.append(Finding("breaking", "replay-pruned", p,
                               f"{field} — Kubernetes would silently drop it"))
    return out


# ── Golden baseline ─────────────────────────────────────────────────────────

def _composed(docs: list) -> dict[str, dict]:
    out = {}
    for d in docs:
        ann = ((d.get("metadata") or {}).get("annotations") or {})
        name = ann.get("crossplane.io/composition-resource-name")
        if name:
            out[name] = d
    return out


def _manifest(doc: dict) -> dict:
    if doc.get("kind") == "Object":
        return ((doc.get("spec") or {}).get("forProvider") or {}).get("manifest") or {}
    return doc


def _dig(node, dotted: str):
    for part in dotted.split("."):
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def compare_golden(old_docs: list, new_docs: list, label: str) -> list[Finding]:
    """Classify rendered-output differences for one case.

    The XR document itself is ignored: its changes are status fields, already
    covered by the schema diff.
    """
    out: list[Finding] = []
    old, new = _composed(old_docs), _composed(new_docs)
    for name, od in old.items():
        nd = new.get(name)
        where = f"{label}/{name}"
        if nd is None:
            out.append(Finding("breaking", "resource-removed", where,
                               "renamed or dropped — Crossplane deletes the underlying object"))
            continue
        om, nm = _manifest(od), _manifest(nd)
        kind = om.get("kind", "")
        immutable = [f for f in IMMUTABLE.get(kind, ()) if _dig(om, f) != _dig(nm, f)]
        for field in immutable:
            out.append(Finding("breaking", "immutable-changed", where,
                               f"{kind} {field} — rejected in place, the XR is stranded"))
        if not immutable and od != nd:
            out.append(Finding("careful", "content-changed", where, kind or str(od.get("kind"))))
    for name in new:
        if name not in old:
            out.append(Finding("safe", "resource-added", f"{label}/{name}"))
    return out


def _read(path: Path) -> str | None:
    return path.read_text() if path.exists() else None


def golden(package: str, baseline: str) -> list[Finding]:
    out: list[Finding] = []
    for p in REL.ls(baseline, f"tests/cases/{package}"):
        if not p.endswith("/expected.yaml") or "/_" in p:
            continue
        case_dir = R.ROOT / Path(p).parent
        current = case_dir / "expected.yaml"
        if not current.exists():
            continue
        rel = str(Path(p).parent)
        if any(REL.show(baseline, f"{rel}/{f}") != _read(case_dir / f) for f in CASE_INPUTS):
            out.append(Finding("safe", "golden-skipped", f"{package}/{case_dir.name}",
                               "case inputs changed since the baseline"))
            continue
        old_docs = [d for d in yaml.safe_load_all(REL.show(baseline, p) or "") if d]
        new_docs = [d for d in yaml.safe_load_all(current.read_text()) if d]
        out += compare_golden(old_docs, new_docs, f"{package}/{case_dir.name}")
    return out


# ── Driver ──────────────────────────────────────────────────────────────────

def check_package(package: str, baseline: str) -> list[Finding]:
    # The baseline tag may predate RFC-007's move, so look for the XRD at every
    # layout this package has had. Without the fallback a moved package reads as
    # `package-added` and the gate silently stops comparing anything.
    old_text = next(
        (t for t in (REL.show(baseline, f"{d}/xrd.yaml") for d in P.baseline_paths(package))
         if t is not None), None)
    # A package dropped from VERSIONS.yaml entirely (archived, not deleted — RFC-003 §Removing
    # the old kinds) has no current path at all; that is itself the removal, not a crash.
    try:
        new_path = P.path(package) / "xrd.yaml"
    except KeyError:
        new_path = None
    if old_text is None:
        return [Finding("safe", "package-added", package, f"not present at {baseline}")]
    if new_path is None or not new_path.exists():
        return [Finding("breaking", "package-removed", package,
                        "every XR of this kind loses its definition")]
    old_doc = yaml.safe_load(old_text)
    new_doc = yaml.safe_load(new_path.read_text())
    return (diff_xrd(old_doc, new_doc)
            + replay(package, baseline, old_doc, new_doc)
            + golden(package, baseline))


def packages(baseline: str) -> list[str]:
    names = list((yaml.safe_load((R.ROOT / "VERSIONS.yaml").read_text()) or {})
                 .get("packages") or {})
    old = REL.show(baseline, "VERSIONS.yaml")
    for name in ((yaml.safe_load(old) or {}).get("packages") or {}) if old else []:
        if name not in names:
            names.append(name)
    return names


def load_allowlist() -> list[dict]:
    if not ALLOWLIST.exists():
        return []
    return (yaml.safe_load(ALLOWLIST.read_text()) or {}).get("allow") or []


def apply_allowlist(package: str, findings: list[Finding], allow: list[dict],
                    used: set[int]) -> None:
    for f in findings:
        if f.tier != "breaking":
            continue
        for i, entry in enumerate(allow):
            if (entry.get("package"), entry.get("rule"), entry.get("path")) != \
                    (package, f.rule, f.path):
                continue
            if not str(entry.get("reason") or "").strip():
                continue  # an allowance without a reason is not an allowance
            f.allowed = True
            used.add(i)


def tier_of(findings: list[Finding]) -> str:
    worst = max((SEVERITY[f.tier] for f in findings), default=0)
    return next(t for t, s in SEVERITY.items() if s == worst)


def _colour(tier: str) -> str:
    return {"breaking": R.RED, "careful": R.YELLOW}.get(tier, R.GREEN)


def self_test() -> int:
    """Classify each fixture and compare against its `# expect:` comments.

    A classifier that has never been shown to fire is not a gate. Each fixture
    is a before.yaml/after.yaml pair — XRDs for the schema diff, rendered
    documents for the golden check — and after.yaml declares every tier+rule it
    must produce. It also fails if anything more severe than the worst
    expectation appears, so a `safe` fixture cannot quietly turn breaking.
    """
    cases = sorted(p for p in FIXTURES.iterdir() if p.is_dir()) if FIXTURES.exists() else []
    if not cases:
        print(f"{R.RED}no fixtures{R.RESET} in {FIXTURES.relative_to(R.ROOT)}")
        return 1
    failed = []
    print(f"API compatibility self-test — {len(cases)} fixture(s)\n")
    for case in cases:
        before = [d for d in yaml.safe_load_all((case / "before.yaml").read_text()) if d]
        after_text = (case / "after.yaml").read_text()
        after = [d for d in yaml.safe_load_all(after_text) if d]
        expects = [tuple(e.split()[:2])
                   for e in re.findall(r"^#\s*expect:\s*(.+)$", after_text, re.MULTILINE)]
        if not expects:
            print(f"  {R.YELLOW}no expectation{R.RESET} {case.name}")
            failed.append(case.name)
            continue
        if before and before[0].get("kind") == "CompositeResourceDefinition":
            findings = diff_xrd(before[0], after[0])
        else:
            findings = compare_golden(before, after, case.name)
        got = {(f.tier, f.rule) for f in findings}
        missed = [e for e in expects if e not in got]
        ceiling = max(SEVERITY.get(t, 0) for t, _ in expects)
        over = [f for f in findings if SEVERITY[f.tier] > ceiling]
        if missed or over:
            print(f"  {R.RED}WRONG{R.RESET}   {case.name}")
            for t, r in missed:
                print(f"        {R.RED}expected {t} {r}, not produced{R.RESET}")
            for f in over:
                print(f"        {R.RED}unexpected {f.tier} {f.rule} {f.path}{R.RESET}")
            failed.append(case.name)
        else:
            print(f"  {R.GREEN}ok{R.RESET}      {case.name} "
                  f"{R.DIM}({', '.join(' '.join(e) for e in expects)}){R.RESET}")
    print()
    if failed:
        print(f"{R.RED}FAILED{R.RESET} {len(failed)}: {', '.join(failed)}")
        return 1
    print(f"{R.GREEN}all {len(cases)} fixture(s) classified as expected{R.RESET}")
    return 0


def main() -> int:
    argv = sys.argv[1:]
    if "--self-test" in argv:
        return self_test()
    as_json = "--json" in argv

    baseline, args, skip = None, [], False
    for i, a in enumerate(argv):
        if skip:
            skip = False
        elif a == "--baseline":
            baseline, skip = argv[i + 1] if i + 1 < len(argv) else None, True
        elif a.startswith("--baseline="):
            baseline = a.split("=", 1)[1]
        elif not a.startswith("-"):
            args.append(a)
    baseline = baseline or REL.previous_tag()

    if baseline is None:
        if as_json:
            print(json.dumps({"baseline": None, "packages": {}, "failed": [], "stale": []}))
        else:
            print(f"{R.YELLOW}API compatibility — no release tag reachable, nothing to "
                  f"compare against; skipped{R.RESET}")
        return 0

    selected = [p for p in packages(baseline) if not args or p in args]
    allow, used = load_allowlist(), set()
    report, failed = {}, []
    for package in selected:
        findings = check_package(package, baseline)
        apply_allowlist(package, findings, allow, used)
        report[package] = {"tier": tier_of(findings), "findings": [asdict(f) for f in findings]}
        if any(f.tier == "breaking" and not f.allowed for f in findings):
            failed.append(package)
    stale = [e for i, e in enumerate(allow) if i not in used]

    if as_json:
        print(json.dumps({"baseline": baseline, "packages": report,
                          "failed": failed, "stale": stale}, indent=2, ensure_ascii=False))
        return 1 if failed else 0

    print(f"API compatibility — {len(selected)} package(s) vs {baseline}\n")
    for package, entry in report.items():
        tier = entry["tier"]
        print(f"  {package:<28} {_colour(tier)}{tier}{R.RESET}")
        additive = 0
        for f in entry["findings"]:
            if f["tier"] == "safe":
                additive += f["rule"] != "golden-skipped"
                if f["rule"] == "golden-skipped":
                    print(f"      {R.DIM}skipped   {f['path']} — {f['detail']}{R.RESET}")
                continue
            note = f" {R.DIM}(allowed){R.RESET}" if f["allowed"] else ""
            print(f"      {_colour(f['tier'])}{f['tier']:<9}{R.RESET} {f['rule']:<20} "
                  f"{f['path']}{R.DIM}{'  ' + f['detail'] if f['detail'] else ''}{R.RESET}{note}")
        if additive:
            print(f"      {R.DIM}{additive} additive change(s){R.RESET}")
    print()

    for entry in stale:
        print(f"{R.YELLOW}unused allowance{R.RESET} {entry.get('package')} {entry.get('rule')} "
              f"{entry.get('path')} {R.DIM}— remove it from "
              f"{ALLOWLIST.relative_to(R.ROOT)}{R.RESET}")
    if failed:
        print(f"{R.RED}FAILED{R.RESET} breaking change(s) to a released API in: {', '.join(failed)}")
        print("\nA released XRD is additive-only — Crossplane has no conversion between\n"
              "versions. Restore the field, make the new one optional, or keep the old\n"
              f"resource name. If the break is deliberate, add it to "
              f"{ALLOWLIST.relative_to(R.ROOT)}\nwith a reason; `make release` then "
              "requires release notes for it.")
        return 1
    print(f"{R.GREEN}no breaking changes vs {baseline}{R.RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
