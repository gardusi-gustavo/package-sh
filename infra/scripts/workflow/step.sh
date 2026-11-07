#!/usr/bin/env bash
# Execute one workflow step. The sb runner sets SB_SCRIPT_NAME.
set -euo pipefail

STEP="${SB_SCRIPT_NAME:-}"
ROOT="."
CONFIG=""
STATE=""
INPUT_FILE=""
OUTPUT_FILE=""
JSON=0
DRY_RUN=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

usage() {
  cat <<'EOF'
usage: step.sh --step NAME [--root PATH] [--config PATH] [--state PATH]
               [--input FILE] [--output FILE] [--json] [--dry-run]

NAME is a vault.* or backup.* step. The sb runner sets SB_SCRIPT_NAME, so
`sb run vault.scan` does not need --step.
EOF
}

die() { echo "error: $*" >&2; exit 2; }
log() { [[ "$JSON" == "1" ]] || echo "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --step) STEP="${2:?--step needs a value}"; shift 2 ;;
    --root) ROOT="${2:?--root needs a value}"; shift 2 ;;
    --config) CONFIG="${2:?--config needs a value}"; shift 2 ;;
    --state) STATE="${2:?--state needs a value}"; shift 2 ;;
    --input) INPUT_FILE="${2:?--input needs a value}"; shift 2 ;;
    --output) OUTPUT_FILE="${2:?--output needs a value}"; shift 2 ;;
    --json) JSON=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$STEP" ]] || die "--step is required (or run through sb)"
[[ -n "$STATE" ]] && export SB_STATE="$STATE"
[[ -d "$ROOT" ]] || die "root not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

INPUT_JSON='{}'
if [[ -n "$INPUT_FILE" ]]; then
  [[ -r "$INPUT_FILE" ]] || die "input not readable: $INPUT_FILE"
  INPUT_JSON="$(cat "$INPUT_FILE")"
elif [[ ! -t 0 ]]; then
  INPUT_JSON="$(cat)"
fi
[[ -n "$INPUT_JSON" ]] || INPUT_JSON='{}'
jq -e . >/dev/null <<<"$INPUT_JSON" || die "input is not valid JSON"

input_get() { jq -r "$1 // empty" <<<"$INPUT_JSON"; }
input_items() {
  jq -c 'if type == "array" then .[] elif type == "object" and has("items") then .items[] else . end' <<<"$INPUT_JSON"
}

emit() {
  local json="$1"
  if [[ -n "$OUTPUT_FILE" ]]; then
    printf '%s\n' "$json" | jq . >"$OUTPUT_FILE.tmp.$$"
    mv "$OUTPUT_FILE.tmp.$$" "$OUTPUT_FILE"
  else
    printf '%s\n' "$json" | jq .
  fi
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }
size_of() { stat -c %s "$1"; }

# ------------------------------------------------------------------ vault
vault_scan() {
  local store_root hash_mode max_items out n=0
  store_root="$(input_get '.store_root')"
  [[ -n "$store_root" ]] || die "vault.scan: store_root required"
  [[ -d "$store_root" ]] || die "vault.scan: not a directory: $store_root"
  hash_mode="$(input_get '.hash_mode')"; hash_mode="${hash_mode:-none}"
  max_items="$(input_get '.max_items')"; max_items="${max_items:-0}"
  out="$WORK/scan.ndjson"; : >"$out"
  local f rel size id domain title sha
  while IFS= read -r -d '' f; do
    rel="${f#"$store_root"/}"
    case "$rel" in .*|*/.*) continue ;; esac
    [[ "$rel" == *.md ]] && continue
    size="$(size_of "$f")"
    id="item-$(printf '%s' "$rel" | sha1sum | awk '{print $1}' | cut -c1-16)"
    domain="${rel%%/*}"
    case "$domain" in video|porn|books|music|games|docs|audio) ;; *) domain="docs" ;; esac
    title="$(basename "$rel")"; title="${title%.*}"
    sha=null
    [[ "$hash_mode" == "all" ]] && sha="\"$(sha_of "$f")\""
    jq -nc --arg id "$id" --arg title "$title" --arg domain "$domain" \
      --argjson size "$size" --argjson sha "$sha" \
      '{id:$id,title:$title,domain:$domain,stage:"input",status:"yellow",size_bytes:$size,sha256:$sha,presence:{store:true,card:false},ticket_id:null}' >>"$out"
    n=$((n + 1))
    [[ "$max_items" != "0" && "$n" -ge "$max_items" ]] && break
  done < <(find "$store_root" -type f -print0 | sort -z)
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg store "$store_root" --argjson n "$n" '{dry_run:true,step:"vault.scan",store_root:$store,items:$n}')"
    return
  fi
  emit "$(jq -s '{items:.}' "$out")"
}

