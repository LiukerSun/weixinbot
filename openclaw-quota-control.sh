#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
STATS_SCRIPT="${SCRIPT_DIR}/openclaw-stats.sh"
INSTANCES_BASE_DIR="${OPENCLAW_INSTANCES_DIR:-/root/openclaw-instances}"
CONFIG_PATH_DEFAULT="${OPENCLAW_QUOTA_CONFIG:-${INSTANCES_BASE_DIR}/quota-config.json}"
COMMAND="check"
BASE_DIR="${INSTANCES_BASE_DIR}"
CONFIG_PATH="${CONFIG_PATH_DEFAULT}"
INTERVAL_SECONDS="${OPENCLAW_QUOTA_INTERVAL_SECONDS:-60}"
INSTANCE_FILTER=""
DRY_RUN=0

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_PATH} check --config <path> [--base-dir <instances_dir>] [--instance <instance_name>] [--dry-run]
  ${SCRIPT_PATH} daemon --config <path> [--base-dir <instances_dir>] [--interval-seconds <n>] [--instance <instance_name>] [--dry-run]

Checks token quotas and stops OpenClaw services when limits are exceeded.
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
    check|daemon)
      COMMAND="$1"
      ;;
    --config)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --config"
      CONFIG_PATH="$1"
      ;;
    --base-dir)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --base-dir"
      BASE_DIR="$1"
      ;;
    --interval-seconds)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --interval-seconds"
      INTERVAL_SECONDS="$1"
      ;;
    --instance)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --instance"
      INSTANCE_FILTER="$1"
      ;;
    --dry-run)
      DRY_RUN=1
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
[[ -n "$CONFIG_PATH" ]] || fail "Missing --config"
[[ -f "$CONFIG_PATH" ]] || fail "Quota config not found: ${CONFIG_PATH}"
[[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || fail "--interval-seconds must be numeric"

require_cmd node

node - "$COMMAND" "$SCRIPT_PATH" "$STATS_SCRIPT" "$BASE_DIR" "$CONFIG_PATH" "$INTERVAL_SECONDS" "$INSTANCE_FILTER" "$DRY_RUN" <<'EOF'
const fs = require("fs");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");

const [
  command,
  scriptPath,
  statsScript,
  baseDir,
  configPath,
  intervalSecondsRaw,
  instanceFilter,
  dryRunRaw,
] = process.argv.slice(2);

const intervalSeconds = Number(intervalSecondsRaw);
const dryRun = dryRunRaw === "1";
const quotaStateFileName = "quota-controller.json";

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function log(message) {
  process.stdout.write(`${new Date().toISOString()} ${message}\n`);
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

function normalizeDateValue(value) {
  return typeof value === "string" ? value.trim() : "";
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
      validFrom: normalizeDateValue(item.validFrom),
      validUntil: normalizeDateValue(item.validUntil),
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
  const validity = instanceConfig.validFrom || instanceConfig.validUntil
    ? buildQuotaValidity(instanceConfig.validFrom, instanceConfig.validUntil, new Date())
    : buildQuotaValidity(defaults.validFrom, defaults.validUntil, new Date());
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
    validity,
  };
}

function formatLocalDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function parseQuotaDate(raw) {
  const value = String(raw || "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return null;
  }
  const [year, month, day] = value.split("-").map((part) => Number(part));
  const parsed = new Date(year, month - 1, day);
  if (
    Number.isNaN(parsed.getTime()) ||
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month - 1 ||
    parsed.getDate() !== day
  ) {
    return null;
  }
  parsed.setHours(0, 0, 0, 0);
  return parsed;
}

function truncateToDay(date) {
  const value = new Date(date.getTime());
  value.setHours(0, 0, 0, 0);
  return value;
}

function addDays(date, days) {
  const value = truncateToDay(date);
  value.setDate(value.getDate() + days);
  return value;
}

function addMonthsClamped(date, months) {
  const source = truncateToDay(date);
  const totalMonths = source.getFullYear() * 12 + source.getMonth() + months;
  const year = Math.floor(totalMonths / 12);
  const monthIndex = ((totalMonths % 12) + 12) % 12;
  const lastDay = new Date(year, monthIndex + 1, 0).getDate();
  const day = Math.min(source.getDate(), lastDay);
  return new Date(year, monthIndex, day);
}

function exactDurationMonths(startDate, endDate) {
  for (let months = 1; months <= 240; months += 1) {
    const expectedEnd = addMonthsClamped(startDate, months);
    if (expectedEnd.getTime() === endDate.getTime()) {
      return months;
    }
    if (expectedEnd.getTime() > endDate.getTime()) {
      break;
    }
  }
  return null;
}

function currentQuotaPeriod(startDate, endDate, now) {
  const today = truncateToDay(now);
  let currentStart = truncateToDay(startDate);
  for (let months = 1; months <= 240; months += 1) {
    const nextStart = addMonthsClamped(startDate, months);
    if (nextStart.getTime() > today.getTime() || nextStart.getTime() >= endDate.getTime()) {
      break;
    }
    currentStart = nextStart;
  }
  let currentEnd = addMonthsClamped(currentStart, 1);
  if (currentEnd.getTime() > endDate.getTime()) {
    currentEnd = truncateToDay(endDate);
  }
  return { currentStart, currentEnd };
}

function buildQuotaValidity(validFrom, validUntil, now) {
  const result = {
    startDate: normalizeDateValue(validFrom),
    endDate: normalizeDateValue(validUntil),
    durationMonths: 0,
    status: "none",
    active: true,
    currentPeriodStart: "",
    currentPeriodEnd: "",
  };
  if (!result.startDate && !result.endDate) {
    return result;
  }
  if (!result.startDate || !result.endDate) {
    result.status = "invalid";
    result.active = false;
    return result;
  }

  const startDate = parseQuotaDate(result.startDate);
  const endDate = parseQuotaDate(result.endDate);
  if (!startDate || !endDate) {
    result.status = "invalid";
    result.active = false;
    return result;
  }

  if (endDate.getTime() <= startDate.getTime()) {
    result.status = "invalid";
    result.active = false;
    return result;
  }
  const durationMonths = exactDurationMonths(startDate, endDate);
  result.durationMonths = durationMonths || 0;

  const today = truncateToDay(now);
  if (today.getTime() < startDate.getTime()) {
    result.status = "upcoming";
    result.active = false;
    return result;
  }
  if (today.getTime() >= endDate.getTime()) {
    result.status = "expired";
    result.active = false;
    return result;
  }

  const period = currentQuotaPeriod(startDate, endDate, today);
  result.status = "active";
  result.active = true;
  result.currentPeriodStart = formatLocalDate(period.currentStart);
  result.currentPeriodEnd = formatLocalDate(period.currentEnd);
  return result;
}

function maxDate(...values) {
  return values.filter(Boolean).reduce((latest, value) => {
    if (!latest || value.getTime() > latest.getTime()) {
      return value;
    }
    return latest;
  }, null);
}

function usageSinceForWindow(windowName, quotaPolicy, now) {
  const validFrom = quotaPolicy.validity.startDate
    ? parseQuotaDate(quotaPolicy.validity.startDate)
    : null;

  if (windowName === "daily") {
    return maxDate(truncateToDay(now), validFrom);
  }
  if (windowName === "monthly") {
    const periodStart = quotaPolicy.validity.currentPeriodStart
      ? parseQuotaDate(quotaPolicy.validity.currentPeriodStart)
      : null;
    if (periodStart) {
      return periodStart;
    }
    const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
    return maxDate(monthStart, validFrom);
  }
  if (windowName === "total") {
    return validFrom;
  }
  return null;
}

function runStats(extraArgs, requestedInstance = instanceFilter) {
  const args = ["--json", "--base-dir", baseDir, ...extraArgs];
  if (requestedInstance) {
    args.push("--instance", requestedInstance);
  }

  const output = execFileSync(statsScript, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return JSON.parse(output);
}

function readUsageTokens(instanceName, windowName, quotaPolicy, now) {
  const since = usageSinceForWindow(windowName, quotaPolicy, now);
  const args = [];
  if (since) {
    args.push("--since", formatLocalDate(since));
  }
  const summary = runStats(args, instanceName);
  return summary.instances?.[0]?.totals?.totalTokens || 0;
}

function detectComposeCommand() {
  const dockerCompose = spawnSync("docker-compose", ["version"], {
    stdio: "ignore",
  });
  if (dockerCompose.status === 0) {
    return { bin: "docker-compose", prefix: [] };
  }

  const dockerComposePlugin = spawnSync("docker", ["compose", "version"], {
    stdio: "ignore",
  });
  if (dockerComposePlugin.status === 0) {
    return { bin: "docker", prefix: ["compose"] };
  }

  fail("docker-compose or docker compose is required for quota control");
}

function runCompose(composeCommand, composeFile, args) {
  const result = spawnSync(
    composeCommand.bin,
    [...composeCommand.prefix, "-f", composeFile, ...args],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  if (result.status !== 0) {
    const stderr = String(result.stderr || "").trim();
    const stdout = String(result.stdout || "").trim();
    fail(stderr || stdout || `Compose command failed for ${composeFile}`);
  }
}

function readQuotaState(instanceDir) {
  return loadJson(path.join(instanceDir, "state", quotaStateFileName));
}

function writeQuotaState(instanceDir, data) {
  const stateDir = path.join(instanceDir, "state");
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(
    path.join(stateDir, quotaStateFileName),
    `${JSON.stringify(data, null, 2)}\n`,
  );
}

function evaluateOnce() {
  const quotaConfig = normalizeQuotaConfig(loadJson(configPath));
  let composeCommand = null;
  const now = new Date();
  const totalSummary = runStats([]);
  const instances = totalSummary.instances || [];
  if (instances.length === 0) {
    log(`No OpenClaw instances found under ${baseDir}.`);
    return;
  }

  for (const instance of instances) {
    const quotaPolicy = mergeQuotaPolicy(quotaConfig, instance.instance);
    const hasLimits = Object.keys(quotaPolicy.limits).length > 0;
    const hasValidity = quotaPolicy.validity.status !== "none";
    if (quotaPolicy.disabled || (!hasLimits && !hasValidity)) {
      continue;
    }

    const state = readQuotaState(instance.path);
    const composeFile = path.join(instance.path, "docker-compose.yml");
    const stopServices = quotaPolicy.stopServices.length > 0
      ? quotaPolicy.stopServices
      : ["openclaw-gateway"];

    if (!quotaPolicy.validity.active) {
      const reasonText = `validity:${quotaPolicy.validity.status}`;

      if (!state?.paused) {
        if (dryRun) {
          log(`instance=${instance.instance} action=would-stop services=${stopServices.join(",")} reason=${reasonText}`);
        } else {
          composeCommand = composeCommand || detectComposeCommand();
          runCompose(composeCommand, composeFile, ["stop", ...stopServices]);
          log(`instance=${instance.instance} action=stopped services=${stopServices.join(",")} reason=${reasonText}`);
        }
      } else {
        log(`instance=${instance.instance} action=already-paused reason=${reasonText}`);
      }

      if (!dryRun) {
        writeQuotaState(instance.path, {
          instance: instance.instance,
          paused: true,
          updatedAt: now.toISOString(),
          pausedAt: state?.paused ? state.pausedAt || now.toISOString() : now.toISOString(),
          pauseReason: quotaPolicy.validity.status,
          resumeWhenWithinLimit: quotaPolicy.resumeWhenWithinLimit,
          stopServices,
          exceededWindows: [],
        });
      }

      continue;
    }

    const exceededWindows = [];
    for (const [windowName, limitTokens] of Object.entries(quotaPolicy.limits)) {
      const usageTokens = readUsageTokens(instance.instance, windowName, quotaPolicy, now);
      if (usageTokens >= limitTokens) {
        exceededWindows.push({
          window: windowName,
          usageTokens,
          limitTokens,
        });
      }
    }

    if (exceededWindows.length > 0) {
      const reasonText = exceededWindows
        .map((item) => `${item.window}:${item.usageTokens}/${item.limitTokens}`)
        .join(",");

      if (!state?.paused) {
        if (dryRun) {
          log(`instance=${instance.instance} action=would-stop services=${stopServices.join(",")} reason=${reasonText}`);
        } else {
          composeCommand = composeCommand || detectComposeCommand();
          runCompose(composeCommand, composeFile, ["stop", ...stopServices]);
          log(`instance=${instance.instance} action=stopped services=${stopServices.join(",")} reason=${reasonText}`);
        }
      } else {
        log(`instance=${instance.instance} action=already-paused reason=${reasonText}`);
      }

      if (!dryRun) {
        writeQuotaState(instance.path, {
          instance: instance.instance,
          paused: true,
          updatedAt: now.toISOString(),
          pausedAt: state?.paused ? state.pausedAt || now.toISOString() : now.toISOString(),
          pauseReason: "limit-exceeded",
          resumeWhenWithinLimit: quotaPolicy.resumeWhenWithinLimit,
          stopServices,
          exceededWindows,
        });
      }

      continue;
    }

    if (state?.paused && quotaPolicy.resumeWhenWithinLimit) {
      if (dryRun) {
        log(`instance=${instance.instance} action=would-resume services=${(state.stopServices || stopServices).join(",")}`);
      } else {
        composeCommand = composeCommand || detectComposeCommand();
        runCompose(composeCommand, composeFile, ["up", "-d", ...(state.stopServices || stopServices)]);
        log(`instance=${instance.instance} action=resumed services=${(state.stopServices || stopServices).join(",")}`);
        writeQuotaState(instance.path, {
          instance: instance.instance,
          paused: false,
          updatedAt: now.toISOString(),
          pausedAt: state.pausedAt || null,
          resumedAt: now.toISOString(),
          pauseReason: "",
          resumeWhenWithinLimit: quotaPolicy.resumeWhenWithinLimit,
          stopServices: state.stopServices || stopServices,
          exceededWindows: [],
        });
      }
      continue;
    }

    if (!dryRun && state) {
      writeQuotaState(instance.path, {
        instance: instance.instance,
        paused: false,
        updatedAt: now.toISOString(),
        pausedAt: state.pausedAt || null,
        resumedAt: state.resumedAt || null,
        pauseReason: "",
        resumeWhenWithinLimit: quotaPolicy.resumeWhenWithinLimit,
        stopServices: state.stopServices || stopServices,
        exceededWindows: [],
      });
    }
  }
}

if (command === "check") {
  evaluateOnce();
  process.exit(0);
}

if (command !== "daemon") {
  fail(`Unsupported command: ${command}`);
}

evaluateOnce();
setInterval(evaluateOnce, intervalSeconds * 1000);
EOF
