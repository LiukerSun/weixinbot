#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
STATS_SCRIPT="${SCRIPT_DIR}/openclaw-stats.sh"
INSTANCES_BASE_DIR="${OPENCLAW_INSTANCES_DIR:-/root/openclaw-instances}"
COMMAND="serve"
BASE_DIR="${INSTANCES_BASE_DIR}"
QUOTA_CONFIG_PATH="${OPENCLAW_QUOTA_CONFIG:-}"
BIND_ADDRESS="${OPENCLAW_MONITOR_BIND:-127.0.0.1}"
PORT="${OPENCLAW_MONITOR_PORT:-9469}"
METRICS_PATH="${OPENCLAW_MONITOR_METRICS_PATH:-/metrics}"
CACHE_TTL_MS="${OPENCLAW_MONITOR_CACHE_TTL_MS:-5000}"

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_PATH} serve [--base-dir <instances_dir>] [--quota-config <path>] [--bind <host>] [--port <port>] [--metrics-path <path>] [--cache-ttl-ms <ms>]
  ${SCRIPT_PATH} snapshot [--base-dir <instances_dir>] [--quota-config <path>]

Exports Prometheus metrics derived from openclaw-stats.sh.
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
    serve|snapshot)
      COMMAND="$1"
      ;;
    --base-dir)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --base-dir"
      BASE_DIR="$1"
      ;;
    --quota-config)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --quota-config"
      QUOTA_CONFIG_PATH="$1"
      ;;
    --bind)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --bind"
      BIND_ADDRESS="$1"
      ;;
    --port)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --port"
      PORT="$1"
      ;;
    --metrics-path)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --metrics-path"
      METRICS_PATH="$1"
      ;;
    --cache-ttl-ms)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --cache-ttl-ms"
      CACHE_TTL_MS="$1"
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

