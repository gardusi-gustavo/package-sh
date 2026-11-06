#!/usr/bin/env bash
# Shared CI entrypoint. The workflow only calls /usr/local/bin/ci.
set -euo pipefail

cd "${CI_PROJECT_DIR:-/repo}"

git config --global --add safe.directory "$PWD" 2>/dev/null || true

ci-lint

if [ -x /repo/infra/scripts/ci/validate-repo.sh ]; then
  /repo/infra/scripts/ci/validate-repo.sh --root /repo
  /repo/infra/scripts/ci/check-size.sh --root /repo
fi

if [ ! -x /usr/local/bin/ci-repo ]; then
  echo "missing /usr/local/bin/ci-repo (infra/scripts/ci.sh was not copied into the image)" >&2
  exit 1
fi

exec /usr/local/bin/ci-repo "$@"
