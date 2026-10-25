// Loopback management page. The token stays in the page URL; the server rejects
// calls that do not present it. No remote assets and no embedded secrets.

const params = new URLSearchParams(location.search);
const token = params.get("token") || "";

const copy = {
  zh: {
    subtitle: "把冷门 App 放到远端，本机只留一个入口",
    refresh: "刷新",
    lang: "English",
    themeLight: "浅色",
    themeDark: "深色",
    themeSystem: "跟随系统",
    skip: "跳到应用",
    retry: "重试",
    cache: "缓存用量",
    backend: "后端",
    apps: "应用",
    sessions: "冷会话",
    recommend: "值得卸载",
    recommendWarn: "不建议卸载",
    recommendEmpty: "没有达到大小阈值的应用",
    recommendEmptyHint: "较大且久未使用的应用会显示在这里",
    recommendUnavailable: "扫描已安装应用需要 macOS",
    recommendFailed: "未能加载建议",
    recommendSummary: (count, freed, min) => `${count} 个 · 大约可腾出 ${freed} · 至少 ${min}`,
    leftoverBackups: (count, size) => `${count} 个残留备份（${size}）可以删除`,
    leftoverAdmin: "删除需要管理员权限。",
    neverUsed: "从未使用",
    idleDays: (n) => n === 1 ? "1 天未使用" : `${n} 天未使用`,
    restoreNeeded: "含商店收据，需要还原模式",
    sizeBound: "大小是下限（扫描超时）",
    modeMount: "挂载",
    modeRestore: "还原",
    modeSkip: "跳过",
    modeUnsupported: "不支持",
    warnloginItem: "登录项",
    warnmenuBarAgent: "菜单栏代理",
    warnbackgroundHelper: "后台辅助进程在运行",
    warnsystemExtension: "带系统扩展",
    warnkernelExtension: "带内核扩展",
    warntoolchain: "引擎使用的工具链",
    warnpinned: "已固定",
    warnalreadyPacked: "已经打包",
    warnsizeTimedOut: "体积扫描超时",
    usedCaption: "已用",
    ofQuota: "配额",
    remaining: "剩余空间",
    floor: "空闲底线",
    detach: "卸载延迟",
    seconds: (n) => `${n} 秒`,
    legendUsed: "已用",
    legendFree: "剩余",
    legendFloor: "空闲底线",
    floorOver: "空闲底线高于配额",
    nearWarn: "接近配额",
    nearHot: "配额将满",
    noData: "没有数据",
    healthyTitle: "运行正常",
    healthySub: "Running OK · Healthy",
    degradedTitle: "性能下降",
    degradedSub: "Degraded",
    offlineTitle: "已离线",
    offlineSub: "Offline",
    latency: "延迟",
    current: "当前",
    endpoints: "端点",
    currentChip: "当前",
    local: "本地目录",
    coldDays: (n) => `超过 ${n} 天未用会进入冷层`,
    offloaded: (n) => `${n} 个已归档`,
    emptyApps: "还没有卸载到远端的应用",
    emptyAppsHint: "pack 之后，应用会显示在这里",
    loadFailed: "未能加载应用",
    emptySessions: "没有冷会话",
    cached: "已缓存",
    remote: "仅远端",
    pinned: "已固定",
    restored: "已还原",
    cold: "冷会话",
    pin: "固定",
    unpin: "取消固定",
    evict: "清除缓存",
    evictDisabled: "清除缓存，目前没有缓存",
    restore: "还原",
    mount: "挂载",
    restoreMode: "临时还原",
    notCached: "未缓存",
    share: (n) => `占配额 ${n}%`,
    quotaUnset: "未设置配额",
  },
  en: {
    subtitle: "Keep rarely used apps remote, and a small launcher on this Mac",
    refresh: "Refresh",
    lang: "中文",
    themeLight: "Light",
    themeDark: "Dark",
    themeSystem: "System",
    skip: "Skip to apps",
    retry: "Retry",
    cache: "Cache",
    backend: "Backend",
    apps: "Apps",
    sessions: "Cold sessions",
    recommend: "Worth offloading",
    recommendWarn: "Poor candidates",
    recommendEmpty: "No apps above the size threshold",
    recommendEmptyHint: "Large apps that have sat unused show up here",
    recommendUnavailable: "Scanning installed apps requires macOS",
    recommendFailed: "Could not load recommendations",
    recommendSummary: (count, freed, min) => `${count} · about ${freed} free · at least ${min}`,
    leftoverBackups: (count, size) => `${count} leftover backup${count === 1 ? "" : "s"} (${size}) can be removed`,
    leftoverAdmin: "Removing them needs an administrator.",
    neverUsed: "Never used",
    idleDays: (n) => n === 1 ? "Last used 1 day ago" : `Last used ${n} days ago`,
    restoreNeeded: "Mac App Store receipt, restore mode",
    sizeBound: "Size is a lower bound (scan timed out)",
    modeMount: "Mount",
    modeRestore: "Restore",
    modeSkip: "Skip",
    modeUnsupported: "Unsupported",
    warnloginItem: "Login item",
    warnmenuBarAgent: "Menu bar agent",
    warnbackgroundHelper: "Background helper is running",
    warnsystemExtension: "Bundles a system extension",
    warnkernelExtension: "Bundles a kernel extension",
    warntoolchain: "Toolchain used by the engine",
    warnpinned: "Pinned",
    warnalreadyPacked: "Already packed",
    warnsizeTimedOut: "Size scan timed out",
    usedCaption: "Used",
    ofQuota: "Quota",
    remaining: "Remaining",
    floor: "Free-space floor",
    detach: "Detach delay",
    seconds: (n) => `${n}s`,
    legendUsed: "Used",
    legendFree: "Free",
    legendFloor: "Floor",
    floorOver: "Floor is larger than the quota",
    nearWarn: "Near quota",
    nearHot: "Quota almost full",
    noData: "No data",
    healthyTitle: "Running OK",
    healthySub: "运行正常 · Healthy",
    degradedTitle: "Degraded",
    degradedSub: "性能下降",
    offlineTitle: "Offline",
    offlineSub: "已离线",
    latency: "Latency",
    current: "Current",
    endpoints: "Endpoints",
    currentChip: "Current",
    local: "Local folder",
    coldDays: (n) => `Cold after ${n} days`,
    offloaded: (n) => `${n} archived`,
    emptyApps: "No offloaded apps",
    emptyAppsHint: "Apps show up here after they are packed",
    loadFailed: "Could not load apps",
    emptySessions: "No cold sessions",
    cached: "Cached",
    remote: "Remote",
    pinned: "Pinned",
    restored: "Restored",
    cold: "Cold",
    pin: "Pin",
    unpin: "Unpin",
    evict: "Evict cache",
    evictDisabled: "Evict cache, nothing cached",
    restore: "Restore",
    mount: "Mount",
    restoreMode: "Restore",
    notCached: "Not cached",
    share: (n) => `${n}% of quota`,
    quotaUnset: "Quota is not set",
  },
};

