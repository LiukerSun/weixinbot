#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_DIR="${SCRIPT_DIR}/.manager"
DEFAULTS_FILE="${MANAGER_DIR}/defaults.env"

INSTANCE_NAME="${1:-}"

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "${@}"
}

choose_instance() {
  local instances_dir="$1"
  local items=()
  local item=""

  while IFS= read -r item; do
    items+=("$item")
  done < <(find "$instances_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  [[ "${#items[@]}" -gt 0 ]] || fail "当前没有实例，请先运行 ./install-openclaw.sh"

  printf '可选实例:\n'
  printf '  %s\n' "${items[@]}"
  read -r -p "请输入实例名: " INSTANCE_NAME
  [[ -n "$INSTANCE_NAME" ]] || fail "实例名不能为空"
}

run_openclaw_image() {
  local entrypoint="$1"
  shift

  docker run --rm -i \
    -e HOME=/home/node \
    -e TERM=xterm-256color \
    -e TZ="${OPENCLAW_TZ:-Asia/Shanghai}" \
    -e OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}" \
    -e OPENCLAW_PRIMARY_MODEL_PROVIDER="${OPENCLAW_PRIMARY_MODEL_PROVIDER:-}" \
    -e ZAI_API_KEY="${ZAI_API_KEY:-}" \
    -e ZAI_MODEL="${ZAI_MODEL:-}" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    -e OPENAI_BASE_URL="${OPENAI_BASE_URL:-}" \
    -e OPENAI_MODEL="${OPENAI_MODEL:-}" \
    -e BRAVE_API_KEY="${BRAVE_API_KEY:-}" \
    -v "${STATE_DIR}:/home/node/.openclaw" \
    -v "${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace" \
    --entrypoint "$entrypoint" \
    "$OPENCLAW_IMAGE" \
    "$@"
}

run_node_in_state() {
  local target="$1"

  docker run --rm -i \
    -e HOME=/home/node \
    -e "BRAVE_API_KEY=${BRAVE_API_KEY:-}" \
    -v "${STATE_DIR}:/state" \
    --entrypoint node \
    "$OPENCLAW_IMAGE" \
    - "$target"
}

wait_for_gateway() {
  local retries=90
  local i=0

  for ((i = 1; i <= retries; i += 1)); do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz" >/dev/null 2>&1; then
        return 0
      fi
    elif node -e "fetch('http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

ensure_state_permissions() {
  mkdir -p "$STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" "$EXTENSIONS_DIR"
  chown -R 1000:1000 "$STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" >/dev/null 2>&1 || true
  find "$STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" -type d -exec chmod 755 {} + >/dev/null 2>&1 || true
  find "$STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" -type f -exec chmod 644 {} + >/dev/null 2>&1 || true
}

configure_gateway_json() {
  local config_file="/state/openclaw.json"

  run_node_in_state "$config_file" <<'EOF'
const fs = require("fs");

const configPath = process.argv[2];
const braveApiKey = process.env.BRAVE_API_KEY || "";
const primaryProvider = String(process.env.OPENCLAW_PRIMARY_MODEL_PROVIDER || "").trim().toLowerCase();
const zaiModel = String(process.env.ZAI_MODEL || "").trim();
const openaiModel = String(process.env.OPENAI_MODEL || "").trim();
let config = {};

let primaryModelRef = "";
if (primaryProvider === "zai" && zaiModel) {
  primaryModelRef = `zai/${zaiModel}`;
} else if (primaryProvider === "openai" && openaiModel) {
  primaryModelRef = `openai/${openaiModel}`;
}

if (fs.existsSync(configPath)) {
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch {
    config = {};
  }
}

config.gateway ??= {};
config.gateway.mode = "local";
config.gateway.controlUi ??= {};
config.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;

config.agents ??= {};
config.agents.defaults ??= {};
config.agents.defaults.model = typeof config.agents.defaults.model === "string"
  ? { primary: config.agents.defaults.model }
  : (config.agents.defaults.model && typeof config.agents.defaults.model === "object" && !Array.isArray(config.agents.defaults.model))
    ? config.agents.defaults.model
    : {};
if (primaryModelRef) {
  config.agents.defaults.model.primary = primaryModelRef;
}

config.tools ??= {};
config.tools.web ??= {};
config.tools.web.search ??= {};
if (braveApiKey) {
  config.tools.web.search.apiKey = braveApiKey;
}

config.plugins ??= {};
config.plugins.allow = (config.plugins.allow || []).filter((entry) => entry !== "openclaw-weixin");

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
EOF
}

reset_weixin_artifacts() {
  rm -rf "${PLUGIN_DIR}"
  find "$EXTENSIONS_DIR" -maxdepth 1 -mindepth 1 -type d -name '.openclaw-install-stage-*' -exec rm -rf {} + >/dev/null 2>&1 || true
}

reset_weixin_config() {
  local config_file="/state/openclaw.json"

  run_node_in_state "$config_file" <<'EOF'
const fs = require("fs");

const configPath = process.argv[2];
let config = {};

if (fs.existsSync(configPath)) {
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch {
    config = {};
  }
}

if (config.channels && typeof config.channels === "object") {
  delete config.channels["openclaw-weixin"];
}

config.plugins ??= {};
if (config.plugins.allow) {
  config.plugins.allow = config.plugins.allow.filter((entry) => entry !== "openclaw-weixin");
}
if (config.plugins.entries && typeof config.plugins.entries === "object") {
  delete config.plugins.entries["openclaw-weixin"];
}
if (config.plugins.installs && typeof config.plugins.installs === "object") {
  delete config.plugins.installs["openclaw-weixin"];
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
EOF
}

ensure_gateway_running() {
  compose up -d openclaw-gateway >/dev/null
  wait_for_gateway || fail "Gateway 启动超时: ${INSTANCE_NAME}"
}

restart_gateway() {
  compose restart openclaw-gateway >/dev/null
  wait_for_gateway || fail "Gateway 重启超时: ${INSTANCE_NAME}"
}

compare_versions() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch
  local right_major right_minor right_patch

  IFS='.' read -r left_major left_minor left_patch <<<"$left"
  IFS='.' read -r right_major right_minor right_patch <<<"$right"

  left_major="${left_major:-0}"
  left_minor="${left_minor:-0}"
  left_patch="${left_patch:-0}"
  right_major="${right_major:-0}"
  right_minor="${right_minor:-0}"
  right_patch="${right_patch:-0}"

  if (( left_major != right_major )); then
    (( left_major > right_major )) && return 1
    return 2
  fi
  if (( left_minor != right_minor )); then
    (( left_minor > right_minor )) && return 1
    return 2
  fi
  if (( left_patch != right_patch )); then
    (( left_patch > right_patch )) && return 1
    return 2
  fi
  return 0
}

detect_openclaw_version() {
  local version_output
  version_output="$(run_openclaw_image sh -lc 'openclaw --version' 2>/dev/null || true)"
  version_output="$(printf '%s' "$version_output" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
  [[ -n "$version_output" ]] || fail "无法检测 OpenClaw 版本"
  printf '%s' "$version_output"
}

resolve_weixin_dist_tag() {
  local openclaw_version="$1"

  compare_versions "$openclaw_version" "2026.3.22"
  case $? in
    0|1)
      printf 'latest'
      ;;
    2)
      printf 'compat-host-gte2026.3.0-lt2026.3.22'
      ;;
    *)
      fail "无法判断微信插件兼容轨道: ${openclaw_version}"
      ;;
  esac
}