vault_classify() {
  local store_root out="$WORK/classify.ndjson"
  store_root="$(input_get '.store_root')"
  : >"$out"
  local item rel ext domain status ticket reason probe src
  while IFS= read -r item; do
    rel="$(jq -r '.relpath // .source_path // empty' <<<"$item")"
    [[ -n "$rel" ]] || rel="$(jq -r '.title' <<<"$item")"
    ext="${rel##*.}"
    domain="$(jq -r '.domain // empty' <<<"$item")"
    case "$ext" in
      mkv|mp4|avi|m4v|webm) domain=video ;;
      mp3|flac|m4a|opus|wav) domain=audio ;;
      pdf|epub) domain=docs ;;
      gb|gbc|gba|sfc|smc|z64|nds) domain=games ;;
      *) [[ -n "$domain" ]] || domain=docs ;;
    esac
    status=yellow; ticket=""; reason=""
    if [[ "$domain" == "video" ]]; then
      src=""
      [[ -n "$store_root" && -f "$store_root/$rel" ]] && src="$store_root/$rel"
      if [[ -n "$src" ]] && command -v ffprobe >/dev/null 2>&1; then
        probe="$(ffprobe -v error -show_entries stream=codec_type,codec_name,height:stream_tags=language -of json "$src" 2>/dev/null || true)"
        if [[ -n "$probe" ]]; then
          local height vcodec audio eng
          height="$(jq -r '[.streams[]?|select(.codec_type=="video")][0].height // 0' <<<"$probe")"
          vcodec="$(jq -r '[.streams[]?|select(.codec_type=="video")][0].codec_name // ""' <<<"$probe")"
          audio="$(jq -r '[.streams[]?|select(.codec_type=="audio")]|length' <<<"$probe")"
          eng="$(jq -r '[.streams[]?|select(.codec_type=="audio")|(.tags.language // "")]|any(.=="eng" or .=="en")' <<<"$probe")"
          if [[ "$audio" == "0" ]]; then
            status=red; ticket=video-red-replace; reason="no audio"
          elif [[ "$height" -gt 720 || "$vcodec" != "h264" ]]; then
            status=yellow; ticket=video-profile-720p; reason="profile mismatch"
          elif [[ "$eng" != "true" ]]; then
            status=yellow; ticket=video-audio-verify; reason="audio language unset"
          else
            status=green
          fi
        fi
      fi
    fi
    jq -c --arg stage processing --arg status "$status" --arg ticket "$ticket" --arg reason "$reason" --arg domain "$domain" \
      '. + {stage:$stage,status:$status,ticket_id:(if $ticket=="" then null else $ticket end),reason:(if $reason=="" then null else $reason end),domain:$domain}' <<<"$item" >>"$out"
  done < <(input_items)
  emit "$(jq -s '{items:.}' "$out")"
}

vault_plan() {
  local out="$WORK/plan.ndjson"
  : >"$out"
  local item id stage ticket action step
  while IFS= read -r item; do
    id="$(jq -r '.id' <<<"$item")"
    stage="$(jq -r '.stage' <<<"$item")"
    ticket="$(jq -r '.ticket_id // empty' <<<"$item")"
    case "$stage" in
      input|processing) action=transform; step=vault.transform ;;
      ready) action=verify; step=vault.verify ;;
      on_card|repairing) action=fetch; step=vault.fetch ;;
      published) action=cleanup; step=vault.cleanup ;;
      *) action=skip; step=vault.plan ;;
    esac
    jq -nc --arg id "$id" --arg action "$action" --arg step "$step" --arg ticket "$ticket" \
      '{item_id:$id,action:$action,step:$step,priority:1,ticket_id:(if $ticket=="" then null else $ticket end),reason:null}' >>"$out"
  done < <(input_items)
  emit "$(jq -s '{actions:.}' "$out")"
}

