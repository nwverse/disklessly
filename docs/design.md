# 256isenough — Design (v1 draft, 2026-10-20)

> 中文摘要：每个冷门 App 打成只读压缩 DMG（远端 ULMO），放在可插拔后端（MVP = iCloud Drive / 本地目录）；
> `/Applications` 里放一个独立 bundle id、可签名的轻量 Stub。点击 Stub → **pre-launch hook**（拉取到本地缓存、
> sha256 校验、`hdiutil attach -readonly -nobrowse`、带文档/URL 打开真 App）→ App 退出 → **post-quit hook**
> （等所有进程离开挂载点、延迟卸载、更新 LRU、按配额淘汰）。引擎/CLI/Stub 用 Swift，GUI 是 `wupan serve`
> 提供的本地网页，用 Pake 打包。MAS/带特权 helper 的 App 走"临时还原"模式。

This document is the implementation spec. Sources: [research.md](research.md), [research-luna.md](research-luna.md),
[research-cursor.md](research-cursor.md). Where they conflict, research-cursor.md wins (no `brctl`, never attach a
dataless DMG, no `cp -c` zero-copy cache, ULMO remote, stub must forward documents and URLs, Pake = tray window +
HTTP to a daemon, sessions tiering starts with pi JSONL only).

Naming: product **256isenough**; CLI **`wupan`** (无盘); stub launcher **`wupan-stub`**; Swift modules `Wupan*`.
Reverse-DNS prefix `io.github.s546126.256isenough`.

---

## 1. Goals, non-goals, glossary, app classes

### 1.1 Goals (MVP)
- G1. Move a self-contained `.app` out of local disk into a remote **repository**, leaving a **stub** in place that
  looks/behaves like the app in Finder, Spotlight, Launchpad, Dock, "Open With" and URL handling.
- G2. Launching the stub (click, document double-click, URL, `open -a`, Dock) transparently fetches, verifies, mounts
  and runs the real app, forwarding every document and URL; when the app quits, the image is detached after a delay
  and the cache is managed by LRU + quota + pins.
- G3. Lifecycle hooks (pre-launch / post-quit) are first-class: built-in steps plus user scripts per app.
- G4. Backend abstraction ready for NAS / WebDAV / OpenList (phase 2); MVP ships `icloud` and `local` backends.
- G5. Never modify a single byte of the real app (signature, entitlements, TCC identity preserved).
- G6. Fully testable: pure logic unit-tested on Linux (Docker `swift` image) and macOS; real e2e on GitHub Actions
  `macos-latest` and on any Mac via `scripts/e2e.sh`.

### 1.2 Non-goals (MVP)
- Block-level lazy streaming (FSKit/macFUSE) — v3.
- App data (`~/Library/Application Support`, containers) offloading — v2 optional.
- Running apps directly from a network mount, from iCloud Drive, or via symlinks / `Contents` links.
- Re-signing real apps, stripping entitlements, shadow-writable images by default.
- Automatic app updates on read-only images (handled by explicit `unpack` → update → `pack` "refresh").
- Kernel extensions, system extensions, VPNs, drivers, Xcode.
- Privileged operations: nothing runs as root; no `sudo` anywhere.

### 1.3 Glossary
| Term | Meaning |
|---|---|
| **Repository (repo)** | Directory tree on a backend holding immutable images + catalog + device files. |
| **Backend** | Storage driver implementing `list/stat/get(range)/put/delete` (+ optional capabilities). |
| **Image** | Immutable read-only compressed DMG of exactly one `.app`, named `<bundleId>-<version>-<sha8>.dmg`. |
| **Image manifest** | Immutable JSON describing one image (hash, size, signing identity, mode, doc/URL types...). |
| **Catalog index** | Derived, rebuildable `catalog/manifest.json` listing all image manifests. |
| **Cache** | Local directory of verified image copies (`~/Library/Caches/256isenough/images`). |
| **Stub (portal)** | Small generated `.app` at the original location with its own bundle id `<orig>.256stub`. |
| **Engine** | `WupanEngine` library implementing pack/fetch/launch/gc; used by CLI and daemon. |
| **Supervisor** | The `wupan hook launch` process that owns one app session from pre-launch to detach. |
| **Session** | One mount lifetime of an image: attach → (one or more app runs) → detach. |
| **Lease** | Record "pid P needs mount M"; the mount is detached only when no live lease and no process uses it. |
| **Mount mode** | Real app runs from the read-only mounted image. |
| **Restore mode** | Real app is copied back to its original path for the duration of use, then swapped back to the stub. |
| **Pin** | User flag: keep cached (and prefetch), never auto-evict. |
| **Device** | One Mac (identified by `deviceId` UUID + hostname) using the repo. |

### 1.4 Supported app classes
| Class | Mode | Examples |
|---|---|---|
| Self-contained GUI app, Developer ID / ad-hoc signed, no helpers | **mount** | Blender, Affinity, games, standalone IDEs, most Electron apps |
| App with embedded app extensions (`PlugIns/*.appex`: Share, Quick Look, Finder Sync) | **mount** + warning (extensions only work while mounted) | many utilities |
| App with Sparkle / Squirrel(ShipIt) self-updater | **mount** + warning (updates impossible on read-only volume; use refresh) | many indie apps |
| Mac App Store app (`Contents/_MASReceipt/receipt`) | **restore** | MAS apps |
| App with privileged helper / login item / bundled launchd plists (`Contents/Library/LaunchServices/*`, `Contents/Library/LaunchDaemons|LaunchAgents/*`, `Contents/Library/LoginItems/*`, `SMPrivilegedExecutables`) | **restore** | Docker-like tools, some backup tools |
| App declaring it must live in `/Applications` (configurable deny-list of bundle ids) | **restore** | Office components, Adobe CC |
| System extensions (`Contents/Library/SystemExtensions`), kexts (`Contents/Library/Extensions/*.kext`), network extensions (`NSExtensionPointIdentifier` = `com.apple.networkextension.*`), DriverKit | **unsupported** | VPNs, drivers |
| Apple system apps (`/System/...`, `com.apple.*` except allow-list), Xcode (`com.apple.dt.Xcode`) | **unsupported** | — |
| Currently running app, app without `CFBundleIdentifier`/`CFBundleExecutable`, invalid signature | **refused** (`--force` only for invalid signature, recorded as warning) | — |

### 1.5 Auto-classification in `pack` (`Classifier`, pure logic)
`pack` gathers an `AppFacts` struct on macOS (`AppInspector`), then a pure function
`classify(AppFacts, Policy) -> Classification { mode, reasons[], warnings[] }` decides. Rules are evaluated in order;
the first `unsupported` hit wins, otherwise any `restore` hit wins, otherwise `mount`:

1. `unsupported` if: path under `/System`; bundle id in `policy.unsupportedBundleIds` (default `com.apple.dt.Xcode`);
   has `Contents/Library/SystemExtensions/*`, `Contents/Library/Extensions/*.kext`, DriverKit `.dext`, or an appex
   whose `NSExtensionPointIdentifier` starts with `com.apple.networkextension`.
2. `restore` if: `_MASReceipt/receipt` exists; `SMPrivilegedExecutables` in Info.plist; any file under
   `Contents/Library/LaunchServices`, `Contents/Library/LaunchDaemons`, `Contents/Library/LaunchAgents`,
   `Contents/Library/LoginItems`; bundle id in `policy.restoreBundleIds`.
3. otherwise `mount`; warnings for: appex present, Sparkle (`SUFeedURL` or `Frameworks/Sparkle.framework`),
   Squirrel/ShipIt, `com.apple.quarantine` xattr on the bundle, signature not Developer ID/App Store (ad-hoc/unsigned).
4. User override: `pack --mode mount|restore` beats rules 2–3 (never rule 1). The override is recorded
   (`classification.override = true`).

`AppFacts` is Codable so classification is unit-tested with JSON fixtures on Linux.

---

## 2. Architecture & components

### 2.1 Overview
```
 Finder / Dock / Spotlight / open -a / URL
            │  (Apple Events: oapp / odoc / GURL)
            ▼
 /Applications/Foo.app  ── stub, bundle id com.foo.Foo.256stub, LSUIElement
   Contents/MacOS/wupan-stub  (Swift/AppKit, ~300 LOC)
            │ collects docs/URLs (≤300 ms), then exec/spawn:
            ▼
 wupan hook launch --app <appId> [--doc ...] [--url ...]      ← "supervisor" process (one per session)
   ├── pre-launch:  lock → resolve image → fetch(backend→cache) → verify sha256 → attach → user hooks → open
   ├── watch:       NSWorkspace termination + process scan of mountpoint
   └── post-quit:   grace delay → user hooks → lsregister -u → detach → LRU update → quota evict
            │ uses
            ▼
 WupanEngine (Swift library)  ── WupanCore (pure) + WupanMac (macOS adapters)
   Backends: LocalFolderBackend, ICloudBackend (MVP) | SMB/NFS path, WebDAV, OpenList (phase 2)
   State:    ~/Library/Application Support/256isenough/state.json (+ flock)

 wupan serve  (optional LaunchAgent io.github.s546126.256isenough.daemon)
   127.0.0.1:47256 HTTP/JSON + SSE, token auth → serves web UI (web/) and calls WupanEngine
            ▲
 Pake app "256isenough.app" (tray + window) loading http://127.0.0.1:47256/ui/?token=…
```

### 2.2 Language decisions
| Component | Language | Why |
|---|---|---|
| Engine, CLI, stub launcher | **Swift 5.10+ (Swift 6 toolchain, language mode 5)** | First-class `FileManager` ubiquity APIs, `NSWorkspace`, `NSRunningApplication`, `libproc`, `Security`/`codesign` APIs; single static-ish binary; same language for stub and engine; SwiftPM builds on Linux for pure logic tests. |
| Web UI | Plain HTML + vanilla JS (ES modules), no build step | Served by `wupan serve` from `Resources/web`; zero toolchain; easy to wrap with Pake. |
| GUI shell | **Pake** (Tauri) build recipe `scripts/build-gui.sh` | User decision. Pake only loads `http://127.0.0.1:47256/ui/`; no fork, no custom IPC. |
| Test glue / e2e | Bash (`scripts/e2e.sh`) + Swift test helpers | Portable to any Mac, runs on GH Actions. |

External tools invoked via `Process` (absolute paths, argument arrays, never a shell): `/usr/bin/hdiutil`,
`/usr/bin/codesign`, `/usr/bin/ditto`, `/usr/sbin/lsof` (optional), `/usr/bin/xattr` (not needed; use
`removexattr(2)`), `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`.
`hdiutil` is wrapped behind `DiskImageTool` so a `diskutil image` implementation can be added for macOS 27+
(hdiutil deprecated there).

### 2.3 Process model
- **No mandatory daemon.** The stub spawns a **supervisor** (`wupan hook launch`) that lives for the whole session
  (pre-launch → app run → post-quit → detach) and then exits. This keeps the MVP robust: no IPC needed for launch,
  works even if the daemon is not installed. Concurrency is solved with file locks (§5.6).
