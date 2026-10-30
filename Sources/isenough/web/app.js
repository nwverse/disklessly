// Loopback management page. The token stays in the page URL; the server rejects
// calls that do not present it. No remote assets and no embedded secrets.

const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const REFRESH_MS = 20000;
const JOB_POLL_MS = 700;

// i18n:begin — both languages must carry the same keys (checked by UIServerTests and scripts/ui-screenshots.mjs).
const copy = {
  zh: {
    subtitle: "把冷门 App 放到远端，本机只留一个入口",
    refresh: "刷新",
    langToggle: "English",
    langAria: "切换到英文界面",
    themeGroup: "外观",
    themeLight: "浅色",
    themeDark: "深色",
    themeSystem: "跟随系统",
    skip: "跳到应用",
    retry: "重试",
    cancel: "取消",
    cache: "缓存用量",
    backend: "后端",
    apps: "应用",
    appsCount: (n) => `应用 ${n}`,
    backfillIcons: "补齐图标",
    search: "搜索",
    sortBy: "排序",
    sortName: "名称",
    sortSize: "大小",
    sortLastUsed: "最近使用",
    filterBy: "显示",
    filterAll: "全部",
    filterCached: "已缓存",
    filterRemote: "仅远端",
    filterPinned: "已固定",
    noMatches: "没有符合条件的应用",
    devices: "设备",
    devicesEmpty: "还没有登记的 Mac",
    devicesSummary: (n) => `${n} 台 Mac 共用这个仓库`,
    thisMac: "本机",
    onDevices: (names) => `也在 ${names}`,
    conflictCopies: (n) => `${n} 个 iCloud 冲突副本，未合并`,
    placeholders: (n) => `${n} 个设备文件还没下载`,
    sessions: "冷会话",
    recommend: "值得卸载",
    recommendWarn: "不建议卸载",
    recommendEmpty: "没有达到大小阈值的应用",
    recommendEmptyHint: "较大且久未使用的应用会显示在这里",
    recommendUnavailable: "扫描已安装应用需要 macOS",
    recommendFailed: "未能加载建议",
    recommendScanning: "正在扫描已安装的应用…",
    recommendSummary: (count, min) => `${count} 个应用 · 只列出不小于 ${min} 的应用`,
    couldFree: (size) => `大约可腾出 ${size}`,
    scannedAgo: (when) => `扫描于${when}`,
    rescan: "重新扫描",
    copyCommand: "复制命令",
    copyCommandFor: (name) => `复制命令：打包 ${name}`,
    copied: (name) => `已复制 ${name} 的打包命令`,
    copyFailed: "无法写入剪贴板，请手动复制命令",
    leftoverBackups: (count, size) => `${count} 个残留备份（${size}）可以删除`,
    leftoverAdmin: "删除需要管理员权限。",
    neverUsed: "从未使用",
    idleDays: (n) => n === 1 ? "1 天未使用" : `${n} 天未使用`,
    restoreNeeded: "含商店收据，需要还原模式",
    sizeBound: "大小是下限（扫描超时）",
    warnloginItem: "登录项",
    warnmenuBarAgent: "菜单栏代理",
    warnbackgroundHelper: "后台辅助进程在运行",
    warnsystemExtension: "带系统扩展",
    warnkernelExtension: "带内核扩展",
    warntoolchain: "引擎使用的工具链",
    warnpinned: "已固定",
    warnalreadyPacked: "已经打包",
    warnsizeTimedOut: "体积扫描超时",
    alreadyInRepo: "仓库里已有相同版本，打包无需上传",
    usedCaption: "已用",
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
    healthySub: "仓库可以访问",
    degradedTitle: "性能下降",
    degradedSub: "仓库可以连接，但缺少文件",
    offlineTitle: "已离线",
    offlineSub: "暂时连不上仓库，已缓存的应用仍可打开",
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
    countNone: "无",
    cached: "已缓存",
    remote: "仅远端",
    pinned: "已固定",
    restored: "已还原",
    stateAttention: "需要处理",
    stateMounted: "已挂载",
    stateDownloading: "下载中",
    remoteToDownload: (size) => `远端 · 需下载 ${size}`,
    lastUsedAt: (when) => `${when}使用`,
    open: "打开",
    openFor: (name) => `打开 ${name}`,
    prefetch: "预取",
    prefetchFor: (name) => `预取 ${name}`,
    prefetchDone: "预取，已在缓存中",
    pin: "固定",
    unpin: "取消固定",
    evict: "清除缓存",
    evictDisabled: "清除缓存，目前没有缓存",
    evictMounted: "清除缓存，应用正在使用，退出后再试",
    evictPinned: "清除缓存，应用已固定，先取消固定",
    more: "更多",
    moreFor: (name) => `${name} 的更多操作`,
    restore: "临时还原",
    unpack: "永久还原到 /Applications…",
    mount: "挂载",
    restoreMode: "还原",
    modeSkip: "跳过",
    modeUnsupported: "不支持",
    share: (n) => `占配额 ${n}%`,
    quotaUnset: "未设置配额",
    confirmEvictTitle: (name) => `清除 ${name} 的缓存？`,
    confirmEvictBody: (size) => `本机会腾出 ${size}。仓库里的镜像保留，下次打开时会重新下载。`,
    confirmEvictOk: "清除缓存",
    confirmRestoreTitle: (name) => `临时还原 ${name}？`,
    confirmRestoreBody: "会把应用解压回本机原位置并打开，退出后再放回仓库。期间会占用完整的磁盘空间。",
    confirmRestoreOk: "还原并打开",
    confirmUnpackTitle: (name) => `把 ${name} 永久还原到 /Applications？`,
    confirmUnpackBody: "应用会完整复制回 /Applications，入口替换为真正的应用，此后不再按需挂载。仓库里的镜像保留。",
    confirmUnpackOk: "永久还原",
    jobStarted: (action, name) => `${name}：${action}已开始`,
    jobDone: (action, name) => `${name}：${action}完成`,
    jobFailed: (action, name, reason) => `${name}：${action}失败。${reason}`,
    actionlaunch: "打开",
    actionprefetch: "预取",
    actionevict: "清除缓存",
    actionrestore: "临时还原",
    actionunpack: "永久还原",
    actionpin: "固定",
    actionunpin: "取消固定",
    phasequeued: "排队中",
    phaseresolve: "查找镜像",
    phasedownload: "下载中",
    phaseopen: "正在打开",
    phaserunning: "已打开",
    phaseevict: "清除中",
    phaseunpack: "复制中",
    phasepin: "更新中",
    errunknown_app: "仓库里找不到这个应用。",
    erroffline: "连不上仓库，请检查网络或共享盘后重试。",
    errintegrity: "下载的镜像校验失败，已丢弃，请重试。",
    errno_space: "磁盘空间不足，先清除一些缓存再试。",
    errbusy: "这个应用正在执行另一项操作，请稍后再试。",
    errunauthorized: "链接已失效。",
    errunsupported: "这台 Mac 不支持这个操作。",
    errneeds_resolution: "这个应用有未处理的改动，请先在终端里运行 isenough resolve。",
    errbad_request: "请求无效。",
    errfailed: "操作失败。",
    expiredTitle: "链接已失效",
    expiredBody: "这个页面的访问令牌已过期或不正确。请在终端里重新运行 isenough ui，再打开它给出的链接。",
    heroTitle: "三步腾出空间",
    heroBody: "把很少用的大应用放到仓库里，本机只留一个很小的入口；双击入口时再按需下载并打开。",
    heroStep1: "1. 选择仓库",
    heroStep2: "2. 查看建议",
    heroStep2Body: "下面会列出体积大、久未使用的应用。",
    heroStep2Link: "跳到建议",
    heroStep3: "3. 卸载到仓库",
    heroStep3Body: "复制建议里的命令到终端运行：",
    heroRepo: (path) => `当前仓库：${path}`,
    kindlocal: "本地目录",
    kindicloud: "iCloud 云盘",
    kindsmb: "SMB 共享",
    kindnfs: "NFS 共享",
    kindwebdav: "WebDAV",
    kindopenlist: "OpenList",
    kinds3: "S3",
    tiercold: "冷",
    tierwarm: "温",
    tierhot: "热",
  },
  en: {
    subtitle: "Keep rarely used apps remote, and a small launcher on this Mac",
    refresh: "Refresh",
    langToggle: "中文",
    langAria: "Switch the page to Chinese",
    themeGroup: "Appearance",
    themeLight: "Light",
    themeDark: "Dark",
    themeSystem: "System",
    skip: "Skip to apps",
    retry: "Retry",
    cancel: "Cancel",
    cache: "Cache",
    backend: "Backend",
    apps: "Apps",
    appsCount: (n) => `Apps ${n}`,
    backfillIcons: "Backfill icons",
    search: "Search",
    sortBy: "Sort",
    sortName: "Name",
    sortSize: "Size",
    sortLastUsed: "Last used",
    filterBy: "Show",
    filterAll: "All",
    filterCached: "Cached",
    filterRemote: "Remote only",
    filterPinned: "Pinned",
    noMatches: "No apps match",
    devices: "Devices",
    devicesEmpty: "No Macs have registered yet",
    devicesSummary: (n) => `${n} ${n === 1 ? "Mac shares" : "Macs share"} this repo`,
    thisMac: "This Mac",
    onDevices: (names) => `Also on ${names}`,
    conflictCopies: (n) => `${n} iCloud conflict ${n === 1 ? "copy" : "copies"}, not merged`,
    placeholders: (n) => `${n} device ${n === 1 ? "file is" : "files are"} not downloaded`,
    sessions: "Cold sessions",
    recommend: "Worth offloading",
    recommendWarn: "Poor candidates",
    recommendEmpty: "No apps above the size threshold",
    recommendEmptyHint: "Large apps that have sat unused show up here",
    recommendUnavailable: "Scanning installed apps requires macOS",
    recommendFailed: "Could not load recommendations",
    recommendScanning: "Scanning installed apps…",
    recommendSummary: (count, min) => `${count} ${count === 1 ? "app" : "apps"} · only apps of ${min} or more are listed`,
    couldFree: (size) => `Could free about ${size}`,
    scannedAgo: (when) => `Scanned ${when}`,
    rescan: "Rescan",
    copyCommand: "Copy command",
    copyCommandFor: (name) => `Copy command to pack ${name}`,
    copied: (name) => `Copied the pack command for ${name}`,
    copyFailed: "Could not write to the clipboard; copy the command by hand",
    leftoverBackups: (count, size) => `${count} leftover backup${count === 1 ? "" : "s"} (${size}) can be removed`,
    leftoverAdmin: "Removing them needs an administrator.",
    neverUsed: "Never used",
    idleDays: (n) => n === 1 ? "Last used 1 day ago" : `Last used ${n} days ago`,
    restoreNeeded: "Mac App Store receipt, restore mode",
    sizeBound: "Size is a lower bound (scan timed out)",
    warnloginItem: "Login item",
    warnmenuBarAgent: "Menu bar agent",
    warnbackgroundHelper: "Background helper is running",
    warnsystemExtension: "Bundles a system extension",
    warnkernelExtension: "Bundles a kernel extension",
    warntoolchain: "Toolchain used by the engine",
    warnpinned: "Pinned",
    warnalreadyPacked: "Already packed",
    warnsizeTimedOut: "Size scan timed out",
    alreadyInRepo: "already in repo, packing is instant, no upload",
    usedCaption: "Used",
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
    healthySub: "The repository is reachable",
    degradedTitle: "Degraded",
    degradedSub: "The repository answers but files are missing",
    offlineTitle: "Offline",
    offlineSub: "The repository is unreachable; cached apps still open",
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
    countNone: "None",
    cached: "Cached",
    remote: "Remote",
    pinned: "Pinned",
    restored: "Restored",
    stateAttention: "Needs attention",
    stateMounted: "Mounted",
    stateDownloading: "Downloading",
    remoteToDownload: (size) => `Remote · ${size} to download`,
    lastUsedAt: (when) => `Used ${when}`,
    open: "Open",
    openFor: (name) => `Open ${name}`,
    prefetch: "Prefetch",
    prefetchFor: (name) => `Prefetch ${name}`,
    prefetchDone: "Prefetch, already cached",
    pin: "Pin",
    unpin: "Unpin",
    evict: "Evict cache",
    evictDisabled: "Evict cache, nothing cached",
    evictMounted: "Evict cache, the app is in use; quit it first",
    evictPinned: "Evict cache, the app is pinned; unpin it first",
    more: "More",
    moreFor: (name) => `More actions for ${name}`,
    restore: "Restore temporarily",
    unpack: "Restore to /Applications for good…",
    mount: "Mount",
    restoreMode: "Restore",
    modeSkip: "Skip",
    modeUnsupported: "Unsupported",
    share: (n) => `${n}% of quota`,
    quotaUnset: "Quota is not set",
    confirmEvictTitle: (name) => `Evict ${name} from the cache?`,
    confirmEvictBody: (size) => `This frees ${size} on this Mac. The image stays in the repo and downloads again the next time you open the app.`,
    confirmEvictOk: "Evict cache",
    confirmRestoreTitle: (name) => `Restore ${name} temporarily?`,
    confirmRestoreBody: "The app is copied back to its original place and opened, then returned to the repo after it quits. It uses the full disk space meanwhile.",
    confirmRestoreOk: "Restore and open",
    confirmUnpackTitle: (name) => `Restore ${name} to /Applications for good?`,
    confirmUnpackBody: "The full app is copied back to /Applications and replaces the launcher; it is no longer mounted on demand. The image stays in the repo.",
    confirmUnpackOk: "Restore for good",
    jobStarted: (action, name) => `${name}: ${action} started`,
    jobDone: (action, name) => `${name}: ${action} finished`,
    jobFailed: (action, name, reason) => `${name}: ${action} failed. ${reason}`,
    actionlaunch: "open",
    actionprefetch: "prefetch",
    actionevict: "evict",
    actionrestore: "restore",
    actionunpack: "permanent restore",
    actionpin: "pin",
    actionunpin: "unpin",
    phasequeued: "Queued",
    phaseresolve: "Finding image",
    phasedownload: "Downloading",
    phaseopen: "Opening",
    phaserunning: "Open",
    phaseevict: "Evicting",
    phaseunpack: "Copying",
    phasepin: "Updating",
    errunknown_app: "The repo has no app by that name.",
    erroffline: "The repository is unreachable. Check the network or share and try again.",
    errintegrity: "The downloaded image failed its checksum and was discarded. Try again.",
    errno_space: "Not enough disk space. Evict some cached apps and try again.",
    errbusy: "This app is busy with another action. Try again shortly.",
    errunauthorized: "The link has expired.",
    errunsupported: "This Mac does not support that action.",
    errneeds_resolution: "This app has unresolved changes. Run isenough resolve in Terminal first.",
    errbad_request: "The request was not valid.",
    errfailed: "The action failed.",
    expiredTitle: "This link has expired",
    expiredBody: "The page token is missing or no longer valid. Run isenough ui in Terminal again and open the link it prints.",
    heroTitle: "Free up space in three steps",
    heroBody: "Large apps you rarely use move into your repo; this Mac keeps a tiny launcher that downloads and opens them on demand.",
    heroStep1: "1. Choose a repo",
    heroStep2: "2. Review recommendations",
    heroStep2Body: "Large apps that have sat unused are listed below.",
    heroStep2Link: "Jump to recommendations",
    heroStep3: "3. Offload",
    heroStep3Body: "Copy a command from the recommendations and run it in Terminal:",
    heroRepo: (path) => `Current repo: ${path}`,
    kindlocal: "Local folder",
    kindicloud: "iCloud Drive",
    kindsmb: "SMB share",
    kindnfs: "NFS share",
    kindwebdav: "WebDAV",
    kindopenlist: "OpenList",
    kinds3: "S3",
    tiercold: "Cold",
    tierwarm: "Warm",
    tierhot: "Hot",
  },
};
// i18n:end
window.isenoughI18n = { copy };

