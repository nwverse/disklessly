# Usage map: local disk and cloud, side by side

Status: implemented. Extends the disk usage map of the dashboard (`docs/ui-dashboard.md`, `UsageMap.swift`,
`Sources/disklessly/web/app.js`). docs/design.md stays the spec for the engine; this only adds a read model and UI.

## Why

The map answers "what fills my 256G". It cannot yet answer the question Disklessly exists for: "what did I already get
back, and what could go next". Offloaded things are invisible on it (a stub weighs a few kilobytes), so the product's
whole effect is off the picture. This puts the cloud footprint on the same picture, at the same scale.

## The picture

```
┌──────────────── This Mac · 245 GB ────────────────┬─┬──── In the cloud · 96 GB ────┐
│ Apps        │ Personal files      │ Library │ Fr │ │ Apps        │ Files & folders │
│  ┌───┐┌──┐  │  ┌───────┐ ┌────┐   │         │ ee │≈│  ┌────┐     │  ┌─────┐        │
│  │☁ 2││  │  │  │       │ │☁ 1 │   │         │    │ │  │    │     │  │     │        │
│  └───┘└──┘  │  └───────┘ └────┘   │         │    │ │  └────┘     │ Sessions │ Data │
└─────────────┴─────────────────────┴─────────┴────┴─┴─────────────┴─────────────────┘
  Free after: 61 GB (+38 GB)   [ Offload 3… ]  [ Move to Trash… ]  [ Clear ]   Free up ──o── 40 GB
```

- **Left: this Mac**, unchanged in content (the tree `/api/usage` returns, free space as a strip along the edge).
- **Right: in the cloud**, everything the repo holds for this device, as a second nested squarified treemap.
- **One scale.** Pixels per byte are equal on both sides: with the height fixed, the cloud side's width is
  `cloud / (disk + cloud)` of the chart. A cloud side below 120 px keeps 120 px and becomes shorter so its area stays
  true. Above 45 % of the width it is compressed and a chip says the ratio ("1 : 3"). Bytes on the cloud side are the
  size the item had on disk (what a restore would take), not the stored size; the stored size is in the detail line.
  The scale is taken at the roots (whole disk, whole cloud plus the "what if" twins), so zooming one side does not
  reflow the other.
- **The channel** between the sides (24 px) carries ribbons. Narrow windows (below 560 px) stack the sides, cloud
  below, and the same rule applies to heights.
- Without a reachable repo the cloud side shows the last known catalog, dimmed, with the backend's state.
- An empty cloud side keeps its 120 px with a short "nothing offloaded yet" note; a server without
  `/api/usage/cloud` (older build) shows the local map alone.

### Cloud groups

| Group (`key`) | Source | Box per | `bytes` | `originPath` |
| --- | --- | --- | --- | --- |
| Group (`key`) | Source | Box per | `bytes` | `originPath` |
| --- | --- | --- | --- | --- |
| `apps` | packed app manifests from the last successful `/api/status` listing, kept in memory by the UI context | app; linked bundles and its data offload are children of the app | the image's plain size (`image.plainSize`; no bundle size is recorded at pack time) | `installPath` |
| `files` | `OffloadedFileRegistry.live` rows; stored size and modification date read from the placeholder (first 2,000) | placeholder | `size` | the placeholder's path without `.disklessly` |
| `linked` | offloaded paths of `linkedBundleStore` entries (under their app when it is packed, else here) | bundle, then path | sum of its offloaded paths | its path when it has one |
| `data` | `AppDataRecord`s in state `offloaded` (under their app when packed, else here) | app | `bytes` | `~/Library/Application Support/<root>` when it has one root |
| `sessions` | `SessionArchive.archivedEntries`, grouped by tool | tool, then session | `size` | `path` |

An app is on the cloud side when this Mac has its stub, or its device record lists the image and the full app is
not installed again. Apps packed only on another Mac are left out (they never took space here); `otherDevice` names
the other Macs that also hold an image this Mac offloaded ("Also on Studio Mini").

Each node also carries `id`, `storedBytes`, `offloadedAt`, `lastUsed`, `stubPath` (the stub app or placeholder on
this Mac), `localBytes` (what of it is in the cache now: a prefetched image is in both places), `restore` and
`restoreId`. `restore` names how it comes back, through routes that already exist:

