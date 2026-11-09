#!/usr/bin/env bash
# Bundle every repository in the canonical topological order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${BUNDLE_BACKUP_ROOT:-/srv/backup/git-bundles}"
ORDER="${BUNDLE_ORDER:-}"
SOURCE_ROOT="${BUNDLE_SOURCE_ROOT:-/srv/gitea/data/git/repositories}"
PROFILE_SOURCE="${BUNDLE_PROFILE_SOURCE:-/home/user/repos/gardusi-gustavo/gardusi-gustavo}"
MODE="local"
MAX_SNAPSHOTS="${BUNDLE_MAX_SNAPSHOTS:-5}"
PASSFILE="${BACKUP_PASSPHRASE_FILE:-/srv/backup/secrets/backup.pass}"
DRY_RUN=0
ENCRYPT_PRIVATE=0
MIRRORS=()
ONLY=()

usage() {
  cat <<'EOF'
usage: bundle-all.sh [options]

  --github              bundle from GitHub HTTPS instead of local bare repos
  --source-root DIR     local bare repository root
  --profile-source DIR  local profile repository
  --root DIR            bundle destination root
  --max-snapshots N     snapshots kept per repository
  --encrypt-private     encrypt the private repository bundle
  --passphrase-file F   GPG passphrase file
  --mirror DIR          mirror each repository bundle tree (repeatable)
  --only owner/repo      bundle only this repository (repeatable)
  --order FILE          bundle order JSON (or BUNDLE_ORDER)
  --dry-run             print the commands only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github) MODE="github"; shift ;;
    --source-root) SOURCE_ROOT="${2:-}"; shift 2 ;;
    --profile-source) PROFILE_SOURCE="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --max-snapshots) MAX_SNAPSHOTS="${2:-}"; shift 2 ;;
    --encrypt-private) ENCRYPT_PRIVATE=1; shift ;;
    --passphrase-file) PASSFILE="${2:-}"; shift 2 ;;
    --mirror) MIRRORS+=("${2:-}"); shift 2 ;;
    --only) ONLY+=("${2:-}"); shift 2 ;;
    --order) ORDER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$ORDER" && -r "$ORDER" ]] || { echo "error: set BUNDLE_ORDER or pass --order" >&2; exit 2; }
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }

run_one() {
  local repo="$1" source="" encrypt=0
  local args=()
  if [[ "$MODE" == "local" ]]; then
    if [[ "$repo" == "gardusi-gustavo/gardusi-gustavo" ]]; then
      source="$PROFILE_SOURCE"
    elif [[ "$repo" == "gardusi-gustavo/private" ]]; then
      source="$SOURCE_ROOT/human/private.git"
    else
      source="$SOURCE_ROOT/$repo.git"
    fi
    [[ -d "$source" ]] || { echo "error: missing source: $source" >&2; exit 1; }
    args+=(--source "$source")
  fi
  if (( ENCRYPT_PRIVATE )) && [[ "$repo" == "gardusi-gustavo/private" ]]; then
    encrypt=1
  fi
  args+=(--backup-root "$ROOT" --max-snapshots "$MAX_SNAPSHOTS")
  (( encrypt )) && args+=(--encrypt --passphrase-file "$PASSFILE")
  for mirror in "${MIRRORS[@]}"; do
    [[ -n "$mirror" ]] && args+=(--mirror "$mirror")
  done
  echo "== $repo"
  if (( DRY_RUN )); then
    printf 'bundle-backup.sh %q %s\n' "$repo" "${args[*]}"
  else
    "$SCRIPT_DIR/bundle-backup.sh" "$repo" "${args[@]}"
  fi
}

if (( ${#ONLY[@]} > 0 )); then
  for repo in "${ONLY[@]}"; do
    [[ -n "$repo" ]] || continue
    run_one "$repo"
  done
else
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    run_one "$repo"
  done < <(jq -r '.tiers[].repos[]' "$ORDER")
fi

echo "bundle order complete"
