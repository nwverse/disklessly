# Dashboard UI target (mockup "Disklessly 仪表盘 Dashboard")

Source: the user's claude.ai design canvas (4 artboards: Light 1194, Dark 1194, Light 375, Dark 375; same
content). Screenshots: [`ui/mockup-light-top.png`](ui/mockup-light-top.png),
[`ui/mockup-light-states.png`](ui/mockup-light-states.png). Mockup numbers are sample data; the page must
show real values from the engine.

## Global

- Bilingual inline labels: Chinese primary, English secondary in a smaller grey run
  (`后端 Backend`, `清除缓存 Evict`). Light and dark themes follow `prefers-color-scheme`.
- Header: blue rounded "256" tile, title `Disklessly`, subtitle `256G 就够了 · 256G is enough`;
  right side `刚刚更新 · Updated just now` (relative time of the last refresh) and a `刷新 Refresh` button.
- Content column max ~1070 px centered; white cards, 12-16 px radius, soft shadow; grey page background.
- 375 px: cards stack in one column; table rows become stacked cards.

## Row 1: two cards

**后端 Backend** (left, narrow): kind pill top-right (`远端 Remote` / `本地 Local`). Big status line with a
coloured dot: `运行正常` + `Healthy · 延迟 42 ms`. Key/value rows `活动端点 Active` (monospace id),
`类型 Kind`. Then `端点 Endpoints · N` list: each endpoint id in monospace with a right-side state
(`待机 standby`, green pill `● 活动 Active`, `本地 local`).

**缓存 Cache** (right, wide): status pill top-right (`空间充足 · Plenty of room` / near / critical).
Hero number `12.4 GiB / 64 GiB 配额 quota · 已用 19%`. Usage meter 0 → quota with ticks `0`, `half`,
`quota`, coloured zones ≥80% (amber) and ≥95% (red), a labelled marker `空闲下限 Free floor · 保留 8 GiB`.
Legend `正常 Normal · ≥ 80% 接近 Near · ≥ 95% 临界 Critical`. Footer stats: `剩余 Free`,
`空闲下限 Floor`, `分离延迟 Detach delay`.
Note: the marker must mean something on this axis. If the floor is a disk-free-space floor (not a cache
quantity), place the marker where cache usage would push free disk space below the floor
(`quota_marker = used + free - floor`, clamped), or drop the marker and keep the floor as a footer stat.
Never draw a disk quantity as if it were a cache quantity.

## 已卸载应用 Offloaded apps

Section heading + right summary `N 个应用 · M 个已缓存 X GiB · K 个已固定`. Table columns
`应用 App | 状态 Status | 缓存 Cache | 操作 Actions`:
- App: coloured letter avatar (or real icon when available), name, `vX · 按需 on-demand` / `完整 full`.
- Status pills: `已缓存 Cached` (green), `已固定 Pinned` (amber, pin glyph), `远端 Remote` (blue/grey).
- Cache: size with a thin bar, or `未缓存 Not cached`.
- Actions: `固定 Pin` / `取消固定 Unpin` (blue tinted) and `清除缓存 Evict` (red outline, trash glyph).
- Footer info line: `清除缓存只删除本地副本，应用仍保留在后端，下次打开时自动拉取。固定的应用不会被自动清除。`
  + `Evict only drops the local copy; pinned apps are never auto-evicted.`

## 会话分层 Session tiers

Summary `14 天未用转冷 Cold after 14 days · 已卸载 N 个 offloaded`. Rows: tier pill (`冷 Cold` grey;
only cold files are archived, so there is no warm tier), app, document path (monospace), relative age (`21 天前`).

## States (must exist in the real page)

- 加载中 Loading: skeleton rows + `正在读取后端… Loading`.
- 空状态 Empty: tray icon, `暂无已卸载应用 / No offloaded apps. / 卸载的应用会显示在这里。`
- 错误 Error: red panel `无法连接后端 Backend unreachable`, endpoint + reason (`超时 5 s`), `重试 Retry`.
- 配额告警 Near quota: amber bar at ≥80% (`86% 接近`), red at ≥95% (`97% 临界`), note
  `低于空闲下限时自动清除未固定的缓存`.
- 后端健康 Health: `正常 Healthy` green with latency, `缓慢 Degraded` amber (e.g. 680 ms), `离线 Offline` red `—`.

## Actual (release/v0.1 QA)

Real `disklessly ui` on isolated `DISKLESSLY_*` dirs (three packed fixture apps: one pinned and cached, one cached,
one remote-only; three archived sessions; `DISKLESSLY_SCAN_ROOTS` pointing at a fixture folder):
[`ui/actual-light-1194.png`](ui/actual-light-1194.png), [`ui/actual-dark-1194.png`](ui/actual-dark-1194.png),
[`ui/actual-light-375.png`](ui/actual-light-375.png), [`ui/actual-dark-375.png`](ui/actual-dark-375.png).
The Error state was checked against an unreachable WebDAV endpoint, and Empty against an empty repo.

## Usage map: this Mac and the cloud

Spec: [`usage-map-cloud.md`](usage-map-cloud.md). The 磁盘占用 Disk usage card draws two nested treemaps at one
scale: this Mac (`/api/usage`) and what the repo holds for it (`/api/usage/cloud`), joined by a 24 px channel with
ribbons for the hovered, focused or selected pair. A tray under the map shows free space after the selection, its
rows, Offload N / Move to Trash / Clear and the Free up goal slider; a Kind | Last used control switches the tint.
Below 560 px the sides stack. Screenshots (fixture data from `scripts/ui-screenshots.mjs`, `UI_SHOT_ONLY=usage`):
[`ui/usage-split-light-1194.png`](ui/usage-split-light-1194.png), [`ui/usage-split-dark-1194.png`](ui/usage-split-dark-1194.png),
[`ui/usage-split-light-375.png`](ui/usage-split-light-375.png), [`ui/usage-split-age-light-1194.png`](ui/usage-split-age-light-1194.png).

### Hidden usage (Not measured)

System & other → 未能测量 Not measured has children from the same scan (design §4.2): 其他用户 Other users (one box per
account and `/Users/Shared`), Spotlight 索引 Spotlight index (after it is measured), 本地快照和可清除空间 Local snapshots and
purgeable space (only when local snapshots exist), and the remainder, 可能是 Spotlight 索引 / 读不到的文件夹 Likely Spotlight
index / unreadable folders (or 读不到的文件夹和其他系统数据 Unreadable folders and other system data once the index is
measured). Each box's tooltip adds its explanation (`hiddenWhy_*`). These boxes have no path, so the map never offers
Offload or Delete on them.

Below the cleanup list, the 隐藏占用 Hidden usage section (`#usage-reconcile`, `GET /api/reconcile`) lists each child with
its size and explanation and, where safe, one button: 精简快照 Thin snapshots, 测量（需要管理员）Measure (needs admin),
重建 Spotlight 索引 Rebuild Spotlight index (only above max(20 GB, 5% of used)). A note gives purgeable space and snapshot
count and the number of unreadable folders (full list in its tooltip). Then 本机 AI 模型 AI models on this Mac: path, size,
last change, in-use reason, and 卸载到仓库 Offload to repo / 移到废纸篓 Move to Trash (disabled while in use). Every
button has its own `confirm()` text (the rebuild one says search is degraded for hours) and posts
`/api/reconcile/action` with `confirm: true`; none is part of a bulk clean.