| `restore` | Page action (after its confirmation) |
| --- | --- |
| `unpack` | `confirmAction("unpack", app)` → `POST /api/unpack` |
| `data/disable` | `confirmAction("data/disable", app)` → `POST /api/data/disable` |
| `links/restore` | `POST /api/links/restore` with `restoreId` |
| `sessions/restore` | `POST /api/sessions/restore` with `restoreId` |
| `fetch` | no page job exists for a file: the dialog explains it and shows the placeholder in Finder (double-click brings it back) |

Times (`modified`, `offloadedAt`, `lastUsed`) are Unix seconds.

## Interactions

Chosen from the brief; each has a keyboard and VoiceOver path, and none bypasses a confirmation.

1. **Linked stubs.** A local box whose subtree holds offloaded items shows a cloud badge with their count (the app
   tile of a stub already has `offloaded`; folders get it from `originPath` prefixes). Hover or focus a badge or a
   cloud box and its partner lights up, joined by one ribbon across the channel. Activating a badge zooms the cloud
   side to those items. Ribbons are drawn for the hovered, focused and selected pairs only (an SVG overlay; no
   ribbon is ever the only way to learn the link: the detail line says "Offloaded from ~/Movies/Raw"). A ribbon
   leaves the local map at its edge, level with the outlined box, so it never covers other local boxes. The menu's
   "Show in the cloud" is the keyboard path to the badge.
2. **Selection and "what if".** Space, ⌘-click or the menu's Select toggles a box. With a selection the map previews
   the outcome: selected local boxes become hatched ghosts, the free strip grows by their sum, dashed twins appear on
   the cloud side, and the tray reads "Free after: 61 GB (+38 GB)". The tray lists the selection as rows (name, size,
   remove) and holds **Offload N…**, **Move to Trash…**, **Clear**. Nothing changes until the existing confirmation
   (one item: the same dialog as the menu; several: one dialog, then one job each). Only local boxes are selectable;
   a selected folder covers what is inside it, so nested selections count once.
3. **Drag.** A local box dropped on the cloud side asks to offload it (`pack` for an app, `offloadfile` otherwise); a
   cloud box dropped on the local side asks to restore it. A drop opens the same `confirmAction` dialog the context
   menu opens. Refused items (`refusal`, `canTrash`) show the not-allowed cursor and the reason in the detail line.
   The keyboard path is the menu: Select plus the tray's Offload / Move to Trash, and Bring back on a cloud box's menu.
4. **Free-up goal.** A slider in the tray ("Free up 40 GB", in GiB up to what is selectable) selects automatically:
   clearable caches first, then by `bytes × age` among items the rules allow, until the goal is met. Bytes count only
   up to what is still missing (so a huge warm folder does not beat a cold one that covers the rest), and non-cache
   picks the goal no longer needs are dropped again. Candidates are the highest box on each branch the rules allow.
   It only selects.
5. **Last-used tint.** A two-way control: **Kind** (today's colors) or **Last used** (four steps: under 30 days,
   under 180 days, under a year, older; coldest strongest). Age comes from the newest modification time in the
   subtree, and `lastUsed` for apps. It is in the detail line and the label too, never color alone.

Not taken: permanent ribbons for every pair (noise), auto-offload from the slider (must stay a choice).

Kept as today: zoom on click, breadcrumbs, Escape to go up, the detail line, the context menu, in-place refresh after
a change (`refreshUsageAfterMutation`), the free strip. The cloud side has its own focus trail and breadcrumb; Tab
moves between the local map, the cloud map and the tray; arrow keys move to the nearest box in that direction.

After an offload or restore finishes, the affected folder is rescanned in place and `/api/usage/cloud` is reloaded, so
a box visibly crosses the channel.

## Engine and API

- `UsageNode` gains optional `modified` (newest mtime under it, collected by the directory scan; no extra walk) and
  `offloadedCount`. Folders are sized by `du`, so a folder's `modified` is its own mtime (it changes when entries are
  added or removed directly inside it), not the newest file deep inside; files carry their own mtime and groups the
  newest of their children. App bundles carry the bundle's mtime (install or update), not a launch date.
- `CloudUsage.assemble(_ input: CloudUsageInputs) -> UsageNode` (new, in DisklesslyEngine): a pure function from the
  catalog rows above to a tree with `kind: offloaded` nodes, largest first, `maxListed` per group with the rest merged
  into "other", exactly as `UsageMap.assemble` does. Tests build the inputs by hand.