let lang = document.documentElement.lang === "en" ? "en" : "zh";
let lastStatus = null;
let lastRecommend = null;
let recommendError = "";
let lastLatency = null;
let loadFailed = false;
let busy = false;

function t(key) {
  return copy[lang][key];
}

function url(path) {
  const target = new URL(path, location.origin);
  if (token) target.searchParams.set("token", token);
  return target;
}

async function api(path, options) {
  const response = await fetch(url(path), options);
  let payload = {};
  try { payload = await response.json(); } catch (e) { payload = {}; }
  if (!response.ok || payload.ok === false) throw new Error(payload.error || response.statusText || "request failed");
  return payload;
}

function bytes(value) {
  const n = Number(value || 0);
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(1)} GiB`;
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MiB`;
  return `${n} B`;
}

function usagePercent(used, quota) {
  if (!quota) return 0;
  return Math.round((used / quota) * 100);
}

function usageLevel(pct) {
  if (pct >= 95) return "hot";
  if (pct >= 80) return "warn";
  return "ok";
}

function healthLevel(status) {
  if (status === "ok") return "healthy";
  if (status === "offline") return "offline";
  return "degraded";
}

function themeLabel() {
  const theme = document.documentElement.getAttribute("data-theme");
  if (theme === "dark") return t("themeDark");
  if (theme === "light") return t("themeLight");
  return t("themeSystem");
}

