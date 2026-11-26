// Loopback management page. The token stays in the page URL; the server rejects
// calls that do not present it. No remote assets and no embedded secrets.
//
// The page shows one language (Chinese or English), chosen in index.html and switched
// from the top bar. All text lives in `copy`.

const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const REFRESH_MS = 20000;
const JOB_POLL_MS = 700;
const USAGE_STALE_MS = 5 * 60 * 1000;
// Key in `pending` for the leftover backup cleanup job (not an app name).
const LEFTOVER_JOB = "backups";
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
    backend: "网盘",
    locationremote: "联网存放",
    locationlocal: "存在本机",
    healthok: "运行正常",
    healthdegraded: "缓慢",
    healthmissing: "还没准备好",
    healthoffline: "离线",
    healthunknown: "正在检查",
    latency: (ms) => `延迟 ${ms} ms`,
    timedOut: (s) => `超时 ${s} s`,
    missingHint: "能连上，但里面还没有 Disklessly 文件夹（缺少 repo.json）",
    offlineHint: "已缓存的应用仍可打开",
    activeEndpoint: "正在用",
    kind: "类型",
    endpoints: "存放位置",
    endpointactive: "正在用",
    endpointstandby: "备用",
    endpointlocal: "本机",
    kindlocal: "本机文件夹",
    kindicloud: "iCloud 云盘",
    kindsmb: "NAS 共享盘（SMB）",
    kindnfs: "NAS 共享盘（NFS）",
    kindwebdav: "WebDAV 网盘",
    kindopenlist: "OpenList",
    kinds3: "S3 存储",
    cache: "本机缓存",
    levelok: "空间充足",
    levelnear: "快到上限",
    levelcritical: "快满了",
    levelunset: "没设上限",
    quotaWord: "上限",
    usedPct: "已用",
    floorLabel: "硬盘至少留出",
    floorKeep: (size) => `保留 ${size}`,
    floorMarkerHint: (size) => `缓存长到这里时，硬盘剩余空间会降到要留出的 ${size}`,
    legendNormal: "正常",
    legendNear: "接近",
    legendCritical: "临界",
    quotaLeft: "离上限还有",
    floor: "硬盘至少留出",
    diskFree: "硬盘剩余",
    detachDelay: "应用退出后多久收起",
    durationS: (n) => `${n} 秒`,
    durationM: (n) => `${n} 分钟`,
    nearNote: "硬盘剩余空间少于要留出的大小时，会自动清掉没设为常留本机的缓存",
    quotaUnset: "没有设置上限",
    noData: "没有数据",
    apps: "已搬到网盘的应用",
    appsSummary: (n, m, size, k) => `${n} 个应用 · ${m} 个已缓存 ${size} · ${k} 个常留本机`,
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
    filterRemote: "只在网盘",
    filterPinned: "常留本机",
    noMatches: "没有符合条件的应用",
    modemount: "打开时下载",
    moderestore: "打开时整个拿回",
    modeskip: "跳过",
    modeunsupported: "不支持",
    cached: "已缓存",
    remote: "只在网盘",
    pinned: "常留本机",
    restored: "已拿回本机",
    stateAttention: "需要处理",
    stateMounted: "正在用",
    stateDownloading: "下载中",
    notCached: "未缓存",
    toDownload: "需下载",
    lastUsedAt: (iso) => `${relativeTime(iso, "zh")}使用`,
    onDevices: (names) => `也在 ${names}`,
    packedOn: (names) => `由 ${names} 搬到网盘`,
    notInstalledHere: "这台 Mac 没有安装",
    launcherMissing: "这台 Mac 上的入口不见了",
    fullAppHere: (version) => `这台 Mac 已装完整版 ${version}`.trim(),
    elsewhereTitle: (n) => `其他 Mac 搬到网盘的应用（${n}）`,
    elsewhereNote: "你的各台 Mac 共用 iCloud 里的同一个 Disklessly 文件夹，所以能看到它们。它们是别的 Mac 搬上去的，这台 Mac 上的应用没有被动过。",
    nothingHere: "这台 Mac 还没有把应用搬到网盘。",
    open: "打开",
    openFor: (name) => `打开 ${name}`,
    prefetch: "先下载好",
    prefetchFor: (name) => `先把 ${name} 下载到本机`,
    pin: "常留本机",
    unpin: "不再常留",
    evict: "清除缓存",
    evictMounted: "应用正在使用，退出后再清除",
    detach: "收起",
    detachFor: (name) => `收起 ${name}（推出它的磁盘镜像）`,
    detachHint: "推出这个应用的磁盘镜像。应用在运行时不能收起；退出后约 2 分钟也会自动收起",
    evictPinned: "设为常留本机的应用不能清除缓存，先点「不再常留」",
    more: "更多",
    moreFor: (name) => `${name} 的更多操作`,
    restore: "临时拿回来",
    unpack: (dir) => `永久拿回到 ${dir}…`,
    share: (n) => `占上限的 ${n}%`,
    evictNote: "清除缓存只删本机这份副本，应用还在网盘里，下次打开时自动下载。设为常留本机的应用不会被自动清除。",
    emptyApps: "还没有搬到网盘的应用",
    emptyAppsHint: "搬到网盘的应用会显示在这里。",
    loadingApps: "正在加载…",
    loading: "正在读取网盘…",
    loadFailed: "未能加载应用",
    unreachable: "连不上网盘",
    appsLoadFailed: "无法读取应用列表",
    confirmEvictTitle: (name) => `清除 ${name} 的缓存？`,
    confirmEvictBody: (size) => `本机会腾出 ${size}。网盘里的那份保留，下次打开时会重新下载。`,
    confirmEvictOk: "清除缓存",
    confirmRestoreTitle: (name) => `临时拿回 ${name}？`,
    confirmRestoreBody: "会把应用解压回本机原位置并打开，退出后再放回网盘。期间会占用完整的磁盘空间。",
    confirmRestoreOk: "拿回来并打开",
    confirmUnpackTitle: (name, dir) => `把 ${name} 永久拿回到 ${dir}？`,
    confirmUnpackBody: (path) => `应用会完整复制回 ${path}，入口替换为真正的应用，此后不再打开时才下载。网盘里的那份保留。`,
    confirmUnpackOk: "永久拿回来",
    jobDone: (action, name) => `${name}：${action}完成`,
    jobFailed: (action, name) => `${name}：${action}失败`,
    actionlaunch: "打开",
    actionprefetch: "先下载好",
    actionevict: "清除缓存",
    actiondetach: "收起",
    actionrestore: "临时拿回来",
    actionunpack: "永久拿回来",
    actionpin: "设为常留本机",
    actionunpin: "不再常留本机",
    actionpack: "搬到网盘",
    actionoffloadfile: "搬到网盘",
    actiontrashpath: "删除",
    phasepack: "正在搬到网盘",
    phasestop: "正在停止",
    phasesnapshot: "正在快照",
    phasearchive: "正在打包",
    phaseencrypt: "正在加密",
    phasehash: "正在校验",
    phaseextract: "正在解包",
    phaseplace: "正在放回",
    phasestub: "放上入口",
    "actiondata/enable": "数据也搬到网盘",
    "actiondata/disable": "数据留本机",
    dataEnable: "数据也搬到网盘",
    dataOffloadNow: "现在搬到网盘",
    usageMenuRefused: (why) => `不能在这里操作：${why}`,
    packAppMenu: "搬到网盘（本机留一个入口）",
    cacheDeleteHint: "缓存目录可直接删除释放空间，不用搬到网盘",
    offloadedAppUsageNote: (bundleSize, extraSize) => `应用本体已在网盘（本机入口 ${bundleSize}），其余 ${extraSize} 是应用数据或缓存`,
    offloadedAppOnlyStubNote: "应用本体已在网盘（本机只剩入口）",
    revealAppData: "在访达中显示应用数据",
    picturesHint: "系统「图片」目录包含照片图库（Photos Library），不建议整个搬到网盘。可在「照片 → 设置 → iCloud」开启「优化 Mac 储存空间」，或打开目录单独清理其它子文件夹。",
    manageContainers: "管理容器镜像",
    containerImagesHead: (n) => `包含 ${n} 个容器镜像：`,
    containerImagesNone: "当前没有可列出的本地镜像（或引擎未运行）。",
    linkToApp: "关联到应用组合…",
    linkPickerTitle: (name) => `将「${name}」关联到应用`,
    linkPickerBody: "点击下方列表中的应用，之后可以一起搬到网盘或拿回来。",
    linkPickerSearch: "搜索应用名称…",
    linkPickerLoading: "正在读取已安装应用…",
    linkPickerEmpty: "未在 /Applications 或 ~/Applications 找到应用",
    linkPickerNoMatch: "没有匹配的应用",
    linkPickerLinkedCount: (n) => `已关联 ${n} 项`,
    linkPickerOffloaded: "已在网盘",
    linkPrompt: (name) => `将「${name}」关联到哪个应用？（输入应用名称或 .app 路径，例如 vphone 或 /Applications/vphone.app）`,
    linkGroupBadge: (app, count) => `联动组合：${app} + ${count} 个关联路径`,
    linkOffloadGroup: "整组搬到网盘",
    linkRestoreGroup: "整组拿回来",
    linkUnlink: "取消联动",
    "actionlinks/offload": "整组搬到网盘",
    "actionlinks/restore": "整组拿回来",
    revealInFinder: "在访达中显示",
    revealFailed: "无法在访达中显示",
    bigDataWaiting: "已设好数据也搬到网盘，但数据还在这台 Mac 上；应用退出后会自动搬走，也可以现在就搬",
    bigReason_appDataOwned: (app) => `${app} 的应用数据。这个应用已搬到网盘，数据也可以跟着搬过去`,
    dataDisable: "数据留在本机",
    dataInRepo: (size) => `数据在网盘（${size}），打开时自动拿回来`,
    dataOnQuit: "数据会在应用退出后搬到网盘",
    dataLocal: (size) => `数据还有 ${size} 没搬到网盘，应用退出后搬过去`,
    cloudBadge: "已搬到网盘",
    permTitle: "先确认两项系统权限",
    permBody: "Disklessly 要替换或删除 /Applications 里的 App，系统需要你允许。没打开时，把应用搬到网盘和拿回来都会被系统阻止，并一直弹出提示。",
    permFda: "完全磁盘访问",
    permAppMgmt: "App 管理",
    permAppMgmtBody: "允许 Disklessly 更新或删除其他 App。这一项系统无法自动检查，请自己确认打开。",
    permOpen: "打开设置",
    permDone: "我已打开",
    permGranted: "已允许",
    permMissing: "未允许",
    dataWaiting: (why) => `数据暂留本机：${why}`,
    confirmDataEnableTitle: (name) => `把 ${name} 的数据也搬到网盘？`,
    confirmDataEnableBody: "它在「应用支持」里的文件夹会打包进网盘，然后从本机移走。打开它时先拿回数据再启动，退出后数据有改动才重新上传。数据拿不回来（比如离线）时不会启动，以免它用空数据打开。应用没退出时会等到它退出。",
    confirmDataDisableTitle: (name) => `把 ${name} 的数据留在本机？`,
    confirmDataDisableBody: "如果数据在网盘，会先拿回来，之后不再搬走。",

    stopAndOffload: "停止并搬到网盘",
    stopAndOffloadFor: (name) => `停止 ${name} 并搬到网盘`,
    loginItemsSettings: "登录项设置",
    confirmStopPackBody: (size) => `会先退出这个应用在后台运行的辅助进程，再把它打包进网盘（约 ${size}），原位置换成一个入口，之后打开时再下载。可能要几分钟。`,
    offloadNow: "搬到网盘",
    offloadNowFor: (name) => `把 ${name} 搬到网盘`,
    offloading: "正在搬…",
    confirmPackTitle: (name) => `把 ${name} 搬到网盘？`,
    confirmPackBody: (size) => `应用会被打包进网盘（约 ${size}），原位置换成一个入口，之后打开时再下载。需要先退出这个应用；可能要几分钟。`,
    confirmPackOk: "搬到网盘",
    confirmFileTitle: (name) => `把 ${name} 搬到网盘？`,
    confirmTrashTitle: (name) => `删除 ${name}？`,
    confirmTrashBody: (size) => `它会被移到废纸篓（约 ${size}），清空废纸篓后才真正释放空间。需要先在其他 app 里关闭它。`,
    trashOk: "移到废纸篓",
    bigUpload: "搬到网盘",
    bigDelete: "删除",
    confirmFileBody: (size) => `它会被移进网盘（约 ${size}），原位置留下一个同名的 .disklessly 占位文件；文件夹的原路径还会变成一个带云角标的链接。双击占位文件，或在访达里右键选“用 Disklessly 取回”，就能把它拿回来。需要先在其他 app 里关闭它。`,
    phasequeued: "排队中",
    phaseresolve: "查找镜像",
    phasedownload: "下载中",
    phaseopen: "正在打开",
    phaserunning: "已打开",
    phaseevict: "清除中",
    phasedetach: "正在收起",
    phaseunpack: "复制中",
    phasepin: "更新中",
    errunknown_app: "网盘里找不到这个应用。",
    erroffline: "连不上网盘，请检查网络或共享盘后重试。",
    errintegrity: "下载下来的应用没通过校验，已丢弃，请重试。",
    errno_space: "磁盘空间不足，先清除一些缓存再试。",
    errcloud_full: "云盘已满，传不上去。先在云盘里腾出空间或升级容量，再重试。",
    errbusy: "这个应用正在执行另一项操作，请稍后再试。",
    errpinned: "这个应用设为常留本机，先点「不再常留」再清除缓存。",
    errunauthorized: "链接已失效。",
    errunsupported: "这台 Mac 不支持这个操作。",
    errneeds_resolution: "这个应用有还没处理的改动，要先决定保留还是丢弃。页面里暂时不能处理：请在终端运行 disklessly resolve 加应用名。",
    errbad_request: "页面发出的请求有误，请刷新页面后重试。",
    errfailed: "操作没有完成，请稍后重试。",
    expiredTitle: "链接已失效",
    expiredBody: "这个页面的链接已过期或不正确。点菜单栏里的 Disklessly 图标，选「Open Dashboard」重新打开。（如果是在终端里用 disklessly ui 打开的，就重新运行它，再打开它给出的链接。）",
    heroTitle: "三步腾出空间",
    heroBody: "把很少用的大应用搬到网盘，本机只留一个很小的入口；双击入口时再下载并打开。",
    heroStep1: "1. 选一个网盘",
    heroStep1Body: "默认用 iCloud 云盘；也可以在下面的「网盘」卡片里连接别的网盘或 NAS，再点「用这个网盘」。",
    heroStep1Link: "去选网盘",
    heroStep2: "2. 看看建议",
    heroStep2Body: "下面会列出体积大、久未使用的应用。",
    heroStep2Link: "跳到建议",
    heroStep3: "3. 搬到网盘",
    heroStep3Body: "在建议里的应用旁点「搬到网盘」。确认之前什么都不会改动。",
    heroRepo: (path) => `现在用的：${path}`,
    heroCli: "习惯用终端？",
    heroCliRepo: "选网盘（这里以 NAS 上的文件夹为例）：",
    heroCliPack: "把一个应用搬到网盘：",
    license: "授权",
    licenseCode: "授权码",
    licenseActivate: "激活",
    licenseRemove: "移除授权",
    licenseBuy: "购买授权",
    licenseFree: (used, limit) => `免费版：已搬 ${used} / ${limit} 个应用或文件到网盘`,
    licenseFreeBody: "打开、临时或永久拿回已搬到网盘的应用，以及拿回已搬到网盘的文件，永远免费。要搬更多，请输入授权码。",
    licenseFull: "已授权：搬到网盘的应用和文件数量不限",
    licenseUntil: (date) => `有效期至 ${date}`,
    licenseUpdates: (date) => `${date} 前的更新已包含`,
    licenseExpired: (date) => `授权码已于 ${date} 过期，免费版限额重新生效`,
    licenseInvalid: "已保存的授权码无法使用，免费版限额生效",
    licenseOk: "授权已激活",
    licenseRemoved: "授权已移除",
    cloudTitle: "网盘：东西搬到哪里",
    cloudRepoDefault: (kind) => kind === "icloud" ? "现在用的：iCloud 云盘（默认）" : "现在用的：本机文件夹（默认）",
    cloudRepoBackend: (id) => `现在用的：${id}`,
    cloudSummary: (n) => n ? `已连接 ${n} 个网盘` : "默认搬到 iCloud 云盘",
    cloudDrives: "连接网盘账号",
    cloudDrivesNote: "连接后就能把东西搬到这个网盘。登录在浏览器中完成，凭据只保存在这台 Mac 上（通过内置的 rclone 连接）。",
    cloudConnect: (name) => `连接 ${name}`,
    cloudNoRemotes: "还没有连接网盘。",
    cloudUse: "用这个网盘",
    cloudDefaultName: (kind) => kind === "icloud" ? "iCloud 云盘" : "本机文件夹",
    cloudActive: "正在用",
    cloudDisconnect: "断开",
    cloudBackDefault: (kind) => kind === "icloud" ? "切回 iCloud 云盘" : "切回本机文件夹",
    cloudUseConfirm: (target, n) => n
      ? `改用 ${target}？\n\n会先把现在网盘里的东西搬过去：${n} 个应用的镜像和其他数据逐个复制、校验，全部成功后才切换，已搬到网盘的应用照常打开。旧网盘里的那份保留为备份，新网盘读不到时自动从备份读。`
      : `改用 ${target}？\n\n现在网盘里的数据会先复制过去并校验，完成后才切换；旧网盘里的那份保留为备份。`,
    cloudTaskmigrate: (phase, p) => `正在搬家（${({ scan: "清点", copy: "复制", verify: "校验", switch: "切换", done: "完成" })[phase] || "准备"}）${p}`,
    "cloudTaskmirror-sync": (phase, p) => `正在同步备份（${({ scan: "清点", copy: "复制", verify: "校验", done: "完成" })[phase] || "准备"}）${p}`,
    cloudProgress: (files, total, done, size) => `：${files}/${total} 个文件，${done} / ${size}`,
    cloudMirror: "备份",
    cloudMirrorAdd: "设为备份",
    cloudMirrorRemove: "取消备份",
    cloudMirrorSync: "立即同步备份",
    cloudMirrorsLine: (n) => `另有 ${n} 个备份网盘，正在用的网盘读不到时自动从备份读。`,
    cloudMirrorLast: (when, ok) => ok ? `上次同步 ${when}` : `上次同步失败（${when}）`,
    cloudMirrorNever: "还没同步过",
    cloudMigrated: (target, n) => `已搬到 ${target}（复制 ${n} 个文件）`,
    cloudDisconnectConfirm: (name) => `断开 ${name}？网盘上的文件不会被删除。`,
    cloudTaskconnect: "正在等待你在浏览器里登录…",
    cloudTaskopenlist: (phase) => `正在安装 OpenList（${({ download: "下载中", verify: "校验中", configure: "配置中", start: "启动中" })[phase] || "准备中"}）…`,
    cloudTaskDone: "完成",
    cloudTaskFailed: (msg) => `失败：${msg}`,
    cloudSwitched: (target) => `已改用 ${target}`,
    cloudNoRclone: "找不到内置的 rclone，请重新安装 Disklessly。",
    openlistTitle: "OpenList（可选）",
    openlistNote: "OpenList 能把阿里云盘、百度网盘、115、夸克等网盘接进来（统一成 WebDAV）。它只在这台 Mac 上运行，不对外开放（127.0.0.1）；首次安装需下载约 50 MB。",
    openlistInstall: "一键安装 OpenList",
    openlistRunning: (url) => `运行中：${url}`,
    openlistStopped: "已停止",
    openlistOpen: "打开管理页",
    openlistPassword: "显示管理员密码",
    openlistPasswordIs: (pw) => `用户 admin，密码 ${pw}`,
    openlistStart: "启动",
    openlistStop: "停止",
    openlistHint: "先在管理页里添加你的网盘，再在上面的 OpenList 旁点「用这个网盘」。",
    errlicense_required: "免费版能搬到网盘的数量已用完（应用和文件合计）。在授权卡片里购买授权并输入授权码，就能继续搬。",
    sessionTiers: "AI 对话记录",
    coldAfter: (n) => `${n} 天没动的对话可以搬到网盘`,
    offloadedCount: (n) => `已搬到网盘 ${n} 个`,
    emptySessions: "还没有搬到网盘的对话",
    sessionIntro: "扫描各个 AI 编程助手的对话记录。勾选后，久未打开的对话会把完整内容搬到网盘，本机只留一份短文本摘要，随时可以拿回原文件。",
    sessionPlanLine: (files, size, cold, coldSize) => `${files} 个对话，${size}；${cold} 个可以搬到网盘（${coldSize}）`,
    sessionPlanNone: "没找到 AI 编程助手的对话记录。",
    sessionPlanAbsent: "这台 Mac 上没有",
    sessionApply: "把选中的旧对话搬到网盘",
    sessionApplying: "正在搬…",
    sessionConfirmTitle: (n, size) => `把 ${n} 个旧对话（${size}）搬到网盘？`,
    sessionConfirmBody: (agents) => `${agents}：完整对话文件打包上传到网盘，读回校验无误后才删除本机文件；本机保留短文本摘要，可以搜索和查看。需要时点「拿回来」把原文件放回原处。最近 24 小时改过或正在打开的对话不会动。`,
    sessionApplied: (n, size) => `已把 ${n} 个对话搬到网盘，腾出 ${size}`,
    sessionFailed: "对话没能搬到网盘",
    sessionDigest: "摘要",
    sessionDigestHide: "收起",
    sessionRestore: "拿回来",
    sessionUntitled: "（无标题）",
    sessionShowList: (n) => `查看 ${n} 个`,
    sessionHideList: () => "收起",
    sessionPickAll: "全选",
    sessionPickNone: "全不选",
    sessionPicked: (n, size) => `已选 ${n} 个，${size}`,
    sessionFilter: "按标题、工具或路径筛选",
    sessionFilterNone: "没有匹配的对话",
    sessionRestored: (path) => `已拿回到 ${path}`,
    sessionRestoreFailed: "没能拿回来",
    tiercold: "旧",
    daysAgo: (n) => (n <= 0 ? "今天" : `${n} 天前`),
    recommend: "建议搬到网盘",
    recommendWarn: "不建议搬走",
    recommendEmpty: "没有达到大小阈值的应用",
    recommendEmptyHint: "较大且久未使用的应用会显示在这里",
    foldedTitle: (n) => `其他应用：较小、正在运行或最近在用（${n}）`,
    foldedHint: "按打开次数和大小综合排序；不展开也不影响上面的清单。",
    recommendUnavailable: "扫描已安装应用需要 macOS",
    recommendFailed: "未能加载建议",
    recommendScanning: "正在扫描已安装的应用…",
    recommendSummary: (count, min) => `${count} 个应用 · 只列出不小于 ${min} 的应用`,
    filesTitle: "大文件和文件夹",
    bigTitle: "其他大头",
    bigScanning: "正在测量模拟器、缓存和应用数据…",
    bigSummary: (n, size) => `${n} 项，共 ${size}。应用以外的空间大多在这里。`,
    bigNone: "没有超过 1 GB 的模拟器、缓存或应用数据。",
    bigGoDev: "去模拟器",
    bigClean: "清理",
    bigCleaning: "正在清理…",
    bigShowUsage: "看占用",
    bigReason_unusedRuntime: "没有模拟器在用这个运行时，可以搬到网盘，要用时再拿回来",
    bigReason_runtime: "模拟器运行时，可以搬到网盘，要用时再拿回来",
    bigReason_idleSimulator: "模拟器数据，可以搬到网盘；拿回来后模拟器的设备编号（UDID）会变",
    bigReason_running: "模拟器正在运行，关掉后才能搬到网盘",
    bigReason_rebuildable: "工具会自动重新下载或生成，清理后挪到废纸篓",
    "bigReason_claude-vm-bundles": "Claude 桌面端下载的 Linux 虚拟机包，退出 Claude 后可以删，需要时会重新下载",
    loc_claudeVmBundles: "Claude 虚拟机包",
    sipSuffix: "（系统保护，SIP）",
    sip_siri: "Siri 离线模型",
    sip_speech: "离线听写模型",
    sip_linguistic: "语言数据",
    sip_translation: "离线翻译模型",
    sip_devdocs: "Apple 离线开发文档",
    sip_font: "扩展字体",
    sip_dictionary: "词典",
    sip_ttsax: "辅助功能语音",
    sip_macintalk: "系统语音",
    bigReason_adviceSip: "系统资产，受系统完整性保护（SIP）；关闭 SIP 后这里会出现删除按钮",
    bigReason_adviceSipOff: "系统资产。SIP 已关闭，可以删除；需要管理员密码，系统以后可能会重新下载",
    bigConfirmBodySip: (size) => `大约释放 ${size}。这些系统资产会被直接删除（不进废纸篓），需要输入管理员密码。相关功能（如 Siri、听写、离线文档）可能失效，系统以后可能会重新下载。`,
    bigReason_appData: "应用数据。在应用里清理；或者先把它的应用搬到网盘，数据就能跟着搬过去",
    bigReason_personal: "个人文件夹。可在「大文件和文件夹」里把不常用的搬到网盘",
    bigConfirmTitle: (name) => `清理「${name}」？`,
    ctrTitle: "容器镜像",
    ctrScanning: "正在读取容器镜像…",
    ctrNone: "这台 Mac 上没有 Apple container、Docker Desktop、OrbStack、Colima 或 Dory。",
    ctrSummary: (n, size, free) => `${n} 个镜像，共 ${size}；没在用的 ${free} 可以搬到网盘或清理。`,
    ctrEngine: (name, size) => `${name} · 磁盘上共 ${size}`,
    ctrEngine_running: "运行中",
    ctrEngine_stopped: "没在运行，只能看到磁盘大小；启动后才能列出镜像",
    ctrEngine_noCli: "找不到命令行工具，只能看到磁盘大小",
    ctrUse_running: (names) => `在用：容器 ${names} 正在运行`,
    ctrUse_stopped: (names) => `在用：停止的容器 ${names} 还引用它，先删掉容器才能移走`,
    ctrUse_recent: (days) => `最近 ${days} 天内拉取或运行过，可能还会用`,
    ctrUse_dangling: "没有标签的旧镜像，通常可以直接清理",
    ctrUse_idle: "没有容器在用，也很久没拉取或运行",
    ctrLastUsed: (days) => (days <= 0 ? "今天用过" : `${days} 天前用过`),
    ctrOffload: "搬到网盘",
    ctrClean: "清理",
    ctrRestore: "拿回来",
    ctrForget: "从网盘删除",
    ctrOffloaded: "已搬到网盘",
    ctrVolumes: "卷",
    ctrVolumeInUse: "有容器在用",
    ctrVolumeNote: "卷里是容器的数据，这里只显示大小，不会动它们。",
    ctrInstalledHere: "这台 Mac 上也有",
    ctrConfirmOffloadTitle: (name) => `把镜像 ${name} 搬到网盘？`,
    ctrConfirmOffloadBody: (size, engine, recent) => `${recent ? "这个镜像最近用过。" : ""}用 ${engine} 把镜像导出成一个 tar 文件（约 ${size}），存进网盘并核对 sha256 无误之后，才从这台 Mac 删除镜像。之后可以一键拿回来。`,
    ctrConfirmCleanTitle: (name) => `清理镜像 ${name}？`,
    ctrConfirmCleanBody: (size) => `直接删除这个镜像（约 ${size}），不保存。以后需要时要重新拉取或构建。`,
    ctrConfirmForgetTitle: (name) => `从网盘删除 ${name}？`,
    ctrConfirmForgetBody: (size) => `删除网盘里的 ${size}，之后就不能再拿回来了。`,
    ctrVMNote: "镜像在虚拟机磁盘里，删除后要等虚拟机回收磁盘（通常重启一次）空间才会回到 Mac。",
    ctrJobDone: (name, freed) => (freed ? `${name}：完成，腾出 ${freed}` : `${name}：完成`),
    ctrJobFailed: (name) => `${name}：失败`,
    phasecheck: "检查中",
    phasesave: "导出中",
    phaseupload: "上传中",
    phaseverify: "校验中",
    phaseremove: "删除中",
    phaseload: "导入中",
    phaseforget: "删除中",
    bigConfirmBody: (size) => `大约释放 ${size}。内容挪到废纸篓（Homebrew 用 brew cleanup），对应的工具下次用到时会重新下载或生成。`,
    filesSummary: (count, min, days) => `${count} 项 · 不小于 ${min}，且 ${days} 天以上没打开过`,
    filesEmpty: "主文件夹里没有又大又久未打开的文件",
    filesScanning: "正在扫描主文件夹…",
    filesPartial: "扫描提前结束，列表可能不完整",
    filesFolder: "文件夹",
    filesFile: "文件",
    filesIdle: (days) => `${days} 天未打开`,
    filesNever: "从未打开",
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
    usageDrilling: (name) => `正在扫描 ${name}…`,
    usageDrillEmpty: (name) => `${name} 里没有可展开的子项`,
    usageDrillFailed: (name) => `无法扫描 ${name}`,
    usageHint: "点击方块放大，点击上方路径返回。",
    usageTotal: (used, free, total) => `共 ${total} · 已用 ${used} · 可用 ${free}`,
    usage_disk: "整块磁盘",
    usage_apps: "应用",
    usage_disklessly: "Disklessly",
    usage_personal: "个人文件",
    usage_library: "资源库",
    usage_appdata: "应用数据（~ 下的隐藏目录）",
    usage_system: "系统及其他",
    usage_macos: "macOS 系统",
    usage_vm: "虚拟内存",
    usage_simruntimes: "iOS 模拟器运行时",
    usage_simdevices: "模拟器设备",
    usage_deriveddata: "Xcode 编译缓存",
    usage_homebrew: "Homebrew",
    usage_var: "系统数据 /private/var",
    usage_unmeasured: "未能测量",
    cleanTitle: "可以腾出空间的地方",
    cleanNote: "“未能测量”包括时间机器本地快照、可清除空间、其他用户的文件、Spotlight 索引，以及读不到的文件夹；下方“隐藏占用”逐项列出。",
    usage_otherusers: "其他用户",
    usage_snapshots: "本地快照和可清除空间",
    usage_spotlight: "Spotlight 索引",
    "usage_spotlight-likely": "可能是 Spotlight 索引 / 读不到的文件夹",
    usage_unexplained: "读不到的文件夹和其他系统数据",
    hiddenWhy_otherusers: "这台 Mac 上其他账户的个人文件夹和 /Users/Shared，只统计可读的部分。",
    hiddenWhy_snapshots: "估算：存在时间机器本地快照时 macOS 报告的可清除空间。单个快照的大小无法得知。",
    hiddenWhy_spotlight: (size) => `已用管理员权限测量。超过 ${size} 视为异常（通常是索引损坏）。`,
    "hiddenWhy_spotlight-likely": "能测量的部分之外剩下的空间。通常是 Spotlight 索引（只有 root 能测量），加上扫描读不到的文件夹。",
    hiddenWhy_unexplained: "测量 Spotlight 索引之后仍剩下的部分：扫描读不到的文件夹和其他系统数据。",
    hiddenTitle: "隐藏占用（未能测量）",
    hiddenSummary: (gap, used) => `已用 ${used}，其中 ${gap} 无法对应到任何文件夹。`,
    hiddenPurgeable: (size, n) => `可清除空间 ${size}，本地快照 ${n} 个。`,
    hiddenPurgeableNoSnap: "没有本地快照：可清除空间多半是上面已经算过的缓存和 iCloud 文件。",
    hiddenUnreadable: (n) => `扫描读不到 ${n} 个文件夹（只有 root 可读，或受隐私保护；完全磁盘访问权限对后者有用）。它们没有大小，算在剩余部分里。`,
    hiddenSpotlightOk: (size) => `Spotlight 索引大小正常（${size}），无需重建。`,
    hiddenModels: "本机 AI 模型（已计入个人文件或资源库）",
    hiddenModelUsed: (when) => `最后改动 ${when}`,
    hiddenModelInUse: (why) => `正在使用：${why}`,
    hiddenModelNever: "最后改动时间未知",
    hiddenNote: "这些操作都要单独确认，不会在批量清理中运行。",
    reconcileRun_thin_snapshots: "精简快照",
    reconcileRun_spotlight_measure: "测量（需要管理员）",
    reconcileRun_spotlight_rebuild: "重建 Spotlight 索引",
    reconcileRun_model_offload: "搬到网盘",
    reconcileRun_model_trash: "移到废纸篓",
    reconcileConfirm_thin_snapshots: "精简本地时间机器快照？\n\nmacOS 会删除它可以舍弃的本地快照（tmutil thinlocalsnapshots）。你的文件不受影响，但存放在这台 Mac 上的还原点会消失。",
    reconcileConfirm_spotlight_measure: "测量 Spotlight 索引？\n\nmacOS 会请求一次管理员密码，用 du 读取索引文件夹的大小。不会改动任何东西。",
    reconcileConfirm_spotlight_rebuild: "重建 Spotlight 索引？\n\n索引会被清空并重建（mdutil -E）。重建期间（可能数小时）Spotlight、邮件和访达的搜索结果不完整。需要管理员密码。",
    reconcileConfirm_model_offload: (name, path) => `把 ${name} 搬到网盘？\n\n${path} 会移进网盘，原处留下 .disklessly 占位文件，需要时可以拿回来。`,
    reconcileConfirm_model_trash: (name, path) => `把 ${name} 移到废纸篓？\n\n${path} 会移到废纸篓；清倒废纸篓后才释放空间。模型可以重新下载。`,
    reconcileCancelled: "已在管理员提示处取消，没有任何改动。",
    reconcileFailed: (name) => `${name}：操作失败`,
    cleanRun: "清理",
    cleanRunning: "清理中…",
    cleanDone: (name, freed) => `${name}：腾出 ${freed}`,
    cleanFailed: (name) => `${name}清理失败`,
    cleanWhat_brew_cleanup: "删除旧版本和下载缓存（brew cleanup --prune=all）",
    cleanWhat_sim_runtimes: "删除已有更新版本或已损坏的模拟器运行时（simctl runtime delete --outdated / --unusable）",
    cleanWhat_sim_devices: "删除运行时已经不存在的模拟器设备（simctl delete unavailable）",
    cleanWhat_derived_data: "删除 Xcode 的编译缓存，下次编译时会重新生成",
    cleanConfirm: (name) => `清理${name}？`,
    usage_free: "可用",
    usage_bundle: "包体",
    usage_cache: "缓存",
    usage_data: "数据",
    usage_repo: "放在本机的 Disklessly 文件夹",
    usage_state: "状态与临时文件",
    usage_files: "散落文件",
    usage_rest: (n) => `其余 ${n} 项`,
    usage_other: "其他",
    usage_cloud: "网盘",
    usage_cloud_apps: "应用",
    usage_cloud_files: "文件和文件夹",
    usage_cloud_linked: "组合",
    usage_cloud_data: "应用数据",
    usage_cloud_sessions: "会话",
    usageCloudTitle: (size) => `网盘 · ${size}`,
    usageCloudEmpty: "还没有搬任何东西到网盘。把左边的方块拖到这里，或选中后点“搬到网盘”。",
    usageCloudOffline: (state) => `网盘现在连不上（${state}），显示的是上次的目录。`,
    usageScaleChip: (n) => `1 : ${n}`,
    usageTintLabel: "方块颜色",
    usageTintKind: "按类别",
    usageTintAge: "按上次使用",
    usageAge0: "时间未知",
    usageAge1: "30 天内",
    usageAge2: "180 天内",
    usageAge3: "一年内",
    usageAge4: "一年以上",
    usageAgeChanged: (when) => `改动于 ${when}`,
    usageLinkedCount: (n) => `${n} 项已搬到网盘`,
    usageOffloadedFrom: (path) => `原来在 ${path}`,
    usageStored: (size) => `网盘里占 ${size}`,
    usageAlsoHere: (size) => `本机也缓存了 ${size}`,
    usageAlsoOn: (name) => `也在 ${name}`,
    usageIncoming: "预览：会搬到网盘",
    usageSelectedState: "已选中",
    usageTrayFreeNow: (free) => `可用 ${free}`,
    usageTrayFreeAfter: (after, plus) => `之后可用 ${after}（+${plus}）`,
    usageTrayOffload: (n) => `搬到网盘（${n} 项）…`,
    usageTrayTrash: (n) => `移到废纸篓 ${n} 项…`,
    usageTrayClear: "清空选择",
    usageTrayOffloadConfirm: (n, size) => `把 ${n} 项（${size}）搬到网盘？`,
    usageTrayOffloadBody: "应用会打包进网盘并留下入口；文件和文件夹会移进网盘并留下同名的 .disklessly 占位文件。每一项各自作为一个任务运行，确认之前什么都不会改动。",
    usageTrayTrashConfirm: (n, size) => `把 ${n} 项（${size}）移到废纸篓？`,
    usageTrayTrashBody: "它们会进入废纸篓，清倒废纸篓之前都还能放回去。",
    usageGoal: (size) => `目标腾出 ${size}`,
    usageSelect: (name) => `选中 ${name}`,
    usageDeselect: (name) => `取消选中 ${name}`,
    usageShowInCloud: (n) => `在网盘里查看（${n} 项）`,
    usageDropOffload: (name) => `松开就把 ${name} 搬到网盘`,
    usageDropRestore: (name) => `松开就把 ${name} 拿回本机`,
    usageRestoreTitle: (name) => `把 ${name} 拿回本机？`,
    usageRestoreBody: (size) => `会从网盘下载约 ${size} 放回原处。`,
    usageRestoreOk: "拿回来",
    usageFetchBody: "文件要从它的 .disklessly 占位文件拿回来：会在访达中显示它，双击就能拿回来。",
    usageMenuRestore: "拿回本机…",
    usageNoRestore: "这一项不能从这里拿回来",
    usageAlreadyOffloaded: "已经在网盘里了",
    usageNoPack: "只有 /Applications 和 ~/Applications 里的应用可以从这里搬到网盘",
    cachesLine: (size, n) => `已搬到网盘的 ${n} 个应用还留着 ${size} 缓存，可以清掉。`,
    cachesNone: "已搬到网盘的应用没有留下缓存。",
    cachesRunning: (names) => `运行中的应用会跳过：${names}`,
    cachesClear: "清理应用缓存",
    cachesConfirmTitle: (size) => `清理已搬到网盘的应用留下的缓存（${size}）？`,
    cachesConfirmBody: "只清空 ~/Library/Caches 里这些应用的缓存文件夹，以及沙盒容器里的 Data/Library/Caches。Application Support 和其他数据不会动；正在运行的应用会跳过。应用下次打开时会重新生成缓存。",
    cachesDone: (size) => `已清理 ${size} 缓存`,
    cachesFailed: "无法清理缓存",
    usageTips: "可以腾出空间的地方",
    dev: "Xcode 模拟器",
    devIntro: "模拟器运行时和模拟器设备可以搬到网盘，用的时候再拿回来。运行时拿回来后和原来一样；模拟器拿回来后会换一个新的设备编号（UDID）。",
    devRuntimes: "运行时",
    devSimulators: "模拟器",
    devOffloaded: "已搬到网盘",
    devOffload: "搬到网盘",
    devRestore: "拿回来",
    devForget: "从网盘删除",
    devCleanDerived: "清理 Xcode 编译缓存（DerivedData）",
    devNone: "没有",
    devShutdown: "关闭模拟器",
    devRunning: "正在运行，关掉后才能搬到网盘",
    devInUseBy: (names) => `${names} 正在用它，关掉后才能搬到网盘`,
    devConfirmShutdownTitle: (name) => `关闭模拟器「${name}」？`,
    devConfirmShutdownBody: "如果有测试或应用正在这台模拟器里跑，会被中断。",
    devUnavailable: "读不到模拟器信息（需要安装 Xcode）",
    devInstalledHere: "这台 Mac 上也有",
    devFrom: (host) => `来自 ${host}`,
    devConfirmRuntimeTitle: (name) => `把 ${name} 搬到网盘？`,
    devConfirmRuntimeBody: (size) => `上传 ${size} 到网盘，校验后用 simctl 从这台 Mac 删除。需要时可以原样拿回来。`,
    devConfirmSimTitle: (name) => `把模拟器 ${name} 搬到网盘？`,
    devConfirmSimBody: (size) => `把模拟器的数据（${size}）打包上传到网盘，校验后删除这台模拟器。拿回来时会新建同型号的模拟器并放回数据，设备编号（UDID）会变。`,
    devConfirmForgetTitle: (name) => `从网盘删除 ${name}？`,
    devConfirmForgetBody: (size) => `删除网盘里的 ${size}，之后就不能再拿回来了。`,
    devConfirmCleanTitle: "清理 Xcode 编译缓存（DerivedData）？",
    devConfirmCleanBody: "把 Xcode 的编译缓存移到废纸篓，Xcode 下次编译时会重新生成。",
    devConfirmOk: "继续",
    devJobDone: (name) => `${name}：完成`,
    devJobFailed: (name) => `${name}：失败`,
    tipRemoveMacAITitle: "Apple Intelligence 模型",
    tipRemoveMacAIBody: "“系统及其他”里有 Apple Intelligence 下载的模型，往往有好几 GB。开源工具 RemoveMacAI 可以关掉 Apple Intelligence、删掉这些模型并阻止重新下载，随时能撤销。",
    tipRemoveMacAILink: "打开 RemoveMacAI",
    tipDevOffloadTitle: "Xcode 模拟器",
    tipDevOffloadBody: "“资源库 › Developer”和“系统及其他”里的模拟器运行时和模拟器设备，可以搬到网盘，用时再拿回来。",
    tipDevOffloadLink: "去搬到网盘",
    tipPackTitle: "系统数据太大？先把大应用搬到网盘",
    tipPackBody: "“系统及其他”常常是大应用留下的文件。建议列表里的应用可以点“搬到网盘”，本机只留一个小入口，要用时再拿回来。",
    tipPackLink: "看建议搬走的应用",
    tipSimslimTitle: "模拟器占内存？用 simslim 瘦身",
    tipSimslimBody: "simslim 能关掉模拟器里用不到的后台服务，每台模拟器的内存大约能少一半以上。它只省内存，不会让模拟器的磁盘占用变小。",
    tipSimslimLink: "打开 simslim",
    copyCommand: "复制命令",
    copyCommandFor: (name) => `复制命令：把 ${name} 搬到网盘`,
    copied: (name) => `已复制把 ${name} 搬到网盘的命令`,
    copyFailed: "无法写入剪贴板，请手动复制命令",
    leftoverBackups: (count, size) => `${count} 个残留备份（${size}）可以删除`,
    leftoverAdmin: "删除需要管理员权限。",
    leftoverClean: "删除残留备份",
    leftoverCleanTitle: (count, size) => `删除 ${count} 个残留备份（${size}）？`,
    leftoverCleanBody: "上面列出的残留备份文件（.disklessly-original- 备份）会被删除。macOS 会先弹出管理员密码框；之后只删除已与网盘里那份核对一致的备份。删除后无法撤销。",
    leftoverCleanOk: "删除",
    leftoverCleanDone: "残留备份已删除",
    leftoverCleanFailed: "无法删除残留备份",
    neverUsed: "从未使用",
    idleDays: (n) => (n === 1 ? "1 天未使用" : `${n} 天未使用`),
    restoreNeeded: "含 App Store 收据，打开时要整个拿回本机",
    sizeBound: "大小是下限（扫描超时）",
    warnloginItem: "登录项",
    warnmenuBarAgent: "菜单栏小程序",
    warnbackgroundHelper: "后台辅助进程在运行",
    warnsystemExtension: "带系统扩展",
    warnkernelExtension: "带内核扩展",
    warntoolchain: "其他程序把它当工具用（工具链）",
    warnpinned: "常留本机",
    warnalreadyPacked: "已经搬到网盘",
    warnsizeTimedOut: "体积扫描超时",
    alreadyInRepo: "网盘里已有相同版本，不用再上传",
    devices: "设备",
    devicesEmpty: "还没有登记的 Mac",
    devicesSummary: (n) => `${n} 台 Mac 共用这个网盘`,
    thisMac: "本机",
    conflictCopies: (n) => `${n} 个 iCloud 冲突副本，未合并`,
    placeholders: (n) => `${n} 个设备文件还没下载`,
    countNone: "无",
    machinesTitle: "其他电脑（通过 SSH）",
    machinesSummary: (n, r) => `${n} 台电脑 · ${r} 台通过 SSH 连接`,
    machinesHostLabel: "电脑地址（SSH 主机名）",
    machinesHostPlaceholder: "例如 gpu-box 或 dev-server",
    machinesAdd: "添加电脑",
    machinesRemove: "移除",
    machinesScan: "扫描磁盘",
    machinesScanning: "正在通过 SSH 扫描…",
    machinesInspect: "查看大项",
    machinesLocalBadge: "本机",
    machinesRemoteBadge: "SSH",
    machinesLevel_offline: "离线",
    machinesLevel_critical: "紧张",
    machinesLevel_warning: "偏高",
    machinesLevel_ok: "正常",
    machinesDiskLine: (used, total, reclaim) => `已用 ${used} / ${total} · 可清理或可搬到网盘 ${reclaim}`,
    machinesNotScanned: "还没扫描。点“扫描磁盘”看看各个硬盘分区和占空间的大项",
    machinesDetailTitle: (host, mode) => `${host} 扫描详情（${mode || "ssh"}）`,
    machinesMountsTitle: "硬盘分区",
    machinesMountFree: (dev, fs, size) => `${dev} (${fs}) · 可用 ${size}`,
    machinesItemsTitle: "可清理的缓存和可搬到网盘的大项",
    machinesOffloadedTitle: "已搬到网盘",
    machinesNoItems: "没找到可清理或可搬到网盘的大项",
    machinesCleanBtn: "清理",
    machinesOffloadBtn: "搬到网盘",
    machinesRestoreBtn: "拿回来",
    machinesPlanConfirmTitle: (act, title, host) => `${host}：${act}「${title}」？`,
    machinesPlanConfirmBody: (path, size, rec) => `目标路径：${path}\n预计释放：${size}\n能从网盘拿回来：${rec ? "能（先上传并校验，再删掉原件；原处留下 .disklessly-remote 占位文件和操作记录）" : "不能（能重新生成的缓存或日志，直接清理）"}`,
    machinesRestoreConfirmTitle: (title, host) => `把 ${title} 拿回 ${host}？`,
    machinesRestoreConfirmBody: (path, size) => `会从网盘直接下载回 ${path}（${size}），校验通过后去掉占位标记。`,
    machinesActionDone: (host, title) => `${host}: ${title} 已完成`,
    machinesActionFailed: (host, title) => `${host}: ${title} 失败`,
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
    backend: "Storage",
    locationremote: "Over the network",
    locationlocal: "On this Mac",
    healthok: "Healthy",
    healthdegraded: "Degraded",
    healthmissing: "Not set up yet",
    healthoffline: "Offline",
    healthunknown: "Checking",
    latency: (ms) => `latency ${ms} ms`,
    timedOut: (s) => `timed out after ${s} s`,
    missingHint: "Reachable, but there is no Disklessly folder in it yet (repo.json is missing)",
    offlineHint: "Cached apps still open",
    activeEndpoint: "In use",
    kind: "Kind",
    endpoints: "Locations",
    endpointactive: "In use",
    endpointstandby: "spare",
    endpointlocal: "this Mac",
    kindlocal: "Local folder",
    kindicloud: "iCloud Drive",
    kindsmb: "SMB share",
    kindnfs: "NFS share",
    kindwebdav: "WebDAV",
    kindopenlist: "OpenList",
    kinds3: "S3",
    cache: "Local cache",
    levelok: "Plenty of room",
    levelnear: "Near quota",
    levelcritical: "Almost full",
    levelunset: "No quota",
    quotaWord: "quota",
    usedPct: "used",
    floorLabel: "Keep free on disk",
    floorKeep: (size) => `keeps ${size} free`,
    floorMarkerHint: (size) => `At this cache size, free disk space falls to the ${size} you asked to keep free`,
    legendNormal: "Normal",
    legendNear: "Near",
    legendCritical: "Critical",
    quotaLeft: "Quota left",
    floor: "Keep free on disk",
    diskFree: "free on disk",
    detachDelay: "Put away after quitting",
    durationS: (n) => `${n} s`,
    durationM: (n) => `${n} min`,
    nearNote: "When free disk space drops below what you keep free, cache of apps not kept on this Mac is cleared automatically",
    quotaUnset: "No quota set",
    noData: "No data",
    apps: "Offloaded apps",
    appsSummary: (n, m, size, k) => `${n} ${n === 1 ? "app" : "apps"} · ${m} cached ${size} · ${k} kept on this Mac`,
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
    filterRemote: "Not on this Mac",
    filterPinned: "Kept on this Mac",
    noMatches: "No apps match",
    modemount: "downloads when opened",
    moderestore: "copied back when opened",
    modeskip: "skip",
    modeunsupported: "unsupported",
    cached: "Cached",
    remote: "Not on this Mac",
    pinned: "Kept on this Mac",
    restored: "Restored",
    stateAttention: "Needs attention",
    stateMounted: "In use",
    stateDownloading: "Downloading",
    notCached: "Not cached",
    toDownload: "to download",
    lastUsedAt: (iso) => `used ${relativeTime(iso, "en")}`,
    onDevices: (names) => `Also on ${names}`,
    packedOn: (names) => `Offloaded on ${names}`,
    notInstalledHere: "Not installed on this Mac",
    launcherMissing: "This Mac's launcher is missing",
    fullAppHere: (version) => `Full app ${version} is installed on this Mac`.replace("  ", " "),
    elsewhereTitle: (n) => `Offloaded on other Macs (${n})`,
    elsewhereNote: "Your Macs share one repo in iCloud, so their apps show up here. They were not offloaded from this Mac, and nothing on this Mac was touched.",
    nothingHere: "No apps offloaded on this Mac yet.",
    open: "Open",
    openFor: (name) => `Open ${name}`,
    prefetch: "Download now",
    prefetchFor: (name) => `Download ${name} to this Mac now`,
    pin: "Keep on this Mac",
    unpin: "Stop keeping",
    evict: "Evict",
    evictMounted: "The app is in use; quit it first",
    detach: "Eject",
    detachFor: (name) => `Eject ${name} (its disk image)`,
    detachHint: "Ejects the disk image. Refused while the app runs; it also ejects about 2 minutes after you quit",
    evictPinned: "Apps kept on this Mac can't be evicted; choose Stop keeping first",
    more: "More",
    moreFor: (name) => `More actions for ${name}`,
    restore: "Restore temporarily",
    unpack: (dir) => `Restore to ${dir} for good…`,
    share: (n) => `${n}% of quota`,
    evictNote: "Evict only drops the copy on this Mac; the app stays in your repo and downloads again when opened. Apps kept on this Mac are never evicted automatically.",
    emptyApps: "No offloaded apps.",
    emptyAppsHint: "Apps you offload show up here.",
    loadingApps: "Loading…",
    loading: "Loading",
    loadFailed: "Could not load apps",
    unreachable: "Can't reach your storage",
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
    actionprefetch: "download",
    actionevict: "evict",
    actiondetach: "eject",
    actionrestore: "restore",
    actionunpack: "permanent restore",
    actionpin: "keep on this Mac",
    actionunpin: "stop keeping",
    actionpack: "offload",
    actionoffloadfile: "offload",
    actiontrashpath: "delete",
    phasepack: "Offloading",
    phasestop: "Stopping",
    phasesnapshot: "Snapshotting",
    phasearchive: "Packing",
    phaseencrypt: "Encrypting",
    phasehash: "Checking",
    phaseextract: "Unpacking",
    phaseplace: "Putting back",
    phasestub: "Installing launcher",
    "actiondata/enable": "Move data to the repo",
    "actiondata/disable": "Keep data here",
    dataEnable: "Move its data too",
    dataOffloadNow: "Offload now",
    usageMenuRefused: (why) => `Not available here: ${why}`,
    packAppMenu: "Offload app to cloud",
    cacheDeleteHint: "Cache folder — delete directly to free space; no need to upload",
    offloadedAppUsageNote: (bundleSize, extraSize) => `App bundle is already in the cloud (${bundleSize} launcher); the remaining ${extraSize} is app data or cache`,
    offloadedAppOnlyStubNote: "App is already in the cloud (launcher only)",
    revealAppData: "Show app data in Finder",
    picturesHint: "Your Pictures folder holds Photos Library. Instead of offloading the whole folder, enable Photos → Settings → iCloud → Optimize Mac Storage, or open it in Finder to offload other subfolders.",
    manageContainers: "Manage container images",
    containerImagesHead: (n) => `${n} container image${n === 1 ? "" : "s"} inside:`,
    containerImagesNone: "No local images listed (or the engine is stopped).",
    linkToApp: "Link to an app group…",
    linkPickerTitle: (name) => `Link "${name}" to an app`,
    linkPickerBody: "Click an app below to offload and restore them together.",
    linkPickerSearch: "Search installed apps…",
    linkPickerLoading: "Loading installed apps…",
    linkPickerEmpty: "No apps found in /Applications or ~/Applications",
    linkPickerNoMatch: "No matching apps",
    linkPickerLinkedCount: (n) => `${n} linked`,
    linkPickerOffloaded: "In cloud",
    linkPrompt: (name) => `Which app should "${name}" be linked with? (Enter app name or .app path, e.g. vphone or /Applications/vphone.app)`,
    linkGroupBadge: (app, count) => `Linked group: ${app} + ${count} path${count === 1 ? "" : "s"}`,
    linkOffloadGroup: "Offload linked group",
    linkRestoreGroup: "Restore linked group",
    linkUnlink: "Unlink from group",
    "actionlinks/offload": "offload group",
    "actionlinks/restore": "restore group",
    revealInFinder: "Show in Finder",
    revealFailed: "Could not show it in Finder",
    bigDataWaiting: "Data offload is on but the data is still on this Mac; it moves after the app quits, or you can move it now",
    bigReason_appDataOwned: (app) => `Data of ${app}. The app is offloaded, so its data can follow it to the cloud`,
    dataDisable: "Keep its data here",
    dataInRepo: (size) => `Data in the repo (${size}), fetched when you open it`,
    dataOnQuit: "Data moves to the repo after it quits",
    dataLocal: (size) => `${size} of data is not in the repo yet; it moves after quit`,
    cloudBadge: "Uninstalled; in the cloud",
    permTitle: "Check two system permissions first",
    permBody: "Disklessly has to replace or delete apps in /Applications, and macOS needs your permission for that. Until both are on, uninstall and pack are blocked and macOS keeps prompting.",
    permFda: "Full Disk Access",
    permAppMgmt: "App Management",
    permAppMgmtBody: "Lets Disklessly update or delete other apps. macOS cannot be checked automatically, so turn it on yourself.",
    permOpen: "Open Settings",
    permDone: "I turned it on",
    permGranted: "Allowed",
    permMissing: "Not allowed",
    dataWaiting: (why) => `Data stays here for now: ${why}`,
    confirmDataEnableTitle: (name) => `Move ${name}'s data to the repo too?`,
    confirmDataEnableBody: "Its folders in Application Support are packed into the repo and removed from this Mac. Opening it fetches the data first; after it quits, the data is uploaded again only if it changed. If the data cannot be fetched (offline, for example) the app does not open, so it never starts with empty data. If the app is open, this waits until it quits.",
    confirmDataDisableTitle: (name) => `Keep ${name}'s data on this Mac?`,
    confirmDataDisableBody: "If the data is in the repo it is brought back first, and it stays here from then on.",

    stopAndOffload: "Stop and offload",
    stopAndOffloadFor: (name) => `Stop ${name} and offload it`,
    loginItemsSettings: "Login items",
    confirmStopPackBody: (size) => `Its background helpers are quit first, then the app is packed into your repo (about ${size}) and its place gets a launcher that downloads and opens it on demand. This can take a few minutes.`,
    offloadNow: "Offload now",
    offloadNowFor: (name) => `Offload ${name} now`,
    offloading: "Offloading…",
    confirmPackTitle: (name) => `Offload ${name}?`,
    confirmPackBody: (size) => `The app is packed into your repo (about ${size}) and its place gets a launcher that downloads and opens it on demand. Quit the app first. This can take a few minutes.`,
    confirmPackOk: "Offload",
    confirmFileTitle: (name) => `Offload ${name}?`,
    confirmTrashTitle: (name) => `Delete ${name}?`,
    confirmTrashBody: (size) => `It moves to the Trash (about ${size}); the space comes back when you empty the Trash. Close it in other apps first.`,
    trashOk: "Move to Trash",
    bigUpload: "Offload",
    bigDelete: "Delete",
    confirmFileBody: (size) => `It moves into your repo (about ${size}) and leaves a small .disklessly placeholder with the same name; a folder's old path also becomes a link with a cloud badge. Double-click the placeholder, or right-click it in Finder and choose Bring back with Disklessly, to get it back. Close it in other apps first.`,
    phasequeued: "Queued",
    phaseresolve: "Finding image",
    phasedownload: "Downloading",
    phaseopen: "Opening",
    phaserunning: "Open",
    phaseevict: "Evicting",
    phasedetach: "Ejecting",
    phaseunpack: "Copying",
    phasepin: "Updating",
    errunknown_app: "The repo has no app by that name.",
    erroffline: "The repository is unreachable. Check the network or share and try again.",
    errintegrity: "The downloaded image failed its checksum and was discarded. Try again.",
    errno_space: "Not enough disk space. Evict some cached apps and try again.",
    errcloud_full: "The cloud drive is full, so nothing can be uploaded. Free space there or upgrade the plan, then try again.",
    errbusy: "This app is busy with another action. Try again shortly.",
    errpinned: "This app is kept on this Mac. Choose Stop keeping before evicting.",
    errunauthorized: "The link has expired.",
    errunsupported: "This Mac does not support that action.",
    errneeds_resolution: "This app has changes that need a decision: keep or discard them. The page can't do this yet; run disklessly resolve with the app name in Terminal.",
    errbad_request: "The page sent a request the app could not use. Reload the page and try again.",
    errfailed: "The action did not finish. Try again later.",
    expiredTitle: "This link has expired",
    expiredBody: "This page's link has expired or is not valid. Click the Disklessly icon in the menu bar and choose Open Dashboard. (If you opened it with disklessly ui in Terminal, run it again and open the link it prints.)",
    heroTitle: "Free up space in three steps",
    heroBody: "Large apps you rarely use move into your repo; this Mac keeps a tiny launcher that downloads and opens them on demand.",
    heroStep1: "1. Choose where things go",
    heroStep1Body: "iCloud Drive is the default. To use another cloud drive or a NAS, connect it in the storage card below and choose Use as repo.",
    heroStep1Link: "Choose storage",
    heroStep2: "2. Review recommendations",
    heroStep2Body: "Large apps that have sat unused are listed below.",
    heroStep2Link: "Jump to recommendations",
    heroStep3: "3. Offload",
    heroStep3Body: "Click Offload now next to an app in the recommendations. Nothing changes until you confirm.",
    heroRepo: (path) => `Current repo: ${path}`,
    heroCli: "Prefer Terminal?",
    heroCliRepo: "Choose the repo (a folder on a NAS in this example):",
    heroCliPack: "Offload one app:",
    license: "License",
    licenseCode: "License code",
    licenseActivate: "Activate",
    licenseRemove: "Remove license",
    licenseBuy: "Buy a license",
    licenseFree: (used, limit) => `Free version: ${used} of ${limit} apps or files offloaded`,
    licenseFreeBody: "Starting, restoring and unpacking offloaded apps, and bringing back offloaded files, is always free. Enter a license code to offload more.",
    licenseFull: "Licensed: unlimited offloaded apps and files",
    licenseUntil: (date) => `Valid until ${date}`,
    licenseUpdates: (date) => `Updates included until ${date}`,
    licenseExpired: (date) => `Your code expired on ${date}; the free limit applies again`,
    licenseInvalid: "The saved license code is not usable; the free limit applies",
    licenseOk: "License activated",
    licenseRemoved: "License removed",
    cloudTitle: "Cloud drives and repo",
    cloudRepoDefault: (kind) => kind === "icloud" ? "Repo: iCloud Drive (default)" : "Repo: a folder on this Mac (default)",
    cloudRepoBackend: (id) => `Repo: ${id}`,
    cloudSummary: (n) => n ? `${n} cloud drive${n === 1 ? "" : "s"} connected` : "The repo lives in iCloud Drive by default",
    cloudDrives: "Cloud drives (built-in rclone)",
    cloudDrivesNote: "Connect a drive to keep offloaded apps there. You sign in in your browser; the credentials stay on this Mac.",
    cloudConnect: (name) => `Connect ${name}`,
    cloudNoRemotes: "No cloud drive connected yet.",
    cloudUse: "Use as repo",
    cloudDefaultName: (kind) => kind === "icloud" ? "iCloud Drive" : "the local folder",
    cloudActive: "Current repo",
    cloudDisconnect: "Disconnect",
    cloudBackDefault: (kind) => kind === "icloud" ? "Back to iCloud Drive" : "Back to the local folder",
    cloudUseConfirm: (target, n) => n
      ? `Switch the repo to ${target}?\n\nThe current repo moves first: the images of ${n} app${n === 1 ? "" : "s"} and everything else are copied and checked, and only then does the switch happen, so offloaded apps keep opening. The old repo stays as a backup; reads fall back to it when the new repo can't be reached.`
      : `Switch the repo to ${target}?\n\nWhat is in the current repo is copied and checked first; the old repo stays as a backup.`,
    cloudTaskmigrate: (phase, p) => `Moving the repo (${({ scan: "counting", copy: "copying", verify: "checking", switch: "switching", done: "done" })[phase] || "preparing"})${p}`,
    "cloudTaskmirror-sync": (phase, p) => `Syncing backups (${({ scan: "counting", copy: "copying", verify: "checking", done: "done" })[phase] || "preparing"})${p}`,
    cloudProgress: (files, total, done, size) => `: ${files}/${total} files, ${done} / ${size}`,
    cloudMirror: "Backup",
    cloudMirrorAdd: "Use as backup",
    cloudMirrorRemove: "Stop backup",
    cloudMirrorSync: "Sync backups now",
    cloudMirrorsLine: (n) => `${n} backup repo${n === 1 ? "" : "s"}; reads fall back to them when the main repo can't be reached.`,
    cloudMirrorLast: (when, ok) => ok ? `Last synced ${when}` : `Last sync failed (${when})`,
    cloudMirrorNever: "Not synced yet",
    cloudMigrated: (target, n) => `Moved to ${target} (${n} files copied)`,
    cloudDisconnectConfirm: (name) => `Disconnect ${name}? Files on the drive are not deleted.`,
    cloudTaskconnect: "Waiting for you to sign in in the browser…",
    cloudTaskopenlist: (phase) => `Installing OpenList (${({ download: "downloading", verify: "verifying", configure: "configuring", start: "starting" })[phase] || "preparing"})…`,
    cloudTaskDone: "Done",
    cloudTaskFailed: (msg) => `Failed: ${msg}`,
    cloudSwitched: (target) => `The repo is now ${target}`,
    cloudNoRclone: "The built-in rclone is missing. Reinstall Disklessly.",
    openlistTitle: "OpenList (optional)",
    openlistNote: "OpenList serves many cloud drives (Aliyun, Baidu, 115, Quark, …) over WebDAV. It runs only on this Mac at 127.0.0.1; the first install downloads about 50 MB.",
    openlistInstall: "Install OpenList",
    openlistRunning: (url) => `Running at ${url}`,
    openlistStopped: "Stopped",
    openlistOpen: "Open admin page",
    openlistPassword: "Show admin password",
    openlistPasswordIs: (pw) => `User admin, password ${pw}`,
    openlistStart: "Start",
    openlistStop: "Stop",
    openlistHint: "Add your drives on the admin page first, then use OpenList as the repo.",
    errlicense_required: "The free limit (apps and files together) is used up. Buy a license in the License card and enter the code to offload more.",
    sessionTiers: "AI conversations",
    coldAfter: (n) => `Cold after ${n} days`,
    offloadedCount: (n) => `${n} offloaded`,
    emptySessions: "No archived sessions",
    sessionIntro: "Scans the session logs of AI coding agents. For the agents you tick, sessions not opened for a while go to the repo as a full snapshot, and this Mac keeps a short text digest. You can restore the original file any time.",
    sessionPlanLine: (files, size, cold, coldSize) => `${files} sessions, ${size}; ${cold} can move (${coldSize})`,
    sessionPlanNone: "No AI coding agent sessions found.",
    sessionPlanAbsent: "Not on this Mac",
    sessionApply: "Move selected cold sessions",
    sessionApplying: "Moving…",
    sessionConfirmTitle: (n, size) => `Move ${n} cold sessions (${size})?`,
    sessionConfirmBody: (agents) => `${agents}: the full session files are packed and uploaded to the repo, read back and checked, and only then deleted here. This Mac keeps a short digest you can search and read. Restore puts the original file back. Sessions changed in the last 24 hours or open now are left alone.`,
    sessionApplied: (n, size) => `Moved ${n} sessions, freed ${size}`,
    sessionFailed: "Moving sessions failed",
    sessionDigest: "Digest",
    sessionDigestHide: "Hide",
    sessionRestore: "Restore",
    sessionUntitled: "(untitled)",
    sessionShowList: (n) => `Show ${n}`,
    sessionHideList: () => "Hide",
    sessionPickAll: "Select all",
    sessionPickNone: "Select none",
    sessionPicked: (n, size) => `${n} selected, ${size}`,
    sessionFilter: "Filter by title, agent or path",
    sessionFilterNone: "No matching sessions",
    sessionRestored: (path) => `Restored to ${path}`,
    sessionRestoreFailed: "Restore failed",
    tiercold: "Cold",
    daysAgo: (n) => (n <= 0 ? "today" : n === 1 ? "1 day ago" : `${n} days ago`),
    recommend: "Worth offloading",
    recommendWarn: "Poor candidates",
    recommendEmpty: "No apps above the size threshold",
    recommendEmptyHint: "Large apps that have sat unused show up here",
    foldedTitle: (n) => `Other apps: small, running, or used recently (${n})`,
    foldedHint: "Sorted by open count and size together. Nothing is hidden; it is only folded.",
    recommendUnavailable: "Scanning installed apps requires macOS",
    recommendFailed: "Could not load recommendations",
    recommendScanning: "Scanning installed apps…",
    recommendSummary: (count, min) => `${count} ${count === 1 ? "app" : "apps"} · only apps of ${min} or more are listed`,
    filesTitle: "Large files and folders",
    bigTitle: "Other big items",
    bigScanning: "Measuring simulators, caches, and app data…",
    bigSummary: (n, size) => `${n} items, ${size} in all. Most space outside apps is here.`,
    bigNone: "No simulator, cache, or app data over 1 GB.",
    bigGoDev: "Go to simulators",
    bigClean: "Clean",
    bigCleaning: "Cleaning…",
    bigShowUsage: "Usage map",
    bigReason_unusedRuntime: "No simulator uses this runtime. Offload it and bring it back when needed",
    bigReason_runtime: "Simulator runtime. Offload it and bring it back when needed",
    bigReason_idleSimulator: "Simulator data. Offload it; it comes back with a new UDID",
    bigReason_running: "Simulator is running. Shut it down to offload it",
    bigReason_rebuildable: "Its tool downloads or builds it again. Cleaning moves it to the Trash",
    "bigReason_claude-vm-bundles": "A Linux VM bundle that Claude desktop downloaded. Safe to delete after quitting Claude; it downloads again when needed",
    loc_claudeVmBundles: "Claude VM bundles",
    sipSuffix: " (system protected, SIP)",
    sip_siri: "Siri offline models",
    sip_speech: "Offline dictation models",
    sip_linguistic: "Language data",
    sip_translation: "Offline translation models",
    sip_devdocs: "Apple developer documentation",
    sip_font: "Extra fonts",
    sip_dictionary: "Dictionaries",
    sip_ttsax: "Accessibility voices",
    sip_macintalk: "System voices",
    bigReason_adviceSip: "A system asset protected by SIP; a delete button appears here once SIP is off",
    bigReason_adviceSipOff: "A system asset. SIP is off, so it can be deleted; it needs an administrator password, and macOS may download it again later",
    bigConfirmBodySip: (size) => `Frees about ${size}. These system assets are deleted outright (not moved to the Trash) after an administrator password. Features that use them (Siri, dictation, offline docs) may stop working, and macOS may download them again later.`,
    bigReason_appData: "App data. Clean it up in the app, or offload its app first so the data can follow it to the cloud",
    bigReason_personal: "Personal folder. Offload what you rarely use under Large files and folders",
    bigConfirmTitle: (name) => `Clean “${name}”?`,
    ctrTitle: "Container images",
    ctrScanning: "Reading container images…",
    ctrNone: "No Apple container, Docker Desktop, OrbStack, Colima or Dory on this Mac.",
    ctrSummary: (n, size, free) => `${n} images, ${size} in all; ${free} nothing uses can be offloaded or cleaned.`,
    ctrEngine: (name, size) => `${name} · ${size} on disk`,
    ctrEngine_running: "Running",
    ctrEngine_stopped: "Not running, so only its disk size is known; start it to list images",
    ctrEngine_noCli: "Its command-line tool was not found, so only its disk size is known",
    ctrUse_running: (names) => `In use: container ${names} is running`,
    ctrUse_stopped: (names) => `In use: stopped container ${names} still refers to it; remove the container first`,
    ctrUse_recent: (days) => `Pulled or run in the last ${days} days; you may still need it`,
    ctrUse_dangling: "Old untagged image; usually safe to clean",
    ctrUse_idle: "No container uses it, and it has not been pulled or run for a while",
    ctrLastUsed: (days) => (days <= 0 ? "used today" : days === 1 ? "used 1 day ago" : `used ${days} days ago`),
    ctrOffload: "Offload",
    ctrClean: "Clean",
    ctrRestore: "Restore",
    ctrForget: "Delete from repo",
    ctrOffloaded: "In the repo",
    ctrVolumes: "Volumes",
    ctrVolumeInUse: "used by a container",
    ctrVolumeNote: "Volumes hold container data; they are listed here and never touched.",
    ctrInstalledHere: "also on this Mac",
    ctrConfirmOffloadTitle: (name) => `Offload image ${name}?`,
    ctrConfirmOffloadBody: (size, engine, recent) => `${recent ? "This image was used recently. " : ""}${engine} saves the image as a tar (about ${size}). Once it is in the repo and its sha256 checks out, the image is removed from this Mac. You can restore it in one click.`,
    ctrConfirmCleanTitle: (name) => `Clean image ${name}?`,
    ctrConfirmCleanBody: (size) => `Deletes the image (about ${size}) without saving it. Pull or build it again when you need it.`,
    ctrConfirmForgetTitle: (name) => `Delete ${name} from the repo?`,
    ctrConfirmForgetBody: (size) => `Deletes ${size} from the repo; it can no longer be restored.`,
    ctrVMNote: "The image lives in a VM disk; the space comes back to the Mac once the VM trims its disk (usually after a restart).",
    ctrJobDone: (name, freed) => (freed ? `${name}: done, freed ${freed}` : `${name}: done`),
    ctrJobFailed: (name) => `${name}: failed`,
    phasecheck: "Checking",
    phasesave: "Saving",
    phaseupload: "Uploading",
    phaseverify: "Verifying",
    phaseremove: "Removing",
    phaseload: "Loading",
    phaseforget: "Deleting",
    bigConfirmBody: (size) => `Frees about ${size}. The contents go to the Trash (Homebrew uses brew cleanup); the tool fetches or rebuilds them when it next needs them.`,
    filesSummary: (count, min, days) => `${count} ${count === 1 ? "item" : "items"} · ${min} or more, not opened for ${days} days`,
    filesEmpty: "No large files that have sat unopened in your home folder",
    filesScanning: "Scanning your home folder…",
    filesPartial: "The scan stopped early; the list may be incomplete",
    filesFolder: "folder",
    filesFile: "file",
    filesIdle: (days) => `not opened for ${days} days`,
    filesNever: "never opened",
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
    usageDrilling: (name) => `Scanning ${name}…`,
    usageDrillEmpty: (name) => `No subfolders or measurable items in ${name}`,
    usageDrillFailed: (name) => `Could not scan ${name}`,
    usageHint: "Click a box to zoom in; click the path above to go back.",
    usageTotal: (used, free, total) => `${total} total · ${used} used · ${free} free`,
    usage_disk: "Whole disk",
    usage_apps: "Apps",
    usage_disklessly: "Disklessly",
    usage_personal: "Personal files",
    usage_library: "Library",
    usage_appdata: "App data (dot folders in ~)",
    usage_system: "System & other",
    usage_macos: "macOS",
    usage_vm: "Virtual memory",
    usage_simruntimes: "iOS simulator runtimes",
    usage_simdevices: "Simulator devices",
    usage_deriveddata: "Xcode DerivedData",
    usage_homebrew: "Homebrew",
    usage_var: "System data /private/var",
    usage_unmeasured: "Not measured",
    cleanTitle: "Where you can free space",
    cleanNote: "Not measured covers Time Machine local snapshots, purgeable space, other users' files, the Spotlight index, and folders the scan could not read; Hidden usage below lists them one by one.",
    usage_otherusers: "Other users",
    usage_snapshots: "Local snapshots and purgeable space",
    usage_spotlight: "Spotlight index",
    "usage_spotlight-likely": "Likely Spotlight index / unreadable folders",
    usage_unexplained: "Unreadable folders and other system data",
    hiddenWhy_otherusers: "Home folders of other accounts on this Mac and /Users/Shared, counted where readable.",
    hiddenWhy_snapshots: "Estimate: the purgeable space macOS reports while local Time Machine snapshots exist. Single snapshot sizes are not available.",
    hiddenWhy_spotlight: (size) => `Measured with an administrator prompt. Above ${size} counts as abnormal (usually a corrupted index).`,
    "hiddenWhy_spotlight-likely": "What is left after everything measurable. Usually the Spotlight index (only root can size it) plus folders the scan could not read.",
    hiddenWhy_unexplained: "Left after the Spotlight index was measured: folders the scan could not read and other system data.",
    hiddenTitle: "Hidden usage (Not measured)",
    hiddenSummary: (gap, used) => `${used} used, of which ${gap} matches no folder.`,
    hiddenPurgeable: (size, n) => `Purgeable space ${size}; ${n} local snapshot(s).`,
    hiddenPurgeableNoSnap: "No local snapshots: purgeable space is mostly caches and iCloud files already counted above.",
    hiddenUnreadable: (n) => `The scan could not read ${n} folder(s) (root-only or privacy-protected; Full Disk Access helps for the latter). They have no size and fall into the remainder.`,
    hiddenSpotlightOk: (size) => `The Spotlight index is a normal size (${size}); no rebuild needed.`,
    hiddenModels: "AI models on this Mac (already counted under Personal files or Library)",
    hiddenModelUsed: (when) => `last changed ${when}`,
    hiddenModelInUse: (why) => `in use: ${why}`,
    hiddenModelNever: "last change unknown",
    hiddenNote: "Each action asks for its own confirmation and never runs as part of a bulk clean.",
    reconcileRun_thin_snapshots: "Thin snapshots",
    reconcileRun_spotlight_measure: "Measure (needs admin)",
    reconcileRun_spotlight_rebuild: "Rebuild Spotlight index",
    reconcileRun_model_offload: "Offload to repo",
    reconcileRun_model_trash: "Move to Trash",
    reconcileConfirm_thin_snapshots: "Thin local Time Machine snapshots?\n\nmacOS deletes the local snapshots it can spare (tmutil thinlocalsnapshots). Your files are not touched; restore points stored on this Mac go away.",
    reconcileConfirm_spotlight_measure: "Measure the Spotlight index?\n\nmacOS asks for an administrator password once and du reads the size of the index folder. Nothing is changed.",
    reconcileConfirm_spotlight_rebuild: "Rebuild the Spotlight index?\n\nThe index is erased and rebuilt (mdutil -E). Spotlight, Mail and Finder search stay incomplete for hours while macOS reindexes. Needs an administrator password.",
    reconcileConfirm_model_offload: (name, path) => `Offload ${name} to the repo?\n\n${path} moves into the repo and a .disklessly placeholder stays in its place; bring it back when you need it.`,
    reconcileConfirm_model_trash: (name, path) => `Move ${name} to the Trash?\n\n${path} goes to the Trash; the space is freed when you empty it. Models can be downloaded again.`,
    reconcileCancelled: "Cancelled at the administrator prompt; nothing was changed.",
    reconcileFailed: (name) => `${name}: action failed`,
    cleanRun: "Clean up",
    cleanRunning: "Cleaning…",
    cleanDone: (name, freed) => `${name}: freed ${freed}`,
    cleanFailed: (name) => `${name}: cleanup failed`,
    cleanWhat_brew_cleanup: "Removes old versions and the download cache (brew cleanup --prune=all)",
    cleanWhat_sim_runtimes: "Deletes simulator runtimes replaced by a newer build or marked unusable (simctl runtime delete --outdated / --unusable)",
    cleanWhat_sim_devices: "Deletes simulator devices whose runtime is gone (simctl delete unavailable)",
    cleanWhat_derived_data: "Deletes Xcode's build cache; it is rebuilt on the next build",
    cleanConfirm: (name) => `Clean up ${name}?`,
    usage_free: "Free",
    usage_bundle: "Bundle",
    usage_cache: "Cache",
    usage_data: "Data",
    usage_repo: "Repo on this Mac",
    usage_state: "State and temp files",
    usage_files: "Loose files",
    usage_rest: (n) => `${n} more`,
    usage_other: "Other",
    usage_cloud: "In the cloud",
    usage_cloud_apps: "Apps",
    usage_cloud_files: "Files and folders",
    usage_cloud_linked: "Linked bundles",
    usage_cloud_data: "App data",
    usage_cloud_sessions: "Sessions",
    usageCloudTitle: (size) => `In the cloud · ${size}`,
    usageCloudEmpty: "Nothing is offloaded yet. Drag a box from the left onto this side, or select it and choose Offload.",
    usageCloudOffline: (state) => `The repo is not reachable (${state}); this is the last known catalog.`,
    usageScaleChip: (n) => `1 : ${n}`,
    usageTintLabel: "Box colour",
    usageTintKind: "Kind",
    usageTintAge: "Last used",
    usageAge0: "Age unknown",
    usageAge1: "Under 30 days",
    usageAge2: "Under 180 days",
    usageAge3: "Under a year",
    usageAge4: "Over a year",
    usageAgeChanged: (when) => `changed ${when}`,
    usageLinkedCount: (n) => `${n} offloaded to the cloud`,
    usageOffloadedFrom: (path) => `Offloaded from ${path}`,
    usageStored: (size) => `${size} in the repo`,
    usageAlsoHere: (size) => `${size} also cached here`,
    usageAlsoOn: (name) => `Also on ${name}`,
    usageIncoming: "Preview: would move to the cloud",
    usageSelectedState: "selected",
    usageTrayFreeNow: (free) => `Free: ${free}`,
    usageTrayFreeAfter: (after, plus) => `Free after: ${after} (+${plus})`,
    usageTrayOffload: (n) => `Offload ${n}…`,
    usageTrayTrash: (n) => `Move ${n} to Trash…`,
    usageTrayClear: "Clear",
    usageTrayOffloadConfirm: (n, size) => `Offload ${n} items (${size})?`,
    usageTrayOffloadBody: "Apps are packed into your repo and leave a launcher; files and folders move into the repo and leave a .disklessly placeholder with the same name. Each runs as its own job; nothing changes until you confirm.",
    usageTrayTrashConfirm: (n, size) => `Move ${n} items (${size}) to the Trash?`,
    usageTrayTrashBody: "They go to the Trash and can be put back until it is emptied.",
    usageGoal: (size) => `Free up ${size}`,
    usageSelect: (name) => `Select ${name}`,
    usageDeselect: (name) => `Deselect ${name}`,
    usageShowInCloud: (n) => `Show in the cloud (${n})`,
    usageDropOffload: (name) => `Drop to offload ${name}`,
    usageDropRestore: (name) => `Drop to bring ${name} back to this Mac`,
    usageRestoreTitle: (name) => `Bring ${name} back to this Mac?`,
    usageRestoreBody: (size) => `About ${size} is downloaded from your repo and put back where it was.`,
    usageRestoreOk: "Restore",
    usageFetchBody: "A file comes back from its .disklessly placeholder: Finder shows it, and a double-click brings the file back.",
    usageMenuRestore: "Bring back to this Mac…",
    usageNoRestore: "This item cannot be restored from here",
    usageAlreadyOffloaded: "Already offloaded",
    usageNoPack: "Only apps in /Applications or ~/Applications can be offloaded from here",
    cachesLine: (size, n) => `${n} offloaded ${n === 1 ? "app still leaves" : "apps still leave"} ${size} of caches you can clear.`,
    cachesNone: "Offloaded apps left no caches behind.",
    cachesRunning: (names) => `Running apps are skipped: ${names}`,
    cachesClear: "Clear app caches",
    cachesConfirmTitle: (size) => `Clear the caches of offloaded apps (${size})?`,
    cachesConfirmBody: "Only these apps' folders in ~/Library/Caches and a sandbox container's Data/Library/Caches are emptied. Application Support and other data stay; running apps are skipped. Apps rebuild their caches the next time they open.",
    cachesDone: (size) => `Cleared ${size} of caches`,
    cachesFailed: "Could not clear caches",
    usageTips: "Where to free up space",
    dev: "Xcode simulators",
    devIntro: "Simulator runtimes and devices can live in the repo until you need them. A runtime comes back as it was; a simulator comes back with a new UDID.",
    devRuntimes: "Runtimes",
    devSimulators: "Simulators",
    devOffloaded: "In the repo",
    devOffload: "Offload",
    devRestore: "Bring back",
    devForget: "Delete from repo",
    devCleanDerived: "Clean the Xcode build cache (DerivedData)",
    devNone: "None",
    devShutdown: "Shut down",
    devRunning: "Running. Shut it down to offload it.",
    devInUseBy: (names) => `In use by ${names}. Shut it down to offload this runtime.`,
    devConfirmShutdownTitle: (name) => `Shut down simulator “${name}”?`,
    devConfirmShutdownBody: "Any test or app running in it will be interrupted.",
    devUnavailable: "Could not read simulators (Xcode is needed)",
    devInstalledHere: "Also on this Mac",
    devFrom: (host) => `from ${host}`,
    devConfirmRuntimeTitle: (name) => `Offload ${name}?`,
    devConfirmRuntimeBody: (size) => `Uploads ${size} to the repo, checks it, then simctl deletes it from this Mac. It can come back unchanged.`,
    devConfirmSimTitle: (name) => `Offload the simulator ${name}?`,
    devConfirmSimBody: (size) => `Packs the simulator's data (${size}), uploads and checks it, then deletes this simulator. Bringing it back creates the same model and puts the data in; the UDID changes.`,
    devConfirmForgetTitle: (name) => `Delete ${name} from the repo?`,
    devConfirmForgetBody: (size) => `Deletes ${size} from the repo. It can't be brought back afterwards.`,
    devConfirmCleanTitle: "Clean the Xcode build cache (DerivedData)?",
    devConfirmCleanBody: "Moves Xcode's build cache to the Trash. Xcode rebuilds it the next time you build.",
    devConfirmOk: "Continue",
    devJobDone: (name) => `${name}: done`,
    devJobFailed: (name) => `${name}: failed`,
    tipRemoveMacAITitle: "Apple Intelligence models",
    tipRemoveMacAIBody: "\"System & other\" includes the models Apple Intelligence downloads, often several GB. The open-source RemoveMacAI turns Apple Intelligence off, deletes those models and stops them downloading again. Every change can be undone.",
    tipRemoveMacAILink: "Open RemoveMacAI",
    tipDevOffloadTitle: "Xcode simulators",
    tipDevOffloadBody: "Simulator runtimes and devices in \"Library › Developer\" and \"System & other\" can wait in the repo until you need them.",
    tipDevOffloadLink: "Offload them",
    tipPackTitle: "System data too big? Offload big apps",
    tipPackBody: "\"System & other\" is often left behind by big apps. Apps in the recommendations can be offloaded to the repo; this Mac keeps a small stub and they come back when you open them.",
    tipPackLink: "See recommended apps",
    tipSimslimTitle: "Simulators use too much memory? Try simslim",
    tipSimslimBody: "simslim turns off background services a simulator does not need, cutting each simulator's memory by more than half. It saves memory only; a simulator's disk use stays the same.",
    tipSimslimLink: "Open simslim",
    copyCommand: "Copy command",
    copyCommandFor: (name) => `Copy command to pack ${name}`,
    copied: (name) => `Copied the pack command for ${name}`,
    copyFailed: "Could not write to the clipboard; copy the command by hand",
    leftoverBackups: (count, size) => `${count} leftover backup${count === 1 ? "" : "s"} (${size}) can be removed`,
    leftoverAdmin: "Removing them needs an administrator.",
    leftoverClean: "Remove leftover backups",
    leftoverCleanTitle: (count, size) => `Remove ${count} leftover backup${count === 1 ? "" : "s"} (${size})?`,
    leftoverCleanBody: "The leftover backup files listed above (.disklessly-original- copies) will be deleted. macOS asks for an administrator password first, and only backups verified against the repo image are removed. This cannot be undone.",
    leftoverCleanOk: "Delete",
    leftoverCleanDone: "Leftover backups removed",
    leftoverCleanFailed: "Could not remove leftover backups",
    neverUsed: "Never used",
    idleDays: (n) => (n === 1 ? "Last used 1 day ago" : `Last used ${n} days ago`),
    restoreNeeded: "Mac App Store receipt: copied back in full when opened",
    sizeBound: "Size is a lower bound (scan timed out)",
    warnloginItem: "Login item",
    warnmenuBarAgent: "Menu bar app",
    warnbackgroundHelper: "Background helper is running",
    warnsystemExtension: "Bundles a system extension",
    warnkernelExtension: "Bundles a kernel extension",
    warntoolchain: "Other tools use it (toolchain)",
    warnpinned: "Kept on this Mac",
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
    machinesTitle: "Other computers (SSH)",
    machinesSummary: (n, r) => `${n} ${n === 1 ? "machine" : "machines"} · ${r} over SSH`,
    machinesHostLabel: "SSH Host",
    machinesHostPlaceholder: "e.g. gpu-box or dev-server",
    machinesAdd: "Add host",
    machinesRemove: "Remove",
    machinesScan: "Scan disk",
    machinesScanning: "Scanning over SSH…",
    machinesInspect: "Inspect items",
    machinesLocalBadge: "This machine",
    machinesRemoteBadge: "SSH",
    machinesLevel_offline: "Offline",
    machinesLevel_critical: "Critical",
    machinesLevel_warning: "Warning",
    machinesLevel_ok: "Healthy",
    machinesDiskLine: (used, total, reclaim) => `${used} / ${total} used · ${reclaim} reclaimable`,
    machinesNotScanned: "Not scanned yet; click Scan disk to inspect mounts and big items",
    machinesDetailTitle: (host, mode) => `${host} scan details (${mode || "ssh"})`,
    machinesMountsTitle: "Disks and partitions",
    machinesMountFree: (dev, fs, size) => `${dev} (${fs}) · ${size} free`,
    machinesItemsTitle: "Cleanable caches & offloadable big items",
    machinesOffloadedTitle: "Offloaded in the repo",
    machinesNoItems: "No large cleanable or offloadable items found",
    machinesCleanBtn: "Clean",
    machinesOffloadBtn: "Offload",
    machinesRestoreBtn: "Restore",
    machinesPlanConfirmTitle: (act, title, host) => `${act} ${title} on ${host}?`,
    machinesPlanConfirmBody: (path, size, rec) => `Path: ${path}\nSize: ${size}\nRestorable from repo: ${rec ? "Yes (verified in repo before removal, leaves .disklessly-remote stub and journal)" : "No (rebuildable cache/logs deleted in place)"}`,
    machinesRestoreConfirmTitle: (title, host) => `Restore ${title} to ${host}?`,
    machinesRestoreConfirmBody: (path, size) => `Streams ${size} from the repo back to ${path} and removes the stub after verification.`,
    machinesActionDone: (host, title) => `${host}: ${title} finished`,
    machinesActionFailed: (host, title) => `${host}: ${title} failed`,
  },
};
// i18n:end
window.disklesslyI18n = { copy };