install_weixin_from_npm_archive() {
  local openclaw_version dist_tag plugin_spec plugin_spec_escaped

  openclaw_version="$(detect_openclaw_version)"
  dist_tag="$(resolve_weixin_dist_tag "$openclaw_version")"
  plugin_spec="${WEIXIN_PLUGIN_PACKAGE}@${dist_tag}"
  printf -v plugin_spec_escaped '%q' "$plugin_spec"

  warn "官方安装器遇到 ClawHub 限流，回退到 npm 归档安装: ${plugin_spec}"
  run_openclaw_image sh -lc "
    set -eu
    tmpdir=\$(mktemp -d)
    trap 'rm -rf \"\$tmpdir\"' EXIT
    cd \"\$tmpdir\"
    npm pack ${plugin_spec_escaped} >/dev/null
    archive=\$(ls -1 *.tgz | head -n 1)
    [ -n \"\$archive\" ]
    openclaw plugins install \"\$tmpdir/\$archive\"
    openclaw channels login --channel openclaw-weixin
  "
}

install_weixin_official() {
  local output_file

  info "使用官方安装器安装并连接微信"
  output_file="$(mktemp)"
  if run_openclaw_image sh -lc 'npx -y @tencent-weixin/openclaw-weixin-cli@latest install' 2>&1 | tee "$output_file"; then
    rm -f "$output_file"
    return 0
  fi

  if grep -Eq 'Rate limit exceeded|failed \(429\)|ClawHub .+ failed \(429\)' "$output_file"; then
    rm -f "$output_file"
    install_weixin_from_npm_archive
    return 0
  fi

  rm -f "$output_file"
  fail "官方安装器执行失败，请检查上面的输出"
}

main() {
  [[ -f "$DEFAULTS_FILE" ]] || fail "默认配置不存在，请先运行 ./install-openclaw.sh"
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"

  [[ -n "${INSTANCES_DIR:-}" ]] || fail "默认配置缺少 INSTANCES_DIR"
  if [[ -z "$INSTANCE_NAME" ]]; then
    choose_instance "$INSTANCES_DIR"
  fi

  INSTANCE_DIR="${INSTANCES_DIR}/${INSTANCE_NAME}"
  ENV_FILE="${INSTANCE_DIR}/.env"
  COMPOSE_FILE="${INSTANCE_DIR}/compose.yml"
  STATE_DIR="${INSTANCE_DIR}/state"
  EXTENSIONS_DIR="${STATE_DIR}/extensions"
  PLUGIN_DIR="${EXTENSIONS_DIR}/openclaw-weixin"

  [[ -f "$ENV_FILE" ]] || fail "实例不存在或缺少 .env: ${INSTANCE_NAME}"
  [[ -f "$COMPOSE_FILE" ]] || fail "实例缺少 compose.yml: ${INSTANCE_NAME}"

  # shellcheck disable=SC1090
  source "$ENV_FILE"

  [[ -n "${OPENCLAW_IMAGE:-}" ]] || fail "实例环境缺少 OPENCLAW_IMAGE"
  [[ -n "${OPENCLAW_WORKSPACE_DIR:-}" ]] || fail "实例环境缺少 OPENCLAW_WORKSPACE_DIR"

  ensure_state_permissions
  configure_gateway_json
  reset_weixin_config
  reset_weixin_artifacts
  ensure_gateway_running
  install_weixin_official
  ensure_state_permissions
  restart_gateway

  info "实例 ${INSTANCE_NAME} 的微信插件已按官方流程安装完成"
  info "如果上面的官方安装器已经显示“与微信连接成功”，现在可以直接测试发消息。"
}

main "$@"