function applyChrome() {
  document.documentElement.lang = lang === "en" ? "en" : "zh-Hans";
  document.querySelector("#subtitle").textContent = t("subtitle");
  document.querySelector("#refresh").textContent = t("refresh");
  document.querySelector("#lang").textContent = t("lang");
  document.querySelector("#theme").textContent = themeLabel();
  document.querySelector("#skip").textContent = t("skip");
  document.querySelector("#retry").textContent = t("retry");
  document.querySelector("#cache-title").textContent = t("cache");
  document.querySelector("#health-title").textContent = t("backend");
  const count = (lastStatus && lastStatus.apps && lastStatus.apps.length) || 0;
  document.querySelector("#apps-title").textContent = lastStatus ? `${t("apps")} ${count}` : t("apps");
  document.querySelector("#sessions-title").textContent = t("sessions");
  document.querySelector("#recommend-title").textContent = t("recommend");
  document.querySelector("#recommend-warn-title").textContent = t("recommendWarn");
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function showBanner(message) {
  const banner = document.querySelector("#banner");
  document.querySelector("#banner-text").textContent = message;
  banner.hidden = false;
}

function hideBanner() {
  document.querySelector("#banner").hidden = true;
  document.querySelector("#banner-text").textContent = "";
}

function iconButton(label, accessibleName, path, action) {
  const node = document.createElement("button");
  node.type = "button";
  node.setAttribute("aria-label", accessibleName);
  node.title = label;
  // The SVG namespace is not fetched. The pieces stay split so the page source has no URL.
  const svgNS = "http" + "://www.w3.org/2000/svg";
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "18");
  svg.setAttribute("height", "18");
  svg.setAttribute("aria-hidden", "true");
  const drawing = document.createElementNS(svgNS, "path");
  drawing.setAttribute("fill", "currentColor");
  drawing.setAttribute("d", path);
  svg.append(drawing);
  node.append(svg, el("span", "btn-label", label));
  node.addEventListener("click", action);
  return node;
}

const iconPin = "M12 2.2c.5 0 .9.4.9.9v1.2A5.1 5.1 0 0 1 17 9.2c0 1.2-.4 2.3-1.1 3.2L14.6 21h-5.2l-1.3-8.6A4.8 4.8 0 0 1 7 9.2a5.1 5.1 0 0 1 4.1-4.9V3.1c0-.5.4-.9.9-.9z";
const iconTrash = "M9 3h6l1 2h4v2H4V5h4l1-2zm1 6h2v9h-2V9zm4 0h2v9h-2V9zM8 9h2v9H8V9z";
const iconRestore = "M12 4a7 7 0 1 1-6.2 3.7H8a5 5 0 1 0 1.2-2.4L7.5 7H3.2V2.7L5 4.5A7 7 0 0 1 12 4z";

function appIcon(name) {
  const letter = (name || "?").trim().charAt(0).toUpperCase() || "?";
  const tones = ["#0f6b4c", "#0c4f8a", "#8a3d12", "#8f1d3a", "#3d4a2a", "#4a3f8a"];
  let hash = 0;
  for (const ch of name || "?") hash = (hash + ch.charCodeAt(0)) % tones.length;
  const node = el("div", "app-icon", letter);
  node.style.background = tones[hash];
  node.setAttribute("aria-hidden", "true");
  return node;
}

function chip(kind, label) {
  return el("span", `chip ${kind}`, label);
}

