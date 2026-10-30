// Headless screenshots of the loopback page against static fixtures.
// Serves Sources/isenough/web and stubs /api/status. No browser leaves 127.0.0.1.
//
//   npm install --prefix /tmp/isenough-ui-shot playwright
//   npx --prefix /tmp/isenough-ui-shot playwright install chromium
//   NODE_PATH=/tmp/isenough-ui-shot/node_modules node scripts/ui-screenshots.mjs

import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../Sources/isenough/web");
const outDir = process.env.UI_SHOT_DIR || "/opt/cursor/artifacts/screenshots";
const GiB = 1024 ** 3;
const quota = 20 * GiB;

function status({ usedRatio, health, apps, appsError, endpoints }) {
  return {
    ok: true,
    backend: {
      kind: "smb",
      activeId: "nas",
      repoPath: "/Volumes/apps/256isenough",
      health,
      healthDetail: health === "missing" ? "repo.json is not in the backend" : "",
      endpoints: endpoints || [
        { id: "nas", type: "smb", host: "nas.local", mountPoint: "/Volumes/apps", url: "" },
        { id: "cloud", type: "icloud", host: "", mountPoint: "", url: "" },
      ],
    },
    cache: {
      usedBytes: Math.round(usedRatio * quota),
      quotaBytes: quota,
      minFreeBytes: 15 * GiB,
      detachDelaySeconds: 120,
    },
    apps,
    appsError: appsError || "",
    sessions: {
      coldDays: 14,
      offloaded: apps.length
        ? [{ id: "abc", tool: "pi", path: "/Users/me/.pi/agent/sessions/blender.jsonl", preview: "渲染农场排队", tier: "cold" }]
        : [],
    },
  };
}

const apps = [
  { name: "Blender", version: "4.2.0", mode: "mount", pinned: true, cached: true, remote: false, restored: false, cachedBytes: 4.2 * GiB, bundleId: "org.blender.blender" },
  { name: "Logic Pro", version: "11.0.1", mode: "restore", pinned: false, cached: false, remote: true, restored: true, cachedBytes: 0, bundleId: "com.apple.logic10" },
  { name: "Comet", version: "1.4", mode: "mount", pinned: false, cached: true, remote: false, restored: false, cachedBytes: 1.1 * GiB, bundleId: "dev.comet.app" },
];

