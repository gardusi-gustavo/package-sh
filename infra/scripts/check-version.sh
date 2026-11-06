#!/usr/bin/env bash
# Validate VERSION and the language manifests that must agree with it.
set -euo pipefail

ROOT="."
VERSION_OVERRIDE=""
RELEASE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "error: --root needs a value" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    --version)
      [[ $# -ge 2 ]] || { echo "error: --version needs a value" >&2; exit 2; }
      VERSION_OVERRIDE="$2"; shift 2 ;;
    --release) RELEASE=1; shift ;;
    -h|--help)
      echo "usage: check-version.sh [--root PATH] [--version X.Y.Z] [--release]"
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$ROOT" ]] || { echo "error: root not found: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT"

[[ -s VERSION ]] || { echo "ERROR: missing VERSION" >&2; exit 1; }
version="$(tr -d '[:space:]' < VERSION)"
[[ -n "$version" ]] || { echo "ERROR: VERSION is empty" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: VERSION must be bare semver X.Y.Z: $version" >&2
  exit 1
}

if [[ -n "$VERSION_OVERRIDE" ]]; then
  override="${VERSION_OVERRIDE#v}"
  [[ "$override" == "$version" ]] || {
    echo "ERROR: VERSION $version != requested $override" >&2
    exit 1
  }
fi

errors=0
check() {
  local label="$1" actual="$2"
  [[ "$actual" == "$version" ]] || {
    echo "ERROR: $label version $actual != $version" >&2
    errors=$((errors + 1))
  }
}

if [[ -s package.json ]]; then
  check package.json "$(jq -r '.version // empty' package.json)"
fi

if [[ -s pyproject.toml ]]; then
  actual="$(awk '
    /^\[project\]/ { in_project = 1; next }
    /^\[/ { in_project = 0 }
    in_project && /^[[:space:]]*version[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"[[:space:]]*$/, "")
      print
      exit
    }
  ' pyproject.toml)"
  if [[ -z "$actual" ]]; then
    echo "ERROR: pyproject.toml has no static version under [project]" >&2
    errors=$((errors + 1))
  else
    check pyproject.toml "$actual"
  fi
fi

if [[ -s Cargo.toml ]]; then
  actual="$(awk '
    /^\[package\]/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && /^[[:space:]]*version[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"[[:space:]]*$/, "")
      print
      exit
    }
  ' Cargo.toml)"
  if [[ -z "$actual" ]]; then
    echo "ERROR: Cargo.toml has no static version under [package]" >&2
    errors=$((errors + 1))
  else
    check Cargo.toml "$actual"
  fi
fi

if (( RELEASE )); then
  tag="v$version"
  if ! git rev-parse --verify "$tag" >/dev/null 2>&1; then
    echo "ERROR: missing tag $tag" >&2
    errors=$((errors + 1))
  else
    [[ "$(git rev-list -n 1 "$tag")" == "$(git rev-parse HEAD)" ]] || {
      echo "ERROR: tag $tag does not point at HEAD" >&2
      errors=$((errors + 1))
    }
  fi
fi

(( errors == 0 )) || exit 1
echo "version ok: $version"