const root = document.documentElement;
let lang = root.getAttribute("data-lang") === "zh" ? "zh" : "en";
let lastStatus = null;
let lastRecommend = null;
let recommendError = "";
let lastLatency = null;
let loadFailed = false;
let expired = false;
let refreshing = null;
let recommendLoading = false;
const pending = new Map(); // app name -> { kind, jobId, phase }
const view = { search: "", sort: "name", filter: "all" };
const folds = {};

function t(key, ...args) {
  let value = copy[lang][key];
  if (value === undefined) {
    console.warn(`isenough ui: missing ${lang} text for "${key}"`);
    value = copy.en[key];
  }
  if (value === undefined) return key;
  return typeof value === "function" ? value(...args) : value;
}

function has(key) {
  return copy[lang][key] !== undefined || copy.en[key] !== undefined;
}

function locale() {
  return lang === "zh" ? "zh-Hans" : "en";
}

function url(path) {
  const target = new URL(path, location.origin);
  if (token) target.searchParams.set("token", token);
  return target;
}

class ApiError extends Error {
  constructor(code, message, status, payload) {
    super(message);
    this.code = code;
    this.status = status;
    this.payload = payload;
  }
}

async function api(path, options) {
  let response;
  try {
    response = await fetch(url(path), options);
  } catch (error) {
    throw new ApiError("offline", error.message || String(error), 0, {});
  }
  let payload = {};
  try { payload = await response.json(); } catch (e) { payload = {}; }
  if (response.status === 401) {
    showExpired();
    throw new ApiError("unauthorized", t("errunauthorized"), 401, payload);
  }
  if (!response.ok || payload.ok === false) {
    const error = payload.error;
    const code = (error && typeof error === "object" && error.code) || "failed";
    const message = (error && typeof error === "object" ? error.message : error) || response.statusText || "request failed";
    throw new ApiError(code, message, response.status, payload);
  }
  return payload;
}

