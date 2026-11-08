#!/usr/bin/env bash
# Check or apply the shared AGENTS guardrail blocks.
#
# The canonical blocks live in docs/agents/blocks/ of this repository. A target
# repository keeps the markers and its local rules; everything between the
# markers is generated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEMPLATES=""

MODE=""
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --repo|--root)
      [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    --templates)
      [[ $# -ge 2 ]] || { echo "error: --templates needs a value" >&2; exit 2; }
      TEMPLATES="$2"; shift 2 ;;
    -h|--help)
      echo "usage: sync-agents.sh --templates PATH --check|--apply [--repo PATH]"
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "error: choose --check or --apply" >&2; exit 2; }
[[ -n "$TEMPLATES" ]] || { echo "error: --templates is required" >&2; exit 2; }
[[ -d "$TEMPLATES" ]] || { echo "error: templates not found: $TEMPLATES" >&2; exit 2; }
TEMPLATES="$(cd "$TEMPLATES" && pwd)"
BLOCKS="$TEMPLATES/agents/blocks"
REPO="${REPO:-$PWD}"
[[ -d "$REPO" ]] || { echo "error: repo not found: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
CONFIG="$REPO/infra/config/repo.json"
AGENTS="$REPO/AGENTS.md"

if [[ "$MODE" == "apply" ]]; then
  [[ "$(id -un)" == "gitea-automation" || "$(id -un)" == "gitea-automation" ]] || {
    echo "error: --apply must run as gitea-automation or gitea-automation (current: $(id -un))" >&2
    exit 2
  }
fi

[[ -s "$CONFIG" ]] || { echo "error: missing $CONFIG" >&2; exit 2; }
[[ -s "$AGENTS" ]] || { echo "error: missing $AGENTS" >&2; exit 2; }

fail() { echo "ERROR: $*" >&2; exit 1; }

require_field() {
  local expr="$1" label="$2"
  jq -e "$expr" "$CONFIG" >/dev/null || fail "$label must be valid in $CONFIG"
}

require_field '.organization | type == "string" and length > 0' ".organization"
require_field '.layer | type == "number" and . >= 0 and . <= 4' ".layer"
require_field '.depends_on | type == "array"' ".depends_on"
require_field '.consumers | type == "array"' ".consumers"
require_field '.data_classification | IN("public","private","personal","secret")' ".data_classification"

has_marker() {
  grep -qxF "$1" "$2"
}

marker_count() {
  grep -cxF "$1" "$AGENTS" || true
}

extract_block() {
  awk -v b="$2" -v e="$3" '
    $0 == b { on = 1; next }
    $0 == e { on = 0; next }
    on { print }
  ' "$1"
}

replace_block() {
  local file="$1" begin="$2" end="$3" block="$4" tmp
  tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" -v blk="$block" '
    $0 == b {
      print b
      while ((getline line < blk) > 0) print line
      close(blk)
      print e
      skip = 1
      next
    }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

render_identity() {
  local org layer repo_id parent runtime central deps consumers data
  org="$(jq -r '.organization' "$CONFIG")"
  layer="$(jq -r '.layer' "$CONFIG")"
  repo_id="$org/$(jq -r '.name' "$CONFIG")"
  parent="templates/md"
  runtime="dashboards/devops"
  central="infra/templates/md/docs/agents/README.md"
  deps="$(jq -r '(.depends_on // []) | if length == 0 then "none" else join(", ") end' "$CONFIG")"
  consumers="$(jq -r '(.consumers // []) | if length == 0 then "none" else join(", ") end' "$CONFIG")"
  data="$(jq -r '.data_classification' "$CONFIG")"
  cat <<EOF
## Repository identity

- Org: $org
- Layer: $layer
- Contract parent: $parent
- Runtime dependency: $runtime
- Depends on: $deps
- Consumed by: $consumers
- Local root: ~/repos/$repo_id
- Backup group: $org
- Data classification: $data
- Central index: $central
EOF
  if [[ -x "$CANONICAL_ROOT/infra/scripts/render-hubs.sh" ]]; then
    "$CANONICAL_ROOT/infra/scripts/render-hubs.sh" --root "$REPO"
  fi
}

blocks=(operating-model issue-workflow decision-records dependency-reading scripts)
optional_blocks=(knowledge-mode coverage self-improvement local-issues docs-links)
errors=0

check_markers() {
  local name="$1" begin="<!-- begin $1 -->" end="<!-- end $1 -->"
  if ! has_marker "$begin" "$AGENTS"; then
    echo "ERROR: missing $begin in AGENTS.md" >&2
    errors=$((errors + 1))
  fi
  if ! has_marker "$end" "$AGENTS"; then
    echo "ERROR: missing $end in AGENTS.md" >&2
    errors=$((errors + 1))
  fi
  if [[ "$(marker_count "$begin" || true)" != "1" || "$(marker_count "$end" || true)" != "1" ]]; then
    echo "ERROR: $name markers must appear exactly once" >&2
    errors=$((errors + 1))
  fi
}

check_identity() {
  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"
  render_identity > "$expected"
  extract_block "$AGENTS" "<!-- begin repository-identity -->" "<!-- end repository-identity -->" > "$actual"
  if ! diff -u "$expected" "$actual" >/dev/null; then
    echo "ERROR: repository identity block is out of date in $AGENTS" >&2
    diff -u "$expected" "$actual" >&2 || true
    errors=$((errors + 1))
  fi
  rm -f "$expected" "$actual"
}

check_block() {
  local name="$1" block expected actual
  block="$BLOCKS/$name.md"
  [[ -s "$block" ]] || { echo "ERROR: missing canonical block $block" >&2; exit 2; }
  expected="$(mktemp)"
  actual="$(mktemp)"
  cat "$block" > "$expected"
  extract_block "$AGENTS" "<!-- begin $name -->" "<!-- end $name -->" > "$actual"
  if ! diff -u "$expected" "$actual" >/dev/null; then
    echo "ERROR: $name block is out of date in $AGENTS" >&2
    diff -u "$expected" "$actual" >&2 || true
    errors=$((errors + 1))
  fi
  rm -f "$expected" "$actual"
}

check_order() {
  local order name last=0 line
  order=(repository-identity operating-model issue-workflow decision-records dependency-reading knowledge-mode coverage self-improvement local-issues scripts)
  for name in "${order[@]}"; do
    line="$(grep -nxF "<!-- begin $name -->" "$AGENTS" | cut -d: -f1 || true)"
    if [[ -z "$line" ]]; then
      return
    fi
    if (( line < last )); then
      echo "ERROR: AGENTS blocks are out of order at $name" >&2
      errors=$((errors + 1))
      return
    fi
    last="$line"
  done
}

check_markers repository-identity
for name in "${blocks[@]}"; do
  check_markers "$name"
done
for name in "${optional_blocks[@]}"; do
  if has_marker "<!-- begin $name -->" "$AGENTS"; then
    check_markers "$name"
  fi
done
check_order
if [[ "$MODE" == "check" ]]; then
  check_identity
  for name in "${blocks[@]}"; do
    check_block "$name"
  done
  for name in "${optional_blocks[@]}"; do
    if has_marker "<!-- begin $name -->" "$AGENTS"; then
      check_block "$name"
    fi
  done
fi

if (( errors > 0 )); then
  echo "agents drift detected; run: $0 --apply --repo $REPO" >&2
  exit 1
fi

if [[ "$MODE" == "check" ]]; then
  echo "agents ok: $REPO"
  exit 0
fi

tmp_identity="$(mktemp)"
render_identity > "$tmp_identity"
replace_block "$AGENTS" "<!-- begin repository-identity -->" "<!-- end repository-identity -->" "$tmp_identity"
rm -f "$tmp_identity"
for name in "${blocks[@]}"; do
  replace_block "$AGENTS" "<!-- begin $name -->" "<!-- end $name -->" "$BLOCKS/$name.md"
done
for name in "${optional_blocks[@]}"; do
  if has_marker "<!-- begin $name -->" "$AGENTS"; then
    replace_block "$AGENTS" "<!-- begin $name -->" "<!-- end $name -->" "$BLOCKS/$name.md"
  fi
done
echo "agents updated: $REPO"