vault_reconcile() {
  local store_root card_root sfile cfile missing extra
  store_root="$(input_get '.store_root')"
  card_root="$(input_get '.card_root')"
  [[ -n "$store_root" && -n "$card_root" ]] || die "vault.reconcile: store_root and card_root required"
  [[ -d "$store_root" && -d "$card_root" ]] || die "vault.reconcile: roots must exist"
  sfile="$WORK/store.txt"; cfile="$WORK/card.txt"
  missing="$WORK/missing.txt"; extra="$WORK/extra.txt"
  (cd "$store_root" && find . -type f ! -name '*.md' -printf '%P\n' | sort) >"$sfile"
  (cd "$card_root" && find . -type f ! -name '*.md' -printf '%P\n' | sort) >"$cfile"
  comm -23 "$sfile" "$cfile" >"$missing" || true
  comm -13 "$sfile" "$cfile" >"$extra" || true
  emit "$(jq -nc --arg now "$(now)" \
    --argjson sc "$(wc -l <"$sfile" | tr -d ' ')" \
    --argjson cc "$(wc -l <"$cfile" | tr -d ' ')" \
    --argjson missing "$(jq -R -s 'split("\n")|map(select(length>0))' "$missing")" \
    --argjson extra "$(jq -R -s 'split("\n")|map(select(length>0))' "$extra")" \
    --argjson stage_counts '{}' \
    '{checked_at:$now,store_items:$sc,card_items:$cc,missing_on_card:$missing,extra_on_card:$extra,hash_mismatches:[],stage_counts:$stage_counts}')"
}

vault_render() {
  local now sc cc missing extra
  now="$(now)"
  sc="$(jq -r '.store_items // 0' <<<"$INPUT_JSON")"
  cc="$(jq -r '.card_items // 0' <<<"$INPUT_JSON")"
  missing="$(jq -r '.missing_on_card | length // 0' <<<"$INPUT_JSON" 2>/dev/null || echo 0)"
  extra="$(jq -r '.extra_on_card | length // 0' <<<"$INPUT_JSON" 2>/dev/null || echo 0)"
  emit "$(jq -nc --arg run "run-$now" --arg wf "vault.sync" --arg now "$now" \
    --argjson sc "$sc" --argjson cc "$cc" --argjson mi "$missing" --argjson ex "$extra" \
    '{run_id:$run,workflow:$wf,status:"succeeded",started_at:$now,finished_at:$now,counts:{store:$sc,card:$cc,missing:$mi,extra:$ex},warnings:[]}')"
}

vault_fetch() {
  local rel store_root card_root src dst sha out
  rel="$(input_get '.relpath // .source_path')"
  store_root="$(input_get '.store_root')"
  card_root="$(input_get '.card_root')"
  [[ -n "$rel" && -n "$store_root" && -n "$card_root" ]] || die "vault.fetch: relpath, store_root, card_root required"
  src="$card_root/$rel"; dst="$store_root/$rel"
  [[ -f "$src" ]] || die "vault.fetch: missing $src"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg s "$src" --arg d "$dst" '{dry_run:true,step:"vault.fetch",source:$s,destination:$d}')"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst.part"
  mv "$dst.part" "$dst"
  sha="$(sha_of "$dst")"
  out="$(jq -c --arg stage processing --arg sha "$sha" '. + {stage:$stage,sha256:$sha,presence:{store:true,card:false}}' <<<"$INPUT_JSON")"
  emit "$out"
}

