const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const errorBox = document.querySelector("#error");

const copy = {
  zh: {
    subtitle: "把冷门 App 放到远端，本机只留一个入口",
    refresh: "刷新",
    lang: "English",
    themeLight: "浅色",
    themeDark: "深色",
    themeSystem: "跟随系统",
    healthOk: "后端正常",
    healthOffline: "后端离线",
    healthMissing: "仓库未初始化",
    healthUnknown: "后端未知",
    cache: "缓存用量",
    used: "已用",
    of: "配额",
    floor: "空闲底线",
    detach: "卸载延迟",
    caption: "已用",
    backend: "后端",
    active: "当前",
    apps: "应用",
    sessions: "冷会话",
    coldDays: (n) => `超过 ${n} 天未用会进入冷层`,
    offloaded: (n) => `${n} 个已归档`,
    emptyApps: "还没有卸载到远端的应用",
    emptySessions: "没有冷会话",
    cached: "已缓存",
    remote: "仅远端",
    pinned: "已固定",
    restored: "已还原",
    cold: "冷会话",
    pin: "固定",
    unpin: "取消固定",
    evict: "腾出",
    restore: "还原",
    mount: "挂载",
    restoreMode: "临时还原",
    notCached: "未缓存",
    local: "本地目录",
  },
  en: {
    subtitle: "Keep rarely used apps remote, and a small launcher on this Mac",
    refresh: "Refresh",
    lang: "中文",
    themeLight: "Light",
    themeDark: "Dark",
    themeSystem: "System",
    healthOk: "Backend online",
    healthOffline: "Backend offline",
    healthMissing: "Repo not initialized",
    healthUnknown: "Backend unknown",
    cache: "Cache",
    used: "Used",
    of: "Quota",
    floor: "Free-space floor",
    detach: "Detach delay",
    caption: "used",
    backend: "Backend",
    active: "Active",
    apps: "Apps",
    sessions: "Cold sessions",
    coldDays: (n) => `Cold after ${n} days`,
    offloaded: (n) => `${n} archived`,
    emptyApps: "No offloaded apps",
    emptySessions: "No cold sessions",
    cached: "Cached",
    remote: "Remote",
    pinned: "Pinned",
    restored: "Restored",
    cold: "Cold",
    pin: "Pin",
    unpin: "Unpin",
    evict: "Evict",
    restore: "Restore",
    mount: "Mount",
    restoreMode: "Restore",
    notCached: "Not cached",
    local: "Local folder",
  },
};

let lang = "zh";
try {
  const saved = localStorage.getItem("isenough.lang");
  if (saved === "en" || saved === "zh") lang = saved;
} catch (e) {}
if (params.get("lang") === "en" || params.get("lang") === "zh") lang = params.get("lang");

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
  const payload = await response.json();
  if (!response.ok || payload.ok === false) throw new Error(payload.error || response.statusText);
  return payload;
}

function bytes(value) {
  const n = Number(value || 0);
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(1)} GiB`;
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MiB`;
  return `${n} B`;
}

function chip(kind, label) {
  const span = document.createElement("span");
  span.className = `chip ${kind}`;
  span.textContent = label;
  return span;
}

function button(label, action) {
  const node = document.createElement("button");
  node.type = "button";
  node.textContent = label;
  node.addEventListener("click", action);
  return node;
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
  document.querySelector("#cache-title").textContent = t("cache");
  document.querySelector("#backend-title").textContent = t("backend");
  document.querySelector("#apps-title").textContent = t("apps");
  document.querySelector("#sessions-title").textContent = t("sessions");
  document.querySelector("#meter-caption").textContent = t("caption");
}

