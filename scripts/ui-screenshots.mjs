// Headless checks and screenshots of the loopback page against static fixtures.
// Serves Sources/isenough/web and stubs /api/*. No request leaves 127.0.0.1.
//
//   npm install --prefix /tmp/isenough-ui-shot playwright
//   npx --prefix /tmp/isenough-ui-shot playwright install chromium
//   NODE_PATH=/tmp/isenough-ui-shot/node_modules node scripts/ui-screenshots.mjs
//
// Without playwright the script still checks that the zh and en text tables have
// the same keys, then stops. UI_SHOT_DIR picks the output folder.

import { spawn } from "node:child_process";
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
const quota = 20 * GiB;
const cjk = /[㐀-鿿]/;

async function checkKeyParity() {
  const source = await readFile(path.join(webRoot, "app.js"), "utf8");
  const start = source.indexOf("// i18n:begin");
  const end = source.indexOf("// i18n:end");
  if (start < 0 || end < 0) throw new Error("app.js lost its i18n markers");
  const block = source.slice(source.indexOf("\n", start), end);
  const copy = vm.runInNewContext(`${block}\ncopy`, {});
  const zh = new Set(Object.keys(copy.zh));
  const en = new Set(Object.keys(copy.en));
  const onlyZh = [...zh].filter((key) => !en.has(key));
  const onlyEn = [...en].filter((key) => !zh.has(key));
  if (onlyZh.length || onlyEn.length) {
    throw new Error(`i18n key mismatch. only zh: ${onlyZh.join(", ") || "-"}; only en: ${onlyEn.join(", ") || "-"}`);
  }
  for (const key of en) {
    if (typeof copy.en[key] !== typeof copy.zh[key]) throw new Error(`i18n key ${key} is a ${typeof copy.zh[key]} in zh and a ${typeof copy.en[key]} in en`);
    if (typeof copy.en[key] === "string" && cjk.test(copy.en[key]) && !key.startsWith("lang")) throw new Error(`en text for ${key} contains Chinese: ${copy.en[key]}`);
  }
  console.log(`i18n: zh and en share ${en.size} keys`);
}

function status({ usedRatio, health, apps, appsError, jobs }) {
  return {
    ok: true,
    backend: {
      kind: "smb",
      activeId: "nas",
      repoPath: "/Volumes/apps/256isenough",
      health,
      healthDetail: health === "missing" ? "repo.json is not in the backend" : "",
      endpoints: [
        { id: "nas", type: "smb", host: "nas.local", mountPoint: "/Volumes/apps", url: "" },
        { id: "cloud", type: "icloud", host: "", mountPoint: "", url: "" },
      ],
    },
    cache: { usedBytes: Math.round(usedRatio * quota), quotaBytes: quota, minFreeBytes: 15 * GiB, detachDelaySeconds: 120 },
    apps,
    appsError: appsError || "",
    jobs: jobs || [],
    devices: apps.length
      ? [{ deviceId: "a", displayName: "Studio", hostname: "studio.local", arch: "arm64", osVersion: "15.1", self: true, images: [] }]
      : [],
    sessions: {
      coldDays: 14,
      offloaded: apps.length ? [{ id: "abc", tool: "pi", path: "/Users/me/.pi/agent/sessions/blender.jsonl", preview: "render farm queue", tier: "cold" }] : [],
    },
  };
}

const daysAgo = (n) => new Date(Date.now() - n * 86400000).toISOString();
const apps = [
  { name: "Blender", imageId: "", version: "4.2.0", mode: "mount", pinned: true, cached: true, remote: false, restored: false, state: "running", mounted: true, cachedBytes: 4.2 * GiB, imageBytes: 4.2 * GiB, lastUsed: daysAgo(0.1), bundleId: "org.blender.blender" },
  { name: "Logic Pro", imageId: "", version: "11.0.1", mode: "restore", pinned: false, cached: false, remote: true, restored: false, state: "", cachedBytes: 0, imageBytes: 1.2 * GiB, lastUsed: daysAgo(40), bundleId: "com.apple.logic10" },
  { name: "Comet", imageId: "", version: "1.4", mode: "mount", pinned: false, cached: true, remote: false, restored: true, state: "needsResolution", needsResolution: true, cachedBytes: 640 * MiB, imageBytes: 640 * MiB, bundleId: "dev.comet.app" },
];

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

const fixtures = {
  main: status({ usedRatio: 0.42, health: "ok", apps }),
  warn: status({ usedRatio: 0.86, health: "ok", apps }),
  empty: status({ usedRatio: 0.04, health: "ok", apps: [] }),
};

function startServer() {
  return new Promise((resolve, reject) => {
    const child = spawn("python3", ["-m", "http.server", "0", "--bind", "127.0.0.1"], {
      cwd: webRoot,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });
    let buffer = "";
    const timer = setTimeout(() => reject(new Error("fixture server did not print a port")), 8000);
    const onData = (chunk) => {
      buffer += chunk.toString();
      const match = buffer.match(/port (\d+)/);
      if (match) {
        clearTimeout(timer);
        resolve({ child, port: Number(match[1]) });
      }
    };
    child.stderr.on("data", onData);
    child.stdout.on("data", onData);
    child.on("exit", (code) => reject(new Error(`fixture server exited ${code}`)));
  });
}

