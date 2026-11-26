// Headless checks and screenshots of the loopback page against static fixtures.
// Serves Sources/disklessly/web and fixture /api/* from a node server on 127.0.0.1.
// The page token picks the fixture (main, near, critical, empty, degraded, offline,
// error, slow, expired), so the same server works for any browser.
//
//   npm install --prefix /tmp/disklessly-ui-shot playwright
//   npx --prefix /tmp/disklessly-ui-shot playwright install chromium
//   NODE_PATH=/tmp/disklessly-ui-shot/node_modules node scripts/ui-screenshots.mjs
//
//   node scripts/ui-screenshots.mjs --serve [port]   # keep the fixture server running
//
// Without playwright the script still checks the zh and en text tables and the usage map math, then stops.
// UI_SHOT_ONLY=usage runs only the split usage map checks and screenshots.
// UI_SHOT_DIR picks the output folder.

import http from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const webRoot = path.join(repoRoot, "Sources/disklessly/web");
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

// The split usage map's layout and selection math lives between markers in app.js, so it is checked here
// without a browser: one scale for both sides, the 120 px clamp, the 45 % compression, the goal picker
// and the "what if" sums.
async function checkUsageMath() {
  const source = await readFile(path.join(webRoot, "app.js"), "utf8");
  const start = source.indexOf("// usage-math:begin");
  const end = source.indexOf("// usage-math:end");
  if (start < 0 || end < 0) throw new Error("app.js lost its usage-math markers");
  const block = source.slice(source.indexOf("\n", start), end);
  const m = vm.runInNewContext(`${block}\n({ usageScale, usageAgeStep, usagePickForGoal, usageWhatIf, usageTopPaths, usageNearest, usageRatioText })`, {});
  const fail = (what) => { throw new Error(`usage math: ${what}`); };
  const near = (a, b, tol = 1.5) => Math.abs(a - b) <= tol;
  // Equal pixels per byte on both sides.
  const even = m.usageScale({ width: 1024, height: 500, diskBytes: 300, cloudBytes: 100, hasCloud: true });
  if (even.compressed || even.clamped) fail("a 25 % cloud side is neither clamped nor compressed");
  if (!near(even.local.w + even.cloud.w, 1000)) fail(`widths ${even.local.w} + ${even.cloud.w} do not fill the row minus the channel`);
  if (!near((even.local.w * even.local.h) / 300, (even.cloud.w * even.cloud.h) / 100, 3)) fail("pixels per byte differ between the sides");
  // A thin cloud side keeps 120 px and gets shorter so its area stays true.
  const thin = m.usageScale({ width: 1024, height: 500, diskBytes: 1000, cloudBytes: 10, hasCloud: true });
  if (!thin.clamped || thin.cloud.w !== 120 || !(thin.cloud.h < 500)) fail(`clamp: ${JSON.stringify(thin)}`);
  if (!near((thin.local.w * thin.local.h) / 1000, (thin.cloud.w * thin.cloud.h) / 10, ((thin.local.w * thin.local.h) / 1000) * 0.03)) fail("the clamped side's area is not true");
  // Above 45 % it is compressed and says the ratio.
  const big = m.usageScale({ width: 1024, height: 500, diskBytes: 100, cloudBytes: 300, hasCloud: true });
  if (!big.compressed || !near(big.cloud.w, 1000 * 0.45) || !(big.ratio > 1)) fail(`compression: ${JSON.stringify(big)}`);
  const expected = (300 * ((big.local.w * 500) / 100)) / (big.cloud.w * 500);
  if (!near(big.ratio, expected, 0.05)) fail(`ratio ${big.ratio} != ${expected}`);
  if (m.usageRatioText(3.04) !== "3" || m.usageRatioText(2.46) !== "2.5" || m.usageRatioText(12.4) !== "12") fail("ratio text");
  // Stacked: the same rule on heights.
  const stacked = m.usageScale({ width: 375, height: 600, diskBytes: 300, cloudBytes: 100, hasCloud: true, stacked: true });
  if (stacked.local.w !== 375 || !near(stacked.local.h + stacked.cloud.h, 576)) fail(`stacked: ${JSON.stringify(stacked)}`);
  const none = m.usageScale({ width: 800, height: 400, diskBytes: 1, cloudBytes: 0, hasCloud: false });
  if (none.cloud || none.local.w !== 800) fail("without a cloud side the local map keeps the whole width");
  const empty = m.usageScale({ width: 800, height: 400, diskBytes: 1, cloudBytes: 0, hasCloud: true });
  if (!empty.empty || empty.cloud.w !== 120) fail("an empty cloud side keeps its minimum width for its message");
  // Age steps.
  const now = Date.UTC(2026, 0, 1);
  const ago = (days) => (now - days * 86400000) / 1000;
  if ([ago(1), ago(90), ago(300), ago(800), 0].map((s) => m.usageAgeStep(s, now)).join() !== "1,2,3,4,0") fail("age steps");
  // Goal: caches first, then bytes x age; it stops once the goal is met.
  const picks = m.usagePickForGoal([
    { key: "fresh-big", bytes: 50, ageDays: 1 },
    { key: "cold-mid", bytes: 20, ageDays: 400 },
    { key: "cache", bytes: 5, ageDays: 1, cache: true },
    { key: "warm", bytes: 10, ageDays: 60 },
  ], 22);
  if (picks.keys.join() !== "cache,cold-mid" || picks.bytes !== 25) fail(`goal picks ${JSON.stringify(picks)}`);
  if (m.usagePickForGoal([{ key: "a", bytes: 1, ageDays: 1 }], 0).keys.length) fail("a zero goal selects nothing");
  // Bytes count only up to what is missing: a colder box that covers the rest wins over a huge warm one,
  // and a pick the goal no longer needs is dropped.
  const capped = m.usagePickForGoal([{ key: "huge-warm", bytes: 100, ageDays: 20 }, { key: "cold-fits", bytes: 12, ageDays: 300 }], 10);
  if (capped.keys.join() !== "cold-fits") fail(`capped goal picks ${JSON.stringify(capped)}`);
  const pruned = m.usagePickForGoal([{ key: "cold-small", bytes: 15, ageDays: 900 }, { key: "warm-big", bytes: 25, ageDays: 10 }], 20);
  if (pruned.keys.join() !== "warm-big" || pruned.bytes !== 25) fail(`unneeded picks are dropped: ${JSON.stringify(pruned)}`);
  const kept = m.usagePickForGoal([{ key: "c1", bytes: 3, ageDays: 1, cache: true }, { key: "cold", bytes: 30, ageDays: 900 }], 20);
  if (kept.keys.join() !== "c1,cold") fail(`caches stay first: ${JSON.stringify(kept)}`);
  // What if: nested selections count once; only offloadable items move to the cloud.
  const what = m.usageWhatIf([
    { path: "/u/Movies", bytes: 40, canOffload: true },
    { path: "/u/Movies/Raw", bytes: 30, canOffload: true },
    { path: "/u/Library/Caches/x", bytes: 5, canOffload: false },
  ], 100);
  if (what.freed !== 45 || what.freeAfter !== 145 || what.incoming !== 40 || what.count !== 2) fail(`what if ${JSON.stringify(what)}`);
  if (m.usageTopPaths([{ path: "/a/b" }, { path: "/a/bc" }]).length !== 2) fail("a sibling with the same prefix is not inside");
  // Arrow keys go to the nearest box in that direction.
  const rects = [{ x: 0, y: 0, w: 10, h: 10 }, { x: 20, y: 0, w: 10, h: 10 }, { x: 0, y: 20, w: 10, h: 10 }, { x: 20, y: 25, w: 10, h: 10 }];
  if (m.usageNearest(rects, 0, "right") !== 1 || m.usageNearest(rects, 0, "down") !== 2 || m.usageNearest(rects, 0, "left") !== -1) fail("nearest box");
  console.log("usage math: scale, clamp, compression, age, goal, what-if and arrow checks pass");
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
    repoPath: "/Volumes/apps/Disklessly",
    health,
    healthDetail: offline ? "timeout" : health === "missing" ? "repo.json is not in the backend" : "",
    timedOut: offline,
    timeoutMs: 5000,
    latencyMs: offline ? undefined : health === "degraded" ? 680 : 42,
    checkedAt: new Date().toISOString(),
    endpoints: [
      { id: "webdav-office", type: "webdav", place: "dav.example.lan/apps", state: "standby" },
      { id: "nas-studio", type: "smb", place: "nas.local/apps", state: "active" },
      { id: "usb-archive", type: "local", place: "/Volumes/Archive/Disklessly", state: "local" },
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

function status({ usedGiB = 12.4, health = "ok", list = apps, appsError = "", appsErrorCode = "" } = {}) {
  return {
    ok: true,
    backend: backend(health),
    cache: cache(usedGiB),
    apps: list,
    appsError,
    appsErrorCode,
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
            { id: "c", tool: "Reaper", path: "~/Music/session-jan.rpp", preview: "", tier: "cold", ageDays: 15, modified: daysAgo(15) },
          ]
        : [],
    },
    generatedAt: new Date().toISOString(),
  };
}

