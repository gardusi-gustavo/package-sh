#!/usr/bin/env bash
# Exercise the local issue validator.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/infra/scripts/ci/validate-local-issues.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_issue() {
  local dir="$1" file="$2" rank="$3" type="$4" status="$5" platform="${6:-null}"
  mkdir -p "$dir/docs/issues"
  jq -n --arg id "$rank" --arg type "$type" --arg status "$status" --argjson platform "$platform" \
    '{id:$id,rank:$id,type:$type,title:"Example",status:$status,source:"agent",author:"gardusi-gustavo-bot",created:"2026-11-07",platform_issue_id:$platform,platform_issue_url:(if $platform == null then null else "http://example/1" end),attempts:[],limits:{max_commits:5,max_file_changes:4},spec:{summary:"Example",acceptance_criteria:["Done"]}}' > "$dir/docs/issues/$file"
}

ok="$tmp/ok"; make_issue "$ok" 3.9-fix-auth.json 3.9 bug backlog
"$HELPER" --root "$ok" >/dev/null

bad_name="$tmp/bad-name"; make_issue "$bad_name" 3.9_fix.json 3.9 bug backlog
if "$HELPER" --root "$bad_name" >/dev/null 2>&1; then echo "error: bad filename passed" >&2; exit 1; fi

dup="$tmp/dup"; make_issue "$dup" 3.9-a.json 3.9 bug backlog; make_issue "$dup" 3.9-b.json 3.9 bug backlog
if "$HELPER" --root "$dup" >/dev/null 2>&1; then echo "error: duplicate rank passed" >&2; exit 1; fi

two="$tmp/two"; make_issue "$two" 3.9-a.json 3.9 bug active 7; make_issue "$two" 3.8-b.json 3.8 bug active 8
if "$HELPER" --root "$two" >/dev/null 2>&1; then echo "error: two active issues passed" >&2; exit 1; fi

type="$tmp/type"; make_issue "$type" 3.9-a.json 3.9 documentation backlog
if "$HELPER" --root "$type" >/dev/null 2>&1; then echo "error: wrong type passed" >&2; exit 1; fi

echo "local issue fixtures: ok"
