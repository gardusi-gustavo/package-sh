#!/usr/bin/env bash
# Print the runner label for the repository's ci.profile.
set -euo pipefail

ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "error: --root needs a value" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "usage: render-ci-profile.sh [--root PATH]"
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$ROOT" ]] || { echo "error: root not found: $ROOT" >&2; exit 2; }
CONFIG="$ROOT/infra/config/repo.json"
[[ -s "$CONFIG" ]] || { echo "error: missing $CONFIG" >&2; exit 1; }

profile="$(jq -r '.ci.profile // "universal"' "$CONFIG")"
case "$profile" in
  universal|base|python|node|go|rust|cpp|java|media|dotnet|ruby|php) ;;
  *) echo "error: invalid ci.profile: $profile" >&2; exit 1 ;;
esac

echo "ci-$profile"
