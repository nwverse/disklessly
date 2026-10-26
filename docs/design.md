# 256isenough — Design (v1 draft rev. r3, 2026-10-23)

> Revision r1 addressed design-review round 1 (B1–B7, N1–N7): hard classifier/format constraints (§1.5, §3.6),
> write-ahead swap journal (§5.8), lock/reservation table (§5.6, §6), mode-specific process ownership (§5.9),
> acknowledged stub↔supervisor protocol (§8.3), cookie+pairing UI auth (§10.1), required macOS gates (§11.3).
>
> Revision r2 addresses round 2 (R2-B1…B6, N1–N5): attachment-infrastructure-aware usage probe (§5.9);
> generation-numbered lossless `bye/done` closing shared by owner and joiner supervisors (§8.3, §5.6.3);
> split capacity model — final-size quota admission vs. incremental transient free-space claims, with the
> local image size measured at pack time (§6.1); one lock hold boundary with try-lock-only victim reclamation
> (§5.6); unresolved updated bundles block launch until `resolve` (§5.8.7); explicit detach outcome branches with
> preserved mount ownership and joinable backoff/stuck sessions (§5.4).
>
> Revision r3 addresses round 3 (R3-B1…B6, N1–N5): one joiner exit rule (EOF after drain, §8.3 authoritative,
> §5.6.3); a supported process-inspection boundary with platform/related/unrelated classes, the kernel unmount
> check as final mount gate and an unsupported-preflight for temporary restore (§5.9); prefetch acquires L2 before
> releasing L1 and every writer owns its own live claim (§5.2.3, §5.6.2, §6.1); a restore-specific adoption branch
> and single-adopter handoff (§5.6.4); `restoredOut` terminal outcome with journaled state retirement (§5.4, §5.8.3);
> invalid-mutation vs. genuinely re-signed update fixtures (§11.3 A34/A34d).

> 中文摘要：每个冷门 App 打成只读压缩 DMG（远端 ULMO），放在可插拔后端（MVP = iCloud Drive / 本地目录）；
> `/Applications` 里放一个独立 bundle id、可签名的轻量 Stub。点击 Stub → **pre-launch hook**（拉取到本地缓存、
> sha256 校验、`hdiutil attach -readonly -nobrowse`、带文档/URL 打开真 App）→ App 退出 → **post-quit hook**
> （等所有进程离开挂载点、延迟卸载、更新 LRU、按配额淘汰）。引擎/CLI/Stub 用 Swift，GUI 是 `isenough serve`
> 提供的本地网页，用 Pake 打包。MAS/带特权 helper 的 App 走"临时还原"模式。

This document is the implementation spec. Sources: [research.md](research.md), [research-luna.md](research-luna.md),
[research-cursor.md](research-cursor.md). Where they conflict, research-cursor.md wins (no `brctl`, never attach a
dataless DMG, no `cp -c` zero-copy cache, ULMO remote, stub must forward documents and URLs, Pake = tray window +
HTTP to a daemon, sessions tiering starts with pi JSONL only).