- **Optional daemon** (`wupan serve`, installed by `wupan daemon install` as LaunchAgent with `KeepAlive`): serves
  the API/UI, runs periodic `gc`, recovers stale mounts at start, handles sleep/wake revalidation, and runs
  prefetch for pinned apps. When the daemon is running, the stub still uses the supervisor path (identical code);
  the daemon only observes state and receives progress via the shared event log (§3.5). Launch-via-daemon is a v1
  optimization, not MVP.
- **Why supervisor per session instead of the stub itself?** The stub must stay a tiny, rarely-regenerated signed
  binary; all logic lives in the versioned `wupan` binary which the stub locates via `Resources/stub.json`
  (`wupanPath`) with fallbacks `~/.local/bin/wupan`, `/usr/local/bin/wupan`, `/opt/homebrew/bin/wupan`.
  The stub stays alive (Dock-less, `LSUIElement`) only during pre-launch to show a progress window, then exits;
  the supervisor is spawned detached (`posix_spawn` + `setsid`) so it outlives the stub.

### 2.4 Swift Package layout
```
Package.swift                (swift-tools-version 5.9; platforms: .macOS(.v13))
Sources/
  WupanCore/        pure Swift, Foundation only, builds on Linux
    Model/          AppManifest, CatalogIndex, DeviceRecord, Config, LocalState, AppFacts, Classification
    Classifier/     classify(AppFacts, Policy)
    Cache/          CachePolicy, LRU planner (planEviction), quota math
    Lifecycle/      SessionState machine (pure transitions), LeaseTable
    Backend/        StorageBackend protocol, BackendCapabilities, RepoLayout, LocalFolderBackend, Fetcher
    Hooks/          HookSpec, HookRunner (Process-based, env contract), HookPhase
    Util/           SHA256 (swift-crypto on Linux / CryptoKit on macOS via #if canImport), AtomicFile,
                    FileLock (flock), JSONCoding (sorted keys, ISO-8601), Semver/version compare, Logging
    API/            APIRoutes model types (request/response Codables) shared by server + tests
  WupanMac/         macOS-only adapters, each file wrapped in #if os(macOS); protocols declared in WupanCore
    HdiutilDiskImageTool.swift   (DiskImageTool)
    MacAppInspector.swift        (AppInspector: Info.plist, codesign info via SecStaticCode, xattrs)
    WorkspaceAppLauncher.swift   (AppLauncher: NSWorkspace.openApplication / open(urls:withApplicationAt:))
    MountUsageProbe.swift        (ProcessProbe: libproc proc_listallpids + proc_pidpath + lsof fallback)
    ICloudBackend.swift          (StorageBackend + UbiquityControl)
    LaunchServices.swift         (lsregister -f/-u wrapper)
    CodeSigner.swift             (codesign stub)
    SystemEvents.swift           (sleep/wake, termination notifications)
  WupanEngine/      orchestration: PackService, FetchService, LaunchSupervisor, GCService, RestoreService,
                    DoctorService, StubBuilder (plist transform is pure; file ops via protocols). Depends on
                    WupanCore; uses WupanMac only through injected protocol implementations (`Platform` struct).
  WupanServer/      tiny HTTP/1.1 server on NIO-free BSD sockets (or Network.framework on macOS), routes → Engine
  wupan/            CLI executable (swift-argument-parser), composition root: builds `Platform.mac` or fails on Linux
  wupan-stub/       AppKit stub launcher executable (macOS only; on Linux compiles to a no-op main)
Resources/web/      index.html, app.js, style.css (copied into the CLI bundle dir / installed share dir)
Tests/
  WupanCoreTests/   Linux + macOS: manifest coding/versioning, classifier fixtures, LRU/quota planner, session state
                    machine, lease table, RepoLayout naming, LocalFolderBackend (temp dirs), Fetcher (resume, sha
                    mismatch), hook runner (env, timeout), plist transform for stubs, API codables, config merge
  WupanEngineTests/ Linux + macOS with fake Platform (FakeDiskImageTool, FakeLauncher, FakeProbe, FakeUbiquity):
                    pack → launch → quit → detach flow, concurrency (two launches), crash recovery, offline
  WupanMacTests/    macOS only (CI): hdiutil create/attach/detach real, inspector on a fixture app, codesign stub
scripts/  e2e.sh, build-gui.sh, make-fixture-app.sh, linux-test.sh (docker run swift:6.0 swift test)
```
Dependencies: `swift-argument-parser`, `swift-crypto` (Linux only via condition). No others in MVP.

The key testability seam is `Platform`:
```swift
public struct Platform {
  var diskImages: DiskImageTool      // create/convert/attach/detach/info/verify
  var inspector: AppInspector        // AppFacts from a .app path
  var launcher: AppLauncher          // open app with docs/urls -> pid; observe termination
  var probe: ProcessProbe            // pids whose executable/open files are under a path
  var ubiquity: UbiquityControl?     // startDownloading/evict/status (nil on non-iCloud)
  var launchServices: LaunchServicesTool
  var signer: CodeSigner
  var clock: Clock; var fs: FileSystem (thin wrapper, real on both OSes)
}
```

---

## 3. Data formats

All JSON files: UTF-8, sorted keys, ISO-8601 UTC timestamps, top-level `"schema": "<name>/<int>"`. Readers accept
the same major and ignore unknown keys; a higher major is refused with exit code 12 (`EX_SCHEMA`). Writes are atomic
(write `*.tmp-<pid>` + `fsync` + `rename`).

### 3.1 Repository layout (on any backend)
```
<repoRoot>/                              iCloud default: ~/Library/Mobile Documents/com~apple~CloudDocs/256isenough/
  repo.json                              {"schema":"repo/1","repoId":"<uuid>","createdAt":...,"layoutVersion":1}
  images/<bundleId>-<version>-<sha8>.dmg         immutable, ULMO; never overwritten
  manifests/<bundleId>-<version>-<sha8>.json     immutable image manifest (source of truth)
  catalog/manifest.json                  derived index of all manifests (rebuildable; last-writer-wins is safe)
  devices/<deviceId>.json                per-device state, written only by that device
  hooks/<bundleId>/{pre-launch,post-quit}        optional shared user hooks (opt-in, see §5.5 / §10)
  trash/                                 images marked deleted (gc moves here first; purge after 30 days)
```
- `<version>` = `CFBundleShortVersionString` sanitized to `[A-Za-z0-9._-]` (else `0`), plus `+<CFBundleVersion>` folded
  in as `_b<build>` when present: `com.blender.blender-4.2.1_b4.2.1-1a2b3c4d.dmg`.
- `<sha8>` = first 8 hex of the image sha256. Names are unique by content → no write conflicts between Macs.
- `catalog/manifest.json` is only an optimization: `wupan` always merges it with `list manifests/` and treats
  `manifests/*.json` as truth. iCloud conflict copies (`manifest 2.json`) are ignored for the catalog and reported by
  `doctor`.

### 3.2 Image manifest (`manifests/<imageId>.json`)
```json
{
  "schema": "image/1",
  "imageId": "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d",
  "bundleId": "com.blender.blender",
  "name": "Blender",
  "version": "4.2.1", "build": "4.2.1",
  "image": {
    "file": "images/com.blender.blender-4.2.1_b4.2.1-1a2b3c4d.dmg",
    "format": "ULMO", "sha256": "1a2b3c4d…64hex", "size": 412345678,
    "volumeName": "Blender 4.2.1", "appPathInVolume": "Blender.app", "fs": "APFS"
  },
  "app": {
    "originalPath": "/Applications/Blender.app",
    "unpackedSize": 1203456789,
    "executable": "Blender",
    "minimumSystemVersion": "11.2",
    "architectures": ["arm64", "x86_64"],
    "iconFile": "blender.icns",
    "documentTypes": [ { "CFBundleTypeName": "Blender File", "CFBundleTypeRole": "Editor",
                         "LSItemContentTypes": ["org.blender.blend"], "CFBundleTypeIconFile": "blender_file.icns" } ],
    "urlTypes": [ { "CFBundleURLName": "Blender URL", "CFBundleURLSchemes": ["blender"] } ],
    "exportedTypes": [], "importedTypes": []
  },
  "signing": {
    "teamId": "68UA947AUU", "authority": "Developer ID Application: Blender Foundation (68UA947AUU)",
    "cdhash": "a1b2…40hex", "designatedRequirement": "identifier \"org.blenderfoundation.blender\" and anchor apple generic …",
    "kind": "developerId", "hardenedRuntime": true, "notarized": null
  },
  "mode": "mount",
  "classification": { "reasons": [], "warnings": ["sparkle"], "override": false },
  "createdAt": "2026-10-20T08:00:00Z",
  "createdBy": { "deviceId": "6F1C…", "host": "mini", "tool": "wupan 0.1.0", "os": "15.6" }
}
```
`documentTypes`/`urlTypes` are stored verbatim (plist → JSON) so stubs can be regenerated on another Mac without the
original app. `exportedTypes`/`importedTypes` (UTI declarations) are copied too so the stub keeps custom UTIs known.
Restore-mode images use `"format": "ULMO"` too (the restore copy is extracted with `ditto` from the mounted image).

### 3.3 Catalog index (`catalog/manifest.json`)
```json
{ "schema": "catalog/1", "updatedAt": "…", "updatedBy": "6F1C…",
  "apps": { "com.blender.blender": { "name": "Blender", "latest": "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d",
            "images": ["com.blender.blender-4.1.0-99aa00bb", "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d"] } } }
```
`latest` = highest version by (`CFBundleShortVersionString` semver-ish compare, then `createdAt`).

### 3.4 Device file (`devices/<deviceId>.json`)
```json
{ "schema": "device/1", "deviceId": "6F1C…", "host": "mini", "model": "Mac16,10", "os": "15.6",
  "updatedAt": "…",
  "apps": { "com.blender.blender": { "imageId": "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d",
            "stubPath": "/Applications/Blender.app", "pinned": false, "lastUsedAt": "…", "launchCount": 7 } } }
```
Used for multi-Mac visibility ("which Macs use which version") and safe trash/purge (`gc --remote` never deletes
an image referenced by any device file updated within 90 days).

