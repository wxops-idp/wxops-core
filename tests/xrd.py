#!/usr/bin/env python3
"""
XRD conformance — the strict half of the suite.

These are our own schemas, so they are validated exactly. Three checks:

  1. Every test fixture and every published example must satisfy its XRD.
     `crossplane render` does NOT enforce this — a required field can be missing
     and render will still produce resources — so without this check a fixture
     can quietly drift into testing an XR that a real cluster would reject.

  2. Negative cases must be rejected. tests/cases/<pkg>/_invalid/*.yaml are XRs
     that must fail validation. Each declares why via an `# expect:` comment, so
     a case cannot pass by failing for an unrelated reason.

  3. Default parity: where an XRD declares a default, KCL's `_get` fallback for
     the same field should agree. A disagreement means the value the composition
     computes offline differs from what a cluster produces — reported, not
     failed, since only some fields are mirrored in KCL.

Usage:
    python3 tests/xrd.py            # all packages
    python3 tests/xrd.py tenant-app
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import render as R  # noqa: E402
import xrdschema as X  # noqa: E402
import yaml  # noqa: E402

import packages as P  # noqa: E402

# Published packages, from VERSIONS.yaml — see tests/lib/packages.py.
PACKAGES = P.names()


def _xrs_for(package: str) -> list[tuple[str, Path]]:
    """Every XR that must be valid: test-case inputs plus published examples."""
    found = []
    case_root = R.CASES / package
    if case_root.exists():
        for case in sorted(case_root.iterdir()):
            if case.name.startswith("_"):
                continue
            xr = case / "xr.yaml"
            if xr.exists():
                found.append((f"cases/{case.name}", xr))
    ex = R.ROOT / "examples" / package
    if ex.exists():
        for f in sorted(ex.glob("*.yaml")):
            # required-resources fixtures are not XRs of this kind
            if f.name.startswith("required"):
                continue
            found.append((f"examples/{f.name}", f))
    return found


def _expectations(path: Path) -> list[str]:
    """Substrings an invalid case must produce, from `# expect:` comments."""
    return re.findall(r"^#\s*expect:\s*(.+)$", path.read_text(), re.MULTILINE)


def check_valid(package: str, failures: list[str]) -> int:
    version, schema = X.spec_schema(package)
    checked = 0
    for label, path in _xrs_for(package):
        doc = yaml.safe_load(path.read_text())
        if not isinstance(doc, dict) or "spec" not in doc:
            continue
        # Validate what a real API server would store, not what the fixture wrote: Kubernetes
        # applies schema defaults BEFORE running `pattern`/`enum`/etc, so a default that itself
        # violates its own field's pattern (as `scm-connection`'s `org: ""` once did against
        # `^[A-Za-z0-9]...`) only surfaces here if defaults are applied first too.
        spec = X.apply_defaults(schema, doc["spec"])
        errs = X.validate(schema, spec)
        unknown = X.unknown_fields(schema, spec)
        checked += 1
        if errs or unknown:
            print(f"    {R.RED}INVALID{R.RESET} {label}")
            for e in errs:
                print(f"        {R.RED}{e}{R.RESET}")
            for u in unknown:
                print(f"        {R.YELLOW}unknown field {u}{R.RESET}"
                      f" {R.DIM}— Kubernetes would silently prune this{R.RESET}")
            failures.append(f"{package}/{label}")
        else:
            print(f"    {R.GREEN}ok{R.RESET}      {label} {R.DIM}({version}){R.RESET}")
    return checked


def check_invalid(package: str, failures: list[str]) -> int:
    inv_dir = R.CASES / package / "_invalid"
    if not inv_dir.exists():
        return 0
    _, schema = X.spec_schema(package)
    checked = 0
    for path in sorted(inv_dir.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text())
        spec = X.apply_defaults(schema, (doc or {}).get("spec", {}))
        errs = X.validate(schema, spec)
        errs += [f"unknown field {u}" for u in X.unknown_fields(schema, spec)]
        want = _expectations(path)
        checked += 1
        label = f"_invalid/{path.name}"

        if not errs:
            print(f"    {R.RED}NOT REJECTED{R.RESET} {label}")
            print(f"        {R.DIM}this XR should have failed validation but did not{R.RESET}")
            failures.append(f"{package}/{label}")
            continue
        if not want:
            print(f"    {R.YELLOW}no expectation{R.RESET} {label}")
            print(f"        {R.DIM}add an '# expect: <substring>' comment so this cannot"
                  f" pass for the wrong reason{R.RESET}")
            failures.append(f"{package}/{label}")
            continue

        blob = " | ".join(errs)
        missed = [w for w in want if w not in blob]
        if missed:
            print(f"    {R.RED}WRONG REASON{R.RESET} {label}")
            for m in missed:
                print(f"        {R.RED}expected error containing: {m}{R.RESET}")
            print(f"        {R.DIM}actual: {blob[:200]}{R.RESET}")
            failures.append(f"{package}/{label}")
        else:
            print(f"    {R.GREEN}rejected{R.RESET} {label} {R.DIM}({want[0][:60]}){R.RESET}")
    return checked


def check_default_parity(package: str) -> list[str]:
    """Report XRD defaults whose KCL `_get` fallback disagrees.

    Advisory only: not every XRD field is read through `_get`, and some are read
    with an intentionally different fallback. A mismatch is a prompt to look, not
    a failure.
    """
    main_k = R.ROOT / "kcl" / package / "main.k"
    if not main_k.exists():
        return []
    src = main_k.read_text()
    _, schema = X.spec_schema(package)
    params = ((schema.get("properties") or {}).get("parameters") or {})

    notes = []
    for field, sub in (params.get("properties") or {}).items():
        if not isinstance(sub, dict) or "default" not in sub:
            continue
        want = sub["default"]
        if isinstance(want, (dict, list)):
            continue
        for m in re.finditer(
            rf'_get\(\s*params\s*,\s*"{re.escape(field)}"\s*,\s*([^)]+)\)', src
        ):
            got = m.group(1).strip()
            lit = {"True": True, "False": False}.get(got)
            if lit is None:
                lit = got.strip('"') if got.startswith('"') else got
                if isinstance(want, int) and not isinstance(want, bool):
                    try:
                        lit = int(lit)
                    except ValueError:
                        pass
            if lit != want:
                notes.append(f"{field}: XRD default {want!r} vs KCL fallback {got}")
    return notes


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    packages = [p for p in PACKAGES if not args or p in args]
    failures: list[str] = []
    parity: dict[str, list[str]] = {}
    n_valid = n_invalid = 0

    print(f"XRD conformance — {len(packages)} package(s)\n")
    for package in packages:
        print(f"  {package}")
        n_valid += check_valid(package, failures)
        n_invalid += check_invalid(package, failures)
        notes = check_default_parity(package)
        if notes:
            parity[package] = notes
        print()

    if parity:
        print(f"{R.YELLOW}default parity — XRD vs KCL fallback{R.RESET}")
        print(f"{R.DIM}Advisory. A mismatch means the composition computes a different value"
              f"\noffline than a cluster would supply.{R.RESET}\n")
        for package, notes in parity.items():
            for n in notes:
                print(f"  {R.YELLOW}{package}{R.RESET}  {n}")
        print()

    if failures:
        print(f"{R.RED}FAILED{R.RESET} {len(failures)}: {', '.join(failures)}")
        return 1
    print(f"{R.GREEN}{n_valid} XR(s) valid, {n_invalid} negative case(s) correctly "
          f"rejected{R.RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
