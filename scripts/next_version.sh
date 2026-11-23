#!/usr/bin/env bash
# Prints the next SemVer (MAJOR.MINOR.PATCH, no "v") for HEAD.
#
# Source of truth = git tags vX.Y.Z. The bump is decided from Conventional
# Commit messages since the last tag:
#   feat!: / fix!: / "BREAKING CHANGE:"  -> MAJOR
#   feat:                               -> MINOR
#   anything else (fix:, chore:, deps)  -> PATCH  (every change that ships gets a new version)
# If HEAD is already tagged, prints that version (makes re-runs idempotent).
set -euo pipefail

last_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
if [[ -z "$last_tag" ]]; then
  base="0.0.0"
  range="HEAD"
else
  base="${last_tag#v}"
  range="${last_tag}..HEAD"
fi

IFS=. read -r major minor patch <<<"$base"
log=$(git log --format='%s%n%b' "$range")

if [[ -z "$log" ]]; then
  echo "$base"   # nothing new since last release
  exit 0
fi

if grep -qE '^[a-z]+(\([^)]*\))?!:|^BREAKING[ -]CHANGE:' <<<"$log"; then
  echo "$((major + 1)).0.0"
elif grep -qE '^feat(\([^)]*\))?:' <<<"$log"; then
  echo "${major}.$((minor + 1)).0"
else
  echo "${major}.${minor}.$((patch + 1))"
fi