const root = document.documentElement;
const primary = root.getAttribute("data-lang") === "en" ? "en" : "zh";
const langTag = { zh: "zh-Hans", en: "en" };

let lastStatus = null;
let lastRecommend = null;
// Remembers whether the folded below-threshold list is open, so re-renders after an action keep it open.
let recommendFoldedOpen = false;
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
const iconEject = "M12 5l7 8H5zM5 15h14v3H5z";
const iconDownload = "M11 4h2v8.2l3.3-3.3 1.4 1.4L12 16l-5.7-5.7 1.4-1.4 3.3 3.3V4zM5 18h14v2H5z";
const iconPin = "M14.5 2.6 21.4 9.5l-1.4 1.4-1.1-.4-3.6 3.6.4 3.9-1.4 1.4-3.6-3.6-4.8 4.8-1.4-1.4 4.8-4.8-3.6-3.6L7.1 9.4l3.9.4 3.6-3.6-.4-1.1z";
const iconTrash = "M9 3h6l1 2h4v2H4V5h4l1-2zM6 9h12l-1 11a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2L6 9zm4 2v8h1.6v-8H10zm2.4 0v8H14v-8h-1.6z";
const iconMore = "M6 10.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zm6 0a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zm6 0a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3z";
const iconCopy = "M8 3h10a2 2 0 0 1 2 2v10h-2V5H8V3zM5 7h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2zm0 2v10h10V9H5z";
const iconRefresh = "M12 4a8 8 0 0 1 7.4 5H17v2h6V5h-2v2.3A10 10 0 0 0 2 12h2a8 8 0 0 1 8-8zm8 8a8 8 0 0 1-15.4 3H7v-2H1v6h2v-2.3A10 10 0 0 0 22 12h-2z";
const iconTray = "M5 4h14l3 9v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-6l3-9zm1.4 2-2.3 7H8l1 2h6l1-2h3.9l-2.3-7H6.4z";
const iconPower = "M11 2h2v10h-2V2zM6.3 5.3l1.4 1.4A7 7 0 1 0 16.3 6.7l1.4-1.4A9 9 0 1 1 6.3 5.3z";
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

