#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_DIR="${SCRIPT_DIR}/.manager"
DEFAULTS_FILE="${MANAGER_DIR}/defaults.env"

DEFAULT_OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:2026.3.28"
DEFAULT_INSTANCES_DIR="${SCRIPT_DIR}/instances"
DEFAULT_PRIMARY_MODEL_PROVIDER="zai"
DEFAULT_ZAI_MODEL="glm-5-turbo"
DEFAULT_OPENAI_MODEL="gpt-5.4"
DEFAULT_PORT_BASE="39088"
DEFAULT_TIMEZONE="Asia/Shanghai"
DEFAULT_WEIXIN_PLUGIN_PACKAGE="@tencent-weixin/openclaw-weixin"

EDIT_DEFAULTS=0
ONE_SHOT_NAME=""

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

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  has_cmd "$1" || fail "Missing required command: $1"
}

compose() {
  docker compose --env-file "$1" -f "$2" "${@:3}"
}

usage() {
  cat <<'EOF'
Usage:
  ./install-openclaw.sh
  ./install-openclaw.sh --edit-defaults
  ./install-openclaw.sh --name <instance-name>

Behavior:
  1. 交互配置并保存默认参数
  2. 连续输入实例名称，快速创建多个 OpenClaw 实例
  3. 每个实例独立目录、独立端口、独立容器
EOF
}

prompt() {
  local label="$1"
  local default_value="${2-}"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " value
    printf '%s' "${value:-$default_value}"
    return
  fi

  read -r -p "${label}: " value
  printf '%s' "$value"
}

prompt_required() {
  local label="$1"
  local default_value="${2-}"
  local value=""

  while true; do
    value="$(prompt "$label" "$default_value")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
    warn "${label} 不能为空"
  done
}

