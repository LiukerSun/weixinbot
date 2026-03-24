#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_SCRIPT="${SCRIPT_DIR}/create-openclaw-instance.sh"
DEFAULT_GATEWAY_BASE=18789
DEFAULT_BRIDGE_OFFSET=1
DEFAULT_PORT_STEP=100
INSTANCES_BASE_DIR="${OPENCLAW_INSTANCES_DIR:-/root/openclaw-instances}"

prompt() {
  local message="$1"
  local default_value="${2:-}"
  local value
  if [[ -n "$default_value" ]]; then
    read -r -p "${message} [${default_value}]: " value
    printf '%s' "${value:-$default_value}"
  else
    read -r -p "${message}: " value
    printf '%s' "$value"
  fi
}

mask_secret() {
  local value="${1:-}"
  local length="${#value}"

  if [[ -z "$value" ]]; then
    printf '\n'
  elif (( length <= 8 )); then
    printf '********\n'
  else
    printf '%s...%s\n' "${value:0:4}" "${value: -4}"
  fi
}

prompt_secret() {
  local message="$1"
  local default_value="${2:-}"
  local masked_default=""
  local value

  if [[ -n "$default_value" ]]; then
    masked_default="$(mask_secret "$default_value")"
    read -r -p "${message} [${masked_default}]: " value
    printf '%s' "${value:-$default_value}"
  else
    read -r -p "${message}: " value
    printf '%s' "$value"
  fi
}

normalize_primary_provider() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    zai)
      printf 'zai'
      ;;
    codex|openai)
      printf 'openai'
      ;;
    *)
      echo "模型提供方必须是 zai 或 openai（兼容 codex 别名）" >&2
      exit 1
      ;;
  esac
}