// The disk usage map and its cloud side (a fixture tree; paths under /Users/me).
const secs = (days) => Math.round((Date.now() - days * 86400000) / 1000);
const dir = (name, gib, days, extra = {}) => ({ name, kind: "personal", bytes: gib * GiB, path: `/Users/me/${name}`, canTrash: true, modified: secs(days), ...extra });
function usageFixture() {
  const apps = [
    // Real scans put the file rule's refusal on apps too (they are outside ~); it must not block packing.
    { name: "Xcode", kind: "apps", bytes: 12 * GiB, path: "/Applications/Xcode.app", refusal: "is outside your home folder", canTrash: false, modified: secs(20), children: [{ name: "Xcode", key: "bundle", kind: "bundle", bytes: 12 * GiB, path: "/Applications/Xcode.app", canTrash: false }] },
    { name: "Final Cut Pro", kind: "apps", bytes: 6.1 * GiB, path: "/Applications/Final Cut Pro.app", refusal: "is outside your home folder", canTrash: false, modified: secs(200), children: [{ name: "Final Cut Pro", key: "bundle", kind: "bundle", bytes: 6.1 * GiB, path: "/Applications/Final Cut Pro.app", canTrash: false }] },
    { name: "Logic Pro", kind: "apps", bytes: 0.02 * GiB, path: "/Applications/Logic Pro.app", offloaded: true, canTrash: false, offloadedCount: 1, children: [{ name: "Logic Pro", key: "bundle", kind: "bundle", bytes: 0.02 * GiB, path: "/Applications/Logic Pro.app", offloaded: true, canTrash: false }] },
  ];
  const personal = [dir("Movies", 60, 500, { offloadedCount: 2 }), dir("code", 25, 3, { offloadedCount: 1 }), dir("Downloads", 14, 90), dir("Documents", 20, 10, { refusal: "is a standard folder", canTrash: false })];
  const library = [
    { name: "Caches", kind: "cache", bytes: 8 * GiB, path: "/Users/me/Library/Caches", canTrash: true, refusal: "holds caches apps rebuild", modified: secs(1) },
    { name: "Application Support", kind: "library", bytes: 22 * GiB, path: "/Users/me/Library/Application Support", canTrash: false, refusal: "is app data", modified: secs(2) },
  ];
  const sum = (list) => list.reduce((s, n) => s + n.bytes, 0);
  const total = 256 * GiB;
  const free = 30 * GiB;
  const groups = [
    { name: "Apps", key: "apps", kind: "apps", bytes: sum(apps), children: apps },
    { name: "Personal files", key: "personal", kind: "personal", bytes: sum(personal), children: personal },
    { name: "Library", key: "library", kind: "library", bytes: sum(library), children: library },
  ];
  const used = total - free - sum(groups);
  groups.push({ name: "System & other", key: "system", kind: "system", bytes: used }, { name: "Free", key: "free", kind: "free", bytes: free });
  return { ok: true, state: "ready", scannedAt: new Date().toISOString(), partial: false, tree: { name: "Disk", key: "disk", kind: "root", bytes: total, children: groups }, cleanup: { state: "idle" } };
}

