# 256isenough — Design (v1 draft rev. r1, 2026-10-21)

> Revision r1 addresses design-review round 1 (B1–B7, N1–N7): hard classifier/format constraints (§1.5, §3.6),
> write-ahead swap journal (§5.8), lock/reservation table (§5.6, §6), mode-specific process ownership (§5.9),
> acknowledged stub↔supervisor protocol (§8.3), cookie+pairing UI auth (§10.1), required macOS gates (§11.3).

> 中文摘要：每个冷门 App 打成只读压缩 DMG（远端 ULMO），放在可插拔后端（MVP = iCloud Drive / 本地目录）；
> `/Applications` 里放一个独立 bundle id、可签名的轻量 Stub。点击 Stub → **pre-launch hook**（拉取到本地缓存、
> sha256 校验、`hdiutil attach -readonly -nobrowse`、带文档/URL 打开真 App）→ App 退出 → **post-quit hook**
> （等所有进程离开挂载点、延迟卸载、更新 LRU、按配额淘汰）。引擎/CLI/Stub 用 Swift，GUI 是 `isenough serve`
> 提供的本地网页，用 Pake 打包。MAS/带特权 helper 的 App 走"临时还原"模式。

This document is the implementation spec. Sources: [research.md](research.md), [research-luna.md](research-luna.md),
[research-cursor.md](research-cursor.md). Where they conflict, research-cursor.md wins (no `brctl`, never attach a
dataless DMG, no `cp -c` zero-copy cache, ULMO remote, stub must forward documents and URLs, Pake = tray window +
HTTP to a daemon, sessions tiering starts with pi JSONL only).

Naming: product **256isenough**; CLI **`isenough`** (the name "wupan" was rejected by the user — never use it); stub launcher **`isenough-stub`**; Swift modules `Isenough*`.
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
| **Engine** | `IsenoughEngine` library implementing pack/fetch/launch/gc; used by CLI and daemon. |
| **Supervisor** | The `isenough hook launch` process that owns one app session from pre-launch to detach. |
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
| Mac App Store app (`Contents/_MASReceipt/receipt`) | **restore** (hard, never mount) | MAS apps |
| App with privileged helper / login item / bundled launchd plists (`Contents/Library/LaunchServices/*`, `Contents/Library/LaunchDaemons|LaunchAgents/*`, `Contents/Library/LoginItems/*`, `SMPrivilegedExecutables`) | **restore** (hard) | Docker-like tools, some backup tools |
| App declaring it must live in `/Applications` (configurable deny-list of bundle ids) | **restore** | Office components, Adobe CC |
| System extensions (`Contents/Library/SystemExtensions`), kexts (`Contents/Library/Extensions/*.kext`), network extensions (`NSExtensionPointIdentifier` = `com.apple.networkextension.*`), DriverKit | **unsupported** | VPNs, drivers |
| Apple system apps (`/System/...`, `com.apple.*` except allow-list), Xcode (`com.apple.dt.Xcode`) | **unsupported** | — |
| Currently running app, app without `CFBundleIdentifier`/`CFBundleExecutable`, invalid signature | **refused** (`--force` only for invalid signature, recorded as warning; never changes the mode) | — |
| Bundle carrying `com.apple.quarantine` (translocation candidate) | **refused in MVP** (B4; see §5.9) | freshly downloaded, never-moved apps |

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
   Squirrel/ShipIt, signature not Developer ID/App Store (ad-hoc/unsigned).
   `refused` (exit 3) if `com.apple.quarantine` is present on the bundle or its main executable (MVP; translocation
   would move the running path outside our usage roots, §5.9). The error text gives the safe recovery: "open the app
   once from its current location, accept Gatekeeper, quit, then remove quarantine yourself if you trust it
   (`xattr -dr com.apple.quarantine <app>`) and re-run pack". We never strip it ourselves.
4. **Overrides are one-directional (B1).** `pack --mode restore` may *upgrade* a `mount` result to `restore`
   (e.g. a misbehaving self-updater). Nothing can downgrade: a rule-1 hit is always `unsupported`, a rule-2 hit is
   always `restore` (MAS receipt, privileged helper, login item, launchd plist, `restoreBundleIds`).
   `pack --mode mount` exists only as an assertion: if classification is not `mount`, pack fails with `EX_UNSUPPORTED`
   and lists the reasons. `--force` never changes the mode. Policy lists in config can only *add* restore/unsupported
   ids; there is no `mountBundleIds`. The override is recorded (`classification.override = "restore"|null`).
   `classify` is total and tested with negative fixtures (MAS + `--mode mount` → error; kext + `--mode restore` →
   unsupported; config with unknown policy keys → ignored, never weakening).

`AppFacts` is Codable so classification is unit-tested with JSON fixtures on Linux.

---

## 2. Architecture & components

### 2.1 Overview
```
 Finder / Dock / Spotlight / open -a / URL
            │  (Apple Events: oapp / odoc / GURL)
            ▼
 /Applications/Foo.app  ── stub, bundle id com.foo.Foo.256stub, LSUIElement
   Contents/MacOS/isenough-stub  (Swift/AppKit, ~400 LOC)
            │ spawns; sends every doc/URL batch over a socketpair; exits after all batches are acked
            ▼
 isenough hook launch --app <appId> --control-fd 3      ← "supervisor" (owner of a session, or short-lived joiner)
   ├── pre-launch:  lock → resolve image → fetch(backend→cache) → verify sha256 → attach → user hooks → open
   ├── watch:       NSWorkspace termination + process scan of mountpoint
   └── post-quit:   grace delay → user hooks → lsregister -u → detach → LRU update → quota evict
            │ uses
            ▼
 IsenoughEngine (Swift library)  ── IsenoughCore (pure) + IsenoughMac (macOS adapters)
   Backends: LocalFolderBackend, ICloudBackend (MVP) | SMB/NFS path, WebDAV, OpenList (phase 2)
   State:    ~/Library/Application Support/256isenough/state.json (+ flock)

 isenough serve  (optional LaunchAgent io.github.s546126.256isenough.daemon)
   127.0.0.1:47256 HTTP/JSON + SSE; session cookie for the UI, Bearer for CLI (§10.1)
            ▲
 Pake app "256isenough.app" (tray + window) loading http://127.0.0.1:47256/ui/ (pairs once with a code)
```

### 2.2 Language decisions
| Component | Language | Why |
|---|---|---|
| Engine, CLI, stub launcher | **Swift 5.10+ (Swift 6 toolchain, language mode 5)** | First-class `FileManager` ubiquity APIs, `NSWorkspace`, `NSRunningApplication`, `libproc`, `Security`/`codesign` APIs; single static-ish binary; same language for stub and engine; SwiftPM builds on Linux for pure logic tests. |
| Web UI | Plain HTML + vanilla JS (ES modules), no build step | Served by `isenough serve` from `Resources/web`; zero toolchain; easy to wrap with Pake. |
| GUI shell | **Pake** (Tauri) build recipe `scripts/build-gui.sh` | User decision. Pake only loads `http://127.0.0.1:47256/ui/`; no fork, no custom IPC. |
| Test glue / e2e | Bash (`scripts/e2e.sh`) + Swift test helpers | Portable to any Mac, runs on GH Actions. |

External tools invoked via `Process` (absolute paths, argument arrays, never a shell): `/usr/bin/hdiutil`,
`/usr/bin/codesign`, `/usr/bin/ditto`, `/usr/sbin/lsof` (optional), `/usr/bin/xattr` (not needed; use
`removexattr(2)`), `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`.
`hdiutil` is wrapped behind `DiskImageTool` so a `diskutil image` implementation can be added for macOS 27+
(hdiutil deprecated there).

### 2.3 Process model
- **No mandatory daemon.** The stub spawns a **supervisor** (`isenough hook launch`) that lives for the whole session
  (pre-launch → app run → post-quit → detach) and then exits. This keeps the MVP robust: no IPC needed for launch,
  works even if the daemon is not installed. Concurrency is solved with file locks (§5.6).
- **Optional daemon** (`isenough serve`, installed by `isenough daemon install` as LaunchAgent with `KeepAlive`): serves
  the API/UI, runs periodic `gc`, recovers stale mounts at start, handles sleep/wake revalidation, and runs
  prefetch for pinned apps. When the daemon is running, the stub still uses the supervisor path (identical code);
  the daemon only observes state and receives progress via the shared event log (§3.5). Launch-via-daemon is a v1
  optimization, not MVP.
- **Why supervisor per session instead of the stub itself?** The stub must stay a tiny, rarely-regenerated signed
  binary; all logic lives in the versioned `isenough` binary which the stub locates via `Resources/stub.json`
  (`isenoughPath`) with fallbacks `~/.local/bin/isenough`, `/usr/local/bin/isenough`, `/opt/homebrew/bin/isenough`.
  The stub stays alive (Dock-less, `LSUIElement`) during pre-launch to show progress and until every forwarded
  document/URL batch is acknowledged (§8.3), then exits; the supervisor is spawned detached (`posix_spawn` +
  `setsid`) so it outlives the stub.