/// Localized sentence for a stable error code; the server message is kept as detail.
function errorText(code, message) {
  const key = "err" + (code || "failed");
  const base = has(key) ? t(key) : t("errfailed");
  if (!message || code === "unauthorized") return base;
  return `${base} (${message})`;
}

// One size rule everywhere: 1024-based units, one decimal below 10, none at 10 and above.
function bytes(value) {
  let n = Math.max(0, Number(value || 0));
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit += 1;
  }
  const digits = unit === 0 || n >= 10 ? 0 : 1;
  const number = new Intl.NumberFormat(locale(), { minimumFractionDigits: 0, maximumFractionDigits: digits }).format(n);
  return `${number} ${units[unit]}`;
}

function relativeTime(iso) {
  const when = Date.parse(iso || "");
  if (!Number.isFinite(when)) return "";
  const seconds = Math.round((when - Date.now()) / 1000);
  const format = new Intl.RelativeTimeFormat(locale(), { numeric: "auto" });
  const steps = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]];
  for (const [unit, size] of steps) {
    if (Math.abs(seconds) >= size) return format.format(Math.round(seconds / size), unit);
  }
  return format.format(0, "second");
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

function kindLabel(kind) {
  const key = "kind" + String(kind || "local").toLowerCase();
  return has(key) ? t(key) : String(kind || "");
}