function cloudFixture(reachable = true) {
  const leaf = (id, name, gib, origin, restore, extra = {}) => ({ id, name, kind: "offloaded", bytes: gib * GiB, storedBytes: gib * 0.7 * GiB, originPath: origin, restore, restoreId: name, offloadedAt: secs(60), modified: secs(120), ...extra });
  const apps = [
    leaf("img-logic", "Logic Pro", 1.2, "/Applications/Logic Pro.app", "unpack", { stubPath: "/Applications/Logic Pro.app", otherDevice: "Studio Mini" }),
    { ...leaf("img-blender", "Blender Studio", 3.1, "/Applications/Blender Studio.app", "unpack"), bytes: 4.0 * GiB, children: [
      leaf("img-blender#image", "Blender Studio", 3.1, "/Applications/Blender Studio.app", "unpack", { key: "bundle" }),
      leaf("linked:b1", "Blender assets", 0.9, "/Users/me/.blender", "links/restore", { key: "linked" }),
    ] },
  ];
  const files = [
    leaf("f-raw", "Raw", 18, "/Users/me/Movies/Raw", "fetch", { stubPath: "/Users/me/Movies/Raw.disklessly", modified: secs(700) }),
    leaf("f-2019", "2019", 9, "/Users/me/Movies/2019", "fetch", { stubPath: "/Users/me/Movies/2019.disklessly", modified: secs(1200) }),
    leaf("f-old", "old-projects", 6, "/Users/me/code/old-projects", "fetch", { stubPath: "/Users/me/code/old-projects.disklessly", modified: secs(400) }),
  ];
  const sessions = [{ name: "claude", kind: "offloaded", bytes: 0.4 * GiB, children: [leaf("s-1", "a.jsonl", 0.4, "/Users/me/.claude/projects/a.jsonl", "sessions/restore")] }];
  const sum = (list) => list.reduce((s, n) => s + n.bytes, 0);
  const groups = [
    { name: "Files and folders", key: "files", kind: "offloaded", bytes: sum(files), children: files },
    { name: "Apps", key: "apps", kind: "offloaded", bytes: sum(apps), children: apps },
    { name: "Sessions", key: "sessions", kind: "offloaded", bytes: sum(sessions), children: sessions },
  ];
  const tree = { name: "Cloud", key: "cloud", kind: "root", bytes: sum(groups), children: groups };
  return { ok: true, generatedAt: new Date().toISOString(), reachable, health: reachable ? "ok" : "offline", totalBytes: tree.bytes, storedBytes: tree.bytes * 0.7, tree };
}

