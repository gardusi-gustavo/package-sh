#!/usr/bin/env bash
# Create a full snapshot bundle, immutable per-tag bundles, and manifests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-}"
shift || true
ROOT="${BUNDLE_BACKUP_ROOT:-/srv/backup/git-bundles}"
MAX_SNAPSHOTS="${BUNDLE_MAX_SNAPSHOTS:-5}"
SOURCE=""
ENCRYPT=0
PASSFILE="${BACKUP_PASSPHRASE_FILE:-/srv/backup/secrets/backup.pass}"
TAGS=1
MIRRORS=()

usage() {
  cat <<'EOF'
usage: bundle-backup.sh <owner/repo> [options]

  --source PATH        local bare repository or clone (default: GitHub HTTPS)
  --backup-root DIR    destination root (default: /srv/backup/git-bundles)
  --max-snapshots N    snapshots to keep per repository (default: 5)
  --encrypt            encrypt bundles with GPG (required for private repos)
  --passphrase-file F  GPG passphrase file (default: /srv/backup/secrets/backup.pass)
  --mirror DIR         copy the repository bundle tree to DIR (repeatable)
  --no-tags            skip tag bundles
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --backup-root) ROOT="${2:-}"; shift 2 ;;
    --max-snapshots) MAX_SNAPSHOTS="${2:-}"; shift 2 ;;
    --encrypt) ENCRYPT=1; shift ;;
    --passphrase-file) PASSFILE="${2:-}"; shift 2 ;;
    --mirror) MIRRORS+=("${2:-}"); shift 2 ;;
    --no-tags) TAGS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" && "$REPO" == */* ]] || { echo "error: owner/repo required" >&2; exit 2; }
[[ "$MAX_SNAPSHOTS" =~ ^[0-9]+$ ]] && (( MAX_SNAPSHOTS >= 1 )) || {
  echo "error: --max-snapshots must be an integer >= 1" >&2; exit 2; }
if (( ENCRYPT )); then
  [[ -r "$PASSFILE" ]] || { echo "error: cannot read passphrase file: $PASSFILE" >&2; exit 2; }
  command -v gpg >/dev/null || { echo "error: gpg is required" >&2; exit 2; }
fi
command -v git >/dev/null || { echo "error: git is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 2; }

REPO_DIR="$ROOT/$REPO"
SNAPSHOT_DIR="$REPO_DIR/snapshots"
TAG_DIR="$REPO_DIR/tags"
mkdir -p "$SNAPSHOT_DIR" "$TAG_DIR"
exec 9>"$REPO_DIR/.lock"
if ! flock -n 9; then
  echo "backup: $REPO is already being bundled" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-backup.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mirror_clone="$work/repo.git"
source_desc="${SOURCE:-https://github.com/$REPO.git}"
echo "== clone $source_desc"
GIT_TERMINAL_PROMPT=0 git clone --mirror --quiet "$source_desc" "$mirror_clone"
head_before="$(git -C "$mirror_clone" rev-parse HEAD)"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot_tmp="$work/snapshot.bundle"
git -C "$mirror_clone" bundle create "$snapshot_tmp" --branches --tags
git -C "$mirror_clone" bundle verify "$snapshot_tmp" >/dev/null

FINAL_PATH=""
finalize() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if (( ENCRYPT )); then
    local encrypted="$dest.gpg"
    gpg --batch --yes --symmetric --cipher-algo AES256 \
      --passphrase-file "$PASSFILE" --output "$encrypted" "$src"
    rm -f "$src"
    local plain="$work/verify.bundle"
    gpg --batch --yes --decrypt --passphrase-file "$PASSFILE" \
      --output "$plain" "$encrypted"
    git -C "$mirror_clone" bundle verify "$plain" >/dev/null
    rm -f "$plain"
    FINAL_PATH="$encrypted"
  else
    mv "$src" "$dest"
    git -C "$mirror_clone" bundle verify "$dest" >/dev/null
    FINAL_PATH="$dest"
  fi
}

snapshot_dest="$SNAPSHOT_DIR/$stamp.bundle"
suffix=1
while [[ -e "$snapshot_dest" || -e "$snapshot_dest.gpg" ]]; do
  snapshot_dest="$SNAPSHOT_DIR/${stamp}-${suffix}.bundle"
  suffix=$((suffix + 1))
done
finalize "$snapshot_tmp" "$snapshot_dest"
snapshot_final="$FINAL_PATH"
head_after="$(git -C "$mirror_clone" rev-parse HEAD)"
[[ "$head_before" == "$head_after" ]] || {
  echo "error: repository HEAD changed during bundle creation" >&2; exit 1; }

if (( TAGS )); then
  while IFS=$'\t' read -r tag_name tag_ref; do
    [[ -n "$tag_name" && -n "$tag_ref" ]] || continue
    commit="$(git -C "$mirror_clone" rev-list -n1 "$tag_ref")"
    short="${commit:0:7}"
    safe_tag="${tag_name//\//_}"
    tag_dest="$TAG_DIR/${safe_tag}-${short}.bundle"
    [[ -e "$tag_dest" || -e "$tag_dest.gpg" ]] && continue
    tag_tmp="$work/tag.bundle"
    git -C "$mirror_clone" bundle create "$tag_tmp" "$tag_ref"
    git -C "$mirror_clone" bundle verify "$tag_tmp" >/dev/null
    finalize "$tag_tmp" "$tag_dest"
  done < <(git -C "$mirror_clone" for-each-ref \
    --format='%(refname:short)%09%(refname)' refs/tags)
fi

mapfile -t snapshots < <(find "$SNAPSHOT_DIR" -maxdepth 1 -type f \
  \( -name '*.bundle' -o -name '*.bundle.gpg' \) -printf '%f\n' | sort)
if (( ${#snapshots[@]} > MAX_SNAPSHOTS )); then
  remove=$(( ${#snapshots[@]} - MAX_SNAPSHOTS ))
  for ((i=0; i<remove; i++)); do
    rm -f "$SNAPSHOT_DIR/${snapshots[$i]}"
  done
fi

python3 "$SCRIPT_DIR/bundle-manifest.py" --root "$ROOT" --repo "$REPO"

for mirror in "${MIRRORS[@]}"; do
  [[ -n "$mirror" ]] || continue
  mkdir -p "$mirror/$REPO"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$REPO_DIR/" "$mirror/$REPO/"
  else
    cp -a "$REPO_DIR/." "$mirror/$REPO/"
  fi
  (cd "$mirror/$REPO" && sha256sum -c SHA256SUMS >/dev/null)
  echo "mirrored: $mirror/$REPO"
done

echo "snapshot: $snapshot_final"
echo "snapshots kept: $(find "$SNAPSHOT_DIR" -maxdepth 1 -type f \( -name '*.bundle' -o -name '*.bundle.gpg' \) | wc -l | tr -d ' ')"
echo "tags kept: $(find "$TAG_DIR" -maxdepth 1 -type f \( -name '*.bundle' -o -name '*.bundle.gpg' \) | wc -l | tr -d ' ')"
