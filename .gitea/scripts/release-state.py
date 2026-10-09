#!/usr/bin/env python3
"""
release-state.py — the release commit is the whole truth; CI only builds what it says.

A release is named release-YYYY-MM-DD (UTC; .2, .3 … for a second one that day).
`make release` calls this to decide which packages a release rebuilds, and to
write that decision into the tree before the tag is cut:

  VERSIONS.yaml      packages.<pkg>.package.current = the release it last changed in
  package/install/   spec.package pinned to ghcr.io/wxops-idp/wxops-core/<pkg>:<release>

CI then builds exactly the packages whose `current` equals the pushed tag. No
job commits back to main: a bot rewriting install manifests after the tag is
how commit f22f0d7 put every manifest back on the Gitea registry.

Compatibility is not carried by the release name. It is the XRD API version,
held additive-only by tests/api_compat.py — which `write` runs as its gate.

Usage:
  release-state.py next                          today's unused release name
  release-state.py plan [--all]                  packages changed since the last release
  release-state.py write <release> [--all]       gate, then pin VERSIONS.yaml + package/install/
  release-state.py check                         VERSIONS.yaml and package/install/ agree
  release-state.py summary <release> [--draft]   markdown package table for a release body
  release-state.py notes <release>               release-notes scaffold, table filled in
"""
from __future__ import annotations

import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests" / "lib"))
import packages as P  # noqa: E402
import releases as REL  # noqa: E402
import yaml  # noqa: E402

REGISTRY = "ghcr.io/wxops-idp/wxops-core"
VERSIONS = ROOT / "VERSIONS.yaml"
INSTALL = ROOT / "package" / "install"
NOTES = ROOT / "release-notes"
ALLOWLIST = ROOT / "tests" / "api-compat-allow.yaml"
MARKER = "<!-- compatibility-report -->"

MANIFEST = """\
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: wxops-core-{pkg}
spec:
  package: {image}
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
"""


def install_path(pkg: str) -> Path:
    """Where this package's install Configuration lives: install/<group>/<pkg>.yaml."""
    return INSTALL / P.group(pkg) / f"{pkg}.yaml"


def packages() -> dict:
    return (yaml.safe_load(VERSIONS.read_text()) or {}).get("packages") or {}


def current(info) -> str:
    return str(((info or {}).get("package") or {}).get("current") or "")


def image(pkg: str, release: str) -> str:
    return f"{REGISTRY}/{pkg}:{release}"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def next_name() -> str:
    base = f"release-{dt.datetime.now(dt.timezone.utc):%Y-%m-%d}"
    name, n = base, 2
    while REL.tag_exists(name):
        name, n = f"{base}.{n}", n + 1
    return name


def changed(all_: bool = False) -> list[str]:
    """Packages whose published content differs from the last release.

    Only package/<pkg>/*.yaml is packaged by `crossplane xpkg build`. KCL needs
    no separate check: kcl-drift-check forces composition.yaml to change with
    main.k, and README.md is not part of the package.
    """
    prev = REL.previous_tag()
    out = []
    for pkg in packages():
        # Compare file CONTENT, not paths: the baseline tag may predate RFC-007's
        # move, and a package that only changed directory has not changed what it
        # publishes. A path-based `git diff` would mark every package changed.
        base_dir = None
        if prev is not None:
            base_dir = next((d for d in P.baseline_paths(pkg)
                             if REL.show(prev, f"{d}/xrd.yaml") is not None), None)
        if all_ or prev is None or base_dir is None:
            out.append(pkg)
            continue
        cur_dir = P.path(pkg)
        packaged = lambda name: name.endswith(".yaml") and name != "kustomization.yaml"
        old_names = {p.rsplit("/", 1)[-1] for p in REL.ls(prev, base_dir)
                     if packaged(p.rsplit("/", 1)[-1])}
        new_names = {f.name for f in cur_dir.glob("*.yaml") if packaged(f.name)}
        if old_names != new_names or any(
                REL.show(prev, f"{base_dir}/{n}") != (cur_dir / n).read_text()
                for n in sorted(new_names)):
            out.append(pkg)
    return out


def compat(baseline: str | None) -> dict:
    """tests/api_compat.py --json against `baseline`."""
    if baseline is None:
        return {"baseline": None, "packages": {}, "failed": [], "stale": []}
    proc = subprocess.run(
        [sys.executable, "tests/api_compat.py", "--json", "--baseline", baseline],
        cwd=ROOT, capture_output=True, text=True,
    )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        sys.exit(f"error: tests/api_compat.py produced no report\n{proc.stderr}")


