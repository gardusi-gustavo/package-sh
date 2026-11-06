#!/usr/bin/env bash
# Oldest-PR merge gate. The oldest open PR in a repository must merge or close
# before a newer PR can merge.
set -euo pipefail

REPO=""
PR=""
TOKEN=""
API="${GITEA_URL:-${GITHUB_SERVER_URL:-http://gitea.localhost:3001}}"
FIXTURE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --api) API="${2:-}"; shift 2 ;;
    --fixture) FIXTURE="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: validate-pr-count.sh --repo OWNER/REPO --pr N [--token TOKEN] [--fixture FILE]"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" && -z "$FIXTURE" ]]; then
  echo "pr count: skipped (not a pull request)"
  exit 0
fi
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || { echo "error: --repo must be OWNER/REPO" >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "error: --pr must be a number" >&2; exit 2; }

if [[ -n "$FIXTURE" ]]; then
  [[ -r "$FIXTURE" ]] || { echo "error: cannot read fixture: $FIXTURE" >&2; exit 2; }
  prs="$(cat "$FIXTURE")"
else
  if [[ -z "$TOKEN" ]]; then
    echo "warning: no API token; merge gate skipped" >&2
    exit 0
  fi
  prs="$(curl -fsS -H "Authorization: token $TOKEN" \
    "${API%/}/api/v1/repos/$REPO/pulls?state=open&limit=100")" || {
    echo "error: cannot list open PRs for $REPO" >&2
    exit 2
  }
fi

oldest="$(jq -r 'sort_by(.created_at) | .[0].number // empty' <<<"$prs")"
[[ -n "$oldest" ]] || { echo "pr count: no open PRs"; exit 0; }

if [[ "$PR" != "$oldest" ]]; then
  echo "pr count: FAILED" >&2
  echo "  PR #$oldest is older in $REPO; merge or close it first" >&2
  exit 1
fi
echo "pr count: ok (#$PR is the oldest open PR)"