prompt_yes_no() {
  local label="$1"
  local default_answer="${2:-Y}"
  local answer=""

  read -r -p "${label} [${default_answer}/$([[ "$default_answer" == "Y" ]] && printf 'n' || printf 'y')]: " answer
  answer="${answer:-$default_answer}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

write_env_kv() {
  local key="$1"
  local value="$2"
  printf '%s=%q\n' "$key" "$value"
}

load_defaults() {
  if [[ -f "$DEFAULTS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DEFAULTS_FILE"
  fi
}

save_defaults() {
  mkdir -p "$MANAGER_DIR"
  {
    write_env_kv "OPENCLAW_IMAGE" "$OPENCLAW_IMAGE"
    write_env_kv "INSTANCES_DIR" "$INSTANCES_DIR"
    write_env_kv "OPENCLAW_PRIMARY_MODEL_PROVIDER" "$OPENCLAW_PRIMARY_MODEL_PROVIDER"
    write_env_kv "ZAI_API_KEY" "${ZAI_API_KEY:-}"
    write_env_kv "ZAI_MODEL" "${ZAI_MODEL:-}"
    write_env_kv "OPENAI_API_KEY" "${OPENAI_API_KEY:-}"
    write_env_kv "OPENAI_BASE_URL" "${OPENAI_BASE_URL:-}"
    write_env_kv "OPENAI_MODEL" "${OPENAI_MODEL:-}"
    write_env_kv "BRAVE_API_KEY" "${BRAVE_API_KEY:-}"
    write_env_kv "PORT_BASE" "$PORT_BASE"
    write_env_kv "OPENCLAW_TZ" "$OPENCLAW_TZ"
    write_env_kv "WEIXIN_PLUGIN_PACKAGE" "$WEIXIN_PLUGIN_PACKAGE"
  } >"$DEFAULTS_FILE"
}

configure_defaults() {
  load_defaults

  OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-$DEFAULT_OPENCLAW_IMAGE}"
  INSTANCES_DIR="${INSTANCES_DIR:-$DEFAULT_INSTANCES_DIR}"
  OPENCLAW_PRIMARY_MODEL_PROVIDER="${OPENCLAW_PRIMARY_MODEL_PROVIDER:-$DEFAULT_PRIMARY_MODEL_PROVIDER}"
  ZAI_API_KEY="${ZAI_API_KEY:-}"
  ZAI_MODEL="${ZAI_MODEL:-$DEFAULT_ZAI_MODEL}"
  OPENAI_API_KEY="${OPENAI_API_KEY:-}"
  OPENAI_BASE_URL="${OPENAI_BASE_URL:-}"
  OPENAI_MODEL="${OPENAI_MODEL:-$DEFAULT_OPENAI_MODEL}"
  BRAVE_API_KEY="${BRAVE_API_KEY:-}"
  PORT_BASE="${PORT_BASE:-$DEFAULT_PORT_BASE}"
  OPENCLAW_TZ="${OPENCLAW_TZ:-$DEFAULT_TIMEZONE}"
  WEIXIN_PLUGIN_PACKAGE="${WEIXIN_PLUGIN_PACKAGE:-$DEFAULT_WEIXIN_PLUGIN_PACKAGE}"

  if [[ -f "$DEFAULTS_FILE" && "$EDIT_DEFAULTS" != "1" ]]; then
    if prompt_yes_no "检测到已保存默认参数，直接使用" "Y"; then
      return
    fi
  fi

  info "配置默认参数。保存后，后面只需要不断输入实例名。"
  OPENCLAW_IMAGE="$(prompt_required "OpenClaw Docker Image" "$OPENCLAW_IMAGE")"
  INSTANCES_DIR="$(prompt_required "实例根目录" "$INSTANCES_DIR")"
  OPENCLAW_PRIMARY_MODEL_PROVIDER="$(prompt_required "主模型提供方 (zai/openai)" "$OPENCLAW_PRIMARY_MODEL_PROVIDER")"
  ZAI_API_KEY="$(prompt "ZAI API Key" "$ZAI_API_KEY")"
  ZAI_MODEL="$(prompt_required "ZAI 模型" "$ZAI_MODEL")"
  OPENAI_API_KEY="$(prompt "OpenAI API Key" "$OPENAI_API_KEY")"
  OPENAI_BASE_URL="$(prompt "OpenAI Base URL" "$OPENAI_BASE_URL")"
  OPENAI_MODEL="$(prompt_required "OpenAI 模型" "$OPENAI_MODEL")"
  BRAVE_API_KEY="$(prompt "Brave Search API Key" "$BRAVE_API_KEY")"
  PORT_BASE="$(prompt_required "自动分配端口起点" "$PORT_BASE")"
  OPENCLAW_TZ="$(prompt_required "时区" "$OPENCLAW_TZ")"
  WEIXIN_PLUGIN_PACKAGE="$(prompt_required "微信插件包名" "$WEIXIN_PLUGIN_PACKAGE")"

  save_defaults
  info "默认参数已保存到 ${DEFAULTS_FILE}"
}

port_in_use() {
  local port="$1"

  if has_cmd ss; then
    ss -Hltn "sport = :${port}" | grep -q .
    return $?
  fi

  docker ps --format '{{.Ports}}' | grep -q ":${port}->"
}

find_free_port_pair() {
  local start_port="$1"
  local candidate="$start_port"

  if (( candidate % 2 != 0 )); then
    candidate=$((candidate + 1))
  fi

  while true; do
    if ! port_in_use "$candidate" && ! port_in_use "$((candidate + 1))"; then
      printf '%s %s' "$candidate" "$((candidate + 1))"
      return
    fi
    candidate=$((candidate + 2))
  done
}

write_compose_file() {
  local compose_file="$1"
  cat >"$compose_file" <<'EOF'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE}
    restart: unless-stopped
    init: true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${OPENCLAW_TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENCLAW_PRIMARY_MODEL_PROVIDER: ${OPENCLAW_PRIMARY_MODEL_PROVIDER}
      ZAI_API_KEY: ${ZAI_API_KEY}
      ZAI_MODEL: ${ZAI_MODEL}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL}
      OPENAI_MODEL: ${OPENAI_MODEL}
      BRAVE_API_KEY: ${BRAVE_API_KEY}
    volumes:
      - ${OPENCLAW_STATE_DIR}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    ports:
      - 127.0.0.1:${OPENCLAW_GATEWAY_PORT}:18789
      - 127.0.0.1:${OPENCLAW_BRIDGE_PORT}:18790
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--bind",
        "lan",
        "--port",
        "18789"
      ]
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  openclaw-cli:
    profiles: ["cli"]
    image: ${OPENCLAW_IMAGE}
    network_mode: service:openclaw-gateway
    init: true
    stdin_open: true
    tty: true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${OPENCLAW_TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENCLAW_PRIMARY_MODEL_PROVIDER: ${OPENCLAW_PRIMARY_MODEL_PROVIDER}
      ZAI_API_KEY: ${ZAI_API_KEY}
      ZAI_MODEL: ${ZAI_MODEL}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL}
      OPENAI_MODEL: ${OPENAI_MODEL}
      BRAVE_API_KEY: ${BRAVE_API_KEY}
    volumes:
      - ${OPENCLAW_STATE_DIR}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    entrypoint: ["node", "dist/index.js"]
    depends_on:
      - openclaw-gateway
EOF
}

