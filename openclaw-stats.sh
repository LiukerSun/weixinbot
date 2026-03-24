#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
INSTANCES_BASE_DIR="${OPENCLAW_INSTANCES_DIR:-/root/openclaw-instances}"
INSTANCE_FILTER=""
OUTPUT_FORMAT="table"
SINCE_VALUE=""
UNTIL_VALUE=""

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_PATH}
  ${SCRIPT_PATH} --instance <instance_name>
  ${SCRIPT_PATH} --base-dir <instances_dir>
  ${SCRIPT_PATH} --since <YYYY-MM-DD|ISO8601>
  ${SCRIPT_PATH} --until <YYYY-MM-DD|ISO8601>
  ${SCRIPT_PATH} --json

Scans OpenClaw instance state directories and summarizes model usage plus token totals
from state/**/*.jsonl* records.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --instance"
      INSTANCE_FILTER="$1"
      ;;
    --base-dir)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --base-dir"
      INSTANCES_BASE_DIR="$1"
      ;;
    --since)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --since"
      SINCE_VALUE="$1"
      ;;
    --until)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --until"
      UNTIL_VALUE="$1"
      ;;
    --json)
      OUTPUT_FORMAT="json"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

require_cmd node

node - "$INSTANCES_BASE_DIR" "$INSTANCE_FILTER" "$OUTPUT_FORMAT" "$SINCE_VALUE" "$UNTIL_VALUE" <<'EOF'
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const [
  baseDir,
  instanceFilter,
  outputFormat,
  sinceValue,
  untilValue,
] = process.argv.slice(2);

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function parseDateBoundary(raw, isEnd) {
  if (!raw) {
    return null;
  }

  const hasExplicitTime = /T|\d{2}:\d{2}/.test(raw);
  const value = hasExplicitTime
    ? new Date(raw)
    : new Date(`${raw}T${isEnd ? "23:59:59.999" : "00:00:00.000"}`);

  if (Number.isNaN(value.getTime())) {
    fail(`Invalid ${isEnd ? "--until" : "--since"} value: ${raw}`);
  }

  return value.getTime();
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function parseEnvFile(filePath) {
  const env = {};

  if (!fs.existsSync(filePath)) {
    return env;
  }

  for (const rawLine of fs.readFileSync(filePath, "utf8").split(/\r?\n/)) {
    if (!rawLine || /^\s*#/.test(rawLine)) {
      continue;
    }
    const separatorIndex = rawLine.indexOf("=");
    if (separatorIndex === -1) {
      continue;
    }
    const key = rawLine.slice(0, separatorIndex).trim();
    env[key] = rawLine.slice(separatorIndex + 1);
  }

  return env;
}

function toModelRef(provider, model) {
  const safeProvider = provider || "unknown";
  const safeModel = model || "unknown";
  return `${safeProvider}/${safeModel}`;
}

function normalizeUsage(usage) {
  const input = Number(usage?.input || 0);
  const output = Number(usage?.output || 0);
  const cacheRead = Number(usage?.cacheRead || 0);
  const cacheWrite = Number(usage?.cacheWrite || 0);
  const totalTokens = Number(
    usage?.totalTokens != null
      ? usage.totalTokens
      : input + output + cacheRead + cacheWrite
  );

  return { input, output, cacheRead, cacheWrite, totalTokens };
}

function addUsage(target, usage) {
  target.input += usage.input;
  target.output += usage.output;
  target.cacheRead += usage.cacheRead;
  target.cacheWrite += usage.cacheWrite;
  target.totalTokens += usage.totalTokens;
}

function createUsageBucket() {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
  };
}

function createContainerBucket() {
  return {
    total: 0,
    running: 0,
    exited: 0,
    other: 0,
  };
}

function formatNumber(value) {
  return new Intl.NumberFormat("en-US").format(value);
}

function pad(value, width, align = "left") {
  const text = String(value);
  if (text.length >= width) {
    return text;
  }
  const filler = " ".repeat(width - text.length);
  return align === "right" ? `${filler}${text}` : `${text}${filler}`;
}

function makeTable(headers, rows) {
  const widths = headers.map((header, index) =>
    Math.max(
      header.label.length,
      ...rows.map((row) => String(row[index]).length),
    ),
  );

  const headerLine = headers
    .map((header, index) => pad(header.label, widths[index], header.align))
    .join("  ");
  const separatorLine = headers
    .map((header, index) =>
      header.align === "right"
        ? "-".repeat(widths[index])
        : "-".repeat(widths[index]),
    )
    .join("  ");
  const body = rows.map((row) =>
    row.map((cell, index) => pad(cell, widths[index], headers[index].align)).join("  "),
  );

  return [headerLine, separatorLine, ...body].join("\n");
}