Naming: product **256isenough**; CLI **`isenough`** (the earlier working name was rejected by the user — never use it; see AGENTS.md); stub launcher **`isenough-stub`**; Swift modules `Isenough*`.
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
| App bundling a `KeepAlive`/`RunAtLoad` LaunchDaemon/Agent plist (persistent helper) | **unsupported** (R3-B2: cleanup could never be proven safe without privilege; keep it installed normally) | always-on sync/VPN daemons |
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
   whose `NSExtensionPointIdentifier` starts with `com.apple.networkextension`; or (R3-B2) an embedded
   LaunchDaemon/LaunchAgent plist (`Contents/Library/LaunchDaemons|LaunchAgents/*.plist`) with `KeepAlive` or
   `RunAtLoad` true (reason `persistentRelatedHelper`: a permanently running helper of another uid could never
   be proven idle, so temporary restore would never clean up, §5.9 pass 3).
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
(hdiutil deprecated there). On macOS 27.0, `hdiutil attach -readonly -nobrowse -mountpoint` warns that the
invocation is deprecated and names `diskutil image attach --readOnly --mountOptions nobrowse --mountPoint`
as the replacement. Attach and detach use that `diskutil` form when `diskutil image --help` exits 0,
and the previous `hdiutil attach` / `hdiutil detach` commands otherwise. The help text is not read.
`diskutil image attach` has no `--noautoopen`; `--mountOptions nobrowse` is the Finder suppression.
There is no `diskutil image detach`: a normal detach is `diskutil eject`, and a forced detach is
`diskutil eject force` followed by `diskutil unmount force` if eject does not exit 0. Success is exit 0
plus a plist that lists the requested mount point (`mount-point` / `MountPoint`). Tool sentences are not
matched. Image creation stays `hdiutil create -format ULMO`. `diskutil image create from` can write ULMO,
but its scrubbing and ownership behavior differ, so pack does not use it. `LC_ALL=C` does not change
hdiutil's language.

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
    "volumeName": "Blender 4.2.1", "appPathInVolume": "Blender.app", "fs": "APFS",
    "localSizes": { "ULFO": 598000000, "UDRO": 1265000000 }
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
    "exportedTypes": [], "importedTypes": [],
    "related": []
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
`image.localSizes` (r2, R2-B3) is the **allocated** size of the image after local conversion, *measured* by `pack`
(it converts its staging ULMO to ULFO and UDRO in staging, records `totalFileAllocatedSize`, deletes them). It is
the size charged against the cache quota (§6.1). Manifests without it (older packs) fall back to the pessimistic
estimate of §6.1, replaced by the measured value in local state after the first fetch.
`app.related` (r3, R3-B2) lists the executable paths/launchd labels of helpers the bundle declares (privileged
helpers, embedded LaunchServices/LaunchDaemons/LaunchAgents/LoginItems); restore-mode probes treat uninspectable
processes matching it as potential dependents (§5.9 pass 3). Empty for typical mount-mode apps.

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
      "imagePath": "…ulfo.dmg", "attachedAt": "…", "owner": { "pid": 4242, "start": 1729411200 },
      "leases": [ { "pid": 5151, "start": 1729411260, "bundleURL": "…/Blender.app", "executablePath": "…" } ],
      "detachAfter": null, "phase": "running", "epoch": 1, "postQuitRanForEpoch": 0,
      "detach": null, "trackedDependents": []
    }
  },
  "restored": { },
  "claims": { "C-ab12": { "owner": { "pid": 4242, "start": 1729411200 }, "imageId": "com.blender…",
                          "volume": "/System/Volumes/Data", "quotaBytes": 598000000,
                          "plannedBytes": 1422000000, "allocatedBytes": 0, "persistentBytes": 0,
                          "stage": "admitted" } }
}
```
`mounts[*].detach` is `null` while running/idle, else `{ "state": "backoff"|"stuck", "attempt": 3,
"firstAttemptAt": "…", "nextRetryAt": "…", "lastError": "hdiutil: resource busy (16)" }` (§5.4). `epoch` counts
running periods of one attachment (incremented by a revive, §5.4.1); `postQuitRanForEpoch` makes post-quit hooks run
exactly once per epoch. `trackedDependents` lists exceptional dependents (§5.9). `claims` replace r1's
`reservations` (§6.1): one per in-flight fetch/extract (or pack/restore staging), owner-identified, reaped when the owner is dead.
`restored` holds restore-mode sessions (r3, R3-B4/B5): `{ appId: { "journal": "journals/<txid>.json", "txid",
"sessionId", "since", "owner": {pid,start}, "phase": "running"|"idle"|"waiting"|"restoringOut", "waitReason":
null|"busy"|"unknown"|"held", "epoch", "postQuitRanForEpoch", "detachAfter", "leases": [ … ], "dest": "/Applications/Foo.app",
"destId": {"dev","ino"}, "staging": "/Applications/.256isenough-staging/<txid>", "stubId": {"dev","ino"} } }` — a
mirror of the session part of the open restore journal; the authoritative swap state **and owner** live in the
write-ahead journal (§5.8; the journal is written first, the mirror second, and recovery repairs the mirror from the
journal). `destId`/`stubId` are the inode identities of the installed real bundle and the parked stub recorded at
`installed`/`stubParked`; together with cdhash they identify "our" restored layout without any attached image.
The entry is removed only by restore-out's `retired` phase (§5.8.3). Per app, `lastOutcome` records the last
terminal session outcome (`detached` | `restoredOut` | `restoredOutRetained`, with `at`) for `status`/GUI. `needsResolution` (per app) is set
when a restored/updated bundle was retained and awaits a user decision (§5.8.7):
`{ "retainedPath": "retained/<appId>/<ts>-Foo.app", "treeHash": "sha256:…", "cdhash": "…", "teamId": "…",
"fromImageId": "…", "txid": "…", "since": "…" }` — the durable identity snapshot of the retained bundle. While it
is set, `launch` **refuses** with `EX_RESOLUTION` (14) and `evict/unpack/gc` refuse the app (§5.8.7). Additional local directories:
`journals/` (swap/pack/install transactions, §5.8), `locks/` (§5.6), `retained/` (never auto-deleted bundles, §5.8).

### 3.6 Config (`config.json`)
```json
{
  "schema": "config/1",
  "backend": { "type": "icloud", "root": "~/Library/Mobile Documents/com~apple~CloudDocs/256isenough" },
  "cache": { "dir": "~/Library/Caches/256isenough", "quotaBytes": 21474836480, "minFreeBytes": 16106127360,
             "localFormat": "ULFO", "keepRemoteDownloaded": false },
  "lifecycle": { "detachDelaySeconds": 120, "detachRetryMaxSeconds": 600, "forceDetachAfterSeconds": 0,
                 "stuckRetrySeconds": 300, "probeIntervalSeconds": 5,
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
| `hook watch --app <appId>` | Internal (r3): detached watcher spawned by a short-lived adopter; owns an adopted mount or restore session until its terminal outcome (§5.6.4). |
| `resolve <app> --keep-updated [--trust]\|--discard\|--export <dir>` | Resolve a retained/updated bundle (journaled, §5.8.7). Required before the app can launch again. |
| `detach <app> [--force\|--forget]` | Retry detaching a `backoff`/`stuck` session now (adopting it if its owner is dead, §5.4); `--force` = one `hdiutil detach -force` after a clean usage probe; `--forget` = drop a record whose attachment is not ours (ownership mismatch). |
| `serve pair` | Print a one-time pairing code for the GUI (§10.1). |
| `prefetch <app>... \| --pinned \| --all` | Download + verify (+ convert) into cache without mounting. |
| `pin <app>` / `unpin <app>` | Toggle pin; pin also prefetches unless `--no-prefetch`. On iCloud optionally sets local `com.apple.fileprovider.pinned` on the remote file when `cache.keepRemoteDownloaded`. |
| `evict <app>... [--remote-local-copy] [--force]` | Drop cached image (refuses if mounted/claimed/`needsResolution`, `EX_BUSY`, even with `--force`; `--force` only overrides a pin). `--remote-local-copy`: also `evictUbiquitousItem` the repo file. |
| `gc [--dry-run] [--remote]` | Enforce quota/min-free (LRU), drop orphan caches/partials, recover stale mounts/journals. `--remote` (v2, not MVP): move unreferenced old images to `trash/`, purge trash > 30 days. |
| `restore <app> [--permanent]` | Restore-mode session (or permanent) via the journaled transaction (§5.8). Without `--permanent` the stub is reinstated after quit. |
| `unpack <app> [--to <dir>]` (alias `rehydrate`) | Permanently put the real app back (stub removed), keep image in repo unless `--delete-remote`. Used for "refresh": `unpack` → update app → `pack`. |
| `stub rebuild <app>\|--all [--sign-identity <id>]` | Regenerate stub(s) from the manifest (e.g. new Mac, new launcher version). |
| `hooks list\|edit\|enable\|disable <app>` | Manage user hooks (§5.5). |
| `doctor [--fix]` | Checks: config, backend reachable, iCloud signed in + Optimize Storage, free space, `hdiutil` present, stale mounts, lock files, LS registration of stubs, conflict copies, stub ↔ manifest consistency, isenough path in stubs. `--fix` performs safe repairs. |
| `recommend [--min-size SIZE] [--limit N] [--min-idle-days N]` | Rank top-level apps in `/Applications` and `~/Applications` worth offloading. See §4.1. |
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
| 14 | EX_RESOLUTION | an updated bundle is retained and must be resolved first (`isenough resolve`, §5.8.7) |

`--json` output shape: `{"ok":true,"data":{…}}` or `{"ok":false,"error":{"code":5,"name":"EX_INTEGRITY","message":"…","details":{…}}}`.

### 4.1 `recommend`

`isenough recommend` lists installed apps worth offloading. It does not pack or delete anything. It reads `/Applications` and `~/Applications`, and only the top-level `.app` bundle in each directory (nested bundles under `Contents` are ignored).

Skipped before scoring:

- stubs (bundle id suffix `.256stub`, executable `isenough-stub`, or `Contents/Resources/stub.json`) and the 256isenough app
- apps whose path resolves under `/System`, and apps signed by Apple as macOS system code (`anchor apple`, not `anchor apple generic`)
- apps whose main executable is currently running
- every dot-prefixed entry, including `.isenough-original-<id>.app` and `.256isenough-staging`
- bundles whose name starts with `.isenough-original-` or ends with `.256orig.app`

For each remaining app the command records:

- allocated size, `st_blocks * 512`, the same basis as `du`, walked in-process with a per-app time limit and an overall scan limit
- `kMDItemLastUsedDate` from Spotlight via `NSMetadataItem` (the MDItem attribute). A null attribute means never used. `mdls` text is not parsed
- Mac App Store receipt at `Contents/_MASReceipt/receipt` (restore mode)
- bundle id
- pinned and already-packed, from local state and the manifest catalog

Score is `(size in MiB) × idle weight`. Idle weight is whole days of 86400 seconds since last use. A never-used app uses 365 + 90, so it ranks above an app of the same size last used 365 days ago. Apps smaller than `--min-size` (default 100 MiB) are omitted. `--min-idle-days` omits apps used more recently; never-used apps still pass. `--limit` truncates the ranked list. Estimated space freed is the sum of the listed apps' sizes.

These are warnings, not recommendations, when they are at least `--min-size` (a timed-out size is always a warning): login items, menu bar agents (`LSUIElement` or `LSBackgroundOnly`), a running background helper, system extensions, kernel extensions, the toolchain the engine uses (Xcode, or the app that contains the active developer directory), pinned apps, and apps that are already packed.

A login item is a non-empty `Contents/Library/LoginItems`, `Contents/Library/LaunchAgents`, or `Contents/Library/LaunchDaemons`, or a plist in `~/Library/LaunchAgents`, `/Library/LaunchAgents`, or `/Library/LaunchDaemons` whose `Program` or `ProgramArguments` path is the app or inside it. `SMAppService` is not used.

Those skipped backups are not recommendations and not warnings. When any are present, the text output and `isenough ui` add one line, `N leftover backups (X) can be removed`, and list their paths. The command does not delete them; copies under `/Applications` need an administrator. `--json` includes `leftoverBackups` (path, sizeBytes, sizeIncomplete) and `leftoverBackupBytes`.

`--json` prints one object with `ok`, `scan`, `recommendations`, `warnings`, `estimatedFreedBytes`, `leftoverBackups`, and `leftoverBackupBytes`. `isenough ui` shows the same lists from `GET /api/recommend`.

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
- Mount-session phases (r2, §5.4): `running → idle → detaching → {detached | backoff | stuck}`;
  `backoff`/`stuck` keep the mount record, its ownership and its cache protection, and return to `running` via a
  **revive** (§5.4.1); only a verified successful detach leads to `cached`.
- `cached` means: complete local file, verified (`localSha256` recorded), not attached.
- `evictable` is a derived predicate, not stored: `cached ∧ ¬pinned ∧ ¬mounted`.
- Stored per-app `state` is advisory (for UI); truth is re-derived at startup from cache files + `hdiutil info -plist`
  + live pids (recovery, §9).

### 5.2 Pre-launch hook (supervisor, in order)
1. **Lock**: `L0(sh)` then `L1 = flock(locks/app/<appId>.lock, LOCK_EX)` (§5.6). Run per-app recovery first (roll forward/back any open
   journal for this app, §5.8; adopt a dead owner's session — mount or restore branch, §5.6.4). If a session exists
   (`mounts` record, or `restored[appId]` with its open journal) and its owner is alive → **join-session path**
   (§5.6.3), which also revives a session in `backoff`/`stuck`/`waiting` (§5.4.1), and return. Else if
   `needsResolution` is set → `EX_RESOLUTION` (§5.8.7; nothing is changed).
2. **Resolve image**: `state.apps[appId].imageId` (pinned version), else catalog `latest`. Read manifest.
3. **Ensure cached.** Lock boundary (R2-B4, one rule, §5.6.1): admission runs holding **L1 only**; then L2(img) is
   taken (blocking, in order) and held through fetch, verify, convert **and** step 4's attach decision.
   a. Under L3 snapshot: if the cache entry is complete → take L2, re-check file size (+mtime+inode fast path;
      re-hash if `verifiedAt` older than 30 days or mtime changed) and go to step 4.
   b. Else **admission** (§6.1, holding L1 only): quota admission of the final local size + free-space admission of
      the remaining transient bytes, with try-lock-only victim reclamation; persists a **claim** for this image
      owned by this process (pid+start). Failure → `EX_NOSPACE` (nothing changed). If a claim for the same imageId
      already exists: owner alive → it is a prefetch that, by the handoff rule (R3-B3, §5.6.2), **already holds
      L2(img)** and is the writer; we publish no claim, wait for L2 (progress window: "waiting for prefetch") and
      go to c. Owner dead → the claim is reaped in c (after we own L2), never before.
   c. Take L2(img) (blocking; legal order L1 → L2). Re-check under L3: (i) cache entry complete → drop our claim if
      any, go to step 4. (ii) a claim of a **dead** owner exists → we hold L2, so no writer exists: reap it (its
      `.part` becomes our resume prefix or a leftover). (iii) if we own no live claim now (we waited for a prefetch
      that failed or died) → release L2, still holding L1 (so no other process can publish a claim for this
      app's images), run admission b. for ourselves, re-take L2, and re-check. **Invariant: the only process that
      writes `.part`/`.tmp`/`images/` of an image holds L2(img) and owns a live claim for it** (writer = claim
      owner); a writer deletes or converts its claim under L3 *before* releasing L2.
      **Fetch** (`Fetcher`): backend-specific ensure-local (iCloud: start download + wait until `.current` and
      allocated size ≥ logical size) then copy remote → `cache/partial/<imageId>.dmg.part` streaming with sha256
      computed during copy (`get(range:)` with resume from `.part` size for range-capable backends). The claim's
      `allocatedBytes` is updated under L3 at each stage boundary and every 256 MB (§6.1). After copy+verify, the
      repo file's local data is evicted if it was dataless before the fetch (§6.2), *before* conversion. Progress
      events → `events.jsonl` + stub progress window.
   d. **Verify**: sha256 == manifest; size == manifest. Mismatch → move file to `cache/bad/`, re-fetch once,
      then `EX_INTEGRITY`.
   e. **Convert** (always; `cache.localFormat` ∈ {`ULFO`,`UDRO`}, §3.6): `hdiutil convert -format ULFO|UDRO` from
      the verified `.part` to `partial/<imageId>.<fmt>.dmg.tmp`, `fsync`, record `localSha256`, `rename` into
      `images/`, delete the ULMO copy. ENOSPC/timeout → delete the `.tmp`, keep nothing half-written. (Cost: one-time
      CPU per fetched version; justified because LZFSE/uncompressed blocks decode much faster on random access at app
      launch than LZMA, and launches outnumber fetches.)
   f. Under L3, in one write: add the complete cache entry (measured allocated size) **and** delete the claim, so
      the bytes move from "claimed" to "used" atomically (§6.1). On any failure: delete `.part`/`.tmp`, delete claim.
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
   detaches the image. The restore session's usage root is the restored path (§5.9). The session is published
   in the journal (`active`, owner) and mirrored in `state.restored[appId]` (§3.5) before the app is opened.
5. **User pre-launch hooks** (§5.5). Non-zero exit / timeout → **full rollback** of everything this supervisor did,
   in reverse order: restore mode → journaled restore-out (§5.8.3) **including its `inspected` phase** — cdhash *and*
   tree hash are compared even though the app never ran, because a pre-launch hook may have modified the restored
   bundle; a changed bundle is retained (`needsResolution`), never deleted (R2-B5); mount mode → `lsregister -u` +
   detach (if we attached; the image is read-only). Then `EX_HOOK`.
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
  every `probeIntervalSeconds` (5 s). A probe that fails or is incomplete yields `unknown`, which is treated exactly
  like `busy`. A new process under the usage root (Dock relaunch of the real app while idle) becomes a lease; state
  stays/returns to `running`.
- All probes `clean` twice in a row (≥5 s apart) → state `idle`, `detachAfter = now + detachDelaySeconds` (120 s).
  (So `idle` is reached 5–10 s after the last user exits; A15 accounts for that, N5.)

### 5.4 Post-quit hook and detach (R2-B6)
Every step that reads or changes the session runs holding `L0(sh)+L1(app)`; the owner holds **no** lock while
sleeping. `epoch`/`postQuitRanForEpoch` (§3.5) make post-quit hooks run once per running period.

1. **Wait** until `detachAfter` (no locks). Joiners may change the session meanwhile (§5.6.3).
2. **Re-validate** under L1: re-read the session. If `phase != idle`, `detachAfter` is null/later, or a lease
   exists → release L1, back to watch (§5.3). Re-probe usage; busy/unknown → release L1, back to watch.
3. **Post-quit hooks** (still under L1; bounded by `hookTimeoutSeconds`; a joiner waits on L1 and the stub shows
   "finishing previous session"): set `phase = detaching`; if `postQuitRanForEpoch < epoch` run user post-quit hooks
   (§5.5) with `ISENOUGH_EXIT_STATUS` = `crash` if a crash report for the leased pid appears in
   `~/Library/Logs/DiagnosticReports` within 5 s, else `unknown` (numeric exit codes of non-child apps are not
   observable), then set `postQuitRanForEpoch = epoch`. Hook failures are logged. Detach retries of the same epoch
   never rerun hooks; a revived session (§5.4.1) gets a new epoch and its next quit runs them again.
4. **Detach attempt** (mount mode; still under L1): verify ownership with `hdiutil info -plist` (attach-time
   `devEntry` maps to our cache image realpath *and* mountpoint `mnt/<imageId>`, N4). If the image is no longer
   attached at all → outcome **detached** (external detach; logged). If attached but not ours (e.g. same image
   re-attached elsewhere) → outcome **stuck** (`lastError: ownership mismatch`, never detached by us; the cache
   file stays protected by the `hdiutil info` check of §6.2 even if the user later runs `isenough detach --forget`,
   which drops only our record). Otherwise `lsregister -u <mnt>/<app>` (best effort), then
   `hdiutil detach <devEntry>` (timeout 60 s), then re-query `hdiutil info`: success only if `devEntry` is gone.
   Outcomes, each written under L3 before L1 is released:
   - **detached** → step 5.
   - **retryable failure** (busy/exit 16, timeout, devEntry still present) and `now − detach.firstAttemptAt <
     detachRetryMaxSeconds` → `phase = backoff`, `detach = {state:"backoff", attempt+1, nextRetryAt = now +
     min(5·2^attempt, 300) s, lastError}`. The **mount record, owner, leases table and cache protection are kept**
     unchanged. Release L1; sleep until `nextRetryAt` while probing (§5.3: any new process under the root revives
     the session itself as in §5.4.1); then go to step 2 (which, for `phase == backoff`, skips the `detachAfter`
     check and step 3's hooks).
   - **exhausted** → if `forceDetachAfterSeconds > 0` and the usage probe is clean, one `hdiutil detach -force`
     attempt, judged like above. Otherwise (or if that fails) `phase = stuck`, `detach.state = "stuck"`; event
     `detach.stuck` + user notification ("Foo's disk image could not be ejected: <lastError>; `isenough detach Foo`").
     The mount record and ownership stay; cache protection stays (§6.2 never evicts an image with a mount record
     *or* an `hdiutil info` attachment). The supervisor then **exits with `EX_DISKIMAGE` (6)** — it does not fall
     through to step 5. The record now has a dead owner and is retried by recovery (§5.6.4): daemon every
     `stuckRetrySeconds`, `gc`, `isenough detach <app>`, or the next launch (which revives it instead, §5.4.1).
     Recovery of a stuck session performs only step 2's probe and step 4 (no hooks: same epoch).
   **Restore mode** (R3-B5): run the journaled **restore-out** transaction (§5.8.3) under L1, which inspects for
   changes before any removal and retains changed bundles. Outcomes, each written under L3 before L1 is released:
   - **waiting(busy|unknown|held)** (re-probe not clean) → journal stays `active`, `restored[appId].phase =
     waiting`, `waitReason` set; release L1; probe with backoff (to 5 min, indefinitely; never forced) and retry
     from step 2. Joinable (a joiner revives it like §5.4.1, using the restored path; no pre-launch re-run within
     the same epoch rule).
   - **restoredOut** / **restoredOutRetained** (terminal) → reached only through restore-out's `retired` phase,
     which in one L3 write removes `state.restored[appId]`, sets `lastOutcome`, `lastUsedAt` and (if retained)
     `needsResolution`; then `closed`. Continue with step 6 (step 5 is mount-only; its LRU update is part of
     `retired`).
5. **Cleanup (mount mode) — only after outcome detached**: under L3 remove the mount record (and session), set
   `lastOutcome = detached`, remove the empty mountpoint dir, `lastUsedAt = now` for app and cache entry;
   device-file write queued (best effort, no lock).
   `launchCount` is incremented when a supervisor *opens* the app (owner launch or revive), never on forwards.
6. **Release L1**, then run the quota pass (§6.2; try-locks only, §5.6.2). It never evicts what we just used unless
   that alone exceeds the quota.
7. Supervisor exits 0.

#### 5.4.1 Revive (joining an idle, backoff or stuck session)
Any supervisor holding L1 that finds a session in `idle`, `backoff` or `stuck` whose attachment is verified ours
(step 4's ownership check) and still attached may revive it instead of mounting again: if the recorded owner is dead
it first adopts ownership (§5.6.4); it sets `detachAfter = null`, `detach = null`, `phase = running`, and
`epoch += 1` if `postQuitRanForEpoch == epoch` (hooks of the previous epoch already ran); it re-runs local
**pre-launch** hooks only when the epoch changed (a new running period), opens the real app from the mount, and adds
the returned pid as a lease (identity-checked, §5.2.6). If such a pre-launch hook fails, nothing is opened, the
session goes back to `idle` with `detachAfter = now` (normal detach path) and the joiner's batch is acked with
`EX_HOOK`. A process that appears under the root without a stub (Dock relaunch during backoff) is revived by the
owner's own probe the same way, without pre-launch hooks (no stub involved). A live backoff owner notices on its next step 2 (phase is
`running` → back to watch); it never detaches a revived session because every detach attempt is preceded by the
step-2 re-validation under the same L1. If the attachment is gone (detached externally), the record is dropped and
a normal launch follows. A `detaching` phase is never observable by others (it only exists under L1); a crash leaves
`detaching` with a dead owner, which recovery treats as `backoff` if still attached, else drops.

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
Owner identity for anything that *outlives* a lock (sessions, claims, journals) is (pid, process start time
from `proc_pidinfo`), so pid reuse cannot impersonate an owner.

| Lock | Scope | Held across |
|---|---|---|
| `L0 = locks/global.lock` | shared (`LOCK_SH`) by every mutating command; exclusive only for `state.json` rebuild after corruption and for `doctor --fix` structural repairs | exactly as long as the command holds any L1/L2 |
| `L1 = locks/app/<appId>.lock` | exclusive; everything that changes the app's stub, restored bundle, session, mount, `needsResolution`, or its cache entries | the command's critical phase; never while sleeping/waiting for the app/timers |
| `L2 = locks/image/<imageId>.lock` | exclusive; the image's `.part`, conversion `.tmp`, `images/` file, `bad/` copy | **the whole materialize+copy+verify+convert of that image, and the attach decision** |
| `L3 = state.lock` | exclusive; read-modify-write of `state.json` incl. claims | short sections, never slow I/O, never while acquiring another lock |

**Global order (deadlock freedom):** `L0(sh) → L1 ascending appId → L2 ascending imageId → L3`. Blocking acquisition
is allowed only in this order. A lock that sorts before one already held may be taken **only with a non-blocking
try-lock** (`LOCK_NB`); failure means "skip that object", never "wait" (this is how reclamation works, below).
A debug lock-order checker (all builds in tests) throws on a blocking out-of-order acquire.

**Hold boundary for slow work (R2-B4, single rule).** L2(img) *is* held during download/copy/convert of *that*
image — this is deliberate: it serializes the only writers of that image's files, and the only other parties
needing L2(img) are a second fetcher of the same image (which should wait for it) and evict/gc of that image
(which try-lock and skip). L2 is never held while waiting for anything *else*: not during user hooks, the app's
lifetime, the detach delay or backoff, repo `put`s of other objects, or user decisions. L3 is never held across
I/O. r1's sentence "long waits are done without L2" is withdrawn; the lock table below is authoritative.

**Space reclamation needs no restart.** Admission (§6.1) runs holding L0(sh)+L1(own app) and *no* L2. Victims
belong to other apps: their L1 sorts arbitrarily relative to ours, so the reclaimer takes victim locks with
try-lock only (L1(victim) `LOCK_NB` → L2(victimImg) `LOCK_NB`), re-checks the victim predicate under L3, deletes,
updates state, releases. A busy victim is skipped and the planner picks the next. There is no "release everything
and restart" path anywhere; therefore no livelock from re-acquiring the same locks. A victim of *our own* app (an
old version of the same app) is covered since we already hold its L1; its L2 is still try-locked.

#### 5.6.2 Lock table per command
| Operation | Locks (in order) | Notes |
|---|---|---|
| launch / `hook launch` (owner) | L1(app) → admission + reclamation (try-locks only) → L2(img) blocking: fetch/verify/convert/attach → release L2 → user pre-launch hooks + open under L1 → release L1 while running | claim persisted before the first byte (§6.1); cache-file check and attach under the same L2 hold |
| join / revive (second supervisor) | L1(app) | §5.6.3, §5.4.1 |
| post-quit / detach / `isenough detach` | L1(app) per attempt (L3 inside for state writes); quota pass after releasing L1 (try-locks only) | §5.4 |
| `prefetch`, `pin` | L1(app) → admission + claim (L3) → **L2(img) blocking while still holding L1** → release L1 → fetch/verify/convert under L2 → completion (claim → cache entry, L3) → release L2 | R3-B3 handoff: claim publication and writer ownership happen in one L1 hold, so whoever later takes L1 and sees a live claim knows its owner already holds L2 and is the writer; a launch never writes under another process's claim (§5.2.3b–c) |
| `evict <app>` | L1(app) → L2(img) (blocking, in order) | refuse if session/mount/claim/restored/`needsResolution` (`EX_BUSY`) |
| `gc` / quota pass / reclamation | plan under L3 snapshot → per victim: try-lock L1(victim) → try-lock L2(img) → re-check predicate under L3 → delete → state under L3 | holds at most its own app's L1 (admission) or nothing (gc); skips busy victims |
| `unpack`, `restore --permanent`, `stub rebuild`, `resolve` | L1(app) (+ L2 for attach/extract) | journaled (§5.8) |
| `pack` | L1(newAppId) + L2(new imageId) | journaled (§5.8.5) |
| recovery / adoption | L1(app) | §5.6.4 |
| `serve` handlers | delegate to the same engine operations | the daemon holds no locks while idle |

#### 5.6.3 Joining a live session (second stub, document drop, relaunch at deadline)
A **joiner** is a supervisor whose `hook launch` found (under L1) a session with a live owner. Joiners and owners
speak the **same** stub protocol (§8.3): `open` batches are acked individually, `ready` is sent once the target app
is running (joiners send it after their first delivered batch), and the stub's lossless `bye/done` closing applies
unchanged. Per batch, holding L1 only for the critical section:
1. Re-read the session. `running` → forward the batch to the *verified* running instance (identity check of
   §5.2.6). `idle`/`backoff`/`stuck` → revive it (§5.4.1) and deliver the batch as the first batch. Not joinable
   any more (record dropped because the image detached meanwhile) → the joiner **becomes an owner** in the same
   process: it continues with §5.2 step 2 (fetch/attach/open) for this and all further batches. `detaching` is
   never observed (it exists only under L1; a joiner simply blocks on L1 until post-quit hooks/detach attempt end).
2. Release L1, ack the batch. Further batches from the same stub repeat 1–2.
3. **Exit rule (R3-B1; §8.3 is authoritative).** `bye(g, r)` does **not** end a joiner: it answers `done(g, r)`
   once every `req ≤ r` is acked and keeps reading fd 3, accepting and acking any later `open` (generation g+1, …)
   by repeating 1–2. The **only** joiner exit condition is EOF on fd 3 (the stub closed after a matching `done`
   and its final drain, or the stub died) **after** every batch received so far has been acked (drained). The
   joiner never closes fd 3 first and never exits on `done`. It never touches the session's ownership, so a
   joiner exiting (or being cancelled/killed) cannot affect the session; a killed joiner only loses unacked
   batches, which the stub re-sends via one respawned supervisor (§8.3). Cancel aborts only its undelivered
   batches. (A joiner that *became an owner* in step 1 follows the owner rule: it keeps running after EOF.)
The owner always re-reads the session after acquiring L1 (§5.4 step 2), so the handoff is synchronized by the lock.

#### 5.6.4 Recovery and adoption (one adopter)
Recovery for an app runs only while holding L1(app); it first replays open **non-session** journals (pack,
unpack, resolve, rollbacks), then dispatches on the session's **mode** — mount sessions (a) are recognized by an
attachment, restore sessions (b) by their journal; the two checks are never mixed (R3-B4).

**Election (both modes).** Under L1 the caller re-reads the owner (mount: `state.mounts[img].owner`; restore: the
open restore journal's `owner`, mirrored in `state.restored[appId]`). Owner (pid+start) alive → not orphaned,
stop. Otherwise the caller becomes the **single adopter**: it rewrites the owner (restore: journal first, WAL rule,
then mirror; mount: under L3) and only then acts. Any later caller sees a live owner. A short-lived adopter
(`gc`, CLI command, stub-less recovery) that must keep watching does not watch itself: still under L1 it spawns a
detached `isenough hook watch --app <id>` (setsid), records **the child's** (pid, start) as owner, and releases
L1; if the child dies, it is just another dead owner. The daemon adopts in-process.

**(a) Mount sessions.** Image ownership is verified before adoption: the attached `devEntry` must map to our cache
image path (`hdiutil info`) *and* its mountpoint must be our `mnt/<imageId>`; an attachment of the same image path
mounted elsewhere is reported but never detached (N4). An adopted session continues where its phase says:
`running`/`idle` → watch (§5.3); `backoff`/`stuck`/crashed `detaching` → §5.4 step 2 then a detach attempt (no hooks
if `postQuitRanForEpoch == epoch`). An adopter that ends in `stuck` again exits `EX_DISKIMAGE` (CLI) or reschedules
(daemon); the record is never dropped while the image is attached.

**(b) Restore sessions (R3-B4).** Input: the open restore journal (`kind` restore-in/restore-out), its paths,
`destId`/`stubId`, `owner`, `epoch`. No attached image is expected (restore-in detached it during `extracted`,
before `stubParked` / `active`). There is no single active-layout prerequisite. `RestoreRecovery.decide` checks
the directory layout against the phase that was actually journaled and accepts both the pre-effect and
post-effect of that phase, because the phase is written before the mutation. A layout that matches neither side,
or that contains a symlink, a path escape, or an unexplained staging entry, is rejected with no rename and no
delete; `doctor` reports the repair hint. A changed inode or cdhash at the controlled destination is watched
and retained unless cdhash, tree hash, and a verified archive all match. Decisions that are intentionally
narrower than this paragraph are recorded in `docs/fb1-decisions.md`. Then by journal phase:

| Journal phase at crash | Usage probe of `<dest>` + staging (§5.9, restore mode) | Action of the adopter |
|---|---|---|
| `prepared`/`extracted`/`stubParked` (app never installed) | not needed | roll back per §5.8.2 (stub stays/returns at `<dest>`), outcome `rolledBack` via `retired`/`closed` |
| `installed` (owner died before `active`; app possibly launched by LS from `<dest>`) | busy/unknown/held | promote to `active` with self as owner (`epoch` 1, `postQuitRanForEpoch` 0; pre-launch hooks are not re-run because the app is already running; post-quit hooks run once at the end), then watch |
| `installed` | clean twice | rollback = journaled restore-out (inspect → stub back → dispose → `retired` with `rolledBack`) |
| `active` (`restored.phase` running/idle/waiting) | busy/unknown/held | adopt; `phase = waiting`, `waitReason`; watch with probe backoff (§5.3); **no swap** |
| `active` | clean twice | adopt, then the normal post-quit path: wait `detachAfter` (set to now + delay if null), post-quit hooks if `postQuitRanForEpoch < epoch`, restore-out (§5.8.3), terminal outcome |
| restore-out `quiesced`/`inspected` | re-probe | busy → back to `active` + `waiting` (nothing was moved yet); clean → continue restore-out forward |
| restore-out `appMoved`/`stubBack`/`disposed`/`retired` | staging only (`app.old` must be clean before `disposed` deletes it) | continue forward; busy staging → stay in that phase with `waitReason`, retry later |

**Exactly when recovery waits vs. runs restore-out:** it swaps only from a journal state whose usage probe was
clean twice under L1 by the current owner; any busy/unknown/held result keeps the restored bundle in place.
Joiners (stub launched while `restored[appId]` has a live owner) follow §5.6.3 with the restored path as the
target; revive of a `waiting` session follows §5.4.1 (new epoch if hooks of the previous epoch ran).

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
    S->>V: posix_spawn(setsid) hook launch --app id --control-fd 3 (socketpair NDJSON, no documents on argv)
    S->>V: open(req=1, documents, urls) after 300 ms coalescing
    V->>V: flock app lock; check live session
    alt session already running (V is a joiner)
        V->>A: NSWorkspace.open(urls, withApplicationAt) on verified instance
        V-->>S: ack(req=1) + ready
        Note over S,V: same bye/done generations as below; joiner exits only on EOF after drain (§8.3)
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
    V-->>S: ack(batch) + ready
    S->>V: bye(gen=1)
    U->>S: late Apple Event (after bye)
    S->>V: open(req, gen=2)
    V-->>S: ack(req) (gen 2 delivered)
    V-->>S: done(gen=1, lastReq) — gen mismatch, S keeps running
    S->>V: bye(gen=2)
    V-->>S: done(gen=2)
    S->>S: final drain, exit(0) → fd 3 EOF
    Note over V: owner: EOF = "client gone", session continues; joiner: EOF after drain → exit
    U->>A: uses app … quits
    A-->>V: didTerminate / NOTE_EXIT
    loop every 5 s
        V->>V: probe processes/open files under mnt
    end
    V->>V: idle; wait detachDelay (cancel on relaunch)
    V->>V: lock; detaching; user post-quit hooks (once per epoch)
    V->>H: lsregister -u realApp; detach devEntry; verify gone (else backoff/stuck, mount kept)
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
  enough space on the destination volume for the extracted app (+10 %), no running process of the bundle id, and
  (restore-in, R3-B2) no running *related* process that the probe cannot inspect (§5.9 pass 3). If
  `/Applications/Foo.app` is not user-writable (e.g. root-owned MAS install), we **refuse before changing anything**
  (`EX_UNSUPPORTED`, message tells the user to move it via Finder, which asks for admin auth, and retry). No helper.
- **Never delete the only copy.** A bundle is deleted only if (a) it is the stub (regenerable from the manifest), or
  (b) it is byte-identical to an image in the repo: its cdhash *and* a tree hash (sha256 over sorted relative paths,
  modes, symlink targets, file contents; computed by `BundleHasher`) equal the values recorded in the manifest
  (`app.treeHash`, new field computed at pack) **and** that image is present in the local verified cache or
  confirmed uploaded. Otherwise the bundle is moved to `retained/<appId>/<ts>-<name>.app` (same volume when possible;
  else kept in staging) and recorded as `needsResolution`.
- **Supervisors never prompt and never block on a user decision.** A decision is recorded (`needsResolution` with
  the retained bundle's identity snapshot, event, GUI/daemon notification, and `status`/`doctor` output); the user
  resolves with `isenough resolve` (§5.8.7). **Until resolved, launching the app is refused** with `EX_RESOLUTION`
  and an alert "Foo was updated while restored; choose Keep update / Discard in 256isenough" (R2-B5, r1's
  "launch the retained bundle" is withdrawn).

#### 5.8.2 restore-in (pre-launch, restore mode)
| Phase | Effect (after journaling the phase) | Recovery if crashed in/after this phase |
|---|---|---|
| `prepared` | preflight; `mkdir staging/<txid>` | remove staging; done |
| `extracted` | `ditto <mnt>/<app> staging/app.new`; verify cdhash + tree hash == manifest; detach image | if `app.new` unverified → delete it, rollback |
| `stubParked` | `rename(<dest>, staging/stub.app)` | if `<dest>` missing and `stub.app` present → continue/rollback by renaming back |
| `installed` | `rename(staging/app.new, <dest>)`; `fsync` parent; `lsregister -f <dest>` | forward: launch path; rollback: run restore-out |
| `active` | journal gets `owner`, `destId`, `stubId`, `epoch`; then the `state.restored[appId]` mirror is written (§3.5); journal stays open for the session lifetime | **restore adoption** (§5.6.4b) — never the mount-adoption path; no attached image is expected or required |

#### 5.8.3 restore-out (post-quit, hook-failure rollback, recovery)
| Phase | Effect | Recovery |
|---|---|---|
| `quiesced` | usage root clean twice (§5.9) and `detachAfter` elapsed — else the journal stays `active` with `waitReason` and the owner keeps waiting/retrying (never forced) | re-probe (clean twice) before moving on; busy → back to `active`, waiting |
| `inspected` | compute cdhash + tree hash of `<dest>`; record `changed: bool` (+ identity snapshot) in journal | re-probe clean once, then recompute |
| `appMoved` | `rename(<dest>, staging/app.old)` | if `<dest>` empty and `app.old` present → continue |
| `stubBack` | `rename(staging/stub.app, <dest>)`; `lsregister -f`; `lsregister -u` old real path | continue |
| `disposed` | unchanged → delete `app.old` (rule "never delete only copy" satisfied); changed → move to `retained/`, journal records `needsResolution` snapshot, event `app.updated` | continue |
| `retired` | (R3-B5) **one** L3 write: delete `state.restored[appId]`; `apps[id].needsResolution` = snapshot if changed; `apps[id].lastOutcome = restoredOut` / `restoredOutRetained` (or `rolledBack` for a hook/launch-failure rollback); `lastUsedAt = now` for app and cache entry (not for `rolledBack`); per-app `state` = `cached` (image still cached) / `remote` / `needsResolution`; `state.json` atomic rename + `fsync` | re-apply (idempotent: every field is assigned, not incremented) |
| `closed` | only after `retired` is durable: remove staging, then the journal | remove leftovers |

**Terminal outcome (R3-B5).** A restore session ends only through `retired`: outcome `restoredOut` (stub back,
identical copy deleted) or `restoredOutRetained` (stub back, changed bundle retained, app blocked until `resolve`).
`waiting(busy|unknown|held)` is **not** terminal: `state.restored[appId]` stays with `phase = waiting` and its
`waitReason`, and the journal stays `active`. Because the journal is closed only after the state write is durable,
every crash point has a recoverable journal: before `retired` → replay forward; during/after `retired` → re-apply
and close. Conversely a `state.restored` entry whose journal file is missing (stale mirror, e.g. manual deletion)
is retired by recovery only if `<dest>` holds our stub (stub bundle id + `stubId`/regenerated stub) and no staging
exists; otherwise it is reported by `doctor` and the app is refused (`EX_BUSY`) — never guessed.
**Consumers see one truth:** `launch` with `restored[appId]` present → join/adopt path (§5.2 step 1); absent and
`needsResolution` set → `EX_RESOLUTION`; `status` shows `restored`/`waiting(reason)`/`lastOutcome`; `evict`/`unpack`
refuse while `restored[appId]` or an open journal exists; recovery is a no-op after `closed`.

If the stub copy in staging is missing/corrupt at `stubBack`, a new stub is built from the manifest first (stubs
are always regenerable). `inspected` always compares cdhash **and** tree hash (also on hook-failure rollback where
the app never ran, R2-B5). Resolution of a retained bundle: §5.8.7.

#### 5.8.4 Self-updating apps in mount mode
Mount images are read-only, so in-place updates fail; updaters that instead write a new copy elsewhere (e.g. to
`/Applications` or `~/Applications`) produce an untracked bundle. `doctor` detects a bundle with the target bundle id
outside our control and offers `pack` refresh; we never delete it automatically.

#### 5.8.5 pack and unpack transactions
pack: `inspected → imaged (staging dmg, verify; measure `localSizes` by converting in staging, §3.2) → uploaded (put + manifest + catalog; wait upload unless
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
idempotent (running it twice is a no-op). The fault set includes `resolve` phases, and a `preLaunchHookMutates` fault (a hook writes into the restored
bundle and exits non-zero): rollback must retain the bundle (tree hash differs) and set `needsResolution`.
r3 additions: the `retired` phase (fault before/after the state write, and between state write and journal
removal) — after recovery `state.restored` is empty, `lastOutcome` is set exactly once, the journal is closed and a
fourth recovery run is a no-op (R3-B5); and the restore-adoption table of §5.6.4b is a pure function
`RestoreRecovery.decide(journalPhase, layout, probe, ownerAlive) -> action`, enumerated exhaustively (every phase ×
{busy, unknown, held, clean} × {owner alive, dead} × {layout ok, mismatch}) with the invariant "no rename of `<dest>`
unless the probe was clean twice under the current owner" (R3-B4).

#### 5.8.7 Retained updated bundles: block, then resolve (R2-B5)
**MVP decision: an app with `needsResolution` cannot be launched** (safe option from the review). Rationale:
launching the retained bundle would need a second trust root (the bundle no longer matches any manifest) and a
second restore source; the retained bundle is evidence the user must decide on, and the cost is one command/click.
- **Durable record.** restore-out's `disposed` phase writes, in the journal *and then* in `state.apps[id].
  needsResolution`, `{retainedPath, treeHash, cdhash, teamId, fromImageId, txid, since}` computed at `inspected`.
  The retained bundle is moved with `rename` (same volume) or `ditto`+verify+tree-hash compare (cross volume) before
  the original location is touched; it is never deleted by any automatic path (gc/evict/unpack refuse the app).
- **Effect on the stub.** pre-launch step 1 refuses with `EX_RESOLUTION` before any change; the stub alerts with
  the two choices; GUI shows a "Resolve" action. `status`/`doctor` list it. A second update cannot happen: nothing
  runs from the retained bundle, and the stub is back at the destination.
- **`resolve --keep-updated [--trust]`** (journal kind `resolve`, under L1): `verified` (recompute tree hash of
  `retainedPath`; must equal the record, else `EX_INTEGRITY` and nothing changes — the user must re-inspect;
  check code signature validity with `SecStaticCodeCheckValidity(kSecCSCheckAllArchitectures | kSecCSStrictValidate)`
  — an invalid signature (e.g. an in-place file write that broke the resource seal) → `EX_INTEGRITY`, nothing
  changes, and `--trust` cannot override it; only `--export`/`--discard` remain (R3-B6). The engine never re-signs
  an app bundle; if its Team ID differs from `trusted.teamId`, or for ad-hoc apps whenever cdhash
  changed, require `--trust`, i.e. explicit trust approval as in `isenough trust`) → `packed` (normal pack
  pipeline from the retained bundle into a **new** image + manifest + catalog; upload confirmed per §7.2) →
  `switched` (`apps[id].imageId` = new image, `trusted` updated, stub rebuilt if its Info.plist changed) →
  `disposed` (retained bundle moved to the Trash — only now, after the new image is verified in cache or uploaded;
  rule "never delete the only copy") → `cleared` (`needsResolution = null`) → `closed`.
- **`resolve --discard`**: `cleared` after moving the retained bundle to the Trash (user-recoverable; never `rm`).
  The old image remains the launch source. `--export <dir>`: moves it to `<dir>` (outside our control), then clears.
- **Crash during resolve**: recovery replays phases; until `cleared` the app stays blocked and the retained bundle
  (or its Trash/new image) exists; a crash in `packed` resumes like `pack --resume`.
- **v1 option (not MVP):** "launch retained" would add a `retained` restore source whose trust rule is the
  record's `treeHash` + explicit approval, and the same block-until-resolved invariant for subsequent updates.

### 5.9 Process ownership and usage roots (B4)

| Mode | Usage root(s) watched | Detach/cleanup gate |
|---|---|---|
| mount | `<mnt>` (realpath) | mount clean → detach |
| restore | `<dest>` (the restored bundle realpath) **and** its `.256isenough-staging/<txid>` dir | root clean → restore-out (§5.8.3) |
| translocated | not supported in MVP: quarantined bundles are refused at pack (§1.5). If at runtime a leased process's `proc_pidpath` lies under `/private/var/folders/*/AppTranslocation/` or any path outside the usage root, the launch is treated as a wrong-path instance (no lease, `EX_LAUNCH`, alert explaining `xattr` recovery) | the pid is added to `trackedDependents` (probe pass 5): the image stays mounted until it exits |

**What counts as a user (R2-B1).** A *dependent user* is a process that executes from, maps, holds open, or has its
cwd on a file **inside the usage root** (the mounted filesystem, or the restored bundle), plus explicitly tracked
dependents (below). The disk-image **attachment infrastructure** — the processes/kernel driver that keep the
*backing DMG* and `/dev/diskN` open for as long as the image is attached (`diskimagesiod`/`diskimages-helper`
family, depending on macOS version) — is *not* a user: it cannot go away before detach, so counting it would make
`idle` unreachable. The probe therefore does **not** inspect holders of the backing image file or of `devEntry`
in its normal passes; only files *on the mounted volume* matter, and infrastructure does not hold those.

**Probe** (`ProcessProbe.usage(root) -> clean | busy([pids]) | unknown(reason) | held(reason)`), primary
implementation in-process via `libproc` (no recursive scans):
1. Executables: `proc_listallpids` + `proc_pidpath` for every pid; path under the root → busy.
2. Open files, cwd and mapped files per pid: `proc_pidinfo(PROC_PIDLISTFDS)` + `PROC_PIDFDVNODEPATHINFO` for vnode
   fds, `PROC_PIDVNODEPATHINFO` for cwd, `PROC_PIDREGIONPATHINFO` iteration for mapped files (dylibs/frameworks
   loaded from the root); any path under the root's realpath → busy. For mount mode the match is additionally done
   by device: vnode `vst_dev` == the mounted filesystem's `st_dev` (catches renamed/unlinked files). This replaces
   r1's `lsof +D` (no assumption that bundles are small). `lsof -Fpn -- <mnt>` (filesystem selector) is run every
   30 s as a cross-check in mount mode; a disagreement is logged and the union counts.
3. **Supported inspection boundary (R3-B2, replaces r2's permission classes).** Facts the design relies on
   (validated by the CI probe artifact, §11.2): as a non-root user, `proc_listallpids` and `proc_pidpath` work for
   *every* pid (this is what `ps` uses), so pass 1 covers all users including root; per-fd/cwd/region information
   (`proc_pidinfo(PROC_PIDLISTFDS)`, `proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO)`,
   `PROC_PIDVNODEPATHINFO`, `PROC_PIDREGIONPATHINFO`) is available only for our own uid. Errors are split (N3):
   `ESRCH` / pid gone / start time changed → the process exited, skip it (it is re-listed next probe); `EPERM` →
   *uninspectable*; anything else → `unknown(probeError)`. Every uninspectable pid is classified once per
   (pid, start), with the reason kept in `details.uninspectable[{pid, uid, path, class}]` for `status`/`doctor`:
   - **own** — our uid: never expected to be EPERM; if it is → `unknown` (≡ busy, unchanged).
   - **related** — another uid (root or other user) and any of: executable under the usage root (already busy by
     pass 1); executable path in the app's **related set** = helper paths declared by the bundle and recorded at
     pack in `manifest.app.related` (`SMPrivilegedExecutables` labels → `/Library/PrivilegedHelperTools/<label>`,
     `Contents/Library/LaunchServices/*`, embedded LaunchDaemons/Agents `Program`/`ProgramArguments[0]`, login
     items) plus user-added `apps.<id>.relatedExecutables` (config); a `system/`-domain launchd job whose label is
     in that set; or a non-nil signing Team ID (from `SecStaticCodeCreateWithPath` on its executable — static
     check of the on-disk file, which needs no access to the process) equal to the app's Team ID. A related
     uninspectable process → `unknown` (≡ busy): it could genuinely depend on the bundle and we cannot see its fds.
   - **platform** — another uid, not related, executable on the sealed system volume (`/System`, `/usr`, `/bin`,
     `/sbin`, `/Library/Apple`) and `SecStaticCode` validates it against the Apple anchor (platform binary) →
     **ignored**, listed only.
   - **unrelated** — another uid, not related, not platform, valid static signature with a different (or nil)
     Team ID → **ignored**, listed only. If its signature cannot be read/validated at all → `unknown` (we cannot
     establish that it is unrelated).
   **Why platform/unrelated may be ignored — per mode, not by DAC:**
   *Mount mode:* the probe only decides *when to attempt* a detach; the completeness proof is the kernel's: a
   non-forced `hdiutil detach` (unmount without `MNT_FORCE`) fails `EBUSY` while *any* process of any uid —
   including root — has a file open, mapped, executing or as cwd on the volume; that yields `backoff` (§5.4), never
   data loss. r2's "0700 excludes other users" argument is withdrawn (it never excluded root). `-force` detach
   (opt-in, default off) is additionally refused while any related or `unknown` pid exists.
   *Restore mode:* there is no kernel gate (renames succeed with open files), so the restriction is explicit.
   Supported assumption **A-R**: the only processes that can *depend* on a restored bundle (execute or map code
   from it, keep it as cwd, or need it to stay in place) are own-uid processes (fully inspected), processes
   executing from it (pass 1, all uids), and the app's related set (declared helpers, same Team ID, configured
   extras). Apple platform daemons and unrelated third-party daemons only *read* bundles transiently (Spotlight,
   `syspolicyd`/XProtect assessment, Time Machine, backup/antivirus scanners); for them restore-out is harmless
   because it moves the bundle by `rename` (an open descriptor stays valid), deletes `app.old` only after
   cdhash+tree-hash inspection proves an identical copy exists, and otherwise retains it. Out of scope (documented
   restriction): another *logged-in user* opening files inside our restored bundle with a non-platform tool of a
   different team (not observable without privilege). **Unsupported-preflight:** temporary restore is refused
   rather than promised when cleanup could never become clean: (i) `pack` classifies a restore-mode app whose
   embedded daemon/helper plist has `KeepAlive` or `RunAtLoad` true as **`unsupported`** with reason
   `persistentRelatedHelper` ("keep this app installed normally; temporary restore cannot detect when its root
   helper stops using it"), and (ii) restore-in's preflight (§5.8.1) refuses with `EX_UNSUPPORTED` (before any
   change) if a related uninspectable process is already running.
4. launchd (restore mode only): `launchctl print gui/$UID` entries whose program path is under the root: with a
   running pid → busy (also caught by pass 1); registered but **not running** → `held(registered: <label>)`. A held
   restore session is not cleaned up (removing the bundle would break the registration) but is reported as
   "registered login item/agent", not as "in use"; `doctor` suggests `restore --permanent` or removing the item.
5. **Tracked dependents** (the only use of backing-file/devEntry checks): if a lease or identity check found a process
   of our bundle running from a path outside the root (translocation, or a wrong-path instance that might be backed
   by our image), its (pid, start) is stored in `mount.trackedDependents`; while any tracked pid lives → busy. This
   is checked by pid liveness, not by enumerating backing-file holders.
6. **Infrastructure baseline** (diagnostic and for the detach error path): right after a successful attach and
   before opening the app, the supervisor records the holders of the backing image and `devEntry`
   (`lsof -Fpn -- <imagePath> <devEntry>`) as `mount.infra = [{pid,start,path}]`, accepting only Apple platform
   binaries under `/System` or `/usr/libexec` (verified with `SecCode` platform-binary check). The set may be
   **empty** (OS versions with an in-kernel disk-image path, N3); nothing requires it to be non-empty. When a detach fails
   busy, holders outside `infra` are reported in `detach.lastError` to explain the failure. They never block `idle`.
`unknown` ≡ busy: cleanup waits and retries (backoff to 5 min, indefinitely), state shows `waiting(unknown)` and
`doctor` explains which probe failed. Restored bundles are **never** removed while busy/unknown/held; there is no
force option for restore cleanup.

**Identity of launched instances:** each lease stores `{pid, start, bundleURL, executablePath}` checked at open
time (§5.2.6) and on every probe; NSWorkspace returning an existing instance of the bundle id from another path is
detected and rejected. Kept originals (`--keep-original`) are renamed `Foo.256orig.app` *and* moved into
`retained/` (and `lsregister -u`'d, best effort) so LS is less likely to prefer them. This is **not** relied upon
(N4): what is authoritative is that we always open by explicit path (`openApplication(at:)`) and verify every
returned instance's path (§5.2.6); LS's preferred URL for the bundle id is only logged as a diagnostic.

---

## 6. Cache & LRU

- **Location**: `~/Library/Caches/256isenough/` (configurable): `images/` (verified, ready), `partial/` (`.part` +
  `.part.json` resume metadata: imageId, expected size/sha, bytes, partial hash state is *not* persisted → on resume
  we re-hash the existing prefix), `bad/` (quarantined mismatches, deleted by gc after 7 days), `mnt/` (mountpoints).
  `~/Library/Caches` is excluded from Time Machine by convention; we also set `NSURLIsExcludedFromBackupKey`.
  The cache must be on the internal APFS Data volume (doctor warns otherwise).
- **Accounting** (allocated sizes, `totalFileAllocatedSize`, never logical): `usedFinal = Σ complete images/ files
  + Σ unclaimed leftovers in partial/` (resumable partials without a live claim, `bad/`); in-flight files of a live
  claim are *not* in `usedFinal` (they are tracked by the claim, §6.1), so nothing is counted twice.
- **Quota** `quotaBytes` (default 20 GiB) applies to **final** cache contents. **Free-space floor** `minFreeBytes`
  (default 15 GiB, read via `volumeAvailableCapacityForImportantUsageKey`) applies to **transient** peaks, per volume.

### 6.1 Capacity admission: final-size quota + transient free-space claims (R2-B3)
Two independent checks replace r1's single `used + reserved + peak` formula (which double-counted allocated work
and charged transient bytes to the quota).

**Sizes of one fetch** (all allocated bytes, on the cache's Data volume; iCloud Drive lives on the same volume):
`M` = repo file materialization (= remote size if it was dataless before the fetch, else 0); `C` = ULMO copy in
`partial/` (= remote size); `F` = final local image = `manifest.image.localSizes[localFormat]` (measured at pack,
§3.2) or, for old manifests, the pessimistic estimate (`UDRO`: `unpackedSize`×1.05; `ULFO`: max(2×remote,
`unpackedSize`×0.8)) — after the fetch the measured value is stored in the cache entry.
Stages and their maximum simultaneous allocation: materialize `M` → copy `M+C` → verify, then evict the repo copy
when allowed (§6.2) → convert `C+F (+M if not evicted)` → done `F (+M if not evicted)`.
`planned` = `M + C + F` (pessimistic: the repo eviction may fail, e.g. Optimize Mac Storage off).
`persistent` = `M` when eviction is known unavailable (`keepRemoteDownloaded`, Finder-pinned repo file, or
`ICloudBackend.canEvict == false` — learned when a previous evict left the status `.current`), else 0.

**Claim** (`state.claims`, written under L3 before the first byte; one per in-flight image):
`{owner, imageId, volume, quotaBytes = F, plannedBytes = planned, allocatedBytes, persistentBytes, stage}`.
`allocatedBytes` = bytes currently allocated by this claim's own files (measured: repo file if it was dataless,
`.part`, `.tmp`), updated under L3 at each stage boundary and every 256 MB of progress. At each stage boundary
`plannedBytes` is lowered to the maximum allocation of the *remaining* stages (after conversion: `F + persistent`).
`remaining(claim) = max(0, plannedBytes − allocatedBytes)`: only bytes **not yet materialized** are reserved; bytes
already allocated are already reflected by the OS free-space value, so they are not counted again.

**Admission** (under L3 for reads/writes; reclamation under try-locks outside L3, §5.6.1), for a new claim `X`:
1. *Quota (final sizes):* `needQ = usedFinal + Σ_otherClaims quotaBytes + F_X − quotaBytes`.
2. *Free space (transient, per volume):* `needF = minFreeBytes + Σ_otherClaims remaining + planned_X − free`.
3. If both ≤ 0 → write claim, done. Else `planEviction(max(needQ, needF), …)` over victims on that volume (§6.2;
   excluding mounted, claimed, pinned, `needsResolution`, and locked ones); release L3; delete victims with try-locks;
   re-read under L3 and recompute (other claims may have changed). Repeat while each round freed > 0 bytes; a round
   that frees nothing (all candidates busy or none left) → `EX_NOSPACE` with `{needQ, needF, plan, pinned}` in
   `details`. Termination: every round either deletes ≥ 1 victim (finite set) or stops.
4. Persistent `M` (retained iCloud bytes) is **not** charged to the cache quota (it is the user's iCloud Drive, not
   our cache) but it is part of `planned`, so free-space admission budgets it; `status`/`doctor` report "iCloud
   keeps full copies: X GB" so the user sees it.

**Completion/failure.** Success: in one L3 write the cache entry (measured `F`) is added and the claim deleted
(bytes move from claim to `usedFinal`). If the measured `F` exceeds `quotaBytes` admitted, the quota pass after the
session evicts others (never the just-used image unless it alone exceeds quota); the launch is not failed.
Failure/cancel: delete `.part`/`.tmp` (or keep a resumable `.part` as an unclaimed leftover), delete the claim.
**Claim ownership (R3-B3).** A claim is owned by exactly the process that writes its files: writer = claim owner,
and the writer holds L2(img) from before its first byte until after the claim is converted or deleted (§5.2.3c,
§5.6.2). There is no claim transfer: a launch that waited for a failed/dead prefetch re-admits under its own
identity. **Reaping** a dead owner's claim requires holding (or try-locking) L2(img) and re-checking under L3 that
the owner (pid+start) is dead; since a live writer always holds L2 and owns its claim, a reaper can never free
the reservation of an active writer. Reaped claims' files become leftovers for gc. Restore/unpack claim the extracted size
on the destination volume (free-space check only); pack claims `unpackedSize` (staging) + image sizes.
**ENOSPC** despite admission (other programs consumed space): as failure, `EX_NOSPACE`; never a half-converted image in
`images/`.

**Tests (pure `CapacityPlanner`, Linux).** (a) A19/A20 numbers: `Q = A2 + A1/2`, incompressible app2 with `C≈F2`
→ app2 admitted after evicting app1 (quota counts only `F`), and refused with pinned app1. (b) Two concurrent claims
advanced stage by stage (materialize, copy, evict-repo, convert, done) with a fake volume whose free space is
decremented by actual allocations: at every interleaving step `free − Σ remaining ≥ minFree` holds, no byte is counted
both in `usedFinal` and a claim, and both complete when `free ≥ minFree + planned1 + planned2`, while exactly one is
admitted when only one fits. (c) Persistent `M`: with `canEvict == false` the second admission sees the first's
`M` in `free`, not in the quota. (d) Measured `F` > estimate → completion succeeds, quota pass evicts. (e) Claim
handoff (R3-B3), pure model with an explicit scheduler: prefetch paused between claim publication and L2 acquisition
is impossible by construction (both inside one L1 hold) — the model checker enumerates interleavings of
{prefetch, launch, reaper, third-app admission} and asserts writer = live-claim owner at every step. Real
multiprocess variants are in §11.2.

### 6.2 Eviction, pins, versions, iCloud interaction
- **Eviction algorithm** (`planEviction`, pure, deterministic for tests):
  1. Candidates = cache entries that are complete, not mounted (no mount record of any phase incl. `backoff`/`stuck`,
     and no `hdiutil info` attachment of the file), not part of an active session, not pinned, not claimed/being
     fetched, not locked (try-lock fails), not belonging to an app with `needsResolution`. Unclaimed leftovers
     (resumable partials, `bad/`) are candidates first.
  2. Order: orphans first (image not referenced by any app in state/catalog or superseded versions), then by
     `lastUsedAt` ascending (LRU), tie-break larger size first, then imageId.
  3. Take until `need` satisfied. If impossible → `EX_NOSPACE` with the plan in `details` (UI suggests unpinning).
  Pinned images may exceed quota (warning in `status`/`doctor`).
- **When**: before fetch (admission, §6.1), after each session ends (post-quit step 6, after releasing the app lock), `gc`, daemon every 6 h, and on
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

**Publication rule (N2, N3).** `put` is atomic only when `capabilities.atomicPut`. A non-atomic store must still
make the object appear at its final path (`image.file`): it uploads to `<dir>/.<name>.tmp-<uuid>`, verifies it
(`stat` size + server hash or full re-read hash), then promotes it with the backend's rename primitive (WebDAV
`MOVE` with `Overwrite: F`, OpenList `/api/fs/rename`); if the server lacks rename it uploads directly to the final
path. Neither rename nor direct upload is assumed atomic (WebDAV `MOVE` is not universally atomic): *publication*
is defined by the manifest: an image is visible only after its manifest is written, and a
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

### 7.4 Phase 2 backends
Implemented on the synchronous `StorageBackend` (`docs/backends.md`): SMB/NFS via `mount_smbfs -N` / `mount_nfs` or an already-mounted path, WebDAV via PROPFIND/GET Range/PUT/MOVE. Credentials stay in the Keychain. `hdiutil create`/`convert` still builds ULMO/ULFO images. The notes below are the original design; where they disagree with `docs/backends.md`, the note file is what the code does.

- **NAS via mounted path (SMB/NFS)**: `LocalFolderBackend` + `mountURL` (`smb://nas/share/256isenough`); `ensureMounted`
  uses `NetFSMountURLAsync` / `open smb://…` once, keychain credentials; availability = path is a mountpoint reachable
  within 3 s (avoid hanging `stat` on dead SMB: probe in a child task with timeout). Never run apps from the share.
- **WebDAV** (`WebDAVBackend`, URLSession): `PROPFIND Depth:1` → list/stat; `GET` + `Range: bytes=a-b` → get;
  `PUT` to `.name.tmp-uuid` then `MOVE` (Overwrite: F) → put (not advertised as `atomicPut`; the manifest-last
  publication rule applies; the manifest itself is small and re-read+hash-checked after writing); `DELETE`. Basic/Digest auth from keychain.
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
- **Request protocol (B5, R2-B2) — identical for owner and joiner supervisors.** The stub spawns **one**
  supervisor: `isenough hook launch --app <appId> --stub <path> --control-fd 3` via `posix_spawn` +
  `POSIX_SPAWN_SETSID`; fd 3 is a socketpair (bidirectional, ordered, NDJSON). No documents are passed on argv.
  Whether that supervisor becomes owner or joiner (§5.6.3) is invisible to the stub. Messages:
  - stub → supervisor: `{"type":"open","req":n,"documents":[…],"urls":[…],"arguments":[…]}` (`req` strictly
    increasing; initial batch after a 300 ms coalescing window, later events immediately); `{"type":"cancel"}`;
    `{"type":"bye","gen":g,"lastReq":r}` (close request of generation `g`, covering every `req ≤ r`).
  - supervisor → stub: `{"type":"progress",…}` and `{"type":"heartbeat"}` (≥ every 2 s until `ready`),
    `{"type":"ack","req":n,"status":"delivered"|"error","code":…,"message":…}`, `{"type":"ready"}` (target app
    running), `{"type":"done","gen":g,"lastReq":r}`. Heartbeats come from a dedicated thread, so they continue
    while the supervisor blocks on a lock (e.g. a second stub waiting for L1 during the first one's download shows
    "waiting for another launch of Foo").
- **Supervisor rules.** It reads fd 3 until EOF for its whole life — `bye` does **not** stop it from accepting
  `open`s. Batches are queued before `ready` and delivered in `req` order (first via `openApplication`+`open(urls…)`,
  later via `open(urls, withApplicationAt:)` on the verified instance); each is acked after NSWorkspace's completion
  handler returns. On `bye(g, r)` it sends `done(g, r)` once every `req ≤ r` has been acked (never earlier). It never
  closes fd 3 first. An **owner** keeps running after EOF (session continues, "client gone"); a **joiner** exits on
  EOF once all received batches are acked — this is its **only** exit condition; it never exits on `bye`/`done`
  (R3-B1, §5.6.3 defers to this paragraph). A joiner killed early only loses batches it never acked — the stub sees
  EOF with them outstanding, below.
- **Stub closing algorithm (lossless at the protocol level).** State: `maxSent`, `acked` set, `gen`. After `ready`
  and a 500 ms quiet period with `outstanding == 0`, it sends `bye(gen, maxSent)`. Any Apple Event that AppKit
  dispatches *after* that (whether before or after the supervisor read `bye`, and before `done` arrives) is sent as
  a new `open` with `req = maxSent+1` on the same socket and **invalidates** the close: `gen += 1`. On receiving
  `done(g, r)`: if `g ≠ gen` or `r < maxSent` it is stale and ignored (the stub waits for acks, quiet period, and
  sends a fresh `bye(gen, maxSent)`); if it matches and `outstanding == 0`, the stub runs a **final drain** on the
  main thread — one zero-timeout pass of the run loop in `.default` and `.modalPanel` modes, which services the
  Apple Event port — and if that drain dispatched an event, the close is invalidated as above; otherwise it calls
  `exit(0)` in the same main-thread turn, without returning to the run loop. Since Apple Events are only handled on
  the main thread, no event dispatched to our handlers can be lost; the stub never terminates with outstanding
  batches.
  *Residual OS window (documented, not claimed away):* an Apple Event whose mach message is enqueued during the
  microseconds between the final drain and `exit` is undeliverable to *any* exiting macOS process; the sender
  (Launch Services) gets `connectionInvalid`/`procNotFound`. This is the same window every app has at termination;
  it is minimized by the drain and the 500 ms quiet period and is the only remaining case. The e2e race tests
  (A11c/A22) record any such miss as a failure so we would learn if it is observable in practice.
- **Timeouts and errors.** No `ready`/heartbeat/progress for 30 s → panel shows "256isenough is not responding" with
  Wait / Cancel (fetch stalls are handled by the supervisor's own stall timer, §9). After `bye`, no matching `done`
  within 10 s while `outstanding == 0` → resend `bye` once, then exit (nothing is outstanding, so nothing can be
  lost). **EOF/EPIPE with outstanding batches** (supervisor crashed or a joiner was killed): the stub spawns **one**
  fresh supervisor (which will join or own the session) and re-sends exactly the unacked batches with their
  original `req` ids (delivery is at-least-once: a duplicate forward is possible only if the old supervisor
  delivered but died before acking; documented). If the second supervisor also fails before acking,
  the stub alerts listing the undelivered documents/URLs. An `ack` with `status:"error"` → `NSAlert` for that
  batch only.
- **Disconnect safety.** The supervisor treats EOF/EPIPE on fd 3 as "client gone": it stops progress writes, keeps
  running the session normally, and logs unacked batches. Closing or killing the stub never affects the app or the
  session.
- **Deterministic tests** (`StubProtocol`, pure state machines driven by a scripted transport, Linux): event injected
  (1) after `bye` sent but before the supervisor reads it, (2) after the supervisor read `bye` but before `done` is
  written, (3) after `done` is written but before the stub reads it, (4) during the final drain; in all cases the
  batch is acked before exit, the stale `done` is ignored and a second `bye` generation completes. Plus: joiner
  receiving 3 batches across 2 generations; **`open(gen+1)` arriving on a live-session joiner's connection after it
  sent `done(gen)`** → the same joiner process acks it (no respawn, no EOF observed by the stub) and exits only
  after the stub's EOF (R3-B1); supervisor EOF with 2 outstanding → respawn re-sends them; `done` timeout
  with nothing outstanding → exit; owner continues after EOF. A macOS integration test drives the real stub binary
  with a fake supervisor and real Apple Events (`NSAppleEventDescriptor` sent via `AESendMessage`) timed around `bye`.
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
| Detach busy | hdiutil exit 16 / "Resource busy" / devEntry still present | `backoff` (mount record + ownership kept, joinable) → `stuck` after `detachRetryMaxSeconds`: supervisor exits 6, notification, retried by daemon/gc/`isenough detach`/next launch (revive); never `-force` unless configured (§5.4). |
| Supervisor / engine crash | dead owner (pid+start) with session record | **Recovery** at every supervisor start, `gc`, daemon start, per app under L1 (§5.6.4): first replay non-session journals (§5.8), then dispatch by mode (§5.6.4). Mount: reconcile `state.mounts` with `hdiutil info -plist`: (a) attached with our image path *and* our mountpoint but not in state → adopt; (b) in state but not attached → drop record; (c) dead owner → single adopter elected under L1+L3: watch if busy/unknown else post-quit. Same image attached elsewhere → report only. **Restore** (R3-B4): never uses the attachment check — driven by the open restore journal, `destId`/`stubId`, owner and the restore-mode probe (§5.6.4b table): busy → adopt and wait; clean → restore-out → `retired`. `status` is read-only and never recovers. |
| Corrupt `state.json` | JSON decode error | Move to `state.json.corrupt-<ts>`, rebuild from cache dir listing + `hdiutil info` + stubs found via `mdfind kMDItemCFBundleIdentifier == '*.256stub'` and `/Applications` scan. |
| Offline, image cached | backend `.unavailable` | Launch works (no backend access needed on cache hit: manifest is cached in `cache/manifests/`). Device-file update deferred. |
| Offline, not cached | `.unavailable` | Fail fast (≤ 5 s probe) `EX_BACKEND`: alert "Blender is not available offline. Pin apps to keep them offline." |
| iCloud not signed in / Drive off | `ubiquityIdentityToken == nil` | `EX_BACKEND` with specific message; `doctor` explains. Cached apps still launch. |
| Disk full | admission fails (§6.1) or `ENOSPC` during copy/convert | Evict per LRU; if still short → `EX_NOSPACE`, delete `.part`, alert lists pinned images + sizes. |
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
| `Locks/Capacity` | lock-order checker (blocking out-of-order acquire throws; try-lock out of order allowed); `CapacityPlanner` tests (a)–(d) of §6.1; claim stage updates; dead-owner reaping; reclamation rounds terminate (all victims busy → `EX_NOSPACE`, never loops). |
| `Tx` (journal) | fault injection at every point of every transaction (§5.8.6); invariant + idempotent recovery; changed-bundle retention; hook-failure rollback; simulated self-update → `retained/` + `needsResolution`. |
| `StubProtocol` | NDJSON codec; supervisor-side queue/ack ordering and `done` only after all `req ≤ lastReq` acked; stub close state machine with generations — the four injection points and joiner/respawn cases of §8.3; EOF/EPIPE marks client gone without aborting the session. |
| `DetachMachine` | pure §5.4 outcomes with a fake `DiskImageTool`: detached / busy×n then detached / exhausted→stuck (record kept, exit 6) / ownership mismatch→stuck / externally detached; revive from idle, backoff and stuck (epoch++, hooks once per epoch); owner's next step-2 sees `running` and does not detach; recovery of stuck/crashed `detaching`. |
| `UsageProbe` | pure classifier over fake `libproc` snapshots: infra holders of image/devEntry ignored; file/cwd/mmap on the mount → busy; same-uid EPERM → unknown; other-uid EPERM ignored in mount mode, unknown in restore mode; registered-not-running launchd job → held; tracked dependent alive → busy. |
| `Engine` (fake `Platform`) | pack → stub build (fake signer) → launch (fake attach/launcher) → quit → detach after delay (fake clock) → LRU updated; two concurrent launches = one attach + one forward; join at detach deadline; supervisor crash → single adoption; offline cached vs uncached; restore-mode swap & rollback; wrong-path instance rejected; probe `unknown` blocks cleanup; post-quit with detach busy → backoff → revive by a joiner → second quit → detach; `needsResolution` → launch refused before any change. |

### 11.2 macOS integration tests (`IsenoughMacTests`, CI only, `#if os(macOS)`)
- `HdiutilDiskImageTool`: create ULMO from fixture folder, convert ULFO, attach with `-plist` (parse devEntry/mount),
  re-attach detection, detach, busy detach (hold an open file handle → exit 16 → retry succeeds after close).
- `MacAppInspector` on the fixture app (bundle id, doc/URL types, codesign info, ad-hoc kind).
- `CodeSigner` + `StubBuilder`: produced stub passes `codesign --verify --strict` and `plutil -lint`.
- `MountUsageProbe` (early in G-a, non-root runner, N2): attached image with no user → `clean` although the backing
  DMG is held by disk-image infrastructure (the recorded `infra` set may be empty, N3); spawn a process from the mount
  → busy; after exit → clean; a process (not under the mount) holding only a data file on the mount → busy; an mmap
  only → busy; a helper surviving its parent → busy; then detach succeeds. Records which pids give EPERM on
  the runner and their class (artifact) to validate the inspection boundary of §5.9 pass 3.
- **Real non-root probe vs. the normal process population (R3-B2, required, G-a/G-b).** The probe runs as the
  runner's ordinary user with the runner's full root/system process population present (no filtering of the
  environment). (1) An idle mounted fixture → `clean` (two passes) although dozens of root pids return EPERM
  (asserted: `details.uninspectable` non-empty, all `platform`/`unrelated`). (2) An idle restored fixture → `clean`
  and restore-out runs. (3) A **relevant unreadable holder**: the test harness (only the harness uses the runner's
  passwordless `sudo`; the engine never does) starts `sudo $E2E_DIR/helpers/E2ERootHelper`, configured as
  `relatedExecutables` of the restored fixture, which opens a file inside the restored bundle → probe `unknown`,
  bundle stays in place, `status` shows `waiting(unknown: related pid … uninspectable)`; after the helper exits →
  clean → restore-out. (4) Mount-mode kernel gate: `sudo /bin/cat <mnt>/…/file` (platform, ignored by the probe)
  holding the file → the detach attempt fails busy → `backoff`, mount kept; after it exits → detached.
  (5) Error split: a pid that exits between listing and inspection is reported `exited`, not `unknown`.
  (6) Classifier: fixture with a `KeepAlive` embedded LaunchDaemon plist → `unsupported`, reason
  `persistentRelatedHelper`.
- **Multiprocess lock tests** (real processes via `isenough` built binary): launch vs `evict` vs `prefetch` vs `gc`
  started together (random order, 50 iterations) → no attach of a missing file, no deleted mounted image, no
  corrupt `.part`; two `gc` processes recovering one dead owner → exactly one adopter; two different-app fetches
  sized so only one fits → one succeeds, other `EX_NOSPACE` (claim admission), never both.
- **Low-space reclamation under contention (R2-B4)**, lock-order checker enabled, 30 iterations: cache holds
  idle app1 (unpinned); quota/minFree set so app2's launch must evict app1; concurrently run `launch app1 --no-wait`
  (wants app1's L1/L2), `launch app2`, `prefetch app3` and `gc`. Each run ends within a timeout (no deadlock/livelock);
  app2 either launches after evicting app1, or exits `8` only if app1 was mounted/claimed at that time (logged
  reason `victim busy`); never an attach of a deleted file; no checker violation.
- **Prefetch/launch claim handoff (R3-B3)**, real processes, test-build hold points (`--test-hold <point>` read
  from the isolated test config, compiled out of release builds, N4): (1) `prefetch app1` held at `claimPublished`
  (after the claim write, before L2) while `launch app1` starts → the launch blocks on L1 (the hold is inside the
  L1 hold), never writes; release → prefetch becomes writer, launch waits on L2 and finds the image cached.
  (2) prefetch held at `l2Acquired`, launch started (blocks on L2), then `kill -9` prefetch → launch takes L2,
  reaps the dead claim, re-admits under its own pid, resumes from the `.part`, completes; at every sampled moment
  `state.claims` has exactly one claim for app1 whose owner is the process holding L2 (checked via a test-only
  `isenough debug locks` that reports flock holders). (3) During (2) a third-app `prefetch app3` sized so it fits
  only if app1's reservation were freed early → it is refused `EX_NOSPACE` (or waits for app1's completion,
  then succeeds), never admitted while app1's writer runs without a claim. 20 iterations each.
- **Journal fault tests on real APFS**: child process `kill -9` at each fault point, then recovery (§5.8.6).

### 11.3 End-to-end: `scripts/e2e.sh`
Single portable bash script (macOS 13+, bash 3.2 compatible, no Homebrew deps). Runs on GitHub Actions `macos-latest`
(`.github/workflows/macos.yml` job `e2e`) and on any Mac by `./scripts/e2e.sh` (needs Xcode CLT for `swift build`).
Everything lives in `E2E_DIR=$(mktemp -d)`; nothing touches `/Applications`, real iCloud, or user config:
`HOME` is not changed, but `ISENOUGH_CONFIG`, `--state-dir`, cache dir, repo root and stub install dir all point into
`$E2E_DIR`. A `trap` cleanup **first** copies diagnostics to `$E2E_DIR/artifacts/` (`events.jsonl`, `isenough.log`,
`state.json`, journals, `hdiutil info -plist`, `lsregister -dump | grep $E2E_DIR`, `ps`, `log show --last 5m
--predicate 'process == "isenough" OR process == "isenough-stub"'`) and copies them to `$E2E_ARTIFACTS` if set (CI upload),
then `lsregister -u`s the stub, fixture and mounted-app paths **before** detaching (N5), detaches only images whose
backing path is under `$E2E_DIR`, and deletes the dir (unless `KEEP=1`). Every relaunch step first removes
`$E2E_DIR/quit-now` (N5). Every step logs the exact command it runs (`set -x` style prefix) so a run is
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
   - A11c `doc_during_close` (R2-B2, R3-B1, N4): the hold switch reaches LS-launched processes explicitly, not via
     the script's environment (LS does not inherit it): test builds of the stub read `Resources/test-hooks.json`
     inside the *test* stub bundle (written by the e2e stub builder before signing) and the supervisor reads
     `testHooks` from the isolated `$E2E_DIR` config; both readers are compiled only with `-D ISENOUGH_TEST_HOOKS`
     and absent from release builds (a CI step greps the release binaries for the symbol). Value `hold: bye|done`
     pauses 1 s right after sending `bye` / before sending `done`; during the pause the script runs
     `open -a <stub> docN.txt`; repeated for both hold points and for an owner and a joiner stub → every `open`
     event is present exactly once and every stub exits 0; for the joiner case the supervisor log shows the late
     batch acked by the **same** joiner pid (no respawn) and that joiner's exit only after EOF.
   - A12 `second_launch_no_remount` (**required**): `open -a <stub> "isenough-e2e://hello?x=1"` → `open` event with that URL appears
     within 10 s; still exactly one attachment of the image in `hdiutil info`; same app pid.
   - A13 `prelaunch_hook_ran`: a local hook `hooks/io.github.s546126.e2eapp/pre-launch` (installed before step 4)
     wrote `$E2E_DIR/hook-pre.env` containing `ISENOUGH_PHASE=pre-launch` and `ISENOUGH_MOUNT_POINT=<mnt>`.
5. **Quit**: `touch $E2E_DIR/quit-now`; config for e2e sets `detachDelaySeconds: 3`.
   - A14 `app_exited`: pid gone within 10 s.
   - A15 `idle_then_detached` (R2-B1, N5): `isenough status` polled every 0.5 s shows `idle` within 15 s of the pid
     exit (two clean probes ≥5 s apart), then within `3 + 20` s of `idle` the image is absent from `hdiutil info`
     and the mountpoint dir is removed. (The attached image's own infrastructure holding the backing DMG does not
     block this, §5.9.)
   - A16 `postquit_hook_ran`: `hook-post.env` contains `ISENOUGH_PHASE=post-quit` and `ISENOUGH_EXIT_STATUS` ∈
     {`unknown`, `crash`} with value `unknown` for this clean quit (no numeric status is promised, §5.4).
   - A17 `lru_updated`: state `apps[..].lastUsedAt` > launch time, `launchCount == 1` (the URL forward doesn't count),
     cache entry `lastUsedAt` updated; state `cached`; `supervisor` process gone; device file written in repo.
6. **Cache hit relaunch**: `isenough launch <app> --no-wait`, then quit.
   - A18 `cache_hit`: `events.jsonl` for this session has no `fetch.start`; launch < 10 s; detaches again.
7. **LRU eviction (deterministic sizes, R2-B3)**: the quota counts final local image sizes only (§6.1), so the
   script derives everything from measured final sizes. After step 6, `A1` = allocated bytes of app1's cache file
   (`stat -f %b` × 512). It packs `…e2eapp2` with **incompressible** random padding so that `F2 =
   manifest.image.localSizes.ULFO ≥ A1 + 20 MB` (measured by pack, §3.2), and sets `Q = F2 + A1/2` (each fits
   alone, both never fit; the margin A1/2 absorbs allocation rounding) and `minFreeBytes = 0` (transient peaks
   `M+C+F2` are checked against real free space only, which the runner has). Then `launch app2` and quit.
   - A19 `lru_evicted`: app2's admission evicted app1 *before* fetching (event `admission.evict app1`), app2
     launched and is cached, app1's file removed; `usedFinal ≤ Q`; no claim left; `gc --dry-run --json` plan empty.
   - A20 `pin_respected`: `pin app1` → admission of app1 evicts app2 (unpinned) and fetches app1 — assert app1
     cached, app2 not. Then `launch app2 --json` exits `8` (`EX_NOSPACE`, `details.pinned` lists app1): pins are never
     evicted. Then `unpin app1`; `launch app2` succeeds (evicting app1).
8. **Races** (real processes): `launch app1 --no-wait & evict app1 & prefetch app1 & gc &` (20 iterations, random
   start delays) → A21 `race_safe`: every launch either ran from a verified mount or exited `9`; no attach error; no
   leftover `.part`/`.tmp`; state passes `doctor`. A22 `relaunch_at_deadline`: with `detachDelaySeconds: 3`, quit the
   app and open the stub with a document at 2.9–3.1 s (loop of offsets) → either the session was revived (same
   mount, new epoch) or a fresh mount happened; the app event log shows the `open` event exactly once every time.
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
   - A27b `infra_not_a_user` (R2-B1): `prefetch` + an attach without opening the app (test-only `isenough debug
     attach <app>`): the probe reports `clean` while `lsof <imagePath>` shows the infrastructure holder; an mmap of a
     file on the mount by a `/usr/bin/python3` one-liner → busy; after it exits → clean.
   - A27c `busy_detach_backoff` (R2-B6): with `detachRetryMaxSeconds: 30`, a test-only fault
     `faults: ["detach:busy:<n>"]` in the isolated `$E2E_DIR` config (test builds only, N4) makes the first n detach attempts fail as busy (hdiutil is still called for real
     on attempt n+1). n=2 → `status` shows `backoff` with attempt counts, then detached; post-quit hook file shows
     exactly one run. During the 2nd backoff interval, open the stub with a document → session revived (same
     devEntry, epoch 2, document delivered once), no second attach; quitting again runs post-quit hooks once more.
     n=∞ → after 30 s the supervisor exits `6`, `status` shows `stuck` with the mount record kept, `evict app1`
     → `9`, quota pass does not touch the image; clearing the fault and running `isenough detach app1` → detached,
     record removed, `lastUsedAt` updated.
   - A28 `wrong_path_instance`: copy the fixture to `$E2E_DIR/other/E2EApp.app`, run it, then open the stub → stub
     alert/`EX_BUSY` (no lease on the foreign pid, no forward to it); quit the foreign copy and retry → normal launch.
   - A29 `quarantine_refused`: pack of a copy with `com.apple.quarantine` set → exit 3, nothing changed.
12. **Restore mode (required)**: fixture `E2EAppMAS` = E2EApp with a dummy `Contents/_MASReceipt/receipt` (the
   classifier only checks presence) installed into `$E2E_DIR/Applications`.
   - A30 `mas_forces_restore`: `pack --mode mount` exits 3; `pack` (auto) → mode `restore`.
   - A31 `restore_swap`: launch via the stub with a document → the real bundle is at the stub path while running
     (cdhash = manifest), the stub is in `.256isenough-staging/<txid>/`, document event logged; after quit the stub is
     back, staging/journal gone, and (R3-B5) `state.restored` has no entry, `lastOutcome == restoredOut`,
     `lastUsedAt` updated, `status` → `cached`; a second launch works normally (new txid); `evict app` then succeeds.
     This runs with the runner's normal root/system process population (R3-B2: the probe must become clean).
   - A32 `restore_helper_waits`: helper outliving the app keeps the restored bundle in place until it exits.
   - A33 `restore_fault_recovery`: for each fault point (test-only `faults` key in the isolated `$E2E_DIR` config,
     not an environment variable, N4), run a launch that `kill -9`s itself there, then `isenough gc`; assert the
     §5.8.6 invariant. The set includes restore-out `disposed:after`, `retired:before`, `retired:after` and
     `closed:before` (R3-B5): after each, `gc` twice, then assert a second launch, `status`, `evict` and a third
     `gc` all see the same terminal state (`restored` empty, journal closed, `lastOutcome` set, stub at dest).
   - A33b `restore_supervisor_killed` (R3-B4, required): launch the restored fixture with its helper; `kill -9` the
     supervisor while app and helper are alive; run two `isenough gc` concurrently → exactly one `adopt` event
     (`mode: restore`), the journal owner is the spawned `hook watch` process, no swap while app/helper live
     (real bundle still at dest, stub still parked). Opening the stub with a document now joins (document delivered
     once). Quit the app, then end the helper → within the probe interval + `detachDelaySeconds` the stub is
     reinstated, post-quit hooks ran exactly once (hooks policy), `restored` empty, journal closed, `lastOutcome
     == restoredOut`. Variant: kill at journal phase `installed` (before `active`) with the app running → adopted,
     not rolled back while busy.
   - A34 `restore_invalid_mutation` (R3-B6 a): the fixture writes a file into its own bundle during the session —
     this breaks the resource seal but does **not** change the executable's cdhash. After quit: bundle in
     `retained/`, `needsResolution` with the new tree hash (cdhash unchanged), nothing deleted. `resolve
     --keep-updated` and `--keep-updated --trust` → both refused `EX_INTEGRITY` ("retained bundle has an invalid
     code signature; export or discard it") and the retained bundle is untouched; `resolve --export
     $E2E_DIR/exported` → bundle moved there, app unblocked, launch uses the previous image.
   - A34b `unresolved_blocks_launch` (R2-B5): while A34's or A34d's record is set, opening the stub (with a
     document) → exit/alert `EX_RESOLUTION` (14), destination still holds the stub, retained bundle untouched.
   - A34d `restore_signed_update` (R3-B6 b, required): a genuine simulated update. During the session the
     **test harness** (never the engine) replaces the restored bundle at `<dest>` with `E2EApp` v1.1 built by
     `scripts/make-fixture-app.sh --version 1.1` and ad-hoc signed by the harness (`codesign --sign -`), so it has
     a valid signature and a different cdhash (asserted before quit with `codesign -dvvv`). After quit: retained,
     `needsResolution.cdhash` == the new cdhash. `resolve --keep-updated` without `--trust` → refused (ad-hoc and
     cdhash changed); `--keep-updated --trust` → new image packed + verified, `trusted.cdhash` updated, retained
     bundle moved to the Trash only after that, app launches from the new image (manifest tree hash/cdhash = the
     retained ones, version 1.1). A crash (`faults: resolve:<phase>:after`) at each resolve phase + `gc` → app still
     blocked or resolved, never without a copy. Then a second harness-built update (v1.2) + `resolve --discard` →
     Trash, launch uses the v1.1 image. The engine's code path never calls `codesign --sign` on apps (asserted by
     grepping the engine's command log).
   - A34c `prelaunch_hook_mutation`: a pre-launch hook writes into the restored bundle and exits 1 → `EX_HOOK`,
     bundle retained (tree hash differs, cdhash equal: tree-hash-only change, rollback coverage), stub back at
     the destination, `lastOutcome == rolledBack`, `needsResolution` set.
13. **Unpack**: `isenough unpack app1 --to $E2E_DIR/restored`.
   - A35 `unpack_ok`: restored app `codesign --verify --strict` ok and cdhash + tree hash equal manifest; stub removed.
14. **GUI auth smoke (daemon, no Pake)**: `isenough serve --port <free>`; with `curl`: unauthenticated `/api/apps` → 401;
   pairing code → cookie + csrf; cookie POST without CSRF/with foreign Origin → 403; `Host: evil.com` → 421; SSE
   stream receives an event for a `prefetch`. (Actual Pake startup is tested in the manual `gui.yml` job: build
   Pake app, start it with the daemon running, pair via a test hook, assert the page fetched `/api/apps` with 200.)

**Required gates.** A11/A11c (document via LS → stub → app, including events during the close handshake), A12 (URL
via LS → stub → live session), A15/A27b (detach despite attachment infrastructure), A19/A20 (capacity), A27c
(backoff/stuck), A31–A34d (restore swap, recovery/adoption, resolution) and the §11.2 real non-root probe test are required: there is no CLI/argv substitute that can turn them green. The stub is always launched
through Launch Services (`open -a <stub> <doc>`, `open -a <stub> <url>`), and the app event log must show
Apple-Event delivery (`application(_:open:)`), not argv. If LS/`open` is unavailable on a runner, the script exits `2`
(inconclusive → CI red) after collecting artifacts. A10 additionally asserts, via `proc_pidpath` of the returned
pid (authoritative, N4), that the instance runs from the mounted path; LS's preferred URL is logged only.

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
  G-a safe local mount lifecycle (local backend, cache, claims, locks, stub protocol, A1–A29). Within G-a, the
  pure state machines (stub close protocol, detach outcomes, capacity planner, lock checker) are built and tested
  first; the HTTP server is not started before G-d (N1). r3 priority (N1): the real non-root usage probe (§11.2) is
  the first macOS-runner deliverable of G-a, and both lifecycle modes (G-a mount, G-b restore incl. adoption)
  precede any server work; optional features are deferred before any safety gate is weakened;
  G-b safe restore (journal, fault injection, A30–A35); G-c iCloud materialization/upload (`icloud` backend, manual
  checklist on the user's Mac); G-d authenticated daemon + Pake GUI (§10.1, step 14). Shared repo hooks, `gc
  --remote`, and multi-Mac UX are deferred to v2 (local hooks stay MVP).
- Modes: mount (full lifecycle) and restore (journaled temporary swap + rollback). Classifier with hard constraints.
- Lifecycle: supervisor per session, leases, mount-usage probe, delayed detach with busy retry, recovery/adoption,
  user hooks (local only in MVP; shared repo hooks behind hash approval move to v2).
- Cache: ULMO remote → ULFO (or UDRO) local conversion, final-size quota + per-volume transient claims, LRU, pins.
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
- `diskutil image create` for ULMO pack images, after scrubbing and ownership match `hdiutil create`. Attach and detach already prefer `diskutil image` when that subcommand exists.
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

## 13. Agent session file offloading with hot/cold tiering

The command is `isenough sessions` (`docs/sessions.md`). A run without `--apply` is a dry run. Cold files are a monthly gzip tar on the active backend. The notes below are the original roadmap; the command, the 24 hour guard, and the index are what the code does.

## 13.1 Original roadmap notes

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
   moment; budgeted by the claim, §6.1); `cache.localFormat` can only choose ULFO or UDRO.
5. **Launch Services duplicates** (stub + mounted real app) may confuse "Open With" briefly during sessions.
6. **TCC**: same bundle id + DR should keep grants, but Accessibility/Input Monitoring toggles may need re-approval.
7. **macOS 27**: `hdiutil attach` is deprecated. The engine attaches with `diskutil image attach --plist --readOnly --mountOptions nobrowse --mountPoint` when `diskutil image --help` exits 0, and falls back to `hdiutil attach -plist -readonly -nobrowse -noautoopen -mountpoint` otherwise. Detach is `diskutil eject` (force: `eject force`, then `unmount force`). hdiutil's failure sentence follows AppleLanguages even with `LC_ALL=C`. Classify by exit status and plist, not by that sentence. `hdiutil create` remains the ULMO pack path. Stricter bundle validation for stubs still needs a 27 test.
8. **GitHub runners**: LS/`open` behavior on CI may differ; e2e then reports *inconclusive* (red), never a skipped
   pass; the same script runs on the user's Mac as the authoritative gate.
9. **Apple Event at stub exit** (§8.3): a mach message enqueued between the stub's final drain and `exit` cannot be
   delivered to any exiting process; the window is microseconds and covered by e2e race tests, but it cannot be
   proven absent without making the stub long-lived (rejected: it would keep a Dock-less process per app).
10. **Disk-image infrastructure process names** change between macOS versions; the probe does not depend on them
   (it only inspects files on the mounted volume), names are only used for diagnostics (§5.9).
11. **GPL-3.0 (Pake)**: our engine is not linked with Pake; distributing the Pake-built app means distributing a GPL
   program (source offer for the wrapper). Self-use: no issue.
12. **Restore-mode inspection boundary (R3-B2)**: without privilege we cannot see fds of other-uid processes; temporary
   restore relies on assumption A-R (§5.9 pass 3) and refuses apps with persistent root helpers. If a real app
   breaks A-R (an unrelated-team root daemon that loads code from the restored bundle), the user must mark it in
   `relatedExecutables` or keep the app installed. Mount mode does not depend on A-R (kernel unmount gate).
13. **TCC / default handlers / Dock pins** across the stub swap are compatibility observations collected by the
   manual checklist (§8.5, N5), not guarantees; actual iCloud API behavior is tested manually on supported releases
   after the fake-backend CI is green (G-c).

### 14.2 Open questions

Resolved for the current tree unless a config value is already set: project license MIT (`LICENSE`); ad-hoc signing (`signIdentity` `-`, override `ISENOUGH_SIGN_IDENTITY`); cache quota 20 GiB; free-space floor 15 GiB; detach delay 120 s. The management page is `isenough ui` (loopback, random token). `scripts/build-ui.sh` copies the web assets and runs Pake into `256isenough.app` when `pake` is installed; CI sets `ISENOUGH_SKIP_PAKE=1`.

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