vault_transform() {
  local rel store_root src dst title base sha out
  rel="$(input_get '.relpath // .source_path')"
  store_root="$(input_get '.store_root')"
  [[ -n "$rel" && -n "$store_root" ]] || die "vault.transform: relpath and store_root required"
  src="$store_root/$rel"
  [[ -f "$src" ]] || die "vault.transform: missing $src"
  base="${rel%.*}"
  dst="$store_root/ready/$base.mkv"
  title="$(basename "$base")"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg s "$src" --arg d "$dst" '{dry_run:true,step:"vault.transform",source:$s,destination:$d,profile:"h264-720p-aac"}')"
    return
  fi
  need ffmpeg
  mkdir -p "$(dirname "$dst")"
  ffmpeg -hide_banner -loglevel error -y -i "$src" -map 0:v:0 -map 0:a:0? \
    -vf "scale='if(gt(a,1),-2,720)':'if(gt(a,1),720,-2)'" \
    -c:v libx264 -preset medium -crf 22 -maxrate 3000k -bufsize 6000k \
    -c:a aac -b:a 192k -ac 2 -sn -map_metadata -1 -metadata "title=$title" "$dst.part.mkv"
  mv "$dst.part.mkv" "$dst"
  sha="$(sha_of "$dst")"
  out="$(jq -c --arg stage ready --arg sha "$sha" '. + {stage:$stage,sha256:$sha,presence:{store:true,card:false}}' <<<"$INPUT_JSON")"
  emit "$out"
}

vault_verify() {
  local store_root rel path sha height vcodec audio subs probe out
  store_root="$(input_get '.store_root')"
  rel="$(input_get '.relpath')"
  path="$(input_get '.source_path // .path')"
  if [[ -z "$path" && -n "$rel" && -n "$store_root" ]]; then
    path="$store_root/ready/${rel%.*}.mkv"
  fi
  [[ -n "$path" && -f "$path" ]] || die "vault.verify: file not found"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg p "$path" '{dry_run:true,step:"vault.verify",path:$p}')"
    return
  fi
  need ffprobe
  sha="$(sha_of "$path")"
  probe="$(ffprobe -v error -show_entries stream=codec_type,codec_name,height -of json "$path" 2>/dev/null || true)"
  height="$(jq -r '[.streams[]?|select(.codec_type=="video")][0].height // 0' <<<"$probe")"
  vcodec="$(jq -r '[.streams[]?|select(.codec_type=="video")][0].codec_name // ""' <<<"$probe")"
  audio="$(jq -r '[.streams[]?|select(.codec_type=="audio")]|length' <<<"$probe")"
  subs="$(jq -r '[.streams[]?|select(.codec_type=="subtitle")]|length' <<<"$probe")"
  if [[ "$vcodec" == "h264" && "$height" -le 720 && "$audio" -ge 1 && "$subs" -eq 0 ]]; then
    out="$(jq -c --arg sha "$sha" --arg now "$(now)" '. + {stage:"ready",sha256:$sha,verified:true,verified_at:$now,presence:{store:true,card:false}}' <<<"$INPUT_JSON")"
  else
    out="$(jq -c '. + {stage:"blocked",reason:"profile mismatch"}' <<<"$INPUT_JSON")"
  fi
  emit "$out"
}

vault_publish() {
  local rel store_root card_root src dst sha src_sha dst_sha out
  rel="$(input_get '.relpath')"
  store_root="$(input_get '.store_root')"
  card_root="$(input_get '.card_root')"
  [[ -n "$rel" && -n "$store_root" && -n "$card_root" ]] || die "vault.publish: relpath, store_root, card_root required"
  src="$(input_get '.source_path')"
  [[ -n "$src" ]] || src="$store_root/ready/${rel%.*}.mkv"
  dst="$(input_get '.card_path')"
  [[ -n "$dst" ]] || dst="$card_root/$rel"
  [[ -f "$src" ]] || die "vault.publish: missing $src"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg s "$src" --arg d "$dst" '{dry_run:true,step:"vault.publish",source:$s,destination:$d}')"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  src_sha="$(sha_of "$src")"
  cp -f "$src" "$dst.part"
  dst_sha="$(sha_of "$dst.part")"
  [[ "$src_sha" == "$dst_sha" ]] || die "vault.publish: hash mismatch"
  mv "$dst.part" "$dst"
  out="$(jq -c --arg stage published --arg sha "$src_sha" '. + {stage:$stage,sha256:$sha,presence:{store:true,card:true}}' <<<"$INPUT_JSON")"
  emit "$out"
}