function render(status) {
  applyChrome();
  const backend = status.backend || {};
  const health = document.querySelector("#health");
  const state = backend.health || "unknown";
  health.dataset.state = state;
  const healthText = { ok: t("healthOk"), offline: t("healthOffline"), missing: t("healthMissing") }[state] || t("healthUnknown");
  document.querySelector("#health-label").textContent = healthText;
  const endpoints = (backend.endpoints || []).map((item) => `${item.type}:${item.id}`).join(", ");
  document.querySelector("#backend").textContent = `${backend.kind || "local"} · ${t("active")} ${backend.activeId || "default"}`;
  const detail = [endpoints || t("local"), backend.healthDetail || ""].filter(Boolean).join(" · ");
  document.querySelector("#backend-detail").textContent = detail;

  const cache = status.cache || {};
  const used = Number(cache.usedBytes || 0);
  const quota = Number(cache.quotaBytes || 0);
  const pct = quota > 0 ? Math.min(100, Math.round((used / quota) * 100)) : 0;
  document.querySelector("#meter").style.setProperty("--pct", String(pct));
  document.querySelector("#meter-pct").textContent = `${pct}%`;
  const stats = document.querySelector("#cache-stats");
  stats.replaceChildren();
  for (const [label, value] of [
    [t("used"), bytes(used)],
    [t("of"), bytes(quota)],
    [t("floor"), bytes(cache.minFreeBytes)],
    [t("detach"), `${cache.detachDelaySeconds || 0}s`],
  ]) {
    const row = document.createElement("div");
    const dt = document.createElement("dt");
    const dd = document.createElement("dd");
    dt.textContent = label;
    dd.textContent = value;
    row.append(dt, dd);
    stats.append(row);
  }

  const apps = document.querySelector("#apps");
  apps.replaceChildren();
  const list = status.apps || [];
  if (list.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = status.appsError || t("emptyApps");
    apps.append(empty);
  }
  for (const app of list) {
    const card = document.createElement("article");
    card.className = "app";
    const top = document.createElement("div");
    top.className = "app-top";
    const title = document.createElement("div");
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = app.name || "";
    const meta = document.createElement("div");
    meta.className = "meta";
    const mode = app.mode === "restore" ? t("restoreMode") : t("mount");
    meta.textContent = `${app.version || ""} · ${mode} · ${app.cached ? bytes(app.cachedBytes) : t("notCached")}`;
    title.append(name, meta);
    const chips = document.createElement("div");
    chips.className = "chips";
    if (app.cached) chips.append(chip("cached", t("cached")));
    if (app.remote || app.cached === false) chips.append(chip("remote", t("remote")));
    if (app.pinned) chips.append(chip("pinned", t("pinned")));
    if (app.restored) chips.append(chip("restored", t("restored")));
    top.append(title, chips);
    const actions = document.createElement("div");
    actions.className = "actions";
    actions.append(button(app.pinned ? t("unpin") : t("pin"), () => act(app.pinned ? "/api/unpin" : "/api/pin", app.name)));
    const evict = button(t("evict"), () => act("/api/evict", app.name));
    if (!app.cached) evict.disabled = true;
    actions.append(evict);
    actions.append(button(t("restore"), () => act("/api/restore", app.name)));
    card.append(top, actions);
    apps.append(card);
  }

  const sessions = status.sessions || {};
  const offloaded = sessions.offloaded || [];
  document.querySelector("#sessions-summary").textContent = `${t("coldDays")(sessions.coldDays || 14)} · ${t("offloaded")(offloaded.length)}`;
  const sessionList = document.querySelector("#sessions");
  sessionList.replaceChildren();
  if (offloaded.length === 0) {
    const empty = document.createElement("li");
    empty.className = "empty";
    empty.textContent = t("emptySessions");
    sessionList.append(empty);
  }
  for (const entry of offloaded) {
    const item = document.createElement("li");
    const top = document.createElement("div");
    top.className = "session-top";
    const tool = document.createElement("div");
    tool.className = "name";
    tool.textContent = entry.tool || "";
    top.append(tool, chip("cold", entry.tier === "cold" ? t("cold") : (entry.tier || t("cold"))));
    const path = document.createElement("div");
    path.className = "path";
    path.textContent = entry.path || "";
    item.append(top, path);
    if (entry.preview) {
      const preview = document.createElement("p");
      preview.className = "preview";
      preview.textContent = entry.preview;
      item.append(preview);
    }
    sessionList.append(item);
  }
}

async function refresh() {
  errorBox.textContent = "";
  try { render(await api("/api/status")); }
  catch (error) { errorBox.textContent = error.message; }
}

async function act(path, app) {
  errorBox.textContent = "";
  try {
    await api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ app }) });
    await refresh();
  } catch (error) {
    errorBox.textContent = error.message;
  }
}

document.querySelector("#refresh").addEventListener("click", refresh);
document.querySelector("#lang").addEventListener("click", () => {
  lang = lang === "zh" ? "en" : "zh";
  try { localStorage.setItem("isenough.lang", lang); } catch (e) {}
  refresh();
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
