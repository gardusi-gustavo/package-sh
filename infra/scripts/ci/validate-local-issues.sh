#!/usr/bin/env bash
# Validate local issue records in docs/issues.
set -euo pipefail

ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "error: --root needs a value" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "usage: validate-local-issues.sh [--root PATH]"
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$ROOT" ]] || { echo "error: root not found: $ROOT" >&2; exit 2; }
DIR="$ROOT/docs/issues"
if [[ ! -d "$DIR" ]]; then
  echo "local issues: none"
  exit 0
fi

errors=0
fail() { echo "ERROR: $*" >&2; errors=$((errors + 1)); }
active=0
count=0
declare -A seen=()

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  base="$(basename "$file")"
  case "$base" in
    README.md|schema.json|template.json) continue ;;
  esac
  count=$((count + 1))

  if [[ ! "$base" =~ ^([123])\.([0-9]{1,6})-([a-z0-9-]+)\.json$ ]]; then
    fail "$base: filename must match <3|2|1>.<1-6 digits>-<slug>.json"
    continue
  fi
  prefix="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  frac="${BASH_REMATCH[2]}"
  [[ "$frac" != *0 ]] || fail "$base: rank must not end in zero"

  jq empty "$file" >/dev/null 2>&1 || { fail "$base: invalid JSON"; continue; }

  id="$(jq -r '.id // empty' "$file")"
  rank="$(jq -r '.rank // empty' "$file")"
  type="$(jq -r '.type // empty' "$file")"
  status="$(jq -r '.status // empty' "$file")"
  [[ "$id" == "$prefix" ]] || fail "$base: id must be $prefix"
  [[ "$rank" == "$prefix" ]] || fail "$base: rank must be $prefix"
  [[ -n "${seen[$rank]:-}" ]] && fail "$base: duplicate rank $rank"
  seen[$rank]=1

  case "$prefix" in
    3.*) expected="bug" ;;
    2.*) expected="documentation" ;;
    1.*) expected="enhancement" ;;
  esac
  [[ "$type" == "$expected" ]] || fail "$base: type must be $expected for rank $prefix"

  case "$status" in
    backlog|active|blocked) ;;
    *) fail "$base: status must be backlog, active, or blocked" ;;
  esac

  jq -e '.source | type == "string" and length > 0' "$file" >/dev/null || fail "$base: source is required"
  jq -e '.author | type == "string" and length > 0' "$file" >/dev/null || fail "$base: author is required"
  jq -e '.created | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")' "$file" >/dev/null || fail "$base: created must be YYYY-MM-DD"
  jq -e '.attempts | type == "array"' "$file" >/dev/null || fail "$base: attempts must be an array"
  jq -e '.limits.max_commits | type == "number" and . >= 1 and floor == .' "$file" >/dev/null || fail "$base: limits.max_commits must be a positive integer"
  jq -e '.limits.max_file_changes | type == "number" and . >= 1 and floor == .' "$file" >/dev/null || fail "$base: limits.max_file_changes must be a positive integer"
  jq -e '.spec | type == "object"' "$file" >/dev/null || fail "$base: spec is required"
  jq -e '.spec.summary | type == "string" and length > 0' "$file" >/dev/null || fail "$base: spec.summary is required"
  jq -e '.spec.acceptance_criteria | type == "array" and length > 0' "$file" >/dev/null || fail "$base: spec.acceptance_criteria is required"
  jq -e 'if has("tags") then (.tags | type == "array") else true end' "$file" >/dev/null || fail "$base: tags must be an array"

  if [[ "$status" == "active" ]]; then
    active=$((active + 1))
    jq -e '.platform_issue_id | type == "number" and . >= 1 and floor == .' "$file" >/dev/null || fail "$base: active issue requires platform_issue_id"
    jq -e '.platform_issue_url | type == "string" and length > 0' "$file" >/dev/null || fail "$base: active issue requires platform_issue_url"
  else
    jq -e '(.platform_issue_id // null) == null' "$file" >/dev/null || fail "$base: only an active issue may have platform_issue_id"
  fi

  lines="$(wc -l < "$file")"
  (( lines <= 300 )) || fail "$base: file exceeds 300 lines"
done < <(find "$DIR" -maxdepth 1 -type f -name '*.json' | sort)

(( active <= 1 )) || fail "more than one active issue"
(( errors == 0 )) || exit 1
echo "local issues: ok ($count files, $active active)"
