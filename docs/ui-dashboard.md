# Dashboard UI target (mockup "256isenough 仪表盘 Dashboard")

Source: the user's claude.ai design canvas (4 artboards: Light 1194, Dark 1194, Light 375, Dark 375; same
content). Screenshots: [`ui/mockup-light-top.png`](ui/mockup-light-top.png),
[`ui/mockup-light-states.png`](ui/mockup-light-states.png). Mockup numbers are sample data; the page must
show real values from the engine.

## Global

- Bilingual inline labels: Chinese primary, English secondary in a smaller grey run
  (`后端 Backend`, `清除缓存 Evict`). Light and dark themes follow `prefers-color-scheme`.
- Header: blue rounded "256" tile, title `256isenough`, subtitle `卸载应用，按需缓存 · Diskless apps`;
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
