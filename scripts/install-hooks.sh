#!/usr/bin/env bash
# Install the shared Git hooks into a repository.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="."
HOOKS_DIR=".githooks"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --hooks-dir) HOOKS_DIR="$2"; shift 2 ;;
    -h|--help) echo "usage: install-hooks.sh [--root PATH] [--hooks-dir NAME]"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
ROOT="$(cd "$ROOT" && pwd)"
DEST="$ROOT/$HOOKS_DIR"
mkdir -p "$DEST"
cp "$SCRIPT_DIR/../hooks/pre-commit" "$SCRIPT_DIR/../hooks/commit-msg" "$SCRIPT_DIR/../hooks/pre-push" "$DEST/"
cp "$SCRIPT_DIR/pr-limit" "$SCRIPT_DIR/pr-size" "$SCRIPT_DIR/pr-size-check.sh" "$DEST/"
chmod +x "$DEST/pre-commit" "$DEST/commit-msg" "$DEST/pre-push" "$DEST/pr-limit" "$DEST/pr-size" "$DEST/pr-size-check.sh"
git -C "$ROOT" config core.hooksPath "$HOOKS_DIR"
echo "installed hooks in $DEST (core.hooksPath=$HOOKS_DIR)"