function renderCache(cache) {
  const body = document.querySelector("#cache-body");
  const card = document.querySelector("#cache-card");
  const near = document.querySelector("#near");
  body.replaceChildren();
  body.removeAttribute("aria-busy");
  if (!cache) {
    card.dataset.level = "ok";
    near.hidden = true;
    body.append(el("p", "usage-caption", t("noData")));
    return;
  }
  const used = Number(cache.usedBytes || 0);
  const quota = Number(cache.quotaBytes || 0);
  const floor = Number(cache.minFreeBytes || 0);
  const pct = usagePercent(used, quota);
  const level = usageLevel(pct);
  card.dataset.level = level;
  if (level === "hot") {
    near.hidden = false;
    near.textContent = t("nearHot");
  } else if (level === "warn") {
    near.hidden = false;
    near.textContent = t("nearWarn");
  } else {
    near.hidden = true;
    near.textContent = "";
  }
  const value = el("p", "usage-value", quota > 0 ? `${pct}%` : "—");
  const caption = el("p", "usage-caption", quota > 0 ? `${bytes(used)} / ${bytes(quota)}` : t("quotaUnset"));
  const track = el("div", "usage-track");
  track.setAttribute("role", "meter");
  track.setAttribute("aria-valuemin", "0");
  track.setAttribute("aria-valuemax", "100");
  track.setAttribute("aria-valuenow", String(Math.max(0, Math.min(100, pct))));
  track.setAttribute("aria-valuetext", `${pct}% ${t("usedCaption")}. ${t("floor")} ${bytes(floor)}`);
  track.setAttribute("aria-labelledby", "cache-title");
  const fill = el("div", "usage-fill");
  fill.style.width = `${Math.max(0, Math.min(100, pct))}%`;
  track.append(fill);
  if (quota > 0 && floor > 0) {
    const marker = el("div", "usage-floor");
    const floorPct = Math.max(0, Math.min(100, (floor / quota) * 100));
    marker.style.left = `${floorPct}%`;
    marker.title = `${t("floor")} ${bytes(floor)}`;
    track.append(marker);
  }
  const legend = el("ul", "legend");
  for (const [kind, label] of [["used", t("legendUsed")], ["free", t("legendFree")], ["floor", t("legendFloor")]]) {
    const item = el("li");
    const swatch = el("i", `swatch ${kind}`);
    swatch.setAttribute("aria-hidden", "true");
    item.append(swatch, document.createTextNode(label));
    legend.append(item);
  }
  body.append(value, caption, track, legend);
  if (quota > 0 && floor > quota) body.append(el("p", "floor-note", t("floorOver")));
  const stats = el("dl", "stats");
  const remaining = quota > used ? quota - used : 0;
  for (const [label, text] of [
    [t("remaining"), quota > 0 ? bytes(remaining) : "—"],
    [t("floor"), bytes(floor)],
    [t("detach"), t("seconds")(cache.detachDelaySeconds || 0)],
  ]) {
    const row = el("div");
    row.append(el("dt", "", label), el("dd", "", text));
    stats.append(row);
  }
  body.append(stats);
}

function endpointLine(item) {
  const row = el("li", item.current ? "endpoint is-current" : "endpoint");
  row.append(el("span", "kind", item.type || "local"));
  row.append(el("strong", "", item.id || ""));
  const place = item.mountPoint || item.url || item.host || "";
  if (place) row.append(el("span", "", place));
  if (item.current) row.append(chip("cached", t("currentChip")));
  return row;
}