/// Routes /api/* for one page. Jobs finish after two polls; evict and friends are logged.
async function routeApi(page, fixture) {
  const log = [];
  let statusHits = 0;
  const jobs = new Map();
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const target = new URL(request.url());
    const json = (status, body) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });
    if (fixture === "expired") return json(401, { ok: false, error: { code: "unauthorized", message: "The page token is missing or expired." } });
    if (target.pathname === "/api/status") {
      statusHits += 1;
      if (fixture === "error" && statusHits === 1) {
        return json(503, { ok: false, error: { code: "offline", message: "The repository did not respond." } });
      }
      return json(200, fixtures[fixture] || fixtures.main);
    }
    if (target.pathname === "/api/recommend") return json(200, { ...recommend, cached: !target.searchParams.get("rescan") });
    if (target.pathname.startsWith("/api/jobs/")) {
      const id = target.pathname.split("/").pop();
      const job = jobs.get(id);
      if (!job) return json(404, { ok: false, error: { code: "unknown_job", message: "no job" } });
      job.polls += 1;
      const done = job.polls >= 2;
      return json(200, { ok: true, id, kind: job.kind, app: job.app, state: done ? (job.app === "Logic Pro" ? "failed" : "done") : "running", phase: done ? "open" : "download", ...(done && job.app === "Logic Pro" ? { error: { code: "offline", message: "SMB share is not mounted" } } : {}) });
    }
    if (request.method() === "POST") {
      const kind = target.pathname.replace("/api/", "");
      const body = JSON.parse(request.postData() || "{}");
      log.push(`${kind}:${body.app}`);
      const id = `job-${log.length}`;
      jobs.set(id, { kind, app: body.app, polls: 0 });
      return json(202, { ok: true, jobId: id, id, kind, app: body.app, state: "running", phase: "queued" });
    }
    return json(404, { ok: false, error: { code: "failed", message: "not found" } });
  });
  return log;
}

