const token = new URLSearchParams(location.search).get("token") || "";
const errorBox = document.querySelector("#error");

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

function render(status) {
  const backend = status.backend || {};
  const endpoints = (backend.endpoints || []).map((item) => `${item.type}:${item.id}`).join(", ") || "local folder";
  document.querySelector("#backend").textContent = `${backend.kind || "local"} · active ${backend.activeId || "default"} · ${endpoints}`;
  const cache = status.cache || {};
  const used = Number(cache.usedBytes || 0);
  const quota = Number(cache.quotaBytes || 0);
  document.querySelector("#cache").textContent = `${bytes(used)} of ${bytes(quota)} · free-space floor ${bytes(cache.minFreeBytes)} · detach ${cache.detachDelaySeconds || 0}s`;
  document.querySelector("#cache-fill").style.width = `${quota > 0 ? Math.min(100, (used / quota) * 100) : 0}%`;
  const apps = document.querySelector("#apps");
  apps.replaceChildren();
  for (const app of status.apps || []) {
    const row = document.createElement("tr");
    const name = document.createElement("td");
    name.textContent = `${app.name} ${app.version}`;
    const mode = document.createElement("td");
    mode.textContent = app.mode;
    const cached = document.createElement("td");
    cached.textContent = app.cached ? bytes(app.cachedBytes) : "not cached";
    const actions = document.createElement("td");
    const pin = document.createElement("button");
    pin.type = "button";
    pin.textContent = app.pinned ? "Unpin" : "Pin";
    pin.addEventListener("click", () => act(app.pinned ? "/api/unpin" : "/api/pin", app.name));
    const evict = document.createElement("button");
    evict.type = "button";
    evict.textContent = "Evict";
    evict.addEventListener("click", () => act("/api/evict", app.name));
    actions.append(pin, evict);
    row.append(name, mode, cached, actions);
    apps.append(row);
  }
  if ((status.apps || []).length === 0) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 4;
    cell.textContent = status.appsError || "No offloaded apps.";
    row.append(cell);
    apps.append(row);
  }
  const sessions = status.sessions || {};
  const offloaded = sessions.offloaded || [];
  document.querySelector("#sessions-summary").textContent = `Cold after ${sessions.coldDays || 14} days. ${offloaded.length} offloaded.`;
  const list = document.querySelector("#sessions");
  list.replaceChildren();
  for (const entry of offloaded) {
    const item = document.createElement("li");
    item.textContent = `${entry.tier} · ${entry.tool} · ${entry.path}`;
    list.append(item);
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
refresh();
