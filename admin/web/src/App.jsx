import { useEffect, useMemo, useState } from "react";

const emptyCreateForm = {
  name: "",
  gatewayPort: "auto",
  bridgePort: "auto",
  withWeixin: true,
  skipWeixinLogin: true,
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

export default function App() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [selectedInstance, setSelectedInstance] = useState(null);
  const [quotaForm, setQuotaForm] = useState(emptyQuotaForm);
  const [createForm, setCreateForm] = useState(emptyCreateForm);
  const [busyAction, setBusyAction] = useState("");
  const [notice, setNotice] = useState("");

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
        item.recentTopModel?.modelRef,
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
      setSelectedInstance(null);
      await loadInstances();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyAction("");
    }
  }

  async function submitCreateInstance(event) {
    event.preventDefault();
    setBusyAction("create-instance");
    setNotice("");
    setError("");

    try {
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
        throw new Error(validityError);
      }

      const payload = {
        name: createForm.name,
        gatewayPort: createForm.gatewayPort,
        bridgePort: createForm.bridgePort,
        withWeixin: createForm.withWeixin,
        skipWeixinLogin: createForm.skipWeixinLogin,
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

      await requestJSON("/api/instances", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      setCreateForm(emptyCreateForm);
      setNotice("新实例已创建");
      await loadInstances();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyAction("");
    }
  }

  const totals = data?.totals || {};
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

      <section className="layout-grid">
        <div className="panel panel-wide">
          <div className="panel-header">
            <div>
              <p className="panel-kicker">Usage Matrix</p>
              <h2>用户实例用量</h2>
            </div>
            <input
              className="search-input"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="搜索实例 / 模型 / 状态"
            />
          </div>

          {error ? <div className="banner error">{error}</div> : null}
          {notice ? <div className="banner success">{notice}</div> : null}

          <div className="table-wrap">
            <table className="instance-table">
              <thead>
                <tr>
                  <th>实例</th>
                  <th>主模型</th>
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
                          最近模型 {instance.recentTopModel?.modelRef || "-"}
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
                        <StatusBadge
                          tone={instance.stats.gatewayState === "running" ? "good" : "warn"}
                          text={instance.stats.gatewayState}
                        />
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
                            额度
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

        <div className="side-column">
          <section className="panel">
            <div className="panel-header">
              <div>
                <p className="panel-kicker">Quota Desk</p>
                <h2>额度操作</h2>
              </div>
            </div>

            {selectedInstance ? (
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

                <div className="form-actions">
                  <button type="submit" disabled={busyAction.endsWith(":quota")}>
                    保存额度
                  </button>
                  <button type="button" className="ghost-button" onClick={() => setSelectedInstance(null)}>
                    取消
                  </button>
                </div>
              </form>
            ) : (
              <div className="empty-state">
                从左侧选择一个实例后，可以直接增加 token 额度，或改成固定额度。
              </div>
            )}
          </section>

          <section className="panel">
            <div className="panel-header">
              <div>
                <p className="panel-kicker">Provisioning</p>
                <h2>创建用户实例</h2>
              </div>
            </div>

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

              <label>
                <span>OpenAI Base URL</span>
                <input
                  value={createForm.openaiBaseUrl}
                  onChange={(event) => setCreateForm((prev) => ({ ...prev, openaiBaseUrl: event.target.value }))}
                />
              </label>

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

              <div className="two-columns">
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
                月额度会按开始日期滚动重置。比如开始日期是 1 月 2 日，就会在 2 月 2 日进入下一个月度周期；开始和截止日期不再要求整月对齐。
              </div>

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
                  checked={createForm.skipWeixinLogin}
                  onChange={(event) =>
                    setCreateForm((prev) => ({ ...prev, skipWeixinLogin: event.target.checked }))
                  }
                />
                <span>创建后不自动拉起微信登录</span>
              </label>

              <div className="form-actions">
                <button type="submit" disabled={busyAction === "create-instance"}>
                  创建实例
                </button>
              </div>
            </form>
          </section>
        </div>
      </section>
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
