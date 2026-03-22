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
      echo "模型提供方必须是 zai 或 codex/openai" >&2
      exit 1
      ;;
  esac
}

display_primary_provider() {
  case "${1:-}" in
    openai) printf 'codex' ;;
    *) printf '%s' "${1:-zai}" ;;
  esac
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
  node - "${INSTANCE_DIR}/state/openclaw.json" "${INSTANCE_DIR}/.env" <<'EOF'
const fs = require("fs");
const path = process.argv[2];
const envPath = process.argv[3];
const data = JSON.parse(fs.readFileSync(path, "utf8"));
const env = {};

for (const rawLine of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
  const line = rawLine.trim();
  if (!line || line.startsWith("#")) {
    continue;
  }

  const separatorIndex = rawLine.indexOf("=");
  if (separatorIndex === -1) {
    continue;
  }

  const key = rawLine.slice(0, separatorIndex).trim();
  env[key] = rawLine.slice(separatorIndex + 1);
}

const primaryProvider = (env.OPENCLAW_PRIMARY_MODEL_PROVIDER || "zai").trim().toLowerCase();
const openaiApiKey = env.OPENAI_API_KEY || "";
const openaiBaseUrl = env.OPENAI_BASE_URL || "";
const openaiModel = env.OPENAI_MODEL || "gpt-5.4";
const enableOpenAI = Boolean(openaiApiKey || openaiBaseUrl || primaryProvider === "openai");

data.plugins = data.plugins || {};
data.plugins.allow = Array.from(new Set([...(data.plugins.allow || []), "openclaw-weixin"]));
data.plugins.entries = data.plugins.entries || {};
data.plugins.entries["openclaw-weixin"] = { enabled: true };

data.auth = data.auth || {};
data.auth.profiles = data.auth.profiles || {};
data.auth.profiles["zai:default"] = { provider: "zai", mode: "api_key" };
if (enableOpenAI) {
  data.auth.profiles["openai:default"] = { provider: "openai", mode: "api_key" };
} else {
  delete data.auth.profiles["openai:default"];
}

data.agents = data.agents || {};
data.agents.defaults = data.agents.defaults || {};
data.agents.defaults.model = {
  ...(data.agents.defaults.model || {}),
  primary: primaryProvider === "openai" ? `openai/${openaiModel}` : "zai/glm-5-turbo",
};
data.agents.defaults.compaction = {
  ...(data.agents.defaults.compaction || {}),
  mode: "safeguard",
};

data.commands = {
  ...(data.commands || {}),
  native: "auto",
  nativeSkills: "auto",
  restart: true,
  ownerDisplay: "raw",
};

data.gateway = data.gateway || {};
data.gateway.mode = "local";
data.gateway.bind = "lan";
data.gateway.controlUi = data.gateway.controlUi || {};
data.gateway.controlUi.allowedOrigins = [
  "http://localhost:18789",
  "http://127.0.0.1:18789",
];

data.tools = data.tools || {};
data.tools.web = data.tools.web || {};
data.tools.web.search = { ...(data.tools.web.search || {}), enabled: true, provider: "brave" };

if (enableOpenAI) {
  data.models = data.models || {};
  data.models.providers = data.models.providers || {};
  data.models.providers.openai = {
    ...(data.models.providers.openai || {}),
    apiKey: "$OPENAI_API_KEY",
    api: "openai-completions",
    models: [
      {
        id: openaiModel,
        name: openaiModel,
        reasoning: true,
        input: ["text"],
        cost: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
        },
        contextWindow: 200000,
        maxTokens: 8192,
      },
    ],
  };

  if (openaiBaseUrl) {
    data.models.providers.openai.baseUrl = openaiBaseUrl;
  } else if (data.models.providers.openai) {
    delete data.models.providers.openai.baseUrl;
  }
} else if (data.models && data.models.providers) {
  delete data.models.providers.openai;
  if (Object.keys(data.models.providers).length === 0) {
    delete data.models.providers;
  }
  if (Object.keys(data.models).length === 0) {
    delete data.models;
  }
}

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
  local suggested_gateway_port suggested_bridge_port gateway_port bridge_port zai_api_key brave_api_key openai_api_key openai_base_url openai_model primary_model_provider
  suggested_gateway_port="$(suggest_gateway_port)"
  suggested_bridge_port=$((suggested_gateway_port + DEFAULT_BRIDGE_OFFSET))
  gateway_port="$(prompt "Gateway 端口" "$suggested_gateway_port")"
  bridge_port="$(prompt "Bridge 端口" "$suggested_bridge_port")"
  primary_model_provider="$(normalize_primary_provider "$(prompt "主模型提供方（zai/codex）" "$(display_primary_provider "${OPENCLAW_PRIMARY_MODEL_PROVIDER:-zai}")")")"
  zai_api_key="$(prompt "ZAI_API_KEY（可留空使用当前环境变量）" "${ZAI_API_KEY:-}")"
  openai_api_key="$(prompt "Codex/OpenAI API key（可留空使用当前环境变量）" "${OPENAI_API_KEY:-${CODEX_API_KEY:-}}")"
  openai_base_url="$(prompt "Codex/OpenAI base URL（可留空）" "${OPENAI_BASE_URL:-${CODEX_BASE_URL:-}}")"
  openai_model="$(prompt "Codex/OpenAI model" "${OPENAI_MODEL:-${CODEX_MODEL:-gpt-5.4}}")"
  brave_api_key="$(prompt "BRAVE_API_KEY（可留空使用当前环境变量）" "${BRAVE_API_KEY:-}")"

  local args=("$INSTANCE_NAME" "$gateway_port" "$bridge_port" --with-weixin --skip-weixin-login)
  args+=(--primary-model-provider "$primary_model_provider")
  if [[ -n "$zai_api_key" ]]; then
    args+=(--zai-api-key "$zai_api_key")
  fi
  if [[ -n "$openai_api_key" ]]; then
    args+=(--codex-api-key "$openai_api_key")
  fi
  if [[ -n "$openai_base_url" ]]; then
    args+=(--codex-base-url "$openai_base_url")
  fi
  if [[ -n "$openai_model" ]]; then
    args+=(--codex-model "$openai_model")
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
    sync_instance_config
    compose restart openclaw-gateway >/dev/null
    wait_for_gateway
    return
  fi

  echo "正在安装微信插件..."
  compose run -T --rm openclaw-cli plugins install "@tencent-weixin/openclaw-weixin"
  sync_weixin_patches
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
