#!/usr/bin/env bash
# Print the repository's permanent hub links as Markdown.
set -euo pipefail

ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "error: --root needs a value" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "usage: render-hubs.sh [--root PATH]"
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$ROOT" ]] || { echo "error: root not found: $ROOT" >&2; exit 2; }
CONFIG="$ROOT/infra/config/repo.json"
[[ -s "$CONFIG" ]] || { echo "error: missing $CONFIG" >&2; exit 1; }

base="${GITEA_URL:-http://gitea.localhost:3001}"
repo="$(jq -r '[.organization, .name] | join("/")' "$CONFIG")"
practice="$(jq -r '.hubs.practice // empty' "$CONFIG")"
automation="$(jq -r '.hubs.automation // empty' "$CONFIG")"

if [[ -n "$practice" ]]; then
  echo "- Practice hub: [#${practice}](${base}/${repo}/issues/${practice})"
fi
if [[ -n "$automation" ]]; then
  echo "- Automation hub: [#${automation}](${base}/${repo}/issues/${automation})"
fi
