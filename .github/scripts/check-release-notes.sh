#!/usr/bin/env bash
# .github/scripts/check-release-notes.sh
#
# Scaffolds release-notes/<release>.md: release-notes/template.md with its
# Compatibility section pre-filled from tests/api_compat.py, plus a git-cliff
# reference block of the commits going into the release.
#
# Required when a release carries a `careful` or `breaking` change — `make
# release` refuses without it. Optional otherwise: the release body CI builds
# always carries the package table and the changelog.
#
# Usage: bash .github/scripts/check-release-notes.sh <release>
#        make release-notes [VERSION=release-YYYY-MM-DD]

set -euo pipefail

NOTES_DIR="release-notes"

version="${1:?usage: check-release-notes.sh <release>}"
notes_file="${NOTES_DIR}/${version}.md"

if [[ -f "$notes_file" ]]; then
  echo "✓ ${notes_file} already exists — nothing to do"
  exit 0
fi

echo "→ generating ${notes_file} from template"

# Build into a temp file: a failed compatibility report must not leave a
# half-written notes file behind for `make release` to accept.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  python3 .github/scripts/release-state.py notes "$version"
  printf '\n---\n\n'
  printf '<!-- Reference block: upcoming commits for this release.\n'
  printf '     Use this to write your Highlights, then REMOVE this section.\n'
  printf '     CI appends the final git-cliff changelog automatically. -->\n\n'
  if command -v git-cliff &>/dev/null; then
    git-cliff --unreleased --strip all 2>/dev/null \
      || printf '<!-- git-cliff: no unreleased commits found -->\n'
  else
    printf '<!-- git-cliff not installed — run: pip install git-cliff -->\n'
  fi
} > "$tmp"
cat "$tmp" > "$notes_file"

printf '\n'
printf '   Generated: %s\n' "${notes_file}"
printf '\n'
printf '   Fill in Highlights, explain every Compatibility row that is not `safe`,\n'
printf '   and remove the reference block at the bottom. `make release` commits it.\n'
printf '\n'
