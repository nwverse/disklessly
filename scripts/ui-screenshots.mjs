// Headless checks and screenshots of the loopback page against static fixtures.
// Serves Sources/isenough/web and fixture /api/* from a node server on 127.0.0.1.
// The page token picks the fixture (main, near, critical, empty, degraded, offline,
// error, slow, expired), so the same server works for any browser.
//
//   npm install --prefix /tmp/isenough-ui-shot playwright
//   npx --prefix /tmp/isenough-ui-shot playwright install chromium
//   NODE_PATH=/tmp/isenough-ui-shot/node_modules node scripts/ui-screenshots.mjs
//
//   node scripts/ui-screenshots.mjs --serve [port]   # keep the fixture server running
//
// Without playwright the script still checks the zh and en text tables, then stops.
// UI_SHOT_DIR picks the output folder.

import http from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const webRoot = path.join(repoRoot, "Sources/isenough/web");
const outDir = process.env.UI_SHOT_DIR || path.join(repoRoot, ".build/ui-screenshots");
const GiB = 1024 ** 3;
const MiB = 1024 ** 2;
const cjk = /[㐀-鿿]/;

async function checkKeyParity() {
  const source = await readFile(path.join(webRoot, "app.js"), "utf8");
  const start = source.indexOf("// i18n:begin");
  const end = source.indexOf("// i18n:end");
  if (start < 0 || end < 0) throw new Error("app.js lost its i18n markers");
  const block = source.slice(source.indexOf("\n", start), end);
  const copy = vm.runInNewContext(`${block}\ncopy`, { relativeTime: () => "" });
  const zh = new Set(Object.keys(copy.zh));
  const en = new Set(Object.keys(copy.en));
  const onlyZh = [...zh].filter((key) => !en.has(key));
  const onlyEn = [...en].filter((key) => !zh.has(key));
  if (onlyZh.length || onlyEn.length) {
    throw new Error(`i18n key mismatch. only zh: ${onlyZh.join(", ") || "-"}; only en: ${onlyEn.join(", ") || "-"}`);
  }
  for (const key of en) {
    if (typeof copy.en[key] !== typeof copy.zh[key]) throw new Error(`i18n key ${key} is a ${typeof copy.zh[key]} in zh and a ${typeof copy.en[key]} in en`);
    const text = typeof copy.en[key] === "function" ? copy.en[key](1, 1, "1 GiB", 1) : copy.en[key];
    if (cjk.test(String(text))) throw new Error(`en text for ${key} contains Chinese: ${text}`);
  }
  if (/\/Applications…|\/Applications for good/.test(source.replace(/\$\{dir\}/g, ""))) throw new Error("unpack label hard-codes /Applications");
  console.log(`i18n: zh and en share ${en.size} keys`);
}

// ---- fixtures -------------------------------------------------------------

const daysAgo = (n) => new Date(Date.now() - n * 86400000).toISOString();

function backend(health) {
  const offline = health === "offline";
  return {
    kind: "smb",
    location: "remote",
    activeId: "nas-studio",
    activePlace: "nas.local/apps",
    repoPath: "/Volumes/apps/256isenough",
    health,
    healthDetail: offline ? "timeout" : health === "missing" ? "repo.json is not in the backend" : "",
    timedOut: offline,
    timeoutMs: 5000,
    latencyMs: offline ? undefined : health === "degraded" ? 680 : 42,
    checkedAt: new Date().toISOString(),
    endpoints: [
      { id: "webdav-office", type: "webdav", place: "dav.example.lan/apps", state: "standby" },
      { id: "nas-studio", type: "smb", place: "nas.local/apps", state: "active" },
      { id: "usb-archive", type: "local", place: "/Volumes/Archive/256isenough", state: "local" },
    ],
  };
}

function cache(usedGiB) {
  const quota = 64 * GiB;
  const used = usedGiB * GiB;
  const diskFree = 49.6 * GiB;
  const floor = 8 * GiB;
  const reach = used + diskFree - floor;
  return {
    usedBytes: used,
    quotaBytes: quota,
    minFreeBytes: floor,
    detachDelaySeconds: 30,
    quotaLeftBytes: Math.max(0, quota - used),
    diskFreeBytes: diskFree,
    ...(reach < quota ? { floorMarkerBytes: Math.max(0, reach) } : {}),
    level: usedGiB / 64 >= 0.95 ? "critical" : usedGiB / 64 >= 0.8 ? "near" : "ok",
  };
}

