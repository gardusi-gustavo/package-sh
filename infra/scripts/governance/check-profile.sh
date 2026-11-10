#!/usr/bin/env bash
# Verify the profile README matches the governance inventory.
set -euo pipefail
README=""
INV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readme) README="${2:-}"; shift 2 ;;
    --inventory) INV="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: check-profile.sh --inventory PATH --readme PATH"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$README" && -r "$README" ]] || { echo "error: --readme PATH is required" >&2; exit 2; }
[[ -n "$INV" && -r "$INV" ]] || { echo "error: --inventory PATH is required" >&2; exit 2; }

errors=0
fail(){ echo "ERROR: $*" >&2; errors=$((errors+1)); }

mapfile -t public < <(jq -r '.repos[] | select(.visibility=="public") | .github' "$INV"; jq -r '.meta[] | select(.visibility=="public") | .github' "$INV")
mapfile -t private < <(jq -r '.repos[] | select(.visibility=="private") | .github' "$INV"; jq -r '.meta[] | select(.visibility=="private") | .github' "$INV")

for repo in "${public[@]}"; do
  grep -q "https://github.com/$repo" "$README" || fail "missing public link: $repo"
done
for repo in "${private[@]}"; do
  if grep -q "https://github.com/$repo" "$README"; then fail "private link must not be public: $repo"; fi
done
(( errors == 0 )) || exit 1
echo "profile inventory: ok (public=${#public[@]} private=${#private[@]})"