function cloudBadge() {
  const badge = el("span", "cloud-badge");
  badge.title = t("cloudBadge");
  badge.setAttribute("aria-label", t("cloudBadge"));
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", "M7 18a4.5 4.5 0 0 1-.5-8.97A6 6 0 0 1 18 9.5a4 4 0 0 1-.5 7.5H7z");
  svg.append(path);
  badge.append(svg);
  return badge;
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
  delayLabel.append(bi("detachDelay"));
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
  // With the full app already installed here, restore and unpack would collide with it.
  const items = fullAppHere(app) ? [] : [
    [bi("restore"), both("restore"), () => confirmAction("restore", app)],
    [bi("unpack", dir), both("unpack", dir), () => confirmAction("unpack", app)],
  ];
  if (!app.cached) items.unshift([bi("prefetch"), both("prefetchFor", app.name), () => startJob("prefetch", app)]);
  if (!fullAppHere(app) && isOnThisMac(app)) {
    const data = app.data || {};
    if (data.enabled) items.push([bi("dataDisable"), both("dataDisable"), () => confirmAction("data/disable", app)]);
    else items.push([bi("dataEnable"), both("dataEnable"), () => confirmAction("data/enable", app)]);
  }
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
  const mine = apps.filter(isOnThisMac);
  const cached = apps.filter((app) => app.cached);
  const size = bytes(cached.reduce((sum, app) => sum + Number(app.cachedBytes || 0), 0));
  const pinned = apps.filter((app) => app.pinned).length;
  node.replaceChildren(one("appsSummary", mine.length, cached.length, size, pinned));
}

function renderApps(list, failure) {
  const rootNode = document.querySelector("#app-list");
  const tools = document.querySelector("#list-tools");
  const head = document.querySelector("#table-head");
  const focusedKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : "";
  rootNode.replaceChildren();
  // Rows from the last answer stay on screen, dimmed, while a reload is in flight.
  if (appsLoading) rootNode.setAttribute("aria-busy", "true");
  else rootNode.removeAttribute("aria-busy");
  const apps = list || [];
  renderAppsSummary(!list || (failure && !apps.length) ? null : apps);
  tools.hidden = apps.length < 2;
  head.hidden = !apps.length;
  if (failure && !apps.length) {
    rootNode.append(errorState(failure.code, failure.message));
    return;
  }
  if (!apps.length) {
    rootNode.append(appsLoading || !appsSettled ? loadingState() : emptyState());
    return;
  }
  const shown = visibleApps(apps);
  if (!shown.length) {
    rootNode.append(el("div", "state-note", both("noMatches")));
    return;
  }
  const quota = Number((lastStatus && lastStatus.cache && lastStatus.cache.quotaBytes) || 0);
  // The repo is shared by every Mac on the account. Apps offloaded on another Mac are listed
  // apart, so they do not look like apps that vanished from this one.
  const here = shown.filter(isOnThisMac);
  const elsewhere = shown.filter((app) => !isOnThisMac(app));
  for (const app of here) rootNode.append(appRow(app, quota));
  if (!here.length) rootNode.append(el("div", "state-note", both("nothingHere")));
  if (elsewhere.length) {
    const group = el("details", "elsewhere");
    group.open = elsewhereOpen;
    group.addEventListener("toggle", () => { elsewhereOpen = group.open; });
    const summary = el("summary", "elsewhere-head");
    summary.append(bi("elsewhereTitle", elsewhere.length));
    group.append(summary, el("p", "elsewhere-note", both("elsewhereNote")));
    for (const app of elsewhere) group.append(appRow(app, quota));
    rootNode.append(group);
  }
  if (focusedKey) {
    const again = rootNode.querySelector(`[data-key="${CSS.escape(focusedKey)}"]`);
    if (again && !again.disabled) again.focus();
  }
}

let elsewhereOpen = false;
// appsLoading: a /api/status request is in flight. appsSettled: a load has finished at least once,
// so "no apps" is only shown after a real answer.
let appsLoading = false;
let appsSettled = false;

/// Shown while the app list has nothing to show yet, or is still loading.
function loadingState() {
  const note = el("div", "state-note state-loading");
  note.setAttribute("role", "status");
  note.append(el("span", "spinner-inline"), el("span", "", t("loadingApps")));
  return note;
}

/// Rows from servers without `local` count as this Mac's, as before.
function isOnThisMac(app) {
  const local = app.local;
  return !local || local.kind === "stub" || local.mine === true;
}

/// The full app is installed here: launching or restoring the image would fight with it.
function fullAppHere(app) {
  return Boolean(app.local && app.local.kind === "installed");
}

function localNote(app) {
  const local = app.local;
  if (!local) return "";
  if (local.kind === "installed") return t("fullAppHere", local.version ? `v${String(local.version).replace(/^v/, "")}` : "");
  if (local.kind === "absent") return t(local.mine ? "launcherMissing" : "notInstalledHere");
  return "";
}

/// One line on what happens to the app's Application Support (data follows the app).
function dataNote(app) {
  const data = app.data;
  if (!data) return "";
  if (data.state === "offloaded") return t("dataInRepo", bytes(data.bytes));
  if (data.lastError) return t("dataWaiting", data.lastError);
  if (!data.enabled) return "";
  if (data.bytes > 0) return t("dataLocal", bytes(data.bytes));
  return t("dataOnQuit");
}

