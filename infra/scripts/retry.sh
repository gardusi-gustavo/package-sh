#!/usr/bin/env bash
# Run a command with bounded retries and backoff.
set -euo pipefail

attempts=3
delay=2
max_delay=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    --attempts) attempts="$2"; shift 2 ;;
    --delay) delay="$2"; shift 2 ;;
    --max-delay) max_delay="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help)
      echo "usage: retry.sh [--attempts N] [--delay SEC] [--max-delay SEC] -- COMMAND..."
      exit 0 ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || { echo "error: command required" >&2; exit 2; }

sleep_for="$delay"
for ((attempt=1; attempt<=attempts; attempt++)); do
  echo "retry: attempt $attempt/$attempts: $*" >&2
  if "$@"; then
    exit 0
  fi
  status=$?
  if (( attempt == attempts )); then
    echo "retry: failed after $attempts attempts" >&2
    exit "$status"
  fi
  echo "retry: waiting ${sleep_for}s" >&2
  sleep "$sleep_for"
  sleep_for=$(( sleep_for * 2 ))
  (( sleep_for > max_delay )) && sleep_for="$max_delay"
done