const fixtures = {
  main: status({ usedRatio: 0.42, health: "ok", apps }),
  warn: status({ usedRatio: 0.86, health: "ok", apps }),
  hot: status({ usedRatio: 0.97, health: "ok", apps }),
  empty: status({ usedRatio: 0.04, health: "missing", apps: [] }),
  error: null,
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

async function shoot(page, name) {
  const file = path.join(outDir, `${name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  return file;
}

async function openFixture(page, origin, fixture, { theme, width, height }) {
  let hits = 0;
  await page.unroute("**/api/**").catch(() => {});
  await page.route("**/api/**", async (route) => {
    hits += 1;
    const target = new URL(route.request().url());
    if (target.pathname !== "/api/status") {
      await route.fulfill({ status: 404, contentType: "application/json", body: JSON.stringify({ ok: false, error: "not found" }) });
      return;
    }
    if (fixture === "error" && hits === 1) {
      await route.fulfill({
        status: 503,
        contentType: "application/json",
        body: JSON.stringify({ ok: false, error: "仓库没有响应。请检查 iCloud 的文件与文件夹权限后再试一次。The repository did not respond." }),
      });
      return;
    }
    const body = fixtures[fixture] || fixtures.main;
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
  await page.setViewportSize({ width, height });
  const leaks = [];
  page.on("request", (request) => {
    const target = new URL(request.url());
    if (target.hostname !== "127.0.0.1") leaks.push(request.url());
  });
  await page.goto(`${origin}/?token=fixture&theme=${theme}&lang=zh`, { waitUntil: "networkidle" });
  if (leaks.length) throw new Error(`page requested ${leaks.join(", ")}`);
  await page.waitForSelector("#cache-card .usage-value, #banner:not([hidden])");
  return { hits: () => hits };
}

async function main() {
  await mkdir(outDir, { recursive: true });
  const server = await startServer();
  const browser = await chromium.launch({ headless: true });
  const notes = [];
  try {
    const origin = `http://127.0.0.1:${server.port}`;
    const desktop = { width: 1194, height: 900 };
    const phone = { width: 375, height: 812 };
    const cases = [
      ["main-light-1194", "main", "light", desktop],
      ["main-dark-1194", "main", "dark", desktop],
      ["main-light-375", "main", "light", phone],
      ["main-dark-375", "main", "dark", phone],
      ["quota-86-light-1194", "warn", "light", desktop],
      ["quota-97-light-1194", "hot", "light", desktop],
      ["empty-light-1194", "empty", "light", desktop],
      ["error-light-1194", "error", "light", desktop],
      ["error-dark-375", "error", "dark", phone],
    ];
    for (const [name, fixture, theme, viewport] of cases) {
      const page = await browser.newPage();
      const traffic = [];
      page.on("request", (request) => {
        const host = new URL(request.url()).hostname;
        if (host !== "127.0.0.1") traffic.push(request.url());
      });
      await openFixture(page, origin, fixture, { theme, ...viewport });
      if (traffic.length) throw new Error(`${name} left the loopback host: ${traffic.join(", ")}`);
      if (fixture === "main" || fixture === "warn" || fixture === "hot") {
        await page.waitForSelector("text=运行正常");
      }
      if (fixture === "warn") {
        await page.waitForSelector("#cache-card[data-level='warn']");
        const text = await page.locator(".usage-value").innerText();
        if (text !== "86%") throw new Error(`expected 86%, got ${text}`);
      }
      if (fixture === "hot") {
        await page.waitForSelector("#cache-card[data-level='hot']");
        const text = await page.locator(".usage-value").innerText();
        if (text !== "97%") throw new Error(`expected 97%, got ${text}`);
      }
      if (fixture === "error") {
        const banner = page.locator("#banner");
        await banner.waitFor({ state: "visible" });
        const box = await banner.boundingBox();
        if (!box || box.width < (viewport.width === 1194 ? 800 : 300)) {
          throw new Error(`${name} error banner is too narrow (${box && box.width})`);
        }
        const retry = page.getByRole("button", { name: "重试" });
        const retryBox = await retry.boundingBox();
        if (!retryBox || retryBox.height < 44) throw new Error(`retry button is ${retryBox && retryBox.height}px`);
      }
      if (fixture === "empty") {
        await page.waitForSelector("text=还没有卸载到远端的应用");
        await page.waitForSelector("text=性能下降");
      }
      if (viewport.width === 375 && fixture === "main") {
        const button = page.locator(".app").first().locator("button").first();
        const box = await button.boundingBox();
        if (!box || box.height < 44) throw new Error(`mobile action button is ${box && box.height}px`);
        const label = await button.locator(".btn-label").innerText();
        if (!label.includes("固定")) throw new Error(`mobile button label missing: ${label}`);
        const evict = page.locator(".app", { hasText: "Logic Pro" }).getByRole("button", { name: /清除缓存/ });
        if (await evict.isEnabled()) throw new Error("evict should be disabled when the app is not cached");
      }
      const file = await shoot(page, name);
      notes.push(file);
      if (fixture === "main" && viewport.width === 1194 && theme === "light") {
        await page.getByRole("button", { name: "English" }).click();
        await page.waitForSelector("text=Evict cache");
        await page.getByRole("button", { name: "中文" }).click();
        await page.waitForSelector("text=清除缓存");
        await page.getByRole("button", { name: "浅色" }).click();
        const themeAttr = await page.locator("html").getAttribute("data-theme");
        if (themeAttr !== "dark") throw new Error(`theme toggle landed on ${themeAttr}`);
      }
      await page.close();
    }

    const page = await browser.newPage();
    await openFixture(page, origin, "error", { theme: "light", width: 1194, height: 900 });
    await page.getByRole("button", { name: "重试" }).click();
    await page.waitForSelector("text=运行正常");
    const hidden = await page.locator("#banner").getAttribute("hidden");
    if (hidden === null) throw new Error("retry left the error banner visible");
    await page.close();
  } finally {
    await browser.close();
    server.child.kill("SIGTERM");
  }
  await writeFile(path.join(outDir, "index.json"), JSON.stringify(notes, null, 2));
  console.log(notes.join("\n"));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
