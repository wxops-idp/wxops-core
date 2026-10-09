#!/usr/bin/env python3
"""
kcl-sync.py — embed kcl/{pkg}/main.k into package/{pkg}/composition.yaml

The kcl/ directory is the authoritative source for KCL logic.
This script re-indents main.k and splices it into the spec.source block
of the corresponding Crossplane composition so xpkg build picks it up.

Usage:
  python3 .gitea/scripts/kcl-sync.py                  # sync all KCL packages
  python3 .gitea/scripts/kcl-sync.py platform-database-clusters # sync one package
  python3 .gitea/scripts/kcl-sync.py --check           # exit 1 if any composition is out of sync

How it works:
  composition.yaml has this structure (indentation matters):
      ...
              spec:
                source: |        <- MARKER (10-space indent + "source: |")
                  <KCL content>  <- 12-space indent
  The script splits on the marker, discards the old content, and appends
  the re-indented main.k. The composition YAML structure is preserved
  because source: | is always the last key in the KCLInput spec block.
"""

import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests" / "lib"))
import packages as P  # noqa: E402

KCL_PACKAGES = ["platform-database-clusters", "tenant-database", "tenant-app"]

# The YAML block scalar marker as it appears in composition.yaml.
# 10 spaces + "source: |" matches the nesting depth of KCLInput.spec.source.
MARKER = "          source: |\n"
INDENT = "            "  # 12 spaces — one level deeper than the marker


def build_indented_source(kcl_text: str) -> str:
    """Re-indent KCL source for embedding into the YAML block scalar."""
    lines = []
    for line in kcl_text.splitlines():
        lines.append(INDENT + line if line.strip() else "")
    # Ensure a single trailing newline so YAML stays well-formed.
    return "\n".join(lines) + "\n"


def sync_package(pkg: str, check_only: bool = False) -> bool:
    src_file = ROOT / "kcl" / pkg / "main.k"
    comp_file = P.path(pkg) / "composition.yaml"

    if not src_file.exists():
        print(f"  skip  {pkg}: kcl/{pkg}/main.k not found")
        return True

    kcl_text = src_file.read_text()
    comp_text = comp_file.read_text()

    if MARKER not in comp_text:
        print(f"  ERROR {pkg}: marker '{MARKER.strip()}' not found in composition.yaml",
              file=sys.stderr)
        return False

    # Split on the marker — everything before it is kept, everything after
    # (the old KCL block) is replaced with the fresh content from main.k.
    before, _ = comp_text.split(MARKER, maxsplit=1)
    new_text = before + MARKER + build_indented_source(kcl_text)

    if check_only:
        if new_text != comp_text:
            print(f"  DRIFT {pkg}: composition.yaml is out of sync with kcl/{pkg}/main.k")
            print(f"         Run: make kcl-sync")
            return False
        print(f"  ok    {pkg}")
        return True

    comp_file.write_text(new_text)
    print(f"  synced {pkg}")
    return True


def main() -> int:
    args = sys.argv[1:]
    check_only = "--check" in args
    targets = [a for a in args if not a.startswith("--")] or KCL_PACKAGES

    ok = True
    for pkg in targets:
        if pkg not in KCL_PACKAGES:
            print(f"  unknown package: {pkg} (known: {', '.join(KCL_PACKAGES)})", file=sys.stderr)
            ok = False
            continue
        if not sync_package(pkg, check_only=check_only):
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
