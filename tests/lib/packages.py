#!/usr/bin/env python3
"""The package registry: which packages exist, and where each one lives.

`VERSIONS.yaml` is the single source of truth. Every entry under `packages:`
(published as an OCI Configuration) and `utilities:` (not published) carries a
`group` and a `path`, so no tool derives a directory from a package name by
string rules — stripping a group prefix would mangle `platform-database-clusters`.

It lives in `tests/lib/` because that is already this repo's shared Python
library: `.gitea/scripts/release-state.py` imports `releases` from here. Both
the test suite and the build scripts therefore import it the same way, and the
CLI below serves the Makefile and the bash scripts:

    python3 tests/lib/packages.py list            # published package names
    python3 tests/lib/packages.py list --all      # published + utilities
    python3 tests/lib/packages.py pairs           # "<name>=<path>" per line
    python3 tests/lib/packages.py path <name>     # repo-relative directory
    python3 tests/lib/packages.py group <name>

`baseline_paths()` exists for the one job that cannot assume today's layout:
comparing against a release tag cut before the packages moved (RFC-007). It
returns every path a package may have had, newest first, so a historical lookup
falls back to the flat `package/<name>` shape instead of silently concluding the
package is new.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
VERSIONS = ROOT / "VERSIONS.yaml"


def registry() -> dict[str, dict]:
    """Every package, published and utility, keyed by name."""
    doc = yaml.safe_load(VERSIONS.read_text()) or {}
    out: dict[str, dict] = {}
    for section, published in (("packages", True), ("utilities", False)):
        for name, info in (doc.get(section) or {}).items():
            entry = dict(info or {})
            entry["published"] = published
            out[name] = entry
    return out


def names(include_utilities: bool = False) -> list[str]:
    """Package names in VERSIONS.yaml order — published only by default."""
    return [n for n, e in registry().items()
            if e["published"] or include_utilities]


def path(name: str) -> Path:
    """Absolute package directory. Raises if the package is unknown."""
    entry = registry().get(name)
    if entry is None:
        raise KeyError(f"{name} is not in VERSIONS.yaml")
    rel = entry.get("path")
    if not rel:
        raise KeyError(f"{name} has no `path` in VERSIONS.yaml")
    return ROOT / rel


def rel_path(name: str) -> str:
    """Repo-relative package directory, as VERSIONS.yaml states it."""
    return str(registry()[name]["path"])


def group(name: str) -> str:
    return str(registry()[name].get("group") or "platform")


def groups() -> list[str]:
    """Distinct groups, in first-seen order."""
    seen: list[str] = []
    for name in registry():
        g = group(name)
        if g not in seen:
            seen.append(g)
    return seen


def baseline_paths(name: str) -> list[str]:
    """Repo-relative directories this package may occupy, newest layout first.

    The flat `package/<name>` entry covers release tags cut before RFC-007's move; the
    `package/platform/<name>` entry covers an archived package (RFC-003 §Removing the old
    kinds): gone from the current registry entirely, but still real at the baseline tag.
    `tests/api_compat.py`'s own `packages()` unions such names in from the baseline specifically
    to classify their removal, so this must resolve a historical path without the name being
    registered now — see `.gitea/scripts/release-state.py` for the mirror-image use.
    """
    try:
        out = [rel_path(name)]
    except KeyError:
        out = []
    for candidate in (f"package/{name}", f"package/platform/{name}"):
        if candidate not in out:
            out.append(candidate)
    return out


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = args[0], args[1:]
    if cmd == "list":
        for n in names(include_utilities="--all" in rest):
            print(n)
    elif cmd == "pairs":
        for n in names(include_utilities="--all" in rest):
            print(f"{n}={rel_path(n)}")
    elif cmd == "path":
        print(rel_path(rest[0]))
    elif cmd == "group":
        print(group(rest[0]))
    elif cmd == "groups":
        for g in groups():
            print(g)
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
