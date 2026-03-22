#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_PATH}
  ${SCRIPT_PATH} --interactive
  ${SCRIPT_PATH} --sync-instance-config <instance_dir>
  ${SCRIPT_PATH} <instance_name> <gateway_port|auto> <bridge_port|auto> [--without-weixin] [--skip-weixin-login] [--primary-model-provider <zai|openai>] [--zai-api-key <key>] [--openai-api-key <key>] [--openai-base-url <url>] [--openai-model <model>] [--brave-api-key <key>]

Creates a new OpenClaw instance under \${OPENCLAW_INSTANCES_DIR:-/root/openclaw-instances}/<instance_name> using the current
official OpenClaw image template. By default, openclaw-weixin is installed.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing dependency: $1"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

APT_UPDATED=0

has_compose() {
  if has_cmd docker-compose; then
    return 0
  fi

  if has_cmd docker && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

ensure_root_for_install() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Automatic dependency installation requires root"
  fi
}

detect_supported_apt_os() {
  if [[ ! -r /etc/os-release ]]; then
    return 1
  fi

  local os_id="" os_codename=""
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

  case "$os_id" in
    ubuntu|debian)
      ;;
    *)
      return 1
      ;;
  esac

  [[ -n "$os_codename" ]] || return 1
  printf '%s %s\n' "$os_id" "$os_codename"
}

apt_update_once() {
  ensure_root_for_install
  has_cmd apt-get || fail "Automatic dependency installation currently supports Debian/Ubuntu with apt-get only"

  if [[ "$APT_UPDATED" == "1" ]]; then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  APT_UPDATED=1
}

apt_install_packages() {
  local packages=("$@")
  [[ "${#packages[@]}" -gt 0 ]] || return 0

  detect_supported_apt_os >/dev/null 2>&1 || fail "Automatic dependency installation currently supports Debian/Ubuntu only"
  apt_update_once
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${packages[@]}"
}

ensure_node_binary() {
  if has_cmd node; then
    return 0
  fi

  if has_cmd nodejs; then
    install -d /usr/local/bin
    ln -sf "$(command -v nodejs)" /usr/local/bin/node
  fi

  has_cmd node
}

ensure_patch_dependencies() {
  local packages=()

  if ! has_cmd base64; then
    packages+=(coreutils)
  fi
  if ! has_cmd gzip; then
    packages+=(gzip)
  fi

  if [[ "${#packages[@]}" -gt 0 ]]; then
    echo "Installing patch dependencies: ${packages[*]}"
    apt_install_packages "${packages[@]}"
  fi

  require_cmd base64
  require_cmd gzip
}

install_docker_stack() {
  local os_id="" os_codename="" arch=""

  read -r os_id os_codename < <(detect_supported_apt_os) || fail "Automatic Docker installation currently supports Debian/Ubuntu only"
  apt_install_packages ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  arch="$(dpkg --print-architecture)"
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_id} ${os_codename} stable
EOF

  APT_UPDATED=0
  apt_install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  if has_cmd systemctl; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
}

ensure_host_dependencies() {
  local packages=()

  if ! has_cmd docker || ! has_compose; then
    echo "Installing Docker Engine and Compose plugin..."
    install_docker_stack
  fi

  if ! has_cmd openssl; then
    packages+=(openssl)
  fi
  if ! has_cmd gzip; then
    packages+=(gzip)
  fi
  if ! has_cmd base64; then
    packages+=(coreutils)
  fi

  if [[ "${#packages[@]}" -gt 0 ]]; then
    echo "Installing host packages: ${packages[*]}"
    apt_install_packages "${packages[@]}"
  fi

  if ! ensure_node_binary; then
    echo "Installing Node.js..."
    apt_install_packages nodejs npm
    ensure_node_binary || fail "Failed to make the node binary available after installing nodejs"
  fi

  require_compose
  require_cmd openssl
  require_cmd base64
  require_cmd gzip
  require_cmd node
}

require_compose() {
  if has_compose; then
    return 0
  fi

  fail "Missing dependency: docker-compose or docker compose"
}

run_compose() {
  if has_cmd docker-compose; then
    docker-compose "$@"
    return
  fi

  docker compose "$@"
}

weixin_accounts_patch_b64() {
  cat <<'EOF'
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
EOF
}

weixin_channel_patch_b64() {
  cat <<'EOF'
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
EOF
}

weixin_process_message_patch_b64() {
  cat <<'EOF'
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
EOF
}