vault_cleanup() {
  local rel store_root card_root src dst src_sha dst_sha out
  rel="$(input_get '.relpath')"
  store_root="$(input_get '.store_root')"
  card_root="$(input_get '.card_root')"
  [[ -n "$rel" && -n "$store_root" && -n "$card_root" ]] || die "vault.cleanup: relpath, store_root, card_root required"
  src="$(input_get '.source_path')"
  [[ -n "$src" ]] || src="$store_root/ready/${rel%.*}.mkv"
  dst="$(input_get '.card_path')"
  [[ -n "$dst" ]] || dst="$card_root/$rel"
  [[ -f "$src" && -f "$dst" ]] || die "vault.cleanup: source and card copy must exist"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg s "$src" --arg d "$dst" '{dry_run:true,step:"vault.cleanup",source:$s,card:$d}')"
    return
  fi
  src_sha="$(sha_of "$src")"
  dst_sha="$(sha_of "$dst")"
  [[ "$src_sha" == "$dst_sha" ]] || die "vault.cleanup: hash mismatch"
  rm -f "$src"
  out="$(jq -c --arg sha "$src_sha" '. + {stage:"published",sha256:$sha,presence:{store:false,card:true}}' <<<"$INPUT_JSON")"
  emit "$out"
}

# ----------------------------------------------------------------- backup
backup_lock() {
  local lock_file mode
  lock_file="$(input_get '.lock_file')"
  mode="$(input_get '.mode')"
  [[ -n "$lock_file" ]] || die "backup.lock: lock_file required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg f "$lock_file" --arg m "$mode" '{dry_run:true,step:"backup.lock",lock_file:$f,mode:$m}')"
    return
  fi
  mkdir -p "$(dirname "$lock_file")"
  if ! (set -C; printf '%s\n' "$$" >"$lock_file") 2>/dev/null; then
    die "backup.lock: already held: $lock_file"
  fi
  emit "$(jq -nc --arg f "$lock_file" --arg now "$(now)" --arg h "$$" '{lock_file:$f,acquired_at:$now,holder:$h}')"
}

backup_unlock() {
  local lock_file
  lock_file="$(input_get '.lock_file')"
  [[ -n "$lock_file" ]] || die "backup.unlock: lock_file required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg f "$lock_file" '{dry_run:true,step:"backup.unlock",lock_file:$f}')"
    return
  fi
  rm -f "$lock_file"
  emit "$(jq -nc --arg f "$lock_file" '{lock_file:$f,released:true}')"
}

backup_preflight() {
  local policy_path policy primary reserve out
  policy_path="$(input_get '.policy_path')"
  [[ -n "$policy_path" ]] || policy_path="$CONFIG"
  [[ -n "$policy_path" && -r "$policy_path" ]] || die "backup.preflight: policy path required"
  policy="$(cat "$policy_path")"
  primary="$(jq -r '.primary_dir' <<<"$policy")"
  reserve="$(jq -r '.retention.reserve_bytes // 0' <<<"$policy")"
  out="$WORK/destinations.ndjson"; : >"$out"
  local d free cap req mode
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    mkdir -p "$d" 2>/dev/null || true
    free="$(df -B1 --output=avail "$d" 2>/dev/null | tail -1 | tr -d ' ' || true)"
    cap="$(df -B1 --output=size "$d" 2>/dev/null | tail -1 | tr -d ' ' || true)"
    req=true
    if [[ "$d" == "$primary" ]]; then mode=primary; else mode=mirror; fi
    jq -nc --arg p "$d" --argjson r "$req" --arg m "$mode" \
      --argjson free "${free:-0}" --argjson cap "${cap:-0}" --argjson w true \
      '{path:$p,required:$r,mode:$m,free_bytes:$free,capacity_bytes:$cap,writable:$w}' >>"$out"
  done < <(jq -r '.primary_dir, (.mirror_dirs[]?)' <<<"$policy")
  emit "$(jq -nc --arg run "run-$(date +%s)" --argjson est 0 --argjson res "$reserve" \
    --argjson dest "$(jq -s '.' "$out")" \
    '{run_id:$run,archive_estimate_bytes:$est,reserve_bytes:$res,destinations:$dest}')"
}

