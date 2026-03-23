#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${OPENCLAW_REPO_OWNER:-LiukerSun}"
REPO_NAME="${OPENCLAW_REPO_NAME:-weixinbot}"
REPO_REF="${OPENCLAW_REPO_REF:-master}"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"
STATS_SCRIPT_NAME="openclaw-stats.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download_file() {
  local url="$1"
  local target="$2"

  if has_cmd curl; then
    curl -fsSL "$url" -o "$target"
    return 0
  fi

  if has_cmd wget; then
    wget -qO "$target" "$url"
    return 0
  fi

  fail "Missing downloader: curl or wget"
}

main() {
  local temp_file
  temp_file="$(mktemp)"
  trap 'rm -f "$temp_file"' EXIT

  download_file "${RAW_BASE_URL}/${STATS_SCRIPT_NAME}" "$temp_file"
  chmod +x "$temp_file"
  exec "$temp_file" "$@"
}

main "$@"