write_instance_env() {
  local env_file="$1"
  local instance_name="$2"
  local gateway_port="$3"
  local bridge_port="$4"
  local state_dir="$5"
  local workspace_dir="$6"
  local token="$7"

  {
    write_env_kv "COMPOSE_PROJECT_NAME" "$instance_name"
    write_env_kv "INSTANCE_NAME" "$instance_name"
    write_env_kv "OPENCLAW_IMAGE" "$OPENCLAW_IMAGE"
    write_env_kv "OPENCLAW_TZ" "$OPENCLAW_TZ"
    write_env_kv "OPENCLAW_GATEWAY_TOKEN" "$token"
    write_env_kv "OPENCLAW_GATEWAY_PORT" "$gateway_port"
    write_env_kv "OPENCLAW_BRIDGE_PORT" "$bridge_port"
    write_env_kv "OPENCLAW_STATE_DIR" "$state_dir"
    write_env_kv "OPENCLAW_WORKSPACE_DIR" "$workspace_dir"
    write_env_kv "OPENCLAW_PRIMARY_MODEL_PROVIDER" "$OPENCLAW_PRIMARY_MODEL_PROVIDER"
    write_env_kv "ZAI_API_KEY" "${ZAI_API_KEY:-}"
    write_env_kv "ZAI_MODEL" "${ZAI_MODEL:-}"
    write_env_kv "OPENAI_API_KEY" "${OPENAI_API_KEY:-}"
    write_env_kv "OPENAI_BASE_URL" "${OPENAI_BASE_URL:-}"
    write_env_kv "OPENAI_MODEL" "${OPENAI_MODEL:-}"
    write_env_kv "BRAVE_API_KEY" "${BRAVE_API_KEY:-}"
    write_env_kv "WEIXIN_PLUGIN_PACKAGE" "$WEIXIN_PLUGIN_PACKAGE"
  } >"$env_file"
}

write_openclaw_json() {
  local config_file="$1"
  local brave_key="${BRAVE_API_KEY:-}"
  local escaped_brave_key="${brave_key//\\/\\\\}"
  escaped_brave_key="${escaped_brave_key//\"/\\\"}"

  cat >"$config_file" <<EOF
{
  "plugins": {
    "allow": []
  },
  "tools": {
    "web": {
      "search": {
        "apiKey": "${escaped_brave_key}"
      }
    }
  }
}
EOF
}

wait_for_gateway() {
  local env_file="$1"
  local compose_file="$2"
  local retries=60
  local i=0

  for ((i = 1; i <= retries; i += 1)); do
    if compose "$env_file" "$compose_file" exec -T openclaw-gateway node -e \
      "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

create_instance() {
  local instance_name="$1"

  [[ "$instance_name" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "实例名只能包含字母、数字、点、下划线和中划线: ${instance_name}"

  local instance_dir="${INSTANCES_DIR}/${instance_name}"
  local state_dir="${instance_dir}/state"
  local workspace_dir="${instance_dir}/workspace"
  local compose_file="${instance_dir}/compose.yml"
  local env_file="${instance_dir}/.env"
  local config_file="${state_dir}/openclaw.json"

  if [[ -e "$instance_dir" ]]; then
    fail "实例目录已存在: ${instance_dir}"
  fi

  read -r gateway_port bridge_port < <(find_free_port_pair "$PORT_BASE")
  local token
  token="$(openssl rand -hex 32)"

  mkdir -p "$state_dir" "$workspace_dir"
  chmod 777 "$state_dir" "$workspace_dir"

  write_compose_file "$compose_file"
  write_instance_env "$env_file" "$instance_name" "$gateway_port" "$bridge_port" "$state_dir" "$workspace_dir" "$token"
  write_openclaw_json "$config_file"

  compose "$env_file" "$compose_file" up -d openclaw-gateway >/dev/null
  if ! wait_for_gateway "$env_file" "$compose_file"; then
    warn "实例已创建，但 Gateway 健康检查超时: ${instance_name}"
  fi

  printf '\n'
  info "实例创建完成: ${instance_name}"
  printf '  目录: %s\n' "$instance_dir"
  printf '  Gateway: http://127.0.0.1:%s\n' "$gateway_port"
  printf '  Bridge: 127.0.0.1:%s\n' "$bridge_port"
  printf '  微信对接: ./weixin-connect.sh %s\n' "$instance_name"
  printf '\n'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --edit-defaults)
        EDIT_DEFAULTS=1
        shift
        ;;
      --name)
        [[ $# -ge 2 ]] || fail "--name 需要实例名"
        ONE_SHOT_NAME="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  require_cmd docker
  require_cmd openssl

  configure_defaults
  mkdir -p "$INSTANCES_DIR"

  if [[ -n "$ONE_SHOT_NAME" ]]; then
    create_instance "$ONE_SHOT_NAME"
    exit 0
  fi

  info "开始连续创建实例。直接回车可结束。"
  while true; do
    local name
    name="$(prompt "请输入实例名，直接回车结束")"
    if [[ -z "$name" ]]; then
      info "已结束。"
      break
    fi
    create_instance "$name"
  done
}

main "$@"