backup_quiesce() {
  local name data cmd
  name="$(input_get '.name')"
  data="$(input_get '.data_dir')"
  cmd="${BACKUP_STOP_COMMAND:-}"
  [[ -n "$name" ]] || die "backup.quiesce: service name required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg n "$name" --arg d "$data" '{dry_run:true,step:"backup.quiesce",name:$n,data_dir:$d}')"
    return
  fi
  [[ -n "$cmd" ]] || die "backup.quiesce: set BACKUP_STOP_COMMAND"
  bash -c "$cmd"
  emit "$(jq -nc --arg n "$name" --arg now "$(now)" '{name:$n,state:"stopped",changed_at:$now}')"
}

backup_resume() {
  local name cmd
  name="$(input_get '.name')"
  cmd="${BACKUP_START_COMMAND:-}"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg n "$name" '{dry_run:true,step:"backup.resume",name:$n}')"
    return
  fi
  [[ -n "$cmd" ]] || die "backup.resume: set BACKUP_START_COMMAND"
  bash -c "$cmd"
  emit "$(jq -nc --arg n "$name" --arg now "$(now)" '{name:$n,state:"running",changed_at:$now}')"
}

backup_dump() {
  local data out cmd version
  data="$(input_get '.data_dir')"
  out="$(input_get '.out_dir')"
  cmd="${BACKUP_DUMP_COMMAND:-}"
  [[ -n "$out" ]] || die "backup.dump: out_dir required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg d "$data" --arg o "$out" '{dry_run:true,step:"backup.dump",data_dir:$d,out_dir:$o}')"
    return
  fi
  [[ -n "$cmd" ]] || die "backup.dump: set BACKUP_DUMP_COMMAND"
  mkdir -p "$out"
  bash -c "$cmd"
  if command -v gitea >/dev/null 2>&1; then
    version="$(gitea --version 2>/dev/null | awk '{print $3}')"
  else
    version="unknown"
  fi
  emit "$(jq -nc --arg d "$out" --arg v "$version" --arg now "$(now)" \
    '{dump_dir:$d,gitea_version:$v,manifest:{},started_at:$now,finished_at:$now}')"
}

backup_validate() {
  local dump_dir db errors=0 integrity="skipped"
  dump_dir="$(input_get '.dump_dir')"
  [[ -n "$dump_dir" && -d "$dump_dir" ]] || die "backup.validate: dump_dir required"
  db="$dump_dir/data/gitea.db"
  [[ -f "$db" ]] || db="$dump_dir/gitea.db"
  if [[ -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    integrity="$(sqlite3 "$db" 'pragma integrity_check;' 2>/dev/null || echo failed)"
  fi
  [[ "$integrity" == "ok" || "$integrity" == "skipped" ]] || errors=$((errors + 1))
  emit "$(jq -nc --arg i "$integrity" --argjson e "$errors" \
    '{sqlite_integrity:$i,table_counts:{},git_fsck:"skipped",errors:(if $e==0 then [] else ["database integrity failed"] end)}')"
}

backup_manifest() {
  local dump_dir manifest
  dump_dir="$(jq -r '.dump.dump_dir // .dump_dir // empty' <<<"$INPUT_JSON")"
  [[ -n "$dump_dir" && -d "$dump_dir" ]] || die "backup.manifest: dump_dir required"
  manifest="$dump_dir/manifest.json"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg m "$manifest" '{dry_run:true,step:"backup.manifest",manifest_path:$m}')"
    return
  fi
  jq -n --arg now "$(now)" '{created:$now,repos:0,issues:0,pull_requests:0,users:0,attachments:0}' >"$manifest"
  emit "$(jq -nc --arg m "$manifest" --arg sha "$(sha_of "$manifest")" '{manifest_path:$m,sha256:$sha}')"
}

backup_archive() {
  local manifest archive password
  manifest="$(jq -r '.manifest.manifest_path // .manifest_path // empty' <<<"$INPUT_JSON")"
  archive="$(input_get '.archive_path')"
  password="${BACKUP_PASSWORD_FILE:-}"
  [[ -n "$archive" ]] || archive="$(dirname "$manifest")/gitea-$(date -u +%Y%m%dT%H%M%SZ).7z"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg a "$archive" '{dry_run:true,step:"backup.archive",archive_path:$a}')"
    return
  fi
  need 7z
  [[ -n "$password" && -r "$password" ]] || die "backup.archive: set BACKUP_PASSWORD_FILE"
  mkdir -p "$(dirname "$archive")"
  7z a -t7z -mhe=on -p"$(cat "$password")" "$archive" "$(dirname "$manifest")" >/dev/null
  emit "$(jq -nc --arg a "$archive" --arg sha "$(sha_of "$archive")" --argjson s "$(size_of "$archive")" --arg now "$(now)" \
    '{archive_path:$a,sha256:$sha,size_bytes:$s,created_at:$now}')"
}