# ── Gate + write ────────────────────────────────────────────────────────────

def gate(release: str) -> None:
    """Refuse a release that breaks the API, or changes it without saying so."""
    report = compat(REL.previous_tag())
    if report["failed"]:
        subprocess.run([sys.executable, "tests/api_compat.py"], cwd=ROOT)
        sys.exit(f"\nerror: {release} would ship a breaking change that is not allowed — see above")

    notable = {p: e["tier"] for p, e in report["packages"].items() if e["tier"] != "safe"}
    notes = NOTES / f"{release}.md"
    if notable:
        listing = ", ".join(f"{p} ({t})" for p, t in notable.items())
        if not notes.exists():
            sys.exit(f"error: {listing} — anything not `safe` needs release notes.\n"
                     f"  make release-notes VERSION={release}\n"
                     f"  then explain each change under Compatibility and re-run.")
        if not re.search(r"(?m)^## Compatibility\b", notes.read_text()):
            sys.exit(f"error: {rel(notes)} has no '## Compatibility' section, "
                     f"and {listing} need one.")
    for entry in report.get("stale") or []:
        print(f"  note: unused allowance {entry.get('package')} {entry.get('rule')} "
              f"{entry.get('path')} — cleared by this release")


def set_current(text: str, pkg: str, value: str) -> str:
    """Rewrite one package's `current:` line, leaving every comment intact."""
    lines = text.splitlines(keepends=True)
    in_block = False
    for i, line in enumerate(lines):
        header = re.match(r"^  ([A-Za-z0-9][A-Za-z0-9-]*):\s*$", line)
        if header:
            in_block = header.group(1) == pkg
        elif re.match(r"^\S", line):
            in_block = False
        elif in_block and re.match(r"^\s+current:", line):
            lines[i] = re.sub(r"(current:\s*)\S+", lambda m: m.group(1) + value, line)
            return "".join(lines)
    sys.exit(f"error: no `current:` for {pkg} in {rel(VERSIONS)}")


def write_manifest(pkg: str, release: str) -> None:
    path = install_path(pkg)
    ref = image(pkg, release)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(MANIFEST.format(pkg=pkg, image=ref))
        # Register the manifest in its group's kustomization, and the group in the
        # top-level one, so a brand-new group installs without a hand edit.
        kust = path.parent / "kustomization.yaml"
        if not kust.exists():
            kust.write_text("apiVersion: kustomize.config.k8s.io/v1beta1\n"
                            "kind: Kustomization\nresources:\n")
        if f"- {pkg}.yaml" not in kust.read_text():
            kust.write_text(kust.read_text().rstrip("\n") + f"\n  - {pkg}.yaml\n")
        top = INSTALL / "kustomization.yaml"
        group_entry = f"- {P.group(pkg)}/"
        if group_entry not in top.read_text():
            top.write_text(top.read_text().rstrip("\n") + f"\n  {group_entry}\n")
        return
    text = path.read_text()
    text = re.sub(r"(?m)^(\s*package:\s*)\S+$", lambda m: m.group(1) + ref, text, count=1)
    # The annotation never tracked anything — every manifest said v0.1.0.
    text = re.sub(r"(?m)^\s*meta\.crossplane\.io/version:.*\n", "", text)
    text = re.sub(r"(?m)^  annotations:\s*\n(?=\S|  \S)", "", text)
    path.write_text(text)


def clear_allowlist() -> None:
    if ALLOWLIST.exists():
        text = ALLOWLIST.read_text()
        ALLOWLIST.write_text(re.sub(r"(?ms)^allow:.*\Z", "allow: []\n", text))


def write(release: str, all_: bool, run_gate: bool = True) -> None:
    if not REL.RELEASE_RE.match(release):
        sys.exit(f"error: '{release}' is not a release name (expected release-YYYY-MM-DD[.N])")
    if REL.tag_exists(release):
        sys.exit(f"error: tag {release} already exists")
    if run_gate:
        gate(release)

    build = changed(all_)
    text = VERSIONS.read_text()
    for pkg in build:
        text = set_current(text, pkg, release)
        write_manifest(pkg, release)
    VERSIONS.write_text(text)
    clear_allowlist()

    for pkg, info in packages().items():
        if pkg in build:
            print(f"  build      {pkg} → {image(pkg, release)}")
        else:
            print(f"  unchanged  {pkg} (last changed in {current(info)})")
    if not build:
        print(f"  no package changed since {REL.previous_tag()} — {release} rebuilds nothing")


# ── Check ───────────────────────────────────────────────────────────────────