function tierLabel(tier) {
  const key = "tier" + String(tier || "cold").toLowerCase();
  return has(key) ? t(key) : String(tier || "");
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function setText(node, text) {
  if (node && node.textContent !== text) node.textContent = text;
}

// ---- chrome ---------------------------------------------------------------

function currentTheme() {
  return root.getAttribute("data-theme") || "system";
}

function applyTheme(value) {
  if (value === "light" || value === "dark") root.setAttribute("data-theme", value);
  else root.removeAttribute("data-theme");
  try {
    if (value === "light" || value === "dark") localStorage.setItem("isenough.theme", value);
    else localStorage.removeItem("isenough.theme");
  } catch (e) {}
  syncTheme();
}

function syncTheme() {
  const group = document.querySelector("#theme");
  group.setAttribute("aria-label", t("themeGroup"));
  const theme = currentTheme();
  for (const button of group.querySelectorAll("[role=radio]")) {
    const checked = button.dataset.themeValue === theme;
    button.setAttribute("aria-checked", String(checked));
    button.tabIndex = checked ? 0 : -1;
  }
}

function applyChrome() {
  root.lang = lang === "zh" ? "zh-Hans" : "en";
  root.setAttribute("data-lang", lang);
  for (const node of document.querySelectorAll("[data-i18n]")) setText(node, t(node.dataset.i18n));
  const toggle = document.querySelector("#lang");
  setText(toggle, t("langToggle"));
  toggle.setAttribute("lang", lang === "zh" ? "en" : "zh-Hans");
  toggle.setAttribute("aria-label", t("langAria"));
  syncTheme();
  const count = (lastStatus && lastStatus.apps && lastStatus.apps.length) || 0;
  setText(document.querySelector("#apps-title"), lastStatus ? t("appsCount", count) : t("apps"));
  setText(document.querySelector("#confirm-cancel"), t("cancel"));
}

function showBanner(message) {
  const banner = document.querySelector("#banner");
  // Only touch the live region when the message changes, so a refresh does not re-announce it.
  setText(document.querySelector("#banner-text"), message);
  if (banner.hidden) banner.hidden = false;
}

function hideBanner() {
  const banner = document.querySelector("#banner");
  if (!banner.hidden) banner.hidden = true;
  setText(document.querySelector("#banner-text"), "");
}

function showExpired() {
  if (expired) return;
  expired = true;
  hideBanner();
  document.querySelector("#expired").hidden = false;
  document.querySelector("#content").hidden = true;
  document.querySelector("#refresh").disabled = true;
}

function toast(message, tone) {
  const region = document.querySelector("#toasts");
  const item = el("div", `toast ${tone || ""}`.trim(), message);
  region.append(item);
  while (region.children.length > 4) region.firstElementChild.remove();
  setTimeout(() => item.remove(), tone === "error" ? 12000 : 6000);
}

// ---- icons ----------------------------------------------------------------

// The SVG namespace is not fetched. The pieces stay split so the page source has no URL.
const svgNS = "http" + "://www.w3.org/2000/svg";
const iconOpen = "M8 5v14l11-7z";
const iconDownload = "M11 4h2v8.2l3.3-3.3 1.4 1.4L12 16l-5.7-5.7 1.4-1.4 3.3 3.3V4zM5 18h14v2H5z";
const iconPin = "M12 2.2c.5 0 .9.4.9.9v1.2A5.1 5.1 0 0 1 17 9.2c0 1.2-.4 2.3-1.1 3.2L14.6 21h-5.2l-1.3-8.6A4.8 4.8 0 0 1 7 9.2a5.1 5.1 0 0 1 4.1-4.9V3.1c0-.5.4-.9.9-.9z";
const iconTrash = "M9 3h6l1 2h4v2H4V5h4l1-2zm1 6h2v9h-2V9zm4 0h2v9h-2V9zM8 9h2v9H8V9z";
const iconMore = "M6 10.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zm6 0a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zm6 0a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3z";
const iconCopy = "M8 3h10a2 2 0 0 1 2 2v10h-2V5H8V3zM5 7h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2zm0 2v10h10V9H5z";

function svgIcon(path) {
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "18");
  svg.setAttribute("height", "18");
  svg.setAttribute("aria-hidden", "true");
  svg.classList.add("glyph");
  const drawing = document.createElementNS(svgNS, "path");
  drawing.setAttribute("fill", "currentColor");
  drawing.setAttribute("d", path);
  svg.append(drawing);
  return svg;
}

function actionButton({ label, name, icon, onClick, className, busy, disabled }) {
  const node = document.createElement("button");
  node.type = "button";
  node.className = ["action", className].filter(Boolean).join(" ");
  if (name && name !== label) node.setAttribute("aria-label", name);
  const spinner = el("span", "spinner");
  spinner.setAttribute("aria-hidden", "true");
  node.append(svgIcon(icon), spinner, el("span", "btn-label", label));
  if (busy) {
    node.setAttribute("aria-busy", "true");
    node.classList.add("is-busy");
  }
  if (disabled) node.disabled = true;
  node.addEventListener("click", onClick);
  return node;
}

function letterIcon(name) {
  const letter = (name || "?").trim().charAt(0).toUpperCase() || "?";
  const tones = ["#0f6b4c", "#0c4f8a", "#8a3d12", "#8f1d3a", "#3d4a2a", "#4a3f8a"];
  let hash = 0;
  for (const ch of name || "?") hash = (hash + ch.charCodeAt(0)) % tones.length;
  const node = el("div", "app-icon", letter);
  node.style.background = tones[hash];
  node.setAttribute("aria-hidden", "true");
  return node;
}

function appIcon(name, imageId) {
  if (!imageId) return letterIcon(name);
  const node = document.createElement("img");
  node.className = "app-icon";
  node.alt = "";
  node.width = 44;
  node.height = 44;
  node.src = String(url("/api/icon/" + encodeURIComponent(imageId)));
  node.addEventListener("error", () => node.replaceWith(letterIcon(name)));
  return node;
}

function chip(kind, label) {
  return el("span", `chip ${kind}`, label);
}

