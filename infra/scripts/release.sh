#!/usr/bin/env bash
# Publish the version in VERSION as a Git tag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) echo "usage: release.sh [--root PATH]"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
cd "$ROOT"
[[ -s VERSION ]] || { echo "error: missing VERSION" >&2; exit 2; }

version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: VERSION must be bare semver X.Y.Z" >&2
  exit 2
}

[[ "$(id -un)" == "user" ]] || {
  echo "error: release must run as user; v* tags are protected" >&2
  exit 2
}
[[ -z "$(git status --porcelain)" ]] || {
  echo "error: worktree is not clean" >&2
  exit 1
}
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || {
  echo "error: release from main" >&2
  exit 1
}

git fetch origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
  echo "error: main is not up to date with origin/main" >&2
  exit 1
}

tag="v$version"
git rev-parse --verify "$tag" >/dev/null 2>&1 && {
  echo "error: tag already exists: $tag" >&2
  exit 1
}

bash "$SCRIPT_DIR/check-version.sh" --root "$ROOT" --version "$version"
bash "$SCRIPT_DIR/ci/validate-publish-targets.sh" --root "$ROOT"

git tag "$tag"
git push origin "$tag"
echo "released $tag"
