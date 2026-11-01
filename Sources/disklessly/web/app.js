// Loopback management page. The token stays in the page URL; the server rejects
// calls that do not present it. No remote assets and no embedded secrets.
//
// The page shows one language (Chinese or English), chosen in index.html and switched
// from the top bar. All text lives in `copy`.

const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const REFRESH_MS = 20000;
const JOB_POLL_MS = 700;
const TICK_MS = 15000;

// i18n:begin — both languages must carry the same keys (checked by UIServerTests and scripts/ui-screenshots.mjs).
const copy = {
  zh: {
    subtitle: "256G 就够了",
    updatedJustNow: "刚刚更新",
    updatedAgo: (m) => `${m} 分钟前更新`,
    updatedNever: "尚未更新",
    refresh: "刷新",
    skip: "跳到应用",
    retry: "重试",
    cancel: "取消",
    details: "详情",
    dismiss: "关闭",
    backend: "后端",
    locationremote: "远端",
    locationlocal: "本地",
    healthok: "运行正常",
    healthdegraded: "缓慢",
    healthmissing: "仓库不完整",
    healthoffline: "离线",
    healthunknown: "正在检查",
    latency: (ms) => `延迟 ${ms} ms`,
    timedOut: (s) => `超时 ${s} s`,
    missingHint: "能连上，但缺少 repo.json",
    offlineHint: "已缓存的应用仍可打开",
    activeEndpoint: "活动端点",
    kind: "类型",
    endpoints: "端点",
    endpointactive: "活动",
    endpointstandby: "待机",
    endpointlocal: "本地",
    kindlocal: "本地目录",
    kindicloud: "iCloud 云盘",
    kindsmb: "SMB 共享",
    kindnfs: "NFS 共享",
    kindwebdav: "WebDAV",
    kindopenlist: "OpenList",
    kinds3: "S3",
    cache: "缓存",
    levelok: "空间充足",
    levelnear: "接近配额",
    levelcritical: "配额将满",
    levelunset: "未设配额",
    quotaWord: "配额",
    usedPct: "已用",
    floorLabel: "空闲下限",
    floorKeep: (size) => `保留 ${size}`,
    floorMarkerHint: (size) => `缓存长到这里时，磁盘可用空间会降到 ${size} 的下限`,
    legendNormal: "正常",
    legendNear: "接近",
    legendCritical: "临界",
    quotaLeft: "配额剩余",
    floor: "空闲下限",
    diskFree: "磁盘可用",
    detach: "分离延迟",
    durationS: (n) => `${n} 秒`,
    durationM: (n) => `${n} 分钟`,
    nearNote: "低于空闲下限时自动清除未固定的缓存",
    quotaUnset: "未设置配额",
    noData: "没有数据",
    apps: "已卸载应用",
    appsSummary: (n, m, size, k) => `${n} 个应用 · ${m} 个已缓存 ${size} · ${k} 个已固定`,
    colApp: "应用",
    colStatus: "状态",
    colCache: "缓存",
    colActions: "操作",
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
    modemount: "按需",
    moderestore: "完整",
    modeskip: "跳过",
    modeunsupported: "不支持",
    cached: "已缓存",
    remote: "远端",
    pinned: "已固定",
    restored: "已还原",
    stateAttention: "需要处理",
    stateMounted: "已挂载",
    stateDownloading: "下载中",
    notCached: "未缓存",
    toDownload: "需下载",
    lastUsedAt: (iso) => `${relativeTime(iso, "zh")}使用`,
    onDevices: (names) => `也在 ${names}`,
    open: "打开",
    openFor: (name) => `打开 ${name}`,
    prefetch: "预取",
    prefetchFor: (name) => `预取 ${name}`,
    pin: "固定",
    unpin: "取消固定",
    evict: "清除缓存",
    evictMounted: "应用正在使用，退出后再清除",
    evictPinned: "已固定的应用不能清除，先取消固定",
    more: "更多",
    moreFor: (name) => `${name} 的更多操作`,
    restore: "临时还原",
    unpack: (dir) => `永久还原到 ${dir}…`,
    share: (n) => `占配额 ${n}%`,
    evictNote: "清除缓存只删除本地副本，应用仍保留在后端，下次打开时自动拉取。固定的应用不会被自动清除。",
    emptyApps: "暂无已卸载应用",
    emptyAppsHint: "卸载的应用会显示在这里。",
    loading: "正在读取后端…",
    loadFailed: "未能加载应用",
    unreachable: "无法连接后端",
    appsLoadFailed: "无法读取应用列表",
    confirmEvictTitle: (name) => `清除 ${name} 的缓存？`,
    confirmEvictBody: (size) => `本机会腾出 ${size}。仓库里的镜像保留，下次打开时会重新下载。`,
    confirmEvictOk: "清除缓存",
    confirmRestoreTitle: (name) => `临时还原 ${name}？`,
    confirmRestoreBody: "会把应用解压回本机原位置并打开，退出后再放回仓库。期间会占用完整的磁盘空间。",
    confirmRestoreOk: "还原并打开",
    confirmUnpackTitle: (name, dir) => `把 ${name} 永久还原到 ${dir}？`,
    confirmUnpackBody: (path) => `应用会完整复制回 ${path}，入口替换为真正的应用，此后不再按需挂载。仓库里的镜像保留。`,
    confirmUnpackOk: "永久还原",
    jobDone: (action, name) => `${name}：${action}完成`,
    jobFailed: (action, name) => `${name}：${action}失败`,
    actionlaunch: "打开",
    actionprefetch: "预取",
    actionevict: "清除缓存",
    actionrestore: "临时还原",
    actionunpack: "永久还原",
    actionpin: "固定",
    actionunpin: "取消固定",
    actionpack: "卸载",
    phasepack: "卸载中",
    offloadNow: "立即卸载",
    offloadNowFor: (name) => `立即卸载 ${name}`,
    offloading: "卸载中…",
    confirmPackTitle: (name) => `卸载 ${name}？`,
    confirmPackBody: (size) => `应用会被打包进仓库（约 ${size}），原位置换成一个入口，之后按需下载打开。需要先退出这个应用；可能要几分钟。`,
    confirmPackOk: "卸载",
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
    errpinned: "这个应用已固定，先取消固定再清除缓存。",
    errunauthorized: "链接已失效。",
    errunsupported: "这台 Mac 不支持这个操作。",
    errneeds_resolution: "这个应用有未处理的改动，请先在终端里运行 disklessly resolve。",
    errbad_request: "请求无效。",
    errfailed: "操作失败。",
    expiredTitle: "链接已失效",
    expiredBody: "这个页面的访问令牌已过期或不正确。请在终端里重新运行 disklessly ui，再打开它给出的链接。",
    heroTitle: "三步腾出空间",
    heroBody: "把很少用的大应用放到仓库里，本机只留一个很小的入口；双击入口时再按需下载并打开。",
    heroStep1: "1. 选择仓库",
    heroStep2: "2. 查看建议",
    heroStep2Body: "下面会列出体积大、久未使用的应用。",
    heroStep2Link: "跳到建议",
    heroStep3: "3. 卸载到仓库",
    heroStep3Body: "复制建议里的命令到终端运行：",
    heroRepo: (path) => `当前仓库：${path}`,
    license: "授权",
    licenseCode: "授权码",
    licenseActivate: "激活",
    licenseRemove: "移除授权",
    licenseFree: (used, limit) => `免费版：已卸载 ${used} / ${limit} 个应用`,
    licenseFreeBody: "启动、还原和取消卸载已卸载的应用永远免费。要卸载更多应用，请输入授权码。",
    licenseFull: "已授权：卸载应用数量不限",
    licenseUntil: (date) => `有效期至 ${date}`,
    licenseUpdates: (date) => `${date} 前的更新已包含`,
    licenseExpired: (date) => `授权码已于 ${date} 过期，免费版限额重新生效`,
    licenseInvalid: "已保存的授权码无法使用，免费版限额生效",
    licenseOk: "授权已激活",
    licenseRemoved: "授权已移除",
    errlicense_required: "免费版的卸载数量已用完。输入授权码可继续卸载更多应用。",
    sessionTiers: "会话分层",
    coldAfter: (n) => `${n} 天未用转冷`,
    offloadedCount: (n) => `已卸载 ${n} 个`,
    emptySessions: "还没有归档的会话",
    tiercold: "冷",
    daysAgo: (n) => (n <= 0 ? "今天" : `${n} 天前`),
    recommend: "值得卸载",
    recommendWarn: "不建议卸载",
    recommendEmpty: "没有达到大小阈值的应用",
    recommendEmptyHint: "较大且久未使用的应用会显示在这里",
    recommendUnavailable: "扫描已安装应用需要 macOS",
    recommendFailed: "未能加载建议",
    recommendScanning: "正在扫描已安装的应用…",
    recommendSummary: (count, min) => `${count} 个应用 · 只列出不小于 ${min} 的应用`,
    couldFree: "大约可腾出",
    scannedAgo: (iso) => `扫描于${relativeTime(iso, "zh")}`,
    rescan: "重新扫描",
    usage: "磁盘占用",
    usageScan: "分析占用",
    usageRescan: "重新分析",
    usageScanning: "正在分析磁盘…",
    usageIntro: "看看 256G 都被谁占了：应用的包体、缓存和数据，以及 Disklessly 自己的缓存。只读取大小，不会改动任何文件。",
    usagePartial: "部分目录超时没有读完，没读完的部分计入“系统及其他”。",
    usageFailed: "无法读取占用",
    usageHint: "点击方块放大，点击上方路径返回。",
    usageTotal: (used, free, total) => `共 ${total} · 已用 ${used} · 可用 ${free}`,
    usage_disk: "整块磁盘",
    usage_apps: "应用",
    usage_disklessly: "Disklessly",
    usage_personal: "个人文件",
    usage_library: "资源库",
    usage_system: "系统及其他",
    usage_free: "可用",
    usage_bundle: "包体",
    usage_cache: "缓存",
    usage_data: "数据",
    usage_repo: "本机仓库",
    usage_state: "状态与临时文件",
    usage_files: "散落文件",
    usage_rest: (n) => `其余 ${n} 项`,
    usage_other: "其他",
    copyCommand: "复制命令",
    copyCommandFor: (name) => `复制命令：打包 ${name}`,
    copied: (name) => `已复制 ${name} 的打包命令`,
    copyFailed: "无法写入剪贴板，请手动复制命令",
    leftoverBackups: (count, size) => `${count} 个残留备份（${size}）可以删除`,
    leftoverAdmin: "删除需要管理员权限。",
    neverUsed: "从未使用",
    idleDays: (n) => (n === 1 ? "1 天未使用" : `${n} 天未使用`),
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
    devices: "设备",
    devicesEmpty: "还没有登记的 Mac",
    devicesSummary: (n) => `${n} 台 Mac 共用这个仓库`,
    thisMac: "本机",
    conflictCopies: (n) => `${n} 个 iCloud 冲突副本，未合并`,
    placeholders: (n) => `${n} 个设备文件还没下载`,
    countNone: "无",
  },
  en: {
    subtitle: "256G is enough",
    updatedJustNow: "Updated just now",
    updatedAgo: (m) => `Updated ${m} min ago`,
    updatedNever: "Not updated yet",
    refresh: "Refresh",
    skip: "Skip to apps",
    retry: "Retry",
    cancel: "Cancel",
    details: "Details",
    dismiss: "Dismiss",
    backend: "Backend",
    locationremote: "Remote",
    locationlocal: "Local",
    healthok: "Healthy",
    healthdegraded: "Degraded",
    healthmissing: "Repo incomplete",
    healthoffline: "Offline",
    healthunknown: "Checking",
    latency: (ms) => `latency ${ms} ms`,
    timedOut: (s) => `timed out after ${s} s`,
    missingHint: "Reachable, but repo.json is missing",
    offlineHint: "Cached apps still open",
    activeEndpoint: "Active",
    kind: "Kind",
    endpoints: "Endpoints",
    endpointactive: "Active",
    endpointstandby: "standby",
    endpointlocal: "local",
    kindlocal: "Local folder",
    kindicloud: "iCloud Drive",
    kindsmb: "SMB share",
    kindnfs: "NFS share",
    kindwebdav: "WebDAV",
    kindopenlist: "OpenList",
    kinds3: "S3",
    cache: "Cache",
    levelok: "Plenty of room",
    levelnear: "Near quota",
    levelcritical: "Almost full",
    levelunset: "No quota",
    quotaWord: "quota",
    usedPct: "used",
    floorLabel: "Free floor",
    floorKeep: (size) => `keeps ${size} free`,
    floorMarkerHint: (size) => `At this cache size, free disk space falls to the ${size} floor`,
    legendNormal: "Normal",
    legendNear: "Near",
    legendCritical: "Critical",
    quotaLeft: "Quota left",
    floor: "Floor",
    diskFree: "free on disk",
    detach: "Detach delay",
    durationS: (n) => `${n} s`,
    durationM: (n) => `${n} min`,
    nearNote: "Unpinned cache is cleared automatically below the free floor",
    quotaUnset: "No quota set",
    noData: "No data",
    apps: "Offloaded apps",
    appsSummary: (n, m, size, k) => `${n} ${n === 1 ? "app" : "apps"} · ${m} cached ${size} · ${k} pinned`,
    colApp: "App",
    colStatus: "Status",
    colCache: "Cache",
    colActions: "Actions",
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
    modemount: "on-demand",
    moderestore: "full",
    modeskip: "skip",
    modeunsupported: "unsupported",
    cached: "Cached",
    remote: "Remote",
    pinned: "Pinned",
    restored: "Restored",
    stateAttention: "Needs attention",
    stateMounted: "Mounted",
    stateDownloading: "Downloading",
    notCached: "Not cached",
    toDownload: "to download",
    lastUsedAt: (iso) => `used ${relativeTime(iso, "en")}`,
    onDevices: (names) => `Also on ${names}`,
    open: "Open",
    openFor: (name) => `Open ${name}`,
    prefetch: "Prefetch",
    prefetchFor: (name) => `Prefetch ${name}`,
    pin: "Pin",
    unpin: "Unpin",
    evict: "Evict",
    evictMounted: "The app is in use; quit it first",
    evictPinned: "Pinned apps can't be evicted; unpin first",
    more: "More",
    moreFor: (name) => `More actions for ${name}`,
    restore: "Restore temporarily",
    unpack: (dir) => `Restore to ${dir} for good…`,
    share: (n) => `${n}% of quota`,
    evictNote: "Evict only drops the local copy; pinned apps are never auto-evicted.",
    emptyApps: "No offloaded apps.",
    emptyAppsHint: "Apps you offload show up here.",
    loading: "Loading",
    loadFailed: "Could not load apps",
    unreachable: "Backend unreachable",
    appsLoadFailed: "Couldn't load the app list",
    confirmEvictTitle: (name) => `Evict ${name} from the cache?`,
    confirmEvictBody: (size) => `This frees ${size} on this Mac. The image stays in the repo and downloads again the next time you open the app.`,
    confirmEvictOk: "Evict",
    confirmRestoreTitle: (name) => `Restore ${name} temporarily?`,
    confirmRestoreBody: "The app is copied back to its original place and opened, then returned to the repo after it quits. It uses the full disk space meanwhile.",
    confirmRestoreOk: "Restore and open",
    confirmUnpackTitle: (name, dir) => `Restore ${name} to ${dir} for good?`,
    confirmUnpackBody: (path) => `The full app is copied back to ${path} and replaces the launcher; it is no longer mounted on demand. The image stays in the repo.`,
    confirmUnpackOk: "Restore for good",
    jobDone: (action, name) => `${name}: ${action} finished`,
    jobFailed: (action, name) => `${name}: ${action} failed`,
    actionlaunch: "open",
    actionprefetch: "prefetch",
    actionevict: "evict",
    actionrestore: "restore",
    actionunpack: "permanent restore",
    actionpin: "pin",
    actionunpin: "unpin",
    actionpack: "offload",
    phasepack: "Offloading",
    offloadNow: "Offload now",
    offloadNowFor: (name) => `Offload ${name} now`,
    offloading: "Offloading…",
    confirmPackTitle: (name) => `Offload ${name}?`,
    confirmPackBody: (size) => `The app is packed into your repo (about ${size}) and its place gets a launcher that downloads and opens it on demand. Quit the app first. This can take a few minutes.`,
    confirmPackOk: "Offload",
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
    errpinned: "This app is pinned. Unpin it before evicting.",
    errunauthorized: "The link has expired.",
    errunsupported: "This Mac does not support that action.",
    errneeds_resolution: "This app has unresolved changes. Run disklessly resolve in Terminal first.",
    errbad_request: "The request was not valid.",
    errfailed: "The action failed.",
    expiredTitle: "This link has expired",
    expiredBody: "The page token is missing or no longer valid. Run disklessly ui in Terminal again and open the link it prints.",
    heroTitle: "Free up space in three steps",
    heroBody: "Large apps you rarely use move into your repo; this Mac keeps a tiny launcher that downloads and opens them on demand.",
    heroStep1: "1. Choose a repo",
    heroStep2: "2. Review recommendations",
    heroStep2Body: "Large apps that have sat unused are listed below.",
    heroStep2Link: "Jump to recommendations",
    heroStep3: "3. Offload",
    heroStep3Body: "Copy a command from the recommendations and run it in Terminal:",
    heroRepo: (path) => `Current repo: ${path}`,
    license: "License",
    licenseCode: "License code",
    licenseActivate: "Activate",
    licenseRemove: "Remove license",
    licenseFree: (used, limit) => `Free version: ${used} of ${limit} apps offloaded`,
    licenseFreeBody: "Starting, restoring and unpacking offloaded apps is always free. Enter a license code to offload more.",
    licenseFull: "Licensed: unlimited offloaded apps",
    licenseUntil: (date) => `Valid until ${date}`,
    licenseUpdates: (date) => `Updates included until ${date}`,
    licenseExpired: (date) => `Your code expired on ${date}; the free limit applies again`,
    licenseInvalid: "The saved license code is not usable; the free limit applies",
    licenseOk: "License activated",
    licenseRemoved: "License removed",
    errlicense_required: "The free limit is used up. Enter a license code to offload more apps.",
    sessionTiers: "Session tiers",
    coldAfter: (n) => `Cold after ${n} days`,
    offloadedCount: (n) => `${n} offloaded`,
    emptySessions: "No archived sessions",
    tiercold: "Cold",
    daysAgo: (n) => (n <= 0 ? "today" : n === 1 ? "1 day ago" : `${n} days ago`),
    recommend: "Worth offloading",
    recommendWarn: "Poor candidates",
    recommendEmpty: "No apps above the size threshold",
    recommendEmptyHint: "Large apps that have sat unused show up here",
    recommendUnavailable: "Scanning installed apps requires macOS",
    recommendFailed: "Could not load recommendations",
    recommendScanning: "Scanning installed apps…",
    recommendSummary: (count, min) => `${count} ${count === 1 ? "app" : "apps"} · only apps of ${min} or more are listed`,
    couldFree: "Could free about",
    scannedAgo: (iso) => `Scanned ${relativeTime(iso, "en")}`,
    rescan: "Rescan",
    usage: "Disk usage",
    usageScan: "Analyze",
    usageRescan: "Analyze again",
    usageScanning: "Analyzing the disk…",
    usageIntro: "See what takes up your 256G: each app's bundle, cache and data, plus Disklessly's own cache. It only reads sizes and changes nothing.",
    usagePartial: "Some folders timed out and were not fully read; what is missing is counted as System & other.",
    usageFailed: "Could not read disk usage",
    usageHint: "Click a box to zoom in; click the path above to go back.",
    usageTotal: (used, free, total) => `${total} total · ${used} used · ${free} free`,
    usage_disk: "Whole disk",
    usage_apps: "Apps",
    usage_disklessly: "Disklessly",
    usage_personal: "Personal files",
    usage_library: "Library",
    usage_system: "System & other",
    usage_free: "Free",
    usage_bundle: "Bundle",
    usage_cache: "Cache",
    usage_data: "Data",
    usage_repo: "Repo on this Mac",
    usage_state: "State and temp files",
    usage_files: "Loose files",
    usage_rest: (n) => `${n} more`,
    usage_other: "Other",
    copyCommand: "Copy command",
    copyCommandFor: (name) => `Copy command to pack ${name}`,
    copied: (name) => `Copied the pack command for ${name}`,
    copyFailed: "Could not write to the clipboard; copy the command by hand",
    leftoverBackups: (count, size) => `${count} leftover backup${count === 1 ? "" : "s"} (${size}) can be removed`,
    leftoverAdmin: "Removing them needs an administrator.",
    neverUsed: "Never used",
    idleDays: (n) => (n === 1 ? "Last used 1 day ago" : `Last used ${n} days ago`),
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
    devices: "Devices",
    devicesEmpty: "No Macs have registered yet",
    devicesSummary: (n) => `${n} ${n === 1 ? "Mac shares" : "Macs share"} this repo`,
    thisMac: "This Mac",
    conflictCopies: (n) => `${n} iCloud conflict ${n === 1 ? "copy" : "copies"}, not merged`,
    placeholders: (n) => `${n} device ${n === 1 ? "file is" : "files are"} not downloaded`,
    countNone: "None",
  },
};
// i18n:end
window.disklesslyI18n = { copy };

