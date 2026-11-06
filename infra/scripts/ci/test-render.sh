#!/usr/bin/env bash
# Exercise the CI profile and hub renderers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CI="$ROOT/infra/scripts/render-ci-profile.sh"
HUBS="$ROOT/infra/scripts/render-hubs.sh"

[[ "$("$CI" --root "$ROOT")" == "ci-universal" ]] || {
  echo "error: toolkit CI profile is not ci-universal" >&2
  exit 1
}

out="$("$HUBS" --root "$ROOT")"
grep -q 'Practice hub' <<<"$out" || { echo "error: practice hub missing" >&2; exit 1; }
grep -q 'Automation hub' <<<"$out" || { echo "error: automation hub missing" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/infra/config"
jq -n '{organization:"packages",name:"example",ci:{profile:"python"},hubs:{practice:7,automation:8}}' > "$tmp/infra/config/repo.json"
[[ "$("$CI" --root "$tmp")" == "ci-python" ]] || { echo "error: python profile not rendered" >&2; exit 1; }
hubs="$("$HUBS" --root "$tmp")"
grep -q '/packages/example/issues/7' <<<"$hubs" || { echo "error: practice link wrong" >&2; exit 1; }
grep -q '/packages/example/issues/8' <<<"$hubs" || { echo "error: automation link wrong" >&2; exit 1; }

echo "render fixtures: ok"