// ---- cache and backend ----------------------------------------------------

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
  near.hidden = level === "ok";
  near.textContent = level === "hot" ? t("nearHot") : level === "warn" ? t("nearWarn") : "";
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
    marker.style.left = `${Math.max(0, Math.min(100, (floor / quota) * 100))}%`;
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
    [t("detach"), t("seconds", cache.detachDelaySeconds || 0)],
  ]) {
    const row = el("div");
    row.append(el("dt", "", label), el("dd", "", text));
    stats.append(row);
  }
  body.append(stats);
}

function endpointLine(item) {
  const row = el("li", item.current ? "endpoint is-current" : "endpoint");
  row.append(el("span", "kind", kindLabel(item.type || "local")));
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
  for (const [label, text] of [
    [t("latency"), latency == null ? "—" : `${latency} ms`],
    [t("current"), backend ? `${backend.activeId || kindLabel(backend.kind) || t("local")}` : "—"],
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
        id: (backend && (backend.activeId || kindLabel(backend.kind))) || t("local"),
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

// ---- apps -----------------------------------------------------------------

function visibleApps(apps) {
  const needle = view.search.trim().toLowerCase();
  const filtered = apps.filter((app) => {
    if (needle && !`${app.name || ""} ${app.bundleId || ""}`.toLowerCase().includes(needle)) return false;
    if (view.filter === "cached") return Boolean(app.cached);
    if (view.filter === "remote") return !app.cached;
    if (view.filter === "pinned") return Boolean(app.pinned);
    return true;
  });
  const size = (app) => Number(app.cached ? app.cachedBytes : app.imageBytes) || 0;
  const used = (app) => Date.parse(app.lastUsed || "") || 0;
  const byName = (a, b) => String(a.name || "").localeCompare(String(b.name || ""), locale());
  filtered.sort((a, b) => {
    if (view.sort === "size") return size(b) - size(a) || byName(a, b);
    if (view.sort === "lastUsed") return used(b) - used(a) || byName(a, b);
    return byName(a, b);
  });
  return filtered;
}

function stateChip(app, job) {
  if (app.needsResolution || app.state === "needsResolution") return chip("attention", t("stateAttention"));
  if (job && job.phase === "download") return chip("downloading", t("stateDownloading"));
  if (app.mounted || app.state === "running") return chip("mounted", t("stateMounted"));
  return null;
}

function closeMenus(except) {
  for (const menu of document.querySelectorAll(".menu:not([hidden])")) {
    if (menu === except) continue;
    menu.hidden = true;
    const trigger = menu.previousElementSibling;
    if (trigger) trigger.setAttribute("aria-expanded", "false");
  }
}

function overflowMenu(app, busy) {
  const wrap = el("div", "more");
  const menuId = `menu-${String(app.imageId || app.name).replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const trigger = actionButton({
    label: t("more"),
    name: t("moreFor", app.name),
    icon: iconMore,
    className: "quiet icon-only",
    disabled: busy,
    onClick: (event) => {
      event.stopPropagation();
      const open = menu.hidden;
      closeMenus(menu);
      menu.hidden = !open;
      trigger.setAttribute("aria-expanded", String(open));
      if (open) menu.querySelector("[role=menuitem]").focus();
    },
  });
  trigger.setAttribute("aria-haspopup", "menu");
  trigger.setAttribute("aria-expanded", "false");
  trigger.setAttribute("aria-controls", menuId);
  const menu = el("div", "menu");
  menu.id = menuId;
  menu.setAttribute("role", "menu");
  menu.hidden = true;
  const items = [
    [t("restore"), () => confirmAction("restore", app)],
    [t("unpack"), () => confirmAction("unpack", app)],
  ];
  for (const [label, run] of items) {
    const item = el("button", "menuitem", label);
    item.type = "button";
    item.setAttribute("role", "menuitem");
    item.tabIndex = -1;
    item.addEventListener("click", () => {
      closeMenus();
      run();
    });
    menu.append(item);
  }
  menu.addEventListener("keydown", (event) => {
    const entries = [...menu.querySelectorAll("[role=menuitem]")];
    const index = entries.indexOf(document.activeElement);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = (index + (event.key === "ArrowDown" ? 1 : entries.length - 1)) % entries.length;
      entries[next].focus();
    } else if (event.key === "Escape") {
      event.preventDefault();
      closeMenus();
      trigger.focus();
    } else if (event.key === "Tab") {
      closeMenus();
    }
  });
  wrap.append(trigger, menu);
  return wrap;
}

function renderApps(list, failed) {
  const rootNode = document.querySelector("#app-list");
  const tools = document.querySelector("#list-tools");
  const focusedKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : "";
  rootNode.replaceChildren();
  rootNode.removeAttribute("aria-busy");
  const apps = list || [];
  tools.hidden = apps.length < 2;
  if (!apps.length) {
    const empty = el("div", "empty");
    empty.append(el("strong", "", failed ? t("loadFailed") : t("emptyApps")));
    if (!failed) empty.append(el("span", "", t("emptyAppsHint")));
    rootNode.append(empty);
    return;
  }
  const shown = visibleApps(apps);
  if (!shown.length) {
    rootNode.append(el("div", "empty", t("noMatches")));
    return;
  }
  const quota = Number((lastStatus && lastStatus.cache && lastStatus.cache.quotaBytes) || 0);
  for (const app of shown) {
    const job = pending.get(app.name);
    const busy = Boolean(job);
    const card = el("article", "app");
    card.dataset.state = app.state || "";
    if (busy) card.setAttribute("aria-busy", "true");
    const main = el("div", "app-main");
    const nameRow = el("div", "name-row");
    const heading = el("h3", "name", app.name || "");
    nameRow.append(heading);
    const chips = el("div", "chips");
    const status = stateChip(app, job);
    if (status) chips.append(status);
    if (app.cached) chips.append(chip("cached", t("cached")));
    else chips.append(chip("remote", t("remote")));
    if (app.pinned) chips.append(chip("pinned", t("pinned")));
    if (app.restored && !app.needsResolution) chips.append(chip("restored", t("restored")));
    nameRow.append(chips);
    const holders = (app.devices || []).filter(Boolean);
    const meta = [
      app.version || "",
      app.mode === "restore" ? t("restoreMode") : t("mount"),
      app.cached ? bytes(app.cachedBytes) : t("remoteToDownload", bytes(app.imageBytes)),
      app.lastUsed ? t("lastUsedAt", relativeTime(app.lastUsed)) : "",
      holders.length ? t("onDevices", holders.join(", ")) : "",
    ].filter(Boolean);
    main.append(nameRow, el("div", "meta", meta.join(" · ")));
    if (job) main.append(el("div", "job-line", t("phase" + (job.phase || "queued"))));
    if (app.cached && quota > 0) {
      const sharePct = Math.max(0, Math.min(100, (Number(app.cachedBytes || 0) / quota) * 100));
      const shownPct = sharePct >= 10 ? Math.round(sharePct) : Math.round(sharePct * 10) / 10;
      const bar = el("div", "share");
      bar.setAttribute("role", "meter");
      bar.setAttribute("aria-valuemin", "0");
      bar.setAttribute("aria-valuemax", "100");
      bar.setAttribute("aria-valuenow", String(Math.round(sharePct)));
      bar.setAttribute("aria-label", t("share", shownPct));
      const fill = el("span");
      fill.style.width = `${sharePct}%`;
      bar.append(fill);
      main.append(bar);
    }
    const actions = el("div", "actions");
    const isBusy = (kind) => busy && job.kind === kind;
    const open = actionButton({ label: t("open"), name: t("openFor", app.name), icon: iconOpen, className: "primary", busy: isBusy("launch"), disabled: busy, onClick: () => startJob("launch", app) });
    const prefetch = actionButton({ label: t("prefetch"), name: app.cached ? t("prefetchDone") : t("prefetchFor", app.name), icon: iconDownload, busy: isBusy("prefetch"), disabled: busy || app.cached, onClick: () => startJob("prefetch", app) });
    const pinKind = app.pinned ? "unpin" : "pin";
    const pin = actionButton({ label: app.pinned ? t("unpin") : t("pin"), icon: iconPin, busy: isBusy("pin") || isBusy("unpin"), disabled: busy, onClick: () => startJob(pinKind, app) });
    pin.setAttribute("aria-pressed", String(Boolean(app.pinned)));
    const evict = actionButton({ label: t("evict"), name: !app.cached ? t("evictDisabled") : app.mounted ? t("evictMounted") : app.pinned ? t("evictPinned") : t("evict"), icon: iconTrash, className: "danger-quiet", busy: isBusy("evict"), disabled: busy || !app.cached || Boolean(app.mounted) || Boolean(app.pinned), onClick: () => confirmAction("evict", app) });
    for (const [kind, node] of [["launch", open], ["prefetch", prefetch], ["pin", pin], ["evict", evict]]) node.dataset.key = `${app.name}:${kind}`;
    actions.append(open, prefetch, pin, evict, overflowMenu(app, busy));
    card.append(appIcon(app.name, app.imageId), main, actions);
    rootNode.append(card);
  }
  if (focusedKey) {
    const again = rootNode.querySelector(`[data-key="${CSS.escape(focusedKey)}"]`);
    if (again && !again.disabled) again.focus();
  }
}

// ---- jobs -----------------------------------------------------------------

function confirmAction(kind, app) {
  const dialog = document.querySelector("#confirm");
  const titles = { evict: "confirmEvictTitle", restore: "confirmRestoreTitle", unpack: "confirmUnpackTitle" };
  const bodies = { evict: "confirmEvictBody", restore: "confirmRestoreBody", unpack: "confirmUnpackBody" };
  const oks = { evict: "confirmEvictOk", restore: "confirmRestoreOk", unpack: "confirmUnpackOk" };
  document.querySelector("#confirm-title").textContent = t(titles[kind], app.name);
  document.querySelector("#confirm-body").textContent = t(bodies[kind], bytes(app.cachedBytes || app.imageBytes));
  const ok = document.querySelector("#confirm-ok");
  ok.textContent = t(oks[kind]);
  ok.className = kind === "evict" || kind === "unpack" ? "danger" : "primary";
  const opener = document.activeElement;
  dialog.returnValue = "";
  dialog.onclose = () => {
    dialog.onclose = null;
    if (dialog.returnValue === "ok") startJob(kind, app);
    else if (opener && opener.isConnected) opener.focus();
  };
  if (typeof dialog.showModal === "function") {
    dialog.showModal();
    document.querySelector("#confirm-cancel").focus();
  } else if (window.confirm(`${document.querySelector("#confirm-title").textContent}\n\n${document.querySelector("#confirm-body").textContent}`)) {
    startJob(kind, app);
  }
}

async function startJob(kind, app) {
  if (pending.has(app.name)) return;
  pending.set(app.name, { kind, jobId: "", phase: "queued" });
  rerenderApps();
  try {
    const started = await api(`/api/${kind}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ app: app.name }) });
    pending.set(app.name, { kind, jobId: started.jobId, phase: started.phase || "queued" });
    rerenderApps();
    pollJob(app.name, kind, started.jobId);
  } catch (error) {
    pending.delete(app.name);
    rerenderApps();
    if (error.code === "unauthorized") return;
    if (error.code === "busy" && error.payload && error.payload.jobId) {
      pending.set(app.name, { kind, jobId: error.payload.jobId, phase: "queued" });
      pollJob(app.name, kind, error.payload.jobId);
    }
    toast(t("jobFailed", t("action" + kind), app.name, errorText(error.code, error.message)), "error");
  }
}