const root = document.documentElement;
const primary = root.getAttribute("data-lang") === "en" ? "en" : "zh";
const langTag = { zh: "zh-Hans", en: "en" };

let lastStatus = null;
let lastRecommend = null;
let recommendError = null;
let loadError = null; // { code, message } when /api/status itself failed
let updatedAt = 0;
let expired = false;
let refreshing = null;
let recommendLoading = false;
const pending = new Map(); // app name -> { kind, jobId, phase }
const view = { search: "", sort: "name", filter: "all" };
const folds = {};

// ---- text -----------------------------------------------------------------

function tl(language, key, ...args) {
  let value = copy[language][key];
  if (value === undefined) {
    console.warn(`disklessly ui: missing ${language} text for "${key}"`);
    value = copy.en[key];
  }
  if (value === undefined) return key;
  return typeof value === "function" ? value(...args) : value;
}

function t(key, ...args) {
  return tl(primary, key, ...args);
}

function has(key) {
  return copy.zh[key] !== undefined && copy.en[key] !== undefined;
}

/// Text in the chosen language, for aria-label and title.
function both(key, ...args) {
  return tl(primary, key, ...args);
}

/// Text in the chosen language as a node.
function bi(key, ...args) {
  return biPair(tl(primary, key, ...args));
}

function one(key, ...args) {
  const node = el("span", "one", tl(primary, key, ...args));
  node.lang = langTag[primary];
  return node;
}