async function main() {
  await checkKeyParity();
  let chromium;
  try {
    ({ chromium } = require("playwright"));
  } catch (error) {
    console.log("playwright is not installed; skipped screenshots (see the header of this script)");
    return;
  }
  await mkdir(outDir, { recursive: true });
  const server = await startServer();
  const browser = await chromium.launch({ headless: true });
  const shots = [];
  const origin = `http://127.0.0.1:${server.port}`;
  const desktop = { width: 1194, height: 900 };
  const phone = { width: 375, height: 812 };

  async function open(name, { fixture = "main", locale = "en-US", theme = "light", viewport = desktop, query = "" } = {}) {
    const context = await browser.newContext({ locale, viewport, colorScheme: theme === "dark" ? "dark" : "light" });
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
    const log = await routeApi(page, fixture);
    await page.goto(`${origin}/?token=fixture&theme=${theme}${query}`, { waitUntil: "networkidle" });
    if (leaks.length) throw new Error(`${name} left the loopback host: ${leaks.join(", ")}`);
    const shoot = async (suffix = "") => {
      const file = path.join(outDir, `${name}${suffix}.png`);
      await page.screenshot({ path: file, fullPage: true });
      shots.push(file);
    };
    const finish = async () => {
      const missing = warnings.filter((text) => text.includes("missing"));
      if (missing.length) throw new Error(`${name}: ${missing.join("; ")}`);
      const errors = warnings.filter((text) => !text.includes("401") && !text.includes("503") && !text.includes("Failed to load resource"));
      if (errors.length) throw new Error(`${name} logged: ${errors.join("; ")}`);
      await context.close();
    };
    return { page, log, shoot, finish };
  }

  try {
    // Language follows navigator.languages: en-US gets English with no Chinese anywhere.
    for (const theme of ["light", "dark"]) {
      const en = await open(`en-${theme}-1194`, { locale: "en-US", theme });
      await en.page.waitForSelector("text=Running OK");
      if ((await en.page.getAttribute("html", "lang")) !== "en") throw new Error("en-US browser did not get lang=en");
      const text = await en.page.locator("body").innerText();
      const chinese = text.split("\n").filter((line) => cjk.test(line) && line.trim() !== "中文");
      if (chinese.length) throw new Error(`en page shows Chinese: ${chinese.join(" | ")}`);
      await en.page.waitForSelector("text=Could free about 9.6 GiB");
      await en.page.waitForSelector("text=Remote · 1.2 GiB to download");
      await en.page.waitForSelector(".chip.attention");
      await en.page.waitForSelector(".chip.mounted");
      const meta = await en.page.locator("#app-list .meta").allInnerTexts();
      if (meta.some((line) => line.startsWith(" ·") || line.startsWith("·"))) throw new Error(`meta line starts with a separator: ${meta.join(" | ")}`);
      await en.shoot();
      await en.finish();

      const zh = await open(`zh-${theme}-1194`, { locale: "zh-CN", theme });
      await zh.page.waitForSelector("text=运行正常");
      if ((await zh.page.getAttribute("html", "lang")) !== "zh-Hans") throw new Error("zh-CN browser did not get lang=zh-Hans");
      await zh.page.waitForSelector("text=远端 · 需下载 1.2 GiB");
      await zh.shoot();
      await zh.finish();
    }

    for (const [locale, prefix] of [["en-US", "en"], ["zh-CN", "zh"]]) {
      const mobile = await open(`${prefix}-light-375`, { locale, viewport: phone });
      const button = mobile.page.locator(".app").first().locator("button.action").first();
      const box = await button.boundingBox();
      if (!box || box.height < 44) throw new Error(`mobile action button is ${box && box.height}px`);
      if (!(await button.locator(".btn-label").isVisible())) throw new Error("mobile action label is hidden");
      await mobile.shoot();
      await mobile.finish();
    }

    // Actions: confirm dialog for evict, row-scoped pending state, toast results.
    const act = await open("actions-en-light-1194", { locale: "en-US" });
    const { page } = act;
    const blender = page.locator(".app", { has: page.locator("h3", { hasText: "Blender" }) });
    await blender.getByRole("button", { name: "Evict cache" }).click();
    const dialog = page.locator("#confirm");
    await dialog.waitFor({ state: "visible" });
    await act.shoot("-confirm");
    await page.getByRole("button", { name: "Cancel" }).click();
    await dialog.waitFor({ state: "hidden" });
    if (act.log.length) throw new Error(`cancel still sent ${act.log.join(", ")}`);
    await blender.getByRole("button", { name: "Evict cache" }).click();
    await dialog.getByRole("button", { name: "Evict cache" }).click();
    await page.waitForSelector("#toasts >> text=Blender: evict finished");
    if (act.log[0] !== "evict:Blender") throw new Error(`expected evict:Blender, got ${act.log.join(", ")}`);

    const logic = page.locator(".app", { has: page.locator("h3", { hasText: "Logic Pro" }) });
    await logic.getByRole("button", { name: "Open Logic Pro" }).click();
    await page.waitForSelector(".app button[aria-busy='true']");
    const busyRows = await page.locator(".app[aria-busy='true']").count();
    if (busyRows !== 1) throw new Error(`pending state should be row-scoped, ${busyRows} rows are busy`);
    if (await blender.getByRole("button", { name: "Open Blender" }).isDisabled()) throw new Error("another row was disabled by a pending job");
    await page.waitForSelector("#toasts >> text=Logic Pro: open failed");
    const failure = await page.locator("#toasts .toast.error").last().innerText();
    if (!failure.includes("repository is unreachable")) throw new Error(`error code was not localized: ${failure}`);

    await logic.getByRole("button", { name: /More actions/ }).click();
    await page.getByRole("menuitem", { name: /for good/ }).click();
    await dialog.waitFor({ state: "visible" });
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "hidden" });
    if (act.log.some((line) => line.startsWith("unpack"))) throw new Error("escape still started unpack");

    await page.getByRole("radio", { name: "Dark" }).click();
    if ((await page.getAttribute("html", "data-theme")) !== "dark") throw new Error("theme radio did not switch to dark");
    if ((await page.getByRole("radio", { name: "Dark" }).getAttribute("aria-checked")) !== "true") throw new Error("aria-checked not updated");
    await page.getByRole("button", { name: "Switch the page to Chinese" }).click();
    await page.waitForSelector("text=清除缓存");
    await act.finish();

    // Onboarding on an empty repo; Devices and Sessions collapse.
    for (const [locale, prefix] of [["en-US", "en"], ["zh-CN", "zh"]]) {
      const empty = await open(`empty-${prefix}-light-1194`, { locale, fixture: "empty" });
      await empty.page.locator("#onboarding").waitFor({ state: "visible" });
      if (await empty.page.locator("#devices-section").getAttribute("open") !== null) throw new Error("empty Devices section is expanded");
      if (await empty.page.locator("#sessions-section").getAttribute("open") !== null) throw new Error("empty Sessions section is expanded");
      await empty.shoot();
      await empty.finish();
    }

    const expired = await open("expired-en-light-1194", { fixture: "expired" });
    await expired.page.locator("#expired").waitFor({ state: "visible" });
    await expired.page.waitForSelector("text=This link has expired");
    await expired.shoot();
    await expired.finish();

    const error = await open("error-zh-dark-375", { fixture: "error", locale: "zh-CN", theme: "dark", viewport: phone });
    const banner = error.page.locator("#banner");
    await banner.waitFor({ state: "visible" });
    const retry = error.page.getByRole("button", { name: "重试" });
    const retryBox = await retry.boundingBox();
    if (!retryBox || retryBox.height < 44) throw new Error(`retry button is ${retryBox && retryBox.height}px`);
    await error.shoot();
    await retry.click();
    await error.page.waitForSelector("text=运行正常");
    if ((await banner.getAttribute("hidden")) === null) throw new Error("retry left the error banner visible");
    await error.finish();
  } finally {
    await browser.close();
    server.child.kill("SIGTERM");
  }
  await writeFile(path.join(outDir, "index.json"), JSON.stringify(shots, null, 2));
  console.log(shots.join("\n"));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
