#!/usr/bin/env python3
"""
Shared render + normalise helpers for the wxops-core test suite.

`crossplane composition render` output is not byte-stable across runs: it stamps
condition timestamps and does not guarantee document order. Golden-file tests are
worthless without removing both sources of churn, so everything here funnels
through normalise().
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / "tests" / "cases"

# Every function any composition references. Missing one fails with the
# unhelpful "unknown function ... is it listed in the render input?".
FUNCTIONS = [
    "providers/function-kcl.yaml",
    "providers/function-patch-and-transform.yaml",
    "providers/function-extra-resources.yaml",
]

# Fields stripped before comparison: values change on every render and carry no
# information about whether the composition is correct.
VOLATILE_TOP = ("creationTimestamp",)
VOLATILE_CONDITION = ("lastTransitionTime",)


class Dumper(yaml.SafeDumper):
    """SafeDumper that indents sequences under their key.

    PyYAML emits block sequences at the parent's indent level, which trips
    yamllint's `indent-sequences: true` in .yamllint.yaml. Generated fixtures are
    linted alongside everything else, so they have to match repo style rather
    than carry an ignore rule.
    """

    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def dump_all(docs) -> str:
    return yaml.dump_all(
        docs, Dumper=Dumper, default_flow_style=False, sort_keys=True, width=1000
    )


def functions_file() -> str:
    """Concatenate the Function manifests into one multi-doc YAML file.

    A plain `cat` produces invalid YAML — each file is its own document and
    needs an explicit `---` separator.
    """
    fh = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
    for rel in FUNCTIONS:
        fh.write("---\n")
        fh.write((ROOT / rel).read_text())
    fh.close()
    return fh.name


def _defaulted(xr_path: Path, package: str) -> Path:
    """Write a copy of the XR with XRD defaults applied, and return its path.

    A missing XRD is fatal: silently rendering the raw XR would skip the defaults
    a cluster applies at admission, so the tests would exercise fallbacks instead
    of real behaviour and nothing would say so. Any other schema problem still
    falls back, but says it on stderr.
    """
    import packages  # local to lib/
    xrd = packages.path(package) / "xrd.yaml"
    if not xrd.exists():
        raise FileNotFoundError(f"no XRD at {xrd} for package {package}")
    try:
        import xrdschema  # local to lib/, imported lazily
        doc = yaml.safe_load(xr_path.read_text())
        _, schema = xrdschema.spec_schema(package)
        doc["spec"] = xrdschema.apply_defaults(schema, doc.get("spec") or {})
    except Exception as exc:  # noqa: BLE001 — reported, not swallowed
        print(f"  warn  {package}: XRD defaults not applied ({exc})", file=sys.stderr)
        return xr_path
    fh = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
    yaml.safe_dump(doc, fh, sort_keys=False)
    fh.close()
    return Path(fh.name)


def render(case_dir: Path, package: str) -> tuple[bool, str, str]:
    """Render one case. Returns (ok, normalised_yaml, stderr)."""
    import packages  # local to lib/
    composition = packages.path(package) / "composition.yaml"
    if not composition.exists():
        return False, "", f"no composition at {composition}"

    xr = case_dir / "xr.yaml"
    if not xr.exists():
        return False, "", f"no xr.yaml in {case_dir}"

    # Feed render the XR a cluster would actually hand the composition: the API
    # server applies XRD defaults at admission, and `crossplane render --xrd`
    # does NOT (verified — output is byte-identical with and without it). Passing
    # the raw XR would exercise KCL's `_get` fallbacks instead of the real
    # defaults, so any disagreement between the two would be untestable.
    xr = _defaulted(xr, package)

    cmd = [
        "crossplane", "composition", "render",
        str(xr), str(composition), functions_file(),
    ]
    observed = case_dir / "observed.yaml"
    if observed.exists():
        cmd += [f"--observed-resources={observed}"]
    required = case_dir / "required.yaml"
    if required.exists():
        cmd += [f"--required-resources={required}"]

    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    if proc.returncode != 0:
        return False, "", proc.stderr.strip()
    return True, normalise(proc.stdout), ""


def _strip_volatile(doc):
    """Recursively drop timestamp fields that change on every render."""
    if isinstance(doc, dict):
        out = {}
        for k, v in doc.items():
            if k in VOLATILE_TOP or k in VOLATILE_CONDITION:
                continue
            out[k] = _strip_volatile(v)
        return out
    if isinstance(doc, list):
        return [_strip_volatile(v) for v in doc]
    return doc


def _sort_key(doc) -> tuple:
    """Stable identity for a rendered document.

    Render does not guarantee document order between runs, so documents are
    sorted by (kind, name) before comparison. The XR itself must stay first —
    it is the composite, not a composed resource — so it is keyed with an
    empty leading element.
    """
    if not isinstance(doc, dict):
        return ("~", "", "")
    kind = str(doc.get("kind", ""))
    meta = doc.get("metadata") or {}
    name = str(meta.get("name", ""))
    # The XR carries no composition-resource-name annotation; composed do.
    ann = (meta.get("annotations") or {})
    is_composed = "crossplane.io/composition-resource-name" in ann
    return ("1" if is_composed else "0", kind, name)


def normalise(raw: str) -> str:
    docs = [d for d in yaml.safe_load_all(raw) if d]
    docs = [_strip_volatile(d) for d in docs]
    docs.sort(key=_sort_key)
    return dump_all(docs)


def load_docs(normalised: str) -> list:
    return [d for d in yaml.safe_load_all(normalised) if d]


def discover() -> list[tuple[str, str, Path]]:
    """Yield (package, case_name, case_dir) for every test case, sorted."""
    found = []
    if not CASES.exists():
        return found
    for pkg_dir in sorted(CASES.iterdir()):
        if not pkg_dir.is_dir():
            continue
        # A leading underscore means "not a real package of cases" — `_api_compat`'s fixtures
        # (no xr.yaml, so already skipped below) and `_archives`, which holds retired packages'
        # cases for the record. Neither has a package/ directory for render() to find.
        if pkg_dir.name.startswith("_"):
            continue
        for case_dir in sorted(pkg_dir.iterdir()):
            if case_dir.is_dir() and (case_dir / "xr.yaml").exists():
                found.append((pkg_dir.name, case_dir.name, case_dir))
    return found


# Terminal colour, disabled when not a TTY or when NO_COLOR is set.
_tty = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
GREEN = "\033[32m" if _tty else ""
RED = "\033[31m" if _tty else ""
YELLOW = "\033[33m" if _tty else ""
DIM = "\033[2m" if _tty else ""
RESET = "\033[0m" if _tty else ""