/// Bilingual label followed by a single value: "已用 used 19%".
function biValue(key, value) {
  const node = el("span", "bi-value");
  node.append(bi(key), document.createTextNode(` ${value}`));
  return node;
}

/// The page shows one language, switched from the top bar.
function biPair(first, _unused, className) {
  const node = el("span", ["bi", className].filter(Boolean).join(" "));
  const main = el("span", "bi-p", first);
  main.lang = langTag[primary];
  node.append(main);
  return node;
}

function locale(language) {
  return langTag[language || primary];
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
    throw new ApiError("unauthorized", "", 401, payload);
  }
  if (!response.ok || payload.ok === false) {
    const error = payload.error;
    const code = (error && typeof error === "object" && error.code) || "failed";
    const message = (error && typeof error === "object" ? error.message : error) || response.statusText || "";
    throw new ApiError(code, message, response.status, payload);
  }
  return payload;
}

/// Error key for a stable server code. The raw server text is never shown inline.
function errorKey(code) {
  const key = "err" + (code || "failed");
  return has(key) ? key : "errfailed";
}

/// Localized error line plus the raw server text folded into a Details disclosure.
function errorBlock(code, raw) {
  const wrap = el("div", "err-block");
  wrap.append(bi(errorKey(code)));
  if (raw && code !== "unauthorized") wrap.append(detailsFold(raw));
  return wrap;
}

function detailsFold(raw) {
  const fold = el("details", "raw");
  const summary = el("summary");
  summary.append(bi("details"));
  fold.append(summary, el("code", "", raw));
  return fold;
}

// One size rule everywhere: 1024-based units, one decimal below 100 for GiB and up.
function bytes(value) {
  let n = Math.max(0, Number(value || 0));
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit += 1;
  }
  const digits = unit === 0 || n >= 100 || (unit < 3 && n >= 10) ? 0 : 1;
  const number = new Intl.NumberFormat(locale(), { minimumFractionDigits: 0, maximumFractionDigits: digits }).format(n);
  return `${number} ${units[unit]}`;
}

function relativeTime(iso, language) {
  const when = Date.parse(iso || "");
  if (!Number.isFinite(when)) return "";
  const seconds = Math.round((when - Date.now()) / 1000);
  const format = new Intl.RelativeTimeFormat(locale(language), { numeric: "auto" });
  const steps = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]];
  for (const [unit, size] of steps) {
    if (Math.abs(seconds) >= size) return format.format(Math.round(seconds / size), unit);
  }
  return format.format(0, "second");
}

function duration(seconds) {
  const n = Math.max(0, Number(seconds || 0));
  if (n >= 60 && n % 60 === 0) return one("durationM", n / 60);
  return one("durationS", n);
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

/// Page level for a server health status.
function healthLevel(status) {
  if (status === "ok") return "healthy";
  if (status === "offline") return "offline";
  if (status === "degraded" || status === "missing") return "degraded";
  return "unknown";
}

function kindKey(kind) {
  const key = "kind" + String(kind || "local").toLowerCase();
  return has(key) ? key : null;
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

function applyChrome() {
  root.lang = langTag[primary];
  for (const node of document.querySelectorAll("[data-t]")) {
    node.replaceChildren(node.dataset.mono === "1" ? document.createTextNode(t(node.dataset.t)) : bi(node.dataset.t));
  }
  // Options and other text-only slots take plain text.
  for (const node of document.querySelectorAll("[data-tp]")) setText(node, both(node.dataset.tp));
  for (const node of document.querySelectorAll("[data-t-label]")) node.setAttribute("aria-label", both(node.dataset.tLabel));
  renderUpdated();
}

/// Saves the other language and reloads. Keeps the token, drops any ?lang= override.
function setupLanguageToggle() {
  const button = document.querySelector("#lang-toggle");
  if (!button) return;
  const other = primary === "zh" ? "en" : "zh";
  button.textContent = other === "en" ? "English" : "中文";
  button.lang = langTag[other];
  button.setAttribute("aria-label", other === "en" ? "Switch to English" : "切换到中文");
  button.addEventListener("click", () => {
    document.cookie = `disklessly_lang=${other}; path=/; max-age=31536000; SameSite=Strict`;
    const next = new URL(location.href);
    next.searchParams.delete("lang");
    location.replace(next);
  });
}

function renderUpdated() {
  const node = document.querySelector("#updated");
  if (!updatedAt) {
    node.replaceChildren(bi("updatedNever"));
    return;
  }
  const minutes = Math.floor((Date.now() - updatedAt) / 60000);
  node.replaceChildren(minutes < 1 ? bi("updatedJustNow") : bi("updatedAgo", minutes));
}

function showBanner(code, raw) {
  const banner = document.querySelector("#banner");
  const body = document.querySelector("#banner-text");
  // Only touch the live region when the error changes, so a refresh does not re-announce it.
  const signature = `${code}|${raw}`;
  if (banner.dataset.signature !== signature) {
    banner.dataset.signature = signature;
    body.replaceChildren(errorBlock(code, raw));
  }
  if (banner.hidden) banner.hidden = false;
}

function hideBanner() {
  const banner = document.querySelector("#banner");
  if (!banner.hidden) banner.hidden = true;
  banner.dataset.signature = "";
  document.querySelector("#banner-text").replaceChildren();
}

function showExpired() {
  if (expired) return;
  expired = true;
  hideBanner();
  document.querySelector("#expired").hidden = false;
  document.querySelector("#content").hidden = true;
  document.querySelector("#refresh").disabled = true;
}

/// Toast with a bilingual headline and an optional localized error with raw details.
function toast({ title, error, tone }) {
  const region = document.querySelector("#toasts");
  const item = el("div", `toast ${tone || ""}`.trim());
  const text = el("div", "toast-text");
  text.append(title);
  if (error) text.append(errorBlock(error.code, error.message));
  const close = el("button", "toast-close", "×");
  close.type = "button";
  close.setAttribute("aria-label", both("dismiss"));
  close.addEventListener("click", () => item.remove());
  item.append(text, close);
  region.append(item);
  while (region.children.length > 4) region.firstElementChild.remove();
  let timer = setTimeout(() => item.remove(), tone === "error" ? 15000 : 6000);
  // Keep an error open while the pointer or focus is on it, so its details can be read.
  item.addEventListener("mouseenter", () => clearTimeout(timer));
  item.addEventListener("focusin", () => clearTimeout(timer));
  item.addEventListener("mouseleave", () => { timer = setTimeout(() => item.remove(), 6000); });
}

// ---- icons ----------------------------------------------------------------

// The SVG namespace is not fetched. The pieces stay split so the page source has no URL.
const svgNS = "http" + "://www.w3.org/2000/svg";
const iconOpen = "M8 5v14l11-7z";
const iconDownload = "M11 4h2v8.2l3.3-3.3 1.4 1.4L12 16l-5.7-5.7 1.4-1.4 3.3 3.3V4zM5 18h14v2H5z";
const iconPin = "M14.5 2.6 21.4 9.5l-1.4 1.4-1.1-.4-3.6 3.6.4 3.9-1.4 1.4-3.6-3.6-4.8 4.8-1.4-1.4 4.8-4.8-3.6-3.6L7.1 9.4l3.9.4 3.6-3.6-.4-1.1z";
const iconTrash = "M9 3h6l1 2h4v2H4V5h4l1-2zM6 9h12l-1 11a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2L6 9zm4 2v8h1.6v-8H10zm2.4 0v8H14v-8h-1.6z";
const iconMore = "M6 10.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zm6 0a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zm6 0a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3z";
const iconCopy = "M8 3h10a2 2 0 0 1 2 2v10h-2V5H8V3zM5 7h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2zm0 2v10h10V9H5z";
const iconRefresh = "M12 4a8 8 0 0 1 7.4 5H17v2h6V5h-2v2.3A10 10 0 0 0 2 12h2a8 8 0 0 1 8-8zm8 8a8 8 0 0 1-15.4 3H7v-2H1v6h2v-2.3A10 10 0 0 0 22 12h-2z";
const iconTray = "M5 4h14l3 9v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-6l3-9zm1.4 2-2.3 7H8l1 2h6l1-2h3.9l-2.3-7H6.4z";
const iconAlert = "M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20zm0 2a8 8 0 1 0 0 16 8 8 0 0 0 0-16zm-1 3h2v7h-2V7zm0 9h2v2h-2v-2z";
const iconInfo = "M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20zm0 2a8 8 0 1 0 0 16 8 8 0 0 0 0-16zm-1 6h2v7h-2v-7zm0-3h2v2h-2V7z";

function svgIcon(path, size) {
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size || 16));
  svg.setAttribute("height", String(size || 16));
  svg.setAttribute("aria-hidden", "true");
  svg.classList.add("glyph");
  const drawing = document.createElementNS(svgNS, "path");
  drawing.setAttribute("fill", "currentColor");
  drawing.setAttribute("d", path);
  svg.append(drawing);
  return svg;
}

