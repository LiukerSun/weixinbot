import { useEffect, useMemo, useState } from "react";
import QRCode from "qrcode";

const emptyCreateForm = {
  name: "",
  gatewayPort: "auto",
  bridgePort: "auto",
  withWeixin: true,
  autoOpenWeixinQr: true,
  primaryModelProvider: "openai",
  zaiApiKey: "",
  zaiModel: "glm-5-turbo",
  openaiApiKey: "",
  openaiBaseUrl: "",
  openaiModel: "gpt-5.4",
  braveApiKey: "",
  quotaDaily: "",
  quotaMonthly: "",
  quotaTotal: "",
  quotaValidFrom: "",
  quotaValidUntil: "",
};

const emptyQuotaForm = {
  mode: "add",
  daily: "",
  monthly: "",
  total: "",
  disabled: false,
  resumeWhenWithinLimit: true,
  validFrom: "",
  validUntil: "",
};

const logTailOptions = [100, 300, 1000, 3000];
const conversationPageSize = 80;

function mergeWeixinQrViewer(response, current = null) {
  return {
    instance: response.instance,
    active: Boolean(response.active),
    connected: Boolean(response.connected),
    status: response.status || "idle",
    message: response.message || "",
    qrUrl: response.qrUrl || "",
    output: response.output || "",
    startedAt: response.startedAt || "",
    updatedAt: response.updatedAt || "",
    finishedAt: response.finishedAt || "",
    loading: false,
    error: "",
    justStarted: current?.justStarted || false,
  };
}

async function requestJSON(path, options = {}) {
  const response = await fetch(path, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    ...options,
  });

  const text = await response.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }

  if (!response.ok) {
    throw new Error(data?.error || text || `request failed: ${response.status}`);
  }

  return data;
}

function formatNumber(value) {
  return new Intl.NumberFormat("en-US").format(Number(value || 0));
}

function formatRatio(value) {
  if (value == null || Number.isNaN(Number(value))) {
    return "-";
  }
  return `${(Number(value) * 100).toFixed(1)}%`;
}

function formatBytes(value) {
  const size = Number(value || 0);
  if (!Number.isFinite(size) || size <= 0) {
    return "0 B";
  }
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  let current = size;
  while (current >= 1024 && index < units.length - 1) {
    current /= 1024;
    index += 1;
  }
  return `${current.toFixed(current >= 10 || index === 0 ? 0 : 1)} ${units[index]}`;
}

function quotaValue(value) {
  if (value === "" || value == null) {
    return undefined;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return undefined;
  }
  return parsed;
}

function normalizeDateInput(value) {
  return String(value || "").trim();
}

function parseDateInput(value) {
  const text = normalizeDateInput(value);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) {
    return null;
  }
  const [year, month, day] = text.split("-").map(Number);
  const parsed = new Date(year, month - 1, day);
  if (
    Number.isNaN(parsed.getTime()) ||
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month - 1 ||
    parsed.getDate() !== day
  ) {
    return null;
  }
  return parsed;
}

function addDays(date, days) {
  const value = new Date(date.getTime());
  value.setDate(value.getDate() + days);
  return value;
}

function addMonthsClamped(date, months) {
  const totalMonths = date.getFullYear() * 12 + date.getMonth() + months;
  const year = Math.floor(totalMonths / 12);
  const monthIndex = ((totalMonths % 12) + 12) % 12;
  const lastDay = new Date(year, monthIndex + 1, 0).getDate();
  const day = Math.min(date.getDate(), lastDay);
  return new Date(year, monthIndex, day);
}

