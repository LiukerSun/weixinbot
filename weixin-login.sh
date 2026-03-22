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

configure_weixin_plugin() {
  node - "${INSTANCE_DIR}/state/openclaw.json" <<'EOF'
const fs = require("fs");
const path = process.argv[2];
const data = JSON.parse(fs.readFileSync(path, "utf8"));
data.plugins = data.plugins || {};
data.plugins.allow = Array.from(new Set([...(data.plugins.allow || []), "openclaw-weixin"]));
data.plugins.entries = data.plugins.entries || {};
data.plugins.entries["openclaw-weixin"] = { enabled: true };
data.auth = data.auth || {};
data.auth.profiles = data.auth.profiles || {};
data.auth.profiles["zai:default"] = { provider: "zai", mode: "api_key" };
data.agents = data.agents || {};
data.agents.defaults = data.agents.defaults || {};
data.agents.defaults.model = { ...(data.agents.defaults.model || {}), primary: "zai/glm-5-turbo" };
data.tools = data.tools || {};
data.tools.web = data.tools.web || {};
data.tools.web.search = { ...(data.tools.web.search || {}), enabled: true, provider: "brave" };
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
EOF
}

sync_weixin_patches() {
  bash "${CREATE_SCRIPT}" --write-weixin-patches "${INSTANCE_DIR}/state"
}

ensure_instance() {
  if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
    return
  fi

  echo "实例 ${INSTANCE_NAME} 不存在，将先创建。"
  local suggested_gateway_port suggested_bridge_port gateway_port bridge_port zai_api_key brave_api_key
  suggested_gateway_port="$(suggest_gateway_port)"
  suggested_bridge_port=$((suggested_gateway_port + DEFAULT_BRIDGE_OFFSET))
  gateway_port="$(prompt "Gateway 端口" "$suggested_gateway_port")"
  bridge_port="$(prompt "Bridge 端口" "$suggested_bridge_port")"
  zai_api_key="$(prompt "ZAI_API_KEY（可留空使用当前环境变量）" "${ZAI_API_KEY:-}")"
  brave_api_key="$(prompt "BRAVE_API_KEY（可留空使用当前环境变量）" "${BRAVE_API_KEY:-}")"

  local args=("$INSTANCE_NAME" "$gateway_port" "$bridge_port" --with-weixin --skip-weixin-login)
  if [[ -n "$zai_api_key" ]]; then
    args+=(--zai-api-key "$zai_api_key")
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
    sync_weixin_patches
    configure_weixin_plugin
    compose restart openclaw-gateway >/dev/null
    wait_for_gateway
    return
  fi

  echo "正在安装微信插件..."
  compose run -T --rm openclaw-cli plugins install "@tencent-weixin/openclaw-weixin"
  sync_weixin_patches
  configure_weixin_plugin
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