const apps = [
  { name: "Blender Studio", imageId: "", version: "4.2.1", mode: "mount", pinned: true, cached: true, remote: false, restored: false, state: "", mounted: false, cachedBytes: 3.1 * GiB, imageBytes: 3.1 * GiB, lastUsed: daysAgo(0.2), bundleId: "org.blender.studio", installPath: "/Applications/Blender Studio.app", devices: ["Studio Mini"] },
  { name: "Krita", imageId: "", version: "5.2.3", mode: "restore", pinned: false, cached: true, remote: false, restored: false, state: "running", mounted: true, cachedBytes: 1.4 * GiB, imageBytes: 1.4 * GiB, lastUsed: daysAgo(1), bundleId: "org.kde.krita", installPath: "/Users/me/Applications/Krita.app" },
  { name: "Logic Pro", imageId: "", version: "11.0.1", mode: "restore", pinned: false, cached: false, remote: true, restored: false, state: "", cachedBytes: 0, imageBytes: 1.2 * GiB, lastUsed: daysAgo(40), bundleId: "com.apple.logic10", installPath: "/Applications/Logic Pro.app" },
  { name: "Reaper", imageId: "", version: "4.8.0", mode: "mount", pinned: false, cached: false, remote: true, restored: true, state: "needsResolution", needsResolution: true, cachedBytes: 0, imageBytes: 640 * MiB, bundleId: "com.cockos.reaper", installPath: "/Applications/Reaper.app" },
];

function status({ usedGiB = 12.4, health = "ok", list = apps, appsError = "" } = {}) {
  return {
    ok: true,
    backend: backend(health),
    cache: cache(usedGiB),
    apps: list,
    appsError,
    jobs: [],
    devices: list.length ? [{ deviceId: "a", displayName: "Studio", hostname: "studio.local", arch: "arm64", osVersion: "15.1", self: true, images: [] }] : [],
    devicePlaceholders: [],
    deviceConflicts: [],
    sessions: {
      coldDays: 14,
      offloaded: list.length
        ? [
            { id: "a", tool: "Blender", path: "~/Projects/teaser/scene_03.blend", preview: "", tier: "cold", ageDays: 21, modified: daysAgo(21) },
            { id: "b", tool: "Krita", path: "~/Art/poster-v4.kra", preview: "", tier: "cold", ageDays: 18, modified: daysAgo(18) },
            { id: "c", tool: "Reaper", path: "~/Music/session-jan.rpp", preview: "", tier: "warm", ageDays: 3, modified: daysAgo(3) },
          ]
        : [],
    },
    generatedAt: new Date().toISOString(),
  };
}

const fixtures = {
  main: () => status(),
  near: () => status({ usedGiB: 55 }),
  critical: () => status({ usedGiB: 62.1 }),
  empty: () => status({ usedGiB: 0.2, list: [] }),
  degraded: () => status({ health: "degraded" }),
  offline: () => status({ health: "offline", list: [], appsError: "Backend unavailable: smb://nas.local/apps did not answer within 5 s" }),
};

const recommend = {
  ok: true,
  scan: "ok",
  detail: "",
  minSizeBytes: 500 * MiB,
  estimatedFreedBytes: 9.6 * GiB,
  scannedAt: new Date(Date.now() - 12 * 60000).toISOString(),
  recommendations: [
    { name: "Final Cut Pro", path: "/Applications/Final Cut Pro.app", bundleId: "com.apple.FinalCut", sizeBytes: 6.1 * GiB, daysIdle: 92, macAppStore: true, suggestedMode: "restore", warnings: [] },
    { name: "Unity Hub", path: "/Applications/Unity Hub.app", bundleId: "com.unity3d.unityhub", sizeBytes: 3.5 * GiB, neverUsed: true, suggestedMode: "mount", warnings: [] },
  ],
  warnings: [{ name: "Docker", path: "/Applications/Docker.app", bundleId: "com.docker.docker", sizeBytes: 2 * GiB, suggestedMode: "skip", warnings: ["loginItem", "backgroundHelper"] }],
  leftoverBackups: [],
};

// ---- fixture server -------------------------------------------------------

