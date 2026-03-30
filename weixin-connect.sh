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

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  has_cmd "$1" || fail "Missing required command: $1"
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

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "${@}"
}

run_node_in_state() {
  local target="$1"
  docker run --rm -i \
    -e "BRAVE_API_KEY=${BRAVE_API_KEY:-}" \
    -v "${STATE_DIR}:/state" \
    --entrypoint node \
    "$OPENCLAW_IMAGE" \
    - "$target"
}

wait_for_gateway() {
  local retries=60
  local i=0

  for ((i = 1; i <= retries; i += 1)); do
    if compose exec -T openclaw-gateway node -e \
      "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

ensure_gateway_running() {
  compose up -d openclaw-gateway >/dev/null
  wait_for_gateway || fail "Gateway 启动超时: ${INSTANCE_NAME}"
}

promote_staged_plugin() {
  local staged_dir=""
  local candidate=""

  [[ -d "$EXTENSIONS_DIR" ]] || return 0

  if [[ -d "$PLUGIN_DIR" ]]; then
    while IFS= read -r candidate; do
      rm -rf -- "$candidate"
    done < <(find "$EXTENSIONS_DIR" -maxdepth 1 -mindepth 1 -type d -name '.openclaw-install-stage-*' | sort)
    return 0
  fi

  staged_dir="$(find "$EXTENSIONS_DIR" -maxdepth 1 -mindepth 1 -type d -name '.openclaw-install-stage-*' | sort | tail -n 1)"
  if [[ -n "$staged_dir" ]]; then
    mv "$staged_dir" "$PLUGIN_DIR"
  fi

  while IFS= read -r candidate; do
    rm -rf -- "$candidate"
  done < <(find "$EXTENSIONS_DIR" -maxdepth 1 -mindepth 1 -type d -name '.openclaw-install-stage-*' | sort)
}

install_weixin_plugin() {
  mkdir -p "$EXTENSIONS_DIR"

  if [[ -d "$PLUGIN_DIR" ]]; then
    return 0
  fi

  info "安装微信插件: ${WEIXIN_PLUGIN_PACKAGE}"
  if has_cmd timeout; then
    timeout 180s compose run -T --rm --no-deps openclaw-cli plugins install "${WEIXIN_PLUGIN_PACKAGE}" || true
  else
    compose run -T --rm --no-deps openclaw-cli plugins install "${WEIXIN_PLUGIN_PACKAGE}" || true
  fi

  promote_staged_plugin
  [[ -d "$PLUGIN_DIR" ]] || fail "微信插件目录不存在，安装失败: ${PLUGIN_DIR}"
}

install_weixin_dependencies() {
  info "安装微信插件运行时依赖"
  compose run -T --rm --no-deps --entrypoint sh openclaw-cli -lc '
    set -e
    cd /home/node/.openclaw/extensions/openclaw-weixin
    npm install --omit=dev --ignore-scripts --no-package-lock
  '
}

configure_openclaw_json() {
  local config_file="/state/openclaw.json"
  local brave_api_key="${BRAVE_API_KEY:-}"

  run_node_in_state "$config_file" <<EOF
const fs = require("fs");

const configPath = process.argv[2];
const braveApiKey = process.env.BRAVE_API_KEY || "";

let config = {};
if (fs.existsSync(configPath)) {
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch {
    config = {};
  }
}

config.plugins ??= {};
config.plugins.allow = Array.from(new Set([...(config.plugins.allow || []), "openclaw-weixin"]));

config.tools ??= {};
config.tools.web ??= {};
config.tools.web.search ??= {};
if (braveApiKey) {
  config.tools.web.search.apiKey = braveApiKey;
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
EOF
}

rewrite_weixin_sdk_imports() {
  run_node_in_state "/state/extensions/openclaw-weixin" <<'EOF'
const fs = require("fs");
const path = require("path");

const extensionRoot = process.argv[2];
const replacements = [
  ["openclaw/plugin-sdk/plugin-entry", "openclaw/plugin-sdk"],
  ["openclaw/plugin-sdk/channel-config-schema", "openclaw/plugin-sdk"],
  ["openclaw/plugin-sdk/infra-runtime", "openclaw/plugin-sdk"],
  ["openclaw/plugin-sdk/reply-runtime", "openclaw/plugin-sdk"],
  ["openclaw/plugin-sdk/text-runtime", "openclaw/plugin-sdk"],
  ["openclaw/plugin-sdk/config-runtime", "openclaw/plugin-sdk"],
  ["openclaw/plugin-sdk/channel-contract", "openclaw/plugin-sdk"],
  ["openclaw/plugin-sdk/core", "openclaw/plugin-sdk"],
  ['import { resolvePreferredOpenClawTmpDir } from "openclaw/plugin-sdk";', ""],
  [
    "const MAIN_LOG_DIR = resolvePreferredOpenClawTmpDir();",
    'const MAIN_LOG_DIR = path.join(process.env.OPENCLAW_TMP_DIR?.trim() || process.env.TMPDIR?.trim() || os.tmpdir(), "openclaw");',
  ],
];

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules") continue;
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(fullPath);
      continue;
    }
    if (!entry.isFile() || !/\.(?:[cm]?[jt]sx?)$/.test(entry.name)) continue;

    const original = fs.readFileSync(fullPath, "utf8");
    let next = original;
    for (const [from, to] of replacements) {
      next = next.split(from).join(to);
    }
    if (next !== original) {
      fs.writeFileSync(fullPath, next);
    }
  }
}