/// Button with a glyph and a bilingual label. A `blocked` reason keeps the button
/// focusable (aria-disabled) so its tooltip still shows and screen readers hear why.
function actionButton({ labelKey, labelArgs, name, icon, onClick, className, busy, disabled, blocked, iconOnly }) {
  const node = document.createElement("button");
  node.type = "button";
  node.className = ["btn", className, iconOnly ? "icon-only" : ""].filter(Boolean).join(" ");
  const spinner = el("span", "spinner");
  spinner.setAttribute("aria-hidden", "true");
  node.append(svgIcon(icon), spinner);
  const args = labelArgs || [];
  if (!iconOnly) {
    const label = el("span", "btn-label");
    label.append(bi(labelKey, ...args));
    node.append(label);
  }
  node.setAttribute("aria-label", name || both(labelKey, ...args));
  node.title = name || both(labelKey, ...args);
  if (busy) {
    node.setAttribute("aria-busy", "true");
    node.classList.add("is-busy");
  }
  if (disabled) node.disabled = true;
  if (blocked && !disabled) {
    node.setAttribute("aria-disabled", "true");
    node.title = blocked;
    node.setAttribute("aria-description", blocked);
  }
  node.addEventListener("click", (event) => {
    if (node.getAttribute("aria-disabled") === "true") {
      event.preventDefault();
      return;
    }
    onClick(event);
  });
  return node;
}

function letterIcon(name) {
  const letter = (name || "?").trim().charAt(0).toUpperCase() || "?";
  const tones = ["#d9622b", "#2563eb", "#15803d", "#7c3aed", "#dc2626", "#0e7490", "#be185d", "#4f46e5"];
  let hash = 0;
  for (const ch of name || "?") hash = (hash * 31 + ch.charCodeAt(0)) % 9973;
  const node = el("div", "avatar", letter);
  node.style.background = tones[hash % tones.length];
  node.setAttribute("aria-hidden", "true");
  return node;
}

function appIcon(name, imageId) {
  if (!imageId) return letterIcon(name);
  const node = document.createElement("img");
  node.className = "avatar";
  node.alt = "";
  node.width = 40;
  node.height = 40;
  node.src = String(url("/api/icon/" + encodeURIComponent(imageId)));
  node.addEventListener("error", () => node.replaceWith(letterIcon(name)));
  return node;
}

function pill(kind, key, ...args) {
  const node = el("span", `pill ${kind}`);
  node.append(bi(key, ...args));
  return node;
}

function skeleton(rows) {
  const wrap = el("div", "skeleton-wrap");
  for (let i = 0; i < rows; i += 1) {
    const row = el("div", "sk-row");
    row.append(el("div", "sk-avatar"), el("div", "sk-lines"));
    row.lastChild.append(el("div", "sk-line"), el("div", "sk-line short"));
    wrap.append(row);
  }
  const note = el("p", "sk-note");
  note.append(bi("loading"));
  wrap.append(note);
  return wrap;
}

// ---- backend ---------------------------------------------------------------

function healthTitleKey(status) {
  if (status === "ok") return "healthok";
  if (status === "degraded") return "healthdegraded";
  if (status === "missing") return "healthmissing";
  if (status === "offline") return "healthoffline";
  return "healthunknown";
}

/// Second status line: latency when it answered, the timeout or a hint when not.
function healthSubline(backend) {
  const words = el("span", "health-sub");
  const status = backend.health;
  const parts = [];
  if (backend.latencyMs != null && status !== "offline") parts.push(t("latency", backend.latencyMs));
  else if (status === "offline" && backend.timedOut) parts.push(t("timedOut", Math.round(Number(backend.timeoutMs || 5000) / 1000)));
  else if (status === "offline") parts.push(t("offlineHint"));
  else if (status === "missing") parts.push(t("missingHint"));
  words.textContent = parts.join(" · ");
  return words;
}

function renderBackend(backend) {
  const card = document.querySelector("#backend-card");
  const body = document.querySelector("#backend-body");
  const pillSlot = document.querySelector("#backend-pill");
  body.removeAttribute("aria-busy");
  body.replaceChildren();
  pillSlot.replaceChildren();
  if (!backend) {
    card.dataset.level = "offline";
    const status = el("div", "health-line");
    const dot = el("span", "dot");
    dot.setAttribute("aria-hidden", "true");
    const words = el("div");
    words.append(el("strong", "health-title", t("healthoffline")));
    status.append(dot, words);
    body.append(status);
    return;
  }
  const level = healthLevel(backend.health);
  card.dataset.level = level;
  const location = backend.location === "local" ? "local" : "remote";
  pillSlot.append(pill(location === "remote" ? "blue" : "grey", "location" + location));

  const status = el("div", "health-line");
  status.setAttribute("role", "status");
  const dot = el("span", "dot");
  dot.setAttribute("aria-hidden", "true");
  const words = el("div");
  const title = el("strong", "health-title", t(healthTitleKey(backend.health)));
  title.lang = langTag[primary];
  words.append(title, healthSubline(backend));
  status.append(dot, words);
  body.append(status);
  if (backend.healthDetail && backend.healthDetail !== "timeout" && backend.health !== "ok") body.append(detailsFold(backend.healthDetail));

  const facts = el("dl", "kv");
  const activeId = backend.activeId || "local";
  const addFact = (labelKey, value, mono, titleText) => {
    const row = el("div");
    const dt = el("dt");
    dt.append(bi(labelKey));
    const dd = el("dd", mono ? "mono" : "");
    if (typeof value === "string") dd.textContent = value;
    else dd.append(value);
    if (titleText) dd.title = titleText;
    row.append(dt, dd);
    facts.append(row);
  };
  addFact("activeEndpoint", activeId, true, backend.activePlace || "");
  // Local repos already say "Local" in the pill; the kind row would only repeat it.
  const key = kindKey(backend.kind);
  if (backend.kind && backend.kind !== "local") addFact("kind", key ? bi(key) : String(backend.kind), false);
  body.append(facts);

  const endpoints = backend.endpoints || [];
  const head = el("p", "list-label");
  head.append(bi("endpoints"), document.createTextNode(` · ${endpoints.length}`));
  body.append(head);
  const list = el("ul", "endpoints");
  for (const endpoint of endpoints) {
    const row = el("li", endpoint.state === "active" ? "endpoint is-active" : "endpoint");
    const name = el("div", "endpoint-name");
    name.append(el("span", "mono", endpoint.id || ""));
    if (endpoint.place) name.append(el("span", "endpoint-place", endpoint.place));
    name.title = endpoint.place || "";
    row.append(name);
    const state = endpoint.state || "standby";
    if (state === "active") {
      const active = pill("green", "endpointactive");
      active.prepend(el("span", "pill-dot"));
      row.append(active);
    } else {
      const quiet = el("span", "endpoint-state");
      quiet.append(bi("endpoint" + (state === "local" ? "local" : "standby")));
      row.append(quiet);
    }
    list.append(row);
  }
  body.append(list);
}

// ---- cache -----------------------------------------------------------------

/// Big number and unit apart, as on the mockup: "12.4" "GiB".
function heroBytes(value) {
  const text = bytes(value);
  const space = text.lastIndexOf(" ");
  const wrap = el("span", "hero-num");
  wrap.append(el("span", "hero-value", text.slice(0, space)), el("span", "hero-unit", text.slice(space + 1)));
  return wrap;
}

