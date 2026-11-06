#!/usr/bin/env bash
# Fail when a repository still uses the old root layout.
set -euo pipefail

ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "error: --root needs a value" >&2; exit 2; }
      ROOT="$2"
      shift 2
      ;;
    -h|--help)
      echo "usage: check-layout.sh [--root PATH]"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -d "$ROOT" ]] || { echo "error: root not found: $ROOT" >&2; exit 2; }
cd "$ROOT"

errors=0
fail() { echo "ERROR: $*" >&2; errors=$((errors+1)); }

for dir in src infra docs; do
  [[ -d "$dir" ]] || fail "missing required directory: $dir/"
done

for f in README.md infra/config/repo.json infra/docker/ci.dockerfile infra/scripts/ci.sh; do
  [[ -s "$f" ]] || fail "missing required file: $f"
done

for old in config docker data scripts .github .gitlab-ci.yml; do
  [[ -e "$old" ]] && fail "old root path still present: $old"
done
[[ -e infra/data ]] && fail "infra/data is retired; use src/data"
[[ -e infra/README.md ]] && fail "Move infra/README.md to docs/"


allowed="src infra docs templates .gitea"
while IFS= read -r top; do
  [[ -n "$top" ]] || continue
  case " $allowed " in
    *" $top "*) ;;
    *) fail "unexpected top-level directory: $top/ (move it under src/ or infra/)" ;;
  esac
done < <(git ls-files | awk -F/ 'NF > 1 { print $1 }' | sort -u)

(( errors == 0 )) || exit 1
echo "layout ok: src/ + infra/ + docs/ + templates/"