walk(extensionRoot);
EOF
}

patch_process_message_sdk_compat() {
  run_node_in_state "/state/extensions/openclaw-weixin/src/messaging/process-message.ts" <<'EOF'
const fs = require("fs");

const targetFile = process.argv[2];
if (!fs.existsSync(targetFile)) process.exit(0);

let source = fs.readFileSync(targetFile, "utf8");

source = source.replace(
  /import \{\s*createTypingCallbacks,\s*resolveDirectDmAuthorizationOutcome,\s*resolveSenderCommandAuthorizationWithRuntime,\s*\} from "openclaw\/plugin-sdk";/,
  "",
);
source = source.replace(
  /import \{\s*createTypingCallbacks,\s*resolveDirectDmAuthorizationOutcome,\s*\} from "openclaw\/plugin-sdk";/,
  "",
);
source = source.replace(
  /import \{\s*createTypingCallbacks,\s*\} from "openclaw\/plugin-sdk";/,
  "",
);
source = source.replace("  resolveSenderCommandAuthorizationWithRuntime,\n", "");
source = source.replace("  resolveDirectDmAuthorizationOutcome,\n", "");
source = source.replace(
  /function createTypingCallbacks\(params: \{\\n[\s\S]*?\}\n?export async function processOneMessage\(/,
  "export async function processOneMessage(",
);
source = source.replace(
  /function resolveWeixinDirectDmAuthorizationOutcome\(params: \{\\n[\s\S]*?\}\n?export async function processOneMessage\(/,
  "export async function processOneMessage(",
);
source = source.replace(
  /async function resolveWeixinCommandAuthorization\(params: \{\\n[\s\S]*?\}\n?export async function processOneMessage\(/,
  "export async function processOneMessage(",
);

if (
  !source.includes("function createTypingCallbacks(") ||
  !source.includes("resolveWeixinDirectDmAuthorizationOutcome(") ||
  !source.includes("resolveWeixinCommandAuthorization(")
) {
  const marker = "export async function processOneMessage(\n";
  const helper = [
    "function createTypingCallbacks(params: {",
    "  start: () => Promise<void>;",
    "  stop?: () => Promise<void>;",
    "  onStartError?: (err: unknown) => void;",
    "  onStopError?: (err: unknown) => void;",
    "  keepaliveIntervalMs?: number;",
    "  maxConsecutiveFailures?: number;",
    "  maxDurationMs?: number;",
    "}) {",
    "  const keepaliveIntervalMs = params.keepaliveIntervalMs ?? 3000;",
    "  const maxConsecutiveFailures = Math.max(1, params.maxConsecutiveFailures ?? 2);",
    "  const maxDurationMs = params.maxDurationMs ?? 60000;",
    "  let consecutiveFailures = 0;",
    "  let tripped = false;",
    "  let closed = false;",
    "  let stopSent = false;",
    "  let keepaliveTimer;",
    "  let ttlTimer;",
    "",
    "  const clearKeepalive = () => {",
    "    if (keepaliveTimer) {",
    "      clearInterval(keepaliveTimer);",
    "      keepaliveTimer = undefined;",
    "    }",
    "  };",
    "",
    "  const clearTtl = () => {",
    "    if (ttlTimer) {",
    "      clearTimeout(ttlTimer);",
    "      ttlTimer = undefined;",
    "    }",
    "  };",
    "",
    "  const fireStart = async () => {",
    "    if (closed || tripped) return;",
    "    try {",
    "      await params.start();",
    "      consecutiveFailures = 0;",
    "    } catch (err) {",
    "      consecutiveFailures += 1;",
    "      params.onStartError?.(err);",
    "      if (consecutiveFailures >= maxConsecutiveFailures) {",
    "        tripped = true;",
    "        clearKeepalive();",
    "        clearTtl();",
    "      }",
    "    }",
    "  };",
    "",
    "  const fireStop = () => {",
    "    closed = true;",
    "    clearKeepalive();",
    "    clearTtl();",
    "    if (!params.stop || stopSent) return;",
    "    stopSent = true;",
    "    void params.stop().catch((err) => {",
    "      (params.onStopError ?? params.onStartError)?.(err);",
    "    });",
    "  };",
    "",
    "  return {",
    "    onReplyStart: async () => {",
    "      if (closed) return;",
    "      stopSent = false;",
    "      tripped = false;",
    "      consecutiveFailures = 0;",
    "      clearKeepalive();",
    "      clearTtl();",
    "      await fireStart();",
    "      if (closed || tripped) return;",
    "      keepaliveTimer = setInterval(() => {",
    "        void fireStart();",
    "      }, keepaliveIntervalMs);",
    "      if (maxDurationMs > 0) {",
    "        ttlTimer = setTimeout(() => {",
    "          fireStop();",
    "        }, maxDurationMs);",
    "      }",
    "    },",
    "    onIdle: fireStop,",
    "    onCleanup: fireStop,",
    "  };",
    "}",
    "",
    "function resolveWeixinDirectDmAuthorizationOutcome(params: {",
    '  dmPolicy: "pairing";',
    "  senderAllowedForCommands: boolean;",
    '}): "allowed" | "unauthorized" {',
    '  if (params.dmPolicy === "pairing" && !params.senderAllowedForCommands) {',
    '    return "unauthorized";',
    "  }",
    '  return "allowed";',
    "}",
    "",
    "async function resolveWeixinCommandAuthorization(params: {",
    "  accountId: string;",
    "  senderId: string;",
    "}): Promise<{ senderAllowedForCommands: boolean; commandAuthorized: boolean }> {",
    "  const allowFrom = readFrameworkAllowFromList(params.accountId);",
    "  if (allowFrom.length === 0) {",
    "    const uid = loadWeixinAccount(params.accountId)?.userId?.trim();",
    "    if (uid) allowFrom.push(uid);",
    "  }",
    "  const senderAllowedForCommands = allowFrom.length === 0 || allowFrom.includes(params.senderId);",
    "  return { senderAllowedForCommands, commandAuthorized: senderAllowedForCommands };",
    "}",
    "",
  ].join("\n");

  if (!source.includes(marker)) {
    throw new Error("process-message marker not found");
  }
  source = source.replace(marker, helper + marker);
}

source = source.replace(
  /const \{ senderAllowedForCommands, commandAuthorized \} =\s*\n\s*await resolveSenderCommandAuthorizationWithRuntime\(\{\n[\s\S]*?\n\s*\}\);/,
  `const { senderAllowedForCommands, commandAuthorized } =
    await resolveWeixinCommandAuthorization({
      accountId: deps.accountId,
      senderId,
    });`,
);

source = source.replace(
  /const directDmOutcome = resolveDirectDmAuthorizationOutcome\(\{\n[\s\S]*?\n\s*\}\);/,
  `const directDmOutcome = resolveWeixinDirectDmAuthorizationOutcome({
    dmPolicy: "pairing",
    senderAllowedForCommands,
  });`,
);

fs.writeFileSync(targetFile, source);
EOF
}

patch_send_sdk_compat() {
  run_node_in_state "/state/extensions/openclaw-weixin/src/messaging/send.ts" <<'EOF'
const fs = require("fs");

const targetFile = process.argv[2];
if (!fs.existsSync(targetFile)) process.exit(0);

let source = fs.readFileSync(targetFile, "utf8");
source = source.replace('import { stripMarkdown } from "openclaw/plugin-sdk";\n', "");
source = source.replace(
  /function stripMarkdown\(text: string\): string \{\\n[\s\S]*?\\n\}\n?/g,
  "",
);

if (!source.includes("function stripMarkdown(")) {
  const marker = "function generateClientId(): string {\n";
  const helper = [
    "function stripMarkdown(text: string): string {",
    "  return String(text)",
    '    .replace(/^#{1,6}\\s+/gm, "")',
    '    .replace(/^\\s*>\\s?/gm, "")',
    '    .replace(/^\\s*[-+*]\\s+/gm, "")',
    '    .replace(/^\\s*\\d+\\.\\s+/gm, "")',
    '    .replace(/(\\*\\*|__|\\*|_|~~|\\\\x60)/g, "")',
    '    .replace(/\\r/g, "");',
    "}",
    "",
  ].join("\n");

  if (!source.includes(marker)) {
    throw new Error("send marker not found");
  }
  source = source.replace(marker, helper + marker);
}

fs.writeFileSync(targetFile, source);
EOF
}

patch_pairing_sdk_compat() {
  run_node_in_state "/state/extensions/openclaw-weixin/src/auth/pairing.ts" <<'EOF'
const fs = require("fs");

const targetFile = process.argv[2];
if (!fs.existsSync(targetFile)) process.exit(0);

let source = fs.readFileSync(targetFile, "utf8");
source = source.replace('import { withFileLock } from "openclaw/plugin-sdk";\n', "");
source = source.replace(
  /async function sleep\(ms: number\): Promise<void> \{\\n[\s\S]*?\}\n(?=async function sleep\(ms: number\): Promise<void> \{)/,
  "",
);
source = source.replace(
  /async function sleep\(ms: number\): Promise<void> \{\\n[\s\S]*?\}\n(?=\/\*\*)/,
  "",
);

if (!/async function withFileLock(?:<[^>]+>)?\(/.test(source)) {
  const marker = "/**\n * Resolve the framework credentials directory (mirrors core resolveOAuthDir).\n";
  const helper = [
    "async function sleep(ms: number): Promise<void> {",
    "  await new Promise((resolve) => setTimeout(resolve, ms));",
    "}",
    "",
    "async function withFileLock<T>(",
    "  filePath: string,",
    "  options: {",
    "    retries?: { retries?: number; factor?: number; minTimeout?: number; maxTimeout?: number };",
    "    stale?: number;",
    "  },",
    "  fn: () => Promise<T>,",
    "): Promise<T> {",
    "  const retries = options.retries?.retries ?? 3;",
    "  const factor = options.retries?.factor ?? 2;",
    "  const minTimeout = options.retries?.minTimeout ?? 100;",
    "  const maxTimeout = options.retries?.maxTimeout ?? 2000;",
    '  const lockDir = filePath + ".lock";',
    "",
    "  let delay = minTimeout;",
    "  for (let attempt = 0; ; attempt += 1) {",
    "    try {",
    "      fs.mkdirSync(lockDir);",
    "      break;",
    "    } catch (err) {",
    "      if (attempt >= retries) throw err;",
    "      await sleep(delay);",
    "      delay = Math.min(maxTimeout, delay * factor);",
    "    }",
    "  }",
    "",
    "  try {",
    "    return await fn();",
    "  } finally {",
    "    try {",
    "      fs.rmSync(lockDir, { recursive: true, force: true });",
    "    } catch {}",
    "  }",
    "}",
    "",
  ].join("\n");

  if (!source.includes(marker)) {
    throw new Error("pairing marker not found");
  }
  source = source.replace(marker, helper + marker);
}

fs.writeFileSync(targetFile, source);
EOF
}

patch_weixin_plugin() {
  rewrite_weixin_sdk_imports
  patch_process_message_sdk_compat
  patch_send_sdk_compat
  patch_pairing_sdk_compat
}

restart_gateway() {
  compose restart openclaw-gateway >/dev/null
  wait_for_gateway || fail "Gateway 重启超时: ${INSTANCE_NAME}"
}

main() {
  require_cmd docker

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
  [[ -n "${WEIXIN_PLUGIN_PACKAGE:-}" ]] || fail "实例环境缺少 WEIXIN_PLUGIN_PACKAGE"

  ensure_gateway_running
  install_weixin_plugin
  install_weixin_dependencies
  configure_openclaw_json
  patch_weixin_plugin
  restart_gateway

  info "实例 ${INSTANCE_NAME} 已完成微信插件安装/修复"
  info "下面进入微信登录流程。扫描终端里的二维码即可。"
  printf '\n'
  compose exec openclaw-gateway node dist/index.js channels login --channel openclaw-weixin
}

main "$@"