function renderHealth(backend, latency) {
  const body = document.querySelector("#health-body");
  const card = document.querySelector("#health-card");
  body.replaceChildren();
  body.removeAttribute("aria-busy");
  const level = backend ? healthLevel(backend.health) : "offline";
  card.dataset.level = level;
  const title = { healthy: t("healthyTitle"), degraded: t("degradedTitle"), offline: t("offlineTitle") }[level];
  const sub = { healthy: t("healthySub"), degraded: t("degradedSub"), offline: t("offlineSub") }[level];
  const status = el("div", "health-status");
  const dot = el("span", "dot");
  dot.setAttribute("aria-hidden", "true");
  const words = el("div");
  words.append(el("strong", "", title), el("span", "subline", sub));
  status.append(dot, words);
  const facts = el("dl", "facts");
  const latencyText = latency == null ? "—" : `${latency} ms`;
  for (const [label, text] of [
    [t("latency"), latencyText],
    [t("current"), backend ? `${backend.activeId || backend.kind || "local"}` : "—"],
  ]) {
    const row = el("div");
    row.append(el("dt", "", label), el("dd", "", text));
    facts.append(row);
  }
  body.append(status, facts);
  if (backend && backend.healthDetail) body.append(el("p", "health-detail", backend.healthDetail));
  const list = el("ul", "endpoints");
  const raw = (backend && backend.endpoints) || [];
  const rows = raw.length
    ? raw.map((item) => ({
        id: item.id || "",
        type: item.type || "",
        host: item.host || "",
        mountPoint: item.mountPoint || "",
        url: item.url || "",
        current: item.id && backend.activeId && item.id === backend.activeId,
      }))
    : [{
        id: (backend && (backend.activeId || backend.kind)) || t("local"),
        type: (backend && backend.kind) || "local",
        host: "",
        mountPoint: (backend && backend.repoPath) || "",
        url: "",
        current: true,
      }];
  body.append(el("p", "endpoint-label", t("endpoints")));
  for (const item of rows) list.append(endpointLine(item));
  body.append(list);
}

function renderApps(list, failed) {
  const root = document.querySelector("#app-list");
  root.replaceChildren();
  root.removeAttribute("aria-busy");
  const apps = list || [];
  if (!apps.length) {
    const empty = el("div", "empty");
    empty.append(el("strong", "", failed ? t("loadFailed") : t("emptyApps")));
    if (!failed) empty.append(el("span", "", t("emptyAppsHint")));
    root.append(empty);
    return;
  }
  const quota = Number((lastStatus && lastStatus.cache && lastStatus.cache.quotaBytes) || 0);
  for (const app of apps) {
    const card = el("article", "app");
    const main = el("div", "app-main");
    const nameRow = el("div", "name-row");
    nameRow.append(el("div", "name", app.name || ""));
    const chips = el("div", "chips");
    if (app.cached) chips.append(chip("cached", t("cached")));
    if (app.remote || app.cached === false) chips.append(chip("remote", t("remote")));
    if (app.pinned) chips.append(chip("pinned", t("pinned")));
    if (app.restored) chips.append(chip("restored", t("restored")));
    nameRow.append(chips);
    const mode = app.mode === "restore" ? t("restoreMode") : t("mount");
    const size = app.cached ? bytes(app.cachedBytes) : t("notCached");
    main.append(nameRow, el("div", "meta", `${app.version || ""} · ${mode} · ${size}`));
    if (app.cached && quota > 0) {
      const sharePct = Math.max(0, Math.min(100, (Number(app.cachedBytes || 0) / quota) * 100));
      const shown = sharePct >= 10 ? Math.round(sharePct) : Math.round(sharePct * 10) / 10;
      const bar = el("div", "share");
      bar.setAttribute("role", "meter");
      bar.setAttribute("aria-valuemin", "0");
      bar.setAttribute("aria-valuemax", "100");
      bar.setAttribute("aria-valuenow", String(Math.round(sharePct)));
      bar.setAttribute("aria-label", t("share")(shown));
      const fill = el("span");
      fill.style.width = `${sharePct}%`;
      bar.append(fill);
      main.append(bar);
    }
    const actions = el("div", "actions");
    const pinLabel = app.pinned ? t("unpin") : t("pin");
    actions.append(iconButton(pinLabel, pinLabel, iconPin, () => act(app.pinned ? "/api/unpin" : "/api/pin", app.name)));
    const evict = iconButton(t("evict"), app.cached ? t("evict") : t("evictDisabled"), iconTrash, () => act("/api/evict", app.name));
    if (!app.cached) evict.disabled = true;
    actions.append(evict);
    actions.append(iconButton(t("restore"), t("restore"), iconRestore, () => act("/api/restore", app.name)));
    card.append(appIcon(app.name), main, actions);
    root.append(card);
  }
}