[[ -x "$STATS_SCRIPT" ]] || fail "Missing stats script: ${STATS_SCRIPT}"
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "--port must be numeric"
[[ "$CACHE_TTL_MS" =~ ^[0-9]+$ ]] || fail "--cache-ttl-ms must be numeric"
[[ "$METRICS_PATH" == /* ]] || fail "--metrics-path must start with /"

require_cmd node

node - "$COMMAND" "$SCRIPT_PATH" "$STATS_SCRIPT" "$BASE_DIR" "${QUOTA_CONFIG_PATH:-}" "$BIND_ADDRESS" "$PORT" "$METRICS_PATH" "$CACHE_TTL_MS" <<'EOF'
const fs = require("fs");
const http = require("http");
const path = require("path");
const { execFileSync } = require("child_process");

const [
  command,
  scriptPath,
  statsScript,
  baseDir,
  quotaConfigPath,
  bindAddress,
  portRaw,
  metricsPath,
  cacheTtlMsRaw,
] = process.argv.slice(2);

const port = Number(portRaw);
const cacheTtlMs = Number(cacheTtlMsRaw);
const quotaStateFileName = "quota-controller.json";

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function escapeLabelValue(value) {
  return String(value)
    .replace(/\\/g, "\\\\")
    .replace(/\n/g, "\\n")
    .replace(/"/g, '\\"');
}

function metricLine(name, labels, value) {
  if (!labels || Object.keys(labels).length === 0) {
    return `${name} ${value}`;
  }
  const serializedLabels = Object.entries(labels)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, labelValue]) => `${key}="${escapeLabelValue(labelValue)}"`)
    .join(",");
  return `${name}{${serializedLabels}} ${value}`;
}

function registerMetric(definitions, name, type, help) {
  if (definitions.has(name)) {
    return;
  }
  definitions.set(name, { type, help });
}

function appendMetric(lines, definitions, name, type, help, labels, value) {
  registerMetric(definitions, name, type, help);
  lines.push(metricLine(name, labels, value));
}

function loadJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function normalizeWindowName(raw) {
  const value = String(raw || "").trim().toLowerCase();
  switch (value) {
    case "day":
    case "daily":
      return "daily";
    case "month":
    case "monthly":
      return "monthly";
    case "total":
    case "all":
    case "all-time":
    case "all_time":
    case "lifetime":
      return "total";
    default:
      return null;
  }
}

function normalizeLimitValue(value) {
  if (value == null || value === "") {
    return null;
  }
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return null;
  }
  return numeric;
}

function normalizeQuotaConfig(raw) {
  const source = raw && typeof raw === "object" ? raw : {};
  const defaults = source.defaults && typeof source.defaults === "object" ? source.defaults : {};
  const instances = source.instances && typeof source.instances === "object" ? source.instances : {};

  function normalizeEntry(entry) {
    const item = entry && typeof entry === "object" ? entry : {};
    const rawLimits = item.limits && typeof item.limits === "object" ? item.limits : {};
    const limits = {};

    for (const [key, value] of Object.entries(rawLimits)) {
      const windowName = normalizeWindowName(key);
      const numericValue = normalizeLimitValue(value);
      if (windowName && numericValue != null) {
        limits[windowName] = numericValue;
      }
    }

    const stopServices = Array.isArray(item.stopServices)
      ? item.stopServices.filter((service) => typeof service === "string" && service.trim())
      : null;

    return {
      disabled: Boolean(item.disabled),
      limits,
      stopServices,
      resumeWhenWithinLimit:
        item.resumeWhenWithinLimit == null ? null : Boolean(item.resumeWhenWithinLimit),
    };
  }

  const normalized = {
    defaults: normalizeEntry(defaults),
    instances: {},
  };

  for (const [instanceName, value] of Object.entries(instances)) {
    normalized.instances[instanceName] = normalizeEntry(value);
  }

  return normalized;
}

function mergeQuotaPolicy(config, instanceName) {
  const defaults = config.defaults || {};
  const instanceConfig = config.instances?.[instanceName] || {};
  return {
    disabled: instanceConfig.disabled || defaults.disabled || false,
    limits: {
      ...(defaults.limits || {}),
      ...(instanceConfig.limits || {}),
    },
    stopServices:
      instanceConfig.stopServices ||
      defaults.stopServices ||
      ["openclaw-gateway"],
    resumeWhenWithinLimit:
      instanceConfig.resumeWhenWithinLimit != null
        ? instanceConfig.resumeWhenWithinLimit
        : defaults.resumeWhenWithinLimit != null
          ? defaults.resumeWhenWithinLimit
          : true,
  };
}

function formatLocalDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function computeWindowSince(windowName, now) {
  if (windowName === "daily") {
    return formatLocalDate(now);
  }
  if (windowName === "monthly") {
    const value = new Date(now.getTime());
    value.setDate(1);
    return formatLocalDate(value);
  }
  return null;
}

function runStats(extraArgs) {
  const args = ["--json", "--base-dir", baseDir, ...extraArgs];
  const output = execFileSync(statsScript, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return JSON.parse(output);
}

function readQuotaState(instanceDir) {
  return loadJson(path.join(instanceDir, "state", quotaStateFileName));
}

function createLookup(summary) {
  const lookup = new Map();
  for (const instance of summary.instances || []) {
    lookup.set(instance.instance, instance);
  }
  return lookup;
}

function collectQuotaWindows(config) {
  const windows = new Set();

  for (const value of Object.keys(config.defaults?.limits || {})) {
    windows.add(value);
  }

  for (const entry of Object.values(config.instances || {})) {
    for (const value of Object.keys(entry.limits || {})) {
      windows.add(value);
    }
  }

  windows.delete("total");
  return Array.from(windows).sort();
}

function renderMetrics() {
  const startedAt = Date.now();
  const definitions = new Map();
  const lines = [];
  const now = new Date();

  let quotaConfig = normalizeQuotaConfig({});
  if (quotaConfigPath) {
    if (!fs.existsSync(quotaConfigPath)) {
      fail(`Quota config not found: ${quotaConfigPath}`);
    }
    quotaConfig = normalizeQuotaConfig(loadJson(quotaConfigPath));
  }

  const baseSummary = runStats([]);
  const windowSummaries = {
    total: baseSummary,
  };

  for (const windowName of collectQuotaWindows(quotaConfig)) {
    const since = computeWindowSince(windowName, now);
    windowSummaries[windowName] = runStats(since ? ["--since", since] : []);
  }

  const perWindowLookup = Object.fromEntries(
    Object.entries(windowSummaries).map(([windowName, summary]) => [windowName, createLookup(summary)]),
  );

  appendMetric(
    lines,
    definitions,
    "openclaw_monitor_up",
    "gauge",
    "Whether the OpenClaw Prometheus exporter completed its last scrape.",
    {},
    1,
  );
  appendMetric(
    lines,
    definitions,
    "openclaw_monitor_last_scrape_timestamp_seconds",
    "gauge",
    "Unix timestamp of the last successful OpenClaw scrape.",
    {},
    Math.floor(now.getTime() / 1000),
  );
  appendMetric(
    lines,
    definitions,
    "openclaw_instances_total",
    "gauge",
    "Total number of discovered OpenClaw instances.",
    {},
    baseSummary.scannedInstances || 0,
  );
  appendMetric(
    lines,
    definitions,
    "openclaw_session_files_total",
    "gauge",
    "Total number of scanned OpenClaw session files.",
    {},
    baseSummary.scannedSessionFiles || 0,
  );
  appendMetric(
    lines,
    definitions,
    "openclaw_assistant_messages_total",
    "counter",
    "Total assistant messages with usage records.",
    {},
    baseSummary.assistantMessages || 0,
  );

  const globalTotals = baseSummary.totals || {};
  const totalKinds = {
    input: globalTotals.input || 0,
    output: globalTotals.output || 0,
    cache_read: globalTotals.cacheRead || 0,
    cache_write: globalTotals.cacheWrite || 0,
    total: globalTotals.totalTokens || 0,
  };

  for (const [kind, value] of Object.entries(totalKinds)) {
    appendMetric(
      lines,
      definitions,
      "openclaw_tokens_total",
      "counter",
      "Aggregated OpenClaw token usage.",
      { kind },
      value,
    );
  }

  for (const instance of baseSummary.instances || []) {
    const quotaState = readQuotaState(instance.path);
    const gatewayState = String(instance.gatewayState || "missing");
    const labels = {
      configured_primary_model: instance.configuredPrimaryModel || "unknown",
      instance: instance.instance,
    };

    appendMetric(
      lines,
      definitions,
      "openclaw_instance_info",
      "gauge",
      "Static information about an OpenClaw instance.",
      labels,
      1,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_session_files",
      "gauge",
      "Number of scanned session files for an OpenClaw instance.",
      { instance: instance.instance },
      instance.sessionFiles || 0,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_assistant_messages_total",
      "counter",
      "Assistant messages with usage records for an OpenClaw instance.",
      { instance: instance.instance },
      instance.assistantMessages || 0,
    );

    const instanceTotals = instance.totals || {};
    const instanceKinds = {
      input: instanceTotals.input || 0,
      output: instanceTotals.output || 0,
      cache_read: instanceTotals.cacheRead || 0,
      cache_write: instanceTotals.cacheWrite || 0,
      total: instanceTotals.totalTokens || 0,
    };

    for (const [kind, value] of Object.entries(instanceKinds)) {
      appendMetric(
        lines,
        definitions,
        "openclaw_instance_tokens_total",
        "counter",
        "Token usage for an OpenClaw instance.",
        { instance: instance.instance, kind },
        value,
      );
    }

    appendMetric(
      lines,
      definitions,
      "openclaw_instance_containers",
      "gauge",
      "Container counts for an OpenClaw instance.",
      { instance: instance.instance, state: "total" },
      instance.containerStats?.total || 0,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_containers",
      "gauge",
      "Container counts for an OpenClaw instance.",
      { instance: instance.instance, state: "running" },
      instance.containerStats?.running || 0,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_containers",
      "gauge",
      "Container counts for an OpenClaw instance.",
      { instance: instance.instance, state: "exited" },
      instance.containerStats?.exited || 0,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_containers",
      "gauge",
      "Container counts for an OpenClaw instance.",
      { instance: instance.instance, state: "other" },
      instance.containerStats?.other || 0,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_gateway_running",
      "gauge",
      "Whether the openclaw-gateway container is running for an instance.",
      { instance: instance.instance },
      gatewayState === "running" ? 1 : 0,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_gateway_present",
      "gauge",
      "Whether the openclaw-gateway container exists for an instance.",
      { instance: instance.instance },
      gatewayState === "missing" ? 0 : 1,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_instance_quota_paused",
      "gauge",
      "Whether the quota controller marked the instance as paused.",
      { instance: instance.instance },
      quotaState?.paused ? 1 : 0,
    );

    for (const model of instance.models || []) {
      const baseLabels = {
        instance: instance.instance,
        model: model.model || "unknown",
        model_ref: model.modelRef || "unknown/unknown",
        provider: model.provider || "unknown",
      };

      appendMetric(
        lines,
        definitions,
        "openclaw_instance_model_assistant_messages_total",
        "counter",
        "Assistant messages per instance model.",
        baseLabels,
        model.assistantMessages || 0,
      );

      const modelKinds = {
        input: model.totals?.input || 0,
        output: model.totals?.output || 0,
        cache_read: model.totals?.cacheRead || 0,
        cache_write: model.totals?.cacheWrite || 0,
        total: model.totals?.totalTokens || 0,
      };

      for (const [kind, value] of Object.entries(modelKinds)) {
        appendMetric(
          lines,
          definitions,
          "openclaw_instance_model_tokens_total",
          "counter",
          "Token usage per instance model.",
          { ...baseLabels, kind },
          value,
        );
      }
    }

    const quotaPolicy = mergeQuotaPolicy(quotaConfig, instance.instance);
    if (!quotaPolicy.disabled) {
      for (const [windowName, limit] of Object.entries(quotaPolicy.limits || {})) {
        const usageSummary = perWindowLookup[windowName]?.get(instance.instance);
        const usageTokens = usageSummary?.totals?.totalTokens || 0;
        appendMetric(
          lines,
          definitions,
          "openclaw_instance_quota_limit_tokens",
          "gauge",
          "Configured quota limit for an OpenClaw instance.",
          { instance: instance.instance, window: windowName },
          limit,
        );
        appendMetric(
          lines,
          definitions,
          "openclaw_instance_quota_usage_tokens",
          "gauge",
          "Observed token usage for a configured quota window.",
          { instance: instance.instance, window: windowName },
          usageTokens,
        );
        appendMetric(
          lines,
          definitions,
          "openclaw_instance_quota_ratio",
          "gauge",
          "Observed usage divided by configured quota limit.",
          { instance: instance.instance, window: windowName },
          limit > 0 ? usageTokens / limit : 0,
        );
        appendMetric(
          lines,
          definitions,
          "openclaw_instance_quota_exceeded",
          "gauge",
          "Whether a configured quota window is exceeded.",
          { instance: instance.instance, window: windowName },
          usageTokens >= limit ? 1 : 0,
        );
      }
    }
  }

  for (const model of baseSummary.models || []) {
    const baseLabels = {
      model: model.model || "unknown",
      model_ref: model.modelRef || "unknown/unknown",
      provider: model.provider || "unknown",
    };

    appendMetric(
      lines,
      definitions,
      "openclaw_model_instances",
      "gauge",
      "Number of instances that used a given model.",
      baseLabels,
      Array.isArray(model.instances) ? model.instances.length : 0,
    );
    appendMetric(
      lines,
      definitions,
      "openclaw_model_assistant_messages_total",
      "counter",
      "Assistant messages grouped by model.",
      baseLabels,
      model.assistantMessages || 0,
    );

    const modelKinds = {
      input: model.totals?.input || 0,
      output: model.totals?.output || 0,
      cache_read: model.totals?.cacheRead || 0,
      cache_write: model.totals?.cacheWrite || 0,
      total: model.totals?.totalTokens || 0,
    };

    for (const [kind, value] of Object.entries(modelKinds)) {
      appendMetric(
        lines,
        definitions,
        "openclaw_model_tokens_total",
        "counter",
        "Token usage grouped by model.",
        { ...baseLabels, kind },
        value,
      );
    }
  }

  const finishedAt = Date.now();
  appendMetric(
    lines,
    definitions,
    "openclaw_monitor_last_scrape_duration_seconds",
    "gauge",
    "Duration of the last OpenClaw scrape in seconds.",
    {},
    (finishedAt - startedAt) / 1000,
  );

  const header = [];
  for (const [name, definition] of definitions.entries()) {
    header.push(`# HELP ${name} ${definition.help}`);
    header.push(`# TYPE ${name} ${definition.type}`);
  }

  return `${header.concat(lines).join("\n")}\n`;
}

if (command === "snapshot") {
  process.stdout.write(renderMetrics());
  process.exit(0);
}

if (command !== "serve") {
  fail(`Unsupported command: ${command}`);
}

let cache = {
  body: "",
  createdAt: 0,
  error: null,
};

const server = http.createServer((request, response) => {
  if (request.url === "/healthz") {
    response.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("ok\n");
    return;
  }

  if (request.url !== metricsPath) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("not found\n");
    return;
  }

  try {
    const now = Date.now();
    if (!cache.body || now - cache.createdAt > cacheTtlMs) {
      cache = {
        body: renderMetrics(),
        createdAt: now,
        error: null,
      };
    }

    response.writeHead(200, {
      "Content-Type": "text/plain; version=0.0.4; charset=utf-8",
      "Cache-Control": "no-store",
    });
    response.end(cache.body);
  } catch (error) {
    cache.error = error;
    response.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
    response.end(`scrape failed: ${error.message}\n`);
  }
});

server.listen(port, bindAddress, () => {
  console.error(
    `OpenClaw exporter listening on http://${bindAddress}:${port}${metricsPath}`,
  );
});
EOF