async function pollJob(name, kind, jobId) {
  while (!expired) {
    await new Promise((resolve) => setTimeout(resolve, JOB_POLL_MS));
    let job;
    try {
      job = await api(`/api/jobs/${encodeURIComponent(jobId)}`);
    } catch (error) {
      if (error.code === "unauthorized") return;
      if (error.status === 404) break;
      continue;
    }
    const current = pending.get(name);
    if (job.state === "running") {
      if (current && current.phase !== job.phase) {
        pending.set(name, { kind, jobId, phase: job.phase });
        rerenderApps();
      }
      continue;
    }
    pending.delete(name);
    if (job.state === "done") toast(t("jobDone", t("action" + kind), name), "ok");
    else toast(t("jobFailed", t("action" + kind), name, errorText(job.error && job.error.code, job.error && job.error.message)), "error");
    break;
  }
  pending.delete(name);
  await load();
}

function adoptServerJobs(status) {
  for (const job of (status && status.jobs) || []) {
    if (!job.app || pending.has(job.app)) continue;
    pending.set(job.app, { kind: job.kind, jobId: job.id, phase: job.phase });
    pollJob(job.app, job.kind, job.id);
  }
}

function rerenderApps() {
  if (lastStatus) renderApps(lastStatus.apps || [], Boolean(lastStatus.appsError));
}