### 3.5 Local state (`~/Library/Application Support/256isenough/`)
```
config.json         user config (§3.6)
state.json          local state DB (below), guarded by state.lock (flock), atomic writes
locks/<appId>.lock  per-app session lock (flock)            appId = bundleId (one active image per app per device)
sessions/<sessionId>.json   live session record (also mirrored in state.json)
events.jsonl        append-only event log (progress + audit); rotated at 5 MB, 3 generations
hooks/<bundleId>/pre-launch[.d/*], post-quit[.d/*]        local user hooks
logs/wupan.log
```
JSON file (not SQLite) is chosen: small (≤ few hundred apps), human-debuggable, Linux-testable, no dependency.
```json
{
  "schema": "state/1", "deviceId": "6F1C…",
  "apps": {
    "com.blender.blender": {
      "imageId": "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d", "mode": "mount",
      "stubPath": "/Applications/Blender.app", "stubBundleId": "com.blender.blender.256stub",
      "pinned": false, "hooksEnabled": true, "lastUsedAt": "…", "launchCount": 7, "state": "idle"
    }
  },
  "cache": {
    "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d": {
      "path": "images/com.blender.blender-4.2.1_b4.2.1-1a2b3c4d.ulfo.dmg", "format": "ULFO",
      "remoteSha256": "1a2b…", "localSha256": "77ee…", "size": 503000000,
      "verifiedAt": "…", "lastUsedAt": "…", "complete": true
    }
  },
  "mounts": {
    "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d": {
      "sessionId": "S-20261020-080000-ab12", "devEntry": "/dev/disk5", "mountPoint": "/Users/me/Library/Caches/256isenough/mnt/com.blender.blender-4.2.1_b4.2.1-1a2b3c4d",
      "imagePath": "…ulfo.dmg", "attachedAt": "…", "supervisorPid": 4242,
      "leases": [ { "pid": 5151, "startedAt": "…" } ], "detachAfter": null
    }
  },
  "restored": { }
}
```
`restored` holds restore-mode sessions: `{ bundleId: { "restoredPath", "stubParkedAt", "sessionId", "since" } }`.

### 3.6 Config (`config.json`)
```json
{
  "schema": "config/1",
  "backend": { "type": "icloud", "root": "~/Library/Mobile Documents/com~apple~CloudDocs/256isenough" },
  "cache": { "dir": "~/Library/Caches/256isenough", "quotaBytes": 21474836480, "minFreeBytes": 16106127360,
             "localFormat": "ULFO", "keepRemoteDownloaded": false },
  "lifecycle": { "detachDelaySeconds": 120, "detachRetryMaxSeconds": 600, "forceDetachAfterSeconds": 0,
                 "attachTimeoutSeconds": 120, "downloadStallSeconds": 300, "hookTimeoutSeconds": 60 },
  "pack": { "remoteFormat": "ULMO", "moveOriginalToTrash": true, "waitForUpload": true, "signIdentity": "-" },
  "server": { "port": 47256 },
  "policy": { "restoreBundleIds": [], "unsupportedBundleIds": ["com.apple.dt.Xcode"] }
}
```
Backend types: `local` (`root` = any directory; tests use a temp dir as fake iCloud), `local-fake-icloud` (tests: simulated dataless/ensureLocal, §7.3), `icloud`; phase 2: `smb`/`nfs`
(=`local` on a mounted path + `mountURL`), `webdav` (`url`, `user`, keychain item), `openlist` (`url`, `user`,
token in keychain, `basePath`, `connections`). `forceDetachAfterSeconds: 0` = never force.

---

## 4. CLI (`wupan`)

Global flags: `--config <path>` (env `WUPAN_CONFIG`), `--state-dir <path>` (env `WUPAN_STATE_DIR`; tests), `--json` (machine output on stdout, logs on stderr),
`-v/--verbose`, `--quiet`. `<app>` accepts bundle id, app name (case-insensitive), stub path, or image id.

| Command | Purpose / key flags |
|---|---|
| `init [--backend local\|icloud] [--root <dir>] [--cache-dir <dir>] [--quota 20G]` | Create config + repo skeleton (`repo.json`, dirs). Idempotent. |
| `pack <path.app> [--mode auto\|mount\|restore] [--format ULMO\|ULFO] [--no-stub] [--stub-dir <dir>] [--keep-original] [--no-wait-upload] [--sign-identity <id>] [--dry-run] [--force]` | Inspect → classify → `hdiutil create -srcfolder` (via staging folder) → sha256 → put image + manifest → update catalog → wait upload (iCloud) → build stub to temp → move original to Trash → install stub at original path → `lsregister -f` stub. `--dry-run` prints classification only. |
| `list [--remote] [--local]` | Apps known (catalog ∪ local state) with mode, version, cached?, pinned, size. |
| `status [<app>]` | Detailed state machine state, mounts, leases, cache entry, backend availability. |
| `launch <app> [--doc <path>]... [--url <url>]... [--no-wait] [--background]` | Run full lifecycle in foreground (= what the stub triggers). `--no-wait`: return after the app is running (detaches supervisor). |
| `hook launch --app <appId> [--doc ..] [--url ..] [--stub <path>]` | Internal: entry point used by the stub (same as `launch`, plus progress UI handshake). |
| `prefetch <app>... \| --pinned \| --all` | Download + verify (+ convert) into cache without mounting. |
| `pin <app>` / `unpin <app>` | Toggle pin; pin also prefetches unless `--no-prefetch`. On iCloud optionally sets local `com.apple.fileprovider.pinned` on the remote file when `cache.keepRemoteDownloaded`. |
| `evict <app>... [--remote-local-copy] [--force]` | Drop cached image (refuses if mounted/pinned without `--force`). `--remote-local-copy`: also `evictUbiquitousItem` the repo file. |
| `gc [--dry-run] [--remote]` | Enforce quota/min-free (LRU), drop orphan caches/partials, recover stale mounts. `--remote`: move unreferenced old images to `trash/`, purge trash > 30 days. |
| `restore <app> [--permanent]` | Restore-mode session (or permanent): copy app back to original path, park stub. Without `--permanent` the stub is reinstated after quit. |
| `unpack <app> [--to <dir>]` (alias `rehydrate`) | Permanently put the real app back (stub removed), keep image in repo unless `--delete-remote`. Used for "refresh": `unpack` → update app → `pack`. |
| `stub rebuild <app>\|--all [--sign-identity <id>]` | Regenerate stub(s) from the manifest (e.g. new Mac, new launcher version). |
| `hooks list\|edit\|enable\|disable <app>` | Manage user hooks (§5.5). |
| `doctor [--fix]` | Checks: config, backend reachable, iCloud signed in + Optimize Storage, free space, `hdiutil` present, stale mounts, lock files, LS registration of stubs, conflict copies, stub ↔ manifest consistency, wupan path in stubs. `--fix` performs safe repairs. |
| `serve [--port 47256] [--print-token]` | HTTP/JSON API + web UI on 127.0.0.1 (§2.3, §10). |
| `daemon install\|uninstall\|status` | Manage the LaunchAgent plist `~/Library/LaunchAgents/io.github.s546126.256isenough.daemon.plist`. |
| `trust <app> [--team-id <id>\|--cdhash <h>]` | Approve a new signing identity for an app (TOFU, §10). |
| `version` | Prints version + schema versions. |

Exit codes (stable, documented in `wupan --help`):
| Code | Name | Meaning |
|---|---|---|
| 0 | OK | success |
| 1 | EX_FAILURE | unspecified error |
| 2 | EX_USAGE | bad arguments / unknown app |
| 3 | EX_UNSUPPORTED | app class unsupported / refused |
| 4 | EX_BACKEND | backend unavailable (offline, iCloud signed out, path missing) |
| 5 | EX_INTEGRITY | sha256 / size mismatch, signature identity mismatch |
| 6 | EX_DISKIMAGE | hdiutil create/attach/detach failure |
| 7 | EX_LAUNCH | app failed to launch / crashed during startup |
| 8 | EX_NOSPACE | insufficient local space even after eviction |
| 9 | EX_BUSY | lock held / app in use / mounted (for evict/unpack) |
| 10 | EX_HOOK | user hook failed (pre-launch non-zero aborts launch) |
| 11 | EX_TIMEOUT | download stall / attach timeout |
| 12 | EX_SCHEMA | state/manifest schema too new or corrupt |
| 13 | EX_CANCELLED | user cancelled (progress window Cancel / SIGINT) |

`--json` output shape: `{"ok":true,"data":{…}}` or `{"ok":false,"error":{"code":5,"name":"EX_INTEGRITY","message":"…","details":{…}}}`.

---

## 5. Hook lifecycle

### 5.1 State machine (per app on this device)
Pure `enum AppState` in `WupanCore/Lifecycle` with an explicit transition table (illegal transitions throw → bug):

```
remote ──fetch──▶ downloading ──complete──▶ verifying ──ok──▶ cached ──attach──▶ mounted ──open──▶ running
   ▲                  │ fail/stall              │ mismatch                         ▲   │                   │ all leases gone
   │                  ▼                         ▼                                  │   ▼ (restore mode:    ▼
   │               remote (partial kept)     remote (bad file quarantined)          │  restoring→restored)  idle (mounted, detach timer)
   │                                                                               └──relaunch── idle ──timer──▶ detaching ──▶ cached
   └────────────────────────────── evict (not pinned, not mounted) ◀──── evictable (= cached ∧ ¬pinned ∧ LRU victim)
```
- `cached` means: complete local file, verified (`localSha256` recorded), not attached.
- `evictable` is a derived predicate, not stored: `cached ∧ ¬pinned ∧ ¬mounted`.
- Stored per-app `state` is advisory (for UI); truth is re-derived at startup from cache files + `hdiutil info -plist`
  + live pids (recovery, §9).

### 5.2 Pre-launch hook (supervisor, in order)
1. **Lock**: `flock(locks/<appId>.lock, LOCK_EX)` (§5.6). If a session exists for the app and its supervisor pid is
   alive → **attach-to-session path** (§5.6) and return.
