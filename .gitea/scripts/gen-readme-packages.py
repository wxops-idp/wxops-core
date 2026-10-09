#!/usr/bin/env python3
"""
gen-readme-packages.py — sync the Packages table in README.md from VERSIONS.yaml.

Reads VERSIONS.yaml for package names, versions, and API versions. Reads each
package/{name}/xrd.yaml for the Kind name. Replaces the block between
<!-- packages-table-start --> and <!-- packages-table-end --> in README.md.

Usage:
  python3 .gitea/scripts/gen-readme-packages.py          # sync README.md
  python3 .gitea/scripts/gen-readme-packages.py --check  # exit 1 if out of sync
"""

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests" / "lib"))
import packages as P  # noqa: E402

START = "<!-- packages-table-start -->"
END = "<!-- packages-table-end -->"


def build_table() -> str:
    versions = yaml.safe_load((ROOT / "VERSIONS.yaml").read_text())
    rows = []
    for name, info in versions.get("packages", {}).items():
        pkg_dir = P.rel_path(name)
        xrd = yaml.safe_load((ROOT / pkg_dir / "xrd.yaml").read_text())
        kind = xrd["spec"]["names"]["kind"]
        api_versions = ", ".join(f"`{v}`" for v in info["api"]["served"])
        pkg_version = info["package"]["current"]
        rows.append(
            f"| [`{name}`]({pkg_dir}/) | `{kind}` | `{P.group(name)}.wxops.cloud`"
            f" | {api_versions} | `{pkg_version}` |"
        )
    return "\n".join([
        "| Package | Kind | Group | API Versions | Last changed in |",
        "|---|---|---|---|---|",
        *rows,
    ])


def main() -> int:
    check_only = "--check" in sys.argv[1:]
    readme_path = ROOT / "README.md"
    readme = readme_path.read_text()

    if START not in readme or END not in readme:
        print(f"ERROR: markers not found in README.md", file=sys.stderr)
        print(f"  Expected '{START}' ... '{END}' around the packages table.", file=sys.stderr)
        return 1

    table = build_table()
    pre = readme[: readme.index(START) + len(START)]
    post = readme[readme.index(END) :]
    new_readme = f"{pre}\n{table}\n{post}"

    if new_readme == readme:
        print("  ok    README.md packages table is up to date")
        return 0

    if check_only:
        print("  DRIFT README.md packages table is out of sync with VERSIONS.yaml")
        print("         Run: make readme-sync")
        return 1

    readme_path.write_text(new_readme)
    print("  synced README.md packages table")
    return 0


if __name__ == "__main__":
    sys.exit(main())
