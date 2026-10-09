#!/usr/bin/env bash
# .gitea/scripts/validate-packages.sh
#
# Validates all Crossplane Configuration packages by running
# `crossplane xpkg build` against each package directory.
# Builds to a temp dir and cleans up — no .xpkg files left behind.
#
# Used by the `crossplane-validate` pre-commit hook and `make validate`.
# Requires the `crossplane` CLI on PATH.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# name=dir pairs from VERSIONS.yaml — the one resolver (see tests/lib/packages.py).
mapfile -t PAIRS < <(python3 "$ROOT_DIR/tests/lib/packages.py" pairs)
TMPDIR="$(mktemp -d)"
FAILED=()

trap 'rm -rf "$TMPDIR"' EXIT

if ! command -v crossplane &>/dev/null; then
  echo "error: crossplane CLI not found on PATH" >&2
  echo "  install: https://docs.crossplane.io/latest/cli/" >&2
  exit 1
fi

echo "crossplane xpkg build — validating ${#PAIRS[@]} packages"
echo ""

for pair in "${PAIRS[@]}"; do
  pkg="${pair%%=*}"
  pkg_dir="$ROOT_DIR/${pair#*=}"
  out="$TMPDIR/$pkg.xpkg"

  printf "  %-24s" "$pkg"

  if crossplane xpkg build \
    -f "$pkg_dir" \
    -o "$out" \
    --ignore kustomization.yaml \
    2>/tmp/xpkg-err-$pkg; then
    echo "✓"
  else
    echo "✗"
    FAILED+=("$pkg")
    cat /tmp/xpkg-err-$pkg >&2
  fi
done

echo ""

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "failed: ${FAILED[*]}" >&2
  exit 1
fi

echo "all packages valid"