function renderCache(cache) {
  const card = document.querySelector("#cache-card");
  const body = document.querySelector("#cache-body");
  const pillSlot = document.querySelector("#cache-pill");
  body.removeAttribute("aria-busy");
  body.replaceChildren();
  pillSlot.replaceChildren();
  if (!cache) {
    card.dataset.level = "ok";
    body.append(el("p", "muted", "—"));
    return;
  }
  const used = Number(cache.usedBytes || 0);
  const quota = Number(cache.quotaBytes || 0);
  const floor = Number(cache.minFreeBytes || 0);
  const pct = usagePercent(used, quota);
  const level = quota > 0 ? usageLevel(pct) : "ok";
  card.dataset.level = level;
  const pillKind = { ok: "blue", warn: "amber", hot: "red" }[level];
  const pillKey = quota <= 0 ? "levelunset" : { ok: "levelok", warn: "levelnear", hot: "levelcritical" }[level];
  pillSlot.append(pill(pillKind, pillKey));

  const hero = el("div", "hero-line");
  hero.append(heroBytes(used));
  const rest = el("span", "hero-rest");
  if (quota > 0) {
    rest.append(document.createTextNode(`/ ${bytes(quota)} `), bi("quotaWord"), document.createTextNode(" · "), biValue("usedPct", `${pct}%`));
  } else {
    rest.append(bi("quotaUnset"));
  }
  hero.append(rest);
  body.append(hero);

  if (quota > 0) {
    const meter = el("div", "meter");
    const marker = cache.floorMarkerBytes != null ? Math.max(0, Math.min(100, (Number(cache.floorMarkerBytes) / quota) * 100)) : null;
    if (marker != null) {
      const label = el("div", "floor-label");
      label.style.left = `${marker}%`;
      label.classList.toggle("align-end", marker > 70);
      label.classList.toggle("align-start", marker < 30);
      label.append(bi("floorLabel"));
      const keep = el("strong", "", t("floorKeep", bytes(floor)));
      label.append(keep);
      meter.append(label);
    }
    const track = el("div", "track");
    track.setAttribute("role", "meter");
    track.setAttribute("aria-valuemin", "0");
    track.setAttribute("aria-valuemax", String(quota));
    track.setAttribute("aria-valuenow", String(Math.min(used, quota)));
    track.setAttribute("aria-valuetext", `${bytes(used)} / ${bytes(quota)}, ${both("usedPct")} ${pct}%`);
    track.setAttribute("aria-labelledby", "cache-title");
    track.append(el("div", "zone near"), el("div", "zone critical"));
    const fill = el("div", `fill ${level}`);
    fill.style.width = `${Math.max(0, Math.min(100, pct))}%`;
    // The 6 px minimum keeps a small cache visible; an empty cache shows no fill.
    if (!(Number(used) > 0)) fill.classList.add("empty");
    track.append(fill);
    if (marker != null) {
      const line = el("div", "floor-marker");
      line.style.left = `${marker}%`;
      line.title = both("floorMarkerHint", bytes(floor));
      track.append(line);
    }
    meter.append(track);
    const ticks = el("div", "ticks");
    ticks.append(el("span", "", "0"), el("span", "", bytes(quota / 2)), el("span", "", bytes(quota)));
    meter.append(ticks);
    body.append(meter);
    const legend = el("ul", "legend");
    for (const [kind, prefix, key] of [["ok", "", "legendNormal"], ["warn", "≥ 80% ", "legendNear"], ["hot", "≥ 95% ", "legendCritical"]]) {
      const item = el("li");
      const swatch = el("i", `swatch ${kind}`);
      swatch.setAttribute("aria-hidden", "true");
      item.append(swatch, document.createTextNode(prefix), bi(key));
      legend.append(item);
    }
    body.append(legend);
    if (level !== "ok") {
      const note = el("p", `near-note ${level}`);
      note.append(svgIcon(iconAlert, 14), bi("nearNote"));
      body.append(note);
    }
  }

  const stats = el("dl", "stats");
  const left = cache.quotaLeftBytes != null ? Number(cache.quotaLeftBytes) : Math.max(0, quota - used);
  const stat = (value, labelKey, extra) => {
    const row = el("div");
    const dd = el("dd", "stat-value", value);
    const dt = el("dt");
    dt.append(bi(labelKey));
    row.append(dt, dd);
    if (extra) row.append(extra);
    stats.append(row);
  };
  stat(quota > 0 ? bytes(left) : "—", "quotaLeft");
  let disk = null;
  if (cache.diskFreeBytes != null) {
    disk = el("p", "stat-extra");
    disk.append(biValue("diskFree", bytes(cache.diskFreeBytes)));
  }
  stat(bytes(floor), "floor", disk);
  const delay = el("div");
  const delayValue = el("dd", "stat-value");
  delayValue.append(duration(cache.detachDelaySeconds));
  const delayLabel = el("dt");
  delayLabel.append(bi("detach"));
  delay.append(delayLabel, delayValue);
  stats.append(delay);
  body.append(stats);
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

function closeMenus(except) {
  for (const menu of document.querySelectorAll(".menu:not([hidden])")) {
    if (menu === except) continue;
    menu.hidden = true;
    const trigger = menu.previousElementSibling;
    if (trigger) trigger.setAttribute("aria-expanded", "false");
  }
}

/// Folder that holds the app's launcher, which a permanent restore writes back to.
function installDir(app) {
  const full = String(app.installPath || "");
  const cut = full.lastIndexOf("/");
  if (cut <= 0) return "/Applications";
  const dir = full.slice(0, cut);
  const home = dir.match(/^\/Users\/[^/]+(\/.*)?$/);
  return home ? `~${home[1] || ""}` : dir;
}

function overflowMenu(app, busy) {
  const wrap = el("div", "more");
  const menuId = `menu-${String(app.imageId || app.name).replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const menu = el("div", "menu");
  const trigger = actionButton({
    labelKey: "more",
    name: both("moreFor", app.name),
    icon: iconMore,
    className: "quiet",
    iconOnly: true,
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
  menu.id = menuId;
  menu.setAttribute("role", "menu");
  menu.hidden = true;
  const dir = installDir(app);
  const items = [
    [bi("restore"), both("restore"), () => confirmAction("restore", app)],
    [bi("unpack", dir), both("unpack", dir), () => confirmAction("unpack", app)],
  ];
  if (!app.cached) items.unshift([bi("prefetch"), both("prefetchFor", app.name), () => startJob("prefetch", app)]);
  for (const [label, name, run] of items) {
    const item = el("button", "menuitem");
    item.append(label);
    item.type = "button";
    item.setAttribute("role", "menuitem");
    item.setAttribute("aria-label", name);
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

function statusPills(app, job) {
  const pills = el("div", "pills");
  if (app.needsResolution || app.state === "needsResolution") pills.append(pill("red attention", "stateAttention"));
  if (job && job.phase === "download") pills.append(pill("blue downloading", "stateDownloading"));
  else if (app.mounted || app.state === "running") pills.append(pill("blue mounted", "stateMounted"));
  if (app.cached) {
    const node = pill("green", "cached");
    node.prepend(el("span", "pill-dot"));
    pills.append(node);
  } else {
    pills.append(pill("grey", "remote"));
  }
  if (app.pinned) {
    const node = pill("amber", "pinned");
    node.prepend(svgIcon(iconPin, 12));
    pills.append(node);
  }
  if (app.restored && !app.needsResolution) pills.append(pill("grey", "restored"));
  return pills;
}

function cacheCell(app, quota) {
  const cell = el("div", "cell cache-cell");
  if (!app.cached) {
    const line = el("div", "cache-size muted");
    line.append(bi("notCached"));
    const sub = el("div", "cache-sub", `${t("toDownload")} ${bytes(app.imageBytes)}`);
    cell.append(line, sub);
    return cell;
  }
  cell.append(el("div", "cache-size", bytes(app.cachedBytes)));
  if (quota > 0) {
    const sharePct = Math.max(0, Math.min(100, (Number(app.cachedBytes || 0) / quota) * 100));
    const shownPct = sharePct >= 10 ? Math.round(sharePct) : Math.round(sharePct * 10) / 10;
    const bar = el("div", "share");
    bar.setAttribute("role", "meter");
    bar.setAttribute("aria-valuemin", "0");
    bar.setAttribute("aria-valuemax", "100");
    bar.setAttribute("aria-valuenow", String(Math.round(sharePct)));
    bar.setAttribute("aria-label", both("share", shownPct));
    bar.title = both("share", shownPct);
    const fill = el("span");
    fill.style.width = `${Math.max(sharePct, 1.5)}%`;
    bar.append(fill);
    cell.append(bar);
  }
  return cell;
}

function emptyState() {
  const empty = el("div", "state-empty");
  const icon = el("div", "tray");
  icon.append(svgIcon(iconTray, 22));
  empty.append(icon, el("strong", "", t("emptyApps")));
  empty.append(el("span", "muted", t("emptyAppsHint")));
  return empty;
}

/// Red panel with the endpoint, the reason, raw details and Retry. Only an
/// `offline` code claims the backend is unreachable; anything else (a corrupt
/// manifest on a reachable repo, say) reads as "couldn't load the app list".
function errorState(code, raw) {
  const offline = !code || code === "offline";
  const titleKey = offline ? "unreachable" : "appsLoadFailed";
  const panel = el("div", "state-error");
  panel.setAttribute("role", "alert");
  const box = el("div", "error-box");
  const head = el("div", "error-head");
  head.append(svgIcon(iconAlert, 18));
  const words = el("div");
  words.append(el("strong", "", t(titleKey)));
  head.append(words);
  box.append(head);
  const backend = lastStatus && lastStatus.backend;
  const where = (backend && (backend.activeId || "local")) || "";
  const reasonParts = [where];
  if (offline && backend && backend.timedOut) reasonParts.push(t("timedOut", Math.round(Number(backend.timeoutMs || 5000) / 1000)));
  else if (code) reasonParts.push(t(errorKey(code)));
  box.append(el("p", "error-where mono", reasonParts.filter(Boolean).join(" · ")));
  if (raw) box.append(detailsFold(raw));
  panel.append(box);
  const retry = actionButton({ labelKey: "retry", icon: iconRefresh, className: "retry", onClick: () => retryNow() });
  panel.append(retry);
  return panel;
}

function renderAppsSummary(apps) {
  const node = document.querySelector("#apps-summary");
  if (!apps) {
    node.replaceChildren();
    return;
  }
  const cached = apps.filter((app) => app.cached);
  const size = bytes(cached.reduce((sum, app) => sum + Number(app.cachedBytes || 0), 0));
  const pinned = apps.filter((app) => app.pinned).length;
  node.replaceChildren(one("appsSummary", apps.length, cached.length, size, pinned));
}

function renderApps(list, failure) {
  const rootNode = document.querySelector("#app-list");
  const tools = document.querySelector("#list-tools");
  const head = document.querySelector("#table-head");
  const focusedKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : "";
  rootNode.replaceChildren();
  rootNode.removeAttribute("aria-busy");
  const apps = list || [];
  renderAppsSummary(failure && !apps.length ? null : apps);
  tools.hidden = apps.length < 2;
  head.hidden = !apps.length;
  if (failure && !apps.length) {
    rootNode.append(errorState(failure.code, failure.message));
    return;
  }
  if (!apps.length) {
    rootNode.append(emptyState());
    return;
  }
  const shown = visibleApps(apps);
  if (!shown.length) {
    rootNode.append(el("div", "state-note", both("noMatches")));
    return;
  }
  const quota = Number((lastStatus && lastStatus.cache && lastStatus.cache.quotaBytes) || 0);
  for (const app of shown) {
    const job = pending.get(app.name);
    const busy = Boolean(job);
    const row = el("article", "app-row");
    row.dataset.app = app.name || "";
    row.dataset.state = app.state || "";
    if (busy) row.setAttribute("aria-busy", "true");

    const who = el("div", "cell app-cell");
    who.append(appIcon(app.name, app.imageId));
    const words = el("div", "app-words");
    words.append(el("h3", "app-name", app.name || ""));
    const meta = el("div", "app-meta");
    if (app.version) meta.append(document.createTextNode(`v${String(app.version).replace(/^v/, "")} · `));
    const modeKey = "mode" + (app.mode || "mount");
    meta.append(has(modeKey) ? bi(modeKey) : document.createTextNode(String(app.mode || "")));
    words.append(meta);
    const holders = (app.devices || []).filter(Boolean);
    const extra = [app.lastUsed ? t("lastUsedAt", app.lastUsed) : "", holders.length ? t("onDevices", holders.join(", ")) : ""].filter(Boolean);
    if (extra.length) words.append(el("div", "app-extra", extra.join(" · ")));
    if (job) {
      const line = el("div", "job-line");
      line.append(bi("phase" + (job.phase || "queued")));
      words.append(line);
    }
    who.append(words);

    const status = el("div", "cell status-cell");
    status.append(statusPills(app, job));

    const actions = el("div", "cell actions");
    const isBusy = (kind) => busy && job.kind === kind;
    const open = actionButton({ labelKey: "open", name: both("openFor", app.name), icon: iconOpen, className: "quiet", iconOnly: true, busy: isBusy("launch"), disabled: busy, onClick: () => startJob("launch", app) });
    const pinKind = app.pinned ? "unpin" : "pin";
    const pinButton = actionButton({ labelKey: pinKind, icon: iconPin, className: "tint", busy: isBusy("pin") || isBusy("unpin"), disabled: busy, onClick: () => startJob(pinKind, app) });
    pinButton.setAttribute("aria-pressed", String(Boolean(app.pinned)));
    let second;
    if (app.cached) {
      const blocked = app.pinned ? both("evictPinned") : app.mounted ? both("evictMounted") : "";
      second = actionButton({ labelKey: "evict", icon: iconTrash, className: "danger-outline", busy: isBusy("evict"), disabled: busy, blocked, onClick: () => confirmAction("evict", app) });
      second.dataset.key = `${app.name}:evict`;
    } else {
      second = actionButton({ labelKey: "prefetch", name: both("prefetchFor", app.name), icon: iconDownload, className: "outline", busy: isBusy("prefetch"), disabled: busy, onClick: () => startJob("prefetch", app) });
      second.dataset.key = `${app.name}:prefetch`;
    }
    open.dataset.key = `${app.name}:launch`;
    pinButton.dataset.key = `${app.name}:pin`;
    actions.append(open, pinButton, second, overflowMenu(app, busy));

    row.append(who, status, cacheCell(app, quota), actions);
    rootNode.append(row);
  }
  if (focusedKey) {
    const again = rootNode.querySelector(`[data-key="${CSS.escape(focusedKey)}"]`);
    if (again && !again.disabled) again.focus();
  }
}

// ---- jobs -----------------------------------------------------------------

function confirmAction(kind, app) {
  const dialog = document.querySelector("#confirm");
  const dir = installDir(app);
  const size = bytes(app.cachedBytes || app.imageBytes);
  const spec = {
    evict: { title: ["confirmEvictTitle", app.name], body: ["confirmEvictBody", size], ok: "confirmEvictOk", danger: true },
    restore: { title: ["confirmRestoreTitle", app.name], body: ["confirmRestoreBody"], ok: "confirmRestoreOk", danger: false },
    pack: { title: ["confirmPackTitle", app.name], body: ["confirmPackBody", size], ok: "confirmPackOk", danger: false },
    unpack: { title: ["confirmUnpackTitle", app.name, dir], body: ["confirmUnpackBody", app.installPath || `${dir}/${app.name}.app`], ok: "confirmUnpackOk", danger: true },
  }[kind];
  const title = document.querySelector("#confirm-title");
  title.replaceChildren(document.createTextNode(t(...spec.title)));
  const body = document.querySelector("#confirm-body");
  body.replaceChildren(document.createTextNode(t(...spec.body)));
  const ok = document.querySelector("#confirm-ok");
  ok.replaceChildren(bi(spec.ok));
  ok.className = spec.danger ? "btn danger" : "btn primary";
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
  } else if (window.confirm(`${title.textContent}\n\n${body.textContent}`)) {
    startJob(kind, app);
  }
}

function jobTitle(key, kind, name) {
  return biPair(tl(primary, key, tl(primary, "action" + kind), name));
}

async function startJob(kind, app) {
  if (pending.has(app.name)) return;
  pending.set(app.name, { kind, jobId: "", phase: "queued" });
  rerenderApps();
  try {
    // Evict never forces from the page: a pinned app is refused by the server too.
    const payload = kind === "evict" ? { app: app.name, force: false } : kind === "pack" ? { app: app.name, path: app.path } : { app: app.name };
    const started = await api(`/api/${kind}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
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
    toast({ title: jobTitle("jobFailed", kind, app.name), error: { code: error.code, message: error.message }, tone: "error" });
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
    if (job.state === "done") toast({ title: jobTitle("jobDone", kind, name), tone: "ok" });
    else toast({ title: jobTitle("jobFailed", kind, name), error: { code: job.error && job.error.code, message: job.error && job.error.message }, tone: "error" });
    break;
  }
  pending.delete(name);
  await load();
  if (kind === "pack") loadRecommendations(true);
}

