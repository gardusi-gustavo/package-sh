#!/usr/bin/env bash
# Mirror active and retired Git bundle trees to an external device.
set -euo pipefail

ROOT="${BUNDLE_BACKUP_ROOT:-/srv/backup/git-bundles}"
RETIRED_ROOT="${BUNDLE_RETIRED_ROOT:-/srv/backup/git-bundles-retired}"
DEVICE_PATH=""
DEVICE_LABEL=""
DEVICE_CONFIG="${BUNDLE_DEVICE_CONFIG:-/home/user/repos/human/private/infra/config/offline-devices.json}"
APPLY=0
FORCE=0

usage() {
  cat <<'EOF'
usage: bundle-mirror.sh [options]

  --device LABEL        device label from offline-devices.json (microsd, backup1)
  --path DIR            explicit mount path
  --config FILE         device config (default: private vault offline-devices.json)
  --root DIR            active bundle root (default: /srv/backup/git-bundles)
  --retired-root DIR    retired bundle root (default: /srv/backup/git-bundles-retired)
  --apply               copy and verify (default: dry run)
  --force               allow a non-mountpoint target (for testing)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_LABEL="${2:-}"; shift 2 ;;
    --path) DEVICE_PATH="${2:-}"; shift 2 ;;
    --config) DEVICE_CONFIG="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --retired-root) RETIRED_ROOT="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$DEVICE_PATH" || -n "$DEVICE_LABEL" ]] || { echo "error: --device or --path is required" >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo "error: missing active root: $ROOT" >&2; exit 2; }
[[ -d "$RETIRED_ROOT" ]] || { echo "error: missing retired root: $RETIRED_ROOT" >&2; exit 2; }
[[ -r "$ROOT/index.json" ]] || { echo "error: missing $ROOT/index.json" >&2; exit 2; }
[[ -r "$RETIRED_ROOT/retired-index.json" ]] || { echo "error: missing $RETIRED_ROOT/retired-index.json" >&2; exit 2; }

if [[ -z "$DEVICE_PATH" ]]; then
  [[ -r "$DEVICE_CONFIG" ]] || { echo "error: missing device config: $DEVICE_CONFIG" >&2; exit 2; }
  DEVICE_PATH="$(jq -r --arg label "$DEVICE_LABEL" '.[$label].mount // empty' "$DEVICE_CONFIG")"
  [[ -n "$DEVICE_PATH" ]] || { echo "error: unknown device label: $DEVICE_LABEL" >&2; exit 2; }
fi

if (( ! FORCE )) && ! mountpoint -q "$DEVICE_PATH"; then
  echo "error: not a mountpoint: $DEVICE_PATH (use --force only for testing)" >&2
  exit 2
fi
if (( FORCE )); then
  mkdir -p "$DEVICE_PATH"
fi

ACTIVE_DEST="$DEVICE_PATH/0-library/backup/git-bundles"
RETIRED_DEST="$DEVICE_PATH/0-library/backup/git-bundles-retired"
ACTIVE_BYTES="$(jq '[.repositories[].total_bytes] | add // 0' "$ROOT/index.json")"
RETIRED_BYTES="$(jq '.total // ([.repositories[].total_bytes] | add) // 0' "$RETIRED_ROOT/retired-index.json")"
ACTIVE_REPOS="$(jq '.repositories | length' "$ROOT/index.json")"
RETIRED_REPOS="$(jq '.repositories | length' "$RETIRED_ROOT/retired-index.json")"
NEEDED=$(( ACTIVE_BYTES + RETIRED_BYTES ))
AVAIL="$(df --output=avail -B1 "$DEVICE_PATH" | tail -1 | tr -d ' ')"
if (( AVAIL < NEEDED + 1073741824 )); then
  echo "error: insufficient space on $DEVICE_PATH: need $NEEDED bytes, avail $AVAIL" >&2
  exit 1
fi

echo "device: $DEVICE_PATH"
echo "active: $ACTIVE_REPOS repos, $ACTIVE_BYTES bytes"
echo "retired: $RETIRED_REPOS repos, $RETIRED_BYTES bytes"
echo "available: $AVAIL bytes"

if (( ! APPLY )); then
  echo "dry run: no files copied"
  exit 0
fi

mkdir -p "$ACTIVE_DEST/gardusi-gustavo" "$RETIRED_DEST/gardusi-gustavo"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$ROOT/gardusi-gustavo/" "$ACTIVE_DEST/gardusi-gustavo/"
  rsync -a --delete "$RETIRED_ROOT/gardusi-gustavo/" "$RETIRED_DEST/gardusi-gustavo/"
else
  cp -a "$ROOT/gardusi-gustavo/." "$ACTIVE_DEST/gardusi-gustavo/"
  cp -a "$RETIRED_ROOT/gardusi-gustavo/." "$RETIRED_DEST/gardusi-gustavo/"
fi
cp "$ROOT/index.json" "$ACTIVE_DEST/index.json"
cp "$RETIRED_ROOT/retired-index.json" "$RETIRED_DEST/retired-index.json"

if find "$ACTIVE_DEST/gardusi-gustavo/private" -type f -name '*.bundle' 2>/dev/null | grep -q .; then
  echo "error: plaintext private bundle found on target" >&2
  exit 1
fi

fail=0
while IFS= read -r -d '' sums; do
  if ! (cd "$(dirname "$sums")" && sha256sum -c SHA256SUMS >/dev/null); then
    echo "FAIL checksum: $sums" >&2
    fail=$((fail + 1))
  fi
done < <(find "$ACTIVE_DEST" "$RETIRED_DEST" -type f -name SHA256SUMS -print0)

LABEL="${DEVICE_LABEL:-$(basename "$DEVICE_PATH")}"
python3 - "$ACTIVE_DEST/mirror.json" "$LABEL" "$DEVICE_PATH" "$ACTIVE_REPOS" "$RETIRED_REPOS" "$ACTIVE_BYTES" "$RETIRED_BYTES" "$fail" <<'PY'
import json, sys
from datetime import datetime, timezone
path, label, mount, active, retired, abytes, rbytes, fail = sys.argv[1:]
data = {
    "synced_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "device_label": label,
    "device_mount": mount,
    "active_repo_count": int(active),
    "retired_repo_count": int(retired),
    "active_bytes": int(abytes),
    "retired_bytes": int(rbytes),
    "checksum_verification": "FAILED" if int(fail) else "PASSED",
}
open(path, "w").write(json.dumps(data, indent=2) + "\n")
PY
cp "$ACTIVE_DEST/mirror.json" "$RETIRED_DEST/mirror.json"

(( fail == 0 )) || { echo "checksum failures: $fail" >&2; exit 1; }
echo "mirror synced and verified: $DEVICE_PATH"