function durationMonthsFromRange(startValue, endValue) {
  const startDate = parseDateInput(startValue);
  const endDate = parseDateInput(endValue);
  if (!startDate || !endDate) {
    return null;
  }
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

function validateValidityRange(startValue, endValue) {
  const validFrom = normalizeDateInput(startValue);
  const validUntil = normalizeDateInput(endValue);
  if (!validFrom && !validUntil) {
    return "";
  }
  if (!validFrom || !validUntil) {
    return "开始日期和截止日期必须一起填写";
  }
  if (!parseDateInput(validFrom) || !parseDateInput(validUntil)) {
    return "有效期日期格式无效";
  }
  if (parseDateInput(validUntil).getTime() <= parseDateInput(validFrom).getTime()) {
    return "截止日期必须晚于开始日期";
  }
  return "";
}

function formatValidityTitle(validity) {
  if (!validity?.startDate || !validity?.endDate) {
    return "长期有效";
  }
  return `${validity.startDate} 至 ${validity.endDate}`;
}

function formatValiditySubtitle(validity) {
  if (!validity?.startDate || !validity?.endDate) {
    return "未设置开始/截止日期";
  }
  const months = validity.durationMonths ? `${validity.durationMonths} 个月` : "自定义区间";
  if (validity.status === "active" && validity.currentPeriodStart && validity.currentPeriodEnd) {
    return `${months} · 当前周期 ${validity.currentPeriodStart} -> ${validity.currentPeriodEnd} 重置`;
  }
  if (validity.status === "upcoming") {
    return `${months} · 尚未生效`;
  }
  if (validity.status === "expired") {
    return `${months} · 已到期`;
  }
  if (validity.status === "invalid") {
    return "有效期配置无效";
  }
  return months;
}

function buildQuotaPayload(form) {
  return {
    mode: form.mode,
    daily: quotaValue(form.daily),
    monthly: quotaValue(form.monthly),
    total: quotaValue(form.total),
    disabled: form.disabled,
    resumeWhenWithinLimit: form.resumeWhenWithinLimit,
    validFrom: normalizeDateInput(form.validFrom),
    validUntil: normalizeDateInput(form.validUntil),
  };
}

function conversationStatusTone(session) {
  if (session.current) {
    return "good";
  }
  if (session.status === "deleted") {
    return "danger";
  }
  if (session.status === "reset") {
    return "warn";
  }
  return "muted";
}

function conversationStatusLabel(session) {
  if (session.current) {
    return "current";
  }
  if (session.status === "deleted") {
    return "deleted";
  }
  if (session.status === "reset") {
    return "reset";
  }
  return "active";
}

function conversationRoleTone(role) {
  if (role === "assistant") {
    return "good";
  }
  if (role === "user") {
    return "warn";
  }
  if (role === "toolResult") {
    return "muted";
  }
  return "danger";
}

function conversationRoleLabel(role) {
  if (role === "assistant") {
    return "assistant";
  }
  if (role === "user") {
    return "user";
  }
  if (role === "toolResult") {
    return "tool";
  }
  return role || "message";
}

export default function App() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [selectedInstance, setSelectedInstance] = useState(null);
  const [createModalOpen, setCreateModalOpen] = useState(false);
  const [quotaForm, setQuotaForm] = useState(emptyQuotaForm);
  const [createForm, setCreateForm] = useState(emptyCreateForm);
  const [busyAction, setBusyAction] = useState("");
  const [notice, setNotice] = useState("");
  const [logViewer, setLogViewer] = useState(null);
  const [conversationViewer, setConversationViewer] = useState(null);
  const [weixinQrViewer, setWeixinQrViewer] = useState(null);
  const [weixinQrImage, setWeixinQrImage] = useState("");

  async function loadInstances() {
    setLoading(true);
    setError("");
    try {
      const response = await requestJSON("/api/instances");
      setData(response);
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadInstances();
  }, []);

  const filteredInstances = useMemo(() => {
    const items = data?.instances || [];
    const keyword = search.trim().toLowerCase();
    if (!keyword) {
      return items;
    }
    return items.filter((item) => {
      return [
        item.stats.instance,
        item.stats.configuredPrimaryModel,
        item.recentModel?.modelRef,
        item.stats.gatewayState,
      ]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(keyword));
    });
  }, [data, search]);

  async function runInstanceAction(instanceName, action) {
    setBusyAction(`${instanceName}:${action}`);
    setNotice("");
    setError("");
    try {
      await requestJSON(`/api/instances/${instanceName}/${action}`, {
        method: "POST",
        body: "{}",
      });
      setNotice(`${instanceName} ${action} 已执行`);
      await loadInstances();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyAction("");
    }
  }

  async function archiveInstance(instance) {
    const instanceName = instance.stats.instance;
    const confirmed = window.confirm(
      `确认归档并删除 ${instanceName} 吗？\n\n系统会先停止并删除该实例的所有容器，然后压缩实例目录，最后删除实例文件，但会保留压缩包备份。`,
    );
    if (!confirmed) {
      return;
    }

    setBusyAction(`${instanceName}:archive`);
    setNotice("");
    setError("");
    try {
      await requestJSON(`/api/instances/${instanceName}/archive`, {
        method: "POST",
        body: "{}",
      });
      closeQuotaEditor();
      setNotice(`${instanceName} 已归档，备份压缩包已保留`);
      await loadInstances();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyAction("");
    }
  }

  async function restoreArchive(archive) {
    const confirmed = window.confirm(
      `确认从备份 ${archive.archiveFile} 恢复实例 ${archive.instance} 吗？\n\n系统会解压备份并重新启动该实例容器。`,
    );
    if (!confirmed) {
      return;
    }

    setBusyAction(`archive:${archive.id}:restore`);
    setNotice("");
    setError("");
    try {
      await requestJSON(`/api/archives/${archive.id}/restore`, {
        method: "POST",
        body: "{}",
      });
      setNotice(`${archive.instance} 已从备份恢复`);
      await loadInstances();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyAction("");
    }
  }

  async function loadLogs(instanceName, options = {}) {
    const service = options.service || logViewer?.service || "openclaw-gateway";
    const tail = Number(options.tail || logViewer?.tail || 300);

    setLogViewer((prev) => ({
      instance: instanceName,
      service,
      tail,
      services: prev?.instance === instanceName ? (prev.services || []) : [],
      content: prev?.instance === instanceName && prev.service === service ? prev.content : "",
      generatedAt: prev?.instance === instanceName ? prev.generatedAt : "",
      loading: true,
      error: "",
    }));

    try {
      const params = new URLSearchParams({
        service,
        tail: String(tail),
      });
      const response = await requestJSON(`/api/instances/${instanceName}/logs?${params.toString()}`);
      setLogViewer({
        instance: response.instance,
        service: response.service,
        tail: response.tail,
        services: response.services || [],
        content: response.content || "",
        generatedAt: response.generatedAt || "",
        loading: false,
        error: "",
      });
    } catch (requestError) {
      setLogViewer((prev) => ({
        instance: instanceName,
        service,
        tail,
        services: prev?.services || [],
        content: prev?.content || "",
        generatedAt: prev?.generatedAt || "",
        loading: false,
        error: requestError.message,
      }));
    }
  }

  function openLogViewer(instance) {
    loadLogs(instance.stats.instance, { service: "openclaw-gateway", tail: 300 });
  }

  function closeLogViewer() {
    setLogViewer(null);
  }

  async function loadConversationDetail(
    instanceName,
    conversationId,
    options = {},
    sessionsOverride = null,
  ) {
    const offset =
      options.offset != null ? Number(options.offset) : conversationViewer?.offset;
    const limit =
      options.limit != null ? Number(options.limit) : conversationViewer?.limit || conversationPageSize;

    setConversationViewer((prev) => ({
      ...(prev || {
        instance: instanceName,
        sessions: [],
        generatedAt: "",
        loading: false,
        error: "",
      }),
      instance: instanceName,
      sessions: sessionsOverride || prev?.sessions || [],
      selectedId: conversationId,
      offset: Number.isFinite(offset) ? offset : prev?.offset || 0,
      limit: Number.isFinite(limit) ? limit : prev?.limit || conversationPageSize,
      detailLoading: true,
      detailError: "",
    }));

    try {
      const params = new URLSearchParams();
      if (Number.isFinite(offset)) {
        params.set("offset", String(offset));
      }
      if (Number.isFinite(limit)) {
        params.set("limit", String(limit));
      }
      const response = await requestJSON(
        `/api/instances/${instanceName}/conversations/${encodeURIComponent(conversationId)}${
          params.size ? `?${params.toString()}` : ""
        }`,
      );
      setConversationViewer((prev) => ({
        ...(prev || {}),
        instance: response.instance,
        sessions: sessionsOverride || prev?.sessions || [],
        selectedId: conversationId,
        conversation: response.conversation || null,
        messages: response.messages || [],
        detailGeneratedAt: response.generatedAt || "",
        offset: Number(response.offset || 0),
        limit: Number(response.limit || conversationPageSize),
        totalMessages: Number(response.totalMessages || 0),
        hasOlder: Boolean(response.hasOlder),
        hasNewer: Boolean(response.hasNewer),
        loading: false,
        detailLoading: false,
        detailError: "",
      }));
    } catch (requestError) {
      setConversationViewer((prev) => ({
        ...(prev || {}),
        instance: instanceName,
        sessions: sessionsOverride || prev?.sessions || [],
        selectedId: conversationId,
        offset: Number.isFinite(offset) ? offset : prev?.offset || 0,
        limit: Number.isFinite(limit) ? limit : prev?.limit || conversationPageSize,
        loading: false,
        detailLoading: false,
        detailError: requestError.message,
      }));
    }
  }

  async function openConversationViewer(instanceName) {
    setConversationViewer({
      instance: instanceName,
      sessions: [],
      generatedAt: "",
      detailGeneratedAt: "",
      selectedId: "",
      conversation: null,
      messages: [],
      offset: 0,
      limit: conversationPageSize,
      totalMessages: 0,
      hasOlder: false,
      hasNewer: false,
      loading: true,
      detailLoading: false,
      error: "",
      detailError: "",
    });

    try {
      const response = await requestJSON(`/api/instances/${instanceName}/conversations`);
      const sessions = response.sessions || [];
      const selectedId = sessions[0]?.id || "";
      setConversationViewer({
        instance: response.instance,
        sessions,
        generatedAt: response.generatedAt || "",
        detailGeneratedAt: "",
        selectedId,
        conversation: null,
        messages: [],
        offset: 0,
        limit: conversationPageSize,
        totalMessages: 0,
        hasOlder: false,
        hasNewer: false,
        loading: false,
        detailLoading: Boolean(selectedId),
        error: "",
        detailError: "",
      });
      if (selectedId) {
        await loadConversationDetail(
          response.instance,
          selectedId,
          { limit: conversationPageSize },
          sessions,
        );
      }
    } catch (requestError) {
      setConversationViewer({
        instance: instanceName,
        sessions: [],
        generatedAt: "",
        detailGeneratedAt: "",
        selectedId: "",
        conversation: null,
        messages: [],
        offset: 0,
        limit: conversationPageSize,
        totalMessages: 0,
        hasOlder: false,
        hasNewer: false,
        loading: false,
        detailLoading: false,
        error: requestError.message,
        detailError: "",
      });
    }
  }

  function closeConversationViewer() {
    setConversationViewer(null);
  }

  async function loadWeixinQrStatus(instanceName) {
    try {
      const response = await requestJSON(`/api/instances/${instanceName}/weixin-qr`);
      setWeixinQrViewer((prev) => {
        if (!prev || prev.instance !== instanceName) {
          return prev;
        }
        return {
          ...mergeWeixinQrViewer(response, prev),
          justStarted: false,
        };
      });
    } catch (requestError) {
      setWeixinQrViewer((prev) => {
        if (!prev || prev.instance !== instanceName) {
          return prev;
        }
        return {
          ...prev,
          loading: false,
          error: requestError.message,
        };
      });
    }
  }

  async function startWeixinQr(instanceName, force = false) {
    setWeixinQrViewer((prev) => ({
      instance: instanceName,
      active: prev?.instance === instanceName ? prev.active : false,
      connected: prev?.instance === instanceName ? prev.connected : false,
      status:
        prev?.instance === instanceName && prev.status && prev.status !== "creating"
          ? prev.status
          : "starting",
      message:
        prev?.instance === instanceName && prev.status && prev.status !== "creating"
          ? prev.message
          : "正在生成微信二维码...",
      qrUrl: prev?.instance === instanceName ? prev.qrUrl : "",
      output: prev?.instance === instanceName ? prev.output : "",
      startedAt: prev?.instance === instanceName ? prev.startedAt : "",
      updatedAt: prev?.instance === instanceName ? prev.updatedAt : "",
      finishedAt: prev?.instance === instanceName ? prev.finishedAt : "",
      loading: true,
      error: "",
      justStarted: true,
    }));

    try {
      const response = await requestJSON(`/api/instances/${instanceName}/weixin-qr/start`, {
        method: "POST",
        body: JSON.stringify({ force }),
      });
      setWeixinQrViewer((prev) => ({
        ...mergeWeixinQrViewer(response, prev),
        justStarted: false,
      }));
    } catch (requestError) {
      setWeixinQrViewer((prev) => ({
        ...(prev || { instance: instanceName }),
        loading: false,
        error: requestError.message,
      }));
    }
  }

  function openWeixinQrViewer(instanceName, force = false) {
    startWeixinQr(instanceName, force);
  }

  function closeWeixinQrViewer() {
    const instanceName = weixinQrViewer?.instance;
    setWeixinQrViewer(null);
    if (instanceName) {
      requestJSON(`/api/instances/${instanceName}/weixin-qr/stop`, {
        method: "POST",
        body: "{}",
      }).catch(() => {});
    }
  }

  function openQuotaEditor(instance) {
    setSelectedInstance(instance);
    setQuotaForm({
      mode: "add",
      daily: "",
      monthly: "",
      total: "",
      disabled: instance.quota.disabled,
      resumeWhenWithinLimit: instance.quota.resumeWhenWithinLimit,
      validFrom: instance.quota.validity?.startDate || "",
      validUntil: instance.quota.validity?.endDate || "",
    });
  }

  function closeQuotaEditor() {
    setSelectedInstance(null);
    setQuotaForm(emptyQuotaForm);
  }

  function openCreateModal() {
    setCreateModalOpen(true);
  }

  function closeCreateModal() {
    setCreateModalOpen(false);
    setCreateForm(emptyCreateForm);
  }

  async function submitQuota(event) {
    event.preventDefault();
    if (!selectedInstance) {
      return;
    }

    setBusyAction(`${selectedInstance.stats.instance}:quota`);
    setNotice("");
    setError("");
    try {
      const validityError = validateValidityRange(quotaForm.validFrom, quotaForm.validUntil);
      if (validityError) {
        throw new Error(validityError);
      }
      await requestJSON(`/api/instances/${selectedInstance.stats.instance}/quota`, {
        method: "POST",
        body: JSON.stringify(buildQuotaPayload(quotaForm)),
      });
      setNotice(`${selectedInstance.stats.instance} 的额度已更新`);
      closeQuotaEditor();
      await loadInstances();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyAction("");
    }
  }

  async function submitCreateInstance(event) {
    event.preventDefault();
    const instanceName = createForm.name.trim();
    const shouldOpenWeixinQr = Boolean(createForm.withWeixin && createForm.autoOpenWeixinQr);
    const quotaPayload = buildQuotaPayload({
      mode: "set",
      daily: createForm.quotaDaily,
      monthly: createForm.quotaMonthly,
      total: createForm.quotaTotal,
      disabled: false,
      resumeWhenWithinLimit: true,
      validFrom: createForm.quotaValidFrom,
      validUntil: createForm.quotaValidUntil,
    });
    const validityError = validateValidityRange(createForm.quotaValidFrom, createForm.quotaValidUntil);
    if (validityError) {
      setError(validityError);
      return;
    }

    const payload = {
      name: instanceName,
      gatewayPort: createForm.gatewayPort,
      bridgePort: createForm.bridgePort,
      withWeixin: createForm.withWeixin,
      skipWeixinLogin: true,
      primaryModelProvider: createForm.primaryModelProvider,
      zaiApiKey: createForm.zaiApiKey,
      zaiModel: createForm.zaiModel,
      openaiApiKey: createForm.openaiApiKey,
      openaiBaseUrl: createForm.openaiBaseUrl,
      openaiModel: createForm.openaiModel,
      braveApiKey: createForm.braveApiKey,
      quota:
        quotaPayload.daily != null ||
        quotaPayload.monthly != null ||
        quotaPayload.total != null ||
        quotaPayload.validFrom ||
        quotaPayload.validUntil
          ? quotaPayload
          : undefined,
    };

    setBusyAction("create-instance");
    setNotice("");
    setError("");
    closeCreateModal();
    if (shouldOpenWeixinQr) {
      setWeixinQrViewer({
        instance: instanceName,
        active: false,
        connected: false,
        status: "creating",
        message: "正在创建实例并准备微信对接...",
        qrUrl: "",
        output: "",
        startedAt: "",
        updatedAt: "",
        finishedAt: "",
        loading: true,
        error: "",
        justStarted: true,
      });
    }

    try {
      const created = await requestJSON("/api/instances", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      setNotice("新实例已创建");
      await loadInstances();
      if (shouldOpenWeixinQr) {
        await startWeixinQr(created?.stats?.instance || instanceName, true);
      }
    } catch (requestError) {
      setError(requestError.message);
      if (shouldOpenWeixinQr) {
        setWeixinQrViewer((prev) => ({
          ...(prev || { instance: instanceName }),
          active: false,
          connected: false,
          status: "error",
          message: "实例创建失败",
          loading: false,
          error: requestError.message,
          justStarted: false,
        }));
      }
    } finally {
      setBusyAction("");
    }
  }

  useEffect(() => {
    if (!weixinQrViewer?.instance || weixinQrViewer.status === "creating") {
      return undefined;
    }

    const timer = window.setInterval(() => {
      loadWeixinQrStatus(weixinQrViewer.instance);
    }, 3000);

    return () => window.clearInterval(timer);
  }, [weixinQrViewer?.instance]);

  useEffect(() => {
    let cancelled = false;

    if (!weixinQrViewer?.qrUrl) {
      setWeixinQrImage("");
      return undefined;
    }

    QRCode.toDataURL(weixinQrViewer.qrUrl, {
      width: 360,
      margin: 1,
      errorCorrectionLevel: "M",
    })
      .then((value) => {
        if (!cancelled) {
          setWeixinQrImage(value);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setWeixinQrImage("");
        }
      });

    return () => {
      cancelled = true;
    };
  }, [weixinQrViewer?.qrUrl]);

  const totals = data?.totals || {};
  const archives = data?.archives || [];
  const activeCount =
    filteredInstances.filter((item) => item.stats.gatewayState === "running").length;
  const pausedCount =
    filteredInstances.filter((item) => item.quotaState?.paused).length;

  return (
    <div className="app-shell">
      <header className="hero">
        <div>
          <p className="eyebrow">OpenClaw Control Room</p>
          <h1>用户实例管理后台</h1>
          <p className="hero-copy">
            查看每个用户实例的 token 用量，直接调整额度，暂停、恢复、重启容器，并在同一界面创建新实例。
          </p>
        </div>

        <div className="hero-actions">
          <button onClick={openCreateModal}>创建实例</button>
          <button className="ghost-button" onClick={loadInstances} disabled={loading}>
            {loading ? "刷新中..." : "刷新数据"}
          </button>
          <div className="quota-file">Quota: {data?.quotaConfigPath || "-"}</div>
        </div>
      </header>

      <section className="summary-grid">
        <SummaryCard label="实例数" value={formatNumber(data?.scannedInstances || 0)} accent="sun" />
        <SummaryCard label="运行中" value={formatNumber(activeCount)} accent="mint" />
        <SummaryCard label="已暂停" value={formatNumber(pausedCount)} accent="rose" />
        <SummaryCard label="总 Tokens" value={formatNumber(totals.totalTokens)} accent="ink" />
      </section>

      <section className="layout-grid single-layout">
        <div className="panel panel-wide">
          <div className="panel-header">
            <div>
              <p className="panel-kicker">Usage Matrix</p>
              <h2>用户实例用量</h2>
            </div>
            <div className="panel-tools">
              <input
                className="search-input"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索实例 / 模型 / 状态"
              />
              <button className="ghost-button" onClick={openCreateModal}>
                新建实例
              </button>
            </div>
          </div>

          {error ? <div className="banner error">{error}</div> : null}
          {notice ? <div className="banner success">{notice}</div> : null}

          <div className="table-wrap">
            <table className="instance-table">
              <thead>
                <tr>
                  <th>实例</th>
                  <th>配置主模型</th>
                  <th>总用量</th>
                  <th>日额度</th>
                  <th>月额度</th>
                  <th>有效期</th>
                  <th>网关</th>
                  <th>状态</th>
                  <th>操作</th>
                </tr>
              </thead>
              <tbody>
                {filteredInstances.map((instance) => {
                  const name = instance.stats.instance;
                  const isBusy = busyAction.startsWith(`${name}:`);
                  const dailyUsage = instance.quotaUsage.daily;
                  const monthlyUsage = instance.quotaUsage.monthly;
                  return (
                    <tr key={name}>
                      <td>
                        <div className="cell-title">{name}</div>
                        <div className="cell-subtitle">
                          消息 {formatNumber(instance.stats.assistantMessages)} / 文件 {formatNumber(instance.stats.sessionFiles)}
                        </div>
                      </td>
                      <td>
                        <div className="cell-title">{instance.stats.configuredPrimaryModel}</div>
                        <div className="cell-subtitle">
                          最近使用模型 {instance.recentModel?.modelRef || "-"}
                        </div>
                      </td>
                      <td>
                        <div className="cell-title">{formatNumber(instance.stats.totals.totalTokens)}</div>
                        <div className="cell-subtitle">
                          I {formatNumber(instance.stats.totals.input)} / O {formatNumber(instance.stats.totals.output)}
                        </div>
                      </td>
                      <td>
                        <div className="cell-title">{formatNumber(instance.quota.limits.daily || 0)}</div>
                        <div className="cell-subtitle">
                          已用 {formatNumber(dailyUsage || 0)} / {formatRatio(instance.quotaRatio.daily)}
                        </div>
                      </td>
                      <td>
                        <div className="cell-title">{formatNumber(instance.quota.limits.monthly || 0)}</div>
                        <div className="cell-subtitle">
                          已用 {formatNumber(monthlyUsage || 0)} / {formatRatio(instance.quotaRatio.monthly)}
                        </div>
                      </td>
                      <td>
                        <div className="cell-title">{formatValidityTitle(instance.quota.validity)}</div>
                        <div className="cell-subtitle">
                          {formatValiditySubtitle(instance.quota.validity)}
                        </div>
                      </td>
                      <td>
                        <div className="log-cell">
                          <StatusBadge
                            tone={instance.stats.gatewayState === "running" ? "good" : "warn"}
                            text={instance.stats.gatewayState}
                          />
                          <div className="gateway-action-links">
                            <button
                              type="button"
                              className="ghost-button log-link-button"
                              onClick={() => openLogViewer(instance)}
                            >
                              查看日志
                            </button>
                            <button
                              type="button"
                              className="ghost-button log-link-button"
                              onClick={() => openConversationViewer(instance.stats.instance)}
                            >
                              查看对话
                            </button>
                            <button
                              type="button"
                              className="ghost-button log-link-button"
                              onClick={() => openWeixinQrViewer(instance.stats.instance, true)}
                            >
                              微信二维码
                            </button>
                          </div>
                        </div>
                      </td>
                      <td>
                        {instance.quotaState?.paused && instance.quota.validity?.status === "upcoming" ? (
                          <StatusBadge tone="warn" text="awaiting start" />
                        ) : instance.quotaState?.paused && instance.quota.validity?.status === "expired" ? (
                          <StatusBadge tone="danger" text="expired" />
                        ) : instance.quotaState?.paused && instance.quota.validity?.status === "invalid" ? (
                          <StatusBadge tone="danger" text="invalid validity" />
                        ) : instance.quotaState?.paused ? (
                          <StatusBadge tone="danger" text="quota paused" />
                        ) : instance.quota.disabled ? (
                          <StatusBadge tone="muted" text="quota off" />
                        ) : instance.quota.validity?.status === "upcoming" ? (
                          <StatusBadge tone="warn" text="awaiting start" />
                        ) : instance.quota.validity?.status === "expired" ? (
                          <StatusBadge tone="danger" text="expired" />
                        ) : instance.quota.validity?.status === "invalid" ? (
                          <StatusBadge tone="danger" text="invalid validity" />
                        ) : instance.quotaExceeded.daily || instance.quotaExceeded.monthly || instance.quotaExceeded.total ? (
                          <StatusBadge tone="warn" text="limit hit" />
                        ) : (
                          <StatusBadge tone="good" text="normal" />
                        )}
                      </td>
                      <td>
                        <div className="action-row">
                          <button disabled={isBusy} onClick={() => openQuotaEditor(instance)}>
                            编辑
                          </button>
                          <button disabled={isBusy} onClick={() => runInstanceAction(name, "pause")}>
                            暂停
                          </button>
                          <button disabled={isBusy} onClick={() => runInstanceAction(name, "resume")}>
                            恢复
                          </button>
                          <button disabled={isBusy} onClick={() => runInstanceAction(name, "restart")}>
                            重启
                          </button>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section className="panel archive-panel">
        <div className="panel-header">
          <div>
            <p className="panel-kicker">Archives</p>
            <h2>备份归档</h2>
          </div>
          <div className="quota-file">Archives: {data?.archivesDir || "-"}</div>
        </div>

        <div className="table-wrap">
          <table className="instance-table">
            <thead>
              <tr>
                <th>实例</th>
                <th>压缩包</th>
                <th>归档时间</th>
                <th>大小</th>
                <th>路径</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {archives.length === 0 ? (
                <tr>
                  <td colSpan="6">
                    <div className="empty-state">当前还没有归档备份。</div>
                  </td>
                </tr>
              ) : (
                archives.map((archive) => {
                  const isBusy = busyAction === `archive:${archive.id}:restore`;
                  return (
                    <tr key={archive.id}>
                      <td>
                        <div className="cell-title">{archive.instance}</div>
                      </td>
                      <td>
                        <div className="cell-title">{archive.archiveFile}</div>
                      </td>
                      <td>
                        <div className="cell-title">{archive.archivedAt || "-"}</div>
                      </td>
                      <td>
                        <div className="cell-title">{formatBytes(archive.sizeBytes)}</div>
                      </td>
                      <td>
                        <div className="cell-subtitle archive-path">{archive.archivePath}</div>
                      </td>
                      <td>
                        <div className="action-row archive-actions">
                          <button
                            disabled={isBusy || !archive.restorable}
                            onClick={() => restoreArchive(archive)}
                          >
                            恢复
                          </button>
                        </div>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedInstance ? (
        <ModalShell
          title={`编辑额度 · ${selectedInstance.stats.instance}`}
          kicker="Quota Editor"
          onClose={closeQuotaEditor}
        >
          <form className="stack-form" onSubmit={submitQuota}>
            <div className="selected-instance">
              <div className="cell-title">{selectedInstance.stats.instance}</div>
              <div className="cell-subtitle">
                当前日额度 {formatNumber(selectedInstance.quota.limits.daily || 0)}，月额度 {formatNumber(selectedInstance.quota.limits.monthly || 0)}
              </div>
              <div className="cell-subtitle">
                {formatValidityTitle(selectedInstance.quota.validity)} · {formatValiditySubtitle(selectedInstance.quota.validity)}
              </div>
            </div>

            <label>
              <span>更新方式</span>
              <select
                value={quotaForm.mode}
                onChange={(event) => setQuotaForm((prev) => ({ ...prev, mode: event.target.value }))}
              >
                <option value="add">增加额度</option>
                <option value="set">直接设置</option>
              </select>
            </label>

            <div className="three-columns">
              <label>
                <span>日额度</span>
                <input
                  value={quotaForm.daily}
                  onChange={(event) => setQuotaForm((prev) => ({ ...prev, daily: event.target.value }))}
                  placeholder="例如 50000"
                />
              </label>
              <label>
                <span>月额度</span>
                <input
                  value={quotaForm.monthly}
                  onChange={(event) => setQuotaForm((prev) => ({ ...prev, monthly: event.target.value }))}
                  placeholder="例如 1000000"
                />
              </label>
              <label>
                <span>历史总额度</span>
                <input
                  value={quotaForm.total}
                  onChange={(event) => setQuotaForm((prev) => ({ ...prev, total: event.target.value }))}
                  placeholder="可选"
                />
              </label>
            </div>

            <div className="two-columns">
              <label>
                <span>开始日期</span>
                <input
                  type="date"
                  value={quotaForm.validFrom}
                  onChange={(event) => setQuotaForm((prev) => ({ ...prev, validFrom: event.target.value }))}
                />
              </label>
              <label>
                <span>截止日期</span>
                <input
                  type="date"
                  value={quotaForm.validUntil}
                  onChange={(event) => setQuotaForm((prev) => ({ ...prev, validUntil: event.target.value }))}
                />
              </label>
            </div>
            <div className="field-note">
              按开始日期滚动重置月额度。例如 2026-01-02 开始，则 2026-02-02 重置。开始和截止日期现在可以自由设置，只要求截止日期晚于开始日期。
            </div>

            <div className="two-columns">
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={quotaForm.disabled}
                  onChange={(event) => setQuotaForm((prev) => ({ ...prev, disabled: event.target.checked }))}
                />
                <span>禁用该实例的限额</span>
              </label>

              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={quotaForm.resumeWhenWithinLimit}
                  onChange={(event) =>
                    setQuotaForm((prev) => ({
                      ...prev,
                      resumeWhenWithinLimit: event.target.checked,
                    }))
                  }
                />
                <span>窗口恢复后自动恢复容器</span>
              </label>
            </div>

            <div className="form-actions">
              <button type="submit" disabled={busyAction.endsWith(":quota")}>
                保存额度
              </button>
              <button type="button" className="ghost-button" onClick={closeQuotaEditor}>
                取消
              </button>
            </div>

            <div className="danger-zone">
              <div>
                <div className="cell-title">归档删除</div>
                <div className="cell-subtitle">
                  会停止并删除该实例所有容器，压缩实例目录后再删除原始文件，压缩包会保留在归档列表中。
                </div>
              </div>
              <button
                type="button"
                className="danger-button"
                disabled={busyAction === `${selectedInstance.stats.instance}:archive`}
                onClick={() => archiveInstance(selectedInstance)}
              >
                归档并删除
              </button>
            </div>
          </form>
        </ModalShell>
      ) : null}

      {createModalOpen ? (
        <ModalShell
          title="创建用户实例"
          kicker="Provisioning"
          onClose={closeCreateModal}
          wide
        >
          <form className="stack-form" onSubmit={submitCreateInstance}>
            <label>
              <span>实例名</span>
              <input
                required
                value={createForm.name}
                onChange={(event) => setCreateForm((prev) => ({ ...prev, name: event.target.value }))}
                placeholder="例如 user_zhangsan"
              />
            </label>

            <div className="two-columns">
              <label>
                <span>Gateway 端口</span>
                <input
                  value={createForm.gatewayPort}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, gatewayPort: event.target.value }))}
                />
              </label>
              <label>
                <span>Bridge 端口</span>
                <input
                  value={createForm.bridgePort}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, bridgePort: event.target.value }))}
                />
              </label>
            </div>

            <label>
              <span>主模型提供方</span>
              <select
                value={createForm.primaryModelProvider}
                onChange={(event) =>
                  setCreateForm((prev) => ({ ...prev, primaryModelProvider: event.target.value }))
                }
              >
                <option value="openai">openai</option>
                <option value="zai">zai</option>
              </select>
            </label>

            {createForm.primaryModelProvider === "openai" ? (
              <>
                <div className="two-columns">
                  <label>
                    <span>OpenAI 模型</span>
                    <input
                      value={createForm.openaiModel}
                      onChange={(event) => setCreateForm((prev) => ({ ...prev, openaiModel: event.target.value }))}
                    />
                  </label>
                  <label>
                    <span>OpenAI API Key</span>
                    <input
                      value={createForm.openaiApiKey}
                      onChange={(event) => setCreateForm((prev) => ({ ...prev, openaiApiKey: event.target.value }))}
                    />
                  </label>
                </div>

                <label>
                  <span>OpenAI Base URL</span>
                  <input
                    value={createForm.openaiBaseUrl}
                    onChange={(event) => setCreateForm((prev) => ({ ...prev, openaiBaseUrl: event.target.value }))}
                  />
                </label>
              </>
            ) : (
              <div className="two-columns">
                <label>
                  <span>ZAI 模型</span>
                  <input
                    value={createForm.zaiModel}
                    onChange={(event) => setCreateForm((prev) => ({ ...prev, zaiModel: event.target.value }))}
                  />
                </label>
                <label>
                  <span>ZAI API Key</span>
                  <input
                    value={createForm.zaiApiKey}
                    onChange={(event) => setCreateForm((prev) => ({ ...prev, zaiApiKey: event.target.value }))}
                  />
                </label>
              </div>
            )}

            <label>
              <span>BraveSearch API Key</span>
              <input
                value={createForm.braveApiKey}
                onChange={(event) => setCreateForm((prev) => ({ ...prev, braveApiKey: event.target.value }))}
                placeholder="可选"
              />
            </label>

            <div className="three-columns">
              <label>
                <span>初始日额度</span>
                <input
                  value={createForm.quotaDaily}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, quotaDaily: event.target.value }))}
                />
              </label>
              <label>
                <span>初始月额度</span>
                <input
                  value={createForm.quotaMonthly}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, quotaMonthly: event.target.value }))}
                />
              </label>
              <label>
                <span>历史总额度</span>
                <input
                  value={createForm.quotaTotal}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, quotaTotal: event.target.value }))}
                />
              </label>
            </div>

            <div className="two-columns">
              <label>
                <span>开始日期</span>
                <input
                  type="date"
                  value={createForm.quotaValidFrom}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, quotaValidFrom: event.target.value }))}
                />
              </label>
              <label>
                <span>截止日期</span>
                <input
                  type="date"
                  value={createForm.quotaValidUntil}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, quotaValidUntil: event.target.value }))}
                />
              </label>
            </div>
            <div className="field-note">
              月额度会按开始日期滚动重置。比如开始日期是 1 月 2 日，就会在 2 月 2 日进入下一个月度周期。
            </div>

            <div className="two-columns">
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={createForm.withWeixin}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, withWeixin: event.target.checked }))}
                />
                <span>安装 openclaw-weixin</span>
              </label>

              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={createForm.autoOpenWeixinQr}
                  onChange={(event) =>
                    setCreateForm((prev) => ({ ...prev, autoOpenWeixinQr: event.target.checked }))
                  }
                />
                <span>创建完成后立即展示微信二维码</span>
              </label>
            </div>

            <div className="field-note">
              为了避免创建流程卡住，后台会先完成容器创建，再单独拉起微信登录弹窗并持续刷新最新二维码。
            </div>

            <div className="form-actions">
              <button type="submit" disabled={busyAction === "create-instance"}>
                创建实例
              </button>
              <button type="button" className="ghost-button" onClick={closeCreateModal}>
                取消
              </button>
            </div>
          </form>
        </ModalShell>
      ) : null}

      {conversationViewer ? (
        <ModalShell
          title={`对话历史 · ${conversationViewer.instance}`}
          kicker="Conversations"
          onClose={closeConversationViewer}
          xwide
          scrollLock
        >
          <div className="conversation-toolbar">
            <div className="selected-instance conversation-summary-card">
              <div className="cell-title">{conversationViewer.instance}</div>
              <div className="cell-subtitle">
                会话 {formatNumber(conversationViewer.sessions?.length || 0)} · 列表更新时间 {conversationViewer.generatedAt || "-"}
              </div>
            </div>

            <div className="log-toolbar-actions">
              <button
                type="button"
                className="ghost-button"
                onClick={() => openConversationViewer(conversationViewer.instance)}
                disabled={conversationViewer.loading || conversationViewer.detailLoading}
              >
                {conversationViewer.loading ? "刷新中..." : "刷新会话"}
              </button>
            </div>
          </div>

          {conversationViewer.error ? <div className="banner error">{conversationViewer.error}</div> : null}

          <div className="conversation-layout">
            <aside className="conversation-sidebar">
              {conversationViewer.loading ? (
                <div className="empty-state">正在加载会话列表...</div>
              ) : conversationViewer.sessions?.length ? (
                conversationViewer.sessions.map((session) => (
                  <button
                    type="button"
                    key={session.id}
                    className={`conversation-session-card${
                      conversationViewer.selectedId === session.id ? " is-selected" : ""
                    }`}
                    onClick={() =>
                      loadConversationDetail(
                        conversationViewer.instance,
                        session.id,
                        { limit: conversationPageSize },
                      )
                    }
                    disabled={conversationViewer.detailLoading && conversationViewer.selectedId === session.id}
                  >
                    <div className="conversation-session-top">
                      <div className="cell-title conversation-session-title">
                        {session.current ? "当前会话" : session.fileName}
                      </div>
                      <StatusBadge
                        tone={conversationStatusTone(session)}
                        text={conversationStatusLabel(session)}
                      />
                    </div>
                    <div className="cell-subtitle">{session.preview || "暂无预览"}</div>
                    <div className="conversation-session-meta">
                      <span>{session.originLabel || session.chatType || session.sessionKey || "-"}</span>
                      <span>{session.updatedAt || session.lastMessageAt || session.createdAt || "-"}</span>
                    </div>
                    <div className="conversation-session-meta">
                      <span>
                        U {formatNumber(session.userMessages)} / A {formatNumber(session.assistantMessages)}
                      </span>
                      <span>{session.recentModel?.modelRef || "-"}</span>
                    </div>
                  </button>
                ))
              ) : (
                <div className="empty-state">这个实例还没有找到会话历史。</div>
              )}
            </aside>

            <section className="conversation-main">
              {conversationViewer.detailError ? (
                <div className="banner error">{conversationViewer.detailError}</div>
              ) : null}

              {conversationViewer.conversation ? (
                <>
                  <div className="conversation-detail-card">
                    <div className="conversation-detail-header">
                      <div>
                        <div className="cell-title">{conversationViewer.conversation.fileName}</div>
                        <div className="cell-subtitle">
                          {conversationViewer.conversation.originLabel ||
                            conversationViewer.conversation.chatType ||
                            conversationViewer.conversation.sessionKey ||
                            "-"}
                        </div>
                      </div>
                      <div className="conversation-detail-badges">
                        <StatusBadge
                          tone={conversationStatusTone(conversationViewer.conversation)}
                          text={conversationStatusLabel(conversationViewer.conversation)}
                        />
                        {conversationViewer.conversation.recentModel?.modelRef ? (
                          <StatusBadge
                            tone="muted"
                            text={conversationViewer.conversation.recentModel.modelRef}
                          />
                        ) : null}
                      </div>
                    </div>

                    <div className="conversation-detail-meta">
                      <span>创建: {conversationViewer.conversation.createdAt || "-"}</span>
                      <span>最后消息: {conversationViewer.conversation.lastMessageAt || "-"}</span>
                      <span>详情更新时间: {conversationViewer.detailGeneratedAt || "-"}</span>
                      <span>
                        展示 {conversationViewer.messages?.length ? conversationViewer.offset + 1 : 0}
                        {" - "}
                        {conversationViewer.offset + (conversationViewer.messages?.length || 0)}
                        {" / "}
                        {conversationViewer.totalMessages || conversationViewer.conversation.messageCount || 0}
                      </span>
                    </div>
                  </div>

                  {conversationViewer.detailLoading ? (
                    <div className="empty-state">正在加载会话内容...</div>
                  ) : conversationViewer.messages?.length ? (
                    <>
                      <div className="conversation-pagination">
                        <button
                          type="button"
                          className="ghost-button"
                          disabled={!conversationViewer.hasOlder || conversationViewer.detailLoading}
                          onClick={() =>
                            loadConversationDetail(conversationViewer.instance, conversationViewer.selectedId, {
                              offset: Math.max(
                                0,
                                (conversationViewer.offset || 0) - (conversationViewer.limit || conversationPageSize),
                              ),
                              limit: conversationViewer.limit || conversationPageSize,
                            })
                          }
                        >
                          上一页
                        </button>
                        <button
                          type="button"
                          className="ghost-button"
                          disabled={!conversationViewer.hasNewer || conversationViewer.detailLoading}
                          onClick={() =>
                            loadConversationDetail(conversationViewer.instance, conversationViewer.selectedId, {
                              offset: (conversationViewer.offset || 0) + (conversationViewer.limit || conversationPageSize),
                              limit: conversationViewer.limit || conversationPageSize,
                            })
                          }
                        >
                          下一页
                        </button>
                      </div>

                      <div className="conversation-page-note">
                        默认只加载最近 {conversationViewer.limit || conversationPageSize} 条消息，避免大文件把界面拖垮。
                      </div>

                      <div className="conversation-message-list">
                        {conversationViewer.messages.map((message, index) => (
                          <ConversationMessageCard
                            key={`${message.id || message.timestamp || "message"}:${message.role}:${index}`}
                            message={message}
                          />
                        ))}
                      </div>
                    </>
                  ) : (
                    <div className="empty-state">这个会话里还没有可展示的消息。</div>
                  )}
                </>
              ) : conversationViewer.detailLoading ? (
                <div className="empty-state">正在加载会话内容...</div>
              ) : (
                <div className="empty-state">从左侧选择一个会话即可查看完整对话历史。</div>
              )}
            </section>
          </div>
        </ModalShell>
      ) : null}

      {logViewer ? (
        <ModalShell
          title={`运行日志 · ${logViewer.instance}`}
          kicker="Logs"
          onClose={closeLogViewer}
          wide
        >
          <div className="log-toolbar">
            <label>
              <span>服务</span>
              <select
                value={logViewer.service}
                onChange={(event) =>
                  loadLogs(logViewer.instance, { service: event.target.value, tail: logViewer.tail })
                }
                disabled={logViewer.loading}
              >
                {(logViewer.services || []).map((service) => (
                  <option key={service} value={service}>
                    {service}
                  </option>
                ))}
              </select>
            </label>

            <label>
              <span>行数</span>
              <select
                value={String(logViewer.tail)}
                onChange={(event) =>
                  loadLogs(logViewer.instance, { service: logViewer.service, tail: Number(event.target.value) })
                }
                disabled={logViewer.loading}
              >
                {logTailOptions.map((value) => (
                  <option key={value} value={value}>
                    最近 {value} 行
                  </option>
                ))}
              </select>
            </label>

            <div className="log-toolbar-actions">
              <button
                type="button"
                className="ghost-button"
                onClick={() => loadLogs(logViewer.instance, { service: logViewer.service, tail: logViewer.tail })}
                disabled={logViewer.loading}
              >
                {logViewer.loading ? "加载中..." : "刷新日志"}
              </button>
            </div>
          </div>

          <div className="log-meta">
            <span>实例: {logViewer.instance}</span>
            <span>服务: {logViewer.service}</span>
            <span>更新: {logViewer.generatedAt || "-"}</span>
          </div>

          {logViewer.error ? <div className="banner error">{logViewer.error}</div> : null}

          <pre className="log-output">
            {logViewer.content || (logViewer.loading ? "正在加载日志..." : "当前没有可显示的日志。")}
          </pre>
        </ModalShell>
      ) : null}

      {weixinQrViewer ? (
        <ModalShell
          title={`微信二维码 · ${weixinQrViewer.instance}`}
          kicker="Weixin Login"
          onClose={closeWeixinQrViewer}
        >
          <div className="qr-toolbar">
            <div className="selected-instance qr-status-card">
              <div className="cell-title">{weixinQrViewer.instance}</div>
              <div className="cell-subtitle">{weixinQrViewer.message || "正在准备微信登录..."}</div>
            </div>

            <div className="qr-toolbar-actions">
              <button
                type="button"
                className="ghost-button"
                onClick={() => loadWeixinQrStatus(weixinQrViewer.instance)}
                disabled={weixinQrViewer.loading}
              >
                {weixinQrViewer.loading ? "加载中..." : "刷新状态"}
              </button>
              <button
                type="button"
                onClick={() => startWeixinQr(weixinQrViewer.instance, true)}
                disabled={weixinQrViewer.loading}
              >
                获取最新二维码
              </button>
            </div>
          </div>

          <div className="log-meta">
            <span>状态: {weixinQrViewer.status || "-"}</span>
            <span>开始: {weixinQrViewer.startedAt || "-"}</span>
            <span>更新: {weixinQrViewer.updatedAt || "-"}</span>
          </div>

          {weixinQrViewer.error ? <div className="banner error">{weixinQrViewer.error}</div> : null}

          <div className="qr-layout">
            <div className="qr-preview">
              {weixinQrViewer.qrUrl ? (
                <>
                  <img
                    className="weixin-qr-image"
                    src={weixinQrImage || ""}
                    alt={`微信二维码 ${weixinQrViewer.instance}`}
                  />
                  <a
                    className="ghost-button qr-open-link"
                    href={weixinQrViewer.qrUrl}
                    target="_blank"
                    rel="noreferrer"
                  >
                    在新窗口打开二维码
                  </a>
                </>
              ) : (
                <div className="empty-state qr-empty-state">
                  {weixinQrViewer.loading || weixinQrViewer.justStarted
                    ? "正在获取二维码..."
                    : "当前还没有可展示的二维码，请点击“获取最新二维码”。"}
                </div>
              )}
            </div>

            <pre className="log-output qr-log-output">
              {weixinQrViewer.output || "这里会显示微信登录过程中的实时输出。"}
            </pre>
          </div>
        </ModalShell>
      ) : null}
    </div>
  );
}