function adoptServerJobs(status) {
  for (const job of (status && status.jobs) || []) {
    if (!job.app || pending.has(job.app)) continue;
    pending.set(job.app, { kind: job.kind, jobId: job.id, phase: job.phase });
    pollJob(job.app, job.kind, job.id);
  }
}

function rerenderApps() {
  if (lastRecommend && !recommendLoading) renderRecommend(lastRecommend, null);
  if (lastStatus) renderApps(lastStatus.apps || [], lastStatus.appsError ? { code: appsErrorCode(lastStatus), message: lastStatus.appsError } : null);
}

/// Server code for an app-list failure; older servers sent only the text.
function appsErrorCode(status) {
  return status.appsErrorCode || "failed";
}

// ---- sessions -------------------------------------------------------------

function renderSessions(sessions) {
  const summary = document.querySelector("#sessions-summary");
  const list = document.querySelector("#sessions");
  list.replaceChildren();
  summary.replaceChildren();
  const offloaded = (sessions && sessions.offloaded) || [];
  if (sessions) {
    const days = Number(sessions.coldDays || 14);
    summary.append(bi("coldAfter", days), document.createTextNode(" · "), one("offloadedCount", offloaded.length));
  }
  if (!offloaded.length) {
    const empty = el("li", "state-note");
    empty.append(bi("emptySessions"));
    list.append(empty);
    return;
  }
  const sorted = [...offloaded].sort((a, b) => (Date.parse(b.modified || "") || 0) - (Date.parse(a.modified || "") || 0));
  for (const entry of sorted) {
    const item = el("li", "session-row");
    // Only cold files are archived, so every offloaded row is cold.
    item.append(pill("grey", "tiercold"));
    item.append(el("span", "session-tool", entry.tool || ""));
    const path = el("span", "session-path mono", entry.displayPath || entry.path || "");
    path.title = [entry.path, entry.preview].filter(Boolean).join("\n");
    item.append(path);
    const age = entry.ageDays != null ? Number(entry.ageDays) : Math.max(0, Math.floor((Date.now() - (Date.parse(entry.modified || "") || Date.now())) / 86400000));
    const ageNode = el("span", "session-age", t("daysAgo", age));
    item.append(ageNode);
    list.append(item);
  }
}

// ---- recommendations ------------------------------------------------------

function recommendReason(app, language) {
  const say = (key, ...args) => tl(language || primary, key, ...args);
  const warnings = app.warnings || [];
  if (warnings.length) return warnings.map((code) => (has("warn" + code) ? say("warn" + code) : code)).join("; ");
  const parts = [];
  if (app.neverUsed) parts.push(say("neverUsed"));
  else if (app.daysIdle != null) parts.push(say("idleDays", Number(app.daysIdle)));
  if (app.macAppStore) parts.push(say("restoreNeeded"));
  if (app.sizeIncomplete) parts.push(say("sizeBound"));
  if (app.alreadyInRepo) {
    const devices = app.otherDevices || [];
    parts.push(say("alreadyInRepo") + (devices.length ? ` (${devices.join(", ")})` : ""));
  }
  return parts.join("; ");
}

