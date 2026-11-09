#!/usr/bin/env bash
# Restore a snapshot and a tag bundle into temporary bare repositories and verify refs.
set -euo pipefail

REPO="${1:-}"
shift || true
ROOT="${BUNDLE_BACKUP_ROOT:-/srv/backup/git-bundles}"
OUT="${RESTORE_ROOT:-/tmp/restore-test}"
KEEP=0
STATUS_FILE=""
PASSFILE="${BACKUP_PASSPHRASE_FILE:-/srv/backup/secrets/backup.pass}"

usage() {
  cat <<'EOF'
usage: bundle-restore-test.sh <owner/repo> [options]

  --root DIR          bundle root (default: /srv/backup/git-bundles)
  --out DIR           restore directory (default: /tmp/restore-test)
  --status-file FILE  write a JSON result
  --keep              keep the restored repository
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --status-file) STATUS_FILE="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" && "$REPO" == */* ]] || { echo "error: owner/repo required" >&2; exit 2; }
REPO_DIR="$ROOT/$REPO"
[[ -d "$REPO_DIR" ]] || { echo "error: missing $REPO_DIR" >&2; exit 2; }
command -v git >/dev/null || { echo "error: git is required" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-restore.XXXXXX")"
git init --bare -q "$work/verify.git"
cleanup() {
  if (( ! KEEP )); then rm -rf "$work"; fi
}
trap cleanup EXIT

decrypt_if_needed() {
  local bundle="$1" plain="$2"
  if [[ "$bundle" == *.gpg ]]; then
    [[ -r "$PASSFILE" ]] || { echo "error: encrypted bundle needs $PASSFILE" >&2; return 1; }
    gpg --batch --yes --decrypt --passphrase-file "$PASSFILE" \
      --output "$plain" "$bundle" >/dev/null
    printf '%s' "$plain"
  else
    printf '%s' "$bundle"
  fi
}

restore_one() {
  local label="$1" bundle="$2" target="$3" plain verify_refs
  plain="$(decrypt_if_needed "$bundle" "$work/$label.bundle")"
  git -C "$work/verify.git" bundle verify "$plain" >/dev/null
  rm -rf "$target"
  git -c advice.defaultBranchName=false clone --bare "$plain" "$target" >/dev/null 2>&1
  git -C "$target" fsck --full >/dev/null
  git bundle list-heads "$plain" | awk '$2 ~ /^refs\/(heads|tags)\// {print $2}' | sort >"$work/$label.expected"
  git -C "$target" show-ref | awk '$2 ~ /^refs\/(heads|tags)\// {print $2}' | sort >"$work/$label.actual"
  if ! diff -u "$work/$label.expected" "$work/$label.actual" >/dev/null; then
    echo "error: restored refs do not match bundle: $label" >&2
    return 1
  fi
  head_ref="$(git -C "$target" for-each-ref --format='%(refname:short)' refs/heads refs/tags | sort | head -1)"
  if [[ -n "$head_ref" ]]; then
    head_short="$(git -C "$target" rev-parse --short "$head_ref")"
  else
    head_short="none"
  fi
  echo "$label refs=$(wc -l <"$work/$label.actual" | tr -d ' ') head=$head_short"
}

snapshot="$(find "$REPO_DIR/snapshots" -maxdepth 1 -type f \
  \( -name '*.bundle' -o -name '*.bundle.gpg' \) -printf '%f\n' | sort | tail -1 || true)"
[[ -n "$snapshot" ]] || { echo "error: no snapshot bundles for $REPO" >&2; exit 1; }
tag_bundle="$(find "$REPO_DIR/tags" -maxdepth 1 -type f \
  \( -name '*.bundle' -o -name '*.bundle.gpg' \) -printf '%f\n' | sort | tail -1 || true)"

target="$OUT/${REPO//\//__}"
mkdir -p "$OUT"
restore_one snapshot "$REPO_DIR/snapshots/$snapshot" "$target"
if [[ -n "$tag_bundle" ]]; then
  restore_one tag "$REPO_DIR/tags/$tag_bundle" "$target-tag"
fi

if [[ -n "$STATUS_FILE" ]]; then
  mkdir -p "$(dirname "$STATUS_FILE")"
  jq -n --arg repository "$REPO" --arg snapshot "$snapshot" \
    --arg tag "$tag_bundle" --arg tested_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg result pass \
    '{repository:$repository,snapshot:$snapshot,tag:$tag,tested_at:$tested_at,result:$result}' \
    >"$STATUS_FILE"
fi

echo "restore test passed: $REPO"
