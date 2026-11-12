#!/usr/bin/env bash
# Repository test entrypoint used by the shared CI workflow.
set -euo pipefail

while IFS= read -r file; do
  bash -n "$file"
done < <(git ls-files '*.sh')

bash -n bin/sb
