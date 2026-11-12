#!/usr/bin/env python3
"""
Golden-file tests for every Composition.

The unit under test is the composition itself: given an XR (plus optionally the
observed state of its composed resources and any required/extra resources), it
must render exactly the resources recorded in expected.yaml.

Usage:
    python3 tests/golden.py              # verify — used by CI and pre-commit
    python3 tests/golden.py --update      # regenerate goldens after an
                                          # intentional composition change
    python3 tests/golden.py app           # limit to one package

Adding a case: create tests/cases/<package>/<case>/xr.yaml (plus observed.yaml
and required.yaml if the case needs them), then run --update and READ THE DIFF
before committing it. A golden file accepted without reading is not a test.
"""
from __future__ import annotations

import difflib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import render as R  # noqa: E402


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    update = "--update" in sys.argv or "-u" in sys.argv

    cases = R.discover()
    if args:
        cases = [c for c in cases if c[0] in args]
    if not cases:
        print(f"{R.RED}no test cases found{R.RESET} (looked in tests/cases/)")
        return 1

    failed: list[str] = []
    written = 0
    print(f"golden render tests — {len(cases)} case(s)\n")

    for package, case, case_dir in cases:
        label = f"{package}/{case}"
        ok, out, err = R.render(case_dir, package)
        if not ok:
            print(f"  {R.RED}RENDER FAIL{R.RESET}  {label}")
            for line in err.splitlines()[:6]:
                print(f"      {R.DIM}{line}{R.RESET}")
            failed.append(label)
            continue

        golden = case_dir / "expected.yaml"
        if update:
            prev = golden.read_text() if golden.exists() else ""
            if prev != out:
                golden.write_text(out)
                written += 1
                verb = "updated" if prev else "created"
                print(f"  {R.YELLOW}{verb:<11}{R.RESET}{label}")
            else:
                print(f"  {R.DIM}unchanged   {label}{R.RESET}")
            continue

        if not golden.exists():
            print(f"  {R.RED}NO GOLDEN{R.RESET}    {label}")
            print(f"      {R.DIM}run: make test-update{R.RESET}")
            failed.append(label)
            continue

        want = golden.read_text()
        if want == out:
            print(f"  {R.GREEN}ok{R.RESET}           {label}")
        else:
            print(f"  {R.RED}DIFF{R.RESET}         {label}")
            diff = difflib.unified_diff(
                want.splitlines(), out.splitlines(),
                fromfile=f"{golden.relative_to(R.ROOT)} (expected)",
                tofile="rendered (actual)", lineterm="", n=2,
            )
            shown = 0
            for line in diff:
                if shown >= 40:
                    print(f"      {R.DIM}... diff truncated{R.RESET}")
                    break
                colour = R.GREEN if line.startswith("+") else R.RED if line.startswith("-") else R.DIM
                print(f"      {colour}{line}{R.RESET}")
                shown += 1
            failed.append(label)

    print()
    if update:
        print(f"{len(cases)} case(s), {written} golden file(s) written")
        print(f"{R.YELLOW}Read the diff before committing.{R.RESET}")
        return 0
    if failed:
        print(f"{R.RED}FAILED{R.RESET} {len(failed)}/{len(cases)}: {', '.join(failed)}")
        print("\nIf a change was intentional: make test-update, then review the diff.")
        return 1
    print(f"{R.GREEN}all {len(cases)} golden test(s) passed{R.RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
