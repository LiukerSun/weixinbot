#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
CREATE_SCRIPT="${SCRIPT_DIR}/create-openclaw-instance.sh"
INSTANCES_BASE_DIR="${OPENCLAW_INSTANCES_DIR:-/root/openclaw-instances}"

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_PATH}
  ${SCRIPT_PATH} <instance_name|container_name> --model <provider/model> [--zai-api-key <key>] [--openai-api-key <key>] [--openai-base-url <url>] [--brave-api-key <key>] [--no-restart] [--skip-test]
  ${SCRIPT_PATH} <instance_name|container_name> --primary-model-provider <zai|openai> [--zai-model <model>] [--openai-model <model>] [--zai-api-key <key>] [--openai-api-key <key>] [--openai-base-url <url>] [--brave-api-key <key>] [--no-restart] [--skip-test]

Examples:
  ${SCRIPT_PATH}
  ${SCRIPT_PATH} openclaw_demo --model openai/gpt-5.4
  ${SCRIPT_PATH} openclaw_demo_openclaw-gateway_1 --model zai/glm-4.5-air
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  has_cmd "$1" || fail "Missing dependency: $1"
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

normalize_openai_base_url() {
  local value="${1:-}"

  if [[ -z "$value" ]]; then
    printf '\n'
    return 0
  fi

  value="${value%/}"
  case "$value" in
    http://*|https://*)
      if [[ "$value" =~ ^https?://[^/]+$ ]]; then
        printf '%s/v1\n' "$value"
      else
        printf '%s\n' "$value"
      fi
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
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

    echo "This value is required." >&2
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

prompt_optional_secret() {
  local label="$1"
  local default_value="${2:-}"
  local masked_default=""
  local value=""

  if [[ -n "$default_value" ]]; then
    masked_default="$(mask_secret "$default_value")"
    read -r -p "${label} [${masked_default}]: " value
    printf '%s\n' "${value:-$default_value}"
  else
    read -r -p "${label}: " value
    printf '%s\n' "$value"
  fi
}

prompt_select() {
  local label="$1"
  local default_index="$2"
  shift 2
  local options=("$@")
  local answer=""
  local i=1

  [[ "${#options[@]}" -gt 0 ]] || fail "prompt_select requires at least one option"
  (( default_index >= 1 && default_index <= ${#options[@]} )) || fail "prompt_select default index out of range"

  echo "${label}:" >&2
  for option in "${options[@]}"; do
    if (( i == default_index )); then
      echo "${i}) ${option} (default)" >&2
    else
      echo "${i}) ${option}" >&2
    fi
    i=$((i + 1))
  done

  while true; do
    read -r -p "Select number [${default_index}]: " answer
    answer="${answer:-$default_index}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
      printf '%s\n' "${options[$((answer - 1))]}"
      return 0
    fi
    echo "Please enter a number between 1 and ${#options[@]}." >&2
  done
}

prompt_yes_no() {
  local label="$1"
  local default_value="${2:-Y}"
  local answer=""

  while true; do
    read -r -p "${label} [${default_value}]: " answer
    answer="${answer:-$default_value}"
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
      y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        echo "Please answer yes or no." >&2
        ;;
    esac
  done
}

run_compose() {
  local compose_file="$1"
  shift

  if has_cmd docker-compose; then
    docker-compose -f "$compose_file" "$@"
    return
  fi

  docker compose -f "$compose_file" "$@"
}

env_value() {
  local env_file="$1"
  local key="$2"

  awk -F= -v expected_key="$key" '
    $1 == expected_key {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "$env_file"
}

resolve_instance_dir() {
  local input_name="$1"
  local candidate=""
  local working_dir=""
  local project_name=""
  local parsed_name=""

  if [[ -d "$input_name" && -f "$input_name/docker-compose.yml" ]]; then
    printf '%s\n' "$input_name"
    return 0
  fi

  candidate="${INSTANCES_BASE_DIR}/${input_name}"
  if [[ -f "${candidate}/docker-compose.yml" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  case "$input_name" in
    *_openclaw-gateway_*|*_openclaw-cli_*)
      parsed_name="${input_name%%_openclaw-*}"
      candidate="${INSTANCES_BASE_DIR}/${parsed_name}"
      if [[ -f "${candidate}/docker-compose.yml" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
  esac

  if has_cmd docker; then
    working_dir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$input_name" 2>/dev/null || true)"
    if [[ -n "$working_dir" && -f "${working_dir}/docker-compose.yml" ]]; then
      printf '%s\n' "$working_dir"
      return 0
    fi

    project_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$input_name" 2>/dev/null || true)"
    if [[ -n "$project_name" ]]; then
      candidate="${INSTANCES_BASE_DIR}/${project_name}"
      if [[ -f "${candidate}/docker-compose.yml" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  fail "Unable to resolve instance from name: ${input_name}"
}

current_primary_model() {
  local instance_dir="$1"
  local env_file="${instance_dir}/.env"
  local provider=""
  local model=""

  [[ -f "$env_file" ]] || fail "Missing env file: ${env_file}"
  provider="$(env_value "$env_file" "OPENCLAW_PRIMARY_MODEL_PROVIDER" || true)"
  provider="${provider:-zai}"
  provider="$(normalize_primary_provider "$provider")"

  if [[ "$provider" == "openai" ]]; then
    model="$(env_value "$env_file" "OPENAI_MODEL" || true)"
    model="${model:-gpt-5.4}"
  else
    model="$(env_value "$env_file" "ZAI_MODEL" || true)"
    model="${model:-glm-5-turbo}"
  fi

  printf '%s/%s\n' "$provider" "$model"
}

list_running_gateway_containers() {
  if ! has_cmd docker; then
    return 0
  fi

  docker ps \
    --filter 'label=com.docker.compose.service=openclaw-gateway' \
    --format '{{.Names}}'
}

list_local_instance_dirs() {
  if [[ ! -d "$INSTANCES_BASE_DIR" ]]; then
    return 0
  fi

  find "$INSTANCES_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort | while read -r instance_dir; do
    if [[ -f "${instance_dir}/docker-compose.yml" ]]; then
      printf '%s\n' "$instance_dir"
    fi
  done
}

run_model_smoke_test() {
  local env_file="$1"

  node - "$env_file" <<'EOF'
const fs = require("fs");

const envPath = process.argv[2];
const env = {};

for (const rawLine of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
  if (!rawLine || /^\s*#/.test(rawLine)) {
    continue;
  }
  const separatorIndex = rawLine.indexOf("=");
  if (separatorIndex === -1) {
    continue;
  }
  env[rawLine.slice(0, separatorIndex).trim()] = rawLine.slice(separatorIndex + 1);
}

function fail(message) {
  console.error(`Smoke test failed: ${message}`);
  process.exit(1);
}

function warn(message) {
  console.log(`Smoke test warning: ${message}`);
  process.exit(0);
}

function normalizeBaseUrl(raw, fallback) {
  const value = (raw || "").trim().replace(/\/+$/, "");
  if (!value) {
    return fallback;
  }
  if (/^https?:\/\/[^/]+$/i.test(value)) {
    return `${value}/v1`;
  }
  return value;
}

async function main() {
  const provider = (env.OPENCLAW_PRIMARY_MODEL_PROVIDER || "zai").trim().toLowerCase();
  let url = "";
  let apiKey = "";
  let model = "";
  let providerLabel = "";

  if (provider === "openai") {
    providerLabel = "openai";
    url = `${normalizeBaseUrl(env.OPENAI_BASE_URL, "https://api.openai.com/v1")}/chat/completions`;
    apiKey = env.OPENAI_API_KEY || "";
    model = env.OPENAI_MODEL || "gpt-5.4";
  } else {
    providerLabel = "zai";
    url = `${normalizeBaseUrl("", "https://open.bigmodel.cn/api/coding/paas/v4")}/chat/completions`;
    apiKey = env.ZAI_API_KEY || "";
    model = env.ZAI_MODEL || "glm-5-turbo";
  }

  if (!apiKey) {
    fail(`${providerLabel} API key is empty`);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30000);

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "user", content: "Reply with OK only." },
        ],
        max_tokens: 8,
        temperature: 0,
      }),
      signal: controller.signal,
    });

    const text = await response.text();
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }

    if (!response.ok) {
      const errorCode = String(parsed?.error?.code || "");
      const errorMessage = String(parsed?.error?.message || "");
      if (
        providerLabel === "zai" &&
        response.status === 429 &&
        errorCode === "1113"
      ) {
        warn(`provider=${providerLabel} model=${model} endpoint=${url} reachable, but the account has no available balance/package. Response: ${JSON.stringify(parsed)}`);
      }
      const snippet = parsed ? JSON.stringify(parsed) : text.slice(0, 500);
      fail(`${providerLabel} request returned HTTP ${response.status}. Response: ${snippet}`);
    }

    const content = parsed?.choices?.[0]?.message?.content;
    console.log(`Smoke test passed: provider=${providerLabel} model=${model} endpoint=${url}`);
    if (content) {
      console.log(`Smoke test reply: ${String(content).trim().slice(0, 200)}`);
    }
  } catch (error) {
    if (error?.name === "AbortError") {
      fail(`${providerLabel} request timed out after 30s`);
    }
    fail(error?.message || String(error));
  } finally {
    clearTimeout(timeout);
  }
}

main();
EOF
}

interactive_select_target() {
  local containers=()
  local container=""
  local instance_dir=""
  local instance_name=""
  local model=""
  local options=()
  local option_keys=()
  local index=1
  local selection=""

  if [[ ! -t 0 ]]; then
    fail "Interactive mode requires a TTY. Re-run directly in a shell, or pass the target name explicitly."
  fi

  mapfile -t containers < <(list_running_gateway_containers)
  for container in "${containers[@]}"; do
    [[ -n "$container" ]] || continue
    instance_dir="$(resolve_instance_dir "$container")"
    instance_name="$(basename "$instance_dir")"
    model="$(current_primary_model "$instance_dir")"
    options+=("${index}) ${instance_name}  container=${container}  current=${model}")
    option_keys+=("$container")
    index=$((index + 1))
  done

  if [[ "${#option_keys[@]}" -eq 0 ]]; then
    while read -r instance_dir; do
      [[ -n "$instance_dir" ]] || continue
      instance_name="$(basename "$instance_dir")"
      model="$(current_primary_model "$instance_dir")"
      options+=("${index}) ${instance_name}  current=${model}")
      option_keys+=("$instance_name")
      index=$((index + 1))
    done < <(list_local_instance_dirs)
  fi

  if [[ "${#option_keys[@]}" -eq 0 ]]; then
    fail "No running OpenClaw instances found, and no local instances exist under ${INSTANCES_BASE_DIR}"
  fi

  echo "Available OpenClaw targets:" >&2
  printf '%s\n' "${options[@]}" >&2

  while true; do
    selection="$(prompt_required "Select target number")"
    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#option_keys[@]} )); then
      printf '%s\n' "${option_keys[$((selection - 1))]}"
      return 0
    fi
    echo "Please enter a number between 1 and ${#option_keys[@]}." >&2
  done
}

TARGET_NAME="${1:-}"
if [[ -n "$TARGET_NAME" ]]; then
  shift || true
fi

MODEL_REF=""
PRIMARY_MODEL_PROVIDER=""
ZAI_MODEL_VALUE=""
OPENAI_MODEL_VALUE=""
ZAI_API_KEY_VALUE=""
OPENAI_API_KEY_VALUE=""
OPENAI_BASE_URL_VALUE=""
BRAVE_API_KEY_VALUE=""
RESTART_AFTER_SYNC=1
RUN_SMOKE_TEST=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || fail "--model requires a value"
      MODEL_REF="${2:-}"
      shift 2
      ;;
    --primary-model-provider|--model-provider)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      PRIMARY_MODEL_PROVIDER="$(normalize_primary_provider "${2:-}")"
      shift 2
      ;;
    --zai-model)
      [[ $# -ge 2 ]] || fail "--zai-model requires a value"
      ZAI_MODEL_VALUE="${2:-}"
      shift 2
      ;;
    --openai-model|--codex-model)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      OPENAI_MODEL_VALUE="${2:-}"
      shift 2
      ;;
    --zai-api-key)
      [[ $# -ge 2 ]] || fail "--zai-api-key requires a value"
      ZAI_API_KEY_VALUE="${2:-}"
      shift 2
      ;;
    --openai-api-key|--codex-api-key)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      OPENAI_API_KEY_VALUE="${2:-}"
      shift 2
      ;;
    --openai-base-url|--codex-base-url)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      OPENAI_BASE_URL_VALUE="$(normalize_openai_base_url "${2:-}")"
      shift 2
      ;;
    --brave-api-key)
      [[ $# -ge 2 ]] || fail "--brave-api-key requires a value"
      BRAVE_API_KEY_VALUE="${2:-}"
      shift 2
      ;;
    --no-restart)
      RESTART_AFTER_SYNC=0
      shift
      ;;
    --skip-test)
      RUN_SMOKE_TEST=0
      shift
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

if [[ -z "$TARGET_NAME" ]]; then
  TARGET_NAME="$(interactive_select_target)"
fi

INSTANCE_DIR="$(resolve_instance_dir "$TARGET_NAME")"
ENV_FILE="${INSTANCE_DIR}/.env"
STATE_DIR="${INSTANCE_DIR}/state"
COMPOSE_FILE="${INSTANCE_DIR}/docker-compose.yml"
CURRENT_PRIMARY_MODEL="$(current_primary_model "$INSTANCE_DIR")"

[[ -x "$CREATE_SCRIPT" ]] || fail "Missing create script: ${CREATE_SCRIPT}"
[[ -f "$ENV_FILE" ]] || fail "Missing env file: ${ENV_FILE}"
[[ -d "$STATE_DIR" ]] || fail "Missing state directory: ${STATE_DIR}"
require_cmd node

if [[ -z "$MODEL_REF" && -z "$PRIMARY_MODEL_PROVIDER" && -z "$ZAI_MODEL_VALUE" && -z "$OPENAI_MODEL_VALUE" ]]; then
  if [[ -t 0 ]]; then
    if [[ "$(current_primary_model "$INSTANCE_DIR" | cut -d/ -f1)" == "openai" ]]; then
      PRIMARY_MODEL_PROVIDER="$(prompt_select "Model provider" 2 "zai" "openai")"
    else
      PRIMARY_MODEL_PROVIDER="$(prompt_select "Model provider" 1 "zai" "openai")"
    fi
    PRIMARY_MODEL_PROVIDER="$(normalize_primary_provider "$PRIMARY_MODEL_PROVIDER")"
    if [[ "$PRIMARY_MODEL_PROVIDER" == "zai" ]]; then
      ZAI_MODEL_VALUE="$(prompt_required "ZAI model（直接回车保留当前值）" "$(env_value "$ENV_FILE" "ZAI_MODEL" || true)")"
      ZAI_MODEL_VALUE="${ZAI_MODEL_VALUE:-glm-5-turbo}"
      ZAI_API_KEY_VALUE="$(prompt_optional_secret "ZAI API key（直接回车保留当前值，可留空）" "$(env_value "$ENV_FILE" "ZAI_API_KEY" || true)")"
    else
      OPENAI_MODEL_VALUE="$(prompt_required "OpenAI model（直接回车保留当前值）" "$(env_value "$ENV_FILE" "OPENAI_MODEL" || true)")"
      OPENAI_MODEL_VALUE="${OPENAI_MODEL_VALUE:-gpt-5.4}"
      OPENAI_API_KEY_VALUE="$(prompt_optional_secret "OpenAI API key（直接回车保留当前值，可留空）" "$(env_value "$ENV_FILE" "OPENAI_API_KEY" || true)")"
      OPENAI_BASE_URL_VALUE="$(normalize_openai_base_url "$(prompt_optional "OpenAI base URL（直接回车保留当前值，可留空）" "$(env_value "$ENV_FILE" "OPENAI_BASE_URL" || true)")")"
    fi
    if prompt_yes_no "Reload gateway after sync" "Y"; then
      RESTART_AFTER_SYNC=1
    else
      RESTART_AFTER_SYNC=0
    fi
  else
    usage
    exit 1
  fi
fi

if [[ -n "$MODEL_REF" ]]; then
  if [[ "$MODEL_REF" != */* ]]; then
    fail "--model must look like provider/model"
  fi

  PRIMARY_MODEL_PROVIDER="$(normalize_primary_provider "${MODEL_REF%%/*}")"
  case "$PRIMARY_MODEL_PROVIDER" in
    zai)
      ZAI_MODEL_VALUE="${MODEL_REF#*/}"
      ;;
    openai)
      OPENAI_MODEL_VALUE="${MODEL_REF#*/}"
      ;;
  esac
fi

node - "$ENV_FILE" "$PRIMARY_MODEL_PROVIDER" "$ZAI_MODEL_VALUE" "$OPENAI_MODEL_VALUE" "$ZAI_API_KEY_VALUE" "$OPENAI_API_KEY_VALUE" "$OPENAI_BASE_URL_VALUE" "$BRAVE_API_KEY_VALUE" <<'EOF'
const fs = require("fs");

const [
  envPath,
  primaryProviderArg,
  zaiModelArg,
  openaiModelArg,
  zaiApiKeyArg,
  openaiApiKeyArg,
  openaiBaseUrlArg,
  braveApiKeyArg,
] = process.argv.slice(2);

const lines = fs.readFileSync(envPath, "utf8").split(/\r?\n/);
const env = {};
const keysInOrder = [];

for (const rawLine of lines) {
  if (!rawLine || /^\s*#/.test(rawLine)) {
    continue;
  }

  const separatorIndex = rawLine.indexOf("=");
  if (separatorIndex === -1) {
    continue;
  }

  const key = rawLine.slice(0, separatorIndex).trim();
  keysInOrder.push(key);
  env[key] = rawLine.slice(separatorIndex + 1);
}

function setValue(key, value) {
  if (value === "") {
    return;
  }

  if (!(key in env)) {
    keysInOrder.push(key);
  }
  env[key] = value;
}

const currentProvider = (env.OPENCLAW_PRIMARY_MODEL_PROVIDER || "zai").trim().toLowerCase();
const nextProvider = primaryProviderArg || currentProvider;
const nextZaiModel = zaiModelArg || env.ZAI_MODEL || "glm-5-turbo";
const nextOpenAiModel = openaiModelArg || env.OPENAI_MODEL || "gpt-5.4";

setValue("OPENCLAW_PRIMARY_MODEL_PROVIDER", nextProvider);
setValue("ZAI_MODEL", nextZaiModel);
setValue("OPENAI_MODEL", nextOpenAiModel);
setValue("ZAI_API_KEY", zaiApiKeyArg);
setValue("OPENAI_API_KEY", openaiApiKeyArg);
setValue("OPENAI_BASE_URL", openaiBaseUrlArg);
setValue("BRAVE_API_KEY", braveApiKeyArg);

const uniqueKeys = [];
for (const key of keysInOrder) {
  if (!uniqueKeys.includes(key)) {
    uniqueKeys.push(key);
  }
}

const output = uniqueKeys.map((key) => `${key}=${env[key] ?? ""}`).join("\n");
fs.writeFileSync(envPath, `${output}\n`);
EOF

bash "$CREATE_SCRIPT" --sync-instance-config "$INSTANCE_DIR" >/dev/null

if [[ "$RESTART_AFTER_SYNC" == "1" ]] && [[ -f "$COMPOSE_FILE" ]] && has_cmd docker; then
  if docker inspect "${TARGET_NAME}" >/dev/null 2>&1 || docker ps -aq --filter "label=com.docker.compose.project=$(basename "$INSTANCE_DIR")" | grep -q .; then
    run_compose "$COMPOSE_FILE" up -d --force-recreate --no-deps openclaw-gateway >/dev/null
  fi
fi

PRIMARY_MODEL_DISPLAY="$(node - "$ENV_FILE" <<'EOF'
const fs = require("fs");
const env = {};

for (const rawLine of fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/)) {
  if (!rawLine || /^\s*#/.test(rawLine)) {
    continue;
  }
  const separatorIndex = rawLine.indexOf("=");
  if (separatorIndex === -1) {
    continue;
  }
  env[rawLine.slice(0, separatorIndex).trim()] = rawLine.slice(separatorIndex + 1);
}

const provider = (env.OPENCLAW_PRIMARY_MODEL_PROVIDER || "zai").trim().toLowerCase();
const model = provider === "openai" ? (env.OPENAI_MODEL || "gpt-5.4") : (env.ZAI_MODEL || "glm-5-turbo");
process.stdout.write(`${provider}/${model}`);
EOF
)"

echo "Updated instance: ${INSTANCE_DIR}"
echo "Primary model provider: $(display_primary_provider "${PRIMARY_MODEL_DISPLAY%%/*}")"
echo "Primary model: ${PRIMARY_MODEL_DISPLAY}"
if [[ "$PRIMARY_MODEL_DISPLAY" == "$CURRENT_PRIMARY_MODEL" ]]; then
  echo "Model change: unchanged (you kept the current value)"
fi
if [[ "$RESTART_AFTER_SYNC" == "1" ]]; then
  echo "Gateway reload: attempted"
else
  echo "Gateway reload: skipped"
fi

if [[ "$RUN_SMOKE_TEST" == "1" ]]; then
  run_model_smoke_test "$ENV_FILE"
else
  echo "Smoke test: skipped"
fi