def check() -> int:
    problems, legacy = [], []
    for pkg, info in packages().items():
        cur = current(info)
        path = install_path(pkg)
        if cur == "unreleased":
            if path.exists():
                problems.append(f"{pkg}: `current: unreleased` but {rel(path)} exists")
            continue
        if not REL.is_release_tag(cur):
            problems.append(f"{pkg}: `current: {cur}` is neither release-YYYY-MM-DD[.N], "
                            f"a legacy vX.Y.Z, nor `unreleased`")
            continue
        if not path.exists():
            problems.append(f"{pkg}: no {rel(path)} for released package")
            continue
        m = re.search(r"(?m)^\s*package:\s*(\S+)$", path.read_text())
        repo, _, tag = (m.group(1) if m else "").rpartition(":")
        if tag != cur:
            problems.append(f"{pkg}: {rel(path)} pins `{tag or '?'}`, VERSIONS.yaml says `{cur}`")
        want = f"{REGISTRY}/{pkg}"
        if repo != want:
            if REL.RELEASE_RE.match(cur):
                problems.append(f"{pkg}: {rel(path)} pulls from `{repo}`, not `{want}`")
            else:
                legacy.append(pkg)  # pinned before date-named releases existed

    if legacy:
        print(f"  note  {len(legacy)} legacy pin(s) not on {REGISTRY}: {', '.join(legacy)} — "
              f"the first `make release ALL=1` moves them")
    if problems:
        for p in problems:
            print(f"  DRIFT {p}")
        print("        package/install/ and VERSIONS.yaml are written by `make release` —"
              " never by hand.")
        return 1
    print("  ok    VERSIONS.yaml and package/install/ agree")
    return 0


# ── Summary ─────────────────────────────────────────────────────────────────

def _kind(pkg: str) -> str:
    xrd = P.path(pkg) / "xrd.yaml"
    doc = yaml.safe_load(xrd.read_text()) if xrd.exists() else {}
    return ((doc.get("spec") or {}).get("names") or {}).get("kind", "?")


def summary(release: str, draft: bool = False) -> str:
    pk = packages()
    if draft or not REL.tag_exists(release):
        baseline, built = REL.previous_tag(), set(changed())
    else:
        baseline = REL.previous_tag(before=release)
        built = {p for p, info in pk.items() if current(info) == release}
    report = compat(baseline)

    rows = ["| Package | Kind | API | Change | In this release |", "|---|---|---|---|---|"]
    notable = []
    for pkg, info in pk.items():
        api = ", ".join(f"`{v}`" for v in ((info or {}).get("api") or {}).get("served") or [])
        entry = report["packages"].get(pkg) or {}
        if pkg in built:
            change, state = f"`{entry.get('tier', 'safe')}`", f"rebuilt — `{image(pkg, release)}`"
        else:
            change, state = "—", f"unchanged since `{current(info)}`"
        rows.append(f"| `{pkg}` | `{_kind(pkg)}` | {api} | {change} | {state} |")
        for f in entry.get("findings") or []:
            if f["tier"] == "safe":
                continue
            allowed = " (allowed)" if f.get("allowed") else ""
            detail = f" — {f['detail']}" if f.get("detail") else ""
            notable.append(f"- `{pkg}` · **{f['tier']}**{allowed} · `{f['rule']}` · "
                           f"`{f['path']}`{detail}")

    head = (f"API group `platform.wxops.cloud`. Change tiers are measured against `{baseline}` "
            f"by `tests/api_compat.py`." if baseline else
            "First release — there is no earlier release to measure changes against.")
    out = [head, "", *rows]
    if notable:
        out += ["", "Changes that are not additive:", "", *notable]
    return "\n".join(out) + "\n"


def notes(release: str) -> str:
    template = (NOTES / "template.md").read_text()
    return template.replace(MARKER, summary(release, draft=True).rstrip("\n"))


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    pos = [a for a in rest if not a.startswith("-")]

    if cmd in ("check", "--check"):
        return check()
    if cmd == "next":
        print(next_name())
        return 0
    if cmd == "plan":
        build = changed("--all" in rest)
        print("\n".join(build) if build else f"(nothing changed since {REL.previous_tag()})")
        return 0
    if cmd in ("write", "summary", "notes"):
        if not pos:
            sys.exit(f"usage: release-state.py {cmd} <release>")
        if cmd == "write":
            write(pos[0], "--all" in rest, run_gate="--no-gate" not in rest)
        elif cmd == "summary":
            print(summary(pos[0], "--draft" in rest), end="")
        else:
            print(notes(pos[0]), end="")
        return 0
    sys.exit(f"error: unknown command '{cmd}' — see --help")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