### 2.4 Swift Package layout
```
Package.swift                (swift-tools-version 5.9; platforms: .macOS(.v13))
Sources/
  IsenoughCore/        pure Swift, Foundation only, builds on Linux
    Model/          AppManifest, CatalogIndex, DeviceRecord, Config, LocalState, AppFacts, Classification
    Classifier/     classify(AppFacts, Policy)
    Cache/          CachePolicy, LRU planner (planEviction), quota math
    Lifecycle/      SessionState machine (pure transitions), LeaseTable
    Backend/        StorageBackend protocol, BackendCapabilities, RepoLayout, LocalFolderBackend, Fetcher
    Hooks/          HookSpec, HookRunner (Process-based, env contract), HookPhase
    Util/           SHA256 (swift-crypto on Linux / CryptoKit on macOS via #if canImport), AtomicFile,
                    FileLock (flock), JSONCoding (sorted keys, ISO-8601), Semver/version compare, Logging
    API/            APIRoutes model types (request/response Codables) shared by server + tests
  IsenoughMac/         macOS-only adapters, each file wrapped in #if os(macOS); protocols declared in IsenoughCore
    HdiutilDiskImageTool.swift   (DiskImageTool)
    MacAppInspector.swift        (AppInspector: Info.plist, codesign info via SecStaticCode, xattrs)
    WorkspaceAppLauncher.swift   (AppLauncher: NSWorkspace.openApplication / open(urls:withApplicationAt:))
    MountUsageProbe.swift        (ProcessProbe: libproc proc_listallpids + proc_pidpath + lsof fallback)
    ICloudBackend.swift          (StorageBackend + UbiquityControl)
    LaunchServices.swift         (lsregister -f/-u wrapper)
    CodeSigner.swift             (codesign stub)
    SystemEvents.swift           (sleep/wake, termination notifications)
  IsenoughEngine/      orchestration: PackService, FetchService, LaunchSupervisor, GCService, RestoreService,
                    DoctorService, StubBuilder (plist transform is pure; file ops via protocols). Depends on
                    IsenoughCore; uses IsenoughMac only through injected protocol implementations (`Platform` struct).
  IsenoughServer/      tiny HTTP/1.1 server on NIO-free BSD sockets (or Network.framework on macOS), routes → Engine
  isenough/            CLI executable (swift-argument-parser), composition root: builds `Platform.mac` or fails on Linux
  isenough-stub/       AppKit stub launcher executable (macOS only; on Linux compiles to a no-op main)
Resources/web/      index.html, app.js, style.css (copied into the CLI bundle dir / installed share dir)
Tests/
  IsenoughCoreTests/   Linux + macOS: manifest coding/versioning, classifier fixtures, LRU/quota planner, session state
                    machine, lease table, RepoLayout naming, LocalFolderBackend (temp dirs), Fetcher (resume, sha
                    mismatch), hook runner (env, timeout), plist transform for stubs, API codables, config merge
  IsenoughEngineTests/ Linux + macOS with fake Platform (FakeDiskImageTool, FakeLauncher, FakeProbe, FakeUbiquity):
                    pack → launch → quit → detach flow, concurrency (two launches), crash recovery, offline
  IsenoughMacTests/    macOS only (CI): hdiutil create/attach/detach real, inspector on a fixture app, codesign stub
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
- `catalog/manifest.json` is only an optimization: `isenough` always merges it with `list manifests/` and treats
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
    "unpackedSize": 1203456789, "treeHash": "sha256:9f0e…64hex",
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
  "classification": { "reasons": [], "warnings": ["sparkle"], "override": null },
  "createdAt": "2026-10-20T08:00:00Z",
  "createdBy": { "deviceId": "6F1C…", "host": "mini", "tool": "isenough 0.1.0", "os": "15.6" }
}
```
`documentTypes`/`urlTypes` are stored verbatim (plist → JSON) so stubs can be regenerated on another Mac without the
original app. `exportedTypes`/`importedTypes` (UTI declarations) are copied too so the stub keeps custom UTIs known.
Restore-mode images use `"format": "ULMO"` too (the restore copy is extracted with `ditto` from the mounted image).
Plist→JSON (N6): `String/Bool/Int/Double/Array/Dict` map directly; `Date` → `{"$date":"ISO-8601"}`, `Data` →
`{"$data":"base64"}`, so `StubPlist` can round-trip to a binary-identical-semantics plist. Manifests also record
`"iconFiles": [...]` and the image stores the icons, so `stub rebuild` on a new Mac extracts icons by attaching the
cached image read-only (never needs the original app). Schema migrations: readers support the current and previous
minor layout of each major; `isenough` rewrites local files (`state`, `config`) to the newest minor on first write;
immutable repo files are never migrated in place. Manifests used by a successful fetch are copied to
`cache/manifests/<imageId>.json` (offline launch).

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
locks/global.lock, locks/app/<appId>.lock, locks/image/<imageId>.lock   flock locks (§5.6)   appId = bundleId
sessions/<sessionId>.json   live session record (also mirrored in state.json)
events.jsonl        append-only event log (progress + audit); rotated at 5 MB, 3 generations
hooks/<bundleId>/pre-launch[.d/*], post-quit[.d/*]        local user hooks
logs/isenough.log
```
JSON file (not SQLite) is chosen: small (≤ few hundred apps), human-debuggable, Linux-testable, no dependency.
```json
{
  "schema": "state/1", "deviceId": "6F1C…",
  "apps": {
    "com.blender.blender": {
      "imageId": "com.blender.blender-4.2.1_b4.2.1-1a2b3c4d", "mode": "mount",
      "stubPath": "/Applications/Blender.app", "stubBundleId": "com.blender.blender.256stub",
      "pinned": false, "hooksEnabled": true, "lastUsedAt": "…", "launchCount": 7, "state": "idle",
      "trusted": { "teamId": "68UA947AUU", "cdhash": null, "approvedAt": "…", "approvedBy": "pack" },
      "needsResolution": null
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
      "imagePath": "…ulfo.dmg", "attachedAt": "…", "owner": { "pid": 4242, "start": 1729411200 }, "joinPending": 0,
      "leases": [ { "pid": 5151, "start": 1729411260, "bundleURL": "…/Blender.app", "executablePath": "…" } ],
      "detachAfter": null, "phase": "running"
    }
  },
  "restored": { },
  "reservations": { "R-ab12": { "owner": "S-20261020-080000-ab12", "pid": 4242, "pidStart": 1729411200,
                                "bytes": 1100000000, "purpose": "fetch:com.blender…" } },
  "pendingDetach": { }
}
```
`restored` holds restore-mode sessions: `{ bundleId: { "journal": "journals/<txid>.json", "sessionId", "since" } }`;
the authoritative swap state lives in the write-ahead journal (§5.8), not here. `needsResolution` (per app) is set
when a restored/updated bundle awaits a user decision (§5.8.4); while set, `launch` uses the retained bundle and
`evict/unpack/gc` refuse the app. `reservations` are cache-capacity reservations (§6); entries whose owner pid/start
time is dead are dropped by any holder of `state.lock`. Additional local directories:
`journals/` (swap/pack/install transactions, §5.8), `locks/` (§5.6), `retained/` (never auto-deleted bundles, §5.8).

### 3.6 Config (`config.json`)
```json
{
  "schema": "config/1",
  "backend": { "type": "icloud", "root": "~/Library/Mobile Documents/com~apple~CloudDocs/256isenough" },
  "cache": { "dir": "~/Library/Caches/256isenough", "quotaBytes": 21474836480, "minFreeBytes": 16106127360,
             "localFormat": "ULFO", "keepRemoteDownloaded": false },
  "lifecycle": { "detachDelaySeconds": 120, "detachRetryMaxSeconds": 600, "forceDetachAfterSeconds": 0,
                 "attachTimeoutSeconds": 120, "downloadStallSeconds": 300, "hookTimeoutSeconds": 60 },
  "pack": { "moveOriginalToTrash": true, "waitForUpload": true, "signIdentity": "-" },
  "server": { "port": 47256 },
  "policy": { "restoreBundleIds": [], "unsupportedBundleIds": ["com.apple.dt.Xcode"] }
}
```
Backend types: `local` (`root` = any directory; tests use a temp dir as fake iCloud), `local-fake-icloud` (tests: simulated dataless/ensureLocal, §7.3), `icloud`; phase 2: `smb`/`nfs`
(=`local` on a mounted path + `mountURL`), `webdav` (`url`, `user`, keychain item), `openlist` (`url`, `user`,
token in keychain, `basePath`, `connections`). `forceDetachAfterSeconds: 0` = never force.

**Image formats are fixed, not options (B1).** Remote images are always `ULMO` (best ratio, smallest transfer and
iCloud footprint); there is no `pack.remoteFormat` and no `pack --format`. `cache.localFormat` accepts only `ULFO`
(default: LZFSE, ~1.2–1.4× the ULMO size, fast random-read decompression at launch) or `UDRO` (uncompressed, fastest,
largest; for very slow CPUs or test fixtures). `ULMO` as a local format is rejected at config load (`EX_USAGE`), as is
any other value, and a remote manifest whose `image.format != "ULMO"` is refused at fetch (`EX_INTEGRITY`). Conversion
cost (one `hdiutil convert` per fetched version, CPU-bound, roughly seconds per 100 MB on Apple silicon, plus
temporary space, §6) is paid once per fetch and amortized over every later launch; that is the justification for not
attaching ULMO locally. Unit tests: config with `localFormat: "ULMO"` or `"UDZO"` → `EX_USAGE`; manifest with
`format: "ULFO"` → refused; `pack --format` → unknown option.

---

## 4. CLI (`isenough`)

Global flags: `--config <path>` (env `ISENOUGH_CONFIG`), `--state-dir <path>` (env `ISENOUGH_STATE_DIR`; tests), `--json` (machine output on stdout, logs on stderr),
`-v/--verbose`, `--quiet`. `<app>` accepts bundle id, app name (case-insensitive), stub path, or image id.

| Command | Purpose / key flags |
|---|---|
| `init [--backend local\|icloud] [--root <dir>] [--cache-dir <dir>] [--quota 20G]` | Create config + repo skeleton (`repo.json`, dirs). Idempotent. |
| `pack <path.app> [--mode auto\|mount\|restore] [--no-stub] [--stub-dir <dir>] [--keep-original] [--no-wait-upload] [--sign-identity <id>] [--dry-run] [--force]` | Inspect → classify → `hdiutil create -srcfolder` (via staging folder) → sha256 → put image + manifest → update catalog → wait upload (iCloud) → build stub to temp → move original to Trash → install stub at original path → `lsregister -f` stub. `--dry-run` prints classification only. |
| `list [--remote] [--local]` | Apps known (catalog ∪ local state) with mode, version, cached?, pinned, size. |
| `status [<app>]` | Detailed state machine state, mounts, leases, cache entry, backend availability. |
| `launch <app> [--doc <path>]... [--url <url>]... [--no-wait] [--background]` | Run full lifecycle in foreground (= what the stub triggers). `--no-wait`: return after the app is running (detaches supervisor). |
| `hook launch --app <appId> --control-fd <n> [--stub <path>]` | Internal: entry point used by the stub (same as `launch`; requests/acks over the control socket, §8.3). |
| `resolve <app> --keep-updated\|--discard\|--keep-both` | Resolve a retained/updated bundle (§5.8). |
| `serve pair` | Print a one-time pairing code for the GUI (§10.1). |
| `prefetch <app>... \| --pinned \| --all` | Download + verify (+ convert) into cache without mounting. |
| `pin <app>` / `unpin <app>` | Toggle pin; pin also prefetches unless `--no-prefetch`. On iCloud optionally sets local `com.apple.fileprovider.pinned` on the remote file when `cache.keepRemoteDownloaded`. |
| `evict <app>... [--remote-local-copy] [--force]` | Drop cached image (refuses if mounted/pinned without `--force`). `--remote-local-copy`: also `evictUbiquitousItem` the repo file. |
| `gc [--dry-run] [--remote]` | Enforce quota/min-free (LRU), drop orphan caches/partials, recover stale mounts/journals. `--remote` (v2, not MVP): move unreferenced old images to `trash/`, purge trash > 30 days. |
| `restore <app> [--permanent]` | Restore-mode session (or permanent) via the journaled transaction (§5.8). Without `--permanent` the stub is reinstated after quit. |
| `unpack <app> [--to <dir>]` (alias `rehydrate`) | Permanently put the real app back (stub removed), keep image in repo unless `--delete-remote`. Used for "refresh": `unpack` → update app → `pack`. |
| `stub rebuild <app>\|--all [--sign-identity <id>]` | Regenerate stub(s) from the manifest (e.g. new Mac, new launcher version). |
| `hooks list\|edit\|enable\|disable <app>` | Manage user hooks (§5.5). |
| `doctor [--fix]` | Checks: config, backend reachable, iCloud signed in + Optimize Storage, free space, `hdiutil` present, stale mounts, lock files, LS registration of stubs, conflict copies, stub ↔ manifest consistency, isenough path in stubs. `--fix` performs safe repairs. |
| `serve [--port 47256] [--print-token]` | HTTP/JSON API + web UI on 127.0.0.1 (§2.3, §10). |
| `daemon install\|uninstall\|status` | Manage the LaunchAgent plist `~/Library/LaunchAgents/io.github.s546126.256isenough.daemon.plist`. |
| `trust <app> [--team-id <id>\|--cdhash <h>]` | Approve a new signing identity for an app (TOFU, §10). |
| `version` | Prints version + schema versions. |

Exit codes (stable, documented in `isenough --help`):
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
Pure `enum AppState` in `IsenoughCore/Lifecycle` with an explicit transition table (illegal transitions throw → bug):

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
1. **Lock**: `L0(sh)` then `L1 = flock(locks/app/<appId>.lock, LOCK_EX)` (§5.6). Run per-app recovery first (roll forward/back any open
   journal for this app, §5.8; adopt a dead owner's session, §5.6). If a session exists and its owner is alive →
   **join-session path** (§5.6.3) and return.
2. **Resolve image**: `state.apps[appId].imageId` (pinned version), else catalog `latest`. Read manifest.
3. **Ensure cached** (holding `L2 = locks/image/<imageId>.lock` from here through step 4's attach decision):
   a. If cache entry complete and file size matches: optionally re-hash if `verifiedAt` older than 30 days or file
      mtime changed (fast path otherwise: size+mtime+inode check). 
   b. Else **reserve** capacity for `peakBytes` via LRU planner + reservation (§6.1); fail `EX_NOSPACE`.
      The reservation is released (or shrunk to the final file size) when the fetch completes or fails.
   c. **Fetch** (`Fetcher`): backend-specific ensure-local (iCloud: start download + wait until `.current` and
      allocated size ≥ logical size) then copy remote → `cache/partial/<imageId>.dmg.part` streaming with sha256
      computed during copy (`get(range:)` with resume from `.part` size for range-capable backends). Progress
      events → `events.jsonl` + stub progress window.
   d. **Verify**: sha256 == manifest; size == manifest. Mismatch → move file to `cache/bad/`, re-fetch once,
      then `EX_INTEGRITY`.
   e. **Convert** (always; `cache.localFormat` ∈ {`ULFO`,`UDRO`}, §3.6): `hdiutil convert -format ULFO|UDRO` from
      the verified `.part` to `partial/<imageId>.<fmt>.dmg.tmp`, `fsync`, record `localSha256`, `rename` into
      `images/`, delete the ULMO copy. ENOSPC/timeout → delete the `.tmp`, keep nothing half-written. (Cost: one-time
      CPU per fetched version; justified because LZFSE/uncompressed blocks decode much faster on random access at app
      launch than LZMA, and launches outnumber fetches.)
   f. Mark `cached`; optionally evict the iCloud local copy of the repo file if it was dataless before we
      started (restore original state; don't keep two copies) unless `keepRemoteDownloaded` or user-pinned in Finder.
4. **Attach** (mount mode, under L2(img)): re-check the cache file is present and verified (evict cannot interleave,
   §5.6.2) and not dataless; check `hdiutil info -plist` for an existing attachment of this image path (canonical
   realpath) → reuse only if its mountpoint is our `mnt/<imageId>` and it is recorded as ours or adopted (§5.6.4);
   an attachment elsewhere → `EX_BUSY` with a message (we never detach images we don't own); else
   `hdiutil attach -plist -readonly -nobrowse -noautoopen -noverify -owners on -mountpoint <cache>/mnt/<imageId> <image>` (`-noverify` OK: we verified sha256; `hdiutil verify` runs once at
   pack). Parse plist → `devEntry`, `mountPoint`. Record mount in state **before** releasing lock. Verify
   `<mnt>/<appPathInVolume>` exists and its `CFBundleIdentifier` == manifest bundleId and (first launch after fetch)
   signing teamId/cdhash == manifest (`SecStaticCodeCheckValidity` with designated requirement), else detach and
   `EX_INTEGRITY`.
   **Restore mode** instead: run the journaled **restore-in** transaction (§5.8.2): it extracts the app from the
   mounted image into a same-volume staging dir, parks the stub *next to it* (same volume), swaps, verifies, and
   detaches the image. The restore session's usage root is the restored path (§5.9).
5. **User pre-launch hooks** (§5.5). Non-zero exit / timeout → **full rollback** of everything this supervisor did,
   in reverse order: restore mode → journaled restore-out (§5.8.3; nothing was launched, so no update check is
   needed beyond the cdhash compare); mount mode → `lsregister -u` + detach (if we attached). Then `EX_HOOK`.
   The rollback itself is journaled, so a crash during it is completed by recovery.
6. **Open**: preflight that no *other* instance of the target bundle id is running from outside our usage root
   (`NSRunningApplication.runningApplications(withBundleIdentifier:)` → `bundleURL`/`executableURL`); if one exists
   (e.g. a kept original or second copy) → do not forward to it: alert "Foo is already running from <path>; quit it
   first" and `EX_BUSY` (after rollback as in step 5). Then `NSWorkspace.openApplication(at: realApp,
   configuration: {activates: true, promptsUserIfNeeded: true, createsNewApplicationInstance: false})`; documents
   via `open([docURLs], withApplicationAt: realApp)`, URLs via `open([url], withApplicationAt: realApp)`.
   **Verify identity** of every returned `NSRunningApplication`: `bundleURL` realpath == realApp realpath and
   `proc_pidpath(pid)` under the usage root; mismatch → treat as a reused wrong-path instance (alert, `EX_LAUNCH`,
   no lease; we roll back our mount if no process uses it). Add **lease** (pid + start time). Ack forwarded
   batches to the stub (§8.3). Release the per-app lock. State `running`.

### 5.3 Watch
- Primary: `NSWorkspace.didTerminateApplicationNotification` for each leased pid; secondary: `kqueue EVFILT_PROC
  NOTE_EXIT` (works without a run loop; used in tests). Leases use (pid, start time) so pid reuse is detected.
- On main pid exit: remove lease; then run the **usage probe** for the session's mode-specific usage root (§5.9)
  every 5 s, with an open-file pass every 30 s. A probe that fails or is incomplete (EPERM on some pids, `lsof`
  missing/timeout) yields `unknown`, which is treated exactly like `busy`. A new process under the usage root
  (Dock relaunch of the real app while idle) becomes a lease; state stays `running`.
- All probes `clean` twice in a row (≥5 s apart) → state `idle`, `detachAfter = now + detachDelaySeconds` (120 s).

### 5.4 Post-quit hook
1. Wait until `detachAfter`. A joining supervisor (§5.6.3) extends/cancels the deadline under the app lock, so the
   owner re-reads `detachAfter` after it acquires the lock in step 2.
2. Take per-app lock. Re-read session (deadline, leases); re-probe usage; if busy/unknown → release lock, back to
   watch.
3. Mark session `detaching` in state (under lock). From here until step 6 any joiner waits on the lock and then
   finds no session (it mounts again).
4. **User post-quit hooks** (§5.5), env `ISENOUGH_EXIT_STATUS` = `crash` if a crash report for the leased pid appears
   in `~/Library/Logs/DiagnosticReports` within 5 s, else `unknown`. We do not promise numeric exit codes: a
   non-child app's status is not observable via NSWorkspace/`NOTE_EXIT` without being its parent. Failures logged.
5. Mount mode: `lsregister -u <mnt>/<app>`; `hdiutil detach <devEntry>` (only if the attach-time `devEntry` +
   image-path ownership still matches, N4); on busy retry with backoff 5,10,20,40… s up to `detachRetryMaxSeconds`
   (between retries the lock is released and the probe re-run; a relaunch wins). Then `forceDetachAfterSeconds > 0`
   → `-force`, else mark `stuck` + notify; the next owner (gc/supervisor/daemon) retries.
   Restore mode: run the journaled **restore-out** transaction (§5.8.3), which inspects for changes *before* any
   removal and retains changed bundles.
6. Update state: remove session/mount, `lastUsedAt = now` for app and cache entry, `launchCount++`; device file write
   queued (best effort, outside the lock).
7. **Release the app lock**, then run the quota pass (§6), which takes locks in global order itself (§5.6.2). The
   quota pass never evicts what we just used unless it alone exceeds quota.
8. Supervisor exits 0.

### 5.5 User-defined hooks
- Locations (local wins over shared, both run if both exist — local first):
  - local: `~/Library/Application Support/256isenough/hooks/<bundleId>/{pre-launch,post-quit}` and
    `…/{pre-launch.d,post-quit.d}/*` (lexical order); global `hooks/_all/…` applies to every app.
  - shared (repo, **v2**; designed now, not in MVP): `<repoRoot>/hooks/<bundleId>/…` — **disabled by default**; enabled per-app with
    `isenough hooks enable <app> --shared --sha256 <hash>` which pins the exact content hash (a modified shared
    script is refused until re-approved). Rationale: the repo is synced from other devices (§10).
- Must be regular files, owned by the user, not group/world-writable, executable. Run with `Process`, no shell,
  `cwd` = hook dir, stdin `/dev/null`, timeout `hookTimeoutSeconds` (SIGTERM then SIGKILL after 5 s).
- Environment contract (also documented in README):
  `ISENOUGH_PHASE` (`pre-launch`|`post-quit`), `ISENOUGH_APP_ID`, `ISENOUGH_BUNDLE_ID`, `ISENOUGH_IMAGE_ID`, `ISENOUGH_VERSION`,
  `ISENOUGH_MODE`, `ISENOUGH_APP_PATH` (real app path, mounted or restored), `ISENOUGH_MOUNT_POINT`, `ISENOUGH_SESSION_ID`,
  `ISENOUGH_EXIT_STATUS` (post-quit: `crash`|`unknown`), `ISENOUGH_STATE_DIR`, `ISENOUGH_ARGS_FILE` = path of a 0600
  JSON file `{"documents":[...],"urls":[...],"arguments":[...]}` (arrays, since file names may contain newlines;
  N6). `ISENOUGH_DOCS`/`ISENOUGH_URLS` are not provided.
- Pre-launch non-zero → abort launch (`EX_HOOK`), stdout/stderr tail shown in stub alert. Post-quit failure → log.
- Typical uses: restore an app-data archive (v2), set `defaults` keys, start/stop a companion service, mount a
  data volume, notify.

### 5.6 Concurrency, locking and capacity (B3)

#### 5.6.1 Lock objects
All locks are `flock(2)` on files under `locks/` (released by the kernel on process death → no stale locks).
Owner identity for anything that *outlives* a lock (sessions, reservations, journals) is (pid, process start time
from `proc_pidinfo`), so pid reuse cannot impersonate an owner.

| Lock | Scope | Held across |
|---|---|---|
| `L0 = locks/global.lock` | shared (`LOCK_SH`) by every mutating command; exclusive only for `state.json` rebuild after corruption and for `doctor --fix` structural repairs | exactly as long as the command holds any L1/L2 (a supervisor drops L0 together with L1 while the app runs) |
| `L1 = locks/app/<appId>.lock` | exclusive; everything that changes the app's stub, restored bundle, session, mount, or its cache entries | the command's critical phase (may be released while waiting, see below) |
| `L2 = locks/image/<imageId>.lock` | exclusive; the image's `.part`, conversion `.tmp`, `images/` file, `bad/` copy | fetch+verify+convert, evict of that file, attach decision |
| `L3 = state.lock` | exclusive; read-modify-write of `state.json` incl. reservations | short sections, never slow I/O or other locks acquired inside |

**Global order (deadlock freedom):** `L0(sh) → L1 in ascending appId order → L2 in ascending imageId order → L3`.
A process never acquires a lock that sorts *before* one it already holds; to need an earlier lock it releases
everything and restarts the operation (all steps are idempotent/journaled). Repo-backend writes and user hooks run
holding at most L1. Long waits (download, detach backoff, user decision, delay timer) are done **without** L2/L3.

#### 5.6.2 Lock table per command
| Operation | Locks | Notes |
|---|---|---|
| launch / `hook launch` (owner) | L1(app) → L2(img) for fetch/convert/attach → release L2 → hold L1 through open; released while running | cache-file check and attach happen under the same L2 hold, so evict cannot slip in between |
| join (second supervisor, forward-only) | L1(app) | §5.6.3 |
| post-quit / detach | L1(app) (+ L2(img) for the cache entry update); quota pass after releasing L1 | §5.4 |
| `prefetch`, `pin` | L1(app) briefly to resolve image → release → L2(img) for fetch/convert | no session interaction; a concurrent launch blocks on L2 and then finds the file cached |
| `evict <app>` | L1(app) → L2(img) | refuse if session/mount/restored/`needsResolution` (`EX_BUSY`) |
| `gc` / quota pass | plan under L3 (snapshot) → for each victim in order: try-lock L1(app) **non-blocking**, then L2(img), re-check predicate, delete, update state under L3 | skips busy victims (never waits on an app lock while holding another); retries plan once |
| `unpack`, `restore --permanent`, `stub rebuild` | L1(app) (+ L2 for attach/extract) | journaled (§5.8) |
| `pack` | L1(newAppId) + L2(new imageId) | journaled (§5.8.5) |
| recovery / adoption | L1(app) | §5.6.4 |
| `serve` handlers | delegate to the same engine operations | the daemon holds no locks while idle |

#### 5.6.3 Joining a live session (second stub, document drop, relaunch at deadline)
A second supervisor acquires L1, finds a session with a live owner, and in the same critical section:
(1) sets `session.joinPending += 1` and `detachAfter = null` (cancels any idle timer); (2) forwards docs/URLs to the
*verified* running instance (identity check of §5.2.6) or, if no app process is running (session `idle`), opens
the real app from the session's real path and adds the returned pid as a lease **itself** (writing the lease under
L3 while holding L1); (3) decrements `joinPending`, releases L1, acks the batch to its stub, exits. The owner always
re-reads the session after acquiring L1 (§5.4.2), so the handoff is synchronized by the lock, not by polling.
A session in `detaching` is not joinable: the joiner waits for L1 and then performs a full launch.
Cancelling a joiner (stub Cancel/SIGINT) only aborts the joiner's own forwarding; it never touches the session.

#### 5.6.4 Recovery and adoption (one adopter)
Recovery for an app runs only while holding L1(app). The adopter re-reads the session under L3; if the recorded
owner (pid+start time) is alive → not orphaned, stop. Otherwise it atomically rewrites `owner` to itself (under L3,
still holding L1) and becomes the watcher/post-quit runner. Any other caller then sees a live owner. Image
ownership is verified before adoption: the attached `devEntry` must map to our cache image path (`hdiutil info`)
*and* its mountpoint must be our `mnt/<imageId>`; an attachment of the same image path mounted elsewhere is reported
but never detached (N4). Open journals (§5.8) are completed before session adoption.

#### 5.6.5 Other notes
- **Two Macs**: no shared mutable files except catalog (derived, last-writer-wins safe) and each own device file.
- **Real app launched outside our stub** (Spotlight hit while mounted, Dock pinned the mount path): `-nobrowse`,
  post-quit `lsregister -u`, `doctor` offers to replace Dock entries pointing into `mnt/` with the stub. A process
  launched this way still lies under the usage root and therefore counts as a lease.

### 5.7 Sequence diagram
```mermaid
sequenceDiagram
    actor U as User
    participant S as Stub (isenough-stub)
    participant V as Supervisor (isenough hook launch)
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
    A-->>V: pid (lease, identity verified)
    V-->>S: ack(batch) + ready; S drains queue, waits acks, exits
    U->>A: uses app … quits
    A-->>V: didTerminate / NOTE_EXIT
    loop every 5 s
        V->>V: probe processes/open files under mnt
    end
    V->>V: idle; wait detachDelay (cancel on relaunch)
    V->>V: lock; detaching; user post-quit hooks
    V->>H: lsregister -u realApp; detach devEntry (retry on busy)
    V->>C: lastUsedAt=now, launchCount++; unlock; LRU quota pass
    V->>B: put devices/<deviceId>.json (best effort)
```

### 5.8 Crash-safe swaps: write-ahead journal (B2)

Every operation that moves an `.app` bundle (pack's final install, restore-in, restore-out, `unpack`,
`restore --permanent`, `stub rebuild` install) is a **transaction** with a write-ahead journal
`journals/<txid>.json` (`{"schema":"tx/1","txid","kind","appId","owner":{pid,start},"phase","paths":{…},
"expect":{…},"createdAt"}`).

#### 5.8.1 Rules
- **WAL before effect.** Before each filesystem mutation the journal is rewritten with the *next* phase and all
  paths involved (atomic temp + `fsync(file)` + `rename` + `fsync(journals/)`). After the mutation, the affected
  parent directories are `fsync`ed. Recovery therefore always knows where every bundle is or may be.
- **Same-volume staging.** All staging lives in a hidden directory next to the destination:
  `<dest-parent>/.256isenough-staging/<txid>/` (e.g. `/Applications/.256isenough-staging/…`). Moves into/out of the
  destination are `rename(2)`/`renamex_np` within one volume and therefore atomic. Copies across volumes (image →
  staging via `ditto`) happen only into staging and are followed by verification before any rename. The
  `parked/` directory in Application Support is no longer used.
- **Idempotent phases.** Each phase checks the observable postcondition first (e.g. "staging/app exists and its
  cdhash == expected") and skips if already done; recovery re-runs the current phase, then continues forward or
  rolls back as the table says. Rollback is itself a sequence of journaled phases.
- **Preflight before any change (N5).** Parent directory writable by the user, destination not root-owned/SIP,
  enough space on the destination volume for the extracted app (+10 %), no running process of the bundle id. If
  `/Applications/Foo.app` is not user-writable (e.g. root-owned MAS install), we **refuse before changing anything**
  (`EX_UNSUPPORTED`, message tells the user to move it via Finder, which asks for admin auth, and retry). No helper.
- **Never delete the only copy.** A bundle is deleted only if (a) it is the stub (regenerable from the manifest), or
  (b) it is byte-identical to an image in the repo: its cdhash *and* a tree hash (sha256 over sorted relative paths,
  modes, symlink targets, file contents; computed by `BundleHasher`) equal the values recorded in the manifest
  (`app.treeHash`, new field computed at pack) **and** that image is present in the local verified cache or
  confirmed uploaded. Otherwise the bundle is moved to `retained/<appId>/<ts>-<name>.app` (same volume when possible;
  else kept in staging) and recorded as `needsResolution`.
- **Supervisors never prompt and never block on a user decision.** A decision is recorded (`needsResolution`, event,
  GUI/daemon notification, and `status`/`doctor` output); the user resolves with `isenough resolve <app> --keep-updated|--discard|--keep-both`
  (CLI/GUI). Until resolved, the stub launches the retained bundle (restore-in from `retained/` instead of the image).

#### 5.8.2 restore-in (pre-launch, restore mode)
| Phase | Effect (after journaling the phase) | Recovery if crashed in/after this phase |
|---|---|---|
| `prepared` | preflight; `mkdir staging/<txid>` | remove staging; done |
| `extracted` | `ditto <mnt>/<app> staging/app.new`; verify cdhash + tree hash == manifest; detach image | if `app.new` unverified → delete it, rollback |
| `stubParked` | `rename(<dest>, staging/stub.app)` | if `<dest>` missing and `stub.app` present → continue/rollback by renaming back |
| `installed` | `rename(staging/app.new, <dest>)`; `fsync` parent; `lsregister -f <dest>` | forward: launch path; rollback: run restore-out |
| `active` | session recorded, journal stays open for the session lifetime | adoption (§5.6.4) |

#### 5.8.3 restore-out (post-quit, hook-failure rollback, recovery)
| Phase | Effect | Recovery |
|---|---|---|
| `quiesced` | usage root clean twice (§5.9) — else stay `active` and keep waiting/retrying (never forced) | re-probe |
| `inspected` | compute cdhash + tree hash of `<dest>`; record `changed: bool` in journal | recompute |
| `appMoved` | `rename(<dest>, staging/app.old)` | if `<dest>` empty and `app.old` present → continue |
| `stubBack` | `rename(staging/stub.app, <dest>)`; `lsregister -f`; `lsregister -u` old real path | continue |
| `disposed` | unchanged → delete `app.old` (rule "never delete only copy" satisfied); changed → move to `retained/`, set `needsResolution`, event `app.updated` | continue |
| `closed` | remove staging + journal | — |

If the stub copy in staging is missing/corrupt at `stubBack`, a new stub is built from the manifest first (stubs
are always regenerable). `isenough resolve --keep-updated` runs `pack` on the retained bundle (new image, upload
confirmed per §7.2) and only then deletes it; `--discard` moves it to the Trash (user-recoverable), never `rm`.

#### 5.8.4 Self-updating apps in mount mode
Mount images are read-only, so in-place updates fail; updaters that instead write a new copy elsewhere (e.g. to
`/Applications` or `~/Applications`) produce an untracked bundle. `doctor` detects a bundle with the target bundle id
outside our control and offers `pack` refresh; we never delete it automatically.

#### 5.8.5 pack and unpack transactions
pack: `inspected → imaged (staging dmg, verify) → uploaded (put + manifest + catalog; wait upload unless
--no-wait-upload) → stubBuilt (stub signed in same-volume staging) → swapped (rename original → staging/orig.app,
rename stub → dest) → originalDisposed (Trash or --keep-original; Trash does not free space until emptied — reported,
N3) → closed`. A crash before `swapped` leaves the original untouched; after it, recovery finishes or reverses by
renames. unpack: `extracted (from cache/image to staging, verified) → stubParked → installed → stubDeleted → closed`.

#### 5.8.6 Fault-injection tests
`TxRunner` takes an injectable `FaultPoint` (`beforeJournal(phase)`, `afterJournal(phase)`, `afterMutation(phase)`,
`hookFailure`, `selfUpdate(simulated tree change)`). Engine tests (fake FS on Linux; real APFS on macOS CI) enumerate
**every** fault point of every transaction, kill the runner there (throw + abandon, and on macOS a real `kill -9`
of a child runner), run recovery, and assert the invariant: exactly one of {stub, real app} at `<dest>`, no bundle
lost (each original/updated bundle exists at dest, in staging, or in `retained/`), journals closed, and recovery is
idempotent (running it twice is a no-op).

### 5.9 Process ownership and usage roots (B4)

| Mode | Usage root(s) watched | Detach/cleanup gate |
|---|---|---|
| mount | `<mnt>` (realpath) | mount clean → detach |
| restore | `<dest>` (the restored bundle realpath) **and** its `.256isenough-staging/<txid>` dir | root clean → restore-out (§5.8.3) |
| translocated | not supported in MVP: quarantined bundles are refused at pack (§1.5). If at runtime a leased process's `proc_pidpath` lies under `/private/var/folders/*/AppTranslocation/` or any path outside the usage root, the launch is treated as a wrong-path instance (no lease, `EX_LAUNCH`, alert explaining `xattr` recovery) and the image stays mounted until that process exits (it may be backed by our image) | probe also checks for any process whose open files include our image file or devEntry |

**Probe** (`ProcessProbe.usage(root) -> clean | busy([pids]) | unknown(reason)`):
1. Executables: `proc_listallpids` + `proc_pidpath` for every pid; any path under a root → busy. A pid whose path
   cannot be read (EPERM other than for root-owned system processes we know cannot map our files) → `unknown`.
2. Open files / cwd / mapped files: `lsof -Fpn -- <root>` used as a **filesystem/mount selector** for mount mode
   (all files on that mounted filesystem; not `+D` recursion), and `lsof -Fpn +D <root>` limited to the bundle for
   restore mode (bundles are small); plus `lsof -Fpn -- <imagePath> <devEntry>` for the backing image. `lsof`
   non-zero for reasons other than "no matches", timeout (10 s), or absence → `unknown`.
3. Helpers that do not execute from the root but hold a data file inside it are caught by (2). Helpers registered
   with launchd from a restored bundle (login items/agents in restore mode) are additionally checked with
   `launchctl print gui/$UID` for program paths under the root → busy.
`unknown` ≡ busy: cleanup waits and retries (backoff to 5 min, indefinitely), state shows `waiting(unknown)` and
`doctor` explains which probe failed. Restored bundles are **never** removed while busy/unknown; there is no force
option for restore cleanup.

**Identity of launched instances:** each lease stores `{pid, start, bundleURL, executablePath}` checked at open
time (§5.2.6) and on every probe; NSWorkspace returning an existing instance of the bundle id from another path is
detected and rejected. Kept originals (`--keep-original`) are renamed `Foo.256orig.app` *and* moved into
`retained/` so LS does not prefer them; `doctor` and e2e check that LS's URL-for-bundle-id resolves to a path under
our usage root during a session.

---

## 6. Cache & LRU

- **Location**: `~/Library/Caches/256isenough/` (configurable): `images/` (verified, ready), `partial/` (`.part` +
  `.part.json` resume metadata: imageId, expected size/sha, bytes, partial hash state is *not* persisted → on resume
  we re-hash the existing prefix), `bad/` (quarantined mismatches, deleted by gc after 7 days), `mnt/` (mountpoints).
  `~/Library/Caches` is excluded from Time Machine by convention; we also set `NSURLIsExcludedFromBackupKey`.
  The cache must be on the internal APFS Data volume (doctor warns otherwise).
- **Accounting**: `used = Σ allocated size of images/ + partial/` (use `totalFileAllocatedSize`, not logical size).
- **Quota** `quotaBytes` (default 20 GiB) and **free-space floor** `minFreeBytes` (default 15 GiB, read via
  `volumeAvailableCapacityForImportantUsageKey`).

### 6.1 Peak budget and atomic reservations (B3, N3)
- **Peak bytes of a fetch** `peak = M + C + L` where `M` = iCloud materialization of the repo file (= remote size
  if it was dataless, else 0; lives on the same Data volume), `C` = independent ULMO copy in `partial/` (= remote
  size), `L` = local image estimate (`UDRO`: `app.unpackedSize` + 5 %; `ULFO`: max(2 × remote size,
  `app.unpackedSize` × 0.8) – deliberately pessimistic; the real ratio is learned per image and stored). After
  conversion, the reservation shrinks to the allocated size of the final file and `M` is released by evicting the
  repo local copy (when allowed, §6 "Interaction with iCloud evict"). Restore/unpack reserve the extracted size on
  the destination volume; pack reserves `unpackedSize` (staging) + image size. Moving an original to the Trash frees
  nothing until the Trash is emptied; `pack` reports that and never counts it as reclaimed.
- **Reservation protocol**: under L3, compute `reserved = Σ live reservations`, then
  `need = max(0, used + reserved + peak − quota, peak + reserved − (free − minFree))`. If `need > 0`, the planner
  selects victims (excluding anything locked, mounted, reserved, pinned, `needsResolution`); the process releases L3,
  deletes victims via the gc protocol (§5.6.2, try-lock), and retries the reservation (max 3 rounds) → `EX_NOSPACE`
  with the plan in `details`. The reservation `{owner pid+start, bytes, purpose}` is written to `state.json` before
  any byte is downloaded; it is released on success/failure and reaped when its owner is dead. Two simultaneous
  fetches of different apps therefore cannot both pass the same free-space check.
- **ENOSPC** during copy/convert despite the reservation (other programs consumed space): delete the `.part`/`.tmp`,
  release the reservation, `EX_NOSPACE`; never leave half-converted images in `images/`.
### 6.2 Eviction, pins, versions, iCloud interaction
- **Eviction algorithm** (`planEviction`, pure, deterministic for tests):
  1. Candidates = cache entries that are complete, not mounted, not part of an active session, not pinned,
     not reserved/being fetched, not locked (try-lock fails), not belonging to an app with `needsResolution`.
  2. Order: orphans first (image not referenced by any app in state/catalog or superseded versions), then by
     `lastUsedAt` ascending (LRU), tie-break larger size first, then imageId.
  3. Take until `need` satisfied. If impossible → `EX_NOSPACE` with the plan in `details` (UI suggests unpinning).
  Pinned images may exceed quota (warning in `status`/`doctor`).
- **When**: before fetch (reservation), after each session ends (post-quit step 7, after releasing the app lock), `gc`, daemon every 6 h, and on
  low-disk notification (daemon, v1).
- **Pinning**: `pin` = never auto-evict locally + prefetch now + daemon re-prefetches pinned images when missing
  (e.g. new version packed on another Mac). Independent of Finder "Keep Downloaded" (which is an xattr on the
  *repo* file, single-device, undocumented): we only set it when `keepRemoteDownloaded` is true.
- **Versions**: when a newer image becomes `latest`, the old cached one becomes an orphan candidate after the app
  next uses the new one. `apps[*].imageId` pins a version explicitly (`isenough launch --image <id>` / `pin --version`).
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

### 7.1 Protocol (`IsenoughCore/Backend`)
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
  func put(_ path: String, from source: URL, progress: @Sendable (Int64) -> Void) async throws  // see publication rule
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

**Publication rule (N2).** `put` is atomic only when `capabilities.atomicPut`; otherwise it uploads to a temp name
and *publication* is defined by the manifest: an image is visible only after its manifest is written, and a
manifest is written only after `stat` (and server hash or a full re-read hash when available) confirms the image.
Readers ignore images without manifests. Resumed ranged reads must match the original `etag`/size (else restart);
a `200` reply to a `Range` request means "full body" → restart the `.part` from 0. Redirects to other hosts strip
`Authorization`. Repo paths are validated (no `..`, absolute, or symlink escaping the root via `realpath`). Name
collision of `<sha8>` with different content → extend to 16 hex, then full hash; never overwrite.

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
    MacOS/isenough-stub                       universal (arm64+x86_64) launcher, identical bytes for every stub
    Resources/
      <iconFile>.icns / Assets.car         copied from the real app (and doc-type icons)
      stub.json                            {"schema":"stub/1","appId":"com.blender.blender","imageId":"…",
                                            "isenoughPath":"/Users/me/.local/bin/isenough","stubVersion":1,"createdAt":"…"}
      <lang>.lproj/InfoPlist.strings       only CFBundleName/CFBundleDisplayName/CFBundleSpokenName
    _CodeSignature/
```
Built in the same-volume staging dir (`<dest-parent>/.256isenough-staging/<txid>/`), signed, verified, then
installed by the journaled pack/rebuild transaction (§5.8.5): `renamex_np(RENAME_EXCL)` when the destination is free,
`RENAME_SWAP` when replacing an existing stub. The real app is moved to the Trash via `FileManager.trashItem`
(undoable), or with `--keep-original` moved to `retained/` (not left next to the stub, so LS cannot pick it, §5.9).

### 8.2 Info.plist transform (pure function `StubPlist.make(original:, manifest:) -> [String: Any]`, unit-tested)
Start from the original Info.plist, then:
- `CFBundleIdentifier` = `<orig>.256stub`; keep `CFBundleName`, `CFBundleDisplayName`, `CFBundleShortVersionString`,
  `CFBundleVersion` (so Finder shows the real version), `CFBundleIconFile`/`CFBundleIconName`, `LSMinimumSystemVersion`
  = `"13.0"` (= SwiftPM deployment target, N5), `CFBundleDocumentTypes`, `CFBundleURLTypes`, `UTExportedTypeDeclarations`,
  `UTImportedTypeDeclarations`, `NSHumanReadableCopyright`, `LSApplicationCategoryType`.
- Set `CFBundleExecutable = "isenough-stub"`, `CFBundlePackageType = "APPL"`, `LSUIElement = true` (no Dock tile for
  the stub itself; the real app gets its own), `NSHighResolutionCapable = true`,
  `IsenoughTargetBundleIdentifier = <orig>`, `IsenoughImageId`, `IsenoughStubVersion`.
- In each document type set `LSHandlerRank = "Alternate"` unless it was `Owner` for a type the real app owns
  exclusively (keep `Owner`), so the stub doesn't steal defaults from other installed apps; `CFBundleTypeRole` kept.
- Remove: `NSPrincipalClass`, `NSMainNibFile`, `NSMainStoryboardFile`, `LSEnvironment`, `LSBackgroundOnly`,
  `LSRequiresNativeExecution`, `LSArchitecturePriority`, `CFBundleExecutable*` variants, `SU*` (Sparkle),
  `ElectronDefaultApp`, `NSAppleScriptEnabled`, `OSAScriptingDefinition`, `NSServices`, `NSExtension*`,
  `SMPrivilegedExecutables`, `SMAuthorizedClients`, `NS*UsageDescription` (stub needs no TCC), `LSFileQuarantineEnabled`,
  `CFBundleHelpBookName/Folder`, `NSUserActivityTypes`, `NSDockTilePlugIn`.
- Rationale for unique bundle id: real app keeps its own LS/TCC identity; Playpen's same-id approach mixes TCC/LS.

### 8.3 Launcher binary (`isenough-stub`, AppKit, no storyboard)
- `NSApplication` with delegate; `setActivationPolicy(.accessory)` (needed to show the progress window). SIGPIPE is
  ignored (`signal(SIGPIPE, SIG_IGN)`) in both the stub and the supervisor; writes check `EPIPE`.
- Receives events: `application(_:open urls:)` (files = `odoc`, other URLs = `GURL`; split by `isFileURL`) and
  `applicationDidFinishLaunching` (`oapp`; extra `CommandLine.arguments` forwarded as `arguments`).
- **Request protocol (B5).** The stub spawns **one** supervisor: `isenough hook launch --app <appId> --stub <path>
  --control-fd 3` via `posix_spawn` + `POSIX_SPAWN_SETSID`; fd 3 is a socketpair (bidirectional, NDJSON). No
  documents are passed on argv. Messages:
  - stub → supervisor: `{"type":"open","req":<n>,"documents":[…],"urls":[…],"arguments":[…]}` — every Apple Event
    batch (initial batch after a 300 ms coalescing window, then any later events immediately) gets a new `req` id;
    `{"type":"cancel"}`; `{"type":"bye"}` (no further requests).
  - supervisor → stub: `{"type":"progress",…}`, `{"type":"ack","req":n,"status":"delivered"|"error","code":…,
    "message":…}`, `{"type":"ready"}` (app running; the owner remains), `{"type":"done"}` (after `bye`, all acks sent).
  - Before `ready` the supervisor queues batches; after attach/open it delivers them in order (first batch via
    `openApplication`+`open(urls…)`, later ones via `open(urls, withApplicationAt:)` on the verified instance) and acks
    each **after** NSWorkspace's completion handler returns without error.
- **Drain before exit.** The stub keeps `outstanding = sent − acked`. After `ready` it waits a 500 ms quiet period;
  if no event arrived and `outstanding == 0`, it sends `bye`, waits for `done` (≤ 5 s), and terminates. Events
  arriving during the quiet period/`bye` handshake are sent first (supervisor accepts until it processes `bye`).
  An event delivered by macOS after the stub decided to exit is impossible to lose: AppKit only delivers events
  while the run loop runs, and the stub stops the run loop only after `done`; any later Apple Event relaunches the
  stub, which then joins the session (§5.6.3).
- **Errors**: an `ack` with `status:"error"` → `NSAlert` for that batch (other batches unaffected). If the supervisor
  dies before acking (socket EOF), the stub alerts with the last stderr lines, listing undelivered items.
- **Disconnect safety.** The supervisor treats EOF/EPIPE on fd 3 as "client gone": it stops all progress writes,
  keeps running the session normally, and logs undelivered acks. Closing or killing the stub therefore never affects
  the app or the session.
- **Cancel** (progress panel button): stub sends `{"type":"cancel"}`. An owner that has not yet launched the app
  aborts and rolls back (journaled, §5.2.5); once the app is running, cancel is ignored. A joiner's cancel only
  aborts its own pending forwarding (§5.6.3). The stub never sends signals to the supervisor.
- UI: no window if `ready` arrives < 700 ms; otherwise a small floating panel "Fetching Blender from iCloud…
  (412 MB)" with progress and **Cancel**. If `isenough` not found: alert "256isenough is not installed (isenough missing)".
- Size target: < 300 KB universal. Built by SwiftPM, `lipo`'d universal in release CI.

### 8.4 Signing
- The stub is signed **after** all files are written: `codesign --force --sign <identity> --options runtime
  --timestamp(=none for ad-hoc) <tmp.app>` then `codesign --verify --strict <tmp.app>`. Never `--deep`, never touches
  the real app (it isn't inside the stub). Pre-sign: `removexattr` of `com.apple.quarantine`, FinderInfo, resource
  forks on stub files only (stub files are ours).
- Identity: `pack.signIdentity` — default `-` (ad-hoc; fine for one user on one Mac). Recommended for the user:
  `Developer ID Application: … (TEAMID)` — stable designated requirement, survives stub rebuilds. The stub needs no
  TCC permissions (it only spawns `isenough`); the real app gets its own TCC prompts under its own identity.
  Notarization is not needed for locally generated stubs (no quarantine); it is needed for the distributed
  `isenough` release / GUI (v1).
- The `isenough-stub` binary inside the release is pre-signed; `StubBuilder` re-signs the whole stub bundle anyway
  because Info.plist differs per app.

### 8.5 Launch Services registration
- After install: `lsregister -f <stub>` (register/refresh). Stub declares doc/URL types → "Open With" works while the
  real app is offline. `lsregister` is undocumented and treated as best effort (N7): nothing depends on its exit
  status for correctness. Dock pins, default handlers, URL scheme defaults and TCC grants are **not guaranteed** to
  survive the bundle-id change; README ships a manual compatibility checklist (Dock pin, double-click a document,
  open a URL, "Open With", TCC prompts) for every new app class.
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
| sha256/size mismatch | after copy | Move to `cache/bad/`, refetch once; second mismatch → `EX_INTEGRITY`, event + alert "image corrupt in repository; run `isenough doctor`". Never attach unverified bytes. |
| Mounted app identity mismatch (bundle id / team / cdhash) | after attach | Detach, `EX_INTEGRITY`. |
| Attach failure (`hdiutil` non-zero, timeout `attachTimeoutSeconds`) | exit status / plist error | If "image already attached" → resolve existing devEntry and reuse; if corrupt → delete cache entry, refetch once; else `EX_DISKIMAGE` with hdiutil stderr. |
| Real app fails to launch | `openApplication` error, or identity mismatch (§5.2.6) | Roll back as for a hook failure (§5.2.5: detach / journaled restore-out), `EX_LAUNCH`, alert with error. |
| Real app crashes | pid exits; crash report check | Treated as quit (`ISENOUGH_EXIT_STATUS=crash`), normal delayed detach. Event logged. |
| Detach busy | hdiutil exit 16 / "Resource busy" | Backoff retry (§5.4); `stuck` state surfaced; never `-force` unless configured. |
| Supervisor / engine crash | dead owner (pid+start) with session record | **Recovery** at every supervisor start, `gc`, daemon start, per app under L1 (§5.6.4): first complete open journals (§5.8), then reconcile `state.mounts` with `hdiutil info -plist`: (a) attached with our image path *and* our mountpoint but not in state → adopt; (b) in state but not attached → drop record; (c) dead owner → single adopter elected under L1+L3: watch if busy/unknown else post-quit. Same image attached elsewhere → report only. `status` is read-only and never recovers. |
| Corrupt `state.json` | JSON decode error | Move to `state.json.corrupt-<ts>`, rebuild from cache dir listing + `hdiutil info` + stubs found via `mdfind kMDItemCFBundleIdentifier == '*.256stub'` and `/Applications` scan. |
| Offline, image cached | backend `.unavailable` | Launch works (no backend access needed on cache hit: manifest is cached in `cache/manifests/`). Device-file update deferred. |
| Offline, not cached | `.unavailable` | Fail fast (≤ 5 s probe) `EX_BACKEND`: alert "Blender is not available offline. Pin apps to keep them offline." |
| iCloud not signed in / Drive off | `ubiquityIdentityToken == nil` | `EX_BACKEND` with specific message; `doctor` explains. Cached apps still launch. |
| Disk full | reservation fails (§6.1) or `ENOSPC` during copy/convert | Evict per LRU; if still short → `EX_NOSPACE`, delete `.part`, alert lists pinned images + sizes. |
| Sleep/wake | daemon: `NSWorkspace.willSleep/didWake`; supervisor: same notifications | Downloads: re-check status on wake (stall timer paused during sleep). Mounted images are local files → survive sleep. On wake the supervisor re-probes leases. |
| Logout / shutdown | SIGTERM to supervisor | Supervisor marks state `interrupted` and exits quickly (journals stay open). Images may or may not be detached by the system (N4); the next run reconciles either outcome. |
| Stub moved/renamed by user | stub.json path mismatch | Works (stub passes its own path). `doctor` updates `stubPath`. |
| `isenough` binary moved | stub can't find it | Alert with fix (`isenough stub rebuild --all`); fallbacks in §2.3. |
| Crash during any bundle swap (restore-in/out, pack install, unpack) | open `journals/<txid>.json` | Recovery replays the journaled phase table (§5.8.2–5.8.5) forward or back; never deletes a bundle unless it matches cdhash+tree hash of a cached/uploaded image; otherwise `retained/` + `needsResolution`. |
| Restored app still busy (helper, open data file) after quit | usage probe busy/unknown (§5.9) | Stay `active`, retry with backoff indefinitely; never force; `status`/GUI show which pids hold it. |
| Pack interrupted | pack journal (§5.8.5) | Steps are idempotent; `pack --resume` continues; original app untouched until `swapped`. |

All errors go to `events.jsonl` (`{"ts","level","app","session","phase","code","message"}`) and `logs/isenough.log`.

---

## 10. Security considerations

- **No privilege**: everything runs as the user; no root helper, no sudo, no setuid. Images mount with `-owners on`
  but `nosuid` is enforced by DiskArbitration for disk images.
- **Integrity chain**: manifest sha256 verified before attach; mounted app's bundle id + Team ID + cdhash/DR checked
  against the manifest (first launch after each fetch); Gatekeeper/XProtect still evaluate on `open` as usual. A
  tampered repo (other device or attacker with iCloud access) can at worst supply a different image + matching
  manifest: **trust anchor** = the `signing.teamId` recorded at pack time is also stored locally in
  `state.apps[*].trusted` (schema §3.5) on the device that packed or first approved it; an image whose Team ID differs from the
  locally trusted one requires explicit `isenough trust <app>` (TOFU). Ad-hoc/unsigned apps: cdhash is the identity;
  a new cdhash for such apps requires approval.
- **Shared hooks are code execution**: disabled by default, content-hash pinned when enabled (§5.5). Local hooks must
  be owned by the user and not writable by others.
- **No `-force` detach** by default (prevents SIGBUS/data loss in running apps).
- **Quarantine**: we don't strip `com.apple.quarantine` from the real app; quarantined bundles are refused at pack in
  MVP (§1.5, §5.9) with the manual recovery instruction. Stub files are ours, xattrs cleaned before signing.
  `hdiutil attach` itself is not claimed to perform a Gatekeeper assessment (N5); Gatekeeper evaluates at `open`.
- **Local HTTP API** (`serve`): binds `127.0.0.1` only (never `0.0.0.0`/`::`); authentication per §10.1. No
  endpoint executes arbitrary commands or takes arbitrary file paths except app paths validated to be `.app` bundles
  under `/Applications` or `~/Applications` (pack, v1). Unix-socket transport is a v1 option for CLI↔daemon.

#### 10.1 API authentication protocol (B6)
Two credentials, one per client type; neither is ever placed in a URL.
- **CLI / scripts: Bearer.** `server-token` (256-bit random, base64url) in Application Support, mode 0600, created by
  `serve` on first start. `isenough` reads it and sends `Authorization: Bearer …`. Bearer requests need no Origin.
- **Web UI (Pake WKWebView): pairing → session cookie.** The page shell (`/ui/*` static HTML/JS/CSS, no data) is
  public. On load, `app.js` calls `GET /api/session`; `401` shows a pairing form. The user runs `isenough serve pair`
  (or clicks "Pair GUI" in `isenough daemon status`), which asks the running daemon (Bearer) for a one-time code:
  8 chars Crockford base32, valid 10 min, single use, invalidated after 5 wrong attempts, attempts rate-limited to
  1/s. `POST /api/pair {"code":…}` (Origin-checked) returns `Set-Cookie: isenough_session=<256-bit>; HttpOnly;
  SameSite=Strict; Path=/; Max-Age=34560000` plus a JSON body containing the per-session `csrf` token. The server
  stores only `sha256(sessionId)`, created/last-used time and a label in `server-sessions.json` (0600), so sessions
  survive daemon restarts. `GET /api/session` (cookie) returns `{csrf, expiresAt}` so a reloaded page regains its
  CSRF token (only same-origin JS can read the response: we never send CORS headers).
- **Request checks** (pure functions, unit-tested): valid `Host` values = `127.0.0.1:<port>` and `localhost:<port>`
  (literal match, otherwise `421`); valid serialized Origins = `http://127.0.0.1:<port>`, `http://localhost:<port>`.
  Cookie-authenticated mutating requests must be `POST`, `Content-Type: application/json`, carry an allowed `Origin`
  (absent Origin → reject) and `X-Isenough-CSRF` equal to the session's csrf token (constant-time compare).
  Cookie-authenticated `GET` (incl. SSE) requires valid Host and, if present, an allowed Origin.
  The response to unauthenticated API calls is `401 {"ok":false,"error":{"name":"EX_UNAUTHENTICATED"}}` without
  `WWW-Authenticate` (no browser auth dialog); wrong CSRF/Origin → `403`.
- **SSE**: `GET /api/events` is authenticated by the cookie (native `EventSource` sends same-origin cookies; it
  cannot send headers). Streams are closed when the session is revoked.
- **Rotation/revocation**: `isenough serve rotate-token` (new Bearer token; CLI rereads the file), `isenough serve sessions
  list|revoke <id>|revoke --all`, idle expiry 90 days. Revocation is immediate (checked per request).
- **Assumption to verify** in the Pake startup test (§11.3): WKWebView in the Pake build persists cookies across app
  restarts. If not, the GUI degrades to re-pairing at each launch (still secure); no secrets are baked into the
  Pake bundle and the shell never reads the daemon's token file.
- Daemon not running: Pake shows a WebView load error; README and `isenough daemon install` (KeepAlive LaunchAgent)
  cover it; the GUI never starts the daemon itself.
- **Secrets** (phase 2 WebDAV/OpenList credentials): Keychain (`kSecClassInternetPassword`), never in config.
- **Repo privacy**: app images are not secret, but device files reveal hostnames/usage; session tiering (roadmap)
  uses a **separate, encrypted** repo.
- **Supply chain**: only `swift-argument-parser` (+ `swift-crypto` on Linux). Pake (GPL-3.0) is a separate program that
  only loads a localhost URL; our code is not linked with it (see §14 licensing question). Before distributing the
  Pake-built app we ship its GPL notice and the exact corresponding wrapper source/build recipe (`scripts/build-gui.sh`,
  Pake version pin, icon/config) (N7).
- **Path handling**: all external tools invoked with argument arrays; bundle ids/versions sanitized before use in
  filenames (`[A-Za-z0-9._-]`, max 200 chars); manifests' relative paths validated (no `..`, no absolute).

---

## 11. Testing plan

### 11.1 Unit tests (`swift test`; Linux via `scripts/linux-test.sh` = `docker run --rm -v $PWD:/src -w /src swift:6.0 swift test`, and macOS CI)
| Module | What is tested |
|---|---|
| `Model` | Codable round-trips for every schema with golden JSON fixtures (`Tests/Fixtures/*.json`); unknown keys ignored; higher major → `EX_SCHEMA`; ISO dates; sorted keys stable output. |
| `RepoLayout` | image naming (`<bundleId>-<ver>-<sha8>`), sanitization, version/build folding, path validation (`..` rejected), conflict-copy detection regex. |
| `Classifier` | fixture `AppFacts` for: plain app → mount; MAS receipt → restore; SMPrivilegedExecutables → restore; LoginItems → restore; system extension/kext/network ext → unsupported; Xcode → unsupported; Sparkle/appex warnings; quarantine → refused. **Negative tests (B1):** MAS/helper/login-item/`restoreBundleIds` + `--mode mount` → `EX_UNSUPPORTED`; kext/sysext/Xcode + `--mode restore` or `--force` → unsupported; `--mode restore` upgrades a plain app; config cannot add mount allow-lists; `localFormat` ∉ {ULFO,UDRO} and remote manifest format ≠ ULMO rejected; `pack --format` unknown. |
| `Cache/LRU` | `planEviction`: quota and minFree math, pins never chosen, mounted never chosen, orphans first, LRU order, deterministic tie-break, impossible plan → error with details; allocated-size accounting. |
| `Lifecycle` | every legal transition; illegal ones throw; recovery reconciliation function `reconcile(state, osMounts, livePids)` table tests (adopt / drop / post-quit). |
| `LeaseTable` | add/remove/cancel detach timer on relaunch, pid-reuse guard (start time). |
| `Backend` | `LocalFolderBackend` list/stat/get(range)/put(atomic)/delete on temp dirs; `FakeUbiquityLocalBackend` notDownloaded → ensureLocal → current; evict; upload-state simulation. |
| `Fetcher` | streaming hash correctness; resume from `.part`; stall timeout (fake clock); sha mismatch → bad/ + one retry; ENOSPC simulation. |
| `HookRunner` | env contract, timeout kill, non-zero handling, permission checks (group-writable refused), ordering local → `.d/*` → shared. |
| `StubPlist` | transform: id suffix, removed keys, kept doc/URL/UTI types, `LSHandlerRank`, `CFBundleExecutable`. |
| `API` | route codables; auth decision table (§10.1): Bearer ok/missing/wrong; cookie+CSRF+Origin matrix; Host `127.0.0.1:p`/`localhost:p` accepted, `evil.com`, `127.0.0.1.evil`, wrong port → 421; absent Origin on cookie POST → 403; pairing code single-use, expiry, attempt limit; revoked session → 401; SSE cookie auth. |
| `Locks/Reservations` | lock-order checker (debug assertion: acquiring a lower-ranked lock while holding a higher one throws); reservation math incl. `reserved` sum; dead-owner reaping; gc try-lock skip. |
| `Tx` (journal) | fault injection at every point of every transaction (§5.8.6); invariant + idempotent recovery; changed-bundle retention; hook-failure rollback; simulated self-update → `retained/` + `needsResolution`. |
| `StubProtocol` | NDJSON codec; supervisor-side queue/ack ordering; stub-side outstanding counter + drain/bye/done state machine (pure); EOF/EPIPE handling marks client gone without aborting the session. |
| `Engine` (fake `Platform`) | pack → stub build (fake signer) → launch (fake attach/launcher) → quit → detach after delay (fake clock) → LRU updated; two concurrent launches = one attach + one forward; join at detach deadline; supervisor crash → single adoption; offline cached vs uncached; restore-mode swap & rollback; wrong-path instance rejected; probe `unknown` blocks cleanup. |

### 11.2 macOS integration tests (`IsenoughMacTests`, CI only, `#if os(macOS)`)
- `HdiutilDiskImageTool`: create ULMO from fixture folder, convert ULFO, attach with `-plist` (parse devEntry/mount),
  re-attach detection, detach, busy detach (hold an open file handle → exit 16 → retry succeeds after close).
- `MacAppInspector` on the fixture app (bundle id, doc/URL types, codesign info, ad-hoc kind).
- `CodeSigner` + `StubBuilder`: produced stub passes `codesign --verify --strict` and `plutil -lint`.
- `MountUsageProbe`: spawn a process from the mount → detected; after exit → not detected; a process (not under
  the mount) holding only a data file on the mount → busy; a helper surviving its parent → busy; `lsof` replaced by a
  failing stub binary → `unknown`.
- **Multiprocess lock tests** (real processes via `isenough` built binary): launch vs `evict` vs `prefetch` vs `gc`
  started together (random order, 50 iterations) → no attach of a missing file, no deleted mounted image, no
  corrupt `.part`; two `gc` processes recovering one dead owner → exactly one adopter; two different-app fetches
  sized so only one fits → one succeeds, other `EX_NOSPACE` (reservation), never both.
- **Journal fault tests on real APFS**: child process `kill -9` at each fault point, then recovery (§5.8.6).

### 11.3 End-to-end: `scripts/e2e.sh`
Single portable bash script (macOS 13+, bash 3.2 compatible, no Homebrew deps). Runs on GitHub Actions `macos-latest`
(`.github/workflows/macos.yml` job `e2e`) and on any Mac by `./scripts/e2e.sh` (needs Xcode CLT for `swift build`).
Everything lives in `E2E_DIR=$(mktemp -d)`; nothing touches `/Applications`, real iCloud, or user config:
`HOME` is not changed, but `ISENOUGH_CONFIG`, `--state-dir`, cache dir, repo root and stub install dir all point into
`$E2E_DIR`. A `trap` cleanup **first** copies diagnostics to `$E2E_DIR/artifacts/` (`events.jsonl`, `isenough.log`,
`state.json`, journals, `hdiutil info -plist`, `lsregister -dump | grep $E2E_DIR`, `ps`, `log show --last 5m
--predicate 'process == "isenough" OR process == "isenough-stub"'`) and copies them to `$E2E_ARTIFACTS` if set (CI upload),
then detaches only images whose backing path is under `$E2E_DIR`, `lsregister -u`s the stub and fixture paths, and
deletes the dir (unless `KEEP=1`). Every step logs the exact command it runs (`set -x` style prefix) so a run is
inspectable. Exit codes: `0` all required assertions passed; `1` an assertion failed; `2` **inconclusive**
(environment cannot run a required gate, e.g. no GUI session / LS unavailable) — CI treats `2` as failure.

Steps and assertions (each assertion prints `PASS/FAIL <name>`; script exits non-zero on first failure and dumps
`events.jsonl`, `isenough.log`, `hdiutil info`):
1. **Build**: `swift build -c release` (isenough, isenough-stub). `scripts/make-fixture-app.sh` compiles
   `Tests/Fixtures/E2EApp` (≈60-line AppKit app `io.github.s546126.e2eapp`, declares doc type `public.plain-text`
   and URL scheme `isenough-e2e`) into `$E2E_DIR/src/E2EApp.app`, ad-hoc signed. On launch it appends one JSON line to
   `$E2E_DIR/app-events.jsonl` (env var not available via LS, so path is baked into the fixture's Info.plist key
   `E2ELogPath` at build time) with `{event:"launch", bundlePath, pid}`, then one line per `open urls` event
   `{event:"open", url, via:"appleEvent"}` from `application(_:open:)` (argv is logged separately as
   `{event:"argv", args}` and never satisfies an `open` assertion); quits itself when file `$E2E_DIR/quit-now` exists (polls 200 ms) or after 60 s.
   - A1 `fixture_valid`: `codesign --verify --strict` passes.
2. **Init** fake iCloud: `isenough init --backend local --root $E2E_DIR/fake-icloud --cache-dir $E2E_DIR/cache --quota 200M`.
   (Variant job `E2E_FAKE_DATALESS=1` uses `FakeUbiquity` mode via `backend.type: "local-fake-icloud"` to exercise
   ensureLocal.)
3. **Pack**: `isenough pack $E2E_DIR/src/E2EApp.app --stub-dir $E2E_DIR/Applications --keep-original --json`.
   - A2 `pack_mode`: JSON `data.mode == "mount"`.
   - A3 `image_in_repo`: exactly one `images/io.github.s546126.e2eapp-1.0_b1-<sha8>.dmg`; `shasum -a 256` equals
     manifest `image.sha256`; `<sha8>` equals its prefix; `hdiutil imageinfo` format is `ULMO`.
   - A4 `manifest_valid`: `manifests/<id>.json` has schema `image/1`, bundleId, version, size == file size, teamId/
     cdhash fields present, documentTypes contains `public.plain-text`, urlTypes contains `isenough-e2e`.
   - A5 `catalog_updated`: `catalog/manifest.json` `apps["io.github.s546126.e2eapp"].latest == <id>`.
   - A6 `stub_valid`: `$E2E_DIR/Applications/E2EApp.app` exists; `codesign --verify --strict` ok;
     `CFBundleIdentifier == io.github.s546126.e2eapp.256stub`; `CFBundleExecutable == isenough-stub`; `LSUIElement` true;
     `Resources/stub.json` appId matches; stub size < 2 MB.
   - A7 `not_cached_yet`: `isenough status <app> --json` → state `remote`, no cache file.
4. **Launch via the hook path, through the stub**: `open -a $E2E_DIR/Applications/E2EApp.app $E2E_DIR/doc1.txt`
   then `open "isenough-e2e://hello?x=1"` is **not** used (would hit global LS default) — URL forwarding is tested via
   `open -a <stub> "isenough-e2e://hello?x=1"` after start (stub forwards to live session).
   Wait (≤ 60 s) for `app-events.jsonl` launch line.
   - A8 `fetched_verified`: cache dir has `images/<id>.ulfo.dmg`; state cache entry `complete:true`, `remoteSha256`
     == manifest; `events.jsonl` contains phases `fetch.start, fetch.done, verify.ok, convert.done, attach.ok`
     in that order.
   - A9 `mounted_readonly`: `hdiutil info -plist` lists the cache image with mountpoint `$E2E_DIR/cache/mnt/<id>`;
     `mount` shows it `read-only` + `nobrowse`.
   - A10 `running_from_mount`: launch line `bundlePath` starts with the mountpoint; pid alive; `isenough status` →
     `running` with one lease; real app's process path (`ps -o comm= -p pid`) under mountpoint.
   - A11 `doc_forwarded` (**required**): `app-events.jsonl` contains `open` with `file://…/doc1.txt`, `via:"appleEvent"`;
     the stub's ack log shows the batch `delivered`; the stub process has exited.
   - A11b `doc_during_fetch`: with the fake-dataless backend delay at 5 s, `open -a <stub> doc2.txt` and, 1 s later,
     `open -a <stub> doc3.txt` (arrives during fetch), and a third doc right after `ready` → all three `open` events
     present exactly once.
   - A12 `second_launch_no_remount` (**required**): `open -a <stub> "isenough-e2e://hello?x=1"` → `open` event with that URL appears
     within 10 s; still exactly one attachment of the image in `hdiutil info`; same app pid.
   - A13 `prelaunch_hook_ran`: a local hook `hooks/io.github.s546126.e2eapp/pre-launch` (installed before step 4)
     wrote `$E2E_DIR/hook-pre.env` containing `ISENOUGH_PHASE=pre-launch` and `ISENOUGH_MOUNT_POINT=<mnt>`.
5. **Quit**: `touch $E2E_DIR/quit-now`; config for e2e sets `detachDelaySeconds: 3`.
   - A14 `app_exited`: pid gone within 10 s.
   - A15 `idle_then_detached`: `isenough status` shows `idle` before the delay elapses (checked at +1 s), then within
     `3 + 20` s the image is absent from `hdiutil info` and the mountpoint dir is empty/removed.
   - A16 `postquit_hook_ran`: `hook-post.env` contains `ISENOUGH_PHASE=post-quit` and `ISENOUGH_EXIT_STATUS` ∈
     {`unknown`, `crash`} with value `unknown` for this clean quit (no numeric status is promised, §5.4).
   - A17 `lru_updated`: state `apps[..].lastUsedAt` > launch time, `launchCount == 1` (the URL forward doesn't count),
     cache entry `lastUsedAt` updated; state `cached`; `supervisor` process gone; device file written in repo.
6. **Cache hit relaunch**: `isenough launch <app> --no-wait`, then quit.
   - A18 `cache_hit`: `events.jsonl` for this session has no `fetch.start`; launch < 10 s; detaches again.
7. **LRU eviction (deterministic sizes)**: the script measures allocated sizes instead of assuming them. After
   step 6, `A1 = allocated bytes of app1's cache file` (`stat -f %b` × 512). It packs `…e2eapp2` with random padding
   chosen so that `A2_est ≥ A1 + 20 MB`, then fetches it with `prefetch` once in a scratch cache to measure `A2`
   exactly, and sets the e2e quota to `Q = max(A1, A2) + min(A1, A2)/2` (so each fits alone, both never fit) and
   `minFreeBytes = 0`. Then `launch app2` and quit.
   - A19 `lru_evicted`: app1's cache file removed (LRU), app2 present; `used ≤ Q`; `gc --dry-run --json` plan empty.
   - A20 `pin_respected`: `pin app1` → app1 fetched; since pinned app1 + app2 > Q the quota pass must evict app2
     (unpinned) — assert app1 cached, app2 not cached. Then `launch app2 --json` must exit `8` (`EX_NOSPACE`):
     app2 cannot fit beside the pinned app1, and pins are never evicted. Then `unpin app1`; `launch app2` succeeds.
8. **Races** (real processes): `launch app1 --no-wait & evict app1 & prefetch app1 & gc &` (20 iterations, random
   start delays) → A21 `race_safe`: every launch either ran from a verified mount or exited `9`; no attach error; no
   leftover `.part`/`.tmp`; state passes `doctor`. A22 `relaunch_at_deadline`: with `detachDelaySeconds: 3`, quit the
   app and open the stub at 2.9–3.1 s (loop of offsets) → either the session was joined (same mount) or a fresh
   mount happened; app event log shows the `open` event every time.
9. **Crash recovery**: launch app1, `kill -9` the supervisor, then quit the app; run `isenough gc` twice concurrently.
   - A23 `stale_mount_recovered`: image detached; exactly one `adopt` event; state has no mounts.
   - A24 `stub_killed_app_survives`: launch, `kill -9` the stub process right after `ready`; app keeps running,
     session completes and detaches normally after quit.
10. **Integrity**: flip one byte in a *copy* of app2's repo image published under a test-only repo, evict its cache,
   `isenough launch app2`.
   - A25 `sha_mismatch_refused`: exit code 5; nothing attached; file moved to `cache/bad/`.
11. **Lifetime protection (mount)**: fixture app spawns a helper (`E2EHelper`, from inside the bundle) that survives
   the main app 10 s; and a `cat`-style process from `/bin` holding a file on the mount open.
   - A26 `helper_blocks_detach`, A27 `datafile_blocks_detach`: no detach while they live; detach after they exit.
   - A28 `wrong_path_instance`: copy the fixture to `$E2E_DIR/other/E2EApp.app`, run it, then open the stub → stub
     alert/`EX_BUSY` (no lease on the foreign pid, no forward to it); quit the foreign copy and retry → normal launch.
   - A29 `quarantine_refused`: pack of a copy with `com.apple.quarantine` set → exit 3, nothing changed.
12. **Restore mode (required)**: fixture `E2EAppMAS` = E2EApp with a dummy `Contents/_MASReceipt/receipt` (the
   classifier only checks presence) installed into `$E2E_DIR/Applications`.
   - A30 `mas_forces_restore`: `pack --mode mount` exits 3; `pack` (auto) → mode `restore`.
   - A31 `restore_swap`: launch via the stub with a document → the real bundle is at the stub path while running
     (cdhash = manifest), the stub is in `.256isenough-staging/<txid>/`, document event logged; after quit the stub is
     back, staging/journal gone.
   - A32 `restore_helper_waits`: helper outliving the app keeps the restored bundle in place until it exits.
   - A33 `restore_fault_recovery`: for each fault point (env `ISENOUGH_FAULT=<phase>:<before|after>`, test builds only),
     run a launch that `kill -9`s itself there, then `isenough gc`; assert the §5.8.6 invariant.
   - A34 `restore_update_retained`: the fixture writes a file into its own bundle during the session (simulated
     self-update) → after quit the bundle is in `retained/`, `status` shows `needsResolution`, nothing deleted;
     `resolve --discard` moves it to the Trash.
13. **Unpack**: `isenough unpack app1 --to $E2E_DIR/restored`.
   - A35 `unpack_ok`: restored app `codesign --verify --strict` ok and cdhash + tree hash equal manifest; stub removed.
14. **GUI auth smoke (daemon, no Pake)**: `isenough serve --port <free>`; with `curl`: unauthenticated `/api/apps` → 401;
   pairing code → cookie + csrf; cookie POST without CSRF/with foreign Origin → 403; `Host: evil.com` → 421; SSE
   stream receives an event for a `prefetch`. (Actual Pake startup is tested in the manual `gui.yml` job: build
   Pake app, start it with the daemon running, pair via a test hook, assert the page fetched `/api/apps` with 200.)

**Required gates.** A11 (document via LS → stub → app), A12 (URL via LS → stub → live session), A31–A33 (restore swap
and recovery) are required: there is no CLI/argv substitute that can turn them green. The stub is always launched
through Launch Services (`open -a <stub> <doc>`, `open -a <stub> <url>`), and the app event log must show
Apple-Event delivery (`application(_:open:)`), not argv. If LS/`open` is unavailable on a runner, the script exits `2`
(inconclusive → CI red) after collecting artifacts. A10 additionally asserts that LS resolved the bundle id to the
mounted path (no preserved original was selected: originals live in `retained/`, §8.1).

CI notes: GitHub macOS runners have a logged-in GUI session, so `open`/NSWorkspace are expected to work; there is
no fallback that marks LS assertions skipped (see Required gates). Running directly (`isenough launch --doc`) is an
extra diagnostic, not a substitute.

### 11.4 CI workflows
- `linux.yml`: `ubuntu-24.04-arm`/`ubuntu-latest` + `swift:6.0` container → `swift build --target IsenoughCore` + `swift test`
  (macOS-only tests compiled out).
- `macos.yml` (`macos-latest`): `swift build`, `swift test`, `scripts/e2e.sh` with `E2E_ARTIFACTS` set; uploads the
  artifacts dir always (`if: always()`); exit `2` (inconclusive) fails the job. GUI build (`scripts/build-gui.sh`, needs Node + Rust) is a separate manual `workflow_dispatch` job.

---

## 12. Scope: MVP vs v1 / v2 / v3

### 12.1 MVP (this branch `feat/mvp`)
- Swift package: `IsenoughCore`, `IsenoughMac`, `IsenoughEngine`, `IsenoughServer`, `isenough`, `isenough-stub` as in §2.4.
- Backends: `local`, `icloud` (FileManager APIs; upload wait; ensureLocal; evict of repo local copy),
  `local-fake-icloud` (tests).
- Commands: `init, pack, list, status, launch, hook launch, prefetch, pin, unpin, evict, gc, restore, unpack, resolve,
  trust, stub rebuild, hooks list/enable/disable, doctor (checks + safe fixes), serve (+ pair, sessions, rotate-token),
  daemon install/uninstall/status, version`. (`trust` is MVP because a Team-ID/cdhash change blocks launch, §10.)
- **Implementation gates (N1)** — each gate must be green on macOS CI before the next starts:
  G-a safe local mount lifecycle (local backend, cache, reservations, locks, stub protocol, A1–A29);
  G-b safe restore (journal, fault injection, A30–A35); G-c iCloud materialization/upload (`icloud` backend, manual
  checklist on the user's Mac); G-d authenticated daemon + Pake GUI (§10.1, step 14). Shared repo hooks, `gc
  --remote`, and multi-Mac UX are deferred to v2 (local hooks stay MVP).
- Modes: mount (full lifecycle) and restore (journaled temporary swap + rollback). Classifier with hard constraints.
- Lifecycle: supervisor per session, leases, mount-usage probe, delayed detach with busy retry, recovery/adoption,
  user hooks (local only in MVP; shared repo hooks behind hash approval move to v2).
- Cache: ULMO remote → ULFO (or UDRO) local conversion, quota + minFree with atomic reservations, LRU, pins.
- Stub: AppKit launcher with doc/URL forwarding + progress window; ad-hoc or configured identity signing; LS register.
- GUI (minimal): `isenough serve` serves `web/` — one page: app list (name, version, mode, state, cached size, pinned,
  last used), actions Launch / Prefetch / Pin / Unpin / Evict, cache usage bar (used/quota/free), live progress via
  `GET /api/events` (SSE), `doctor` results. API: `GET /api/apps`, `GET /api/apps/{id}`, `POST /api/apps/{id}/launch|
  prefetch|pin|unpin|evict`, `GET /api/cache`, `POST /api/gc`, `GET /api/doctor`, `GET /api/events`, `GET /api/version`.
  Pack stays CLI-only in MVP (drag & drop pack is v1).
  `scripts/build-gui.sh`: `npx pake-cli http://127.0.0.1:47256/ui/ --name 256isenough --show-system-tray
  --hide-on-close --width 900 --height 640 --icon assets/icon.icns` (no token in the URL; the page pairs once,
  §10.1), then patch generated `Info.plist`
  (`LSUIElement=true` optional flag `--no-dock`) and re-sign. CI does not build it.
- Tests per §11; docs: README (install, quickstart, hook env contract, exit codes), this design.

### 12.2 v1
- Native-feeling UX: progress in the GUI for stub launches, drag-and-drop pack, "refresh app version" flow,
  daemon-driven launch over a Unix socket (faster cold starts, single owner of mounts), low-disk notifications,
  `NSMetadataQuery`-based push progress, Developer ID signed + notarized `isenough` release and Homebrew tap.
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
- **Recall**: (a) explicit `isenough sessions restore <id|cwd|--recent>`; (b) launcher wrapper hook: `isenough exec pi …`
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
   moment; budgeted by the reservation, §6.1); `cache.localFormat` can only choose ULFO or UDRO.
5. **Launch Services duplicates** (stub + mounted real app) may confuse "Open With" briefly during sessions.
6. **TCC**: same bundle id + DR should keep grants, but Accessibility/Input Monitoring toggles may need re-approval.
7. **macOS 27**: hdiutil deprecated (still works); stricter bundle validation for stubs — test on 27 betas.
8. **GitHub runners**: LS/`open` behavior on CI may differ; e2e then reports *inconclusive* (red), never a skipped
   pass; the same script runs on the user's Mac as the authoritative gate.
9. **GPL-3.0 (Pake)**: our engine is not linked with Pake; distributing the Pake-built app means distributing a GPL
   program (source offer for the wrapper). Self-use: no issue.

### 14.2 Open questions
1. Project license for our own code (MIT/Apache-2.0 suggested; compatible with distributing a separate GPL Pake shell)?
2. Signing identity: use your Developer ID for stubs (stable DR) or ad-hoc for MVP? Team ID to configure in CI secrets?
3. Target macOS versions (13+ assumed for the stub; engine 13+)? Is the Mac mini on 15, 26 or 27? Optimize Mac Storage on?
4. Default cache quota (20 GiB) and free-space floor (15 GiB) OK?
5. Default detach delay 120 s OK? Should pinned apps stay mounted (never detach)?
6. Move originals to Trash after pack (default) or keep them in `retained/` until first successful launch?
7. Install location of `isenough` (`~/.local/bin` vs `/usr/local/bin` vs Homebrew)?
8. Is a Pake tray window acceptable as the GUI, or do you want a native SwiftUI menu bar extra in v1?
9. Which apps (list + sizes) should be the first compatibility test set?
10. Multi-Mac sharing of one repo in scope for v2?