function appRow(app, quota) {
    const job = pending.get(app.name);
    const busy = Boolean(job);
    const row = el("article", "app-row");
    row.dataset.app = app.name || "";
    row.dataset.state = app.state || "";
    if (busy) row.setAttribute("aria-busy", "true");

    const who = el("div", "cell app-cell");
    const icon = appIcon(app.name, app.imageId);
    if (!fullAppHere(app) && isOnThisMac(app)) {
      // Uninstalled from this Mac: the app lives in the repo, so a cloud badge marks it.
      const wrap = el("span", "avatar-wrap");
      wrap.append(icon, cloudBadge());
      who.append(wrap);
    } else {
      who.append(icon);
    }
    const words = el("div", "app-words");
    words.append(el("h3", "app-name", app.name || ""));
    const meta = el("div", "app-meta");
    if (app.version) meta.append(document.createTextNode(`v${String(app.version).replace(/^v/, "")} · `));
    const modeKey = "mode" + (app.mode || "mount");
    meta.append(has(modeKey) ? bi(modeKey) : document.createTextNode(String(app.mode || "")));
    words.append(meta);
    const holders = (app.devices || []).filter(Boolean);
    const fromKey = isOnThisMac(app) ? "onDevices" : "packedOn";
    const extra = [localNote(app), app.lastUsed ? t("lastUsedAt", app.lastUsed) : "", holders.length ? t(fromKey, holders.join(", ")) : "", dataNote(app)].filter(Boolean);
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
    if (app.mounted) {
      // A mounted image cannot be evicted; offer to eject it instead.
      second = actionButton({ labelKey: "detach", name: both("detachFor", app.name), icon: iconEject, className: "outline", busy: isBusy("detach"), disabled: busy, onClick: () => startJob("detach", app) });
      second.title = t("detachHint");
      second.dataset.key = `${app.name}:detach`;
    } else if (app.cached) {
      const blocked = app.pinned ? both("evictPinned") : app.mounted ? both("evictMounted") : "";
      second = actionButton({ labelKey: "evict", icon: iconTrash, className: "danger-outline", busy: isBusy("evict"), disabled: busy, blocked, onClick: () => confirmAction("evict", app) });
      second.dataset.key = `${app.name}:evict`;
    } else {
      second = actionButton({ labelKey: "prefetch", name: both("prefetchFor", app.name), icon: iconDownload, className: "outline", busy: isBusy("prefetch"), disabled: busy, onClick: () => startJob("prefetch", app) });
      second.dataset.key = `${app.name}:prefetch`;
    }
    open.dataset.key = `${app.name}:launch`;
    pinButton.dataset.key = `${app.name}:pin`;
    if (fullAppHere(app)) actions.append(pinButton, second, overflowMenu(app, busy));
    else actions.append(open, pinButton, second, overflowMenu(app, busy));

    row.append(who, status, cacheCell(app, quota), actions);
    return row;
}

// ---- jobs -----------------------------------------------------------------

function confirmAction(kind, app) {
  askConfirm(confirmSpec(kind, app), () => startJob(kind, app));
}

/// The confirmation each job kind asks for; the menus, the usage map's tray and its drag and drop share it.
function confirmSpec(kind, app) {
  const dir = installDir(app);
  const size = bytes(app.cachedBytes || app.imageBytes);
  const spec = {
    evict: { title: ["confirmEvictTitle", app.name], body: ["confirmEvictBody", size], ok: "confirmEvictOk", danger: true },
    restore: { title: ["confirmRestoreTitle", app.name], body: ["confirmRestoreBody"], ok: "confirmRestoreOk", danger: false },
    pack: { title: ["confirmPackTitle", app.name], body: [app.stopFirst ? "confirmStopPackBody" : "confirmPackBody", size], ok: app.stopFirst ? "stopAndOffload" : "confirmPackOk", danger: false },
    offloadfile: { title: ["confirmFileTitle", app.label || app.name], body: ["confirmFileBody", size], ok: "confirmPackOk", danger: false },
    trashpath: { title: ["confirmTrashTitle", app.label || app.name], body: ["confirmTrashBody", size], ok: "trashOk", danger: true },
    "data/enable": { title: ["confirmDataEnableTitle", app.name], body: ["confirmDataEnableBody"], ok: "dataEnable", danger: false },
    "data/disable": { title: ["confirmDataDisableTitle", app.name], body: ["confirmDataDisableBody"], ok: "dataDisable", danger: false },
    unpack: { title: ["confirmUnpackTitle", app.name, dir], body: ["confirmUnpackBody", app.installPath || `${dir}/${app.name}.app`], ok: "confirmUnpackOk", danger: true },
  }[kind];
  return spec;
}

/// The shared confirm dialog. `spec` holds [key, ...args] for title and body.
function askConfirm(spec, onOk) {
  const dialog = document.querySelector("#confirm");
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
    if (dialog.returnValue === "ok") onOk();
    else if (opener && opener.isConnected) opener.focus();
  };
  if (typeof dialog.showModal === "function") {
    dialog.showModal();
    document.querySelector("#confirm-cancel").focus();
  } else if (window.confirm(`${title.textContent}\n\n${body.textContent}`)) {
    onOk();
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
    const payload = kind === "evict" ? { app: app.name, force: false } : kind === "pack" ? { app: app.name, path: app.path, stopFirst: Boolean(app.stopFirst) } : (kind === "offloadfile" || kind === "trashpath") ? { app: app.name, path: app.path } : { app: app.name };
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
  let succeeded = false;
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
      if (!current || current.phase !== job.phase || current.doneBytes !== job.doneBytes || current.totalBytes !== job.totalBytes) {
        pending.set(name, { kind, jobId, phase: job.phase, doneBytes: job.doneBytes, totalBytes: job.totalBytes });
        rerenderApps();
      }
      continue;
    }
    pending.delete(name);
    if (job.state === "done") {
      succeeded = true;
      toast({ title: jobTitle("jobDone", kind, name), tone: "ok" });
    } else {
      toast({ title: jobTitle("jobFailed", kind, name), error: { code: job.error && job.error.code, message: job.error && job.error.message }, tone: "error" });
    }
    break;
  }
  pending.delete(name);
  await load();
  if (kind === "pack") loadRecommendations(true);
  if (kind === "offloadfile" || kind === "trashpath") {
    loadFiles();
    loadBig();
    if (succeeded) await refreshUsageAfterMutation(name);
  }
}

function adoptServerJobs(status) {
  for (const job of (status && status.jobs) || []) {
    if (!job.app || pending.has(job.app)) continue;
    pending.set(job.app, { kind: job.kind, jobId: job.id, phase: job.phase, doneBytes: job.doneBytes, totalBytes: job.totalBytes });
    pollJob(job.app, job.kind, job.id);
  }
}

function renderActiveJobs() {
  const host = document.querySelector("#active-jobs");
  if (!host) return;
  host.replaceChildren();
  if (!pending.size) { host.hidden = true; return; }
  host.hidden = false;
  for (const [key, job] of pending.entries()) {
    const label = key.includes("/") ? key.split("/").filter(Boolean).pop() || key : key;
    const action = tl(primary, "action" + job.kind) || job.kind;
    const phase = tl(primary, "phase" + (job.phase || "queued")) || job.phase || "";
    const hasBytes = typeof job.totalBytes === "number" && job.totalBytes > 0 && typeof job.doneBytes === "number";
    const pct = hasBytes ? Math.min(99, Math.max(1, Math.round((job.doneBytes / job.totalBytes) * 100))) : null;
    const phaseText = hasBytes
      ? `${phase} · ${bytes(job.doneBytes)} / ${bytes(job.totalBytes)} (${pct}%)`
      : (phase ? `${phase}…` : "…");
    const row = el("div", "active-job");
    const head = el("div", "active-job-head");
    head.append(
      el("span", "active-job-name", `${label} · ${action}`),
      el("span", "active-job-phase mono", phaseText),
    );
    const bar = el("div", "active-job-bar");
    const fill = el("div", hasBytes ? "active-job-fill determinate" : "active-job-fill");
    if (hasBytes) fill.style.width = `${pct}%`;
    bar.append(fill);
    row.append(head, bar);
    host.append(row);
  }
}

function rerenderApps() {
  renderActiveJobs();
  if (usageData && usageData.tree) drawUsageMap();
  if (lastRecommend && !recommendLoading) renderRecommend(lastRecommend, null);
  if (filesData) renderFiles();
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
    document.querySelector("#sessions-filter")?.remove();
    const empty = el("li", "state-note");
    empty.append(bi("emptySessions"));
    list.append(empty);
    return;
  }
  const sorted = [...offloaded].sort((a, b) => (Date.parse(b.modified || "") || 0) - (Date.parse(a.modified || "") || 0));
  let filter = document.querySelector("#sessions-filter");
  if (!filter) {
    filter = el("input", "session-filter");
    filter.id = "sessions-filter";
    filter.type = "search";
    filter.autocomplete = "off";
    filter.addEventListener("input", () => {
      sessionFilter = filter.value;
      renderSessions(lastSessions);
    });
    list.before(filter);
  }
  filter.placeholder = t("sessionFilter");
  filter.value = sessionFilter;
  lastSessions = sessions;
  const needle = sessionFilter.trim().toLowerCase();
  const shown = needle ? sorted.filter((e) => [e.title, e.tool, e.displayPath, e.path].some((v) => (v || "").toLowerCase().includes(needle))) : sorted;
  if (!shown.length) {
    const none = el("li", "state-note", t("sessionFilterNone"));
    list.append(none);
  }
  for (const entry of shown) {
    const item = el("li", "session-row");
    // Only cold files are archived, so every offloaded row is cold.
    item.append(pill("grey", "tiercold"));
    item.append(el("span", "session-tool", entry.tool || ""));
    const main = el("span", "session-main");
    const title = el("span", "session-title", entry.title || t("sessionUntitled"));
    title.title = entry.title || "";
    const path = el("span", "session-path mono", entry.displayPath || entry.path || "");
    path.title = entry.path || "";
    main.append(title, path);
    item.append(main);
    const age = entry.ageDays != null ? Number(entry.ageDays) : Math.max(0, Math.floor((Date.now() - (Date.parse(entry.modified || "") || Date.now())) / 86400000));
    const ageNode = el("span", "session-age", t("daysAgo", age));
    item.append(ageNode);
    const actions = el("span", "session-actions");
    if (entry.hasDigest) {
      const open = sessionDigestOpen.has(entry.id);
      const toggle = el("button", "btn quiet", t(open ? "sessionDigestHide" : "sessionDigest"));
      toggle.type = "button";
      toggle.addEventListener("click", () => toggleSessionDigest(entry.id, sessions));
      actions.append(toggle);
    }
    const restore = el("button", "btn outline", t("sessionRestore"));
    restore.type = "button";
    restore.disabled = sessionBusy();
    restore.addEventListener("click", () => restoreSession(entry));
    actions.append(restore);
    item.append(actions);
    if (sessionDigestOpen.has(entry.id)) item.append(el("pre", "session-digest", sessionDigestOpen.get(entry.id) || "…"));
    list.append(item);
  }
}

// Agent session plan: what each agent has, and what could move to the repo.
let sessionPlan = null;
let sessionPick = null; // Set of tool ids the user ticked; null until the plan first loads
const sessionExcluded = new Set(); // paths of cold sessions the user unticked
const sessionExpanded = new Set(); // agents whose session list is open
let sessionTimer = null;
let sessionApplyBytes = 0;
const sessionDigestOpen = new Map(); // entry id -> digest text
let sessionFilter = ""; // text typed into the archived-session filter
let lastSessions = null;

function sessionBusy() {
  return !!(sessionPlan && sessionPlan.task && sessionPlan.task.state === "running");
}

function sessionPickedItems(tool) {
  return (tool.sessions || []).filter((item) => !sessionExcluded.has(item.path));
}

function renderSessionPlan() {
  const box = document.querySelector("#sessions-plan");
  if (!box) return;
  box.removeAttribute("aria-busy");
  box.replaceChildren();
  if (!sessionPlan) return;
  const tools = (sessionPlan.tools || []).filter((tool) => tool.present && tool.files > 0);
  if (!tools.length) { box.append(el("p", "muted", t("sessionPlanNone"))); return; }
  if (!sessionPick) sessionPick = new Set(tools.filter((tool) => tool.coldFiles > 0).map((tool) => tool.tool));
  const busy = sessionBusy();
  for (const tool of tools) {
    const row = el("div", "session-plan-row");
    const label = el("label", "session-plan-tool");
    const box2 = document.createElement("input");
    box2.type = "checkbox";
    const chosen = sessionPickedItems(tool).length;
    box2.checked = sessionPick.has(tool.tool) && tool.coldFiles > 0 && chosen > 0;
    box2.indeterminate = box2.checked && chosen < (tool.sessions || []).length;
    box2.disabled = busy || tool.coldFiles === 0;
    box2.addEventListener("change", () => {
      if (box2.checked) {
        sessionPick.add(tool.tool);
        for (const item of tool.sessions || []) sessionExcluded.delete(item.path);
      } else sessionPick.delete(tool.tool);
      renderSessionPlan();
    });
    label.append(box2, el("strong", null, tool.label || tool.tool));
    row.append(label, el("span", "muted", t("sessionPlanLine", tool.files, bytes(tool.bytes), tool.coldFiles, bytes(tool.coldBytes))));
    if ((tool.sessions || []).length) {
      const open = sessionExpanded.has(tool.tool);
      const toggle = el("button", "btn quiet", t(open ? "sessionHideList" : "sessionShowList", tool.sessions.length));
      toggle.type = "button";
      toggle.setAttribute("aria-expanded", String(open));
      toggle.addEventListener("click", () => {
        if (sessionExpanded.has(tool.tool)) sessionExpanded.delete(tool.tool); else sessionExpanded.add(tool.tool);
        renderSessionPlan();
      });
      row.append(toggle);
    }
    box.append(row);
    if (sessionExpanded.has(tool.tool)) box.append(sessionPlanList(tool, busy));
  }
  const picked = tools.filter((tool) => sessionPick.has(tool.tool) && tool.coldFiles > 0);
  const items = picked.flatMap((tool) => sessionPickedItems(tool));
  const narrowed = picked.some((tool) => sessionPickedItems(tool).length < (tool.sessions || []).length);
  const count = items.length;
  const size = items.reduce((n, item) => n + Number(item.bytes || 0), 0);
  const actions = el("div", "session-plan-actions");
  const apply = el("button", "btn tint", t(busy ? "sessionApplying" : "sessionApply"));
  apply.type = "button";
  apply.disabled = busy || !count;
  if (busy) apply.setAttribute("aria-busy", "true");
  apply.addEventListener("click", () => askConfirm(
    { title: ["sessionConfirmTitle", count, bytes(size)], body: ["sessionConfirmBody", picked.map((tool) => tool.label || tool.tool).join("、")], ok: "sessionApply", danger: true },
    () => { sessionApplyBytes = size; applySessions(picked.map((tool) => tool.tool), narrowed ? items.map((item) => item.path) : null); }));
  actions.append(apply);
  if (count) actions.append(el("span", "muted", t("sessionPicked", count, bytes(size))));
  box.append(actions);
}

// Where a session ran, home-relative.
function sessionProject(item) {
  return (item.project || "").replace(/^\/(?:Users|home)\/[^/]+(?=\/|$)/, "~");
}

// The cold sessions of one agent, each with its own tick box.
function sessionPlanList(tool, busy) {
  const list = el("ul", "session-plan-list");
  const all = tool.sessions || [];
  const head = el("li", "session-plan-item session-plan-bulk");
  for (const [key, include] of [["sessionPickAll", true], ["sessionPickNone", false]]) {
    const button = el("button", "btn quiet", t(key));
    button.type = "button";
    button.disabled = busy;
    button.addEventListener("click", () => {
      for (const item of all) { if (include) sessionExcluded.delete(item.path); else sessionExcluded.add(item.path); }
      if (include) sessionPick.add(tool.tool);
      renderSessionPlan();
    });
    head.append(button);
  }
  list.append(head);
  for (const item of all) {
    const row = el("li", "session-plan-item");
    const label = el("label");
    const tick = document.createElement("input");
    tick.type = "checkbox";
    tick.checked = sessionPick.has(tool.tool) && !sessionExcluded.has(item.path);
    tick.disabled = busy;
    tick.addEventListener("change", () => {
      if (tick.checked) { sessionExcluded.delete(item.path); sessionPick.add(tool.tool); } else sessionExcluded.add(item.path);
      renderSessionPlan();
    });
    const text = el("span", "session-main");
    const title = el("span", "session-title", item.title || t("sessionUntitled"));
    title.title = item.path || "";
    text.append(title);
    const project = sessionProject(item);
    if (project) text.append(el("span", "session-path mono", project));
    label.append(tick, text);
    const age = Math.max(0, Math.floor((Date.now() - (Date.parse(item.modified || "") || Date.now())) / 86400000));
    row.append(label, el("span", "muted", bytes(Number(item.bytes || 0))), el("span", "session-age", t("daysAgo", age)));
    list.append(row);
  }
  return list;
}

async function loadSessionPlan() {
  clearTimeout(sessionTimer);
  const before = sessionPlan && sessionPlan.task && sessionPlan.task.state;
  try {
    sessionPlan = await api("/api/sessions/plan");
  } catch (error) {
    if (error.code === "unauthorized") return;
    sessionPlan = null;
  }
  renderSessionPlan();
  const task = (sessionPlan && sessionPlan.task) || {};
  if (task.state === "running") { sessionTimer = setTimeout(loadSessionPlan, 2000); return; }
  if (before === "running") sessionTaskFinished(task);
}

function sessionTaskFinished(task) {
  if (task.state === "failed") {
    toast({ title: bi(task.action === "sessions-restore" ? "sessionRestoreFailed" : "sessionFailed"), error: { code: "failed", message: task.message || "" }, tone: "error" });
  } else if (task.action === "sessions-restore") {
    toast({ title: bi("sessionRestored", task.path || ""), tone: "ok" });
  } else {
    const moved = Math.max(0, (task.cold || []).length - (task.keptLocal || []).length);
    toast({ title: bi("sessionApplied", moved, bytes(sessionApplyBytes)), tone: "ok" });
  }
  refresh();
}

async function applySessions(tools, paths) {
  try {
    const payload = paths ? { tools, paths } : { tools };
    const started = await api("/api/sessions/apply", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    sessionPlan = Object.assign({}, sessionPlan, { task: started.task });
    renderSessionPlan();
    sessionTimer = setTimeout(loadSessionPlan, 1500);
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("sessionFailed"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

async function restoreSession(entry) {
  try {
    const started = await api("/api/sessions/restore", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: entry.id }) });
    sessionPlan = Object.assign({}, sessionPlan, { task: started.task });
    renderSessionPlan();
    sessionTimer = setTimeout(loadSessionPlan, 1500);
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("sessionRestoreFailed"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

async function toggleSessionDigest(id, sessions) {
  if (sessionDigestOpen.has(id)) { sessionDigestOpen.delete(id); renderSessions(sessions); return; }
  sessionDigestOpen.set(id, "");
  renderSessions(sessions);
  try {
    const result = await api(`/api/sessions/digest?id=${encodeURIComponent(id)}`);
    sessionDigestOpen.set(id, result.digest || "");
  } catch (error) {
    if (error.code === "unauthorized") return;
    sessionDigestOpen.set(id, error.message || "");
  }
  renderSessions(sessions);
}

// ---- recommendations ------------------------------------------------------

// Warnings that are only said, not a reason to hold an app back (see RecommendRanking.noteOnlyWarnings).
const NOTE_ONLY_WARNINGS = new Set(["loginItem", "menuBarAgent"]);

/// The offload button for a recommendation row. An app whose helper is running gets
/// "Stop and offload": the pack job quits the app's own processes first.
function recommendActions(app) {
  const actions = el("div", "actions");
  const job = pending.get(app.name);
  const packing = Boolean(job && job.kind === "pack");
  const stop = (app.warnings || []).includes("backgroundHelper");
  actions.append(actionButton({
    labelKey: packing ? "offloading" : stop ? "stopAndOffload" : "offloadNow",
    name: both(stop ? "stopAndOffloadFor" : "offloadNowFor", app.name),
    icon: iconTray,
    className: "primary",
    busy: packing,
    disabled: Boolean(job),
    onClick: () => confirmAction("pack", { name: app.name, path: app.path, cachedBytes: app.sizeBytes, stopFirst: stop }),
  }));
  if ((app.warnings || []).includes("loginItem")) {
    actions.append(actionButton({
      labelKey: "loginItemsSettings",
      name: both("loginItemsSettings"),
      icon: iconOpen,
      className: "outline",
      onClick: async () => {
        try { await api("/api/loginitems/open", { method: "POST" }); }
        catch (error) { toast({ title: bi("loginItemsSettings"), error, tone: "error" }); }
      },
    }));
  }
  return actions;
}

function recommendReason(app, language) {
  const say = (key, ...args) => tl(language || primary, key, ...args);
  const warnings = app.warnings || [];
  const warnText = (code) => (has("warn" + code) ? say("warn" + code) : code);
  if (warnings.some((code) => !NOTE_ONLY_WARNINGS.has(code))) return warnings.map(warnText).join("; ");
  const parts = [];
  if (app.neverUsed) parts.push(say("neverUsed"));
  else if (app.daysIdle != null) parts.push(say("idleDays", Number(app.daysIdle)));
  if (app.macAppStore) parts.push(say("restoreNeeded"));
  if (app.sizeIncomplete) parts.push(say("sizeBound"));
  if (app.alreadyInRepo) {
    const devices = app.otherDevices || [];
    parts.push(say("alreadyInRepo") + (devices.length ? ` (${devices.join(", ")})` : ""));
  }
  for (const code of warnings) parts.push(warnText(code));
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
  const button = el("button", "btn quiet");
  button.id = "leftover-clean";
  button.type = "button";
  button.append(bi("leftoverClean"));
  button.addEventListener("click", () => confirmLeftoverCleanup(total));
  line.append(" ", button);
  for (const item of items) paths.append(el("li", "mono path", item.path || ""));
}

/// Leftover backups go through one administrator prompt on the server; the page confirms first.
function confirmLeftoverCleanup(total) {
  const items = (lastRecommend && lastRecommend.leftoverBackups) || [];
  if (!items.length || pending.has(LEFTOVER_JOB)) return;
  askConfirm({ title: ["leftoverCleanTitle", items.length, total], body: ["leftoverCleanBody"], ok: "leftoverCleanOk", danger: true }, cleanupLeftovers);
}

async function cleanupLeftovers() {
  if (pending.has(LEFTOVER_JOB)) return;
  const button = document.querySelector("#leftover-clean");
  if (button) button.disabled = true;
  pending.set(LEFTOVER_JOB, { kind: "backups/cleanup", jobId: "", phase: "queued" });
  let failure = null;
  try {
    const started = await api("/api/backups/cleanup", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ app: LEFTOVER_JOB }) });
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, JOB_POLL_MS));
      const job = await api(`/api/jobs/${encodeURIComponent(started.jobId)}`);
      if (job.state === "running") continue;
      if (job.state !== "done") failure = job.error || { code: "failed", message: "" };
      break;
    }
  } catch (error) {
    if (error.code === "unauthorized") return;
    failure = { code: error.code, message: error.message };
  } finally {
    pending.delete(LEFTOVER_JOB);
    if (button) button.disabled = false;
  }
  if (failure) toast({ title: bi("leftoverCleanFailed"), error: failure, tone: "error" });
  else toast({ title: bi("leftoverCleanDone"), tone: "ok" });
  loadRecommendations(true);
  loadUsage();
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

function recommendRow(app) {
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
  const actions = recommendActions(app);
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
  return row;
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
  for (const app of apps) list.append(recommendRow(app));
  const folded = report.folded || [];
  if (folded.length) {
    // Below the threshold: still listed, folded, ordered by use count and size together.
    const details = el("details", "rec-folded");
    details.open = recommendFoldedOpen;
    details.addEventListener("toggle", () => { recommendFoldedOpen = details.open; });
    details.append(el("summary", "rec-folded-title", t("foldedTitle", folded.length)));
    details.append(el("p", "muted small", t("foldedHint")));
    for (const app of folded) details.append(recommendRow(app));
    list.append(details);
  }
  const poor = report.warnings || [];
  warnTitle.hidden = poor.length === 0;
  for (const app of poor) {
    const item = el("li", "poor-row");
    const top = el("div", "rec-name");
    top.append(el("span", "app-name", app.name || ""), pill("grey", modeKeyFor(app.suggestedMode)));
    const words = el("div", "app-words");
    words.append(top, el("div", "mono path", app.path || ""), biPair(recommendReason(app, primary), "", "rec-reason"));
    item.append(words);
    // Only what cannot work is held back: the toolchain, extensions, and apps already packed.
    const blocked = app.suggestedMode === "unsupported" || (app.warnings || []).includes("alreadyPacked");
    if (!blocked) {
      item.classList.add("poor-row-actionable");
      item.append(recommendActions(app));
    }
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

let appManagementConfirmed = localStorage.getItem("disklessly.appManagementConfirmed") === "1";

async function loadPermissions() {
  const card = document.querySelector("#permissions");
  try {
    const perms = await api("/api/permissions");
    const fdaOk = perms.fullDiskAccess === "granted";
    card.hidden = fdaOk && appManagementConfirmed;
    document.querySelector("#perm-fda-state").replaceChildren(bi(fdaOk ? "permGranted" : "permMissing"));
    document.querySelector("#perm-app-ok").hidden = appManagementConfirmed;
  } catch (error) {
    if (error.code !== "unauthorized") card.hidden = true;
  }
}

async function openPermission(which) {
  try {
    await api("/api/permissions/open", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ which }) });
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("usageFailed"), error: { code: error.code, message: error.message }, tone: "error" });
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

/// A Linux build cannot offload apps: hide the app list, onboarding, and recommendations.
function appsSupported() {
  return !lastStatus || lastStatus.platform !== "linux";
}

function applyPlatform() {
  const off = !appsSupported();
  for (const id of ["#apps", "#recommend-section", "#cache-card"]) document.querySelector(id).hidden = off;
  if (off) document.querySelector("#onboarding").hidden = true;
  document.querySelector("#skip").setAttribute("href", off ? "#sessions-section" : "#apps");
}

function render(status) {
  lastStatus = status;
  applyChrome();
  renderOnboarding(status);
  loadPermissions();
  renderBackend(status.backend || null);
  renderCache(status.cache || null);
  if (status.appsError) showBanner(appsErrorCode(status), status.appsError);
  rerenderApps();
  renderDevices(status);
  renderSessions(status.sessions || null);
  applyPlatform();
}

function renderFailure() {
  applyChrome();
  renderOnboarding(null);
  renderBackend(null);
  renderCache(null);
  renderApps([], loadError || { code: "offline", message: "" });
  renderDevices(null);
  renderSessions(null);
  applyPlatform();
}

// ---- license --------------------------------------------------------------

let licenseState = null;