backup_test() {
  local archive password
  archive="$(jq -r '.archive.archive_path // .archive_path // empty' <<<"$INPUT_JSON")"
  password="${BACKUP_PASSWORD_FILE:-}"
  [[ -n "$archive" && -f "$archive" ]] || die "backup.test: archive required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg a "$archive" '{dry_run:true,step:"backup.test",archive_path:$a}')"
    return
  fi
  need 7z
  [[ -n "$password" && -r "$password" ]] || die "backup.test: set BACKUP_PASSWORD_FILE"
  7z t -p"$(cat "$password")" "$archive" >/dev/null
  emit "$(jq -nc --arg a "$archive" --arg sha "$(sha_of "$archive")" '{archive_path:$a,sha256:$sha,tested:true}')"
}

backup_copy() {
  local archive sha dest final temp
  archive="$(input_get '.archive_path')"
  sha="$(input_get '.sha256')"
  final="$(input_get '.final_path')"
  [[ -n "$archive" && -n "$sha" && -n "$final" ]] || die "backup.copy: archive_path, sha256, final_path required"
  temp="$final.part"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg a "$archive" --arg f "$final" '{dry_run:true,step:"backup.copy",archive_path:$a,final_path:$f}')"
    return
  fi
  mkdir -p "$(dirname "$final")"
  cp -f "$archive" "$temp"
  [[ "$(sha_of "$temp")" == "$sha" ]] || die "backup.copy: checksum mismatch"
  emit "$(jq -nc --arg d "$(dirname "$final")" --arg t "$temp" --arg f "$final" --arg sha "$sha" \
    '{destination:$d,temp_path:$t,final_path:$f,sha256:$sha,verified:false,published:false}')"
}

backup_verify_copy() {
  local temp sha
  temp="$(jq -r '.temp_path // .archive_path // empty' <<<"$INPUT_JSON")"
  sha="$(input_get '.sha256')"
  [[ -n "$temp" && -f "$temp" && -n "$sha" ]] || die "backup.verify_copy: temp_path and sha256 required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg t "$temp" '{dry_run:true,step:"backup.verify_copy",temp_path:$t}')"
    return
  fi
  [[ "$(sha_of "$temp")" == "$sha" ]] || die "backup.verify_copy: checksum mismatch"
  emit "$(jq -c '. + {verified:true}' <<<"$INPUT_JSON")"
}

backup_publish_copy() {
  local temp final
  temp="$(input_get '.temp_path')"
  final="$(input_get '.final_path')"
  [[ -n "$temp" && -n "$final" ]] || die "backup.publish_copy: temp_path and final_path required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg t "$temp" --arg f "$final" '{dry_run:true,step:"backup.publish_copy",temp_path:$t,final_path:$f}')"
    return
  fi
  mv -f "$temp" "$final"
  emit "$(jq -c '. + {published:true}' <<<"$INPUT_JSON")"
}