function recommendReason(app) {
  const warnings = app.warnings || [];
  if (warnings.length) return warnings.map((code) => t("warn" + code) || code).join("; ");
  const parts = [bytes(app.sizeBytes)];
  if (app.neverUsed) parts.push(t("neverUsed"));
  else if (app.daysIdle != null) parts.push(t("idleDays")(Number(app.daysIdle)));
  let text = parts.join(", ");
  if (app.macAppStore) text += "; " + t("restoreNeeded");
  if (app.sizeIncomplete) text += "; " + t("sizeBound");
  return text;
}

function modeLabel(mode) {
  if (mode === "restore") return t("modeRestore");
  if (mode === "unsupported") return t("modeUnsupported");
  if (mode === "skip") return t("modeSkip");
  return t("modeMount");
}

function renderLeftovers(report) {
  const line = document.querySelector("#recommend-leftovers");
  const paths = document.querySelector("#recommend-leftover-paths");
  line.replaceChildren();
  paths.replaceChildren();
  const items = (report && report.leftoverBackups) || [];
  if (!items.length) {
    line.hidden = true;
    paths.hidden = true;
    return;
  }
  const total = items.reduce((sum, item) => sum + Number(item.sizeBytes || 0), 0);
  line.hidden = false;
  line.append(document.createTextNode(t("leftoverBackups")(items.length, bytes(total)) + " " + t("leftoverAdmin")));
  paths.hidden = false;
  for (const item of items) {
    const row = el("li");
    row.append(el("div", "path", item.path || ""));
    paths.append(row);
  }
}

function renderRecommend(report, failed) {
  const summary = document.querySelector("#recommend-summary");
  const list = document.querySelector("#recommend-list");
  const warnTitle = document.querySelector("#recommend-warn-title");
  const warnings = document.querySelector("#recommend-warnings");
  list.replaceChildren();
  warnings.replaceChildren();
  list.removeAttribute("aria-busy");
  if (!report) {
    summary.textContent = failed || t("recommendFailed");
    const empty = el("div", "empty");
    empty.append(el("strong", "", failed || t("recommendFailed")));
    list.append(empty);
    warnTitle.hidden = true;
    renderLeftovers(null);
    return;
  }
  if (report.scan === "unavailable") {
    summary.textContent = report.detail || t("recommendUnavailable");
  } else {
    summary.textContent = t("recommendSummary")((report.recommendations || []).length, bytes(report.estimatedFreedBytes || 0), bytes(report.minSizeBytes || 0));
  }
  const apps = report.recommendations || [];
  if (!apps.length && report.scan !== "unavailable") {
    const empty = el("div", "empty");
    empty.append(el("strong", "", t("recommendEmpty")));
    empty.append(el("span", "", t("recommendEmptyHint")));
    list.append(empty);
  }
  for (const app of apps) {
    const card = el("article", "app");
    const main = el("div", "app-main");
    const nameRow = el("div", "name-row");
    nameRow.append(el("div", "name", app.name || ""));
    nameRow.append(chip(app.macAppStore ? "restored" : "cached", modeLabel(app.suggestedMode)));
    main.append(nameRow, el("div", "meta", `${bytes(app.sizeBytes)} · ${app.bundleId || ""}`), el("div", "recommend-reason", recommendReason(app)));
    card.append(appIcon(app.name), main);
    list.append(card);
  }
  const poor = report.warnings || [];
  warnTitle.hidden = poor.length === 0;
  for (const app of poor) {
    const item = el("li");
    const top = el("div", "session-top");
    top.append(el("div", "name", app.name || ""), chip("warn", modeLabel(app.suggestedMode)));
    item.append(top, el("div", "path", app.path || ""), el("p", "preview", recommendReason(app)));
    warnings.append(item);
  }
  renderLeftovers(report);
}