function SummaryCard({ label, value, accent }) {
  return (
    <article className={`summary-card accent-${accent}`}>
      <p>{label}</p>
      <strong>{value}</strong>
    </article>
  );
}

function StatusBadge({ text, tone }) {
  return <span className={`status-badge tone-${tone}`}>{text}</span>;
}

function ConversationMessageCard({ message }) {
  return (
    <article className="conversation-message-card">
      <div className="conversation-message-header">
        <div className="conversation-message-title">
          <StatusBadge tone={conversationRoleTone(message.role)} text={conversationRoleLabel(message.role)} />
          {message.toolName ? <span className="cell-subtitle">tool: {message.toolName}</span> : null}
        </div>
        <div className="conversation-message-meta">
          <span>{message.timestamp || "-"}</span>
          {message.provider || message.model ? (
            <span>
              {[message.provider, message.model].filter(Boolean).join(" / ")}
            </span>
          ) : null}
          {message.usage?.totalTokens ? (
            <span>tokens {formatNumber(message.usage.totalTokens)}</span>
          ) : null}
          {message.stopReason ? <span>{message.stopReason}</span> : null}
          {message.error ? <span>error</span> : null}
        </div>
      </div>

      <div className="conversation-content-list">
        {(message.content || []).map((block, index) => (
          <ConversationContentBlockView key={`${block.type}:${index}`} block={block} />
        ))}
      </div>
    </article>
  );
}