- `GET /api/usage/cloud` → `{ok, generatedAt, reachable, health, totalBytes, storedBytes, tree, appsListedAt?}`. It
  reads the local catalog and state only (no backend round trip), so it answers in milliseconds; `reachable` and
  `health` are the last health result (`BackendHealthProbe.last`, never a new probe; unknown counts as reachable).
  The app catalog is replaced only by a listing that worked, so an offline repo keeps the last one. It lives in
  memory: a UI started while the repo is offline shows no apps on the cloud side until a listing succeeds.
- `/api/usage` and `/api/usage/dir` nodes include `modified` and `offloadedCount` (`UsageMap.countOffloaded` over the
  catalog's origin paths, at response time). The page recounts from the cloud tree it loaded, so badges follow a
  reload of `/api/usage/cloud` without a rescan.
- No new mutation routes: offload, pack, restore and trash go through the existing job routes and their refusal
  checks (`fileOffloadRefusal`, `trashPathRefusal`).

## Page

- `index.html`: the usage card gets the tint control, a second chart container (`#usage-cloud`) with its own crumbs,
  the ribbon overlay and the tray.
- `app.js`: `drawUsageMap` lays out both sides with `usageScale` and draws each with `drawUsageSide(side, size)`
  (tree, focus trail and container per side) instead of duplicating it; `usageSquarify` is shared. New
  `loadCloudUsage`, `usageScale`, `drawUsageRibbons`, `usageSelected` (keyed by path, so it survives a refresh),
  `renderUsageTray`, `usagePickForGoal`, `usageAgeStep`, `usageWhatIf`, `usageNearest`. The pure math sits between
  `// usage-math:begin` and `// usage-math:end` and is checked by `scripts/ui-screenshots.mjs` without a browser.
  `loadCloudUsage` redraws only when the response changed, so the 20 s refresh keeps hover, focus and selection.
- `style.css`: classes `usage-split`, `usage-channel`, `usage-ribbon`, `usage-box.is-ghost`, `usage-box.is-incoming`,
  `usage-box.is-linked`, `usage-badge`, `usage-tray`, `usage-age-1` … `usage-age-4`; colors through the existing
  custom properties, light and dark; `prefers-reduced-motion` turns the growth animation into a cross-fade.
- Strings in both `zh` and `en` tables of `app.js`: `usageCloudTitle`, `usageCloudEmpty`, `usageCloudOffline`,
  `usageScaleChip`, `usageTintLabel`, `usageTintKind`, `usageTintAge`, `usageAge0` … `usageAge4`, `usageAgeChanged`,
  `usageLinkedCount`, `usageOffloadedFrom`, `usageStored`, `usageAlsoHere`, `usageAlsoOn`, `usageIncoming`,
  `usageSelectedState`, `usageTrayFreeNow`, `usageTrayFreeAfter`, `usageTrayOffload`, `usageTrayTrash`,
  `usageTrayClear`, `usageTrayOffloadConfirm`, `usageTrayOffloadBody`, `usageTrayTrashConfirm`, `usageTrayTrashBody`,
  `usageGoal`, `usageSelect`, `usageDeselect`, `usageShowInCloud`, `usageDropOffload`, `usageDropRestore`,
  `usageRestoreTitle`, `usageRestoreBody`, `usageRestoreOk`, `usageFetchBody`, `usageMenuRestore`, `usageNoRestore`,
  `usageAlreadyOffloaded`, `usage_cloud`, `usage_cloud_apps`, `usage_cloud_files`, `usage_cloud_linked`,
  `usage_cloud_data`, `usage_cloud_sessions`.

## Tests

- `CloudUsageTests`: groups and sums, linked bundles and data under their app, sessions by tool, merging into
  "other", another device's items, an empty catalog.
- `UsageMapTests`: `modified` is the newest mtime (and a scanned folder's own mtime); `offloadedCount` from origin paths.
- `ManagementUIUsageCloudTests`: `/api/usage/cloud` shape, offline health, and that it neither probes nor lists the backend.
- Page: the shared-scale and clamp math, the goal picker and the "what if" sums are pure functions exercised by the
  screenshot script's checks (`scripts/ui-screenshots.mjs`) with a fixture tree; screenshots of the split map in both
  themes and at a narrow width go to `docs/ui/` (`usage-split-*.png`). With playwright, `UI_SHOT_ONLY=usage` runs the
  browser checks of the split map alone: badges, one Tab stop per map, Space selection with ghosts, twins, the
  growing free strip and a ribbon, the tray and drag confirmations that start nothing when cancelled, the goal
  slider, the Last used tint, the badge zoom, the stacked layout without sideways scroll, and the dimmed offline side.