function renderLicense(info) {
  licenseState = info;
  const summary = document.querySelector("#license-summary");
  const detail = document.querySelector("#license-detail");
  const remove = document.querySelector("#license-remove");
  const buy = document.querySelector("#license-buy");
  const input = document.querySelector("#license-code");
  input.setAttribute("aria-label", both("licenseCode"));
  if (!info) { summary.replaceChildren(); detail.replaceChildren(); remove.hidden = true; buy.hidden = true; return; }
  // The link comes from the engine; only a secure web address is shown. The window opens it in the browser.
  const store = typeof info.purchaseURL === "string" && info.purchaseURL.startsWith("https:") ? info.purchaseURL : "";
  if (store) buy.href = store; else buy.removeAttribute("href");
  buy.hidden = !store || info.state === "licensed";
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

// ---- large files ----------------------------------------------------------

let filesData = null;
let filesTimer = null;
let filesAutoStarted = false;

function fileReason(item, language) {
  if (item.daysIdle == null) return tl(language, "filesNever");
  return tl(language, "filesIdle", Number(item.daysIdle));
}

function renderFiles() {
  const scanned = document.querySelector("#files-scanned");
  const button = document.querySelector("#files-scan");
  const summary = document.querySelector("#files-summary");
  const list = document.querySelector("#files-list");
  scanned.replaceChildren();
  summary.replaceChildren();
  list.replaceChildren();
  const data = filesData || {};
  const scanning = data.state === "scanning";
  button.disabled = scanning;
  if (scanning) button.setAttribute("aria-busy", "true");
  else button.removeAttribute("aria-busy");
  if (scanning) scanned.append(bi("filesScanning"));
  else if (data.scannedAt) scanned.append(bi("scannedAgo", data.scannedAt));
  const items = data.items || [];
  if (data.state === "ready") {
    const days = Number(data.minIdleDays || 0);
    summary.append(one("filesSummary", items.length, bytes(data.minSizeBytes || 0), days));
    if (data.partial) summary.append(document.createTextNode(" · "), bi("filesPartial"));
    if (!items.length) {
      const empty = el("div", "state-note");
      empty.append(bi("filesEmpty"));
      list.append(empty);
    }
  }
  for (const item of items) {
    const row = el("article", "rec-row");
    const who = el("div", "app-cell");
    who.append(letterIcon(item.name || "?"));
    const words = el("div", "app-words");
    const nameLine = el("div", "rec-name");
    nameLine.append(el("h3", "app-name", item.name || ""), pill("grey", item.kind === "folder" ? "filesFolder" : "filesFile"));
    words.append(nameLine, el("div", "app-meta", bytes(item.sizeBytes)), biPair(fileReason(item, primary), null, "rec-reason"), el("div", "mono path", item.path || ""));
    who.append(words);
    const actions = el("div", "actions");
    const job = pending.get(item.path);
    const busy = Boolean(job && job.kind === "offloadfile");
    actions.append(actionButton({
      labelKey: busy ? "offloading" : "offloadNow",
      name: both("offloadNowFor", item.name),
      icon: iconTray,
      className: "primary",
      busy,
      disabled: Boolean(job),
      onClick: () => confirmAction("offloadfile", { name: item.path, label: item.name, path: item.path, cachedBytes: item.sizeBytes }),
    }));
    row.append(who, actions);
    list.append(row);
  }
}

async function loadFiles() {
  clearTimeout(filesTimer);
  try {
    filesData = await api("/api/files");
  } catch (error) {
    if (error.code === "unauthorized") return;
    return;
  }
  // The first view scans once; it only reads sizes and dates.
  if (filesData.state === "idle" && !filesAutoStarted) {
    filesAutoStarted = true;
    return startFilesScan();
  }
  renderFiles();
  if (filesData.state === "scanning" && !expired) filesTimer = setTimeout(loadFiles, 3000);
}

async function startFilesScan() {
  try {
    filesData = await api("/api/files/scan", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    renderFiles();
    clearTimeout(filesTimer);
    filesTimer = setTimeout(loadFiles, 2000);
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("filesTitle"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

// ---- Xcode simulators -----------------------------------------------------

let devData = null;
const devBusy = new Map(); // item id -> job kind

const devConfirms = {
  "dev/offload-runtime": (item) => ({ title: ["devConfirmRuntimeTitle", item.title], body: ["devConfirmRuntimeBody", bytes(item.bytes)], ok: "devConfirmOk", danger: false }),
  "dev/offload-simulator": (item) => ({ title: ["devConfirmSimTitle", item.name], body: ["devConfirmSimBody", bytes(item.bytes)], ok: "devConfirmOk", danger: false }),
  "dev/shutdown-simulator": (item) => ({ title: ["devConfirmShutdownTitle", item.name], body: ["devConfirmShutdownBody"], ok: "devShutdown", danger: true }),
  "dev/forget": (item) => ({ title: ["devConfirmForgetTitle", item.title], body: ["devConfirmForgetBody", bytes(item.bytes)], ok: "devForget", danger: true }),
  "dev/clean-derived-data": () => ({ title: ["devConfirmCleanTitle"], body: ["devConfirmCleanBody"], ok: "devConfirmOk", danger: false }),
};

function devAction(kind, id, label, item) {
  const confirm = devConfirms[kind];
  if (confirm) askConfirm(confirm(item), () => devJob(kind, id, label));
  else devJob(kind, id, label);
}

async function devJob(kind, id, label) {
  if (devBusy.has(id)) return;
  devBusy.set(id, kind);
  renderDev();
  let failure = null;
  try {
    const started = await api(`/api/${kind}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ app: id }) });
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, JOB_POLL_MS));
      const job = await api(`/api/jobs/${encodeURIComponent(started.jobId)}`);
      if (job.state === "running") continue;
      if (job.state !== "done") failure = job.error || { code: "failed", message: "" };
      break;
    }
  } catch (error) {
    if (error.code === "unauthorized") return;
    failure = { code: error.code, message: error.message };
  }
  devBusy.delete(id);
  if (failure) toast({ title: biPair(tl(primary, "devJobFailed", label), null), error: failure, tone: "error" });
  else toast({ title: biPair(tl(primary, "devJobDone", label), null), tone: "ok" });
  await loadDev();
}

function devRow(name, detail, size, buttons) {
  const row = el("div", "rec-row");
  const who = el("div");
  const title = el("div", "rec-name");
  title.append(el("strong", null, name));
  who.append(title);
  if (detail) {
    const reason = el("span", "rec-reason");
    reason.append(detail);
    who.append(reason);
  }
  const actions = el("div", "actions");
  actions.append(el("span", "muted small", size), ...buttons);
  row.append(who, actions);
  return row;
}

function devGroup(titleKey, rows) {
  const box = el("div", "dev-group");
  const head = el("h3", "dev-group-title");
  head.append(bi(titleKey));
  box.append(head);
  if (rows.length) box.append(...rows);
  else box.append(el("p", "muted small", t("devNone")));
  return box;
}

function renderDev() {
  const list = document.querySelector("#dev-list");
  if (!list) return;
  list.removeAttribute("aria-busy");
  list.replaceChildren();
  if (!devData) return;
  if (devData.unavailable) {
    list.append(el("p", "muted", t("devUnavailable")));
  }
  const button = (labelKey, icon, kind, id, label, item, blocked, className) =>
    actionButton({ labelKey, icon, className: className || "outline", busy: devBusy.get(id) === kind, disabled: devBusy.has(id), blocked: blocked || undefined, onClick: () => devAction(kind, id, label, item) });
  // A blocked row says why in its detail line, not only in the button's tooltip.
  const withNote = (text, note) => {
    if (!note) return text;
    const node = el("span");
    if (text) node.append(text, " · ");
    node.append(el("span", "warn-text", note));
    return node;
  };
  const runtimes = (devData.runtimes || []).map((r) => {
    const inUse = (r.inUseBy || []).join(", ");
    const note = inUse ? t("devInUseBy", inUse) : r.blocked || "";
    return devRow(r.title, withNote(r.runtimeIdentifier.replace("com.apple.CoreSimulator.SimRuntime.", ""), note), bytes(r.bytes), r.deletable ? [button("devOffload", iconTray, "dev/offload-runtime", r.id, r.title, r, r.blocked)] : []);
  });
  const simulators = (devData.simulators || []).filter((d) => d.bytes >= 50 * 1024 * 1024).map((d) => {
    const booted = d.state === "Booted";
    const buttons = booted
      ? [button("devShutdown", iconPower, "dev/shutdown-simulator", d.udid, d.name, d)]
      : [button("devOffload", iconTray, "dev/offload-simulator", d.udid, d.name, d, d.blocked)];
    return devRow(d.name, withNote("", booted ? t("devRunning") : d.blocked), bytes(d.bytes), buttons);
  });
  const offloaded = (devData.offloaded || []).map((o) => {
    const detail = el("span");
    detail.append(t(o.kind === "runtime" ? "devRuntimes" : "devSimulators"), " · ", t("devFrom", o.host));
    if (o.present) detail.append(" · ", t("devInstalledHere"));
    const restoreKind = o.kind === "runtime" ? "dev/restore-runtime" : "dev/restore-simulator";
    const buttons = [];
    if (!o.present) buttons.push(button("devRestore", iconDownload, restoreKind, o.id, o.title, o));
    buttons.push(button("devForget", iconTrash, "dev/forget", o.id, o.title, o, null, "danger-outline"));
    return devRow(o.title, detail, bytes(o.bytes), buttons);
  });
  list.append(devGroup("devRuntimes", runtimes), devGroup("devSimulators", simulators), devGroup("devOffloaded", offloaded));
  const clean = el("p", "dev-clean");
  clean.append(button("devCleanDerived", iconTrash, "dev/clean-derived-data", "derived-data", "DerivedData", {}, null, "quiet"));
  list.append(clean);
}

async function loadDev() {
  try {
    devData = await api("/api/dev");
  } catch (error) {
    if (error.code === "unauthorized") return;
    document.querySelector("#dev-list").replaceChildren(errorBlock(error.code, error.message));
    return;
  }
  renderDev();
}

// ---- disk usage -----------------------------------------------------------

let usageData = null;
let usageFocus = []; // child indexes from the root
let usageTimer = null;
let usageAutoStarted = false;
const usageDirCache = new Map(); // path -> { children, partial }
const usageDrilledEmpty = new Set(); // paths confirmed empty by a complete scan
const usageLocalPatches = new Map(); // dirPath -> { children, partial, deletedBytes, wasDirScanned, seq }
let usagePatchSeq = 0;
let usageDirCacheStamp = null; // usageData.scannedAt for cache invalidation
let usageDrillingPath = null;
let usageDrillingLabel = "";

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

/// Re-attaches previously fetched directory children after /api/usage replaces the top-level tree.
function hydrateUsageTree(node) {
  function attach(cur) {
    if (!cur) return;
    if (cur.path) {
      if ((!cur.children || !cur.children.length) && usageDirCache.has(cur.path)) {
        const entry = usageDirCache.get(cur.path);
        if (entry && Array.isArray(entry.children) && entry.children.length) {
          cur.children = entry.children;
          cur._dirScanned = true;
        }
      }
      if (usageDrilledEmpty.has(cur.path)) cur._drilledEmpty = true;
    }
    for (const child of cur.children || []) attach(child);
  }
  attach(node);
  applyUsageLocalPatches(node);
}

function updateUsageAncestors(tree, pathIndexes, delta) {
  if (!delta) return;
  let cur = tree;
  for (let i = 0; i < pathIndexes.length; i++) {
    cur.bytes = Math.max(0, (cur.bytes || 0) + delta);
    cur = cur.children && cur.children[pathIndexes[i]];
    if (!cur) break;
  }
  const freeNode = (tree.children || []).find((c) => c.key === "free");
  if (freeNode) {
    freeNode.bytes = Math.max(0, (freeNode.bytes || 0) - delta);
    tree.bytes = Math.max(0, (tree.bytes || 0) - delta);
  }
}

function applyUsageLocalPatches(tree) {
  if (!tree || !usageLocalPatches.size) return;
  for (const [dirPath, patch] of usageLocalPatches.entries()) {
    const pathIdx = findUsagePathByFSPath(tree, dirPath);
    if (!pathIdx) continue;
    let target = tree;
    for (const idx of pathIdx) {
      target = target && target.children && target.children[idx];
    }
    if (!target || target._localPatchSeq === patch.seq) continue;
    const oldBytes = target.bytes || 0;
    const childrenSum = (patch.children || []).reduce((s, c) => s + (c.bytes || 0), 0);
    let delta = childrenSum - oldBytes;
    if (!patch.wasDirScanned && delta > 0 && typeof patch.deletedBytes === "number") {
      delta = -patch.deletedBytes;
    }
    const newBytes = Math.max(0, oldBytes + delta);
    delta = newBytes - oldBytes;
    target.children = patch.children;
    target._dirScanned = true;
    target._localPatchSeq = patch.seq;
    target.bytes = newBytes;
    updateUsageAncestors(tree, pathIdx, delta);
  }
}

function findUsageNodeByFSPath(node, targetPath) {
  if (!node) return null;
  if (node.path === targetPath) return node;
  for (const child of node.children || []) {
    const found = findUsageNodeByFSPath(child, targetPath);
    if (found) return found;
  }
  return null;
}

/// Refreshes the affected directory in place after trash/offload so the treemap keeps the user's current view.
async function refreshUsageAfterMutation(changedPath) {
  if (!usageData || !usageData.tree || !changedPath) return;
  const trail = usageNodeAt(usageFocus);
  const focusNode = trail[trail.length - 1] && trail[trail.length - 1].node;
  const normalized = changedPath.replace(/\/+$/, "");
  const slash = normalized.lastIndexOf("/");
  const parentDir = slash > 0 ? normalized.slice(0, slash) : (slash === 0 ? "/" : "");
  let keepPath = (focusNode && focusNode.path) || null;
  if (keepPath === normalized) keepPath = parentDir || null;

  for (const key of Array.from(usageDirCache.keys())) {
    if (key === normalized || key.startsWith(normalized + "/") || normalized.startsWith(key + "/")) {
      usageDirCache.delete(key);
    }
  }
  for (const key of Array.from(usageDrilledEmpty)) {
    if (key === normalized || key.startsWith(normalized + "/") || normalized.startsWith(key + "/")) {
      usageDrilledEmpty.delete(key);
    }
  }
  for (const key of Array.from(usageLocalPatches.keys())) {
    if (key === normalized || key.startsWith(normalized + "/")) {
      usageLocalPatches.delete(key);
    }
  }

  const knownDeleted = findUsageNodeByFSPath(usageData.tree, normalized);
  const deletedBytes = knownDeleted && typeof knownDeleted.bytes === "number" ? knownDeleted.bytes : null;
  const targetDir = (parentDir && findUsageNodeByFSPath(usageData.tree, parentDir)) ? parentDir : keepPath;
  if (targetDir) {
    const targetNode = findUsageNodeByFSPath(usageData.tree, targetDir);
    const targetKind = (targetNode && targetNode.kind) || (focusNode && focusNode.kind) || "personal";
    try {
      const res = await api(`/api/usage/dir?path=${encodeURIComponent(targetDir)}&kind=${encodeURIComponent(targetKind)}&rescan=1`);
      const nextChildren = Array.isArray(res && res.children) ? res.children : [];
      if (nextChildren.length) {
        usageDirCache.set(targetDir, { children: nextChildren, partial: Boolean(res.partial) });
        usageDrilledEmpty.delete(targetDir);
      } else if (!res || !res.partial) {
        usageDrilledEmpty.add(targetDir);
      }
      const wasDirScanned = Boolean(targetNode && (targetNode._dirScanned || targetNode.path === (focusNode && focusNode.path)));
      usagePatchSeq += 1;
      usageLocalPatches.set(targetDir, {
        children: nextChildren,
        partial: Boolean(res && res.partial),
        deletedBytes,
        wasDirScanned,
        seq: usagePatchSeq,
      });
      hydrateUsageTree(usageData.tree);
    } catch {
      // Keep the current treemap focus even if the local rescan fails.
    }
  }
  if (keepPath) {
    usageFocus = findUsagePathByFSPath(usageData.tree, keepPath) || (parentDir && findUsagePathByFSPath(usageData.tree, parentDir)) || [];
  }
  renderUsage();
}

/// Finds the live index path in `node` whose filesystem path equals `targetPath`.
function findUsagePathByFSPath(node, targetPath, prefix = []) {
  if (!node) return null;
  if (node.path === targetPath) return prefix;
  const kids = node.children || [];
  for (let i = 0; i < kids.length; i++) {
    const found = findUsagePathByFSPath(kids[i], targetPath, [...prefix, i]);
    if (found) return found;
  }
  return null;
}

// usage-math:begin — pure layout and selection math for the split map (checked by scripts/ui-screenshots.mjs).
const USAGE_CHANNEL = 24; // px between the local and the cloud side; carries the ribbons
const USAGE_MIN_SIDE = 120; // the cloud side never gets narrower; it gets shorter instead
const USAGE_MAX_SHARE = 0.45; // above this the cloud side is compressed and says "1 : N"

/// One scale for both sides: pixels per byte are equal, so the cloud side's share of the width is
/// cloud / (disk + cloud). Stacked layouts share the height the same way. Returns pixel sizes.
function usageScale({ width, height, diskBytes, cloudBytes, hasCloud, stacked, channel = USAGE_CHANNEL, minSide = USAGE_MIN_SIDE, maxShare = USAGE_MAX_SHARE }) {
  const out = { stacked: Boolean(stacked), compressed: false, clamped: false, empty: false, ratio: 1, local: { w: Math.floor(width), h: Math.floor(height) }, cloud: null };
  if (!hasCloud) return out;
  const along = stacked ? height : width;
  const across = stacked ? width : height;
  const avail = Math.max(0, along - channel);
  const disk = Math.max(1, diskBytes || 0);
  const cloud = Math.max(0, cloudBytes || 0);
  const share = cloud / (disk + cloud);
  let localAlong;
  let cloudAlong;
  let cloudAcross = across;
  if (!cloud) {
    out.empty = true;
    cloudAlong = Math.min(minSide, avail / 2);
    localAlong = avail - cloudAlong;
  } else if (share > maxShare) {
    out.compressed = true;
    localAlong = avail * (1 - maxShare);
    cloudAlong = avail - localAlong;
    const perByte = (localAlong * across) / disk;
    out.ratio = (cloud * perByte) / (cloudAlong * across);
  } else if (avail * share < minSide) {
    out.clamped = true;
    cloudAlong = Math.min(minSide, avail / 2);
    localAlong = avail - cloudAlong;
    const perByte = (localAlong * across) / disk;
    cloudAcross = Math.min(across, (cloud * perByte) / cloudAlong);
  } else {
    cloudAlong = avail * share;
    localAlong = avail - cloudAlong;
  }
  const size = (a, b) => (stacked ? { w: Math.floor(b), h: Math.floor(a) } : { w: Math.floor(a), h: Math.floor(b) });
  out.local = size(localAlong, across);
  out.cloud = size(cloudAlong, Math.max(cloudAcross, 8));
  return out;
}

/// The four last-used steps: under 30 days, under 180 days, under a year, older. 0 = unknown.
function usageAgeStep(modifiedSeconds, nowMs) {
  if (!modifiedSeconds) return 0;
  const days = (nowMs - modifiedSeconds * 1000) / 86400000;
  if (days < 30) return 1;
  if (days < 180) return 2;
  if (days < 365) return 3;
  return 4;
}

/// Paths of a selection without the ones inside another selected path, so nothing counts twice.
function usageTopPaths(items) {
  const sorted = [...items].sort((a, b) => a.path.length - b.path.length);
  const kept = [];
  for (const item of sorted) {
    if (!kept.some((k) => item.path === k.path || item.path.startsWith(k.path.endsWith("/") ? k.path : k.path + "/"))) kept.push(item);
  }
  return kept;
}

/// "What if": free space after the selection goes, and what moves to the cloud.
function usageWhatIf(items, freeBytes) {
  const top = usageTopPaths(items);
  const freed = top.reduce((sum, item) => sum + (item.bytes || 0), 0);
  const incoming = top.filter((item) => item.canOffload).reduce((sum, item) => sum + (item.bytes || 0), 0);
  return { freed, incoming, freeAfter: (freeBytes || 0) + freed, count: top.length };
}

/// The free-up goal: clearable caches first (largest first), then the rest by bytes × age in days,
/// until the goal is met. Bytes count only up to what is still missing, so a huge box does not win
/// over a colder one that already covers the rest; non-cache picks the goal no longer needs are dropped.
/// It only picks; nothing runs until the user confirms.
function usagePickForGoal(candidates, goal) {
  if (!(goal > 0)) return { keys: [], bytes: 0 };
  const usable = candidates.filter((c) => c.bytes > 0);
  const picked = [];
  let bytes = 0;
  for (const c of usable.filter((c) => c.cache).sort((a, b) => b.bytes - a.bytes)) {
    if (bytes >= goal) break;
    picked.push(c);
    bytes += c.bytes;
  }
  const rest = usable.filter((c) => !c.cache);
  while (bytes < goal && rest.length) {
    const missing = goal - bytes;
    const score = (c) => Math.min(c.bytes, missing) * Math.max(1, c.ageDays || 0);
    let best = 0;
    for (let i = 1; i < rest.length; i++) {
      if (score(rest[i]) > score(rest[best]) || (score(rest[i]) === score(rest[best]) && rest[i].bytes < rest[best].bytes)) best = i;
    }
    const [c] = rest.splice(best, 1);
    picked.push(c);
    bytes += c.bytes;
  }
  // Caches stay picked (they come first by the rule); other picks the goal no longer needs are dropped.
  for (let i = picked.length - 1; i >= 0; i--) {
    if (!picked[i].cache && bytes - picked[i].bytes >= goal) { bytes -= picked[i].bytes; picked.splice(i, 1); }
  }
  return { keys: picked.map((c) => c.key), bytes };
}

/// Index of the box nearest to `from` in direction `dir` (left, right, up, down), or -1.
function usageNearest(rects, from, dir) {
  const a = rects[from];
  if (!a) return -1;
  const ax = a.x + a.w / 2;
  const ay = a.y + a.h / 2;
  let best = -1;
  let bestScore = Infinity;
  rects.forEach((r, i) => {
    if (i === from) return;
    const dx = r.x + r.w / 2 - ax;
    const dy = r.y + r.h / 2 - ay;
    const primary = dir === "left" ? -dx : dir === "right" ? dx : dir === "up" ? -dy : dy;
    const secondary = dir === "left" || dir === "right" ? Math.abs(dy) : Math.abs(dx);
    if (primary <= 0.5) return;
    const score = primary + secondary * 2;
    if (score < bestScore) { bestScore = score; best = i; }
  });
  return best;
}

/// "1 : 3" ratio text for a compressed cloud side.
function usageRatioText(ratio) {
  return ratio < 10 ? String(Math.round(ratio * 10) / 10) : String(Math.round(ratio));
}
// usage-math:end

let cloudUsage = null; // GET /api/usage/cloud
let cloudUsageSignature = "";
let usageCloudFocus = [];
let usageCloudOrigins = []; // origin paths of everything offloaded, for the badges on the local side
const usageSelected = new Map(); // fs path -> { path, bytes, label, isApp, canOffload, canTrash, cache, modified }
let usageHover = null; // { side, el } the box under the pointer or keyboard focus
let usageDrag = null; // { side, node, label }
let usageGoal = 0; // GiB
let usageTint = (() => { try { return localStorage.getItem("disklessly.usageTint") === "age" ? "age" : "kind"; } catch { return "kind"; } })();
const usageActive = { local: "", cloud: "" }; // the box each map's Tab stop is on

// The cloud side's colour per group, from the local palette.
const USAGE_CLOUD_COLOR = { apps: "bundle", files: "personal", linked: "apps", data: "data", sessions: "repo" };

function usageCloudLabel(node, parent, depth) {
  const key = node.key;
  if (depth === 0) return t("usage_cloud");
  if (key === "rest") return t("usage_rest", node.name);
  if (depth === 1 && key && has("usage_cloud_" + key)) return t("usage_cloud_" + key);
  if (key === "bundle") return t("usage_bundle");
  if (key === "data" && parent && parent.key !== "data") return t("usage_data");
  return node.name;
}

function usageCloudTrail(path) {
  let node = usageCloudTree();
  const trail = [{ node, parent: null }];
  for (const index of path) {
    const child = node && node.children && node.children[index];
    if (!child) break;
    trail.push({ node: child, parent: node });
    node = child;
  }
  return trail;
}

function usageHome() {
  return (usageData && usageData.tree && (findHome(usageData.tree) || "")) || "";
}

function findHome(tree) {
  const personal = (tree.children || []).find((c) => c.key === "personal");
  const first = personal && (personal.children || []).find((c) => c.path);
  return first ? first.path.replace(/\/[^/]+$/, "") : "";
}

function usageDisplayPath(path) {
  const home = usageHome();
  if (home && path && (path === home || path.startsWith(home + "/"))) return "~" + path.slice(home.length);
  return path || "";
}

/// The cloud tree as drawn: with a selection, the items that would move there appear as dashed twins.
function usageCloudTree() {
  const tree = cloudUsage && cloudUsage.tree;
  if (!tree) return null;
  const incoming = usageTopPaths([...usageSelected.values()]).filter((item) => item.canOffload);
  if (!incoming.length) return tree;
  const groups = (tree.children || []).slice();
  let added = 0;
  for (const item of incoming) {
    const key = item.isApp ? "apps" : "files";
    let index = groups.findIndex((g) => g.key === key);
    if (index < 0) { groups.push({ name: key, key, kind: "offloaded", bytes: 0, children: [] }); index = groups.length - 1; }
    const group = groups[index];
    groups[index] = Object.assign({}, group, {
      bytes: (group.bytes || 0) + item.bytes,
      children: [...(group.children || []), { name: item.label, kind: "offloaded", bytes: item.bytes, originPath: item.path, _incoming: true }],
    });
    added += item.bytes;
  }
  return Object.assign({}, tree, { bytes: (tree.bytes || 0) + added, children: groups });
}

function usageOffloadedUnder(node) {
  if (!node || !node.path) return 0;
  if (!cloudUsage) return node.offloadedCount || 0;
  const prefix = node.path.endsWith("/") ? node.path : node.path + "/";
  return usageCloudOrigins.filter((o) => o === node.path || o.startsWith(prefix)).length;
}

function usageIsSelected(path) {
  if (!path || !usageSelected.size) return false;
  for (const key of usageSelected.keys()) {
    if (path === key || path.startsWith(key + "/")) return true;
  }
  return false;
}

/// What the rules allow for a local box: offload (pack an app, offload a file or folder) and Trash.
/// An app's `refusal` is the file rule (apps live outside the home folder), so it does not apply to packing;
/// pack takes a top-level app in /Applications or ~/Applications that is not a stub (the server checks again).
function usageAllowed(node) {
  const isApp = Boolean(node.path && node.path.endsWith(".app"));
  const canTrash = !isApp && (typeof node.canTrash === "boolean" ? node.canTrash : !node.refusal);
  let canOffload = !node.refusal;
  if (isApp) {
    const parent = node.path.replace(/\/[^/]+$/, "");
    const home = usageHome();
    const packable = parent === "/Applications" || (home && parent === home + "/Applications") || /^\/(Users|home)\/[^/]+\/Applications$/.test(parent);
    canOffload = packable && !node.offloaded;
  }
  return { isApp, canTrash, canOffload };
}

function usageSelectionItem(node, label) {
  const allowed = usageAllowed(node);
  return { path: node.path, bytes: node.bytes || 0, label, isApp: allowed.isApp, canOffload: allowed.canOffload, canTrash: allowed.canTrash, cache: node.kind === "cache" && allowed.canTrash, modified: node.modified || 0 };
}

function usageToggleSelect(node, label) {
  if (!node || !node.path) return;
  if (usageSelected.has(node.path)) usageSelected.delete(node.path);
  else {
    const item = usageSelectionItem(node, label);
    if (!item.canOffload && !item.canTrash) {
      showUsageTip(item.isApp ? t(node.offloaded ? "usageAlreadyOffloaded" : "usageNoPack") : t("usageMenuRefused", node.refusal || ""));
      return;
    }
    usageSelected.set(node.path, item);
  }
  renderUsage();
}

/// Boxes the free-up goal may pick: the highest box on each branch the rules allow.
function usageGoalCandidates(node, parent, out = []) {
  if (!node) return out;
  const usable = node.path && node.key !== "bundle" && !(node.path.endsWith(".app") && node.offloaded);
  if (usable) {
    const allowed = usageAllowed(node);
    if (allowed.canOffload || allowed.canTrash) {
      const label = usageLabel(node, parent);
      const ageDays = node.modified ? Math.max(0, (Date.now() - node.modified * 1000) / 86400000) : 30;
      out.push({ key: node.path, bytes: node.bytes || 0, ageDays, cache: node.kind === "cache" && allowed.canTrash, node, label });
      return out;
    }
  }
  for (const child of node.children || []) usageGoalCandidates(child, node, out);
  return out;
}

function showUsageTip(text) {
  const tip = document.querySelector("#usage-tip");
  tip.hidden = false;
  tip.textContent = text;
}

function renderUsage() {
  const chart = document.querySelector("#usage-chart");
  const crumbs = document.querySelector("#usage-crumbs");
  const legend = document.querySelector("#usage-legend");
  const summary = document.querySelector("#usage-summary");
  const scanned = document.querySelector("#usage-scanned");
  const button = document.querySelector("#usage-scan");
  const tip = document.querySelector("#usage-tip");
  const tint = document.querySelector("#usage-tint");
  summary.replaceChildren();
  scanned.replaceChildren();
  const scanning = usageData && usageData.state === "scanning";
  button.disabled = Boolean(scanning);
  button.firstElementChild.replaceChildren(bi(usageData && usageData.tree ? "usageRescan" : "usageScan"));
  if (scanning) button.setAttribute("aria-busy", "true"); else button.removeAttribute("aria-busy");
  if (!usageData || !usageData.tree) {
    chart.hidden = crumbs.hidden = legend.hidden = tip.hidden = tint.hidden = document.querySelector("#usage-tips").hidden = true;
    document.querySelector("#usage-cloud-side").hidden = document.querySelector("#usage-channel").hidden = document.querySelector("#usage-tray").hidden = true;
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
  renderUsageCrumbs("local", trail);

  const focus = trail[trail.length - 1].node;
  chart.hidden = false;
  chart.setAttribute("role", "group");
  chart.setAttribute("aria-label", t("usage"));
  tint.hidden = false;
  tint.setAttribute("aria-label", t("usageTintLabel"));
  for (const seg of tint.querySelectorAll("[data-tint]")) seg.setAttribute("aria-pressed", String(seg.dataset.tint === usageTint));
  drawUsageMap();

  renderUsageTips(focus, trail.length === 1);

  legend.hidden = false;
  legend.replaceChildren();
  if (usageTint === "age") {
    for (const step of [1, 2, 3, 4, 0]) {
      const item = el("li", "usage-legend-item");
      item.append(el("span", `usage-swatch usage-age-${step}`), bi(`usageAge${step}`));
      legend.append(item);
    }
  } else {
    for (const kind of USAGE_LEGEND) {
      const item = el("li", "usage-legend-item");
      // Linux names the "library" box App data (the dot folders under ~).
      const text = kind === "library" && !appsSupported() ? "usage_appdata" : usageKindText[kind];
      item.append(el("span", `usage-swatch u-${kind}`), bi(text));
      legend.append(item);
    }
  }
  renderUsageTray();
  renderCleanups(root);
  renderReconcile(root);
}

function renderUsageCrumbs(side, trail) {
  const crumbs = document.querySelector(side === "cloud" ? "#usage-cloud-crumbs" : "#usage-crumbs");
  // The cloud side's title names its root, so its path shows only once it is zoomed in.
  crumbs.hidden = side === "cloud" && trail.length < 2;
  crumbs.replaceChildren();
  trail.forEach((step, depth) => {
    if (depth) { const sep = el("span", "usage-sep"); sep.setAttribute("aria-hidden", "true"); crumbs.append(sep); }
    const last = depth === trail.length - 1;
    const label = side === "cloud" ? usageCloudLabel(step.node, step.parent, depth) : depth === 0 ? usageLabel(step.node, null) : usageLabel(step.node, step.parent);
    const item = el(last ? "span" : "button", last ? "usage-crumb current" : "usage-crumb", label);
    if (!last) {
      item.type = "button";
      item.addEventListener("click", (event) => {
        const byKeyboard = event.detail === 0;
        if (side === "cloud") usageCloudFocus = usageCloudFocus.slice(0, depth);
        else usageFocus = usageFocus.slice(0, depth);
        usageAnimate = true;
        renderUsage();
        if (byKeyboard) focusFirstUsageBox(side);
      });
    }
    crumbs.append(item);
  });
}

// Squarified treemap (Bruls, Huizing, van Wijk): lays the children of one node into a rectangle so that
// each child's area matches its share of the bytes and the boxes stay as close to square as they can.
// Returns [{ child, index, x, y, w, h }] in pixels; children with no bytes get no box.
function usageSquarify(children, x, y, w, h) {
  const items = children.map((child, index) => ({ child, index, bytes: child.bytes || 0 })).filter((item) => item.bytes > 0);
  items.sort((a, b) => b.bytes - a.bytes);
  const total = items.reduce((sum, item) => sum + item.bytes, 0);
  const out = [];
  if (!total || w <= 0 || h <= 0) return out;
  const scale = (w * h) / total;
  for (const item of items) item.area = item.bytes * scale;
  const worst = (row, side) => {
    const sum = row.reduce((s, r) => s + r.area, 0);
    let max = 0;
    let min = Infinity;
    for (const r of row) { max = Math.max(max, r.area); min = Math.min(min, r.area); }
    return Math.max((side * side * max) / (sum * sum), (sum * sum) / (side * side * min));
  };
  const place = (row) => {
    const sum = row.reduce((s, r) => s + r.area, 0);
    if (w >= h) {
      // A column on the left, as wide as the row's share.
      const cw = sum / h;
      let cy = y;
      for (const r of row) { const rh = r.area / cw; out.push({ child: r.child, index: r.index, x, y: cy, w: cw, h: rh }); cy += rh; }
      x += cw; w -= cw;
    } else {
      const rh = sum / w;
      let cx = x;
      for (const r of row) { const cw = r.area / rh; out.push({ child: r.child, index: r.index, x: cx, y, w: cw, h: rh }); cx += cw; }
      y += rh; h -= rh;
    }
  };
  let row = [];
  for (const item of items) {
    const side = Math.min(w, h);
    if (row.length && worst([...row, item], side) > worst(row, side)) { place(row); row = []; }
    row.push(item);
  }
  if (row.length) place(row);
  return out;
}

const USAGE_MAP_DEPTH = 3; // nested levels drawn below the focused node
const USAGE_HEADER = 22; // title strip of a box whose children are drawn inside it
let usageAnimate = false; // the next map redraw is a zoom step, so its boxes fade in
let usageMeasure = null;
let usageFontFamily = ""; // read once per redraw: getComputedStyle after each appended box would force a style recalc

/// Width in pixels of a line of text in the page's font, so labels are only drawn where they fit whole.
function usageTextWidth(text, weight, px) {
  if (!usageMeasure) usageMeasure = document.createElement("canvas").getContext("2d");
  if (!usageFontFamily) usageFontFamily = getComputedStyle(document.body).fontFamily;
  usageMeasure.font = `${weight} ${px}px ${usageFontFamily}`;
  return Math.ceil(usageMeasure.measureText(text).width);
}

/// Keyboard users keep their place after a zoom: focus the first box of the redrawn map.
function focusFirstUsageBox(side = "local") {
  const first = document.querySelector(`${side === "cloud" ? "#usage-cloud" : "#usage-chart"} .usage-box`);
  if (first) first.focus({ preventScroll: true });
}

function usageCloudShown() {
  return Boolean(cloudUsage && cloudUsage.tree);
}

/// Draws both sides at one scale: the local disk on the left (or on top when narrow), the cloud on the right.
function drawUsageMap() {
  const chart = document.querySelector("#usage-chart");
  if (!usageData || !usageData.tree || chart.hidden) return;
  const split = document.querySelector("#usage-split");
  const localSide = document.querySelector("#usage-local-side");
  const cloudSide = document.querySelector("#usage-cloud-side");
  const channel = document.querySelector("#usage-channel");
  const width = Math.floor(split.getBoundingClientRect().width) || 640;
  const stacked = width < 560;
  const base = Math.round(stacked ? Math.min(440, Math.max(300, width * 1.05)) : Math.min(520, Math.max(260, (width * 9) / 16)));
  const cloudTree = usageCloudTree();
  const hasCloud = usageCloudShown();
  const scale = usageScale({ width, height: stacked ? base + 220 : base, diskBytes: usageData.tree.bytes, cloudBytes: cloudTree ? cloudTree.bytes : 0, hasCloud, stacked });
  split.classList.toggle("is-stacked", stacked);
  split.classList.toggle("has-cloud", hasCloud);
  localSide.style.width = hasCloud && !stacked ? `${scale.local.w}px` : "";
  cloudSide.hidden = !hasCloud;
  channel.hidden = !hasCloud;
  usageFontFamily = getComputedStyle(document.body).fontFamily;
  const animate = usageAnimate;
  usageAnimate = false;
  drawUsageSide("local", { w: stacked || !hasCloud ? width : scale.local.w, h: scale.local.h }, animate);
  if (hasCloud) {
    const offline = cloudUsage.reachable === false;
    cloudSide.classList.toggle("is-offline", offline);
    const cloudChart = document.querySelector("#usage-cloud");
    cloudChart.setAttribute("role", "group");
    cloudChart.setAttribute("aria-label", t("usage_cloud"));
    cloudSide.style.width = stacked ? "" : `${scale.cloud.w}px`;
    document.querySelector("#usage-cloud-title").textContent = t("usageCloudTitle", bytes((cloudUsage.tree && cloudUsage.tree.bytes) || 0));
    const chip = document.querySelector("#usage-scale-chip");
    chip.hidden = !scale.compressed;
    chip.textContent = scale.compressed ? t("usageScaleChip", usageRatioText(scale.ratio)) : "";
    const note = document.querySelector("#usage-cloud-note");
    const empty = !(cloudUsage.tree.bytes > 0);
    note.hidden = !(offline || empty);
    note.textContent = offline ? t("usageCloudOffline", cloudUsage.health || "offline") : empty ? t("usageCloudEmpty") : "";
    renderUsageCrumbs("cloud", usageCloudTrail(usageCloudFocus));
    drawUsageSide("cloud", { w: stacked ? scale.cloud.w : scale.cloud.w, h: scale.cloud.h }, animate);
  }
  drawUsageRibbons();
  if (usageDrillingPath) showUsageTip(t("usageDrilling", usageDrillingLabel || usageDrillingPath));
}

/// One side as a nested treemap: each box's area is its size, boxes with room show their children inside
/// under a title strip, and a box with children zooms in when clicked.
function drawUsageSide(side, size, animate) {
  const cloud = side === "cloud";
  const chart = document.querySelector(cloud ? "#usage-cloud" : "#usage-chart");
  const tip = document.querySelector("#usage-tip");
  const trail = cloud ? usageCloudTrail(usageCloudFocus) : usageNodeAt(usageFocus);
  const focusPath = cloud ? usageCloudFocus : usageFocus;
  const focus = trail[trail.length - 1].node;
  if (!focus) { chart.replaceChildren(); return; }
  const width = Math.max(40, size.w);
  const height = Math.max(8, size.h);
  // Narrow sides get one level less nesting, so the boxes keep room for their labels.
  const narrow = width < 560;
  const maxDepth = narrow ? 2 : USAGE_MAP_DEPTH;
  chart.style.height = `${height}px`;
  chart.style.width = cloud ? `${width}px` : "";
  chart.replaceChildren();
  chart.classList.toggle("is-zooming", animate);
  chart.classList.toggle("tint-age", usageTint === "age");
  const now = Date.now();
  const freed = cloud ? 0 : usageWhatIf([...usageSelected.values()], 0).freed;
  const box = (node, parent, rect, path, depth, group) => {
    // Edges snap to whole pixels, so neighbouring boxes share one border line.
    const x = Math.round(rect.x);
    const y = Math.round(rect.y);
    const w = Math.round(rect.x + rect.w) - x;
    const h = Math.round(rect.y + rect.h) - y;
    if (w < 4 || h < 4) return;
    const kids = node.children && node.children.length ? node.children : null;
    const nested = Boolean(kids) && depth < maxDepth && w >= (depth >= 2 ? 96 : 72) && h >= USAGE_HEADER + (depth >= 2 ? 50 : 28);
    const big = !nested && w >= 160 && h >= 72;
    const colour = cloud ? (node.kind === "free" ? "free" : USAGE_CLOUD_COLOR[group] || "other") : node.kind;
    const item = el("button", `usage-box u-${colour} d${depth}${nested ? " frame" : ""}`);
    item.type = "button";
    item.tabIndex = -1;
    if (big) item.classList.add("big");
    const isBusy = !cloud && Boolean((node.path && (pending.has(node.path) || usageDrillingPath === node.path)) || (node.name && pending.has(node.name)));
    if (isBusy) item.classList.add("is-busy");
    const age = usageAgeStep(cloud ? node.lastUsed || node.modified || node.offloadedAt : node.modified, now);
    if (usageTint === "age" && node.kind !== "free") item.classList.add(`usage-age-${age}`);
    item.style.left = `${x}px`;
    item.style.top = `${y}px`;
    item.style.width = `${w}px`;
    item.style.height = `${h}px`;
    const key = cloud ? `c:${node.id || path.join(".")}` : `l:${node.path || path.join(".")}`;
    item.dataset.key = key;
    if (!cloud && node.path) item.dataset.path = node.path;
    if (cloud && node.originPath) item.dataset.origin = node.originPath;
    const ghost = !cloud && usageIsSelected(node.path);
    if (ghost) item.classList.add("is-ghost");
    if (cloud && node._incoming) item.classList.add("is-incoming");
    if (cloud && node.otherDevice) item.classList.add("is-shared");
    const label = cloud ? usageCloudLabel(node, parent, depth) : usageLabel(node, parent);
    const share = focus.bytes ? node.bytes / focus.bytes : 0;
    const pct = focus.bytes ? `${(share * 100).toFixed(share < 0.1 ? 1 : 0)}%` : "";
    // A name or size is drawn only when it fits whole; a cut-off size is worse than none.
    const sizeText = bytes(node.bytes);
    const isAppTile = !cloud && !nested && Boolean(node.path && node.path.endsWith(".app"));
    const iconPx = isAppTile ? (w >= 88 && h >= 68 ? 28 : w >= 44 && h >= 44 ? 24 : w >= 24 && h >= 24 ? 18 : 0) : 0;
    const nameW = usageTextWidth(label, 600, (nested && depth === 1) || big ? 13 : 12);
    const sizeW = usageTextWidth(sizeText, 400, 11.5);
    const inner = w - (big ? 22 : 14);
    const name = () => item.append(el("span", "usage-name", label));
    const sizeEl = () => item.append(el("span", "usage-size", sizeText));
    const appendAppIcon = (px) => {
      const img = document.createElement("img");
      img.className = "usage-app-icon";
      img.width = px;
      img.height = px;
      img.loading = "lazy";
      img.alt = "";
      img.src = String(url("/api/app-icon?path=" + encodeURIComponent(node.path)));
      img.addEventListener("error", () => { img.remove(); }, { once: true });
      item.append(img);
    };
    if (nested) {
      if (w >= 48) { name(); if (nameW + 6 + sizeW <= inner) sizeEl(); }
    } else if (iconPx > 0) {
      // Finviz-style app tile: show the app logo even when the box is too small for text.
      const fitsText = h >= iconPx + 24 && inner >= Math.min(nameW, 36);
      if (fitsText) {
        item.classList.add("has-icon");
        appendAppIcon(iconPx);
        name();
        if (h >= iconPx + 42 && sizeW <= inner) sizeEl();
      } else {
        item.classList.add("icon-only");
        appendAppIcon(iconPx);
      }
    } else if (h >= 22 && inner >= Math.min(nameW, 28)) {
      name();
      // The size sits under the name in a tall leaf, or beside it in a short one.
      if (h >= 42 && sizeW <= inner) sizeEl();
      else if (nameW + 6 + sizeW <= inner) { item.classList.add("inline"); sizeEl(); }
    }
    // Cloud badge: how many offloaded items came from here; activating it shows them on the cloud side.
    const linkedCount = cloud ? 0 : usageOffloadedUnder(node);
    if (linkedCount && w >= 44 && h >= 22) {
      const badge = el("span", "usage-badge");
      badge.append(cloudGlyph(), document.createTextNode(String(linkedCount)));
      badge.title = t("usageLinkedCount", linkedCount);
      badge.addEventListener("click", (event) => { event.stopPropagation(); usageShowInCloud(node.path); });
      item.append(badge);
    }
    const full = cloud ? label : usageLabelBoth(node, parent);
    const named = !cloud && node.key && ["bundle", "cache", "data"].includes(node.key) && parent && parent.name && parent.key == null ? `${parent.name} · ${full}` : full;
    const facts = [named, bytes(node.bytes), pct];
    const ageSeconds = cloud ? node.lastUsed || node.modified : node.modified;
    if (ageSeconds) facts.push(`${t(`usageAge${age}`)} (${t("usageAgeChanged", relativeTime(new Date(ageSeconds * 1000).toISOString()))})`);
    if (linkedCount) facts.push(t("usageLinkedCount", linkedCount));
    if (!cloud && node.key && has("hiddenWhy_" + node.key)) facts.push(hiddenWhy(node));
    if (ghost) facts.push(t("usageSelectedState"));
    if (cloud) {
      if (node._incoming) facts.push(t("usageIncoming"));
      if (node.originPath) facts.push(t("usageOffloadedFrom", usageDisplayPath(node.originPath)));
      if (node.storedBytes) facts.push(t("usageStored", bytes(node.storedBytes)));
      if (node.localBytes) facts.push(t("usageAlsoHere", bytes(node.localBytes)));
      if (node.otherDevice) facts.push(t("usageAlsoOn", node.otherDevice));
    }
    item.title = facts.filter(Boolean).join(" · ");
    item.setAttribute("aria-label", item.title);
    if (ghost) item.setAttribute("aria-pressed", "true");
    const canLazyDrill = !cloud && !kids && Boolean(node.path && !node.path.endsWith(".app") && !node._drilledEmpty && !usageDrilledEmpty.has(node.path));
    if (kids || canLazyDrill) item.classList.add("zoomable");
    item.addEventListener("click", async (event) => {
      // ⌘-click or Ctrl-click selects instead of zooming.
      if (!cloud && (event.metaKey || event.ctrlKey) && node.path) { usageToggleSelect(node, label); return; }
      if (!kids && !canLazyDrill) return;
      // A click from the keyboard (detail 0) keeps focus on the map after the redraw.
      const byKeyboard = event.detail === 0;
      if (!kids && canLazyDrill) {
        await usageDrill(node, label, path, item, byKeyboard);
        return;
      }
      if (cloud) usageCloudFocus = path; else usageFocus = path;
      usageAnimate = true;
      renderUsage();
      if (byKeyboard) focusFirstUsageBox(side);
    });
    const show = () => { showUsageTip(item.title); usageHover = { side, el: item, node }; drawUsageRibbons(); };
    item.addEventListener("mouseenter", show);
    item.addEventListener("pointerdown", show);
    item.addEventListener("focus", () => { usageActive[side] = key; for (const other of chart.querySelectorAll(".usage-box[tabindex='0']")) other.tabIndex = -1; item.tabIndex = 0; show(); });
    item.addEventListener("mouseleave", () => { if (usageHover && usageHover.el === item) { usageHover = null; drawUsageRibbons(); } });
    item.addEventListener("keydown", (event) => {
      if (event.key === " " && !cloud && node.path) { event.preventDefault(); usageToggleSelect(node, label); focusUsageKey(side, key); }
    });
    item.addEventListener("keyup", (event) => { if (event.key === " ") event.preventDefault(); });
    if (!cloud && node.path) item.addEventListener("contextmenu", (event) => { event.preventDefault(); usageContextMenu(event, node, label); });
    if (cloud && !node._incoming && (node.restore || node.stubPath)) item.addEventListener("contextmenu", (event) => { event.preventDefault(); usageCloudMenu(event, node, label); });
    // Drag across the channel: local to cloud offloads, cloud to local restores. Both ask first.
    if ((!cloud && node.path) || (cloud && node.restore && !node._incoming)) {
      item.draggable = true;
      item.addEventListener("dragstart", (event) => {
        usageDrag = { side, node, label };
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", node.path || node.originPath || label);
        item.classList.add("is-dragging");
      });
      item.addEventListener("dragend", () => {
        usageDrag = null;
        item.classList.remove("is-dragging");
        for (const target of document.querySelectorAll(".usage-chart.is-drop")) target.classList.remove("is-drop");
      });
    }
    chart.append(item);
    // Children are later siblings in the DOM, so they sit on top of the frame and take their own clicks.
    if (nested) {
      for (const cell of usageSquarify(kids, x + 2, y + USAGE_HEADER, w - 4, h - USAGE_HEADER - 2)) {
        box(cell.child, node, cell, [...path, cell.index], depth + 1, group);
      }
    }
  };
  // Free space gets a strip along one edge, so the used boxes stay together and the free strip reads as one piece.
  // With a selection the strip grows by what it would free ("what if"); the selected boxes stay as ghosts.
  const layoutTop = (children) => {
    const fi = children.findIndex((c) => c.key === "free" && c.bytes > 0);
    const total = children.reduce((s, c) => s + (c.bytes || 0), 0);
    const freeBytes = fi >= 0 ? children[fi].bytes + freed : 0;
    const share = fi >= 0 && total ? Math.min(0.9, freeBytes / total) : 0;
    const strip = Math.round((narrow ? height : width) * share);
    if (fi < 0 || strip < 28 || share > 0.9) return usageSquarify(children, 0, 0, width, height);
    const rest = children.map((c, i) => (i === fi ? { bytes: 0 } : c));
    return narrow
      ? [...usageSquarify(rest, 0, 0, width, height - strip), { child: children[fi], index: fi, x: 0, y: height - strip, w: width, h: strip }]
      : [...usageSquarify(rest, 0, 0, width - strip, height), { child: children[fi], index: fi, x: width - strip, y: 0, w: strip, h: height }];
  };
  // The focused node fills the whole map (the path above names it); its children are the top boxes.
  const parent = trail.length > 1 ? trail[trail.length - 2].node : null;
  // On the cloud side every box takes the colour of its top group (apps, files, ...).
  const rootGroup = cloud && focusPath.length ? ((usageCloudTree().children || [])[focusPath[0]] || {}).key : null;
  if (focus.children && focus.children.length) {
    for (const cell of layoutTop(focus.children)) {
      box(cell.child, focus, cell, [...focusPath, cell.index], 1, cloud ? rootGroup || cell.child.key : null);
    }
  } else {
    box(focus, parent, { x: 0, y: 0, w: width, h: height }, focusPath, maxDepth, rootGroup);
  }
  if (freed && !cloud) {
    const strip = chart.querySelector(".usage-box.u-free");
    if (strip) strip.classList.add("is-growing");
  }
  // One Tab stop per map; arrow keys move between its boxes.
  const stop = (usageActive[side] && [...chart.querySelectorAll(".usage-box")].find((b) => b.dataset.key === usageActive[side])) || chart.querySelector(".usage-box");
  if (stop) stop.tabIndex = 0;
}

function focusUsageKey(side, key) {
  const chart = document.querySelector(side === "cloud" ? "#usage-cloud" : "#usage-chart");
  const target = [...chart.querySelectorAll(".usage-box")].find((b) => b.dataset.key === key);
  if (target) target.focus({ preventScroll: true });
}

function cloudGlyph() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", "usage-badge-icon");
  const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
  p.setAttribute("d", "M7 18a5 5 0 0 1-.6-10A6 6 0 0 1 18 9a4.5 4.5 0 0 1-.5 9H7z");
  svg.append(p);
  return svg;
}

/// Lazy drill-down into a folder the overview did not list inside.
async function usageDrill(node, label, path, item, byKeyboard) {
  const targetPath = node.path;
  const targetKind = node.kind || "personal";
  if (usageDrillingPath === targetPath) return;
  const cached = usageDirCache.get(targetPath);
  if (cached && Array.isArray(cached.children) && cached.children.length) {
    if (usageData && usageData.tree) hydrateUsageTree(usageData.tree);
    usageFocus = (usageData && usageData.tree && findUsagePathByFSPath(usageData.tree, targetPath)) || path;
    usageAnimate = true;
    renderUsage();
    if (byKeyboard) focusFirstUsageBox();
    return;
  }
  usageDrillingPath = targetPath;
  usageDrillingLabel = label;
  item.classList.add("is-busy");
  showUsageTip(t("usageDrilling", label));
  try {
    const res = await api(`/api/usage/dir?path=${encodeURIComponent(targetPath)}&kind=${encodeURIComponent(targetKind)}`);
    if (res && Array.isArray(res.children) && res.children.length) {
      usageDirCache.set(targetPath, { children: res.children, partial: Boolean(res.partial) });
      usageDrilledEmpty.delete(targetPath);
      if (usageData && usageData.tree) hydrateUsageTree(usageData.tree);
      usageFocus = (usageData && usageData.tree && findUsagePathByFSPath(usageData.tree, targetPath)) || path;
      usageAnimate = true;
      renderUsage();
      if (byKeyboard) focusFirstUsageBox();
      return;
    }
    if (res && res.partial) {
      toast({ title: biPair(t("usageDrillFailed", label)), tone: "error" });
      drawUsageMap();
      return;
    }
    usageDrilledEmpty.add(targetPath);
    node._drilledEmpty = true;
    showUsageTip(t("usageDrillEmpty", label));
    drawUsageMap();
  } catch (err) {
    if (err && err.code !== "unauthorized") {
      toast({ title: biPair(t("usageDrillFailed", label)), error: { code: err.code || "failed", message: err.message || "" }, tone: "error" });
    }
    drawUsageMap();
  } finally {
    if (usageDrillingPath === targetPath) {
      usageDrillingPath = null;
      usageDrillingLabel = "";
    }
  }
}

/// The partner boxes of a box: a local folder's offloaded items on the cloud side, or the local box
/// an offloaded item came from (the deepest one drawn).
function usagePartners(side, node) {
  if (!node) return [];
  if (side === "local") {
    if (!node.path) return [];
    const prefix = node.path + "/";
    return [...document.querySelectorAll("#usage-cloud .usage-box[data-origin]")].filter((b) => b.dataset.origin === node.path || b.dataset.origin.startsWith(prefix));
  }
  const origin = node.originPath;
  if (!origin) return [];
  let best = null;
  for (const b of document.querySelectorAll("#usage-chart .usage-box[data-path]")) {
    const p = b.dataset.path;
    if ((origin === p || origin.startsWith(p + "/")) && (!best || p.length > best.dataset.path.length)) best = b;
  }
  return best ? [best] : [];
}

/// Ribbons across the channel for the hovered or focused pair and for selected items and their twins only.
function drawUsageRibbons() {
  const svg = document.querySelector("#usage-ribbons");
  const split = document.querySelector("#usage-split");
  if (!svg || !split) return;
  for (const lit of document.querySelectorAll(".usage-box.is-linked")) lit.classList.remove("is-linked");
  svg.replaceChildren();
  if (!usageCloudShown()) return;
  const pairs = [];
  if (usageHover && usageHover.el && usageHover.el.isConnected) {
    const partners = usagePartners(usageHover.side, usageHover.node);
    for (const p of partners) p.classList.add("is-linked");
    if (partners[0]) pairs.push(usageHover.side === "local" ? [usageHover.el, partners[0]] : [partners[0], usageHover.el]);
  }
  for (const twin of document.querySelectorAll("#usage-cloud .usage-box.is-incoming[data-origin]")) {
    const local = [...document.querySelectorAll("#usage-chart .usage-box[data-path]")].find((b) => b.dataset.path === twin.dataset.origin);
    if (local) pairs.push([local, twin]);
  }
  if (!pairs.length) return;
  const base = split.getBoundingClientRect();
  svg.setAttribute("viewBox", `0 0 ${Math.max(1, base.width)} ${Math.max(1, base.height)}`);
  const stacked = split.classList.contains("is-stacked");
  // A ribbon leaves the local map at its edge, level with the box (which is outlined), so it never
  // covers other local boxes; it lands on the cloud map's edge level with its partner.
  const localEdge = document.querySelector("#usage-chart").getBoundingClientRect();
  // Stacked, the ribbon lands above the cloud side's title so it never covers the text.
  const cloudEdge = document.querySelector(stacked ? "#usage-cloud-side" : "#usage-cloud").getBoundingClientRect();
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  for (const [a, b] of pairs.slice(0, 12)) {
    const r1 = a.getBoundingClientRect();
    const r2 = b.getBoundingClientRect();
    const L = stacked
      ? { x: clamp(r1.left, localEdge.left, localEdge.right) - base.left, r: clamp(r1.right, localEdge.left, localEdge.right) - base.left, b: localEdge.bottom - base.top }
      : { y: clamp(r1.top, localEdge.top, localEdge.bottom) - base.top, b: clamp(r1.bottom, localEdge.top, localEdge.bottom) - base.top, r: localEdge.right - base.left };
    const C = stacked
      ? { x: r2.left - base.left, r: r2.right - base.left, y: cloudEdge.top - base.top }
      : { y: r2.top - base.top, b: r2.bottom - base.top, x: cloudEdge.left - base.left };
    let d;
    if (stacked) {
      const my = (L.b + C.y) / 2;
      d = `M${L.x} ${L.b} C${L.x} ${my} ${C.x} ${my} ${C.x} ${C.y} L${C.r} ${C.y} C${C.r} ${my} ${L.r} ${my} ${L.r} ${L.b} Z`;
    } else {
      const mx = (L.r + C.x) / 2;
      d = `M${L.r} ${L.y} C${mx} ${L.y} ${mx} ${C.y} ${C.x} ${C.y} L${C.x} ${C.b} C${mx} ${C.b} ${mx} ${L.b} ${L.r} ${L.b} Z`;
    }
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", d);
    path.setAttribute("class", "usage-ribbon");
    svg.append(path);
  }
}

/// Zooms the cloud side to the first offloaded item that came from `path` and lights it up.
function usageShowInCloud(path) {
  const tree = cloudUsage && cloudUsage.tree;
  if (!tree || !path) return;
  const prefix = path + "/";
  const find = (node, trail) => {
    for (let i = 0; i < (node.children || []).length; i++) {
      const child = node.children[i];
      if (child.originPath && (child.originPath === path || child.originPath.startsWith(prefix))) return [...trail, i];
      const deeper = find(child, [...trail, i]);
      if (deeper) return deeper;
    }
    return null;
  };
  const found = find(tree, []);
  if (!found) return;
  usageCloudFocus = found.slice(0, -1);
  usageAnimate = true;
  renderUsage();
  const target = [...document.querySelectorAll("#usage-cloud .usage-box[data-origin]")].find((b) => b.dataset.origin === path || b.dataset.origin.startsWith(prefix));
  if (target) target.focus({ preventScroll: true });
}

let usageResizeTimer = null;
window.addEventListener("resize", () => {
  clearTimeout(usageResizeTimer);
  usageResizeTimer = setTimeout(drawUsageMap, 120);
});

const USAGE_ARROWS = { ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down" };
for (const side of ["local", "cloud"]) {
  const chart = document.querySelector(side === "cloud" ? "#usage-cloud" : "#usage-chart");
  chart.addEventListener("keydown", (event) => {
    if (document.querySelector(".usage-menu")) return;
    // Escape zooms out one level on this side, as a keyboard stand-in for the breadcrumbs.
    if (event.key === "Escape") {
      const trail = side === "cloud" ? usageCloudFocus : usageFocus;
      if (!trail.length) return;
      event.preventDefault();
      if (side === "cloud") usageCloudFocus = usageCloudFocus.slice(0, -1); else usageFocus = usageFocus.slice(0, -1);
      renderUsage();
      focusFirstUsageBox(side);
      return;
    }
    const dir = USAGE_ARROWS[event.key];
    if (!dir) return;
    const boxes = [...chart.querySelectorAll(".usage-box")];
    const from = boxes.indexOf(document.activeElement);
    if (from < 0) return;
    const rects = boxes.map((b) => ({ x: parseFloat(b.style.left), y: parseFloat(b.style.top), w: parseFloat(b.style.width), h: parseFloat(b.style.height) }));
    const next = usageNearest(rects, from, dir);
    event.preventDefault();
    if (next >= 0) boxes[next].focus({ preventScroll: true });
  });
  // A drop from the other side asks to offload (onto the cloud) or restore (onto this Mac).
  chart.addEventListener("dragover", (event) => {
    if (!usageDrag || usageDrag.side === side) return;
    const reason = usageDropRefusal(usageDrag);
    if (reason) { showUsageTip(reason); return; }
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    chart.classList.add("is-drop");
    showUsageTip(t(side === "cloud" ? "usageDropOffload" : "usageDropRestore", usageDrag.label));
  });
  chart.addEventListener("dragleave", () => chart.classList.remove("is-drop"));
  chart.addEventListener("drop", (event) => {
    chart.classList.remove("is-drop");
    if (!usageDrag || usageDrag.side === side || usageDropRefusal(usageDrag)) return;
    event.preventDefault();
    const { node, label } = usageDrag;
    usageDrag = null;
    if (side === "cloud") usageOffload([usageSelectionItem(node, label)]);
    else usageRestore(node, label);
  });
}

for (const seg of document.querySelectorAll("#usage-tint [data-tint]")) {
  seg.addEventListener("click", () => {
    usageTint = seg.dataset.tint === "age" ? "age" : "kind";
    try { localStorage.setItem("disklessly.usageTint", usageTint); } catch {}
    renderUsage();
  });
}

function usageDropRefusal(drag) {
  if (drag.side === "local") {
    const allowed = usageAllowed(drag.node);
    if (allowed.isApp && drag.node.offloaded) return t("usageAlreadyOffloaded");
    if (allowed.isApp && !allowed.canOffload) return t("usageNoPack");
    return allowed.canOffload ? "" : t("usageMenuRefused", drag.node.refusal || "");
  }
  return drag.node.restore ? "" : t("usageNoRestore");
}

/// Offload one or more local boxes through the existing jobs: pack for an app, offloadfile otherwise.
/// One item opens the same dialog as the context menu; several open one dialog for all of them.
function usageOffload(items) {
  const list = usageTopPaths(items).filter((i) => i.canOffload);
  if (!list.length) return;
  const target = (i) => (i.isApp ? ["pack", { name: i.label, path: i.path, cachedBytes: i.bytes }] : ["offloadfile", { name: i.path, label: i.label, path: i.path, cachedBytes: i.bytes }]);
  const done = () => { for (const i of list) usageSelected.delete(i.path); renderUsage(); };
  if (list.length === 1) {
    const [kind, app] = target(list[0]);
    askConfirm(confirmSpec(kind, app), () => { done(); startJob(kind, app); });
    return;
  }
  const total = list.reduce((s, i) => s + i.bytes, 0);
  askConfirm({ title: ["usageTrayOffloadConfirm", list.length, bytes(total)], body: ["usageTrayOffloadBody"], ok: "confirmPackOk", danger: false }, () => {
    done();
    for (const i of list) { const [kind, app] = target(i); startJob(kind, app); }
  });
}

function usageTrash(items) {
  const list = usageTopPaths(items).filter((i) => i.canTrash);
  if (!list.length) return;
  const done = () => { for (const i of list) usageSelected.delete(i.path); renderUsage(); };
  const app = (i) => ({ name: i.path, label: i.label, path: i.path, cachedBytes: i.bytes });
  if (list.length === 1) {
    askConfirm(confirmSpec("trashpath", app(list[0])), () => { done(); startJob("trashpath", app(list[0])); });
    return;
  }
  const total = list.reduce((s, i) => s + i.bytes, 0);
  askConfirm({ title: ["usageTrayTrashConfirm", list.length, bytes(total)], body: ["usageTrayTrashBody"], ok: "trashOk", danger: true }, () => {
    done();
    for (const i of list) startJob("trashpath", app(i));
  });
}

/// Brings an offloaded item back with the job its kind uses; every path asks first.
function usageRestore(node, label) {
  const rows = (lastStatus && lastStatus.apps) || [];
  const row = rows.find((a) => a.name === node.restoreId) || { name: node.restoreId || label, installPath: node.originPath };
  const generic = (onOk) => askConfirm({ title: ["usageRestoreTitle", label], body: ["usageRestoreBody", bytes(node.bytes)], ok: "usageRestoreOk", danger: false }, onOk);
  switch (node.restore) {
    case "unpack":
    case "data/disable":
      confirmAction(node.restore, row);
      return;
    case "links/restore":
      generic(() => startJob("links/restore", { name: node.restoreId }));
      return;
    case "sessions/restore":
      generic(() => restoreSession({ id: node.restoreId }));
      return;
    case "fetch":
      // There is no fetch job on the page: bringing a file back starts from its placeholder in Finder.
      askConfirm({ title: ["usageRestoreTitle", label], body: ["usageFetchBody"], ok: "revealInFinder", danger: false }, () => revealInFinder(node.stubPath || node.originPath));
      return;
    default:
      showUsageTip(t("usageNoRestore"));
  }
}

/// The tray under the map: free space after the selection, the selection, its actions, and the goal slider.
function renderUsageTray() {
  const tray = document.querySelector("#usage-tray");
  if (!usageData || !usageData.tree) { tray.hidden = true; return; }
  tray.hidden = false;
  const root = usageData.tree;
  const free = ((root.children || []).find((c) => c.key === "free") || {}).bytes || 0;
  const items = [...usageSelected.values()];
  const what = usageWhatIf(items, free);
  const head = document.querySelector("#usage-tray-free");
  head.textContent = items.length ? t("usageTrayFreeAfter", bytes(what.freeAfter), bytes(what.freed)) : t("usageTrayFreeNow", bytes(free));
  const top = usageTopPaths(items);
  const offload = document.querySelector("#usage-tray-offload");
  const trash = document.querySelector("#usage-tray-trash");
  const clear = document.querySelector("#usage-tray-clear");
  const offloadCount = top.filter((i) => i.canOffload).length;
  const trashCount = top.filter((i) => i.canTrash).length;
  offload.textContent = t("usageTrayOffload", offloadCount);
  trash.textContent = t("usageTrayTrash", trashCount);
  offload.disabled = !offloadCount;
  trash.disabled = !trashCount;
  clear.disabled = !items.length;
  const list = document.querySelector("#usage-tray-list");
  list.replaceChildren();
  list.hidden = !top.length;
  for (const item of top) {
    const row = el("li", "usage-tray-row");
    row.append(el("span", "usage-tray-name", item.label), el("span", "usage-tray-path mono small muted", usageDisplayPath(item.path)), el("span", "usage-tray-size", bytes(item.bytes)));
    const remove = el("button", "btn quiet usage-tray-remove", "×");
    remove.type = "button";
    remove.setAttribute("aria-label", t("usageDeselect", item.label));
    remove.addEventListener("click", () => { usageSelected.delete(item.path); renderUsage(); });
    row.append(remove);
    list.append(row);
  }
  const candidates = usageGoalCandidates(root, null);
  const maxGiB = Math.floor(candidates.reduce((s, c) => s + c.bytes, 0) / 1073741824);
  const goal = document.querySelector("#usage-goal");
  goal.max = String(maxGiB);
  goal.disabled = !maxGiB;
  if (usageGoal > maxGiB) usageGoal = maxGiB;
  goal.value = String(usageGoal);
  const label = t("usageGoal", bytes(usageGoal * 1073741824));
  document.querySelector("#usage-goal-label").textContent = label;
  goal.setAttribute("aria-valuetext", label);
}

document.querySelector("#usage-tray-offload").addEventListener("click", () => usageOffload([...usageSelected.values()]));
document.querySelector("#usage-tray-trash").addEventListener("click", () => usageTrash([...usageSelected.values()]));
document.querySelector("#usage-tray-clear").addEventListener("click", () => { usageSelected.clear(); usageGoal = 0; renderUsage(); });
let usageGoalFrame = 0;
document.querySelector("#usage-goal").addEventListener("input", (event) => {
  usageGoal = Number(event.target.value) || 0;
  cancelAnimationFrame(usageGoalFrame);
  usageGoalFrame = requestAnimationFrame(() => {
    if (!usageData || !usageData.tree) return;
    const candidates = usageGoalCandidates(usageData.tree, null);
    const picked = new Set(usagePickForGoal(candidates, usageGoal * 1073741824).keys);
    // The goal only selects: it replaces the selection with its picks and starts nothing.
    usageSelected.clear();
    for (const c of candidates) if (picked.has(c.key)) usageSelected.set(c.key, usageSelectionItem(c.node, c.label));
    renderUsage();
    document.querySelector("#usage-goal").focus({ preventScroll: true });
  });
});

/// Loads the cloud side. Redraws only when it changed, so a periodic refresh keeps hover, focus and selection.
async function loadCloudUsage() {
  let next;
  try {
    next = await api("/api/usage/cloud");
  } catch (error) {
    // An older server has no cloud side; the map stays as it was.
    if (error.code === "unauthorized") return;
    if (!cloudUsage) return;
    next = Object.assign({}, cloudUsage, { reachable: false });
  }
  const signature = JSON.stringify([next.reachable, next.health, next.totalBytes, next.tree]);
  if (signature === cloudUsageSignature) return;
  cloudUsageSignature = signature;
  cloudUsage = next;
  usageCloudOrigins = [];
  const walk = (node) => {
    if (!node) return;
    if (node.originPath && (!node.children || !node.children.length)) usageCloudOrigins.push(node.originPath);
    for (const child of node.children || []) walk(child);
  };
  walk(next.tree);
  // Keep the cloud side's zoom while it still points at something.
  if (usageCloudTrail(usageCloudFocus).length !== usageCloudFocus.length + 1) usageCloudFocus = [];
  if (usageData && usageData.tree) renderUsage();
}

/// Right-click on a cloud box: bring it back, or show its stub on this Mac.
function usageCloudMenu(event, node, label) {
  closeUsageMenu();
  const menu = el("div", "menu usage-menu");
  menu.setAttribute("role", "menu");
  const head = el("div", "usage-menu-head");
  head.append(el("strong", "", label));
  if (node.originPath) head.append(el("span", "mono small muted", t("usageOffloadedFrom", usageDisplayPath(node.originPath))));
  menu.append(head);
  const entries = [];
  if (node.restore) entries.push([t("usageMenuRestore"), () => usageRestore(node, label)]);
  if (node.stubPath) entries.push([t("revealInFinder"), () => revealInFinder(node.stubPath)]);
  for (const [text, run] of entries) {
    const item = el("button", "menuitem", text);
    item.type = "button";
    item.setAttribute("role", "menuitem");
    item.addEventListener("click", () => { closeUsageMenu(); run(); });
    menu.append(item);
  }
  placeUsageMenu(menu, event);
}

function placeUsageMenu(menu, event) {
  let x = event.clientX;
  let y = event.clientY;
  // A keyboard-opened menu reports no pointer position, so it opens at the top-left of its box.
  if (x === 0 && y === 0 && event.currentTarget && event.currentTarget.getBoundingClientRect) {
    const rect = event.currentTarget.getBoundingClientRect();
    x = rect.left + 8;
    y = rect.top + 8;
  }
  menu.style.left = `${Math.max(0, Math.min(x, window.innerWidth - 280))}px`;
  menu.style.top = `${Math.max(0, Math.min(y, window.innerHeight - 180))}px`;
  document.body.append(menu);
  const first = menu.querySelector(".menuitem:not([disabled])");
  if (first) first.focus();
  menu.addEventListener("keydown", (e) => { if (e.key === "Escape") closeUsageMenu(); });
  setTimeout(() => document.addEventListener("click", closeUsageMenu, { once: true }), 0);
}

/// Right-click on a box that is one folder: offload it (a cloud-badged link stays) or move it to the Trash.
/// The server applies the same safety rules again; here a refused folder shows why instead.
function usageContextMenu(event, node, label) {
  closeUsageMenu();
  const menu = el("div", "menu usage-menu");
  menu.setAttribute("role", "menu");
  const head = el("div", "usage-menu-head");
  head.append(el("strong", "", label), el("span", "mono small muted", node.path));
  menu.append(head);
  // Select (the keyboard path to the tray's Offload and Move to Trash) and the cloud partner.
  const selectable = usageAllowed(node);
  if (selectable.canOffload || selectable.canTrash) {
    const select = el("button", "menuitem", t(usageSelected.has(node.path) ? "usageDeselect" : "usageSelect", label));
    select.type = "button";
    select.setAttribute("role", "menuitem");
    select.addEventListener("click", () => { closeUsageMenu(); usageToggleSelect(node, label); });
    menu.append(select);
  }
  if (usageOffloadedUnder(node)) {
    const inCloud = el("button", "menuitem", t("usageShowInCloud", usageOffloadedUnder(node)));
    inCloud.type = "button";
    inCloud.setAttribute("role", "menuitem");
    inCloud.addEventListener("click", () => { closeUsageMenu(); usageShowInCloud(node.path); });
    menu.append(inCloud);
  }
  const isApp = Boolean(node.path && node.path.endsWith(".app"));
  const isPictures = Boolean(node.path && (/\/Pictures$/i.test(node.path) || /\.photoslibrary$/i.test(node.path)));
  const isContainerDir = Boolean(node.name && /com\.apple\.container|docker|orbstack|colima/i.test(node.name));
  const busy = Boolean(pending.get(node.path) || pending.get(label));
  const matchedApp = isApp
    ? ((lastStatus && lastStatus.apps) || []).find((a) => a.installPath === node.path || (a.name && a.name.toLowerCase() === label.toLowerCase()))
    : null;
  const isOffloadedStub = Boolean(isApp && (node.offloaded || (matchedApp && !fullAppHere(matchedApp) && isOnThisMac(matchedApp))));
  const appDataChild = isApp ? (node.children || []).find((c) => c.key === "data") : null;
  const appBundleChild = isApp ? (node.children || []).find((c) => c.key === "bundle") : null;
  const canOffload = !node.refusal;
  const canTrash = typeof node.canTrash === "boolean" ? node.canTrash : !node.refusal;
  const entries = isApp
    ? (isOffloadedStub
      ? [
          ["revealInFinder", () => revealInFinder(node.path), true],
          ...(appDataChild && appDataChild.path ? [["revealAppData", () => revealInFinder(appDataChild.path), true]] : []),
          ...(matchedApp && (!matchedApp.data || !matchedApp.data.enabled || matchedApp.data.state === "local")
            ? [[matchedApp.data && matchedApp.data.enabled ? "dataOffloadNow" : "dataEnable", () => confirmAction("data/enable", matchedApp), true]]
            : []),
        ]
      : [
          ["revealInFinder", () => revealInFinder(node.path), true],
          ["packAppMenu", () => confirmAction("pack", { name: label, path: node.path, cachedBytes: node.bytes }), false],
        ])
    : [
        ["revealInFinder", () => revealInFinder(node.path), true],
        ["bigUpload", () => confirmAction("offloadfile", { name: node.path, label, path: node.path, cachedBytes: node.bytes }), false, !canOffload || busy],
        ["bigDelete", () => confirmAction("trashpath", { name: node.path, label, path: node.path, cachedBytes: node.bytes }), false, !canTrash || busy],
      ];
  for (const [key, run, always, forcedDisabled] of entries) {
    const item = el("button", "menuitem", t(key));
    item.type = "button";
    item.setAttribute("role", "menuitem");
    // Showing it in Finder changes nothing, so the safety rules do not apply to it.
    item.disabled = typeof forcedDisabled === "boolean" ? forcedDisabled : (!always && ((!isApp && Boolean(node.refusal)) || busy));
    item.addEventListener("click", () => { closeUsageMenu(); run(); });
    menu.append(item);
  }
  if (isOffloadedStub) {
    const bundleBytes = (appBundleChild && appBundleChild.bytes) || node.bytes || 0;
    const extraBytes = Math.max(0, (node.bytes || 0) - ((appBundleChild && appBundleChild.bytes) || 0));
    const noteText = extraBytes > 1024 * 1024
      ? t("offloadedAppUsageNote", bytes(bundleBytes), bytes(extraBytes))
      : t("offloadedAppOnlyStubNote");
    menu.append(el("div", "usage-menu-note small muted", noteText));
  }
  if (isContainerDir) {
    const engineKey = /com\.apple\.container/i.test(node.name) ? "apple" : /orbstack/i.test(node.name) ? "orbstack" : /colima/i.test(node.name) ? "colima" : "docker";
    const imgs = (ctrData && ctrData.images ? ctrData.images : []).filter((i) => i.engine === engineKey);
    const listBox = el("div", "usage-menu-list");
    if (imgs.length) {
      listBox.append(el("div", "small muted", t("containerImagesHead", imgs.length)));
      for (const img of imgs.slice(0, 8)) {
        const row = el("div", "usage-menu-list-row");
        row.append(el("span", "mono", img.title || img.shortId), el("span", "muted", bytes(img.bytes || 0)));
        listBox.append(row);
      }
    } else {
      listBox.append(el("div", "small muted", t("containerImagesNone")));
    }
    menu.append(listBox);
    const jump = el("button", "menuitem", t("manageContainers"));
    jump.type = "button";
    jump.setAttribute("role", "menuitem");
    jump.addEventListener("click", () => {
      closeUsageMenu();
      const sec = document.querySelector("#ctr-section");
      if (sec) sec.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    menu.append(jump);
  }
  if (isPictures) {
    menu.append(el("div", "usage-menu-note small muted", t("picturesHint")));
  } else if (!isApp && !canOffload && canTrash) {
    menu.append(el("div", "usage-menu-note small muted", t("cacheDeleteHint")));
  } else if (!isApp && node.refusal) {
    menu.append(el("div", "usage-menu-note small muted", t("usageMenuRefused", node.refusal)));
  }
  const linked = ((lastStatus && lastStatus.linkedBundles) || []).find(
    (b) => b.appPath === node.path || (Array.isArray(b.paths) && b.paths.includes(node.path)),
  );
  if (linked) {
    menu.append(el("div", "usage-menu-note small", t("linkGroupBadge", linked.name, (linked.paths || []).length)));
    const groupOffload = el("button", "menuitem", t("linkOffloadGroup"));
    groupOffload.type = "button";
    groupOffload.setAttribute("role", "menuitem");
    groupOffload.disabled = Boolean(pending.get(linked.id));
    groupOffload.addEventListener("click", () => { closeUsageMenu(); startJob("links/offload", { name: linked.id }); });
    const groupRestore = el("button", "menuitem", t("linkRestoreGroup"));
    groupRestore.type = "button";
    groupRestore.setAttribute("role", "menuitem");
    groupRestore.disabled = Boolean(pending.get(linked.id));
    groupRestore.addEventListener("click", () => { closeUsageMenu(); startJob("links/restore", { name: linked.id }); });
    menu.append(groupOffload, groupRestore);
    if (!isApp) {
      const unlinkBtn = el("button", "menuitem", t("linkUnlink"));
      unlinkBtn.type = "button";
      unlinkBtn.setAttribute("role", "menuitem");
      unlinkBtn.addEventListener("click", async () => {
        closeUsageMenu();
        try {
          const res = await api("/api/links/remove", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ appPath: linked.appPath, path: node.path }) });
          if (lastStatus && res.linkedBundles) lastStatus.linkedBundles = res.linkedBundles;
        } catch (err) {
          toast({ title: biPair(err.message || "Unlink failed"), tone: "error" });
        }
      });
      menu.append(unlinkBtn);
    }
  } else if (!isApp && canOffload) {
    const linkBtn = el("button", "menuitem", t("linkToApp"));
    linkBtn.type = "button";
    linkBtn.setAttribute("role", "menuitem");
    linkBtn.addEventListener("click", () => {
      closeUsageMenu();
      openLinkAppPicker(node, label);
    });
    menu.append(linkBtn);
  }
  let x = event.clientX;
  let y = event.clientY;
  // A keyboard-opened menu reports no pointer position, so it opens at the top-left of its box.
  if (x === 0 && y === 0 && event.currentTarget && event.currentTarget.getBoundingClientRect) {
    const rect = event.currentTarget.getBoundingClientRect();
    x = rect.left + 8;
    y = rect.top + 8;
  }
  menu.style.left = `${Math.min(x, window.innerWidth - 280)}px`;
  menu.style.top = `${Math.min(y, window.innerHeight - 180)}px`;
  document.body.append(menu);
  const first = menu.querySelector(".menuitem:not([disabled])");
  if (first) first.focus();
  menu.addEventListener("keydown", (e) => { if (e.key === "Escape") closeUsageMenu(); });
  setTimeout(() => document.addEventListener("click", closeUsageMenu, { once: true }), 0);
}

async function openLinkAppPicker(node, label) {
  const dialog = document.querySelector("#link-picker");
  const title = document.querySelector("#link-picker-title");
  const body = document.querySelector("#link-picker-body");
  const search = document.querySelector("#link-picker-search");
  const list = document.querySelector("#link-picker-list");
  const cancel = document.querySelector("#link-picker-cancel");
  if (!dialog || !list) return;
  title.textContent = t("linkPickerTitle", label);
  body.textContent = t("linkPickerBody");
  search.placeholder = t("linkPickerSearch");
  search.value = "";
  list.replaceChildren(el("div", "link-picker-empty", t("linkPickerLoading")));
  const opener = document.activeElement;
  let allApps = [];
  let closed = false;
  const finish = () => {
    closed = true;
    search.oninput = null;
    cancel.onclick = null;
    dialog.onclose = null;
    if (dialog.open) dialog.close();
    if (opener && opener.isConnected) opener.focus();
  };
  cancel.onclick = finish;
  dialog.onclose = () => {
    closed = true;
    search.oninput = null;
    cancel.onclick = null;
    dialog.onclose = null;
    if (opener && opener.isConnected) opener.focus();
  };
  const renderRows = () => {
    list.replaceChildren();
    const q = search.value.trim().toLowerCase();
    const filtered = q ? allApps.filter((a) => (a.name || "").toLowerCase().includes(q) || (a.path || "").toLowerCase().includes(q)) : allApps;
    if (!allApps.length) {
      list.append(el("div", "link-picker-empty", t("linkPickerEmpty")));
      return;
    }
    if (!filtered.length) {
      list.append(el("div", "link-picker-empty", t("linkPickerNoMatch")));
      return;
    }
    for (const app of filtered) {
      const btn = el("button", "link-picker-item");
      btn.type = "button";
      btn.setAttribute("role", "option");
      const img = document.createElement("img");
      img.className = "link-picker-icon";
      img.alt = "";
      img.loading = "lazy";
      img.src = String(url("/api/app-icon?path=" + encodeURIComponent(app.path)));
      img.addEventListener("error", () => { img.remove(); }, { once: true });
      const meta = el("div", "link-picker-meta");
      const titleRow = el("div", "link-picker-title-row");
      titleRow.append(el("span", "link-picker-name", app.name));
      if (app.offloaded) titleRow.append(el("span", "link-picker-badge", t("linkPickerOffloaded")));
      if (app.linkedCount > 0) titleRow.append(el("span", "link-picker-badge", t("linkPickerLinkedCount", app.linkedCount)));
      meta.append(titleRow, el("span", "link-picker-path mono", app.path));
      btn.append(img, meta);
      btn.addEventListener("click", async () => {
        for (const item of list.querySelectorAll(".link-picker-item")) item.disabled = true;
        try {
          const res = await api("/api/links/add", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ appPath: app.path, appName: app.name, path: node.path }),
          });
          if (lastStatus && res.linkedBundles) lastStatus.linkedBundles = res.linkedBundles;
          finish();
          toast({ title: biPair(t("linkGroupBadge", res.bundle.name, (res.bundle.paths || []).length)), tone: "ok" });
        } catch (err) {
          for (const item of list.querySelectorAll(".link-picker-item")) item.disabled = false;
          toast({ title: biPair(err.message || "Link failed"), tone: "error" });
        }
      });
      list.append(btn);
    }
  };
  search.oninput = renderRows;
  if (typeof dialog.showModal === "function") dialog.showModal();
  search.focus();
  try {
    const res = await api("/api/links/apps");
    if (closed) return;
    allApps = Array.isArray(res && res.apps) ? res.apps : [];
    renderRows();
  } catch (err) {
    if (closed) return;
    list.replaceChildren(el("div", "link-picker-empty", err.message || t("linkPickerEmpty")));
  }
}

async function revealInFinder(path) {
  try {
    await api("/api/reveal", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path }) });
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("revealFailed"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

function closeUsageMenu() {
  for (const menu of document.querySelectorAll(".usage-menu")) menu.remove();
}

/// Boxes with a cleanup, anywhere in the tree, largest first.
function usageActions(node, parent, out = []) {
  if (node.action && node.bytes > 0) out.push({ node, parent });
  for (const child of node.children || []) usageActions(child, node, out);
  return out.sort((a, b) => b.node.bytes - a.node.bytes);
}

function renderCleanups(root) {
  const box = document.querySelector("#usage-clean");
  const found = usageActions(root);
  box.hidden = !found.length;
  box.replaceChildren();
  if (!found.length) return;
  box.append(el("h3", "usage-clean-title", t("cleanTitle")));
  const cleanup = (usageData && usageData.cleanup) || {};
  const list = el("ul", "usage-clean-list");
  for (const { node, parent } of found) {
    const name = usageLabel(node, parent);
    const item = el("li", "usage-clean-item");
    const words = el("div", "usage-clean-words");
    words.append(el("strong", "", `${name} · ${bytes(node.bytes)}`), el("span", "muted", t("cleanWhat_" + node.action.replace(/-/g, "_"))));
    const running = cleanup.state === "running" && cleanup.action === node.action;
    const button = el("button", "btn outline", t(running ? "cleanRunning" : "cleanRun"));
    button.type = "button";
    button.disabled = cleanup.state === "running";
    if (running) button.setAttribute("aria-busy", "true");
    button.addEventListener("click", () => {
      if (window.confirm(`${t("cleanConfirm", name)}\n\n${t("cleanWhat_" + node.action.replace(/-/g, "_"))}`)) runCleanup(node.action, name);
    });
    item.append(words, button);
    list.append(item);
  }
  box.append(list, el("p", "muted small", t("cleanNote")));
}

// Hidden usage: the children of "Not measured" with their own actions, plus the AI model folders.
let reconcileData = null;
let reconcileFor = null;
let reconcileLoading = false;

function usageFind(node, key) {
  if (!node) return null;
  if (node.key === key) return node;
  for (const child of node.children || []) {
    const found = usageFind(child, key);
    if (found) return found;
  }
  return null;
}

function hiddenWhy(node) {
  if (node.key !== "spotlight") return t("hiddenWhy_" + node.key);
  const unmeasured = usageData && usageData.tree ? usageFind(usageData.tree, "unmeasured") : null;
  const threshold = unmeasured && unmeasured.hidden ? unmeasured.hidden.spotlightThresholdBytes : 0;
  return t("hiddenWhy_spotlight", bytes(threshold || 0));
}

async function loadReconcile(stamp) {
  if (reconcileLoading) return;
  reconcileLoading = true;
  try {
    reconcileData = await api("/api/reconcile");
    reconcileFor = stamp;
  } catch (error) {
    reconcileData = null;
    reconcileFor = stamp;
  } finally {
    reconcileLoading = false;
  }
  if (usageData && usageData.tree) renderReconcile(usageData.tree);
}

function reconcileButton(action, labelKey, confirmText, name) {
  const cleanup = (usageData && usageData.cleanup) || {};
  const running = cleanup.state === "running" && cleanup.action === action;
  const button = el("button", "btn outline", t(running ? "cleanRunning" : labelKey));
  button.type = "button";
  button.disabled = cleanup.state === "running";
  if (running) button.setAttribute("aria-busy", "true");
  // Every action has its own confirmation; nothing here is part of a bulk clean.
  button.addEventListener("click", () => { if (window.confirm(confirmText)) runReconcileAction(action, name); });
  return button;
}

function renderReconcile(root) {
  const box = document.querySelector("#usage-reconcile");
  if (!box) return;
  const unmeasured = usageFind(root, "unmeasured");
  const facts = unmeasured && unmeasured.hidden;
  const stamp = usageData && usageData.scannedAt;
  if (facts && reconcileFor !== stamp && !reconcileLoading) loadReconcile(stamp);
  const models = (reconcileData && reconcileData.models) || [];
  box.hidden = !facts && !models.length;
  box.replaceChildren();
  if (box.hidden) return;
  box.append(el("h3", "usage-clean-title", t("hiddenTitle")));
  const list = el("ul", "usage-clean-list");
  if (facts) {
    box.append(el("p", "muted small", t("hiddenSummary", bytes(facts.gapBytes || 0), bytes(facts.usedBytes || 0))));
    for (const part of unmeasured.children || []) {
      const name = usageLabel(part, unmeasured);
      const item = el("li", "usage-clean-item");
      const words = el("div", "usage-clean-words");
      words.append(el("strong", "", `${name} · ${bytes(part.bytes)}`), el("span", "muted", hiddenWhy(part)));
      if (part.key === "otherusers") words.append(el("span", "muted", (part.children || []).map((c) => `${c.name} ${bytes(c.bytes)}`).join(" · ")));
      item.append(words);
      const action = part.reconcile;
      if (action) item.append(reconcileButton(action, "reconcileRun_" + action.replace(/-/g, "_"), t("reconcileConfirm_" + action.replace(/-/g, "_")), name));
      else if (part.key === "spotlight") words.append(el("span", "muted", t("hiddenSpotlightOk", bytes(part.bytes))));
      list.append(item);
    }
    const notes = [t("hiddenPurgeable", bytes(facts.purgeableBytes || 0), (facts.snapshots || []).length)];
    if (!(facts.snapshots || []).length && facts.purgeableBytes > 0) notes.push(t("hiddenPurgeableNoSnap"));
    if ((facts.unreadable || []).length) notes.push(t("hiddenUnreadable", facts.unreadable.length));
    box.append(list);
    const note = el("p", "muted small", notes.join(" "));
    if ((facts.unreadable || []).length) note.title = facts.unreadable.join("\n");
    box.append(note);
  } else {
    box.append(list);
  }
  if (models.length) {
    box.append(el("h4", "usage-clean-title", t("hiddenModels")));
    const modelList = el("ul", "usage-clean-list");
    for (const model of models) {
      const item = el("li", "usage-clean-item");
      const words = el("div", "usage-clean-words");
      const when = model.lastUsed ? t("hiddenModelUsed", relativeTime(new Date(model.lastUsed * 1000).toISOString())) : t("hiddenModelNever");
      words.append(el("strong", "", `${model.title} · ${bytes(model.bytes)}`), el("span", "muted", `${usageDisplayPath(model.path)} · ${when}`));
      if (model.inUse) words.append(el("span", "muted", t("hiddenModelInUse", (model.inUseBy || []).join("; "))));
      item.append(words);
      const actions = el("div", "usage-clean-actions");
      for (const kind of ["offload", "trash"]) {
        const button = reconcileButton(`model-${kind}:${model.id}`, `reconcileRun_model_${kind}`, t(`reconcileConfirm_model_${kind}`, model.title, model.path), model.title);
        // In use: the server refuses too; the button says why instead of failing later.
        if (model.inUse) { button.disabled = true; button.title = t("hiddenModelInUse", (model.inUseBy || []).join("; ")); }
        actions.append(button);
      }
      item.append(actions);
      modelList.append(item);
    }
    box.append(modelList);
  }
  box.append(el("p", "muted small", t("hiddenNote")));
}

async function runReconcileAction(action, name) {
  cleanupName = name;
  try {
    const started = await api("/api/reconcile/action", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action, confirm: true }) });
    usageData = Object.assign({}, usageData, { cleanup: started.cleanup });
    reconcileFor = null;
    renderUsage();
    clearTimeout(usageTimer);
    usageTimer = setTimeout(loadUsage, 1500);
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("reconcileFailed", name), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

let cleanupName = "";

async function runCleanup(action, name) {
  cleanupName = name;
  try {
    const started = await api("/api/usage/clean", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action }) });
    usageData = Object.assign({}, usageData, { cleanup: started.cleanup });
    renderUsage();
    clearTimeout(usageTimer);
    usageTimer = setTimeout(loadUsage, 1500);
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("cleanFailed", name), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

// Caches of offloaded apps, measured after a usage scan and cleared on request.
let cachesData = null;
let cachesScannedAt = null;

function renderCaches() {
  const line = document.querySelector("#usage-caches");
  const text = document.querySelector("#usage-caches-text");
  const button = document.querySelector("#usage-caches-clear");
  if (!cachesData) { line.hidden = true; return; }
  const apps = (cachesData.apps || []).filter((a) => a.bytes > 0);
  const clearable = apps.filter((a) => !a.refused);
  const running = apps.filter((a) => a.refused).map((a) => a.name);
  line.hidden = false;
  text.replaceChildren(clearable.length ? one("cachesLine", bytes(cachesData.freedBytes), clearable.length) : bi("cachesNone"));
  if (running.length) text.append(el("br"), one("cachesRunning", running.join(", ")));
  button.hidden = !clearable.length;
}

async function loadCaches() {
  try {
    cachesData = await api("/api/caches");
  } catch (error) {
    if (error.code === "unauthorized") return;
    cachesData = null;
  }
  renderCaches();
}

function clearCaches() {
  if (!cachesData || !cachesData.freedBytes) return;
  const size = bytes(cachesData.freedBytes);
  askConfirm({ title: ["cachesConfirmTitle", size], body: ["cachesConfirmBody"], ok: "cachesClear", danger: true }, async () => {
    const button = document.querySelector("#usage-caches-clear");
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
    try {
      const report = await api("/api/caches/clear", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      cachesData = report;
      startUsageScan();
      const failed = report.failed || [];
      if (failed.length) toast({ title: bi("cachesFailed"), error: { code: "failed", message: failed.join("; ") }, tone: "error" });
      else toast({ title: one("cachesDone", bytes(report.freedBytes)) });
      await loadCaches();
    } catch (error) {
      if (error.code !== "unauthorized") toast({ title: bi("cachesFailed"), error: { code: error.code, message: error.message }, tone: "error" });
    } finally {
      button.disabled = false;
      button.removeAttribute("aria-busy");
    }
  });
}

/// Tools outside Disklessly that free space Disklessly can't, shown for the
/// whole disk and for the part of it they act on.
const USAGE_TIPS = [
  { id: "RemoveMacAI", kind: "system", url: "https://github.com/omlahore/RemoveMacAI" },
  { id: "DevOffload", kind: "library", url: "#dev-section" },
  { id: "Pack", kind: "system", url: "#recommend-section" },
  { id: "Simslim", kind: "library", url: "https://github.com/MobAI-App/simslim" },
];

function renderUsageTips(focus, atRoot) {
  const list = document.querySelector("#usage-tips");
  const tips = USAGE_TIPS.filter((tip) => atRoot || focus.kind === tip.kind || focus.key === tip.kind);
  list.hidden = !tips.length;
  list.replaceChildren();
  if (!tips.length) return;
  list.append(el("h3", "usage-tips-title"));
  list.firstChild.append(bi("usageTips"));
  for (const tip of tips) {
    const item = el("div", `usage-tip-item`);
    const title = el("div", "usage-tip-head");
    title.append(el("span", `usage-swatch u-${tip.kind}`), bi(`tip${tip.id}Title`));
    const body = el("p", "muted small");
    body.append(bi(`tip${tip.id}Body`));
    const link = el("a", "link");
    link.href = tip.url;
    if (!tip.url.startsWith("#")) {
      link.target = "_blank";
      link.rel = "noopener noreferrer";
    }
    link.append(bi(`tip${tip.id}Link`));
    if (!tip.url.startsWith("#")) link.append(document.createTextNode(" ↗"));
    item.append(title, body, link);
    list.append(item);
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
  if (usageData && usageData.scannedAt) {
    if (usageDirCacheStamp && usageData.scannedAt !== usageDirCacheStamp) {
      usageDirCache.clear();
      usageDrilledEmpty.clear();
      usageLocalPatches.clear();
    }
    usageDirCacheStamp = usageData.scannedAt;
  }
  if (usageData && usageData.tree) hydrateUsageTree(usageData.tree);
  // Nothing measured since the app started: analyze right away, it only reads sizes.
  if (usageData.state === "idle" && !usageAutoStarted) {
    usageAutoStarted = true;
    return startUsageScan();
  }
  renderUsage();
  const cleanup = usageData.cleanup || {};
  if (cleanupName && cleanup.state && cleanup.state !== "running") {
    const name = cleanupName;
    cleanupName = "";
    if (cleanup.state === "done") toast({ title: bi("cleanDone", name, bytes(cleanup.freedBytes || 0)), tone: "ok" });
    else toast({ title: bi("cleanFailed", name), error: { code: "failed", message: cleanup.message || "" }, tone: "error" });
  }
  if ((usageData.state === "scanning" || cleanup.state === "running") && !expired) usageTimer = setTimeout(loadUsage, 2000);
  // Measured once a scan finished, and again after the next one.
  else if (usageData.tree && usageData.scannedAt !== cachesScannedAt) { cachesScannedAt = usageData.scannedAt; loadCaches(); }
}

async function startUsageScan() {
  try {
    usageDirCache.clear();
    usageDrilledEmpty.clear();
    usageLocalPatches.clear();
    usageDrillingPath = null;
    usageDrillingLabel = "";
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
  appsLoading = true;
  // Keep the last rows (dimmed) while the request runs; with no rows yet, show the loading row.
  if (lastStatus) renderApps(lastStatus.apps || [], lastStatus.appsError ? { code: appsErrorCode(lastStatus), message: lastStatus.appsError } : null);
  else renderApps(null, null);
  let status;
  try {
    status = await api("/api/status");
  } catch (error) {
    appsLoading = false;
    if (error.code === "unauthorized") {
      // Not a finished load: an unauthorized answer does not mean the list is empty.
      renderApps(lastStatus ? lastStatus.apps || [] : null, null);
      return;
    }
    appsSettled = true;
    loadError = { code: error.code, message: error.message };
    showBanner(error.code, error.message);
    if (!lastStatus) renderFailure();
    else {
      renderBackend(Object.assign({}, lastStatus.backend, { health: "offline", latencyMs: null }));
      renderApps(lastStatus.apps || [], lastStatus.appsError ? { code: appsErrorCode(lastStatus), message: lastStatus.appsError } : null);
    }
    return;
  }
  appsLoading = false;
  appsSettled = true;
  loadError = null;
  updatedAt = Date.now();
  if (!status.appsError) hideBanner();
  adoptServerJobs(status);
  render(status);
  loadLicense();
  loadUsage();
  loadCloudUsage();
  if (!filesData || filesData.state !== "scanning") loadFiles();
  loadDev();
  if (!sessionBusy()) loadSessionPlan();
  if (appsSupported() && (!bigData || bigData.state !== "scanning")) loadBig();
  if (!ctrData || ctrData.state !== "scanning") loadContainers();
  if (!machinesData || !machinesData.scanning) loadMachines();
}

/// The disk map is measured again when it was never measured or is older than USAGE_STALE_MS.
function usageStale() {
  if (usageData && usageData.state === "scanning") return false;
  if (!usageData || !usageData.scannedAt) return true;
  const measured = Date.parse(usageData.scannedAt);
  return !(measured > 0) || Date.now() - measured > USAGE_STALE_MS;
}

function refresh() {
  // Coalesce overlapping refreshes instead of a page-wide busy flag; actions run independently.
  if (!refreshing) {
    const button = document.querySelector("#refresh");
    button.setAttribute("aria-busy", "true");
    // The first status says whether this build offloads apps; after that both load together.
    const recommend = () => (appsSupported() ? loadRecommendations(false) : null);
    if (usageStale()) startUsageScan();
    refreshing = Promise.all(lastStatus ? [load(), recommend()] : [load().then(recommend)]).finally(() => {
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

// ---- cloud drives -----------------------------------------------------------

let cloudState = null;
let cloudPoll = null;

function cloudButton(key, args, onClick, className) {
  const button = el("button", `btn ${className || "outline"}`, t(key, ...(args || [])));
  button.type = "button";
  button.addEventListener("click", onClick);
  return button;
}

function renderCloud(info) {
  cloudState = info;
  const summary = document.querySelector("#cloud-summary");
  const repo = document.querySelector("#cloud-repo");
  const task = document.querySelector("#cloud-task");
  const list = document.querySelector("#cloud-remotes");
  const connect = document.querySelector("#cloud-connect");
  const openlist = document.querySelector("#cloud-openlist");
  if (!info) { [summary, repo, list, connect, openlist].forEach((n) => n.replaceChildren()); task.hidden = true; return; }
  const remotes = info.remotes || [];
  const active = info.activeBackendId || "";
  const mirrors = info.mirrors || [];
  const mirrorIds = new Set(mirrors.map((m) => m.id));
  summary.textContent = t("cloudSummary", remotes.length);
  repo.replaceChildren(document.createTextNode(active ? t("cloudRepoBackend", active) : t("cloudRepoDefault", info.defaultKind)));
  if (active) {
    repo.append(" ", cloudButton("cloudBackDefault", [info.defaultKind], () => useRepo({ id: "default" }, t("cloudDefaultName", info.defaultKind)), "quiet"));
  }
  const running = info.task && info.task.state === "running";
  if (mirrors.length) {
    const line = el("p", "muted");
    const last = mirrors.map((m) => m.lastSync).filter(Boolean).sort((a, b) => String(b.lastSyncAt).localeCompare(String(a.lastSyncAt)))[0];
    line.append(t("cloudMirrorsLine", mirrors.length), " ",
      last ? t("cloudMirrorLast", new Date(last.lastSyncAt).toLocaleString(), last.ok) : t("cloudMirrorNever"), " ");
    const sync = cloudButton("cloudMirrorSync", [], () => cloudPost("/api/cloud/mirrors/sync"), "quiet");
    sync.disabled = running;
    line.append(sync);
    repo.append(line);
  }
  if (info.task && info.task.state) {
    task.hidden = false;
    task.dataset.state = info.task.state;
    const p = info.task.progress;
    const progress = p && p.filesTotal ? t("cloudProgress", p.filesDone || 0, p.filesTotal, bytes(p.bytesDone || 0), bytes(p.bytesTotal || 0)) : "";
    task.textContent = info.task.state === "running" ? t(`cloudTask${info.task.action}`, info.task.phase, progress)
      : info.task.state === "failed" ? t("cloudTaskFailed", info.task.message || "") : t("cloudTaskDone");
  } else {
    task.hidden = true;
  }
  list.replaceChildren(...(remotes.length ? remotes.map((remote) => {
    const row = el("li", "cloud-row");
    const name = el("span", "grow", `${remote.name}`);
    if (remote.type) name.append(el("span", "muted", `  ${remote.type}`));
    row.append(name);
    const mirrored = remote.backendId && mirrorIds.has(remote.backendId);
    if (mirrored) row.append(el("span", "pill grey", t("cloudMirror")));
    if (remote.active) {
      row.append(el("span", "pill green", t("cloudActive")));
    } else {
      const use = cloudButton("cloudUse", [], () => useRepo(remote.backendId ? { id: remote.backendId } : { remote: remote.name }, remote.name), "tint");
      use.disabled = running;
      row.append(use);
      if (remote.backendId) {
        const mirror = cloudButton(mirrored ? "cloudMirrorRemove" : "cloudMirrorAdd", [], () => cloudPost("/api/cloud/mirrors", { action: mirrored ? "remove" : "add", id: remote.backendId }), "quiet");
        mirror.disabled = running;
        row.append(mirror);
      }
      row.append(cloudButton("cloudDisconnect", [], () => disconnectRemote(remote.name), "quiet"));
    }
    return row;
  }) : [el("li", "muted", t("cloudNoRemotes"))]));
  if (!info.rclone) {
    connect.replaceChildren(el("span", "muted", t("cloudNoRclone")));
  } else {
    connect.replaceChildren(...(info.providers || []).map((p) => {
      const button = cloudButton("cloudConnect", [p.name], () => connectDrive(p.id));
      button.disabled = running;
      return button;
    }));
  }
  const ol = info.openlist || {};
  if (!ol.installed) {
    const button = cloudButton("openlistInstall", [], installOpenList, "outline");
    button.disabled = running;
    openlist.replaceChildren(button);
  } else {
    const nodes = [el("span", "grow", ol.running ? t("openlistRunning", ol.url) : t("openlistStopped"))];
    if (ol.running) {
      const link = el("a", "btn outline", t("openlistOpen"));
      link.href = ol.url;
      link.target = "_blank";
      link.rel = "noopener";
      nodes.push(link);
      nodes.push(cloudButton("openlistPassword", [], showOpenListPassword, "quiet"));
      nodes.push(cloudButton("openlistStop", [], () => openListPower("stop"), "quiet"));
    } else {
      nodes.push(cloudButton("openlistStart", [], () => openListPower("start"), "outline"));
    }
    if (active === ol.backendId) nodes.push(el("span", "pill green", t("cloudActive")));
    else nodes.push(cloudButton("cloudUse", [], () => useRepo({ id: ol.backendId }, "OpenList"), "tint"));
    openlist.replaceChildren(...nodes, el("p", "muted", t("openlistHint")));
  }
  clearTimeout(cloudPoll);
  if (running) cloudPoll = setTimeout(loadCloud, 2000);
}

async function loadCloud() {
  const wasRunning = cloudState && cloudState.task && cloudState.task.state === "running";
  try {
    const info = await api("/api/cloud");
    renderCloud(info);
    if (wasRunning && info.task && info.task.state === "failed") toast({ title: t("cloudTitle"), error: { code: "failed", message: info.task.message || "" }, tone: "error" });
    else if (wasRunning && info.task && info.task.state === "done" && info.task.action === "migrate") {
      toast({ title: info.task.migrated ? t("cloudMigrated", migratingTo || info.task.backendId || "", info.task.copied || 0) : t("cloudSwitched", migratingTo || info.task.backendId || ""), tone: "ok" });
      migratingTo = null;
      refresh();
    } else if (wasRunning && info.task && info.task.state === "done") toast({ title: t("cloudTaskDone"), tone: "ok" });
    if (wasRunning && info.task && info.task.state !== "running") migratingTo = null;
  } catch (error) {
    if (error.code !== "unauthorized") renderCloud(null);
  }
}

async function cloudPost(path, body) {
  try {
    const result = await api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
    if (result.cloud) renderCloud(result.cloud);
    return result;
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: t("cloudTitle"), error: { code: error.code, message: error.message }, tone: "error" });
    return null;
  }
}

function connectDrive(provider) { return cloudPost("/api/cloud/connect", { provider }); }
function installOpenList() { return cloudPost("/api/openlist/install"); }
function openListPower(which) { return cloudPost(`/api/openlist/${which}`); }

async function disconnectRemote(name) {
  if (!confirm(t("cloudDisconnectConfirm", name))) return;
  await cloudPost("/api/cloud/disconnect", { remote: name });
}

async function useRepo(target, label) {
  if (!confirm(t("cloudUseConfirm", label, (cloudState && cloudState.appsHere) || 0))) return;
  // Always move the repo's contents first; the server switches only after every copy checks out,
  // and keeps the old repo as a backup.
  migratingTo = label;
  const result = await cloudPost("/api/cloud/use", Object.assign({}, target, { migrate: true, keepOldAsMirror: true }));
  if (!result) { migratingTo = null; return; }
  clearTimeout(cloudPoll);
  cloudPoll = setTimeout(loadCloud, 1000);
}

let migratingTo = null;

async function showOpenListPassword(event) {
  const button = event.currentTarget;
  try {
    const result = await api("/api/openlist/password");
    const secret = el("span", "cloud-secret", t("openlistPasswordIs", result.password));
    button.replaceWith(secret);
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: t("openlistPassword"), error: { code: error.code, message: error.message }, tone: "error" });
  }
}

// ---- other big items --------------------------------------------------------

let bigData = null;
let bigTimer = null;

function renderBig() {
  const list = document.querySelector("#big-list");
  const summary = document.querySelector("#big-summary");
  const scanned = document.querySelector("#big-scanned");
  if (!list) return;
  list.replaceChildren();
  if (!bigData || bigData.state === "scanning" && !bigData.items) {
    summary.textContent = t("bigScanning");
    scanned.textContent = "";
    return;
  }
  const items = bigData.items || [];
  summary.textContent = items.length ? t("bigSummary", items.length, bytes(bigData.bytes || 0)) : t("bigNone");
  scanned.textContent = bigData.state === "scanning" ? t("bigScanning") : "";
  const cleanup = bigData.cleanup || {};
  for (const item of items) {
    const buttons = [];
    if (item.action === "dev-offload") {
      buttons.push(actionButton({ labelKey: "bigGoDev", icon: iconTray, className: "outline", onClick: () => document.querySelector("#dev-section").scrollIntoView({ behavior: "smooth" }) }));
    } else if (item.action === "clean") {
      const running = cleanup.state === "running" && cleanup.action === item.target;
      buttons.push(actionButton({ labelKey: running ? "bigCleaning" : (item.reason === "adviceSipOff" ? "bigDelete" : "bigClean"), icon: iconTrash, className: "outline", busy: running, disabled: cleanup.state === "running",
        onClick: () => askConfirm({ title: ["bigConfirmTitle", bigTitle(item)], body: [item.reason === "adviceSipOff" ? "bigConfirmBodySip" : "bigConfirmBody", bytes(item.bytes)], ok: "bigClean", danger: true }, () => runBigCleanup(item)) }));
    } else {
      // The data folder of an app offloaded here can follow that app into the repo.
      const owner = item.kind === "appData" && ((lastStatus && lastStatus.apps) || []).find((app) =>
        (app.name === item.title || app.bundleId === item.title) && isOnThisMac(app) && !fullAppHere(app));
      if (owner && !(owner.data && owner.data.enabled && owner.data.state !== "local")) {
        // Not on yet, or on but the data is still here (it moves after the app quits): enabling again moves it now.
        const waiting = Boolean(owner.data && owner.data.enabled);
        const job = pending.get(owner.name);
        buttons.push(actionButton({ labelKey: waiting ? "dataOffloadNow" : "dataEnable", icon: iconTray, className: "outline", busy: Boolean(job && job.kind === "data/enable"), disabled: Boolean(job),
          onClick: () => confirmAction("data/enable", owner) }));
      }
      if (item.fileActions) {
        const target = { name: item.path, label: bigTitle(item), path: item.path, cachedBytes: item.bytes };
        const job = pending.get(item.path);
        buttons.push(actionButton({ labelKey: "bigUpload", icon: iconTray, className: "outline", busy: Boolean(job && job.kind === "offloadfile"), disabled: Boolean(job),
          onClick: () => confirmAction("offloadfile", target) }));
        buttons.push(actionButton({ labelKey: "bigDelete", icon: iconTrash, className: "danger-outline", busy: Boolean(job && job.kind === "trashpath"), disabled: Boolean(job),
          onClick: () => confirmAction("trashpath", target) }));
      }
      buttons.push(actionButton({ labelKey: "revealInFinder", icon: iconMore, className: "quiet", onClick: () => revealInFinder(item.path) }));
      buttons.push(actionButton({ labelKey: "bigShowUsage", icon: iconMore, className: "quiet", onClick: () => document.querySelector("#usage-section").scrollIntoView({ behavior: "smooth" }) }));
    }
    const detail = el("span");
    const dataOwner = item.kind === "appData" && ((lastStatus && lastStatus.apps) || []).find((app) =>
      (app.name === item.title || app.bundleId === item.title) && isOnThisMac(app) && !fullAppHere(app));
    if (dataOwner && dataOwner.data && dataOwner.data.enabled && dataOwner.data.state === "local") {
      detail.append(t("bigDataWaiting"));
      if (dataOwner.data.lastError) detail.append(el("br"), el("span", "small", dataOwner.data.lastError));
    } else if (dataOwner) {
      detail.append(t("bigReason_appDataOwned", dataOwner.name));
    } else {
      detail.append(t("bigReason_" + item.reason));
    }
    detail.append(el("br"), el("span", "mono small", item.path));
    list.append(devRow(bigTitle(item), detail, bytes(item.bytes), buttons));
  }
}

/// A big item's title in the page language: rows Disklessly names itself carry a string key.
function bigTitle(item) {
  if (!item.titleKey) return item.title;
  const name = t(item.titleKey);
  return item.id.startsWith("advice:sip-") ? name + t("sipSuffix") : name;
}

async function loadBig() {
  clearTimeout(bigTimer);
  try {
    bigData = await api("/api/bigitems");
  } catch (error) {
    if (error.code === "unauthorized") return;
    bigData = { state: "ready", items: [] };
  }
  renderBig();
  const cleaning = bigData.cleanup && bigData.cleanup.state === "running";
  if (bigData.state === "scanning" || cleaning) bigTimer = setTimeout(loadBig, 2000);
}

async function runBigCleanup(item) {
  try {
    await api("/api/usage/clean", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: item.target }) });
  } catch (error) {
    if (error.code !== "unauthorized") toast({ title: bi("cleanFailed", bigTitle(item)), error: { code: error.code, message: error.message }, tone: "error" });
  }
  loadBig();
}

async function rescanBig() {
  try { await api("/api/bigitems/scan", { method: "POST" }); } catch (error) { if (error.code === "unauthorized") return; }
  bigData = Object.assign({}, bigData, { state: "scanning" });
  renderBig();
  bigTimer = setTimeout(loadBig, 2000);
}

// ---- container images -------------------------------------------------------

let ctrData = null;
let ctrTimer = null;
const ctrBusy = new Map(); // key or record id -> job kind

const engineTitle = (id) => ({ apple: "Apple container", "docker-desktop": "Docker Desktop", orbstack: "OrbStack", colima: "Colima", dory: "Dory" }[id] || id);
const daysSince = (iso) => (iso ? Math.floor((Date.now() - Date.parse(iso)) / 86400000) : null);

function ctrUseText(image) {
  const names = (image.containers || []).join(", ");
  if (image.use === "running" || image.use === "stopped") return t("ctrUse_" + image.use, names);
  if (image.use === "recent") return t("ctrUse_recent", ctrData.recentDays || 30);
  return t("ctrUse_" + image.use);
}

const ctrConfirms = {
  "containers/offload": (item) => ({ title: ["ctrConfirmOffloadTitle", item.title], body: ["ctrConfirmOffloadBody", bytes(item.bytes), engineTitle(item.engine), item.use === "recent"], ok: "ctrOffload", danger: false }),
  "containers/clean": (item) => ({ title: ["ctrConfirmCleanTitle", item.title], body: ["ctrConfirmCleanBody", bytes(item.bytes)], ok: "ctrClean", danger: true }),
  "containers/forget": (item) => ({ title: ["ctrConfirmForgetTitle", item.title], body: ["ctrConfirmForgetBody", bytes(item.bytes)], ok: "ctrForget", danger: true }),
};

function ctrAction(kind, id, item) {
  const confirm = ctrConfirms[kind];
  if (confirm) askConfirm(confirm(item), () => ctrJob(kind, id, item.title));
  else ctrJob(kind, id, item.title);
}

async function ctrJob(kind, id, label) {
  if (ctrBusy.has(id)) return;
  ctrBusy.set(id, kind);
  renderContainers();
  let failure = null;
  try {
    const started = await api(`/api/${kind}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ app: id }) });
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, JOB_POLL_MS));
      const job = await api(`/api/jobs/${encodeURIComponent(started.jobId)}`);
      if (job.state === "running") continue;
      if (job.state !== "done") failure = job.error || { code: "failed", message: "" };
      break;
    }
  } catch (error) {
    if (error.code === "unauthorized") return;
    failure = { code: error.code, message: error.message };
  }
  ctrBusy.delete(id);
  if (failure) toast({ title: biPair(t("ctrJobFailed", label), null), error: failure, tone: "error" });
  else toast({ title: biPair(t("ctrJobDone", label, null), null), tone: "ok" });
  rescanContainers();
}