function startServer(port = 0) {
  const jobs = new Map();
  const log = [];
  const hits = new Map();
  const server = http.createServer(async (request, response) => {
    const target = new URL(request.url, "http://127.0.0.1");
    const fixture = target.searchParams.get("token") || (request.headers.authorization || "").replace(/^Bearer /, "") || "main";
    const json = (code, body) => {
      response.writeHead(code, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      response.end(JSON.stringify(body));
    };
    if (!target.pathname.startsWith("/api/")) {
      const name = { "/": "index.html", "/index.html": "index.html", "/app.js": "app.js", "/style.css": "style.css" }[target.pathname];
      if (!name) return json(404, { ok: false });
      const body = await readFile(path.join(webRoot, name));
      const type = name.endsWith(".html") ? "text/html; charset=utf-8" : name.endsWith(".js") ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8";
      response.writeHead(200, { "Content-Type": type, "Cache-Control": "no-store" });
      return response.end(body);
    }
    if (fixture === "expired") return json(401, { ok: false, error: { code: "unauthorized", message: "The page token is missing or expired." } });
    if (target.pathname === "/api/status") {
      const count = (hits.get(fixture) || 0) + 1;
      hits.set(fixture, count);
      // Hang so the page stays on its loading state; unref so the timer never keeps node alive.
      if (fixture === "slow") await new Promise((resolve) => setTimeout(resolve, 600000).unref());
      // error: the first call fails, Retry succeeds.
      if (fixture === "error" && count === 1) return json(503, { ok: false, error: { code: "offline", message: "connect ECONNREFUSED nas.local:445" } });
      if (fixture === "down") return json(503, { ok: false, error: { code: "offline", message: "connect ECONNREFUSED nas.local:445" } });
      return json(200, (fixtures[fixture] || fixtures.main)());
    }
    if (target.pathname === "/api/health") return json(200, { ok: true, ...backend(fixture === "offline" ? "offline" : "ok") });
    if (target.pathname === "/api/recommend") return json(200, { ...recommend, cached: !target.searchParams.get("rescan") });
    if (target.pathname.startsWith("/api/icon/")) return json(404, { ok: false });
    if (target.pathname.startsWith("/api/jobs/")) {
      const id = target.pathname.split("/").pop();
      const job = jobs.get(id);
      if (!job) return json(404, { ok: false, error: { code: "unknown_job", message: "no job" } });
      job.polls += 1;
      const done = job.polls >= 2;
      const fails = job.app === "Logic Pro";
      return json(200, { ok: true, id, kind: job.kind, app: job.app, state: done ? (fails ? "failed" : "done") : "running", phase: done ? "open" : "download", ...(done && fails ? { error: { code: "offline", message: "SMB share is not mounted (nas.local/apps)" } } : {}) });
    }
    if (request.method === "POST") {
      let raw = "";
      for await (const chunk of request) raw += chunk;
      const kind = target.pathname.replace("/api/", "");
      const body = JSON.parse(raw || "{}");
      log.push(`${kind}:${body.app}${body.force ? ":force" : ""}`);
      const id = `job-${log.length}`;
      jobs.set(id, { kind, app: body.app, polls: 0 });
      return json(202, { ok: true, jobId: id, id, kind, app: body.app, state: "running", phase: "queued" });
    }
    return json(404, { ok: false, error: { code: "failed", message: "not found" } });
  });
  return new Promise((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve({ server, port: server.address().port, log, hits }));
  });
}

// ---- screenshots ----------------------------------------------------------

