#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${OPENCLAW_REPO_OWNER:-LiukerSun}"
REPO_NAME="${OPENCLAW_REPO_NAME:-weixinbot}"
REPO_REF="${OPENCLAW_REPO_REF:-master}"
INSTALL_DIR="${OPENCLAW_INSTALL_DIR:-/usr/local/bin}"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"
CREATE_SCRIPT_NAME="create-openclaw-instance.sh"
WEIXIN_LOGIN_SCRIPT_NAME="weixin-login.sh"
STATS_SCRIPT_NAME="openclaw-stats.sh"
SET_MODEL_SCRIPT_NAME="set-openclaw-model.sh"
MONITOR_SCRIPT_NAME="openclaw-monitor.sh"
QUOTA_CONTROL_SCRIPT_NAME="openclaw-quota-control.sh"

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

install_script() {
  local name="$1"
  local source_url="${RAW_BASE_URL}/${name}"
  local temp_file
  temp_file="$(mktemp)"

  download_file "$source_url" "$temp_file"
  install -d "$INSTALL_DIR"
  install -m 0755 "$temp_file" "${INSTALL_DIR}/${name}"
  rm -f "$temp_file"
}

main() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Please run this installer as root so it can write to ${INSTALL_DIR}"
  fi

  install_script "$CREATE_SCRIPT_NAME"
  install_script "$WEIXIN_LOGIN_SCRIPT_NAME"
  install_script "$STATS_SCRIPT_NAME"
  install_script "$SET_MODEL_SCRIPT_NAME"
  install_script "$MONITOR_SCRIPT_NAME"
  install_script "$QUOTA_CONTROL_SCRIPT_NAME"

  echo "Installed scripts:"
  echo "  ${INSTALL_DIR}/${CREATE_SCRIPT_NAME}"
  echo "  ${INSTALL_DIR}/${WEIXIN_LOGIN_SCRIPT_NAME}"
  echo "  ${INSTALL_DIR}/${STATS_SCRIPT_NAME}"
  echo "  ${INSTALL_DIR}/${SET_MODEL_SCRIPT_NAME}"
  echo "  ${INSTALL_DIR}/${MONITOR_SCRIPT_NAME}"
  echo "  ${INSTALL_DIR}/${QUOTA_CONTROL_SCRIPT_NAME}"
  echo ""
  exec "${INSTALL_DIR}/${CREATE_SCRIPT_NAME}" "$@"
}

main "$@"