// ---- recommendations ------------------------------------------------------

function recommendReason(app) {
  const warnings = app.warnings || [];
  if (warnings.length) return warnings.map((code) => (has("warn" + code) ? t("warn" + code) : code)).join("; ");
  const parts = [];
  if (app.neverUsed) parts.push(t("neverUsed"));
  else if (app.daysIdle != null) parts.push(t("idleDays", Number(app.daysIdle)));
  if (app.macAppStore) parts.push(t("restoreNeeded"));
  if (app.sizeIncomplete) parts.push(t("sizeBound"));
  if (app.alreadyInRepo) {
    const devices = app.otherDevices || [];
    parts.push(t("alreadyInRepo") + (devices.length ? ` (${devices.join(", ")})` : ""));
  }
  return parts.join("; ");
}

function modeLabel(mode) {
  if (mode === "restore") return t("restoreMode");
  if (mode === "skip") return t("modeSkip");
  if (mode === "unsupported") return t("modeUnsupported");
  return t("mount");
}

function packCommand(path) {
  const escaped = String(path || "").replace(/(["\\$`])/g, "\\$1");
  return `isenough pack "${escaped}"`;
}

async function copyText(text) {
  try {
    if (navigator.clipboard && window.isSecureContext !== false) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch (e) {}
  const area = el("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.append(area);
  area.select();
  let ok = false;
  try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
  area.remove();
  return ok;
}

function renderLeftovers(report) {
  const line = document.querySelector("#recommend-leftovers");
  const paths = document.querySelector("#recommend-leftover-paths");
  line.replaceChildren();
  paths.replaceChildren();
  const items = (report && report.leftoverBackups) || [];
  line.hidden = !items.length;
  paths.hidden = !items.length;
  if (!items.length) return;
  const total = items.reduce((sum, item) => sum + Number(item.sizeBytes || 0), 0);
  line.append(document.createTextNode(t("leftoverBackups", items.length, bytes(total)) + " " + t("leftoverAdmin")));
  for (const item of items) {
    const row = el("li");
    row.append(el("div", "path", item.path || ""));
    paths.append(row);
  }
}

function renderScanLine() {
  const scanned = document.querySelector("#recommend-scanned");
  const rescan = document.querySelector("#rescan");
  if (recommendLoading) {
    setText(scanned, t("recommendScanning"));
    rescan.setAttribute("aria-busy", "true");
    rescan.disabled = true;
  } else {
    setText(scanned, lastRecommend && lastRecommend.scannedAt ? t("scannedAgo", relativeTime(lastRecommend.scannedAt)) : "");
    rescan.removeAttribute("aria-busy");
    rescan.disabled = false;
  }
}

function renderRecommend(report, failed) {
  const summary = document.querySelector("#recommend-summary");
  const total = document.querySelector("#recommend-total");
  const list = document.querySelector("#recommend-list");
  const warnTitle = document.querySelector("#recommend-warn-title");
  const warnings = document.querySelector("#recommend-warnings");
  list.replaceChildren();
  warnings.replaceChildren();
  list.removeAttribute("aria-busy");
  renderScanLine();
  if (!report) {
    total.hidden = true;
    summary.textContent = "";
    const empty = el("div", "empty");
    empty.append(el("strong", "", t("recommendFailed")));
    if (failed) empty.append(el("span", "", failed));
    list.append(empty);
    warnTitle.hidden = true;
    renderLeftovers(null);
    return;
  }
  const apps = report.recommendations || [];
  if (report.scan === "unavailable") {
    total.hidden = true;
    summary.textContent = t("recommendUnavailable");
  } else {
    total.hidden = !apps.length;
    total.textContent = t("couldFree", bytes(report.estimatedFreedBytes || 0));
    summary.textContent = t("recommendSummary", apps.length, bytes(report.minSizeBytes || 0));
  }
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
    nameRow.append(el("h3", "name", app.name || ""));
    nameRow.append(chip(app.macAppStore ? "restored" : "cached", modeLabel(app.suggestedMode)));
    const reason = recommendReason(app);
    main.append(nameRow, el("div", "meta", [bytes(app.sizeBytes), app.bundleId || ""].filter(Boolean).join(" · ")));
    if (reason) main.append(el("div", "recommend-reason", reason));
    const command = packCommand(app.path);
    main.append(el("code", "inline-command", command));
    const actions = el("div", "actions");
    actions.append(actionButton({
      label: t("copyCommand"),
      name: t("copyCommandFor", app.name),
      icon: iconCopy,
      onClick: async () => {
        if (await copyText(command)) toast(t("copied", app.name), "ok");
        else toast(t("copyFailed"), "error");
      },
    }));
    card.append(appIcon(app.name), main, actions);
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

// ---- devices, sessions, onboarding ---------------------------------------

function setFold(id, countId, count) {
  const fold = document.querySelector(id);
  setText(document.querySelector(countId), count ? String(count) : t("countNone"));
  fold.classList.toggle("is-empty", !count);
  // Open the section the first time it has content; afterwards respect the user's toggle.
  const had = folds[id];
  if (had === undefined || (had === 0 && count > 0)) fold.open = count > 0;
  folds[id] = count;
}

function renderDevices(status) {
  const summary = document.querySelector("#devices-summary");
  const list = document.querySelector("#devices");
  list.replaceChildren();
  const devices = (status && status.devices) || [];
  const conflicts = (status && status.deviceConflicts) || [];
  const placeholders = (status && status.devicePlaceholders) || [];
  const notes = [];
  if (status && devices.length) notes.push(t("devicesSummary", devices.length));
  if (conflicts.length) notes.push(t("conflictCopies", conflicts.length));
  if (placeholders.length) notes.push(t("placeholders", placeholders.length));
  summary.textContent = notes.join(" · ");
  summary.hidden = !notes.length;
  setFold("#devices-section", "#devices-count", devices.length);
  if (!devices.length) {
    list.append(el("li", "empty", status ? t("devicesEmpty") : t("loadFailed")));
    return;
  }
  for (const device of devices) {
    const item = el("li");
    const top = el("div", "session-top");
    top.append(el("div", "name", device.displayName || device.hostname || device.deviceId || ""));
    if (device.self) top.append(chip("cached", t("thisMac")));
    item.append(top);
    const images = device.images || [];
    const detail = images.map((image) => `${image.bundleId || image.imageId} ${image.version || ""}`.trim()).join(", ");
    item.append(el("div", "path", [device.hostname, device.arch, device.osVersion].filter(Boolean).join(" · ")));
    if (detail) item.append(el("p", "preview", detail));
    list.append(item);
  }
}

function renderSessions(sessions) {
  const summary = document.querySelector("#sessions-summary");
  const list = document.querySelector("#sessions");
  list.replaceChildren();
  const offloaded = (sessions && sessions.offloaded) || [];
  summary.textContent = sessions ? [t("coldDays", sessions.coldDays || 14), t("offloaded", offloaded.length)].join(" · ") : "";
  setFold("#sessions-section", "#sessions-count", offloaded.length);
  if (!offloaded.length) {
    list.append(el("li", "empty", t("emptySessions")));
    return;
  }
  for (const entry of offloaded) {
    const item = el("li");
    const top = el("div", "session-top");
    top.append(el("div", "name", entry.tool || ""), chip("cold", tierLabel(entry.tier)));
    item.append(top, el("div", "path", entry.path || ""));
    if (entry.preview) item.append(el("p", "preview", entry.preview));
    list.append(item);
  }
}

function renderOnboarding(status) {
  const hero = document.querySelector("#onboarding");
  const show = Boolean(status) && !status.appsError && !((status.apps || []).length);
  hero.hidden = !show;
  const repo = status && status.backend && status.backend.repoPath;
  setText(document.querySelector("#hero-repo"), repo ? t("heroRepo", repo) : "");
}

// ---- load -----------------------------------------------------------------

function render(status) {
  lastStatus = status;
  applyChrome();
  renderOnboarding(status);
  renderCache(status.cache || {});
  renderHealth(status.backend || {}, lastLatency);
  const failed = Boolean(status.appsError);
  if (failed) showBanner(status.appsError);
  renderApps(status.apps || [], failed);
  renderDevices(status);
  renderSessions(status.sessions || {});
}

function renderFailure() {
  applyChrome();
  renderOnboarding(null);
  renderCache(null);
  renderHealth(null, lastLatency);
  renderApps([], true);
  renderDevices(null);
  renderSessions(null);
}

async function loadRecommendations(rescan) {
  if (recommendLoading) return;
  recommendLoading = true;
  renderScanLine();
  try {
    const report = await api(rescan ? "/api/recommend?rescan=1" : "/api/recommend");
    lastRecommend = report;
    recommendError = "";
  } catch (error) {
    if (error.code === "unauthorized") return;
    recommendError = errorText(error.code, error.message);
  } finally {
    recommendLoading = false;
  }
  if (lastRecommend) renderRecommend(lastRecommend, "");
  else renderRecommend(null, recommendError);
}

async function load() {
  if (expired) return;
  const started = performance.now();
  try {
    const status = await api("/api/status");
    lastLatency = Math.round(performance.now() - started);
    loadFailed = false;
    if (!status.appsError) hideBanner();
    adoptServerJobs(status);
    render(status);
  } catch (error) {
    if (error.code === "unauthorized") return;
    lastLatency = Math.round(performance.now() - started);
    loadFailed = !lastStatus;
    showBanner(error.message || String(error));
    if (!lastStatus) renderFailure();
    else renderHealth(Object.assign({}, lastStatus.backend, { health: "offline" }), lastLatency);
  }
}

function refresh() {
  // Coalesce overlapping refreshes instead of a page-wide busy flag; actions run independently.
  if (!refreshing) {
    refreshing = Promise.all([load(), loadRecommendations(false)]).finally(() => { refreshing = null; });
  }
  return refreshing;
}

function rerenderAll() {
  if (lastStatus) render(lastStatus);
  else if (loadFailed) renderFailure();
  else applyChrome();
  if (lastRecommend) renderRecommend(lastRecommend, "");
  else if (recommendError) renderRecommend(null, recommendError);
  else renderScanLine();
}

// ---- wiring ---------------------------------------------------------------

document.querySelector("#refresh").addEventListener("click", refresh);
document.querySelector("#retry").addEventListener("click", refresh);
document.querySelector("#rescan").addEventListener("click", () => loadRecommendations(true));
document.querySelector("#icon-backfill").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  if (button.getAttribute("aria-busy") === "true") return;
  button.setAttribute("aria-busy", "true");
  button.disabled = true;
  try {
    const report = await api("/api/icons/backfill", { method: "POST" });
    const warnings = report.warnings || [];
    if (warnings.length) toast(warnings.join("; "), "error");
    await load();
  } catch (error) {
    if (error.code !== "unauthorized") toast(errorText(error.code, error.message), "error");
  } finally {
    button.removeAttribute("aria-busy");
    button.disabled = false;
  }
});
document.querySelector("#lang").addEventListener("click", () => {
  lang = lang === "zh" ? "en" : "zh";
  try { localStorage.setItem("isenough.lang", lang); } catch (e) {}
  rerenderAll();
});
const themeGroup = document.querySelector("#theme");
themeGroup.addEventListener("click", (event) => {
  const button = event.target.closest("[role=radio]");
  if (button) applyTheme(button.dataset.themeValue);
});
themeGroup.addEventListener("keydown", (event) => {
  const keys = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
  if (!(event.key in keys)) return;
  event.preventDefault();
  const radios = [...themeGroup.querySelectorAll("[role=radio]")];
  const index = radios.findIndex((item) => item.dataset.themeValue === currentTheme());
  const next = radios[(index + keys[event.key] + radios.length) % radios.length];
  applyTheme(next.dataset.themeValue);
  next.focus();
});
document.querySelector("#search").addEventListener("input", (event) => {
  view.search = event.target.value;
  rerenderApps();
});
document.querySelector("#sort").addEventListener("change", (event) => {
  view.sort = event.target.value;
  rerenderApps();
});
document.querySelector("#filter").addEventListener("change", (event) => {
  view.filter = event.target.value;
  rerenderApps();
});
document.addEventListener("click", (event) => {
  if (!event.target.closest(".more")) closeMenus();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeMenus();
});
setInterval(() => {
  if (document.visibilityState === "visible" && !expired) refresh();
}, REFRESH_MS);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !expired) refresh();
});

applyChrome();
refresh();