2. **Resolve image**: `state.apps[appId].imageId` (pinned version), else catalog `latest`. Read manifest.
3. **Ensure cached**:
   a. If cache entry complete and file size matches: optionally re-hash if `verifiedAt` older than 30 days or file
      mtime changed (fast path otherwise: size+mtime+inode check). 
   b. Else `ensureSpace(manifest.image.size + estimated local size)` via LRU planner (§6); fail `EX_NOSPACE`.
   c. **Fetch** (`Fetcher`): backend-specific ensure-local (iCloud: start download + wait until `.current` and
      allocated size ≥ logical size) then copy remote → `cache/partial/<imageId>.dmg.part` streaming with sha256
      computed during copy (`get(range:)` with resume from `.part` size for range-capable backends). Progress
      events → `events.jsonl` + stub progress window.
   d. **Verify**: sha256 == manifest; size == manifest. Mismatch → move file to `cache/bad/`, re-fetch once,
      then `EX_INTEGRITY`.
   e. **Convert** (if `cache.localFormat != remote format`): `hdiutil convert -format ULFO` to
      `images/<imageId>.ulfo.dmg`, record `localSha256`, delete the verified ULMO copy. (Cost: one-time CPU,
      ~seconds per 100 MB; justified because ULFO is decoded in-kernel and gives faster random reads at app launch
      than ULMO which goes through user-space `diskimages-helper`. Configurable `ULMO` = no conversion, `UDRO` =
      fastest but largest.)
   f. Mark `cached`; optionally evict the iCloud local copy of the repo file if it was dataless before we
      started (restore original state; don't keep two copies) unless `keepRemoteDownloaded` or user-pinned in Finder.
4. **Attach** (mount mode): check `hdiutil info -plist` for an existing attachment of this image path (canonical
   realpath) → reuse; else `hdiutil attach -plist -readonly -nobrowse -noautoopen -noverify -owners on
   -mountpoint <cache>/mnt/<imageId> <image>` (`-noverify` OK: we verified sha256; `hdiutil verify` runs once at
   pack). Parse plist → `devEntry`, `mountPoint`. Record mount in state **before** releasing lock. Verify
   `<mnt>/<appPathInVolume>` exists and its `CFBundleIdentifier` == manifest bundleId and (first launch after fetch)
   signing teamId/cdhash == manifest (`SecStaticCodeCheckValidity` with designated requirement), else detach and
   `EX_INTEGRITY`.
   **Restore mode** instead: attach as above, `ditto <mnt>/<app> <orig>.256restore-tmp`, detach, move stub to
   `~/Library/Application Support/256isenough/parked/<bundleId>.app`, rename tmp → original path, record in
   `restored`.
5. **User pre-launch hooks** (§5.5). Non-zero exit → abort: detach (if we attached), `EX_HOOK`.
6. **Open**: `NSWorkspace.openApplication(at: realApp, configuration: {activates: true, promptsUserIfNeeded: true,
   createsNewApplicationInstance: false})`; if docs: `open([docURLs], withApplicationAt:)`; for each URL:
   `open([url], withApplicationAt:)`. Returns `NSRunningApplication` → pid → add **lease**. Release the per-app
   lock. State `running`.

### 5.3 Watch
- Primary: `NSWorkspace.didTerminateApplicationNotification` for the leased pid; secondary: `kqueue EVFILT_PROC
  NOTE_EXIT` on the pid (works without a run loop; used in tests).
- On main pid exit: remove lease; then **mount-usage probe** every 5 s: any process whose executable path
  (`proc_pidpath`) is under the mountpoint (helpers, crashpad, renderer, login items), or (fallback, every 30 s)
  `lsof +D`-style open-file check limited to the mountpoint (`/usr/sbin/lsof -Fp -- <mnt>`). If a user re-opens the
  real app from Dock while idle (process under mount appears again) → it counts as a lease; stay `running`.
- No process uses the mount → state `idle`, set `detachAfter = now + detachDelaySeconds` (default 120 s).

### 5.4 Post-quit hook
1. Wait until `detachAfter`; any relaunch (stub click → new supervisor sees live session, §5.6) cancels the timer.
2. Take per-app lock. Re-probe usage; if in use → back to watch.
3. **User post-quit hooks** (§5.5), env `WUPAN_EXIT_STATUS` (main pid exit code if known, `crash` if a crash report
   for that pid appears in `~/Library/Logs/DiagnosticReports` within 5 s, else `unknown`). Failures are logged
   only.
4. `lsregister -u <mnt>/<app>` (unregister real app path **before** detach, avoids dangling LS records).
5. `hdiutil detach <devEntry>`; on `EBUSY` (exit 16 / "Resource busy") retry with backoff 5,10,20,40… s up to
   `detachRetryMaxSeconds`; then if `forceDetachAfterSeconds > 0` → `detach -force`, else leave mounted, mark
   `stuck`, notify (UI/`doctor`); the next `gc`/supervisor retries.
6. Update state: remove mount, `lastUsedAt = now` for app and cache entry, `launchCount++`, write device file
   (`devices/<deviceId>.json`, best-effort, coalesced).
7. Run `gc` quota pass (LRU; never evicts what we just used unless it alone exceeds quota).
8. Restore mode: verify no process runs from restored path, move restored app → `trash staging`
   (`<orig>.256old`), move parked stub back, delete staging (if the app modified itself in place —
   e.g. updated — detect by cdhash change and **ask**: keep updated → `pack` new image (refresh), or discard).
9. Release lock, supervisor exits 0.

### 5.5 User-defined hooks
- Locations (local wins over shared, both run if both exist — local first):
  - local: `~/Library/Application Support/256isenough/hooks/<bundleId>/{pre-launch,post-quit}` and
    `…/{pre-launch.d,post-quit.d}/*` (lexical order); global `hooks/_all/…` applies to every app.
  - shared (repo): `<repoRoot>/hooks/<bundleId>/…` — **disabled by default**; enabled per-app with
    `wupan hooks enable <app> --shared --sha256 <hash>` which pins the exact content hash (a modified shared
    script is refused until re-approved). Rationale: the repo is synced from other devices (§10).
- Must be regular files, owned by the user, not group/world-writable, executable. Run with `Process`, no shell,
  `cwd` = hook dir, stdin `/dev/null`, timeout `hookTimeoutSeconds` (SIGTERM then SIGKILL after 5 s).
- Environment contract (also documented in README):
  `WUPAN_PHASE` (`pre-launch`|`post-quit`), `WUPAN_APP_ID`, `WUPAN_BUNDLE_ID`, `WUPAN_IMAGE_ID`, `WUPAN_VERSION`,
  `WUPAN_MODE`, `WUPAN_APP_PATH` (real app path, mounted or restored), `WUPAN_MOUNT_POINT`, `WUPAN_SESSION_ID`,
  `WUPAN_DOCS` / `WUPAN_URLS` (newline-separated), `WUPAN_EXIT_STATUS` (post-quit), `WUPAN_STATE_DIR`.
- Pre-launch non-zero → abort launch (`EX_HOOK`), stdout/stderr tail shown in stub alert. Post-quit failure → log.
- Typical uses: restore an app-data archive (v2), set `defaults` keys, start/stop a companion service, mount a
  data volume, notify.

### 5.6 Concurrency & locking
- Locks: `state.lock` (short critical sections for read-modify-write of `state.json`; never held across slow I/O)
  and `locks/<appId>.lock` (held across pre-launch steps 2–6 and post-quit steps 2–9). Downloads of *different*
  apps run in parallel; same image: second waiter blocks on the app lock and then finds it cached.
- `flock` locks die with the process → no stale lock after crash. The session record carries `supervisorPid` +
  process start time (to avoid pid reuse).
- **Two launches at once** (double click twice, or doc open while starting): second stub → second supervisor →
  blocks on app lock (stub shows "Starting…") → when acquired, sees mount in `running` with live supervisor →
  **attach-to-session path**: just forwards docs/URLs via `NSWorkspace.open(urls, withApplicationAt: mountedApp)`
  (or `openApplication` to activate), appends an event, exits 0. No second mount.
- **Stub relaunch while running/idle**: same attach-to-session path; if session is `idle` (detach timer pending), the
  watcher sees the new process under the mount and cancels the timer. If session is `detaching` (lock held by the
  post-quit), the new supervisor waits for the lock, then finds `cached` and mounts again (rare; costs seconds).
- **Supervisor dead but mount alive** (crash, `kill`): any new supervisor/`gc`/daemon start detects session with dead
  `supervisorPid` → **adopts** it: if processes use the mount → becomes its watcher; else run post-quit.
- **Two Macs**: no shared mutable files except catalog (derived, last-writer-wins safe) and each own device file.
- **Real app launched outside our stub** (e.g. Spotlight finds the mounted real app while idle, or Dock pinned the
  real app path): the mounted app path disappears after detach; Dock icon breaks. Mitigation: `-nobrowse` (no
  Spotlight indexing) + post-quit `lsregister -u` + `doctor` checks Dock plist for real-mount paths and offers to
  replace with the stub (as AppPorts does).

### 5.7 Sequence diagram
```mermaid
sequenceDiagram
    actor U as User
    participant S as Stub (wupan-stub)
    participant V as Supervisor (wupan hook launch)
    participant B as Backend (iCloud/local)
    participant C as Cache
    participant H as hdiutil
    participant A as Real App
    U->>S: click / open doc / URL (oapp, odoc, GURL)
    S->>S: collect events ≤300 ms, show progress window
    S->>V: posix_spawn(setsid) hook launch --app id --doc… --url… (progress via events fifo)
    V->>V: flock app lock; check live session
    alt session already running
        V->>A: NSWorkspace.open(urls, withApplicationAt)
        V-->>S: done
    else not cached
        V->>B: ensureLocal (startDownloadingUbiquitousItem, poll .current)
        B-->>V: local & complete
        V->>C: stream copy → .part (sha256 on the fly)
        V->>V: verify sha256+size, convert ULMO→ULFO
    end
    V->>H: attach -readonly -nobrowse -noautoopen -plist -mountpoint mnt
    H-->>V: devEntry, mountPoint
    V->>V: check bundleId + code signature vs manifest; user pre-launch hooks
    V->>A: NSWorkspace.openApplication + open(docs/urls)
    A-->>V: pid (lease)
    V-->>S: ready → stub exits
    U->>A: uses app … quits
    A-->>V: didTerminate / NOTE_EXIT
    loop every 5 s
        V->>V: probe processes/open files under mnt
    end
    V->>V: idle; wait detachDelay (cancel on relaunch)
    V->>V: user post-quit hooks
    V->>H: lsregister -u realApp; detach devEntry (retry on busy)
    V->>C: lastUsedAt=now, launchCount++; LRU gc to quota
    V->>B: put devices/<deviceId>.json (best effort)
```

---

## 6. Cache & LRU

- **Location**: `~/Library/Caches/256isenough/` (configurable): `images/` (verified, ready), `partial/` (`.part` +
  `.part.json` resume metadata: imageId, expected size/sha, bytes, partial hash state is *not* persisted → on resume
  we re-hash the existing prefix), `bad/` (quarantined mismatches, deleted by gc after 7 days), `mnt/` (mountpoints).
  `~/Library/Caches` is excluded from Time Machine by convention; we also set `NSURLIsExcludedFromBackupKey`.
  The cache must be on the internal APFS Data volume (doctor warns otherwise).
- **Accounting**: `used = Σ allocated size of images/ + partial/` (use `totalFileAllocatedSize`, not logical size).
- **Quota** `quotaBytes` (default 20 GiB) and **free-space floor** `minFreeBytes` (default 15 GiB, read via
  `volumeAvailableCapacityForImportantUsageKey`). Effective budget before a fetch of size `n` (local size estimate =
  manifest size × 1.35 when converting ULMO→ULFO, refined after first convert):
  `need = max(0, used + n − quota, n − (free − minFree))`.
- **Eviction algorithm** (`planEviction`, pure, deterministic for tests):
  1. Candidates = cache entries that are complete, not mounted, not part of an active session, not pinned,
     not the image being fetched.
  2. Order: orphans first (image not referenced by any app in state/catalog or superseded versions), then by
     `lastUsedAt` ascending (LRU), tie-break larger size first, then imageId.
  3. Take until `need` satisfied. If impossible → `EX_NOSPACE` with the plan in `details` (UI suggests unpinning).
  Pinned images may exceed quota (warning in `status`/`doctor`).
- **When**: before fetch (`ensureSpace`), after each session ends (post-quit step 7), `gc`, daemon every 6 h, and on
  low-disk notification (daemon, v1).
- **Pinning**: `pin` = never auto-evict locally + prefetch now + daemon re-prefetches pinned images when missing
  (e.g. new version packed on another Mac). Independent of Finder "Keep Downloaded" (which is an xattr on the
  *repo* file, single-device, undocumented): we only set it when `keepRemoteDownloaded` is true.
- **Versions**: when a newer image becomes `latest`, the old cached one becomes an orphan candidate after the app
  next uses the new one. `apps[*].imageId` pins a version explicitly (`wupan launch --image <id>` / `pin --version`).
- **APFS clone usage**: we do **not** use `cp -c` from iCloud Drive into the cache as a "zero-copy" trick: clone
  sharing does not survive File Provider eviction/re-download (research-cursor §2.3) and cloning a dataless
  placeholder clones nothing. The cache is a real streamed copy (needed anyway for on-the-fly hashing). APFS clones
  are used only *inside* the cache dir (e.g. `clonefile` for `stub rebuild` icon extraction or test fixtures). Since
  the default local format is ULFO (different bytes from the ULMO remote), clone sharing would be irrelevant anyway.
- **Interaction with iCloud evict**: the repo copy in iCloud Drive and the cache copy are separate files → after a
  successful fetch we evict the repo file's local data (`evictUbiquitousItem`) **only if it was not local before
  the fetch** (we don't fight the user's Finder state), never if it carries `com.apple.fileprovider.pinned`, never
  while uploading (`ubiquitousItemIsUploading`). With Optimize Mac Storage off, eviction is a no-op/fails → logged at
  debug level; `doctor` reports "iCloud keeps full copies: repo occupies X GB locally" so the user understands
  space use. After `pack`, the local repo copy is evicted only after upload is confirmed (§7.2).

---

## 7. Backend abstraction

### 7.1 Protocol (`WupanCore/Backend`)
```swift
public struct RemoteItem: Codable, Equatable { var path: String; var size: Int64; var modified: Date?;
  var isDirectory: Bool; var etag: String?; var localState: LocalState? }   // localState: iCloud only
public enum LocalState: String, Codable { case current, downloading, notDownloaded, unknown }
public struct BackendCapabilities: OptionSet { rangeReads, atomicPut, serverSideHash,
  ensureLocal /* needs materialization before read (iCloud) */, evictLocalCopy, uploadStatus, localPath }

public protocol StorageBackend: Sendable {
  var id: String { get }                             // "icloud", "local", "openlist:https://…"
  var capabilities: BackendCapabilities { get }
  func list(_ dir: String) async throws -> [RemoteItem]          // non-recursive; paths are repo-relative, "/"-separated
  func stat(_ path: String) async throws -> RemoteItem?          // nil = not found
  func get(_ path: String, range: Range<Int64>?, to sink: ByteSink,
           progress: @Sendable (Int64) -> Void) async throws      // streaming; throws .rangeNotSupported if needed
  func put(_ path: String, from source: URL, progress: @Sendable (Int64) -> Void) async throws  // atomic: temp + rename/move
  func delete(_ path: String) async throws
  // optional capabilities (default impls throw .unsupported)
  func ensureLocal(_ path: String, progress: @Sendable (DownloadProgress) -> Void) async throws   // .ensureLocal
  func evictLocalCopy(_ path: String) async throws                                             // .evictLocalCopy
  func uploadState(_ path: String) async throws -> UploadState                                 // .uploadStatus
  func localURL(_ path: String) -> URL?                                                        // .localPath
}
public enum BackendError: Error { notFound, unavailable(reason), notSignedIn, rangeNotSupported, conflict,
  quota, stalled, unsupported, io(Error) }
```
Rules: all repo files except `catalog/manifest.json` and `devices/*` are write-once; `put` of an existing
immutable path with identical size+sha is a no-op, different content → `.conflict` (bug). `Fetcher` handles resume
(`range` from `.part` size when `rangeReads`), retries (3× exponential, on `.unavailable`/io), stall detection
(no progress for `downloadStallSeconds` → `EX_TIMEOUT`), and hashing; backends stay dumb.

### 7.2 iCloud backend (`ICloudBackend`, macOS; built on top of `LocalFolderBackend`)
- Root `~/Library/Mobile Documents/com~apple~CloudDocs/256isenough/` (the user-visible iCloud Drive folder; no
  ubiquity container entitlement needed for a non-sandboxed CLI). Availability: `FileManager.ubiquityIdentityToken`
  non-nil (signed in, Drive enabled) + root dir exists → else `.notSignedIn` / `.unavailable`.
- `ensureLocal`: read `URLResourceValues` (`ubiquitousItemDownloadingStatus`, `ubiquitousItemIsDownloading`,
  `ubiquitousItemDownloadingError`, `fileSize`, `fileAllocatedSize`); if not `.current` → `startDownloadingUbiquitousItem`
  then poll every 1 s (removing cached resource values each time; `NSMetadataQuery` optional for push updates in the
  daemon). Done when status `.current` **and** `fileAllocatedSize ≥ fileSize` (or `totalFileAllocatedSize` > 0 and the
  file is not dataless: `stat.st_flags & SF_DATALESS == 0`). Progress is **indeterminate** (allocated size jumps 0→full;
  UI shows spinner + elapsed time + size). Stall: no status change and no error for `downloadStallSeconds` → retry
  `startDownloading` once, then `EX_TIMEOUT`.
- **Hard rule**: nothing ever opens/maps/attaches a repo file directly; we only `read()` it sequentially after
  `ensureLocal` succeeded (dataless check is re-done right before copy; if dataless → back to ensureLocal). We never
  `hdiutil attach` a file in iCloud Drive.
- `get`: plain sequential read via `FileHandle` (range supported once local).
- `put`: copy to `<dir>/.<name>.tmp-<uuid>` (hidden temp *inside* the target dir, so the final step is a same-volume
  `rename`), then rename. iCloud sees one new file.
- `uploadState`: `ubiquitousItemIsUploaded`, `ubiquitousItemIsUploading`, `ubiquitousItemUploadingError`. Upload is
  "done" when `isUploaded && !isUploading && error == nil` observed **twice, ≥5 s apart**. `pack --wait-upload`
  (default on) waits (indeterminate progress, no timeout but Ctrl-C safe: image remains, pack resumes at "wait upload"
  step via `pack --resume <imageId>`); the original app is moved to Trash only after upload completes (or immediately
  with `--no-wait-upload`, which prints a warning that the only copy is local until upload completes).
- `evictLocalCopy`: `evictUbiquitousItem`, then verify status became `.notDownloaded` (don't trust return value);
  skip if pinned xattr present or uploading.
- Conflict copies: `list` filters names matching `/ \d+(\.[^.]+)?$/` and reports them as conflicts.
- Large-file limit / quota: `put` maps `NSFileWriteOutOfSpaceError` / ubiquitous uploading error "quota" → `.quota`;
  `pack` refuses images larger than `backend.maxFileSize` (iCloud default 50 GB, configurable, with a doc note that
  Apple's limit may change).

### 7.3 LocalFolder backend (`LocalFolderBackend`, pure Foundation, Linux-testable)
- Any directory: external disk, SMB/NFS mounted share, or a temp dir. Used as **fake iCloud** in tests and e2e:
  `FakeUbiquityLocalBackend` wraps it to simulate `ensureLocal` (a "dataless" marker file `.<name>.dataless` makes
  `stat().localState = .notDownloaded`; `ensureLocal` removes it after a configurable delay; `evictLocalCopy`
  re-creates it) so the iCloud state machine is exercised on Linux and in CI without an Apple ID.
- `put` = temp + `rename`, `get` with ranges via `FileHandle.seek`. Capabilities: `rangeReads, atomicPut, localPath`.

### 7.4 Phase 2 backends (designed now, not implemented)
- **NAS via mounted path (SMB/NFS)**: `LocalFolderBackend` + `mountURL` (`smb://nas/share/256isenough`); `ensureMounted`
  uses `NetFSMountURLAsync` / `open smb://…` once, keychain credentials; availability = path is a mountpoint reachable
  within 3 s (avoid hanging `stat` on dead SMB: probe in a child task with timeout). Never run apps from the share.
- **WebDAV** (`WebDAVBackend`, URLSession): `PROPFIND Depth:1` → list/stat; `GET` + `Range: bytes=a-b` → get;
  `PUT` to `name.tmp-uuid` then `MOVE` (Overwrite: F) → atomic put; `DELETE`. Basic/Digest auth from keychain.
- **OpenList/AList** (`OpenListBackend`): auth `POST /api/auth/login` → token (stored in keychain, refreshed on 401);
  `POST /api/fs/list {path, refresh:false}`; `POST /api/fs/get {path}` → `raw_url` (may be a 302 to a cloud direct
  link, short-lived) and `size`; `PUT /api/fs/put` with headers `File-Path` (URL-encoded) and `As-Task: false`;
  `POST /api/fs/remove {dir, names}`. **Multi-connection range download**: split into N (default 4, ≤8) chunks of
  ≥16 MB, each `GET raw_url` with `Range`, written with `pwrite` into a preallocated `.part`; chunk map persisted in
  `.part.json` for resume; on 403/410 (expired direct link) re-call `/api/fs/get`; whole-file sha256 after assembly
  (per-chunk hashing optional). Falls back to WebDAV `/dav` when REST is disabled. The `Fetcher`'s chunked mode is
  generic (`capabilities.rangeReads` + `parallelRanges` hint) so WebDAV/S3 reuse it.

---

## 8. Stub generation & signing

### 8.1 Bundle layout
```
/Applications/Blender.app/                 (same name/path as the original → Dock/Spotlight/Launchpad keep working)
  Contents/
    Info.plist                             transformed (below)
    PkgInfo                                "APPL????"
    MacOS/wupan-stub                       universal (arm64+x86_64) launcher, identical bytes for every stub
    Resources/
      <iconFile>.icns / Assets.car         copied from the real app (and doc-type icons)
      stub.json                            {"schema":"stub/1","appId":"com.blender.blender","imageId":"…",
                                            "wupanPath":"/Users/me/.local/bin/wupan","stubVersion":1,"createdAt":"…"}
      <lang>.lproj/InfoPlist.strings       only CFBundleName/CFBundleDisplayName/CFBundleSpokenName
    _CodeSignature/
```
Built in a temp dir next to the destination (`/Applications/.256stub-<uuid>.app`, same volume), signed, verified,
then swapped in with `rename` (`renamex_np(RENAME_EXCL)` when the destination is free; when replacing an existing
stub: `RENAME_SWAP` then delete old). The real app is first moved to the Trash via `FileManager.trashItem` (undoable),
or kept with `--keep-original` (renamed `Blender.256orig.app`, mostly for tests).

### 8.2 Info.plist transform (pure function `StubPlist.make(original:, manifest:) -> [String: Any]`, unit-tested)
Start from the original Info.plist, then:
- `CFBundleIdentifier` = `<orig>.256stub`; keep `CFBundleName`, `CFBundleDisplayName`, `CFBundleShortVersionString`,
  `CFBundleVersion` (so Finder shows the real version), `CFBundleIconFile`/`CFBundleIconName`, `LSMinimumSystemVersion`
  = `"12.0"` (stub's own requirement), `CFBundleDocumentTypes`, `CFBundleURLTypes`, `UTExportedTypeDeclarations`,
  `UTImportedTypeDeclarations`, `NSHumanReadableCopyright`, `LSApplicationCategoryType`.
- Set `CFBundleExecutable = "wupan-stub"`, `CFBundlePackageType = "APPL"`, `LSUIElement = true` (no Dock tile for
  the stub itself; the real app gets its own), `NSHighResolutionCapable = true`,
  `WupanTargetBundleIdentifier = <orig>`, `WupanImageId`, `WupanStubVersion`.
- In each document type set `LSHandlerRank = "Alternate"` unless it was `Owner` for a type the real app owns
  exclusively (keep `Owner`), so the stub doesn't steal defaults from other installed apps; `CFBundleTypeRole` kept.
- Remove: `NSPrincipalClass`, `NSMainNibFile`, `NSMainStoryboardFile`, `LSEnvironment`, `LSBackgroundOnly`,
  `LSRequiresNativeExecution`, `LSArchitecturePriority`, `CFBundleExecutable*` variants, `SU*` (Sparkle),
  `ElectronDefaultApp`, `NSAppleScriptEnabled`, `OSAScriptingDefinition`, `NSServices`, `NSExtension*`,
  `SMPrivilegedExecutables`, `SMAuthorizedClients`, `NS*UsageDescription` (stub needs no TCC), `LSFileQuarantineEnabled`,
  `CFBundleHelpBookName/Folder`, `NSUserActivityTypes`, `NSDockTilePlugIn`.
- Rationale for unique bundle id: real app keeps its own LS/TCC identity; Playpen's same-id approach mixes TCC/LS.

### 8.3 Launcher binary (`wupan-stub`, AppKit, no storyboard)
- `NSApplication` with delegate; `setActivationPolicy(.accessory)` (needed to show the progress window).
- Receives events:
  - `application(_:open urls: [URL])` — covers both files (`odoc`) and custom URL schemes (`GURL`);
    files split from URLs by `url.isFileURL`.
  - `applicationDidFinishLaunching` — `oapp`/plain launch; also reads `CommandLine.arguments` (when run as
    `open -a Stub --args …` or directly) and forwards extra args as `--arg` (passed via
    `OpenConfiguration.arguments` to the real app).
  - Events arriving within a **300 ms coalescing window** after launch are batched into one supervisor call;
    later events (stub still alive during pre-launch) are queued and forwarded in a second call
    (`hook launch` for a live session = forward-only path, §5.6).
- Spawns `wupan hook launch --app <appId> --stub <bundlePath> --progress-fd 3 [--doc p]… [--url u]… [--arg a]…`
  via `posix_spawn` with `POSIX_SPAWN_SETSID`, fd 3 = pipe. Supervisor writes NDJSON progress lines
  (`{"phase":"downloading","bytes":…,"total":…}`, `{"phase":"ready"}`, `{"phase":"error","code":5,"message":…}`).
- UI: no window if `ready` arrives < 700 ms; otherwise a small floating panel "Fetching Blender from iCloud… (412 MB)"
  with indeterminate/determinate progress and **Cancel** (sends SIGINT to the supervisor → it cleans up, exit 13).
  Errors → `NSAlert` with message + "Open Logs" / "Run Doctor". After `ready`/error, the stub terminates; the
  supervisor continues independently (closing the pipe is not a signal).
- If `wupan` not found: alert "256isenough is not installed (wupan missing)". If supervisor dies before `ready`:
  alert with last stderr lines.
- Size target: < 300 KB universal. Built by SwiftPM, `lipo`'d universal in release CI.

### 8.4 Signing
- The stub is signed **after** all files are written: `codesign --force --sign <identity> --options runtime
  --timestamp(=none for ad-hoc) <tmp.app>` then `codesign --verify --strict <tmp.app>`. Never `--deep`, never touches
  the real app (it isn't inside the stub). Pre-sign: `removexattr` of `com.apple.quarantine`, FinderInfo, resource
  forks on stub files only (stub files are ours).
- Identity: `pack.signIdentity` — default `-` (ad-hoc; fine for one user on one Mac). Recommended for the user:
  `Developer ID Application: … (TEAMID)` — stable designated requirement, survives stub rebuilds. The stub needs no
  TCC permissions (it only spawns `wupan`); the real app gets its own TCC prompts under its own identity.
  Notarization is not needed for locally generated stubs (no quarantine); it is needed for the distributed
  `wupan` release / GUI (v1).
- The `wupan-stub` binary inside the release is pre-signed; `StubBuilder` re-signs the whole stub bundle anyway
  because Info.plist differs per app.

### 8.5 Launch Services registration
- After install: `lsregister -f <stub>` (register/refresh). Stub declares doc/URL types → "Open With" works while the
  real app is offline.
- During a mounted session the real app gets registered by LS on launch; post-quit step 4 runs `lsregister -u
  <mnt>/<app>` before detach. `doctor --fix` runs `lsregister -u` for any registered path under our `mnt/` dir that no
  longer exists (from `lsregister -dump` parsing, best-effort, diagnostic) — never a global `-gc`/reset.
- `unpack`/uninstall: `lsregister -u <stub>` before deleting the stub, then `lsregister -f` the restored real app.
- Default handlers: if the real app was the default for a URL scheme, `pack` re-points it to the stub
  (`NSWorkspace.setDefaultApplication(at: stubURL, toOpenURLsWithScheme:)`, macOS 12+; may prompt the user); for content types we leave defaults (LS falls back to the
  stub because the real app is gone). `unpack` restores the original bundle id.

---

## 9. Error, crash, offline handling

| Situation | Detection | Behavior |
|---|---|---|
| Interrupted download (Ctrl-C, crash, network loss, sleep) | `.part` + `.part.json` exist | Next fetch resumes: range-capable backends continue from verified prefix length (prefix re-hashed); iCloud: `ensureLocal` again (iCloud resumes internally) then re-copy (local copy is fast). `gc` deletes partials older than 7 days. |
| Download stall | no progress/status change for `downloadStallSeconds` | Retry once (re-request download), then `EX_TIMEOUT`; stub alert offers Retry. |
| sha256/size mismatch | after copy | Move to `cache/bad/`, refetch once; second mismatch → `EX_INTEGRITY`, event + alert "image corrupt in repository; run `wupan doctor`". Never attach unverified bytes. |
| Mounted app identity mismatch (bundle id / team / cdhash) | after attach | Detach, `EX_INTEGRITY`. |
| Attach failure (`hdiutil` non-zero, timeout `attachTimeoutSeconds`) | exit status / plist error | If "image already attached" → resolve existing devEntry and reuse; if corrupt → delete cache entry, refetch once; else `EX_DISKIMAGE` with hdiutil stderr. |
| Real app fails to launch | `openApplication` error | Run post-quit path immediately (detach), `EX_LAUNCH`, alert with error. |
| Real app crashes | pid exits; crash report check | Treated as quit (`WUPAN_EXIT_STATUS=crash`), normal delayed detach. Event logged. |
| Detach busy | hdiutil exit 16 / "Resource busy" | Backoff retry (§5.4); `stuck` state surfaced; never `-force` unless configured. |
| Supervisor / engine crash | dead `supervisorPid` with mount record | **Recovery** at every supervisor start, `gc`, `status`, daemon start: reconcile `state.mounts` with `hdiutil info -plist` (images under our cache dir): (a) mounted in OS but not in state → adopt (create session); (b) in state but not mounted → drop record; (c) dead supervisor → adopt: watch if in use else post-quit now. Also `restored` entries with dead session → finish restore-mode post-quit when the app isn't running. |
| Corrupt `state.json` | JSON decode error | Move to `state.json.corrupt-<ts>`, rebuild from cache dir listing + `hdiutil info` + stubs found via `mdfind kMDItemCFBundleIdentifier == '*.256stub'` and `/Applications` scan. |
| Offline, image cached | backend `.unavailable` | Launch works (no backend access needed on cache hit: manifest is cached in `cache/manifests/`). Device-file update deferred. |
| Offline, not cached | `.unavailable` | Fail fast (≤ 5 s probe) `EX_BACKEND`: alert "Blender is not available offline. Pin apps to keep them offline." |
| iCloud not signed in / Drive off | `ubiquityIdentityToken == nil` | `EX_BACKEND` with specific message; `doctor` explains. Cached apps still launch. |
| Disk full | `ensureSpace` plan fails or `ENOSPC` during copy/convert | Evict per LRU; if still short → `EX_NOSPACE`, delete `.part`, alert lists pinned images + sizes. |
| Sleep/wake | daemon: `NSWorkspace.willSleep/didWake`; supervisor: same notifications | Downloads: re-check status on wake (stall timer paused during sleep). Mounted images are local files → survive sleep. On wake the supervisor re-probes leases. |
| Logout / shutdown | SIGTERM to supervisor | Supervisor marks state `interrupted` and exits quickly; macOS detaches images at logout; next run reconciles. |
| Stub moved/renamed by user | stub.json path mismatch | Works (stub passes its own path). `doctor` updates `stubPath`. |
| `wupan` binary moved | stub can't find it | Alert with fix (`wupan stub rebuild --all`); fallbacks in §2.3. |
| Restore-mode crash mid-swap | `restored` record + both/neither present | Recovery completes or rolls back the swap: real app present & not running → move back to trash staging and reinstate parked stub. Never deletes the only copy of anything that isn't in the repo (checked via manifest sha of image). |
| Pack interrupted | `pack.json` journal in `staging/` | Steps are idempotent; `pack --resume` continues; original app untouched until final step. |

All errors go to `events.jsonl` (`{"ts","level","app","session","phase","code","message"}`) and `logs/wupan.log`.

---

## 10. Security considerations

- **No privilege**: everything runs as the user; no root helper, no sudo, no setuid. Images mount with `-owners on`
  but `nosuid` is enforced by DiskArbitration for disk images.
- **Integrity chain**: manifest sha256 verified before attach; mounted app's bundle id + Team ID + cdhash/DR checked
  against the manifest (first launch after each fetch); Gatekeeper/XProtect still evaluate on `open` as usual. A
  tampered repo (other device or attacker with iCloud access) can at worst supply a different image + matching
  manifest: **trust anchor** = the `signing.teamId` recorded at pack time is also stored locally in
  `state.apps[*].trustedTeamId` on the device that packed or first approved it; an image whose Team ID differs from the
  locally trusted one requires explicit `wupan trust <app>` (TOFU). Ad-hoc/unsigned apps: cdhash is the identity;
  a new cdhash for such apps requires approval.
- **Shared hooks are code execution**: disabled by default, content-hash pinned when enabled (§5.5). Local hooks must
  be owned by the user and not writable by others.
- **No `-force` detach** by default (prevents SIGBUS/data loss in running apps).
- **Quarantine**: we don't strip `com.apple.quarantine` from the real app; if present at pack time we warn (the app
  may be translocated) and require `--allow-quarantined` — then the image contains the xattr as is. Stub files are
  ours, xattrs cleaned before signing.
- **Local HTTP API** (`serve`): binds `127.0.0.1` only (never `0.0.0.0`/`::`); random 256-bit token generated at
  first start, stored in `~/Library/Application Support/256isenough/server-token` (mode 0600); every API call requires
  `Authorization: Bearer <token>`; the UI page is loaded as `/ui/?token=…`, which sets an `HttpOnly; SameSite=Strict`
  cookie and redirects to `/ui/` (token not kept in URL/history). Mutating endpoints are `POST` only, require
  `Content-Type: application/json` and reject requests whose `Origin`/`Host` header isn't
  `http://127.0.0.1:<port>` / `localhost` (DNS-rebinding defense). No endpoint executes arbitrary commands or takes
  arbitrary file paths except app paths validated to be `.app` bundles under `/Applications` or `~/Applications`
  (pack). Unix-socket transport is a v1 option for CLI↔daemon.
- **Secrets** (phase 2 WebDAV/OpenList credentials): Keychain (`kSecClassInternetPassword`), never in config.
- **Repo privacy**: app images are not secret, but device files reveal hostnames/usage; session tiering (roadmap)
  uses a **separate, encrypted** repo.
- **Supply chain**: only `swift-argument-parser` (+ `swift-crypto` on Linux). Pake (GPL-3.0) is a separate program that
  only loads a localhost URL; our code is not linked with it (see §14 licensing question).
- **Path handling**: all external tools invoked with argument arrays; bundle ids/versions sanitized before use in
  filenames (`[A-Za-z0-9._-]`, max 200 chars); manifests' relative paths validated (no `..`, no absolute).

---

## 11. Testing plan

### 11.1 Unit tests (`swift test`; Linux via `scripts/linux-test.sh` = `docker run --rm -v $PWD:/src -w /src swift:6.0 swift test`, and macOS CI)
| Module | What is tested |
|---|---|
| `Model` | Codable round-trips for every schema with golden JSON fixtures (`Tests/Fixtures/*.json`); unknown keys ignored; higher major → `EX_SCHEMA`; ISO dates; sorted keys stable output. |
| `RepoLayout` | image naming (`<bundleId>-<ver>-<sha8>`), sanitization, version/build folding, path validation (`..` rejected), conflict-copy detection regex. |
| `Classifier` | fixture `AppFacts` for: plain app → mount; MAS receipt → restore; SMPrivilegedExecutables → restore; LoginItems → restore; system extension/kext/network ext → unsupported; Xcode → unsupported; Sparkle/appex/quarantine warnings; override semantics. |
| `Cache/LRU` | `planEviction`: quota and minFree math, pins never chosen, mounted never chosen, orphans first, LRU order, deterministic tie-break, impossible plan → error with details; allocated-size accounting. |
| `Lifecycle` | every legal transition; illegal ones throw; recovery reconciliation function `reconcile(state, osMounts, livePids)` table tests (adopt / drop / post-quit). |
| `LeaseTable` | add/remove/cancel detach timer on relaunch, pid-reuse guard (start time). |
| `Backend` | `LocalFolderBackend` list/stat/get(range)/put(atomic)/delete on temp dirs; `FakeUbiquityLocalBackend` notDownloaded → ensureLocal → current; evict; upload-state simulation. |
| `Fetcher` | streaming hash correctness; resume from `.part`; stall timeout (fake clock); sha mismatch → bad/ + one retry; ENOSPC simulation. |
| `HookRunner` | env contract, timeout kill, non-zero handling, permission checks (group-writable refused), ordering local → `.d/*` → shared. |
| `StubPlist` | transform: id suffix, removed keys, kept doc/URL/UTI types, `LSHandlerRank`, `CFBundleExecutable`. |
| `API` | route request/response codables; token/Origin check logic as pure functions. |
| `Engine` (fake `Platform`) | pack → stub build (fake signer) → launch (fake attach/launcher) → quit → detach after delay (fake clock) → LRU updated; two concurrent launches = one attach + one forward; supervisor crash → adoption; offline cached vs uncached; restore-mode swap & rollback. |

### 11.2 macOS integration tests (`WupanMacTests`, CI only, `#if os(macOS)`)
- `HdiutilDiskImageTool`: create ULMO from fixture folder, convert ULFO, attach with `-plist` (parse devEntry/mount),
  re-attach detection, detach, busy detach (hold an open file handle → exit 16 → retry succeeds after close).
- `MacAppInspector` on the fixture app (bundle id, doc/URL types, codesign info, ad-hoc kind).
- `CodeSigner` + `StubBuilder`: produced stub passes `codesign --verify --strict` and `plutil -lint`.
- `MountUsageProbe`: spawn a process from the mount → detected; after exit → not detected.

### 11.3 End-to-end: `scripts/e2e.sh`
Single portable bash script (macOS 13+, bash 3.2 compatible, no Homebrew deps). Runs on GitHub Actions `macos-latest`
(`.github/workflows/macos.yml` job `e2e`) and on any Mac by `./scripts/e2e.sh` (needs Xcode CLT for `swift build`).
Everything lives in `E2E_DIR=$(mktemp -d)`; nothing touches `/Applications`, real iCloud, or user config:
`HOME` is not changed, but `WUPAN_CONFIG`, `--state-dir`, cache dir, repo root and stub install dir all point into
`$E2E_DIR`. A `trap` cleanup detaches any image under `$E2E_DIR`, `lsregister -u`s the stub and fixture paths, and
deletes the dir (unless `KEEP=1`).

Steps and assertions (each assertion prints `PASS/FAIL <name>`; script exits non-zero on first failure and dumps
`events.jsonl`, `wupan.log`, `hdiutil info`):
1. **Build**: `swift build -c release` (wupan, wupan-stub). `scripts/make-fixture-app.sh` compiles
   `Tests/Fixtures/E2EApp` (≈60-line AppKit app `io.github.s546126.e2eapp`, declares doc type `public.plain-text`
   and URL scheme `wupane2e`) into `$E2E_DIR/src/E2EApp.app`, ad-hoc signed. On launch it appends one JSON line to
   `$E2E_DIR/app-events.jsonl` (env var not available via LS, so path is baked into the fixture's Info.plist key
   `E2ELogPath` at build time) with `{event:"launch", bundlePath, pid}`, then one line per `open urls` event
   `{event:"open", url}`; quits itself when file `$E2E_DIR/quit-now` exists (polls 200 ms) or after 60 s.
   - A1 `fixture_valid`: `codesign --verify --strict` passes.
2. **Init** fake iCloud: `wupan init --backend local --root $E2E_DIR/fake-icloud --cache-dir $E2E_DIR/cache --quota 200M`.
   (Variant job `E2E_FAKE_DATALESS=1` uses `FakeUbiquity` mode via `backend.type: "local-fake-icloud"` to exercise
   ensureLocal.)
3. **Pack**: `wupan pack $E2E_DIR/src/E2EApp.app --stub-dir $E2E_DIR/Applications --keep-original --json`.
   - A2 `pack_mode`: JSON `data.mode == "mount"`.
   - A3 `image_in_repo`: exactly one `images/io.github.s546126.e2eapp-1.0_b1-<sha8>.dmg`; `shasum -a 256` equals
     manifest `image.sha256`; `<sha8>` equals its prefix; `hdiutil imageinfo` format is `ULMO`.
   - A4 `manifest_valid`: `manifests/<id>.json` has schema `image/1`, bundleId, version, size == file size, teamId/
     cdhash fields present, documentTypes contains `public.plain-text`, urlTypes contains `wupane2e`.
   - A5 `catalog_updated`: `catalog/manifest.json` `apps["io.github.s546126.e2eapp"].latest == <id>`.
   - A6 `stub_valid`: `$E2E_DIR/Applications/E2EApp.app` exists; `codesign --verify --strict` ok;
     `CFBundleIdentifier == io.github.s546126.e2eapp.256stub`; `CFBundleExecutable == wupan-stub`; `LSUIElement` true;
     `Resources/stub.json` appId matches; stub size < 2 MB.
   - A7 `not_cached_yet`: `wupan status <app> --json` → state `remote`, no cache file.
4. **Launch via the hook path, through the stub**: `open -a $E2E_DIR/Applications/E2EApp.app $E2E_DIR/doc1.txt`
   then `open "wupane2e://hello?x=1"` is **not** used (would hit global LS default) — URL forwarding is tested via
   `open -a <stub> "wupane2e://hello?x=1"` after start (stub forwards to live session).
   Wait (≤ 60 s) for `app-events.jsonl` launch line.
   - A8 `fetched_verified`: cache dir has `images/<id>.ulfo.dmg`; state cache entry `complete:true`, `remoteSha256`
     == manifest; `events.jsonl` contains phases `fetch.start, fetch.done, verify.ok, convert.done, attach.ok`
     in that order.
   - A9 `mounted_readonly`: `hdiutil info -plist` lists the cache image with mountpoint `$E2E_DIR/cache/mnt/<id>`;
     `mount` shows it `read-only` + `nobrowse`.
   - A10 `running_from_mount`: launch line `bundlePath` starts with the mountpoint; pid alive; `wupan status` →
     `running` with one lease; real app's process path (`ps -o comm= -p pid`) under mountpoint.
   - A11 `doc_forwarded`: `app-events.jsonl` contains `open` with `file://…/doc1.txt`.
   - A12 `second_launch_no_remount`: `open -a <stub> "wupane2e://hello?x=1"` → `open` event with that URL appears
     within 10 s; still exactly one attachment of the image in `hdiutil info`; same app pid.
   - A13 `prelaunch_hook_ran`: a local hook `hooks/io.github.s546126.e2eapp/pre-launch` (installed before step 4)
     wrote `$E2E_DIR/hook-pre.env` containing `WUPAN_PHASE=pre-launch` and `WUPAN_MOUNT_POINT=<mnt>`.
5. **Quit**: `touch $E2E_DIR/quit-now`; config for e2e sets `detachDelaySeconds: 3`.
   - A14 `app_exited`: pid gone within 10 s.
   - A15 `idle_then_detached`: `wupan status` shows `idle` before the delay elapses (checked at +1 s), then within
     `3 + 20` s the image is absent from `hdiutil info` and the mountpoint dir is empty/removed.
   - A16 `postquit_hook_ran`: `hook-post.env` contains `WUPAN_PHASE=post-quit` and `WUPAN_EXIT_STATUS=0`.
   - A17 `lru_updated`: state `apps[..].lastUsedAt` > launch time, `launchCount == 1` (the URL forward doesn't count),
     cache entry `lastUsedAt` updated; state `cached`; `supervisor` process gone; device file written in repo.
6. **Cache hit relaunch**: `wupan launch <app> --no-wait`, then quit.
   - A18 `cache_hit`: `events.jsonl` for this session has no `fetch.start`; launch < 10 s; detaches again.
7. **LRU eviction**: pack a second fixture copy with a different bundle id (`…e2eapp2`) and ~150 MB of random padding
   (> quota 200 MB together), launch & quit it.
   - A19 `lru_evicted`: first image's cache file removed (LRU), second present; `wupan gc --dry-run --json` plan empty.
   - A20 `pin_respected`: `wupan pin app1` (re-fetches it) then launch app2 again → app1 stays, app2 evicted or
     `EX_NOSPACE` not raised (quota math documented in test).
8. **Crash recovery**: launch app1, `kill -9` the supervisor, then quit the app; run `wupan gc`.
   - A21 `stale_mount_recovered`: image detached after `gc`; state has no mounts.
9. **Integrity**: flip one byte in the repo image of app2 (copy then modify, keeps immutability rule for the
   real case), evict its cache, `wupan launch app2`.
   - A22 `sha_mismatch_refused`: exit code 5; nothing attached; file moved to `cache/bad/`.
10. **Unpack**: `wupan unpack app1 --to $E2E_DIR/restored`.
   - A23 `unpack_ok`: restored app `codesign --verify --strict` ok and cdhash equals manifest; stub removed.
11. Optional `E2E_RESTORE=1`: pack with `--mode restore` and assert swap/rollback (A24–A25).

CI notes: GitHub macOS runners have a logged-in GUI session, so `open`/NSWorkspace work. If LS launching proves
unreliable on the runner, the script falls back to `wupan launch --doc …` (same supervisor path minus the stub
binary) and marks A11/A12 as `SKIP(stub-ls)` — with a separate assertion that runs the stub binary directly
(`E2EApp.app/Contents/MacOS/wupan-stub` with a document argument) to still cover forwarding code.

### 11.4 CI workflows
- `linux.yml`: `ubuntu-24.04-arm`/`ubuntu-latest` + `swift:6.0` container → `swift build --target WupanCore` + `swift test`
  (macOS-only tests compiled out).
- `macos.yml` (`macos-latest`): `swift build`, `swift test`, `scripts/e2e.sh`; uploads `$E2E_DIR` logs as artifact on
  failure. GUI build (`scripts/build-gui.sh`, needs Node + Rust) is a separate manual `workflow_dispatch` job.

---

## 12. Scope: MVP vs v1 / v2 / v3

### 12.1 MVP (this branch `feat/mvp`)
- Swift package: `WupanCore`, `WupanMac`, `WupanEngine`, `WupanServer`, `wupan`, `wupan-stub` as in §2.4.
- Backends: `local`, `icloud` (FileManager APIs; upload wait; ensureLocal; evict of repo local copy),
  `local-fake-icloud` (tests).
- Commands: `init, pack, list, status, launch, hook launch, prefetch, pin, unpin, evict, gc, restore, unpack,
  stub rebuild, hooks list/enable/disable, doctor (checks + safe fixes), serve, daemon install/uninstall/status, version`.
- Modes: mount (full lifecycle) and restore (temporary swap + rollback). Classifier with policy lists.
- Lifecycle: supervisor per session, leases, mount-usage probe, delayed detach with busy retry, recovery/adoption,
  user hooks (local; shared hooks behind hash approval).
- Cache: ULFO local conversion, quota + minFree, LRU, pins.
- Stub: AppKit launcher with doc/URL forwarding + progress window; ad-hoc or configured identity signing; LS register.
- GUI (minimal): `wupan serve` serves `web/` — one page: app list (name, version, mode, state, cached size, pinned,
  last used), actions Launch / Prefetch / Pin / Unpin / Evict, cache usage bar (used/quota/free), live progress via
  `GET /api/events` (SSE), `doctor` results. API: `GET /api/apps`, `GET /api/apps/{id}`, `POST /api/apps/{id}/launch|
  prefetch|pin|unpin|evict`, `GET /api/cache`, `POST /api/gc`, `GET /api/doctor`, `GET /api/events`, `GET /api/version`.
  Pack stays CLI-only in MVP (drag & drop pack is v1).
  `scripts/build-gui.sh`: `npx pake-cli http://127.0.0.1:47256/ui/ --name 256isenough --show-system-tray
  --hide-on-close --width 900 --height 640 --icon assets/icon.icns`, then patch generated `Info.plist`
  (`LSUIElement=true` optional flag `--no-dock`) and re-sign. CI does not build it.
- Tests per §11; docs: README (install, quickstart, hook env contract, exit codes), this design.

### 12.2 v1
- Native-feeling UX: progress in the GUI for stub launches, drag-and-drop pack, "refresh app version" flow,
  daemon-driven launch over a Unix socket (faster cold starts, single owner of mounts), low-disk notifications,
  `NSMetadataQuery`-based push progress, Developer ID signed + notarized `wupan` release and Homebrew tap.
- Compatibility database (`compat.json`: bundleId → mode, notes, tested OS) shipped and user-contributed.
- `diskutil image` backend for `DiskImageTool` on macOS 27+.
- Optional SwiftUI `MenuBarExtra` companion if Pake tray UX is insufficient.

### 12.3 v2 (phase 2)
- Backends: SMB/NFS mounted path, WebDAV, OpenList (REST + multi-connection range fetch), maybe S3.
- Multi-Mac: shared repo, per-device files, remote gc with references, `trust` UX.
- Optional app-data archiving (second image per app, restored by pre-launch hook / archived by post-quit).
- Agent session tiering (§13), first pi.

### 12.4 v3
- Block-level lazy loading (FSKit extension or macFUSE-FSKit) so large apps start before full download.
- Chunked, deduplicated images (content-defined chunking) for cheap version updates.

---

## 13. Roadmap design (not MVP): agent session file offloading with hot/cold tiering

Goal: keep agent session histories available without them filling the disk. Same engine primitives (backend,
cache, manifest, hooks), different object type.

- **Scope, in order**: (1) pi `~/.pi/agent/sessions/--<cwd>--/*.jsonl`; (2) Claude Code `~/.claude/projects/*/<id>.jsonl`
  + matching `subagents/`, `tool-results/`; (3) Codex `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`; (4) Cursor CLI
  `agent-transcripts/**/*.jsonl`. **Never**: credentials (`~/.claude.json`, `.credentials.json`, `~/.codex/auth.json`,
  `config.toml`), any SQLite (`*.sqlite`, `*.db`, `state.vscdb`, `-wal`, `-shm`), Cursor IDE storage, opencode db.
  Rules are format-based (JSONL only), with per-tool adapters supplying paths and resume semantics.
- **Tiers**: hot = local (current/recent sessions, last N=14 days, any file modified < 24 h, any file open by a
  process); cold = remote **separate encrypted repo** `sessions/` (age/ChaCha20-Poly1305 per file, key in Keychain;
  never the plain app repo).
- **Eligibility to move cold**: JSONL, closed (no process has it open — `proc_pidfdinfo`/`lsof` check), mtime older
  than threshold, last line is complete JSON (newline-terminated), not referenced as current session.
- **Move protocol**: copy → hash → put `sessions/<tool>/<relpath>.jsonl.zst.enc` + manifest
  `{schema:"session/1", tool, originalPath, sha256, size, mtime, sessionId, parentSession, cwd}` → verify upload →
  replace local file with nothing (pi) or a tiny tombstone index entry in `~/.256isenough/sessions-index.json`
  (we do not leave stub files the agent might parse as corrupt sessions).
- **Recall**: (a) explicit `wupan sessions restore <id|cwd|--recent>`; (b) launcher wrapper hook: `wupan exec pi …`
  (or a shell alias) runs a pre-launch hook that restores cold sessions for the current cwd before `pi`/`claude`
  starts (pi `--continue`/`--resume` need the files back at the original absolute path, `parentSession` paths kept);
  restore resets mtime to the original value for listing order, except Claude where mtime is set to now to avoid the
  `cleanupPeriodDays` sweep (document trade-off; suggest raising `cleanupPeriodDays`).
- **Search**: index cold sessions' first user message + cwd + timestamps in `sessions-index.json` so lists/search
  work without downloading.
- **Hazards**: append-only files being written (closed check), tool format changes (adapter versioned, disable on
  unknown header — pi header `type:session` version 3), iCloud conflict copies (`file 2.jsonl`) → never put live
  session dirs into iCloud Drive; secrets inside transcripts → encryption mandatory.

---

## 14. Risks & open questions for the user

### 14.1 Risks
1. **Supervisor-per-session design** depends on the stub being able to spawn a long-lived detached process; if
   macOS ties it to the stub's lifetime (e.g. via responsible-process accounting/TCC prompts attributed to the stub),
   we move launches into the daemon (v1 design already planned).
2. **Helper processes** that outlive the main app (Electron/Chrome helpers, login items) keep the mount busy →
   app stays mounted longer than expected (correct but surprising); probe cost is low.
3. **iCloud behavior** of non-sandboxed CLI (download/evict/upload status) only has public evidence on 14+; must be
   validated on the user's 15/26; progress is indeterminate; large uploads can take hours.
4. **ULMO→ULFO conversion** doubles CPU time on first fetch and needs temporary space (ULMO + ULFO both present for a
   moment); tunable via `cache.localFormat`.
5. **Launch Services duplicates** (stub + mounted real app) may confuse "Open With" briefly during sessions.
6. **TCC**: same bundle id + DR should keep grants, but Accessibility/Input Monitoring toggles may need re-approval.
7. **macOS 27**: hdiutil deprecated (still works); stricter bundle validation for stubs — test on 27 betas.
8. **GitHub runners**: LS/`open` behavior on headless-ish CI may differ; fallback path in e2e documented.
9. **GPL-3.0 (Pake)**: our engine is not linked with Pake; distributing the Pake-built app means distributing a GPL
   program (source offer for the wrapper). Self-use: no issue.

### 14.2 Open questions
1. Project license for our own code (MIT/Apache-2.0 suggested; compatible with distributing a separate GPL Pake shell)?
2. Signing identity: use your Developer ID for stubs (stable DR) or ad-hoc for MVP? Team ID to configure in CI secrets?
3. Target macOS versions (13+ assumed for the stub; engine 13+)? Is the Mac mini on 15, 26 or 27? Optimize Mac Storage on?
4. Default cache quota (20 GiB) and free-space floor (15 GiB) OK?
5. Default detach delay 120 s OK? Should pinned apps stay mounted (never detach)?
6. Move originals to Trash after pack (default) or keep a renamed copy until first successful launch?
7. Install location of `wupan` (`~/.local/bin` vs `/usr/local/bin` vs Homebrew)?
8. Is a Pake tray window acceptable as the GUI, or do you want a native SwiftUI menu bar extra in v1?
9. Which apps (list + sizes) should be the first compatibility test set?
10. Multi-Mac sharing of one repo in scope for v2?
