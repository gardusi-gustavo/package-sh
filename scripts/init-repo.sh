#!/usr/bin/env bash
# Apply shared Git ignore and attribute templates to a repository.
set -euo pipefail
ROOT="."
ECOSYSTEM="base"
GIT_TEMPLATES="${TEMPLATES_GIT_ROOT:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --ecosystem) ECOSYSTEM="$2"; shift 2 ;;
    --git-templates) GIT_TEMPLATES="$2"; shift 2 ;;
    -h|--help) echo "usage: init-repo.sh --ecosystem NAME [--root PATH] [--git-templates PATH]"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$GIT_TEMPLATES" && -d "$GIT_TEMPLATES" ]] || { echo "error: set --git-templates or TEMPLATES_GIT_ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"
{
  cat "$GIT_TEMPLATES/ignore/base.gitignore"
  [[ -f "$GIT_TEMPLATES/ignore/$ECOSYSTEM.gitignore" ]] && cat "$GIT_TEMPLATES/ignore/$ECOSYSTEM.gitignore"
} > "$ROOT/.gitignore"
cp "$GIT_TEMPLATES/attributes/base.gitattributes" "$ROOT/.gitattributes"
echo "applied $ECOSYSTEM ignore and base attributes to $ROOT"
