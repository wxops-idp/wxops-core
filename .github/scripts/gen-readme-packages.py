#!/usr/bin/env python3
"""
gen-readme-packages.py — sync the Packages table in README.md from VERSIONS.yaml.

Reads VERSIONS.yaml for package names, versions, and API versions. Reads each
package/{name}/xrd.yaml for the Kind name. Replaces the block between
<!-- packages-table-start --> and <!-- packages-table-end --> in README.md, and the
two badges derived from the same file (package count, served API versions) between
<!-- badges-dynamic-start --> and <!-- badges-dynamic-end -->.

Usage:
  python3 .github/scripts/gen-readme-packages.py          # sync README.md
  python3 .github/scripts/gen-readme-packages.py --check  # exit 1 if out of sync
"""

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests" / "lib"))
import packages as P  # noqa: E402

START = "<!-- packages-table-start -->"
END = "<!-- packages-table-end -->"
B_START = "<!-- badges-dynamic-start -->"
B_END = "<!-- badges-dynamic-end -->"


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


def build_badges() -> str:
    """The badges that follow VERSIONS.yaml, so they cannot drift from the packages table."""
    versions = yaml.safe_load((ROOT / "VERSIONS.yaml").read_text())
    packages = versions.get("packages", {})
    served = sorted({v for info in packages.values() for v in info["api"]["served"]})
    return "\n".join([
        f"[![Packages](https://img.shields.io/badge/packages-{len(packages)}-blue)](#packages)",
        f"[![API](https://img.shields.io/badge/API-{'%20%7C%20'.join(served)}-orange)](docs/api-reference/status-contract.md#api-version)",
    ])


def main() -> int:
    check_only = "--check" in sys.argv[1:]
    readme_path = ROOT / "README.md"
    readme = readme_path.read_text()

    for a, b, what in ((START, END, "the packages table"), (B_START, B_END, "the dynamic badges")):
        if a not in readme or b not in readme:
            print(f"ERROR: markers not found in README.md", file=sys.stderr)
            print(f"  Expected '{a}' ... '{b}' around {what}.", file=sys.stderr)
            return 1

    table = build_table()
    pre = readme[: readme.index(START) + len(START)]
    post = readme[readme.index(END) :]
    new_readme = f"{pre}\n{table}\n{post}"

    pre = new_readme[: new_readme.index(B_START) + len(B_START)]
    post = new_readme[new_readme.index(B_END) :]
    new_readme = f"{pre}\n{build_badges()}\n{post}"

    if new_readme == readme:
        print("  ok    README.md packages table and badges are up to date")
        return 0

    if check_only:
        print("  DRIFT README.md packages table or badges are out of sync with VERSIONS.yaml")
        print("         Run: make readme-sync")
        return 1

    readme_path.write_text(new_readme)
    print("  synced README.md packages table and badges")
    return 0


if __name__ == "__main__":
    sys.exit(main())