function ConversationContentBlockView({ block }) {
  if (block.type === "image") {
    return (
      <div className="conversation-block conversation-block-image">
        {block.dataUrl ? (
          <img className="conversation-image-preview" src={block.dataUrl} alt="会话图片内容" />
        ) : (
          <div className="cell-subtitle">{block.note || "图片内容暂不可预览"}</div>
        )}
      </div>
    );
  }

  if (block.type === "toolCall") {
    return (
      <div className="conversation-block">
        <div className="conversation-block-label">{block.name || "tool call"}</div>
        {block.arguments ? <pre className="conversation-block-pre">{block.arguments}</pre> : null}
      </div>
    );
  }

  return (
    <div className={`conversation-block${block.type === "thinking" ? " conversation-block-thinking" : ""}`}>
      {block.note ? <div className="conversation-block-label">{block.note}</div> : null}
      <pre className="conversation-block-pre">{block.text || ""}</pre>
    </div>
  );
}

function ModalShell({
  kicker,
  title,
  children,
  onClose,
  wide = false,
  xwide = false,
  scrollLock = false,
}) {
  return (
    <div className="modal-overlay" onClick={onClose}>
      <div
        className={`modal-card${wide ? " modal-card-wide" : ""}${xwide ? " modal-card-xwide" : ""}${
          scrollLock ? " modal-card-scroll-lock" : ""
        }`}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="modal-header">
          <div>
            <p className="panel-kicker">{kicker}</p>
            <h2>{title}</h2>
          </div>
          <button type="button" className="ghost-button modal-close" onClick={onClose}>
            关闭
          </button>
        </div>
        <div className={`modal-body${scrollLock ? " modal-body-scroll-lock" : ""}`}>{children}</div>
      </div>
    </div>
  );
}