function renderContainers() {
  const list = document.querySelector("#ctr-list");
  const summary = document.querySelector("#ctr-summary");
  if (!list) return;
  list.replaceChildren();
  if (!ctrData || (ctrData.state === "scanning" && !ctrData.engines)) {
    summary.textContent = t("ctrScanning");
    return;
  }
  const engines = ctrData.engines || [];
  const images = ctrData.images || [];
  const offloaded = ctrData.offloaded || [];
  if (!engines.length && !offloaded.length) {
    summary.textContent = t("ctrNone");
    return;
  }
  summary.textContent = t("ctrSummary", images.length, bytes(ctrData.bytes || 0), bytes(ctrData.reclaimableBytes || 0)) + (ctrData.state === "scanning" ? " " + t("ctrScanning") : "");
  const button = (labelKey, icon, kind, id, item, className, blocked) =>
    actionButton({ labelKey, icon, className: className || "outline", busy: ctrBusy.get(id) === kind, disabled: ctrBusy.has(id) || !!blocked, blocked: blocked || undefined, onClick: () => ctrAction(kind, id, item) });
  for (const engine of engines) {
    const rows = [];
    const engineNote = el("span");
    engineNote.append(t("ctrEngine_" + engine.status));
    if (engine.note && engine.status !== "running") engineNote.append(" · ", el("span", "muted small", engine.note));
    if (engine.vmDisk) engineNote.append(el("br"), el("span", "muted small", t("ctrVMNote")));
    for (const image of images.filter((i) => i.engine === engine.engine)) {
      const detail = el("span");
      const use = el("span", image.inUse ? "warn-text" : null, ctrUseText(image));
      detail.append(use);
      const days = daysSince(image.lastUsed);
      if (days !== null) detail.append(" · ", t("ctrLastUsed", days));
      detail.append(el("br"), el("span", "mono small", image.shortId));
      const blocked = image.inUse ? ctrUseText(image) : null;
      const buttons = [
        button("ctrOffload", iconTray, "containers/offload", image.key, image, "outline", blocked),
        button("ctrClean", iconTrash, "containers/clean", image.key, image, "danger-outline", blocked),
      ];
      rows.push(devRow(image.title, detail, bytes(image.bytes), buttons));
    }
    const volumes = (ctrData.volumes || []).filter((v) => v.engine === engine.engine);
    for (const volume of volumes) {
      const detail = el("span");
      detail.append(t("ctrVolumes"));
      if (volume.inUse) detail.append(" · ", t("ctrVolumeInUse"));
      detail.append(" · ", el("span", "muted small", t("ctrVolumeNote")));
      rows.push(devRow(volume.name, detail, volume.bytes != null ? bytes(volume.bytes) : "", []));
    }
    const box = el("div", "dev-group");
    const head = el("h3", "dev-group-title");
    head.append(t("ctrEngine", engine.title, bytes(engine.dataBytes || 0)));
    box.append(head, el("p", "muted small", ""));
    box.lastChild.append(engineNote);
    if (rows.length) box.append(...rows);
    list.append(box);
  }
  if (offloaded.length) {
    const rows = offloaded.map((o) => {
      const detail = el("span");
      detail.append(engineTitle(o.engine), " · ", t("devFrom", o.host));
      if (o.present) detail.append(" · ", t("ctrInstalledHere"));
      const buttons = [];
      if (!o.present) buttons.push(button("ctrRestore", iconDownload, "containers/restore", o.id, o));
      buttons.push(button("ctrForget", iconTrash, "containers/forget", o.id, o, "danger-outline"));
      return devRow(o.title, detail, bytes(o.bytes), buttons);
    });
    list.append(devGroup("ctrOffloaded", rows));
  }
}

