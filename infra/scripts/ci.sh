#!/usr/bin/env bash
set -euo pipefail
ROOT="${CI_PROJECT_DIR:-$PWD}"
cd "$ROOT"
"$ROOT/infra/scripts/ci/validate-repo.sh" --root "$ROOT"
"$ROOT/infra/scripts/ci/test-repo-contract.sh"
"$ROOT/infra/scripts/ci/test-publish-targets.sh"
"$ROOT/infra/scripts/ci/test-render.sh"
"$ROOT/infra/scripts/check-version.sh" --root "$ROOT"
"$ROOT/infra/scripts/ci/check-size.sh" --root "$ROOT"
if [[ -x "$ROOT/infra/scripts/check-layout.sh" ]]; then
  "$ROOT/infra/scripts/check-layout.sh" --root "$ROOT"
fi
while IFS= read -r -d '' f; do
  bash -n "$f"
done < <(find "$ROOT/infra/scripts" -name '*.sh' -print0)