async function main() {
  await checkKeyParity();
  const serveIndex = process.argv.indexOf("--serve");
  if (serveIndex >= 0) {
    const { port } = await startServer(Number(process.argv[serveIndex + 1] || 0));
    console.log(`fixture server: http://127.0.0.1:${port}/?token=main  (tokens: ${[...Object.keys(fixtures), "error", "down", "slow", "expired"].join(", ")})`);
    return;
  }
  let chromium;
  try {
    ({ chromium } = require("playwright"));
  } catch (error) {
    console.log("playwright is not installed; skipped screenshots (see the header of this script)");
    return;
  }
  await mkdir(outDir, { recursive: true });
  const fixtureServer = await startServer();
  const browser = await chromium.launch({ headless: true });
  const shots = [];
  const origin = `http://127.0.0.1:${fixtureServer.port}`;
  const desktop = { width: 1194, height: 900 };
  const phone = { width: 375, height: 812 };

  async function open(name, { fixture = "main", theme = "light", viewport = desktop, query = "", wait = "networkidle" } = {}) {
    const context = await browser.newContext({ locale: "zh-CN", viewport, colorScheme: theme === "dark" ? "dark" : "light" });
    const page = await context.newPage();
    const leaks = [];
    const warnings = [];
    page.on("request", (request) => {
      if (new URL(request.url()).hostname !== "127.0.0.1") leaks.push(request.url());
    });
    page.on("console", (message) => {
      if (message.type() === "warning" || message.type() === "error") warnings.push(message.text());
    });
    page.on("pageerror", (error) => warnings.push(String(error)));
    await page.goto(`${origin}/?token=${fixture}${query}`, { waitUntil: wait });
    if (leaks.length) throw new Error(`${name} left the loopback host: ${leaks.join(", ")}`);
    const shoot = async (suffix = "", full = true) => {
      const file = path.join(outDir, `${name}${suffix}.png`);
      await page.screenshot({ path: file, fullPage: full });
      shots.push(file);
    };
    const finish = async () => {
      const missing = warnings.filter((text) => text.includes("missing"));
      if (missing.length) throw new Error(`${name}: ${missing.join("; ")}`);
      const errors = warnings.filter((text) => !text.includes("401") && !text.includes("503") && !text.includes("404") && !text.includes("Failed to load resource"));
      if (errors.length) throw new Error(`${name} logged: ${errors.join("; ")}`);
      await context.close();
    };
    return { page, shoot, finish };
  }

  const expectText = async (page, text) => page.waitForSelector(`text=${text}`, { timeout: 5000 });

  try {
    for (const theme of ["light", "dark"]) {
      for (const [viewport, width] of [[desktop, 1194], [phone, 375]]) {
        const view = await open(`main-${theme}-${width}`, { theme, viewport });
        const { page } = view;
        await expectText(page, "运行正常");
        await expectText(page, "Healthy · 延迟 42 ms");
        await expectText(page, "空间充足");
        await expectText(page, "Plenty of room");
        await expectText(page, "已卸载应用");
        await expectText(page, "Offloaded apps");
        await expectText(page, "会话分层");
        if ((await page.getAttribute("html", "lang")) !== "zh-Hans") throw new Error("primary language is not zh-Hans");
        // Endpoint states, one active pill.
        if ((await page.locator(".endpoint.is-active").count()) !== 1) throw new Error("expected one active endpoint");
        // Floor marker sits where cache growth would push free disk below the floor: 12.4 + 49.6 - 8 = 54 GiB of 64.
        const left = await page.locator(".floor-marker").evaluate((node) => parseFloat(node.style.left));
        if (Math.abs(left - (54 / 64) * 100) > 0.5) throw new Error(`floor marker at ${left}%`);
        // Unpack label uses the app's own folder, not a fixed /Applications.
        const pinned = page.locator(".app-row", { has: page.locator("h3", { hasText: "Blender Studio" }) });
        const evict = pinned.locator("button", { hasText: "清除缓存" });
        if ((await evict.getAttribute("aria-disabled")) !== "true") throw new Error("pinned app's Evict is not disabled");
        if (!(await evict.getAttribute("title")).includes("取消固定")) throw new Error("pinned Evict lacks its tooltip");
        if (width === 375) {
          const button = pinned.locator("button.btn").nth(1);
          const box = await button.boundingBox();
          if (!box || box.height < 44) throw new Error(`mobile action button is ${box && box.height}px`);
          const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
          if (overflow > 1) throw new Error(`375 px layout scrolls sideways by ${overflow}px`);
        }
        await view.shoot();
        await view.finish();
      }
    }

    // Actions: confirm for evict, pinned refusal, row-scoped pending state, localized error toast with raw details.
    const act = await open("actions-light-1194");
    const { page } = act;
    const krita = page.locator(".app-row", { has: page.locator("h3", { hasText: "Krita" }) });
    const blender = page.locator(".app-row", { has: page.locator("h3", { hasText: "Blender Studio" }) });
    await blender.locator("button", { hasText: "清除缓存" }).click({ force: true });
    if (await page.locator("#confirm").isVisible()) throw new Error("pinned Evict opened the confirm dialog");
    // Krita is mounted: blocked as well.
    if ((await krita.locator("button", { hasText: "清除缓存" }).getAttribute("aria-disabled")) !== "true") throw new Error("mounted app's Evict is not disabled");
    await blender.getByRole("button", { name: /取消固定/ }).click();
    await page.waitForSelector("#toasts >> text=Blender Studio：取消固定完成");
    if (fixtureServer.log.at(-1) !== "unpin:Blender Studio") throw new Error(`expected unpin, got ${fixtureServer.log.join(", ")}`);

    const logic = page.locator(".app-row", { has: page.locator("h3", { hasText: "Logic Pro" }) });
    await logic.getByRole("button", { name: /打开 Logic Pro/ }).click();
    await page.waitForSelector(".app-row button[aria-busy='true']");
    const busyRows = await page.locator(".app-row[aria-busy='true']").count();
    if (busyRows !== 1) throw new Error(`pending state should be row-scoped, ${busyRows} rows are busy`);
    await page.waitForSelector("#toasts >> text=Logic Pro：打开失败");
    const failure = page.locator("#toasts .toast.error").last();
    const visible = await failure.innerText();
    if (!visible.includes("连不上仓库")) throw new Error(`error code was not localized: ${visible}`);
    if (await failure.locator("details code").isVisible()) throw new Error("raw server text is not folded");
    await failure.locator("summary").click();
    if (!(await failure.locator("details code").innerText()).includes("SMB share is not mounted")) throw new Error("raw detail missing");
    await act.shoot("-toast", false);

    await logic.getByRole("button", { name: /Logic Pro 的更多操作/ }).click();
    const unpack = page.getByRole("menuitem", { name: /永久还原到 \/Applications/ });
    await unpack.waitFor();
    await unpack.click();
    const dialog = page.locator("#confirm");
    await dialog.waitFor({ state: "visible" });
    if (!(await dialog.innerText()).includes("/Applications/Logic Pro.app")) throw new Error("unpack confirm lacks the install path");
    await act.shoot("-confirm", false);
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "hidden" });
    if (fixtureServer.log.some((line) => line.startsWith("unpack"))) throw new Error("escape still started unpack");
    await krita.getByRole("button", { name: /Krita 的更多操作/ }).click();
    await page.getByRole("menuitem", { name: /永久还原到 ~\/Applications/ }).waitFor();
    await page.keyboard.press("Escape");
    await act.finish();

    // Near quota and critical.
    for (const fixture of ["near", "critical"]) {
      const view = await open(`${fixture}-light-1194`, { fixture });
      await expectText(view.page, fixture === "near" ? "接近配额" : "配额将满");
      await expectText(view.page, "低于空闲下限时自动清除未固定的缓存");
      await view.shoot("", false);
      await view.finish();
    }

    // Degraded health.
    const slowBackend = await open("degraded-dark-1194", { fixture: "degraded", theme: "dark" });
    await expectText(slowBackend.page, "Degraded · 延迟 680 ms");
    await slowBackend.shoot("", false);
    await slowBackend.finish();

    // Offline: backend card red, Error panel with endpoint and timeout, Retry.
    const offline = await open("offline-light-1194", { fixture: "offline" });
    await expectText(offline.page, "无法连接后端");
    await expectText(offline.page, "Backend unreachable");
    await expectText(offline.page, "超时 5 s");
    const banner = await offline.page.locator("#banner").innerText();
    if (banner.includes("did not answer")) throw new Error("banner shows raw server text inline");
    await offline.shoot("", false);
    await offline.finish();

    // Empty repo: onboarding and the empty state.
    const empty = await open("empty-light-1194", { fixture: "empty" });
    await expectText(empty.page, "暂无已卸载应用");
    await empty.page.locator("#onboarding").waitFor({ state: "visible" });
    if (await empty.page.locator("#devices-section").getAttribute("open") !== null) throw new Error("empty Devices section is expanded");
    await empty.shoot();
    await empty.finish();

    // Loading skeleton while /api/status hangs.
    const loading = await open("loading-light-1194", { fixture: "slow", wait: "domcontentloaded" });
    await expectText(loading.page, "正在读取后端…");
    await loading.shoot("", false);
    await loading.page.close();

    // English first on request.
    const english = await open("en-light-1194", { query: "&lang=en" });
    await expectText(english.page, "Healthy");
    if ((await english.page.getAttribute("html", "lang")) !== "en") throw new Error("?lang=en did not put English first");
    await english.shoot("", false);
    await english.finish();

    const expired = await open("expired-light-1194", { fixture: "expired" });
    await expired.page.locator("#expired").waitFor({ state: "visible" });
    await expectText(expired.page, "链接已失效");
    await expired.shoot("", false);
    await expired.finish();

    // First status call fails; Retry recovers.
    const error = await open("error-dark-375", { fixture: "error", theme: "dark", viewport: phone });
    await error.page.locator("#banner").waitFor({ state: "visible" });
    await expectText(error.page, "无法连接后端");
    await error.shoot();
    await error.page.locator(".state-error button").click();
    await expectText(error.page, "运行正常");
    if ((await error.page.locator("#banner").getAttribute("hidden")) === null) throw new Error("retry left the error banner visible");
    await error.finish();
  } finally {
    await browser.close();
    // The "slow" fixture leaves a request hanging on purpose; drop it so the process exits.
    fixtureServer.server.closeAllConnections();
    fixtureServer.server.close();
  }
  await writeFile(path.join(outDir, "index.json"), JSON.stringify(shots, null, 2));
  console.log(shots.join("\n"));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
