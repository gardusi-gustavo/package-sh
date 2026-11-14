#!/usr/bin/env bash
# Agent entry point. Runs inside the caller repository.
# Usage: agent.sh <code|adjust> <issue-or-pr-number> [comment]
set -euo pipefail

mode="${1:?mode: code or adjust}"
number="${2:?issue or pull request number}"
comment="${3:-}"
repo="${GITHUB_REPOSITORY:?}"
model="${OPENCODE_MODEL:-deepseek/deepseek-flash}"

if ! command -v opencode >/dev/null 2>&1; then
  npm install -g opencode-ai
fi

case "$mode" in
  code)
    title="$(gh issue view "$number" --repo "$repo" --json title --jq .title)"
    body="$(gh issue view "$number" --repo "$repo" --json body --jq .body)"
    prompt="Implement issue #${number} in this repository.

Title: ${title}

Body:
${body}

Rules:
- read AGENTS.md and follow it;
- make the smallest change that satisfies the issue;
- do not modify .github/workflows/**;
- run the repository tests before finishing;
- do not commit; the workflow commits."
    ;;
  adjust)
    title="$(gh pr view "$number" --repo "$repo" --json title --jq .title)"
    body="$(gh pr view "$number" --repo "$repo" --json body --jq .body)"
    prompt="Adjust the current pull request #${number} in this repository.

Title: ${title}

Current description:
${body}

Requested adjustment:
${comment}

Rules:
- keep the change minimal;
- do not modify .github/workflows/**;
- run the repository tests before finishing;
- do not commit; the workflow commits."
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

opencode run --model "$model" --auto "$prompt"
