#!/usr/bin/env bash
# Create a new lightweight tag on the current HEAD of a local repository and
# optionally push it to origin.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ship-tag.sh --source PATH --tag TAG [--push]

Options:
  --repo PATH     repository directory containing .git (alias: --source)
  --tag TAG       new tag name
  --push          push the new tag to origin
  -h, --help      show this help

The script never moves or deletes an existing tag.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

SOURCE=""
TAG=""
PUSH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source|--repo)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      SOURCE="$2"; shift 2 ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag needs a value"
      TAG="$2"; shift 2 ;;
    --push)
      PUSH=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE" ]] || die "--repo is required"
[[ -n "$TAG" ]] || die "--tag is required"
[[ -d "$SOURCE" ]] || die "source not found: $SOURCE"
git -C "$SOURCE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree: $SOURCE"

if git -C "$SOURCE" rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag already exists, refusing to move it: $TAG"
fi

git -C "$SOURCE" tag "$TAG" HEAD
echo "created $TAG at $(git -C "$SOURCE" rev-parse HEAD) in $SOURCE"

if [[ "$PUSH" -eq 1 ]]; then
  git -C "$SOURCE" push origin "refs/tags/$TAG"
  echo "pushed $TAG"
fi