display_primary_provider() {
  printf '%s' "${1:-zai}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_port_in_use() {
  local port="$1"

  if has_cmd ss; then
    ss -H -ltn "( sport = :${port} )" 2>/dev/null | grep -q .
    return $?
  fi

  if has_cmd lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  node - "$port" <<'EOF'
const net = require("net");
const port = Number(process.argv[2]);
const server = net.createServer();

server.once("error", (error) => {
  if (error && (error.code === "EADDRINUSE" || error.code === "EACCES")) {
    process.exit(0);
  }
  process.exit(2);
});

server.once("listening", () => {
  server.close(() => process.exit(1));
});

server.listen({ host: "127.0.0.1", port, exclusive: true });
EOF
  case "$?" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

suggest_gateway_port() {
  local port="$DEFAULT_GATEWAY_BASE"
  while true; do
    if ! is_port_in_use "$port" && ! is_port_in_use "$((port + DEFAULT_BRIDGE_OFFSET))"; then
      printf '%s' "$port"
      return
    fi
    port=$((port + DEFAULT_PORT_STEP))
  done
}

compose() {
  if has_cmd docker-compose; then
    docker-compose -f "${INSTANCE_DIR}/docker-compose.yml" "$@"
    return
  fi

  docker compose -f "${INSTANCE_DIR}/docker-compose.yml" "$@"
}

wait_for_gateway() {
  local retries=60
  local delay=2
  local i
  for ((i=1; i<=retries; i++)); do
    if compose exec -T openclaw-gateway node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  echo "Gateway health check timed out"
  return 1
}

sync_instance_config() {
  bash "${CREATE_SCRIPT}" --sync-instance-config "${INSTANCE_DIR}"
}

ensure_instance() {
  if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
    return
  fi

  echo "实例 ${INSTANCE_NAME} 不存在，将先创建。"
  local suggested_gateway_port suggested_bridge_port gateway_port bridge_port zai_api_key zai_model brave_api_key openai_api_key openai_base_url openai_model primary_model_provider
  suggested_gateway_port="$(suggest_gateway_port)"
  suggested_bridge_port=$((suggested_gateway_port + DEFAULT_BRIDGE_OFFSET))
  gateway_port="$(prompt "Gateway 端口" "$suggested_gateway_port")"
  bridge_port="$(prompt "Bridge 端口" "$suggested_bridge_port")"
  primary_model_provider="$(normalize_primary_provider "$(prompt "主模型提供方（zai/openai）" "$(display_primary_provider "${OPENCLAW_PRIMARY_MODEL_PROVIDER:-zai}")")")"
  zai_api_key="$(prompt_secret "ZAI_API_KEY（可留空使用当前环境变量）" "${ZAI_API_KEY:-}")"
  zai_model="$(prompt "ZAI model" "${ZAI_MODEL:-glm-5-turbo}")"
  openai_api_key="$(prompt_secret "OpenAI API key（可留空使用当前环境变量）" "${OPENAI_API_KEY:-${CODEX_API_KEY:-}}")"
  openai_base_url="$(prompt "OpenAI base URL（可留空）" "${OPENAI_BASE_URL:-${CODEX_BASE_URL:-}}")"
  openai_model="$(prompt "OpenAI model" "${OPENAI_MODEL:-${CODEX_MODEL:-gpt-5.4}}")"
  brave_api_key="$(prompt_secret "BRAVE_API_KEY（可留空使用当前环境变量）" "${BRAVE_API_KEY:-}")"

  local args=("$INSTANCE_NAME" "$gateway_port" "$bridge_port" --with-weixin --skip-weixin-login)
  args+=(--primary-model-provider "$primary_model_provider")
  if [[ -n "$zai_api_key" ]]; then
    args+=(--zai-api-key "$zai_api_key")
  fi
  if [[ -n "$zai_model" ]]; then
    args+=(--zai-model "$zai_model")
  fi
  if [[ -n "$openai_api_key" ]]; then
    args+=(--openai-api-key "$openai_api_key")
  fi
  if [[ -n "$openai_base_url" ]]; then
    args+=(--openai-base-url "$openai_base_url")
  fi
  if [[ -n "$openai_model" ]]; then
    args+=(--openai-model "$openai_model")
  fi
  if [[ -n "$brave_api_key" ]]; then
    args+=(--brave-api-key "$brave_api_key")
  fi
  bash "${CREATE_SCRIPT}" "${args[@]}"
}

ensure_gateway_running() {
  compose up -d openclaw-gateway >/dev/null
  wait_for_gateway
}

restart_gateway() {
  compose restart openclaw-gateway >/dev/null
  wait_for_gateway
}

ensure_weixin_plugin() {
  if compose run -T --rm --no-deps --entrypoint sh openclaw-cli -lc '[ -d /home/node/.openclaw/extensions/openclaw-weixin ]'; then
    sync_instance_config
    compose restart openclaw-gateway >/dev/null
    wait_for_gateway
    return
  fi

  echo "正在安装微信插件..."
  if has_cmd timeout; then
    timeout 180s compose run -T --rm --no-deps openclaw-cli plugins install "@tencent-weixin/openclaw-weixin" || true
  else
    compose run -T --rm --no-deps openclaw-cli plugins install "@tencent-weixin/openclaw-weixin" || true
  fi
  if ! compose run -T --rm --no-deps --entrypoint sh openclaw-cli -lc '[ -d /home/node/.openclaw/extensions/openclaw-weixin ]'; then
    echo "微信插件安装失败：未发现扩展目录"
    exit 1
  fi
  sync_instance_config
  compose restart openclaw-gateway >/dev/null
  wait_for_gateway
}

main() {
  local input_name
  input_name="${1:-}"
  if [[ -z "$input_name" ]]; then
    input_name="$(prompt "请输入实例名")"
  fi

  if [[ -z "$input_name" ]]; then
    echo "实例名不能为空"
    exit 1
  fi

  bash "${CREATE_SCRIPT}" --ensure-host-deps

  INSTANCE_NAME="$input_name"
  INSTANCE_DIR="${INSTANCES_BASE_DIR}/${INSTANCE_NAME}"

  ensure_instance
  ensure_gateway_running
  ensure_weixin_plugin

  echo "即将显示微信登录二维码。"
  echo "实例目录: ${INSTANCE_DIR}"
  echo "按 Ctrl+C 可退出。"
  if compose exec openclaw-gateway node dist/index.js channels login --channel openclaw-weixin; then
    echo "登录成功，正在重启 OpenClaw Gateway 以加载最新微信会话..."
    restart_gateway
    echo "Gateway 已重启完成。现在可以测试微信收发。"
  fi
}

main "$@"