write_embedded_weixin_patches() {
  local state_dir="$1"
  local extension_root="${state_dir}/extensions/openclaw-weixin"
  local target_accounts="${extension_root}/src/auth/accounts.ts"
  local target_channel="${extension_root}/src/channel.ts"
  local target_process_message="${extension_root}/src/messaging/process-message.ts"

  require_cmd base64
  require_cmd gzip
  [[ -d "$extension_root" ]] || fail "openclaw-weixin is not installed under ${extension_root}"

  mkdir -p "$(dirname "$target_accounts")" "$(dirname "$target_channel")" "$(dirname "$target_process_message")"
  weixin_accounts_patch_b64 | base64 -d | gzip -dc >"$target_accounts"
  weixin_channel_patch_b64 | base64 -d | gzip -dc >"$target_channel"
  weixin_process_message_patch_b64 | base64 -d | gzip -dc >"$target_process_message"

  if grep -q 'openclaw/plugin-sdk/command-auth' "$target_process_message"; then
    fail "Weixin compatibility patch verification failed: forbidden command-auth import still present"
  fi
}

prompt_required() {
  local label="$1"
  local default_value="${2:-}"
  local value=""
  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "${label} [${default_value}]: " value
      value="${value:-$default_value}"
    else
      read -r -p "${label}: " value
    fi
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "This value is required."
  done
}

prompt_optional() {
  local label="$1"
  local default_value="${2:-}"
  local value=""
  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " value
    printf '%s\n' "${value:-$default_value}"
  else
    read -r -p "${label}: " value
    printf '%s\n' "$value"
  fi
}

prompt_yes_no() {
  local label="$1"
  local default_value="${2:-N}"
  local answer=""
  while true; do
    read -r -p "${label} [${default_value}]: " answer
    answer="${answer:-$default_value}"
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *)
        echo "Please answer yes or no."
        ;;
    esac
  done
}

normalize_primary_provider() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    zai)
      printf 'zai\n'
      ;;
    codex|openai)
      printf 'openai\n'
      ;;
    *)
      fail "primary model provider must be zai or openai (codex is still accepted as an alias)"
      ;;
  esac
}

display_primary_provider() {
  printf '%s\n' "${1:-zai}"
}

is_port_in_use() {
  local port="$1"
  local status=0

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
  console.error(error);
  process.exit(2);
});

server.once("listening", () => {
  server.close(() => process.exit(1));
});

server.listen({ host: "127.0.0.1", port, exclusive: true });
EOF
  status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) fail "Port probe failed for ${port}" ;;
  esac
}

find_free_port_pair() {
  local port="${1:-18789}"

  while (( port <= 65533 )); do
    if ! is_port_in_use "$port" && ! is_port_in_use "$((port + 1))"; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 100))
  done

  fail "Unable to find a free gateway/bridge port pair"
}

validate_port_range() {
  local label="$1"
  local port="$2"
  if (( port < 1 || port > 65535 )); then
    fail "${label} must be between 1 and 65535"
  fi
}

resolve_ports() {
  local gateway_raw="$1"
  local bridge_raw="$2"
  local gateway=""
  local bridge=""

  if [[ "$gateway_raw" == "auto" && "$bridge_raw" != "auto" ]]; then
    fail "bridge_port cannot be fixed when gateway_port is auto"
  fi

  if [[ "$gateway_raw" == "auto" && "$bridge_raw" == "auto" ]]; then
    gateway="$(find_free_port_pair 18789)"
    bridge="$((gateway + 1))"
  elif [[ "$gateway_raw" != "auto" && "$bridge_raw" == "auto" ]]; then
    gateway="$gateway_raw"
    bridge="$((gateway_raw + 1))"
  else
    gateway="$gateway_raw"
    bridge="$bridge_raw"
  fi

  [[ "$gateway" =~ ^[0-9]+$ ]] || fail "gateway_port must be numeric or auto"
  [[ "$bridge" =~ ^[0-9]+$ ]] || fail "bridge_port must be numeric or auto"

  validate_port_range "gateway_port" "$gateway"
  validate_port_range "bridge_port" "$bridge"
  [[ "$gateway" != "$bridge" ]] || fail "gateway_port and bridge_port must be different"

  if is_port_in_use "$gateway"; then
    fail "gateway_port ${gateway} is already in use"
  fi
  if is_port_in_use "$bridge"; then
    fail "bridge_port ${bridge} is already in use"
  fi

  printf '%s %s\n' "$gateway" "$bridge"
}