function modeKeyFor(mode) {
  const key = "mode" + (mode || "mount");
  return has(key) ? key : "modemount";
}

function packCommand(path) {
  const escaped = String(path || "").replace(/(["\\$`])/g, "\\$1");
  return `disklessly pack "${escaped}"`;
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
  const total = bytes(items.reduce((sum, item) => sum + Number(item.sizeBytes || 0), 0));
  line.append(biPair(`${tl(primary, "leftoverBackups", items.length, total)} ${tl(primary, "leftoverAdmin")}`));
  for (const item of items) paths.append(el("li", "mono path", item.path || ""));
}

function renderScanLine() {
  const scanned = document.querySelector("#recommend-scanned");
  const rescan = document.querySelector("#rescan");
  scanned.replaceChildren();
  if (recommendLoading) {
    scanned.append(bi("recommendScanning"));
    rescan.setAttribute("aria-busy", "true");
    rescan.disabled = true;
  } else {
    if (lastRecommend && lastRecommend.scannedAt) scanned.append(bi("scannedAgo", lastRecommend.scannedAt));
    rescan.removeAttribute("aria-busy");
    rescan.disabled = false;
  }
}

function renderRecommend(report, failure) {
  const summary = document.querySelector("#recommend-summary");
  const total = document.querySelector("#recommend-total");
  const list = document.querySelector("#recommend-list");
  const warnTitle = document.querySelector("#recommend-warn-title");
  const warnings = document.querySelector("#recommend-warnings");
  list.replaceChildren();
  warnings.replaceChildren();
  summary.replaceChildren();
  list.removeAttribute("aria-busy");
  renderScanLine();
  if (!report) {
    total.hidden = true;
    const empty = el("div", "state-note");
    empty.append(bi("recommendFailed"));
    if (failure) empty.append(errorBlock(failure.code, failure.message));
    list.append(empty);
    warnTitle.hidden = true;
    renderLeftovers(null);
    return;
  }
  const apps = report.recommendations || [];
  if (report.scan === "unavailable") {
    total.hidden = true;
    summary.append(bi("recommendUnavailable"));
  } else {
    total.hidden = !apps.length;
    total.replaceChildren(biValue("couldFree", bytes(report.estimatedFreedBytes || 0)));
    summary.append(one("recommendSummary", apps.length, bytes(report.minSizeBytes || 0)));
  }
  if (!apps.length && report.scan !== "unavailable") {
    const empty = el("div", "state-note");
    empty.append(bi("recommendEmpty"), el("br"), bi("recommendEmptyHint"));
    list.append(empty);
  }
  for (const app of apps) {
    const row = el("article", "rec-row");
    const who = el("div", "app-cell");
    who.append(appIcon(app.name));
    const words = el("div", "app-words");
    const nameLine = el("div", "rec-name");
    nameLine.append(el("h3", "app-name", app.name || ""), pill(app.macAppStore ? "amber" : "blue", modeKeyFor(app.suggestedMode)));
    words.append(nameLine, el("div", "app-meta", [bytes(app.sizeBytes), app.bundleId || ""].filter(Boolean).join(" · ")));
    const reason = recommendReason(app, primary);
    if (reason) words.append(biPair(reason, "", "rec-reason"));
    const command = packCommand(app.path);
    words.append(el("code", "inline-command", command));
    who.append(words);
    const actions = el("div", "actions");
    const job = pending.get(app.name);
    const packing = Boolean(job && job.kind === "pack");
    actions.append(actionButton({
      labelKey: packing ? "offloading" : "offloadNow",
      name: both("offloadNowFor", app.name),
      icon: iconTray,
      className: "primary",
      busy: packing,
      disabled: Boolean(job),
      onClick: () => confirmAction("pack", { name: app.name, path: app.path, cachedBytes: app.sizeBytes }),
    }));
    actions.append(actionButton({
      labelKey: "copyCommand",
      name: both("copyCommandFor", app.name),
      icon: iconCopy,
      className: "outline",
      onClick: async () => {
        if (await copyText(command)) toast({ title: bi("copied", app.name), tone: "ok" });
        else toast({ title: bi("copyFailed"), tone: "error" });
      },
    }));
    row.append(who, actions);
    list.append(row);
  }
  const poor = report.warnings || [];
  warnTitle.hidden = poor.length === 0;
  for (const app of poor) {
    const item = el("li", "poor-row");
    const top = el("div", "rec-name");
    top.append(el("span", "app-name", app.name || ""), pill("grey", modeKeyFor(app.suggestedMode)));
    item.append(top, el("div", "mono path", app.path || ""), biPair(recommendReason(app, primary), "", "rec-reason"));
    warnings.append(item);
  }
  renderLeftovers(report);
}

// ---- devices, onboarding --------------------------------------------------

function setFold(id, countId, count) {
  const fold = document.querySelector(id);
  const counter = document.querySelector(countId);
  counter.replaceChildren(count ? document.createTextNode(String(count)) : bi("countNone"));
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
  summary.replaceChildren();
  const devices = (status && status.devices) || [];
  const conflicts = (status && status.deviceConflicts) || [];
  const placeholders = (status && status.devicePlaceholders) || [];
  const notes = [];
  if (status && devices.length) notes.push(["devicesSummary", devices.length]);
  if (conflicts.length) notes.push(["conflictCopies", conflicts.length]);
  if (placeholders.length) notes.push(["placeholders", placeholders.length]);
  notes.forEach(([key, n], index) => {
    if (index) summary.append(document.createTextNode(" · "));
    summary.append(bi(key, n));
  });
  summary.hidden = !notes.length;
  setFold("#devices-section", "#devices-count", devices.length);
  if (!devices.length) {
    const empty = el("li", "state-note");
    empty.append(bi(status ? "devicesEmpty" : "loadFailed"));
    list.append(empty);
    return;
  }
  for (const device of devices) {
    const item = el("li", "device-row");
    const top = el("div", "rec-name");
    top.append(el("span", "app-name", device.displayName || device.hostname || device.deviceId || ""));
    if (device.self) top.append(pill("blue", "thisMac"));
    item.append(top);
    item.append(el("div", "mono path", [device.hostname, device.arch, device.osVersion].filter(Boolean).join(" · ")));
    const images = device.images || [];
    const detail = images.map((image) => `${image.bundleId || image.imageId} ${image.version || ""}`.trim()).join(", ");
    if (detail) item.append(el("p", "muted small", detail));
    list.append(item);
  }
}

function renderOnboarding(status) {
  const hero = document.querySelector("#onboarding");
  const show = Boolean(status) && !status.appsError && !((status.apps || []).length);
  hero.hidden = !show;
  const repo = status && status.backend && status.backend.repoPath;
  const slot = document.querySelector("#hero-repo");
  slot.replaceChildren(repo ? bi("heroRepo", repo) : document.createTextNode(""));
}

// ---- load -----------------------------------------------------------------

function render(status) {
  lastStatus = status;
  applyChrome();
  renderOnboarding(status);
  renderBackend(status.backend || null);
  renderCache(status.cache || null);
  if (status.appsError) showBanner(appsErrorCode(status), status.appsError);
  rerenderApps();
  renderDevices(status);
  renderSessions(status.sessions || null);
}

function renderFailure() {
  applyChrome();
  renderOnboarding(null);
  renderBackend(null);
  renderCache(null);
  renderApps([], loadError || { code: "offline", message: "" });
  renderDevices(null);
  renderSessions(null);
}

// ---- license --------------------------------------------------------------

let licenseState = null;

function renderLicense(info) {
  licenseState = info;
  const summary = document.querySelector("#license-summary");
  const detail = document.querySelector("#license-detail");
  const remove = document.querySelector("#license-remove");
  const input = document.querySelector("#license-code");
  input.setAttribute("aria-label", both("licenseCode"));
  if (!info) { summary.replaceChildren(); detail.replaceChildren(); remove.hidden = true; return; }
  const lines = [];
  if (info.state === "licensed") {
    summary.replaceChildren(bi("licenseFull"));
    if (info.expires) lines.push(one("licenseUntil", info.expires));
    if (info.updatesUntil) lines.push(one("licenseUpdates", info.updatesUntil));
  } else if (info.state === "expired") {
    summary.replaceChildren(bi("licenseFree", info.offloaded, info.freeLimit));
    lines.push(one("licenseExpired", info.expires || "?"));
  } else if (info.state === "invalid") {
    summary.replaceChildren(bi("licenseFree", info.offloaded, info.freeLimit));
    lines.push(one("licenseInvalid"));
  } else {
    summary.replaceChildren(bi("licenseFree", info.offloaded, info.freeLimit));
    lines.push(bi("licenseFreeBody"));
  }
  detail.replaceChildren(...lines.flatMap((node, i) => (i ? [document.createElement("br"), node] : [node])));
  remove.hidden = info.state === "free";
}

async function loadLicense() {
  try { renderLicense(await api("/api/license")); } catch (error) { if (error.code !== "unauthorized") renderLicense(null); }
}

async function submitLicense(event) {
  event.preventDefault();
  const input = document.querySelector("#license-code");
  const code = input.value.trim();
  if (!code) return;
  try {
    renderLicense(await api("/api/license/activate", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code }) }));
    input.value = "";
    toast({ title: bi("licenseOk"), tone: "ok" });
  } catch (error) {
    toast({ title: bi("licenseActivate"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

async function removeLicense() {
  try {
    renderLicense(await api("/api/license/deactivate", { method: "POST" }));
    toast({ title: bi("licenseRemoved"), tone: "ok" });
  } catch (error) {
    toast({ title: bi("licenseRemove"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}


async function loadRecommendations(rescan) {
  if (recommendLoading) return;
  recommendLoading = true;
  renderScanLine();
  try {
    lastRecommend = await api(rescan ? "/api/recommend?rescan=1" : "/api/recommend");
    recommendError = null;
  } catch (error) {
    if (error.code === "unauthorized") return;
    recommendError = { code: error.code, message: error.message };
  } finally {
    recommendLoading = false;
  }
  if (lastRecommend) renderRecommend(lastRecommend, null);
  else renderRecommend(null, recommendError);
}

// ---- disk usage -----------------------------------------------------------

let usageData = null;
let usageFocus = []; // child indexes from the root
let usageTimer = null;
let usageAutoStarted = false;

const USAGE_LEGEND = ["bundle", "cache", "data", "offloaded", "personal", "library", "system", "free"];
const usageKindText = { bundle: "usage_bundle", cache: "usage_cache", data: "usage_data", offloaded: "usage_disklessly", personal: "usage_personal", library: "usage_library", system: "usage_system", free: "usage_free" };

function usageLabel(node, parent) {
  const key = node.key;
  if (key === "rest") return t("usage_rest", node.name);
  if (["bundle", "cache", "data"].includes(key) && (!parent || parent.key !== "disklessly")) return t("usage_" + key);
  if (key && has("usage_" + key) && !["cache"].includes(key)) return t("usage_" + key);
  return node.name;
}

function usageLabelBoth(node, parent) {
  const key = node.key;
  const keyed = (k, ...a) => both("usage_" + k, ...a);
  if (key === "rest") return keyed("rest", node.name);
  if (["bundle", "cache", "data"].includes(key) && (!parent || parent.key !== "disklessly")) return keyed(key);
  if (key && has("usage_" + key) && key !== "cache") return keyed(key);
  return node.name;
}

function usageNodeAt(path) {
  let node = usageData.tree;
  const trail = [{ node, parent: null }];
  for (const index of path) {
    const child = node.children && node.children[index];
    if (!child) break;
    trail.push({ node: child, parent: node });
    node = child;
  }
  return trail;
}

function renderUsage() {
  const chart = document.querySelector("#usage-chart");
  const crumbs = document.querySelector("#usage-crumbs");
  const legend = document.querySelector("#usage-legend");
  const summary = document.querySelector("#usage-summary");
  const scanned = document.querySelector("#usage-scanned");
  const button = document.querySelector("#usage-scan");
  const tip = document.querySelector("#usage-tip");
  summary.replaceChildren();
  scanned.replaceChildren();
  const scanning = usageData && usageData.state === "scanning";
  button.disabled = Boolean(scanning);
  button.firstElementChild.replaceChildren(bi(usageData && usageData.tree ? "usageRescan" : "usageScan"));
  if (scanning) button.setAttribute("aria-busy", "true"); else button.removeAttribute("aria-busy");
  if (!usageData || !usageData.tree) {
    chart.hidden = crumbs.hidden = legend.hidden = tip.hidden = true;
    summary.append(bi(scanning ? "usageScanning" : "usageIntro"));
    return;
  }
  if (usageData.scannedAt) scanned.append(bi("scannedAgo", usageData.scannedAt));
  const root = usageData.tree;
  const free = (root.children.find((c) => c.key === "free") || {}).bytes || 0;
  summary.append(one("usageTotal", bytes(root.bytes - free), bytes(free), bytes(root.bytes)));
  if (usageData.partial) summary.append(el("br"), bi("usagePartial"));
  if (scanning) summary.append(el("br"), bi("usageScanning"));
  summary.append(el("br"), bi("usageHint"));

  const trail = usageNodeAt(usageFocus);
  crumbs.hidden = false;
  crumbs.replaceChildren();
  trail.forEach((step, depth) => {
    if (depth) crumbs.append(el("span", "usage-sep", "›"));
    const last = depth === trail.length - 1;
    const label = depth === 0 ? usageLabel(step.node, null) : usageLabel(step.node, step.parent);
    const item = el(last ? "span" : "button", last ? "usage-crumb current" : "usage-crumb", label);
    if (!last) {
      item.type = "button";
      item.addEventListener("click", () => { usageFocus = usageFocus.slice(0, depth); renderUsage(); });
    }
    crumbs.append(item);
  });

  const focus = trail[trail.length - 1].node;
  chart.hidden = false;
  chart.replaceChildren();
  const levels = 4;
  const rowHeight = 30;
  chart.style.height = `${levels * rowHeight}px`;
  const draw = (node, parent, left, width, depth, path) => {
    if (depth >= levels || width < 0.35) return;
    const box = el("button", `usage-box u-${node.kind}`);
    box.type = "button";
    box.style.left = `${left}%`;
    box.style.width = `calc(${width}% - 2px)`;
    box.style.top = `${depth * rowHeight}px`;
    box.style.height = `${rowHeight - 2}px`;
    const label = usageLabel(node, parent);
    const pct = focus.bytes ? `${((node.bytes / focus.bytes) * 100).toFixed(node.bytes / focus.bytes < 0.1 ? 1 : 0)}%` : "";
    if (width > 4) box.append(el("span", "usage-name", label), width > 9 ? el("span", "usage-size", bytes(node.bytes)) : document.createTextNode(""));
    const full = usageLabelBoth(node, parent);
    const named = node.key && ["bundle", "cache", "data"].includes(node.key) && parent && parent.name && parent.key == null ? `${parent.name} · ${full}` : full;
    box.title = `${named} · ${bytes(node.bytes)} · ${pct}`;
    box.setAttribute("aria-label", box.title);
    const zoomable = Boolean(node.children && node.children.length) && depth > 0;
    if (zoomable) box.classList.add("zoomable");
    box.addEventListener("click", () => {
      if (!zoomable) return;
      usageFocus = path;
      renderUsage();
    });
    box.addEventListener("mouseenter", () => { tip.hidden = false; tip.textContent = box.title; });
    chart.append(box);
    let x = left;
    (node.children || []).forEach((child, i) => {
      const w = node.bytes ? (child.bytes / node.bytes) * width : 0;
      draw(child, node, x, w, depth + 1, [...path, i]);
      x += w;
    });
  };
  // The focused box fills the top row; its children and theirs sit below it.
  draw(focus, trail.length > 1 ? trail[trail.length - 2].node : null, 0, 100, 0, usageFocus);
  // Row 0 is the focus itself and never zooms; children are found by their parent's list.
  const rootBox = chart.firstElementChild;
  if (rootBox) rootBox.classList.remove("zoomable");

  legend.hidden = false;
  legend.replaceChildren();
  for (const kind of USAGE_LEGEND) {
    const item = el("li", "usage-legend-item");
    item.append(el("span", `usage-swatch u-${kind}`), bi(usageKindText[kind]));
    legend.append(item);
  }
}

async function loadUsage() {
  clearTimeout(usageTimer);
  try {
    usageData = await api("/api/usage");
  } catch (error) {
    if (error.code === "unauthorized") return;
    document.querySelector("#usage-summary").replaceChildren(bi("usageFailed"), errorBlock(error.code, error.message));
    return;
  }
  // Nothing measured since the app started: analyze right away, it only reads sizes.
  if (usageData.state === "idle" && !usageAutoStarted) {
    usageAutoStarted = true;
    return startUsageScan();
  }
  renderUsage();
  if (usageData.state === "scanning" && !expired) usageTimer = setTimeout(loadUsage, 2000);
}

async function startUsageScan() {
  try {
    usageData = await api("/api/usage/scan", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    usageFocus = [];
    renderUsage();
    clearTimeout(usageTimer);
    usageTimer = setTimeout(loadUsage, 1500);
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("usageFailed"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

async function load() {
  if (expired) return;
  let status;
  try {
    status = await api("/api/status");
  } catch (error) {
    if (error.code === "unauthorized") return;
    loadError = { code: error.code, message: error.message };
    showBanner(error.code, error.message);
    if (!lastStatus) renderFailure();
    else renderBackend(Object.assign({}, lastStatus.backend, { health: "offline", latencyMs: null }));
    return;
  }
  loadError = null;
  updatedAt = Date.now();
  if (!status.appsError) hideBanner();
  adoptServerJobs(status);
  render(status);
  loadLicense();
  loadUsage();
}

function refresh() {
  // Coalesce overlapping refreshes instead of a page-wide busy flag; actions run independently.
  if (!refreshing) {
    const button = document.querySelector("#refresh");
    button.setAttribute("aria-busy", "true");
    refreshing = Promise.all([load(), loadRecommendations(false)]).finally(() => {
      refreshing = null;
      button.removeAttribute("aria-busy");
    });
  }
  return refreshing;
}

/// Retry asks for a fresh backend probe first, so a recovered backend shows at once.
async function retryNow() {
  try { await api("/api/health?fresh=1"); } catch (e) {}
  return refresh();
}

// ---- wiring ---------------------------------------------------------------

document.querySelector("#refresh").addEventListener("click", refresh);
document.querySelector("#retry").addEventListener("click", retryNow);
document.querySelector("#rescan").addEventListener("click", () => loadRecommendations(true));
document.querySelector("#usage-scan").addEventListener("click", startUsageScan);
document.querySelector("#license-form").addEventListener("submit", submitLicense);
document.querySelector("#license-remove").addEventListener("click", removeLicense);
document.querySelector("#icon-backfill").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  if (button.getAttribute("aria-busy") === "true") return;
  button.setAttribute("aria-busy", "true");
  button.disabled = true;
  try {
    const report = await api("/api/icons/backfill", { method: "POST" });
    const warnings = report.warnings || [];
    if (warnings.length) toast({ title: bi("backfillIcons"), error: { code: "failed", message: warnings.join("; ") }, tone: "error" });
    await load();
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("backfillIcons"), error: { code: error.code, message: error.message }, tone: "error" });
  } finally {
    button.removeAttribute("aria-busy");
    button.disabled = false;
  }
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
setInterval(renderUpdated, TICK_MS);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !expired) refresh();
});

applyChrome();
setupLanguageToggle();
document.querySelector("#app-list").replaceChildren(skeleton(3));
refresh();
