#!/usr/bin/env bash
# Common lint suite. Runs before every repo-specific ci.sh.
set -euo pipefail

ROOT="${CI_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"

section() {
  printf '\n== %s ==\n' "$*"
}

section "whitespace"
base="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-${CI_COMMIT_BEFORE_SHA:-}}"
if [ -n "$base" ] \
   && [ "$base" != "0000000000000000000000000000000000000000" ] \
   && git cat-file -e "${base}^{commit}" 2>/dev/null; then
  git diff --check "$base" HEAD
else
  git diff --check
fi

section "shellcheck"
shell_files=()
while IFS= read -r -d '' file; do
  shell_files+=("$file")
done < <(git ls-files -z -- '*.sh' '*.bash')
if [ "${#shell_files[@]}" -gt 0 ]; then
  shellcheck -S warning "${shell_files[@]}"
fi

section "hadolint"
docker_files=()
while IFS= read -r -d '' file; do
  docker_files+=("$file")
done < <(git ls-files -z -- '*Dockerfile*' '*.dockerfile')
if [ "${#docker_files[@]}" -gt 0 ]; then
  hadolint --failure-threshold error "${docker_files[@]}"
fi

section "done"