function renderSessions(sessions) {
  const summary = document.querySelector("#sessions-summary");
  const list = document.querySelector("#sessions");
  list.replaceChildren();
  const offloaded = (sessions && sessions.offloaded) || [];
  summary.textContent = sessions ? `${t("coldDays")(sessions.coldDays || 14)} · ${t("offloaded")(offloaded.length)}` : "";
  if (!offloaded.length) {
    list.append(el("li", "empty", t("emptySessions")));
    return;
  }
  for (const entry of offloaded) {
    const item = el("li");
    const top = el("div", "session-top");
    top.append(el("div", "name", entry.tool || ""), chip("cold", entry.tier === "cold" ? t("cold") : (entry.tier || t("cold"))));
    item.append(top, el("div", "path", entry.path || ""));
    if (entry.preview) item.append(el("p", "preview", entry.preview));
    list.append(item);
  }
}

function render(status) {
  lastStatus = status;
  applyChrome();
  renderCache(status.cache || {});
  renderHealth(status.backend || {}, lastLatency);
  const failed = Boolean(status.appsError);
  if (failed) showBanner(status.appsError);
  renderApps(status.apps || [], failed);
  renderSessions(status.sessions || {});
}

function renderFailure() {
  applyChrome();
  renderCache(null);
  renderHealth(null, lastLatency);
  renderApps([], true);
  renderSessions(null);
}

async function loadRecommendations() {
  try {
    const report = await api("/api/recommend");
    lastRecommend = report;
    recommendError = "";
    renderRecommend(report, "");
  } catch (error) {
    recommendError = error.message || String(error);
    if (!lastRecommend) renderRecommend(null, recommendError);
  }
}

async function load() {
  const started = performance.now();
  try {
    const status = await api("/api/status");
    lastLatency = Math.round(performance.now() - started);
    loadFailed = false;
    if (!status.appsError) hideBanner();
    render(status);
  } catch (error) {
    lastLatency = Math.round(performance.now() - started);
    loadFailed = !lastStatus;
    showBanner(error.message || String(error));
    if (!lastStatus) renderFailure();
    else renderHealth(Object.assign({}, lastStatus.backend, { health: "offline" }), lastLatency);
  }
}

async function refresh() {
  if (busy) return;
  busy = true;
  try { await Promise.all([load(), loadRecommendations()]); }
  finally { busy = false; }
}

async function act(path, app) {
  if (busy) return;
  busy = true;
  try {
    await api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ app }) });
    hideBanner();
    await load();
  } catch (error) {
    showBanner(error.message || String(error));
  } finally {
    busy = false;
  }
}

document.querySelector("#refresh").addEventListener("click", refresh);
document.querySelector("#retry").addEventListener("click", refresh);
document.querySelector("#lang").addEventListener("click", () => {
  lang = lang === "zh" ? "en" : "zh";
  try { localStorage.setItem("isenough.lang", lang); } catch (e) {}
  if (lastStatus) render(lastStatus);
  else if (loadFailed) renderFailure();
  else applyChrome();
  if (lastRecommend) renderRecommend(lastRecommend, "");
  else if (recommendError) renderRecommend(null, recommendError);
  if (!document.querySelector("#banner").hidden) document.querySelector("#retry").textContent = t("retry");
});
document.querySelector("#theme").addEventListener("click", () => {
  const current = document.documentElement.getAttribute("data-theme");
  const next = current === "light" ? "dark" : current === "dark" ? "" : "light";
  if (next) document.documentElement.setAttribute("data-theme", next);
  else document.documentElement.removeAttribute("data-theme");
  try {
    if (next) localStorage.setItem("isenough.theme", next);
    else localStorage.removeItem("isenough.theme");
  } catch (e) {}
  document.querySelector("#theme").textContent = themeLabel();
});
applyChrome();
refresh();
