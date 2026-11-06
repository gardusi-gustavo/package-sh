#!/usr/bin/env bash
# Validate a consumer repository. Sibling scripts come from this checkout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CI_PROJECT_DIR:-$PWD}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) echo "usage: ci.sh [--root PATH]"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$ROOT"

"$SCRIPT_DIR/ci/validate-repo.sh" --root "$ROOT"
"$SCRIPT_DIR/check-version.sh" --root "$ROOT"
"$SCRIPT_DIR/ci/check-size.sh" --root "$ROOT"
if [[ -x "$SCRIPT_DIR/check-layout.sh" ]]; then
  "$SCRIPT_DIR/check-layout.sh" --root "$ROOT"
fi