if [[ "${1:-}" == "--write-weixin-patches" ]]; then
  shift
  [[ $# -eq 1 ]] || fail "Usage: ${SCRIPT_PATH} --write-weixin-patches <state_dir>"
  ensure_patch_dependencies
  write_embedded_weixin_patches "$1"
  exit 0
fi

if [[ "${1:-}" == "--ensure-host-deps" ]]; then
  shift
  [[ $# -eq 0 ]] || fail "Usage: ${SCRIPT_PATH} --ensure-host-deps"
  ensure_host_dependencies
  exit 0
fi

INTERACTIVE=0
SYNC_INSTANCE_DIR=""
if [[ "${1:-}" == "--sync-instance-config" ]]; then
  shift
  [[ $# -eq 1 ]] || fail "Usage: ${SCRIPT_PATH} --sync-instance-config <instance_dir>"
  SYNC_INSTANCE_DIR="$1"
  shift
fi

if [[ -n "$SYNC_INSTANCE_DIR" ]]; then
  INTERACTIVE=0
elif [[ $# -eq 0 ]]; then
  INTERACTIVE=1
elif [[ "${1:-}" == "--interactive" ]]; then
  INTERACTIVE=1
  shift
fi

INSTANCE_NAME=""
GATEWAY_PORT=""
BRIDGE_PORT=""

WITH_WEIXIN=1
AUTO_WEIXIN_LOGIN=1
ZAI_API_KEY_VALUE="${ZAI_API_KEY:-}"
OPENAI_API_KEY_VALUE="${OPENAI_API_KEY:-${CODEX_API_KEY:-}}"
OPENAI_BASE_URL_VALUE="${OPENAI_BASE_URL:-${CODEX_BASE_URL:-}}"
OPENAI_MODEL_VALUE="${OPENAI_MODEL:-${CODEX_MODEL:-gpt-5.4}}"
PRIMARY_MODEL_PROVIDER="$(normalize_primary_provider "${OPENCLAW_PRIMARY_MODEL_PROVIDER:-zai}")"
BRAVE_API_KEY_VALUE="${BRAVE_API_KEY:-}"
INSTANCES_BASE_DIR="${OPENCLAW_INSTANCES_DIR:-/root/openclaw-instances}"

if [[ -z "$SYNC_INSTANCE_DIR" && "$INTERACTIVE" == "0" ]]; then
  if [[ $# -lt 3 ]]; then
    usage
    exit 1
  fi
  INSTANCE_NAME="$1"
  GATEWAY_PORT="$2"
  BRIDGE_PORT="$3"
  shift 3
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      INTERACTIVE=1
      shift
      ;;
    --with-weixin)
      WITH_WEIXIN=1
      shift
      ;;
    --without-weixin)
      WITH_WEIXIN=0
      shift
      ;;
    --skip-weixin-login)
      AUTO_WEIXIN_LOGIN=0
      shift
      ;;
    --zai-api-key)
      [[ $# -ge 2 ]] || fail "--zai-api-key requires a value"
      ZAI_API_KEY_VALUE="${2:-}"
      shift 2
      ;;
    --codex-api-key|--openai-api-key)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      OPENAI_API_KEY_VALUE="${2:-}"
      shift 2
      ;;
    --codex-base-url|--openai-base-url)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      OPENAI_BASE_URL_VALUE="${2:-}"
      shift 2
      ;;
    --codex-model|--openai-model)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      OPENAI_MODEL_VALUE="${2:-}"
      shift 2
      ;;
    --primary-model-provider|--model-provider)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      PRIMARY_MODEL_PROVIDER="$(normalize_primary_provider "${2:-}")"
      shift 2
      ;;
    --brave-api-key)
      [[ $# -ge 2 ]] || fail "--brave-api-key requires a value"
      BRAVE_API_KEY_VALUE="${2:-}"
      shift 2
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "$SYNC_INSTANCE_DIR" ]]; then
  ensure_host_dependencies
fi

if [[ "$INTERACTIVE" == "1" ]]; then
  if [[ ! -t 0 ]]; then
    fail "Interactive mode requires a TTY. Re-run directly in a shell, or pass the parameters explicitly."
  fi

  echo "OpenClaw guided install"
  echo ""
  AUTO_GATEWAY_PORT="$(find_free_port_pair 18789)"
  AUTO_BRIDGE_PORT="$((AUTO_GATEWAY_PORT + 1))"
  INSTANCE_NAME="$(prompt_required "Instance name")"
  GATEWAY_PORT="$(prompt_required "Gateway port" "$AUTO_GATEWAY_PORT")"
  BRIDGE_PORT="$(prompt_required "Bridge port" "$AUTO_BRIDGE_PORT")"
  if prompt_yes_no "Install openclaw-weixin" "Y"; then
    WITH_WEIXIN=1
  else
    WITH_WEIXIN=0
  fi
  PRIMARY_MODEL_PROVIDER="$(normalize_primary_provider "$(prompt_required "Primary model provider (zai/openai)" "$(display_primary_provider "$PRIMARY_MODEL_PROVIDER")")")"
  ZAI_API_KEY_VALUE="$(prompt_optional "ZAI API key (optional)" "$ZAI_API_KEY_VALUE")"
  OPENAI_API_KEY_VALUE="$(prompt_optional "OpenAI API key (optional)" "$OPENAI_API_KEY_VALUE")"
  OPENAI_BASE_URL_VALUE="$(prompt_optional "OpenAI base URL (optional)" "$OPENAI_BASE_URL_VALUE")"
  OPENAI_MODEL_VALUE="$(prompt_optional "OpenAI model" "$OPENAI_MODEL_VALUE")"
  BRAVE_API_KEY_VALUE="$(prompt_optional "Brave API key" "$BRAVE_API_KEY_VALUE")"

  echo ""
  echo "Summary:"
  echo "  Instance: ${INSTANCE_NAME}"
  echo "  Gateway port: ${GATEWAY_PORT}"
  echo "  Bridge port: ${BRIDGE_PORT}"
  echo "  Weixin: $([[ "$WITH_WEIXIN" == "1" ]] && echo yes || echo no)"
  echo "  Primary model provider: $(display_primary_provider "$PRIMARY_MODEL_PROVIDER")"
  echo "  OpenAI model: ${OPENAI_MODEL_VALUE}"
  echo "  OpenAI base URL: ${OPENAI_BASE_URL_VALUE:-<default>}"
  echo "  Auto weixin login: $([[ "$WITH_WEIXIN" == "1" && "$AUTO_WEIXIN_LOGIN" == "1" ]] && echo yes || echo no)"
  echo "  Instance dir: ${INSTANCES_BASE_DIR}/${INSTANCE_NAME}"
  echo ""
  prompt_yes_no "Continue" "Y" || exit 0
fi

if [[ -z "$SYNC_INSTANCE_DIR" ]]; then
  [[ "$INSTANCE_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "instance_name contains invalid characters"
  read -r GATEWAY_PORT BRIDGE_PORT < <(resolve_ports "$GATEWAY_PORT" "$BRIDGE_PORT")

  INSTANCE_DIR="${INSTANCES_BASE_DIR}/${INSTANCE_NAME}"
  STATE_DIR="${INSTANCE_DIR}/state"
  WORKSPACE_DIR="${INSTANCE_DIR}/workspace"
  TOKEN="$(openssl rand -hex 32)"
else
  INSTANCE_DIR="$SYNC_INSTANCE_DIR"
  STATE_DIR="${INSTANCE_DIR}/state"
  WORKSPACE_DIR="${INSTANCE_DIR}/workspace"
  TOKEN=""
fi

CREATED_INSTANCE_DIR=0
CREATE_COMPLETED=0

compose() {
  DOCKER_BUILDKIT=1 COMPOSE_DOCKER_CLI_BUILD=1 run_compose -f "${INSTANCE_DIR}/docker-compose.yml" "$@"
}

cleanup_partial_instance() {
  if [[ "${CREATE_COMPLETED}" == "1" || "${CREATED_INSTANCE_DIR}" != "1" ]]; then
    return 0
  fi

  echo "Cleaning up incomplete instance: ${INSTANCE_DIR}" >&2
  if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
    run_compose -f "${INSTANCE_DIR}/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "${INSTANCE_DIR}"
}

trap cleanup_partial_instance ERR INT TERM

wait_for_gateway() {
  local retries=60
  local delay=2
  local i
  for ((i = 1; i <= retries; i++)); do
    if compose exec -T openclaw-gateway node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  fail "Gateway health check timed out"
}

restart_gateway() {
  compose restart openclaw-gateway >/dev/null
  wait_for_gateway
}

write_compose_file() {
  cat >"${INSTANCE_DIR}/docker-compose.yml" <<'EOF'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE}
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      OPENCLAW_PRIMARY_MODEL_PROVIDER: ${OPENCLAW_PRIMARY_MODEL_PROVIDER:-}
      CLAUDE_AI_SESSION_KEY: ${CLAUDE_AI_SESSION_KEY:-}
      CLAUDE_WEB_SESSION_KEY: ${CLAUDE_WEB_SESSION_KEY:-}
      CLAUDE_WEB_COOKIE: ${CLAUDE_WEB_COOKIE:-}
      ZAI_API_KEY: ${ZAI_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-}
      OPENAI_MODEL: ${OPENAI_MODEL:-}
      BRAVE_API_KEY: ${BRAVE_API_KEY:-}
      TZ: ${OPENCLAW_TZ}
    volumes:
      - ${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    ports:
      - "127.0.0.1:${OPENCLAW_GATEWAY_PORT}:18789"
      - "127.0.0.1:${OPENCLAW_BRIDGE_PORT}:18790"
    init: true
    restart: unless-stopped
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--bind",
        "${OPENCLAW_GATEWAY_BIND}",
        "--port",
        "18789",
      ]
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  openclaw-cli:
    profiles: ["cli"]
    image: ${OPENCLAW_IMAGE}
    network_mode: "service:openclaw-gateway"
    cap_drop:
      - NET_RAW
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      OPENCLAW_PRIMARY_MODEL_PROVIDER: ${OPENCLAW_PRIMARY_MODEL_PROVIDER:-}
      BROWSER: echo
      CLAUDE_AI_SESSION_KEY: ${CLAUDE_AI_SESSION_KEY:-}
      CLAUDE_WEB_SESSION_KEY: ${CLAUDE_WEB_SESSION_KEY:-}
      CLAUDE_WEB_COOKIE: ${CLAUDE_WEB_COOKIE:-}
      ZAI_API_KEY: ${ZAI_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-}
      OPENAI_MODEL: ${OPENAI_MODEL:-}
      BRAVE_API_KEY: ${BRAVE_API_KEY:-}
      TZ: ${OPENCLAW_TZ}
    volumes:
      - ${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    stdin_open: true
    tty: true
    init: true
    entrypoint: ["node", "dist/index.js"]
    depends_on:
      - openclaw-gateway
EOF
}

write_config_json() {
  node - "${STATE_DIR}/openclaw.json" "${INSTANCE_DIR}/.env" <<'EOF'
const fs = require("fs");

const path = process.argv[2];
const envPath = process.argv[3];
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
const resolvedOpenAiBaseUrl = openaiBaseUrl || "https://api.openai.com/v1";
const enableOpenAI = Boolean(openaiApiKey || openaiBaseUrl || primaryProvider === "openai");

const data = {
  auth: {
    profiles: {
      "zai:default": {
        provider: "zai",
        mode: "api_key",
      },
    },
  },
  agents: {
    defaults: {
      model: {
        primary: primaryProvider === "openai" ? `openai/${openaiModel}` : "zai/glm-5-turbo",
      },
      compaction: {
        mode: "safeguard",
      },
    },
  },
  commands: {
    native: "auto",
    nativeSkills: "auto",
    restart: true,
    ownerDisplay: "raw",
  },
  gateway: {
    mode: "local",
    bind: "lan",
    controlUi: {
      allowedOrigins: [
        "http://localhost:18789",
        "http://127.0.0.1:18789",
      ],
    },
  },
  tools: {
    web: {
      search: {
        enabled: true,
        provider: "brave",
      },
    },
  },
};

if (enableOpenAI) {
  data.auth.profiles["openai:default"] = {
    provider: "openai",
    mode: "api_key",
  };
  data.models = {
    providers: {
      openai: {
        apiKey: "$OPENAI_API_KEY",
        baseUrl: resolvedOpenAiBaseUrl,
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
      },
    },
  };

}

fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
EOF
}

configure_weixin_plugin() {
  node - "${STATE_DIR}/openclaw.json" <<'EOF'
const fs = require("fs");
const path = process.argv[2];
const data = JSON.parse(fs.readFileSync(path, "utf8"));
data.plugins = data.plugins || {};
data.plugins.allow = Array.from(new Set([...(data.plugins.allow || []), "openclaw-weixin"]));
data.plugins.entries = data.plugins.entries || {};
data.plugins.entries["openclaw-weixin"] = { enabled: true };
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
EOF
}

sync_weixin_patches() {
  write_embedded_weixin_patches "$STATE_DIR"
}

if [[ -n "$SYNC_INSTANCE_DIR" ]]; then
  INSTANCE_DIR="$SYNC_INSTANCE_DIR"
  STATE_DIR="${INSTANCE_DIR}/state"

  [[ -f "${INSTANCE_DIR}/.env" ]] || fail "Missing instance env file: ${INSTANCE_DIR}/.env"
  [[ -d "$STATE_DIR" ]] || fail "Missing state directory: ${STATE_DIR}"
  ensure_node_binary || fail "Missing dependency: node"

  write_compose_file
  write_config_json
  echo "Synced OpenClaw compose: ${INSTANCE_DIR}/docker-compose.yml"
  echo "Synced OpenClaw config: ${STATE_DIR}/openclaw.json"
  exit 0
fi

if [[ -e "$INSTANCE_DIR" ]] && [[ -n "$(find "$INSTANCE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "Instance directory already exists and is not empty: $INSTANCE_DIR"
fi

mkdir -p "${INSTANCES_BASE_DIR}"
mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"
CREATED_INSTANCE_DIR=1
chmod 777 "$STATE_DIR" "$WORKSPACE_DIR"
write_compose_file

cat >"${INSTANCE_DIR}/.env" <<EOF
OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest
OPENCLAW_GATEWAY_TOKEN=${TOKEN}
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}
OPENCLAW_BRIDGE_PORT=${BRIDGE_PORT}
OPENCLAW_TZ=Asia/Hong_Kong
OPENCLAW_CONFIG_DIR=${STATE_DIR}
OPENCLAW_WORKSPACE_DIR=${WORKSPACE_DIR}
OPENCLAW_PRIMARY_MODEL_PROVIDER=${PRIMARY_MODEL_PROVIDER}
ZAI_API_KEY=${ZAI_API_KEY_VALUE}
OPENAI_API_KEY=${OPENAI_API_KEY_VALUE}
OPENAI_BASE_URL=${OPENAI_BASE_URL_VALUE}
OPENAI_MODEL=${OPENAI_MODEL_VALUE}
BRAVE_API_KEY=${BRAVE_API_KEY_VALUE}
EOF

write_config_json

compose up -d openclaw-gateway
wait_for_gateway

if [[ "$WITH_WEIXIN" == "1" ]]; then
  compose run -T --rm openclaw-cli plugins install "@tencent-weixin/openclaw-weixin"
  sync_weixin_patches
  configure_weixin_plugin
  restart_gateway
fi

CREATE_COMPLETED=1
trap - ERR INT TERM

echo "Created instance: ${INSTANCE_DIR}"
echo "Gateway: 127.0.0.1:${GATEWAY_PORT}"
echo "Bridge: 127.0.0.1:${BRIDGE_PORT}"
echo "Primary model provider: $(display_primary_provider "$PRIMARY_MODEL_PROVIDER")"
echo "Primary model: $([[ "$PRIMARY_MODEL_PROVIDER" == "openai" ]] && printf 'openai/%s' "$OPENAI_MODEL_VALUE" || printf 'zai/glm-5-turbo')"
echo "Compose file: ${INSTANCE_DIR}/docker-compose.yml"
echo "Create/start command for future use:"
echo "  $(has_cmd docker-compose && printf 'docker-compose' || printf 'docker compose') -f ${INSTANCE_DIR}/docker-compose.yml up -d"
if [[ "$WITH_WEIXIN" == "1" ]]; then
  if [[ "$AUTO_WEIXIN_LOGIN" == "1" ]]; then
    echo "即将显示微信登录二维码。"
    echo "实例目录: ${INSTANCE_DIR}"
    echo "按 Ctrl+C 可退出。"
    if compose exec openclaw-gateway node dist/index.js channels login --channel openclaw-weixin; then
      echo "登录成功，正在重启 OpenClaw Gateway 以加载最新微信会话..."
      restart_gateway
      echo "Gateway 已重启完成。现在可以测试微信收发。"
    else
      echo "WARNING: Auto weixin login did not complete. You can retry with:" >&2
      echo "  ${SCRIPT_DIR}/weixin-login.sh ${INSTANCE_NAME}" >&2
    fi
  else
    echo "Next step:"
    echo "  ${SCRIPT_DIR}/weixin-login.sh ${INSTANCE_NAME}"
  fi
fi
