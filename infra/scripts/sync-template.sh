#!/usr/bin/env bash
# Copy the shared template bundle into a consumer repository.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATES=""
TARGET=""
FORCE=0
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|--repo)
      [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --templates)
      [[ $# -ge 2 ]] || { echo "error: --templates needs a value" >&2; exit 2; }
      TEMPLATES="$2"; shift 2 ;;
    --force)
      FORCE=1; shift ;;
    --version)
      [[ $# -ge 2 ]] || { echo "error: --version needs a value" >&2; exit 2; }
      VERSION="$2"; shift 2 ;;
    -h|--help)
      echo "usage: sync-template.sh --templates PATH --target PATH [--force] [--version X.Y.Z]"
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "error: --target is required" >&2; exit 2; }
[[ -n "$TEMPLATES" ]] || { echo "error: --templates is required" >&2; exit 2; }
[[ -d "$TEMPLATES" ]] || { echo "error: templates not found: $TEMPLATES" >&2; exit 2; }
TEMPLATES="$(cd "$TEMPLATES" && pwd)"
[[ -d "$TARGET" ]] || { echo "error: target not found: $TARGET" >&2; exit 2; }
TARGET="$(cd "$TARGET" && pwd)"
[[ "$TARGET" != "$ROOT" ]] || { echo "error: target must not be this repository" >&2; exit 2; }

source_version="${VERSION:-$(tr -d '[:space:]' < "$TEMPLATES/VERSION")}"
[[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: VERSION must be bare semver X.Y.Z" >&2
  exit 2
}
target_config="$TARGET/infra/config/repo.json"
[[ -s "$target_config" ]] || { echo "error: missing $target_config" >&2; exit 2; }
target_version="$(jq -r '.template.ref // .template.version // "0"' "$target_config")"

if (( ! FORCE )) && [[ "$target_version" == "$source_version" ]]; then
  echo "template already at $source_version; use --force to overwrite"
  exit 0
fi

files=(
  .gitea/pull_request_template.md
  .gitea/issue_template/config.yaml
  .gitea/issue_template/bug.md
  .gitea/issue_template/docs.md
  .gitea/issue_template/feature.md
  .gitea/issue_template/idea.md
  .gitea/issue_template/problem.md
  src/data/coverage.json
)

source_dir="$TEMPLATES/repo"
for f in "${files[@]}"; do
  src="$source_dir/$f"
  [[ -s "$src" ]] || { echo "error: missing template file: $src" >&2; exit 1; }
  mkdir -p "$TARGET/$(dirname "$f")"
  cp "$src" "$TARGET/$f"
  [[ "$f" == *.sh ]] && chmod +x "$TARGET/$f"
  echo "synced $f"
done

if [[ -s "$TEMPLATES/workflows/ci.yml" ]]; then
  mkdir -p "$TARGET/.gitea/workflows"
  cp "$TEMPLATES/workflows/ci.yml" "$TARGET/.gitea/workflows/ci.yml"
  echo "synced .gitea/workflows/ci.yml"
fi

tmp="$(mktemp)"
jq --arg v "$source_version" '.template.ref = $v | del(.template.version)' "$target_config" > "$tmp"
mv "$tmp" "$target_config"
echo "template version: ${target_version} -> ${source_version}"