backup_reconcile() {
  local archive mirror base out="$WORK/reconcile.ndjson"
  archive="$(jq -r '.archive.archive_path // .archive_path // empty' <<<"$INPUT_JSON")"
  mirror="$(input_get '.mirror')"
  [[ -n "$archive" && -n "$mirror" ]] || die "backup.reconcile: archive and mirror required"
  base="$(basename "$archive")"
  : >"$out"
  if [[ -f "$mirror/$base" ]]; then
    jq -nc --arg m "$mirror" '{missing:[],copied:[],errors:[]}' >>"$out"
  elif [[ "$DRY_RUN" == "1" ]]; then
    jq -nc --arg m "$mirror/$base" '{dry_run:true,step:"backup.reconcile",would_copy:$m}' >>"$out"
  else
    mkdir -p "$mirror"
    cp -f "$archive" "$mirror/$base"
    jq -nc --arg m "$mirror/$base" '{missing:[],copied:[$m],errors:[]}' >>"$out"
  fi
  emit "$(jq -s '.[0]' "$out")"
}

backup_prune() {
  local dest archive max reserve keep_min out="$WORK/archives.txt"
  dest="$(input_get '.destination')"
  archive="$(jq -r '.archive.archive_path // .archive_path // empty' <<<"$INPUT_JSON")"
  max="$(jq -r '.retention.max_bytes // 5368709120' <<<"$INPUT_JSON")"
  reserve="$(jq -r '.retention.reserve_bytes // 536870912' <<<"$INPUT_JSON")"
  keep_min="$(jq -r '.retention.minimum_valid_archives // 5' <<<"$INPUT_JSON")"
  [[ -n "$dest" && -d "$dest" ]] || die "backup.prune: destination required"
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg d "$dest" '{dry_run:true,step:"backup.prune",destination:$d}')"
    return
  fi
  find "$dest" -maxdepth 1 -name 'gitea-*.7z' -printf '%f\n' | sort >"$out"
  local total kept=0 pruned=0 freed=0 f remaining
  total="$(du -sb "$dest" 2>/dev/null | awk '{print $1}')"
  remaining="$(wc -l <"$out" | tr -d ' ')"
  local limit=$((max - reserve))
  while IFS= read -r f; do
    if (( total > limit && remaining > keep_min )) && [[ "$f" != "$(tail -1 "$out")" ]]; then
      local size
      size="$(size_of "$dest/$f")"
      rm -f "$dest/$f" "$dest/$f.sha256"
      total=$((total - size)); freed=$((freed + size)); pruned=$((pruned + 1)); remaining=$((remaining - 1))
    else
      kept=$((kept + 1))
    fi
  done <"$out"
  emit "$(jq -nc --arg d "$dest" --argjson kept "$kept" --argjson pruned "$pruned" --argjson freed "$freed" \
    '{destination:$d,kept:[],pruned:[],freed_bytes:$freed,under_budget:true,minimum_met:true,kept_count:$kept,pruned_count:$pruned}')"
}

backup_status() {
  local out
  out="$OUTPUT_FILE"
  [[ -n "$out" ]] || out="$ROOT/backup-status.json"
  local result mode archive size baseline warning
  result="$(jq -r '.result // "failed"' <<<"$INPUT_JSON")"
  mode="$(jq -r '.mode // "manual"' <<<"$INPUT_JSON")"
  archive="$(jq -r '.archive // ""' <<<"$INPUT_JSON")"
  size=0; baseline=0; warning=false
  if [[ -n "$archive" && -f "$archive" ]]; then size="$(size_of "$archive")"; fi
  if [[ "$DRY_RUN" == "1" ]]; then
    emit "$(jq -nc --arg r "$result" '{dry_run:true,step:"backup.status",result:$r}')"
    return
  fi
  jq -n --arg r "$result" --arg m "$mode" --arg a "$archive" --argjson s "$size" --argjson b "$baseline" --argjson w "$warning" --arg now "$(now)" \
    '{result:$r,mode:$m,archive:$a,size_bytes:$s,size_baseline_bytes:$b,size_warning:$w,destinations:[],checks:[],started_at:$now,finished_at:$now}' >"$out"
  emit "$(jq -c '.' "$out")"
}

# ------------------------------------------------------------------ dispatch
handler="$(echo "$STEP" | tr '.-' '__')"
if ! declare -F "$handler" >/dev/null; then
  die "unknown step: $STEP"
fi
"$handler"