async function loadContainers() {
  clearTimeout(ctrTimer);
  try {
    ctrData = await api("/api/containers");
  } catch (error) {
    if (error.code === "unauthorized") return;
    ctrData = { state: "ready", engines: [], images: [] };
  }
  renderContainers();
  if (ctrData.state === "scanning") ctrTimer = setTimeout(loadContainers, 2000);
}

async function rescanContainers() {
  try { await api("/api/containers/scan", { method: "POST" }); } catch (error) { if (error.code === "unauthorized") return; }
  ctrData = Object.assign({}, ctrData, { state: "scanning" });
  renderContainers();
  ctrTimer = setTimeout(loadContainers, 1500);
}

// ---- remote ssh machines ----------------------------------------------------

let machinesData = null;
let machinesTimer = null;
let selectedMachineHost = null;
let selectedMachineDetail = null;
const machineBusy = new Set();

function machineLevelPillKind(level) {
  if (level === "offline" || level === "critical") return "red";
  if (level === "warning") return "amber";
  return "green";
}

function renderMachines() {
  const cardsNode = document.querySelector("#machines-cards");
  const summaryNode = document.querySelector("#machines-summary");
  const detailNode = document.querySelector("#machines-detail");
  if (!cardsNode || !summaryNode) return;
  cardsNode.replaceChildren();
  if (!machinesData) {
    summaryNode.textContent = t("loading");
    return;
  }
  const list = machinesData.machines || [];
  const remoteCount = list.filter((m) => !m.isLocal).length;
  summaryNode.textContent = t("machinesSummary", list.length, remoteCount) + (machinesData.scanning ? " · " + t("machinesScanning") : "");

  for (const m of list) {
    const detail = el("span");
    detail.append(
      pill(m.isLocal ? "blue" : "grey", m.isLocal ? "machinesLocalBadge" : "machinesRemoteBadge"),
      " ",
      pill(machineLevelPillKind(m.level), "machinesLevel_" + (m.level || "ok"))
    );
    if (m.platform) detail.append(" · ", el("span", "mono small", m.platform));
    if (m.scanMode && !m.isLocal) detail.append(" · ", el("span", "muted small", m.scanMode));
    detail.append(el("br"));
    if (m.totalBytes > 0) {
      const reclaim = (m.reclaimableBytes || 0) + (m.offloadableBytes || 0);
      detail.append(t("machinesDiskLine", bytes(m.usedBytes || 0), bytes(m.totalBytes || 0), bytes(reclaim)));
    } else if (!m.isLocal) {
      detail.append(el("span", "muted small", m.lastError || t("machinesNotScanned")));
    }

    const buttons = [];
    if (!m.isLocal) {
      const scanning = Boolean(m.scanning) || machineBusy.has("scan:" + m.host);
      buttons.push(actionButton({
        labelKey: scanning ? "machinesScanning" : "machinesScan",
        icon: iconRefresh,
        className: "outline",
        busy: scanning,
        disabled: scanning,
        onClick: () => triggerMachineScan(m.host),
      }));
      buttons.push(actionButton({
        labelKey: "machinesInspect",
        icon: iconMore,
        className: selectedMachineHost === m.host ? "primary" : "outline",
        onClick: () => selectMachineDetail(m.host),
      }));
      buttons.push(actionButton({
        labelKey: "machinesRemove",
        icon: iconTrash,
        className: "quiet",
        onClick: () => removeMachineHost(m.host),
      }));
    }
    const sizeLabel = m.totalBytes > 0 ? bytes(m.usedBytes || 0) : "";
    const row = devRow(m.displayName || m.host, detail, sizeLabel, buttons);
    row.dataset.level = m.level || "ok";
    row.dataset.host = m.host;
    cardsNode.append(row);
  }

  renderMachineDetail(detailNode);
}

