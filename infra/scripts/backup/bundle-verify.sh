#!/usr/bin/env bash
# Verify every bundle, checksum manifest, and manifest/index consistency.
set -euo pipefail

ROOT="${1:-${BUNDLE_BACKUP_ROOT:-/srv/backup/git-bundles}}"
PASSFILE="${BACKUP_PASSPHRASE_FILE:-/srv/backup/secrets/backup.pass}"
[[ -d "$ROOT" ]] || { echo "error: missing backup root: $ROOT" >&2; exit 2; }
command -v git >/dev/null || { echo "error: git is required" >&2; exit 2; }

failed=0
checked=0
skipped=0
work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git init --bare -q "$work/empty.git"

for repo_dir in "$ROOT"/*/*; do
  [[ -d "$repo_dir" ]] || continue
  [[ -f "$repo_dir/manifest.json" ]] || continue
  echo "== ${repo_dir#"$ROOT"/}"
  if [[ -s "$repo_dir/SHA256SUMS" ]]; then
    if ! (cd "$repo_dir" && sha256sum -c SHA256SUMS >/dev/null); then
      echo "  FAIL checksums"
      failed=$((failed + 1))
    fi
  fi
  while IFS= read -r -d '' bundle; do
    checked=$((checked + 1))
    if [[ "$bundle" == *.gpg ]]; then
      if [[ -r "$PASSFILE" ]] && command -v gpg >/dev/null 2>&1; then
        plain="$work/verify.bundle"
        if gpg --batch --yes --decrypt --passphrase-file "$PASSFILE" \
            --output "$plain" "$bundle" >/dev/null 2>&1 &&
           git -C "$work/empty.git" bundle verify "$plain" >/dev/null 2>&1; then
          echo "  OK $(basename "$bundle")"
        else
          echo "  FAIL $(basename "$bundle")"
          failed=$((failed + 1))
        fi
        rm -f "$plain"
      else
        echo "  SKIP encrypted $(basename "$bundle")"
        skipped=$((skipped + 1))
      fi
    else
      if git -C "$work/empty.git" bundle verify "$bundle" >/dev/null 2>&1; then
        echo "  OK $(basename "$bundle")"
      else
        echo "  FAIL $(basename "$bundle")"
        failed=$((failed + 1))
      fi
    fi
  done < <(find "$repo_dir/snapshots" "$repo_dir/tags" -type f \
    \( -name '*.bundle' -o -name '*.bundle.gpg' \) -print0 2>/dev/null)
done

echo "checked=$checked skipped=$skipped failed=$failed"
(( failed == 0 ))