const fixtures = {
  main: () => status(),
  near: () => status({ usedGiB: 55 }),
  critical: () => status({ usedGiB: 62.1 }),
  empty: () => status({ usedGiB: 0.2, list: [] }),
  degraded: () => status({ health: "degraded" }),
  offline: () => status({ health: "offline", list: [], appsError: "Backend unavailable: smb://nas.local/apps did not answer within 5 s", appsErrorCode: "offline" }),
  // Reachable, healthy backend whose app list still failed: not "unreachable".
  appsfailed: () => status({ list: [], appsError: "refusing to place a Keychain secret on the mount command line", appsErrorCode: "failed" }),
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
    if (target.pathname === "/api/usage") return json(200, usageFixture());
    if (target.pathname === "/api/usage/cloud") return json(200, cloudFixture(fixture !== "offline"));
    if (target.pathname === "/api/usage/dir") return json(200, { ok: true, path: target.searchParams.get("path"), partial: false, children: [] });
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
  await checkUsageMath();
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
    // Split usage map: this Mac and the cloud at one scale, badges, ribbons, selection with its "what if", the tray.
    for (const [theme, viewport, width] of [["light", desktop, 1194], ["dark", desktop, 1194], ["light", phone, 375]]) {
      const view = await open(`usage-split-${theme}-${width}`, { theme, viewport });
      const { page } = view;
      const section = page.locator("#usage-section");
      await page.locator("#usage-cloud .usage-box").first().waitFor();
      await expectText(page, "网盘 · ");
      const movies = page.locator("#usage-chart .usage-box[data-path='/Users/me/Movies']");
      if ((await movies.locator(".usage-badge").innerText()).trim() !== "2") throw new Error("Movies lacks its cloud badge of 2");
      const tabStops = await page.locator("#usage-chart .usage-box[tabindex='0']").count();
      if (tabStops !== 1) throw new Error(`the local map has ${tabStops} Tab stops`);
      const stacked = await page.locator("#usage-split.is-stacked").count();
      if ((width === 375) !== Boolean(stacked)) throw new Error(`stacked layout at ${width}px: ${stacked}`);
      // Keyboard selection: Space on Movies previews the outcome; nothing is posted.
      const before = fixtureServer.log.length;
      await movies.focus();
      await page.keyboard.press(" ");
      await page.locator("#usage-chart .usage-box.is-ghost[data-path='/Users/me/Movies']").waitFor();
      await page.locator("#usage-cloud .usage-box.is-incoming").first().waitFor();
      await page.locator("#usage-chart .usage-box.u-free.is-growing").waitFor();
      if (!(await page.locator("#usage-tray-free").innerText()).includes("之后可用")) throw new Error("the tray does not say free after");
      if (await page.locator("#usage-ribbons path").count() < 1) throw new Error("no ribbon for the selected pair");
      if (fixtureServer.log.length !== before) throw new Error("selecting started a job");
      if (width === 375) {
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        if (overflow > 1) throw new Error(`375 px usage map scrolls sideways by ${overflow}px`);
      }
      await section.screenshot({ path: path.join(outDir, `usage-split-${theme}-${width}.png`) });
      shots.push(path.join(outDir, `usage-split-${theme}-${width}.png`));
      if (theme === "light" && width === 1194) {
        // The tray's Offload opens the existing confirmation; Escape changes nothing.
        await page.locator("#usage-tray-offload").click();
        await page.locator("#confirm").waitFor({ state: "visible" });
        await page.keyboard.press("Escape");
        await page.locator("#confirm").waitFor({ state: "hidden" });
        if (fixtureServer.log.length !== before) throw new Error("cancelled offload started a job");
        await page.locator("#usage-tray-clear").click();
        // The goal slider only selects.
        await page.locator("#usage-goal").evaluate((input) => { input.value = "10"; input.dispatchEvent(new Event("input", { bubbles: true })); });
        await page.locator("#usage-chart .usage-box.is-ghost").first().waitFor();
        if (fixtureServer.log.length !== before) throw new Error("the goal slider started a job");
        // Last-used tint.
        await page.locator("#usage-tint [data-tint='age']").click();
        await page.locator("#usage-chart .usage-box.usage-age-4").first().waitFor();
        await section.screenshot({ path: path.join(outDir, "usage-split-age-light-1194.png") });
        shots.push(path.join(outDir, "usage-split-age-light-1194.png"));
        await page.locator("#usage-tint [data-tint='kind']").click();
        // Drag across the channel opens the same confirmation as the menu; cancelling changes nothing.
        await page.locator("#usage-tray-clear").click();
        await page.locator("#usage-chart .usage-box[data-path='/Users/me/Downloads']").dragTo(page.locator("#usage-cloud"));
        await page.locator("#confirm").waitFor({ state: "visible" });
        if (!(await page.locator("#confirm").innerText()).includes("Downloads")) throw new Error("drop to offload does not name the folder");
        await page.keyboard.press("Escape");
        await page.locator("#confirm").waitFor({ state: "hidden" });
        await page.locator("#usage-chart .usage-box[data-path='/Applications/Final Cut Pro.app']").first().dragTo(page.locator("#usage-cloud"));
        await page.locator("#confirm").waitFor({ state: "visible" });
        if (!(await page.locator("#confirm").innerText()).includes("Final Cut Pro")) throw new Error("drop of an app does not open its pack dialog");
        await page.keyboard.press("Escape");
        await page.locator("#confirm").waitFor({ state: "hidden" });
        await page.locator("#usage-cloud .usage-box[data-origin='/Users/me/Movies/Raw']").dragTo(page.locator("#usage-chart"));
        await page.locator("#confirm").waitFor({ state: "visible" });
        await page.keyboard.press("Escape");
        await page.locator("#confirm").waitFor({ state: "hidden" });
        if (fixtureServer.log.length !== before) throw new Error("a cancelled drop started a job");
        // A badge zooms the cloud side to what came from there.
        await movies.locator(".usage-badge").click();
        await page.locator("#usage-cloud-crumbs:not([hidden])").waitFor();
        await page.locator("#usage-cloud .usage-box[data-origin='/Users/me/Movies/Raw']").waitFor();
      }
      await view.finish();
    }
    // Unreachable repo: the cloud side keeps the last catalog, dimmed, and says why.
    const offlineMap = await open("usage-split-offline-light-1194", { fixture: "offline" });
    await offlineMap.page.locator("#usage-cloud-side.is-offline").waitFor();
    await offlineMap.page.locator("#usage-cloud-note:not([hidden])").waitFor();
    await offlineMap.finish();

    // UI_SHOT_ONLY=usage stops after the usage map (the rest checks the app list and states).
    if (process.env.UI_SHOT_ONLY === "usage") return;

    for (const theme of ["light", "dark"]) {
      for (const [viewport, width] of [[desktop, 1194], [phone, 375]]) {
        const view = await open(`main-${theme}-${width}`, { theme, viewport });
        const { page } = view;
        await expectText(page, "运行正常");
        await expectText(page, "Healthy · 延迟 42 ms");
        await expectText(page, "空间充足");
        await expectText(page, "Plenty of room");
        await expectText(page, "已搬到网盘的应用");
        await expectText(page, "Offloaded apps");
        await expectText(page, "AI 对话记录");
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
        if (!(await evict.getAttribute("title")).includes("不再常留")) throw new Error("pinned Evict lacks its tooltip");
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
    await blender.getByRole("button", { name: /不再常留/ }).click();
    await page.waitForSelector("#toasts >> text=Blender Studio：不再常留本机完成");
    if (fixtureServer.log.at(-1) !== "unpin:Blender Studio") throw new Error(`expected unpin, got ${fixtureServer.log.join(", ")}`);

    const logic = page.locator(".app-row", { has: page.locator("h3", { hasText: "Logic Pro" }) });
    await logic.getByRole("button", { name: /打开 Logic Pro/ }).click();
    await page.waitForSelector(".app-row button[aria-busy='true']");
    const busyRows = await page.locator(".app-row[aria-busy='true']").count();
    if (busyRows !== 1) throw new Error(`pending state should be row-scoped, ${busyRows} rows are busy`);
    await page.waitForSelector("#toasts >> text=Logic Pro：打开失败");
    const failure = page.locator("#toasts .toast.error").last();
    const visible = await failure.innerText();
    if (!visible.includes("连不上网盘")) throw new Error(`error code was not localized: ${visible}`);
    if (await failure.locator("details code").isVisible()) throw new Error("raw server text is not folded");
    await failure.locator("summary").click();
    if (!(await failure.locator("details code").innerText()).includes("SMB share is not mounted")) throw new Error("raw detail missing");
    await act.shoot("-toast", false);

    await logic.getByRole("button", { name: /Logic Pro 的更多操作/ }).click();
    const unpack = page.getByRole("menuitem", { name: /永久拿回到 \/Applications/ });
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
    await page.getByRole("menuitem", { name: /永久拿回到 ~\/Applications/ }).waitFor();
    await page.keyboard.press("Escape");
    await act.finish();

    // Near quota and critical.
    for (const fixture of ["near", "critical"]) {
      const view = await open(`${fixture}-light-1194`, { fixture });
      await expectText(view.page, fixture === "near" ? "快到上限" : "快满了");
      await expectText(view.page, "硬盘剩余空间少于要留出的大小时，会自动清掉没设为常留本机的缓存");
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
    await expectText(offline.page, "连不上网盘");
    await expectText(offline.page, "Can't reach your storage");
    await expectText(offline.page, "超时 5 s");
    const banner = await offline.page.locator("#banner").innerText();
    if (banner.includes("did not answer")) throw new Error("banner shows raw server text inline");
    await offline.shoot("", false);
    await offline.finish();

    // Empty repo: onboarding and the empty state.
    const empty = await open("empty-light-1194", { fixture: "empty" });
    await expectText(empty.page, "还没有搬到网盘的应用");
    await empty.page.locator("#onboarding").waitFor({ state: "visible" });
    if (await empty.page.locator("#devices-section").getAttribute("open") !== null) throw new Error("empty Devices section is expanded");
    await empty.shoot();
    await empty.finish();

    // Loading skeleton while /api/status hangs.
    const loading = await open("loading-light-1194", { fixture: "slow", wait: "domcontentloaded" });
    await expectText(loading.page, "正在读取网盘…");
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
    await expectText(error.page, "连不上网盘");
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
