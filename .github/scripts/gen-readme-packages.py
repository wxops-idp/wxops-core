#!/usr/bin/env python3
"""
gen-readme-packages.py — sync the Packages list in README.md (one collapsed <details> per API group) from VERSIONS.yaml.

Reads VERSIONS.yaml for package names, versions, and API versions. Reads each
package/{name}/xrd.yaml for the Kind name. Replaces the block between
<!-- packages-table-start --> and <!-- packages-table-end --> in README.md, and the
two badges derived from the same file (package count, served API versions) between
<!-- badges-dynamic-start --> and <!-- badges-dynamic-end -->, kept on the badge line.

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


# What each API group is for (ADR-005 decision 8). Scope is read from the XRDs, never written here; a group missing from GROUPS fails the sync.
GROUPS = {
    "tenant": ("what a team runs",
               "What a team runs: its applications and their databases. Each one is created in the team's own namespace, which decides whose it is and "
               "where it runs, so there is no owner, namespace or cluster to type."),
    "platform": ("shared capacity",
                 "Capacity the platform team provides to every team: PostgreSQL clusters, either a shared pool per environment or one dedicated to a "
                 "single database."),
    "scm": ("Git hosting",
            "Git hosting through OpenTofu: register a Gitea or GitHub service once, then create or observe its repositories, teams and OAuth apps. "
            "One module per resource serves every vendor."),
    "auth": ("identity and rules",
             "Identity and rules: the records the OIDC broker logs people in with (its connection, static users, clients and upstream connectors), "
             "personas that turn SCM teams into RBAC subjects and the bindings that grant them roles, and reviewed Kyverno policies."),
}
SCOPE_DETAIL = {
    "Namespaced": "a team's own, created in its namespace; the namespace's `wxops.cloud/owner` owns it",
    "Cluster": "one object for the whole cluster, written by the platform team",
}


def _first_sentence(text: str) -> str:
    text = " ".join(text.split())
    cut = text.find(". ")
    return text if cut == -1 else text[: cut + 1]


def build_table() -> str:
    versions = yaml.safe_load((ROOT / "VERSIONS.yaml").read_text())
    packages = versions.get("packages", {})
    by_group: dict[str, list[str]] = {}
    for name in packages:
        by_group.setdefault(P.group(name), []).append(name)
    missing = [g for g in by_group if g not in GROUPS]
    if missing:
        sys.exit(f"ERROR: no purpose text for API group(s) {missing} — add them to GROUPS in {Path(__file__).name}")

    blocks = []
    for group in [g for g in GROUPS if g in by_group]:
        rows, scopes = [], []
        for name in by_group[group]:
            info = packages[name]
            pkg_dir = P.rel_path(name)
            xrd = yaml.safe_load((ROOT / pkg_dir / "xrd.yaml").read_text())
            kind = xrd["spec"]["names"]["kind"]
            scope = xrd["spec"].get("scope", "Cluster")
            if scope not in scopes:
                scopes.append(scope)
            api_versions = ", ".join(f"`{v}`" for v in info["api"]["served"])
            api_page = Path("docs/api-reference") / group / f"{Path(pkg_dir).name}.md"
            docs = f"[API]({api_page})" if (ROOT / api_page).exists() else "—"
            rows.append(f"| [`{name}`]({pkg_dir}/) | `{kind}` | {_first_sentence(info.get('description', ''))} | {api_versions} "
                        f"| `{info['package']['current']}` | {docs} |")
        short, purpose = GROUPS[group]
        count = f"{len(rows)} package{'s' if len(rows) != 1 else ''}"
        blocks += [
            "<details>",
            f"<summary><b><code>{group}.wxops.cloud</code></b> · <b>{' + '.join(scopes)}</b> · {count} — {short}</summary>",
            "",
            purpose,
            "",
            *[f"**Scope:** `{sc}` — {SCOPE_DETAIL.get(sc, '')}." for sc in scopes],
            "",
            "| Package | Kind | What it does | API | Last changed in | Docs |",
            "|---|---|---|---|---|---|",
            *rows,
            "",
            "</details>",
        ]
    return "\n".join(blocks)


def build_badges() -> str:
    """The badges that follow VERSIONS.yaml, so they cannot drift from the packages table."""
    versions = yaml.safe_load((ROOT / "VERSIONS.yaml").read_text())
    packages = versions.get("packages", {})
    served = sorted({v for info in packages.values() for v in info["api"]["served"]})
    return " ".join([
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
    # Inline, not on their own lines: the badges share one line with their static neighbours.
    new_readme = f"{pre} {build_badges()}{post}"

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