function renderMachineDetail(detailNode) {
  if (!detailNode) return;
  detailNode.replaceChildren();
  if (!selectedMachineHost || !selectedMachineDetail) {
    detailNode.hidden = true;
    return;
  }
  detailNode.hidden = false;
  const host = selectedMachineHost;
  const d = selectedMachineDetail;
  const head = el("h3", "dev-group-title", t("machinesDetailTitle", host, d.scanMode || "fallback-sh"));
  detailNode.append(head);

  if (d.lastError) {
    detailNode.append(el("p", "warn-text small", d.lastError));
  }

  const mounts = d.mounts || [];
  if (mounts.length) {
    const mGroup = el("div", "dev-group");
    mGroup.append(el("h4", "dev-group-title", t("machinesMountsTitle")));
    for (const m of mounts) {
      const sub = el("span", "mono small", t("machinesMountFree", m.device, m.fsType, bytes(m.availableBytes || 0)));
      mGroup.append(devRow(m.mountPoint, sub, `${bytes(m.usedBytes || 0)} / ${bytes(m.totalBytes || 0)}`, []));
    }
    detailNode.append(mGroup);
  }

  const items = d.items || [];
  const iGroup = el("div", "dev-group");
  iGroup.append(el("h4", "dev-group-title", t("machinesItemsTitle")));
  if (!items.length) {
    iGroup.append(el("p", "muted small", t("machinesNoItems")));
  } else {
    for (const item of items) {
      const sub = el("span");
      sub.append(item.reason || item.category || "");
      sub.append(el("br"), el("span", "mono small", item.path));
      const busyKey = `${host}:${item.id}`;
      const busy = machineBusy.has(busyKey);
      const isOffload = item.action === "offload";
      const btn = actionButton({
        labelKey: isOffload ? "machinesOffloadBtn" : "machinesCleanBtn",
        icon: isOffload ? iconTray : iconTrash,
        className: isOffload ? "outline" : "danger-outline",
        busy,
        disabled: busy,
        onClick: () => planAndConfirmRemoteItem(host, item),
      });
      iGroup.append(devRow(item.title, sub, bytes(item.bytes || 0), [btn]));
    }
  }
  detailNode.append(iGroup);

  const offloaded = d.offloaded || [];
  if (offloaded.length) {
    const oGroup = el("div", "dev-group");
    oGroup.append(el("h4", "dev-group-title", t("machinesOffloadedTitle")));
    for (const rec of offloaded) {
      const sub = el("span");
      sub.append(el("span", "mono small", rec.originalPath));
      const busyKey = `${host}:restore:${rec.id}`;
      const busy = machineBusy.has(busyKey);
      const btn = actionButton({
        labelKey: "machinesRestoreBtn",
        icon: iconDownload,
        className: "outline",
        busy,
        disabled: busy,
        onClick: () => confirmRestoreRemoteItem(host, rec),
      });
      oGroup.append(devRow(rec.title, sub, bytes(rec.logicalBytes || rec.storedBytes || 0), [btn]));
    }
    detailNode.append(oGroup);
  }
}

async function loadMachines() {
  clearTimeout(machinesTimer);
  try {
    machinesData = await api("/api/machines");
  } catch (error) {
    if (error.code === "unauthorized") return;
    machinesData = { machines: [], scanning: false };
  }
  if (!selectedMachineHost && machinesData.machines) {
    const firstRemote = machinesData.machines.find((m) => !m.isLocal);
    if (firstRemote && firstRemote.totalBytes > 0) {
      selectedMachineHost = firstRemote.host;
    }
  }
  if (selectedMachineHost) {
    try {
      selectedMachineDetail = await api(`/api/machines/detail?host=${encodeURIComponent(selectedMachineHost)}`);
    } catch (e) {
      selectedMachineDetail = null;
    }
  }
  renderMachines();
  if (machinesData && machinesData.scanning) {
    machinesTimer = setTimeout(loadMachines, 1500);
  }
}

async function selectMachineDetail(host) {
  selectedMachineHost = host;
  try {
    selectedMachineDetail = await api(`/api/machines/detail?host=${encodeURIComponent(host)}`);
  } catch (error) {
    if (error.code === "unauthorized") return;
    selectedMachineDetail = null;
  }
  renderMachines();
}

async function triggerMachineScan(host) {
  const key = "scan:" + host;
  if (machineBusy.has(key)) return;
  machineBusy.add(key);
  selectedMachineHost = host;
  renderMachines();
  try {
    await api("/api/machines/scan", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ host, sync: true }),
    });
  } catch (error) {
    if (error.code !== "unauthorized") {
      toast({ title: biPair(t("machinesActionFailed", host, t("machinesScan")), null), error: { code: error.code, message: error.message }, tone: "error" });
    }
  } finally {
    machineBusy.delete(key);
  }
  await loadMachines();
}

async function addMachineFromInput() {
  const input = document.querySelector("#machines-host-input");
  if (!input) return;
  const host = input.value.trim();
  if (!host) return;
  try {
    machinesData = await api("/api/machines/add", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ host }),
    });
    input.value = "";
    selectedMachineHost = host;
    await triggerMachineScan(host);
  } catch (error) {
    if (error.code !== "unauthorized") {
      toast({ title: biPair(t("machinesActionFailed", host, t("machinesAdd")), null), error: { code: error.code, message: error.message }, tone: "error" });
    }
  }
}

async function removeMachineHost(host) {
  try {
    machinesData = await api("/api/machines/remove", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ host }),
    });
    if (selectedMachineHost === host) {
      selectedMachineHost = null;
      selectedMachineDetail = null;
    }
    renderMachines();
  } catch (error) {
    if (error.code !== "unauthorized") {
      toast({ title: biPair(t("machinesActionFailed", host, t("machinesRemove")), null), error: { code: error.code, message: error.message }, tone: "error" });
    }
  }
}

async function planAndConfirmRemoteItem(host, item) {
  let planItem = item;
  try {
    const plan = await api("/api/machines/plan", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ host, action: item.action, target: item.id }),
    });
    if (plan.items && plan.items.length) planItem = plan.items[0];
  } catch (error) {
    if (error.code !== "unauthorized") {
      toast({ title: biPair(t("machinesActionFailed", host, item.title), null), error: { code: error.code, message: error.message }, tone: "error" });
    }
    return;
  }
  const isOffload = item.action === "offload";
  const actLabel = t(isOffload ? "machinesOffloadBtn" : "machinesCleanBtn");
  askConfirm(
    {
      title: ["machinesPlanConfirmTitle", actLabel, planItem.title || item.title, host],
      body: ["machinesPlanConfirmBody", planItem.path || item.path, bytes(planItem.bytes || item.bytes || 0), Boolean(planItem.recoverable)],
      ok: isOffload ? "machinesOffloadBtn" : "machinesCleanBtn",
      danger: !isOffload,
    },
    () => executeRemoteItemAction(host, item)
  );
}

async function executeRemoteItemAction(host, item) {
  const busyKey = `${host}:${item.id}`;
  if (machineBusy.has(busyKey)) return;
  machineBusy.add(busyKey);
  renderMachines();
  const endpoint = item.action === "offload" ? "/api/machines/offload" : "/api/machines/clean";
  try {
    await api(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ host, target: item.id }),
    });
    toast({ title: biPair(t("machinesActionDone", host, item.title), null), tone: "ok" });
  } catch (error) {
    if (error.code !== "unauthorized") {
      toast({ title: biPair(t("machinesActionFailed", host, item.title), null), error: { code: error.code, message: error.message }, tone: "error" });
    }
  } finally {
    machineBusy.delete(busyKey);
  }
  await loadMachines();
}

function confirmRestoreRemoteItem(host, rec) {
  askConfirm(
    {
      title: ["machinesRestoreConfirmTitle", rec.title, host],
      body: ["machinesRestoreConfirmBody", rec.originalPath, bytes(rec.logicalBytes || rec.storedBytes || 0)],
      ok: "machinesRestoreBtn",
      danger: false,
    },
    () => executeRestoreRemoteItem(host, rec)
  );
}

async function executeRestoreRemoteItem(host, rec) {
  const busyKey = `${host}:restore:${rec.id}`;
  if (machineBusy.has(busyKey)) return;
  machineBusy.add(busyKey);
  renderMachines();
  try {
    await api("/api/machines/restore", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ host, id: rec.id }),
    });
    toast({ title: biPair(t("machinesActionDone", host, rec.title), null), tone: "ok" });
  } catch (error) {
    if (error.code !== "unauthorized") {
      toast({ title: biPair(t("machinesActionFailed", host, rec.title), null), error: { code: error.code, message: error.message }, tone: "error" });
    }
  } finally {
    machineBusy.delete(busyKey);
  }
  await loadMachines();
}

// ---- wiring ---------------------------------------------------------------

document.querySelector("#refresh").addEventListener("click", refresh);
document.querySelector("#retry").addEventListener("click", retryNow);
document.querySelector("#rescan").addEventListener("click", () => loadRecommendations(true));
document.querySelector("#usage-scan").addEventListener("click", startUsageScan);
document.querySelector("#perm-fda").addEventListener("click", () => openPermission("fullDisk"));
document.querySelector("#perm-app").addEventListener("click", () => openPermission("appManagement"));
document.querySelector("#perm-app-ok").addEventListener("click", () => {
  localStorage.setItem("disklessly.appManagementConfirmed", "1");
  appManagementConfirmed = true;
  loadPermissions();
});
document.querySelector("#files-scan").addEventListener("click", startFilesScan);
document.querySelector("#big-scan").addEventListener("click", rescanBig);
document.querySelector("#ctr-scan").addEventListener("click", rescanContainers);
document.querySelector("#machines-refresh")?.addEventListener("click", loadMachines);
document.querySelector("#machines-add-btn")?.addEventListener("click", addMachineFromInput);
document.querySelector("#machines-host-input")?.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    addMachineFromInput();
  }
});
document.querySelector("#usage-caches-clear").addEventListener("click", clearCaches);
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
loadCloud();