function listInstanceDirs(rootDir) {
  if (!fs.existsSync(rootDir)) {
    return [];
  }

  return fs
    .readdirSync(rootDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(rootDir, entry.name))
    .filter((instanceDir) => fs.existsSync(path.join(instanceDir, "docker-compose.yml")))
    .sort((a, b) => a.localeCompare(b));
}

function walkJsonlFiles(rootDir, files) {
  for (const entry of fs.readdirSync(rootDir, { withFileTypes: true })) {
    const fullPath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      walkJsonlFiles(fullPath, files);
      continue;
    }
    if (!entry.isFile()) {
      continue;
    }
    if (/\.jsonl(?:\.(?:reset|deleted)\..+)?$/.test(entry.name)) {
      files.push(fullPath);
    }
  }
}

function listSessionFiles(instanceStateDir) {
  if (!fs.existsSync(instanceStateDir)) {
    return [];
  }

  const files = [];
  walkJsonlFiles(instanceStateDir, files);
  return files.sort((a, b) => a.localeCompare(b));
}

function detectDocker() {
  try {
    execFileSync("docker", ["version", "--format", "{{.Server.Version}}"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return { available: true, source: "docker", error: null };
  } catch (error) {
    return {
      available: false,
      source: "filesystem",
      error: error && error.code === "ENOENT" ? "docker command not found" : "docker daemon unavailable",
    };
  }
}

function readComposeContainers(projectName) {
  try {
    const output = execFileSync(
      "docker",
      [
        "ps",
        "-a",
        "--filter",
        `label=com.docker.compose.project=${projectName}`,
        "--format",
        "{{json .}}",
      ],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      },
    );

    return output
      .split(/\r?\n/)
      .filter((line) => line.trim())
      .map((line) => {
        try {
          const item = JSON.parse(line);
          return {
            id: item.ID || "",
            name: item.Names || "",
            service: item.Labels
              ?.split(",")
              .map((entry) => entry.split("="))
              .find(([key]) => key === "com.docker.compose.service")?.[1] || "unknown",
            state: String(item.State || "unknown").toLowerCase(),
            status: item.Status || "",
          };
        } catch {
          return null;
        }
      })
      .filter(Boolean)
      .sort((a, b) => a.name.localeCompare(b.name));
  } catch {
    return [];
  }
}

function summarizeContainers(containers) {
  const totals = createContainerBucket();

  for (const container of containers) {
    totals.total += 1;
    if (container.state === "running") {
      totals.running += 1;
      continue;
    }
    if (["exited", "dead", "created", "removing"].includes(container.state)) {
      totals.exited += 1;
      continue;
    }
    totals.other += 1;
  }

  return totals;
}

function getGatewayState(containers) {
  const gateway = containers.find((container) => container.service === "openclaw-gateway");
  return gateway ? gateway.state : "missing";
}

const sinceTs = parseDateBoundary(sinceValue, false);
const untilTs = parseDateBoundary(untilValue, true);

if (sinceTs != null && untilTs != null && sinceTs > untilTs) {
  fail("--since cannot be later than --until");
}

const instanceDirs = listInstanceDirs(baseDir).filter((instanceDir) =>
  instanceFilter ? path.basename(instanceDir) === instanceFilter : true,
);

if (instanceFilter && instanceDirs.length === 0) {
  fail(`Instance not found: ${instanceFilter}`);
}

const summary = {
  baseDir,
  filters: {
    instance: instanceFilter || null,
    since: sinceValue || null,
    until: untilValue || null,
  },
  containerDiscovery: detectDocker(),
  scannedInstances: 0,
  scannedSessionFiles: 0,
  assistantMessages: 0,
  totals: createUsageBucket(),
  containers: createContainerBucket(),
  instances: [],
  models: [],
};

const globalModelMap = new Map();

for (const instanceDir of instanceDirs) {
  const instanceName = path.basename(instanceDir);
  const stateDir = path.join(instanceDir, "state");
  const openclawConfigPath = path.join(stateDir, "openclaw.json");
  const envPath = path.join(instanceDir, ".env");
  const env = parseEnvFile(envPath);
  const config = readJson(openclawConfigPath);
  const configuredPrimaryModel =
    config?.agents?.defaults?.model?.primary ||
    (env.OPENCLAW_PRIMARY_MODEL_PROVIDER === "openai"
      ? `openai/${env.OPENAI_MODEL || "gpt-5.4"}`
      : "zai/glm-5-turbo");
  const containers = summary.containerDiscovery.available
    ? readComposeContainers(instanceName)
    : [];
  const containerStats = summarizeContainers(containers);

  const instanceSummary = {
    instance: instanceName,
    path: instanceDir,
    configuredPrimaryModel,
    recentModel: null,
    containerStats,
    gatewayState: getGatewayState(containers),
    containers,
    sessionFiles: 0,
    assistantMessages: 0,
    totals: createUsageBucket(),
    models: [],
  };
  const instanceModelMap = new Map();
  let recentModel = null;
  let recentModelTs = null;

  for (const sessionFile of listSessionFiles(stateDir)) {
    instanceSummary.sessionFiles += 1;
    summary.scannedSessionFiles += 1;

    let lastProvider = null;
    let lastModel = null;
    const content = fs.readFileSync(sessionFile, "utf8");
    for (const line of content.split(/\r?\n/)) {
      if (!line.trim()) {
        continue;
      }

      let entry;
      try {
        entry = JSON.parse(line);
      } catch {
        continue;
      }

      if (entry.type === "model_change") {
        lastProvider = entry.provider || lastProvider;
        lastModel = entry.modelId || lastModel;
        continue;
      }

      if (
        entry.type === "custom" &&
        entry.customType === "model-snapshot" &&
        entry.data
      ) {
        lastProvider = entry.data.provider || lastProvider;
        lastModel = entry.data.modelId || lastModel;
        continue;
      }

      if (entry.type !== "message" || entry.message?.role !== "assistant") {
        continue;
      }

      const messageTimestamp = Date.parse(entry.timestamp || entry.message?.timestamp || "");
      if ((sinceTs != null || untilTs != null) && !Number.isFinite(messageTimestamp)) {
        continue;
      }
      if (sinceTs != null && messageTimestamp < sinceTs) {
        continue;
      }
      if (untilTs != null && messageTimestamp > untilTs) {
        continue;
      }

      const provider = entry.message?.provider || lastProvider;
      const model = entry.message?.model || lastModel;
      const modelRef = toModelRef(provider, model);
      if (
        Number.isFinite(messageTimestamp) &&
        (recentModelTs == null || messageTimestamp > recentModelTs)
      ) {
        recentModelTs = messageTimestamp;
        recentModel = {
          provider: provider || "unknown",
          model: model || "unknown",
          modelRef,
          timestamp: new Date(messageTimestamp).toISOString(),
        };
      }

      const usage = normalizeUsage(entry.message?.usage);
      if (usage.totalTokens <= 0) {
        continue;
      }

      instanceSummary.assistantMessages += 1;
      summary.assistantMessages += 1;
      addUsage(instanceSummary.totals, usage);
      addUsage(summary.totals, usage);

      if (!instanceModelMap.has(modelRef)) {
        instanceModelMap.set(modelRef, {
          provider: provider || "unknown",
          model: model || "unknown",
          modelRef,
          assistantMessages: 0,
          totals: createUsageBucket(),
        });
      }

      const instanceModelSummary = instanceModelMap.get(modelRef);
      instanceModelSummary.assistantMessages += 1;
      addUsage(instanceModelSummary.totals, usage);

      if (!globalModelMap.has(modelRef)) {
        globalModelMap.set(modelRef, {
          provider: provider || "unknown",
          model: model || "unknown",
          modelRef,
          assistantMessages: 0,
          totals: createUsageBucket(),
          instances: new Set(),
        });
      }

      const globalModelSummary = globalModelMap.get(modelRef);
      globalModelSummary.assistantMessages += 1;
      addUsage(globalModelSummary.totals, usage);
      globalModelSummary.instances.add(instanceName);
    }
  }

  instanceSummary.recentModel = recentModel;
  instanceSummary.models = Array.from(instanceModelMap.values())
    .sort((a, b) => b.totals.totalTokens - a.totals.totalTokens || a.modelRef.localeCompare(b.modelRef));
  if (summary.containerDiscovery.available) {
    summary.containers.total += instanceSummary.containerStats.total;
    summary.containers.running += instanceSummary.containerStats.running;
    summary.containers.exited += instanceSummary.containerStats.exited;
    summary.containers.other += instanceSummary.containerStats.other;
  }
  summary.instances.push(instanceSummary);
}

summary.scannedInstances = summary.instances.length;
summary.models = Array.from(globalModelMap.values())
  .map((item) => ({
    provider: item.provider,
    model: item.model,
    modelRef: item.modelRef,
    instances: Array.from(item.instances).sort(),
    assistantMessages: item.assistantMessages,
    totals: item.totals,
  }))
  .sort((a, b) => b.totals.totalTokens - a.totals.totalTokens || a.modelRef.localeCompare(b.modelRef));
summary.instances.sort((a, b) => b.totals.totalTokens - a.totals.totalTokens || a.instance.localeCompare(b.instance));

if (outputFormat === "json") {
  console.log(JSON.stringify(summary, null, 2));
  process.exit(0);
}

if (summary.scannedInstances === 0) {
  console.log(`No OpenClaw instances found under ${baseDir}`);
  process.exit(0);
}

console.log("OpenClaw usage summary");
console.log(`Base dir: ${summary.baseDir}`);
console.log(`Instances: ${summary.scannedInstances}`);
if (summary.containerDiscovery.available) {
  console.log(
    `Containers: total=${formatNumber(summary.containers.total)}, running=${formatNumber(summary.containers.running)}, exited=${formatNumber(summary.containers.exited)}, other=${formatNumber(summary.containers.other)}`,
  );
} else {
  console.log(`Containers: unavailable (${summary.containerDiscovery.error})`);
}
console.log(`Session files: ${summary.scannedSessionFiles}`);
console.log(`Assistant messages: ${formatNumber(summary.assistantMessages)}`);
if (summary.filters.since || summary.filters.until) {
  console.log(
    `Time filter: ${summary.filters.since || "-infinity"} .. ${summary.filters.until || "+infinity"}`,
  );
}
console.log(
  `Tokens: input=${formatNumber(summary.totals.input)}, output=${formatNumber(summary.totals.output)}, cacheRead=${formatNumber(summary.totals.cacheRead)}, cacheWrite=${formatNumber(summary.totals.cacheWrite)}, total=${formatNumber(summary.totals.totalTokens)}`,
);
console.log("");

const instanceRows = summary.instances.map((item) => [
  item.instance,
  item.configuredPrimaryModel,
  `${formatNumber(item.containerStats.running)}/${formatNumber(item.containerStats.total)}`,
  item.gatewayState,
  formatNumber(item.sessionFiles),
  formatNumber(item.assistantMessages),
  formatNumber(item.totals.input),
  formatNumber(item.totals.output),
  formatNumber(item.totals.cacheRead),
  formatNumber(item.totals.cacheWrite),
  formatNumber(item.totals.totalTokens),
]);

console.log("By instance");
console.log(
  makeTable(
    [
      { label: "INSTANCE", align: "left" },
      { label: "CONFIGURED_MODEL", align: "left" },
      { label: "RUN/TOTAL", align: "right" },
      { label: "GATEWAY", align: "left" },
      { label: "FILES", align: "right" },
      { label: "MSGS", align: "right" },
      { label: "INPUT", align: "right" },
      { label: "OUTPUT", align: "right" },
      { label: "CACHE_READ", align: "right" },
      { label: "CACHE_WRITE", align: "right" },
      { label: "TOTAL", align: "right" },
    ],
    instanceRows,
  ),
);

console.log("");
console.log("By model");
console.log(
  makeTable(
    [
      { label: "MODEL", align: "left" },
      { label: "INSTANCES", align: "right" },
      { label: "MSGS", align: "right" },
      { label: "INPUT", align: "right" },
      { label: "OUTPUT", align: "right" },
      { label: "CACHE_READ", align: "right" },
      { label: "CACHE_WRITE", align: "right" },
      { label: "TOTAL", align: "right" },
    ],
    summary.models.map((item) => [
      item.modelRef,
      formatNumber(item.instances.length),
      formatNumber(item.assistantMessages),
      formatNumber(item.totals.input),
      formatNumber(item.totals.output),
      formatNumber(item.totals.cacheRead),
      formatNumber(item.totals.cacheWrite),
      formatNumber(item.totals.totalTokens),
    ]),
  ),
);
EOF
