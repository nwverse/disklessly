# Changelog

All notable changes to Disklessly (`disklessly`) are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Login items and menu bar agents are no longer held back from offloading: they are recommended with a note, and a login item gets a "Login items" button that opens System Settings → Login Items (`POST /api/loginitems/open`).
- Apps listed under "Poor candidates" get an offload button too, except the toolchain, apps with system or kernel extensions, and apps already packed. An app whose background helper is running gets "Stop and offload": the pack job (`POST /api/pack` with `"stopFirst": true`) quits the processes inside the bundle (SIGTERM, then SIGKILL after 8 s) and packs, retrying once if launchd starts a helper again.
- Dashboard order follows the flow: disk usage first, then what to offload, offloaded apps, container images, Macs sharing the repo (now an open card instead of a fold at the bottom), simulators, sessions, cloud drives, and repo and cache last. The license card is hidden for now.

## [0.2.0] - 2026-11-07

### Added

- Session tiering lists each cold session (title, project folder, size, age) under its agent and can move only the ones you tick (`POST /api/sessions/apply` takes `paths`).

- `disklessly repo merge --from ID|default` and `POST /api/cloud/merge`: merge another repo into the active one. Migrating onto a backend that already is another repo now merges into it, keeping its `repoId` and rebuilding its catalog, instead of being refused.

- Container images: `disklessly containers [list|offload|restore|clean|forget]`, `GET /api/containers`,
  `POST /api/containers/scan`, jobs `containers/offload|clean|restore|forget`, and a "Container images" group under
  Other big items. Lists the images and volumes of Apple container, Docker Desktop, OrbStack, Colima and Dory
  (through each engine's own socket), says whether a running or stopped container uses each image or it was
  pulled or run in the last 30 days, and falls back to the disk size when an engine is stopped or has no CLI.
  Offload saves the image to `containers/images/<id>.tar` write-once, checks the repo copy's sha256, and only then
  removes it; restore downloads, checks and `load`s it. Images a container uses are refused; volumes are only listed.
- Archived agent sessions show a title (the agent's own title, or the first prompt) and can be filtered by title, agent or path before restoring.

- Moving to another repo takes the offloaded apps along: `disklessly repo migrate --to ID|default
  [--keep-old-as-mirror]` (and `POST /api/cloud/use` with `"migrate": true`, run as a cloud task) copies every
  object, including `repo.json` so the `repoId` and existing stubs stay valid, verifies the copy, and only then
  switches. A failed or interrupted move leaves the config on the old repo; running it again resumes.
- Repo mirrors: `mirrorBackendIds` in the config, `disklessly repo mirror add|remove|list|sync`, and
  `POST /api/cloud/mirrors` / `/api/cloud/mirrors/sync`. Reads fail over to a mirror when the active repo is down
  or lacks an object; writes go to the active repo only. The last sync of each mirror is kept in
  `<stateDir>/mirrors.json` and listed in `GET /api/cloud` as `mirrors`.
- Session tiering finds more agents: Codex `archived_sessions`, Oh My Pi, Gemini CLI and Qwen chats (`.json`),
  Factory, Kimi, Copilot CLI, Goose (JSONL era), Grok, Mistral Vibe, Kiro, OpenClaw, Prime, and Cursor agent
  transcripts, plus Claude Code's XDG folder on Linux. Roots take extra `suffixes` and a `requireComponent`
  folder; credential, token, settings, state, and SQLite names are never tiered. Claude desktop's session
  folders hold rewritten state JSON, not transcripts, and are left alone.
- `DisklesslyEngine.sessionPlan(days:)`: a read-only per-agent dry run (files, bytes, cold files and bytes,
  open, too large, oldest and newest), and `sessionApply(tools:)` to archive only the agents a user picked.
- Archived sessions get a deterministic short digest (user prompts and final answers, at most 8 KiB) in the
  index and in `stateDir/sessions/digests/<id>.md`; `sessions search` matches it. The archived transcript
  is unchanged. The session index moves to schema 3 and migrates version 2 in place.

- Linux build of the CLI (`scripts/release-linux.sh` makes `disklessly-<ver>-linux-<arch>.tar.gz`). It runs
  `sessions` (with `--encrypt`), `ui` (sessions, disk usage, devices, license), `backend`, `devices`, `license`,
  `init`, `list`, `status`, and `version`; app commands exit 3 with "… is macOS only". XDG folders, secrets in the
  Secret Service via `secret-tool` or a 0600 `~/.config/disklessly/secrets.json`, open sessions detected through
  `/proc` when lsof is missing, and a usage map of `/opt`, Flatpak, and Snap apps. See `docs/linux.md`, which also
  sketches offloading AppImage files.
- Cloud drives through a bundled rclone (v1.75.2, `Contents/MacOS/rclone`). `disklessly cloud connect
  gdrive|dropbox|onedrive|box|pcloud` signs in in the browser and stores an `rclone` backend without switching
  the repo; `cloud list`, `cloud disconnect NAME`, `backend add rclone --remote NAME`, `backend use default`, and
  `disklessly rclone ARGS...` (the bundled rclone with Disklessly's own config under the state dir). Whole-file
  downloads use several streams at once. Google Drive asks only for files Disklessly creates (`drive.file`) and
  signs in through Disklessly's own Google OAuth client (`Contents/Resources/google-oauth.json`, or
  `DISKLESSLY_GDRIVE_CLIENT_ID`/`_SECRET`) instead of rclone's shared, rate-limited one.
  Each Disklessly process keeps one `rclone rcd` on 127.0.0.1 (random credentials, stopped when the process
  exits, even by a crash), so repo calls skip rclone's start-up and root lookup; `DISKLESSLY_RCLONE_DAEMON=0`
  uses the rclone CLI instead.
- One-click OpenList: `disklessly openlist install|status|password|start|stop|uninstall` downloads the pinned
  release, checks its SHA-256, and runs it on 127.0.0.1 as a LaunchAgent with an admin password kept in the
  Keychain. OpenList is downloaded on request and never bundled.
- Cloud drives card in the dashboard: connect a drive, install and open OpenList, and switch the repo (with a
  warning about apps offloaded to the current repo) or switch back to iCloud Drive.
- Offload any large file or folder, not only apps. `disklessly offload PATH` moves it into the repo:
  - a file is stored as is, a folder as tar + zstd;
  - the object is write-once at `files/objects/<sha256>`;
  - the original is deleted only after the repo copy reads back with the same SHA-256;
  - a `PATH.disklessly` placeholder with the Finder tag "Disklessly" is left in its place.

  `disklessly fetch PLACEHOLDER` brings it back. Open files, app bundles and their contents, `~/Library`, VM disks
  and Disklessly's own folders are refused. See `docs/files.md`.
- `disklessly files` and a "Large files and folders" list under Worth offloading in the dashboard. They show files and
  whole folders of 500 MiB or more not opened for 30 days, using the newest of Spotlight's last-used date, mtime and atime. The scan
  skips hidden and tool folders, source checkouts, package stores, iCloud items and running VM images. Each row has an
  Offload now button (`POST /api/offloadfile`, `GET /api/files`, `POST /api/files/scan`).
- Finder right-click: Services → "Offload with Disklessly" and "Bring back with Disklessly". `.disklessly`
  placeholders are a document type of Disklessly.app, so double-clicking one brings the file back.
- `DISKLESSLY_HOME` overrides the home folder that `files` and `offload` use (for tests).

- Optional encryption of app images in the repo. `disklessly images key init` makes a 256-bit image key in the
  Keychain (synchronizable, so iCloud Keychain gives it to your other Macs; `images key export|import` copies it by
  hand). `disklessly images encrypt on` (config `imageEncryption`, env `DISKLESSLY_IMAGE_ENCRYPTION`) or
  `pack --encrypt` seals new images before upload: AES-256-GCM over 1 MiB segments (`DKLI`, ported from open-lark's
  olk-file), streamed file to file. The manifest's `sha256`/`size` describe the ciphertext and a new
  `image.encryption` carries the scheme, key id and plain sha256. Fetching verifies the ciphertext, decrypts it into
  the cache and checks the plain hash; the cache and mounts are unchanged. Plain images keep working. A Mac without
  the key refuses to adopt an encrypted image and keeps the original app. Older Disklessly versions cannot attach
  encrypted images. See `docs/image-encryption.md`.
- Permission onboarding in the menu-bar app. At launch it checks App Management (required to swap apps in
  /Applications) and Full Disk Access (recommended), opens the matching System Settings pane, and floats a small
  panel with the app icon to drag into the list there. Also under Permissions… in the menu.
- `disklessly caches [--apply]` and a "Clear app caches" button in the Disk usage card: empties
  `~/Library/Caches/<bundleId>`, `~/Library/Caches/<app name>` and a sandbox container's `Data/Library/Caches` for
  offloaded apps. Dry run by default. An app that runs, has an open restore journal or is mid-detach is skipped;
  links are not followed and Application Support and other app data are never touched (`GET /api/caches`,
  `POST /api/caches/clear`). docs/app-data-offload.md designs moving app data itself into per-device data images.
- The dashboard lists apps offloaded on another Mac in their own group and says what this Mac has (not installed, or the full app). The repo is shared by every Mac, so these used to look like apps that vanished from this Mac. Open, restore and unpack are hidden when the full app is installed here.
- Disk usage card in the dashboard: a flame chart of what fills the disk. Boxes zoom in; each app splits into
  bundle, cache and data, Disklessly's own cache and repo get their own box, and the rest is System & other.
  The scan only reads sizes (`du`), runs in the background on request (`POST /api/usage/scan`), and a timeout
  keeps what finished.
- Offload now button on the recommendations: the dashboard packs the app itself, with a confirm dialog and progress.
- Free version limit and license codes. The free version offloads up to 2 apps at once; `disklessly license
  [status|activate CODE|deactivate]` and a License card in the dashboard manage an Ed25519-signed code that is
  verified offline. Only `pack` checks the limit (exit code 15, `license_required` in the dashboard API).
  Buyout and time-limited promo codes. `disklessly-license` is a maintainer tool that makes the key pair and
  issues codes; it is not part of any release artifact.

### Changed

- Google Drive uploads use 64 MiB chunks instead of rclone's 8 MiB default (about 60% faster per image in testing).

- The free limit counts offloaded files and folders together with apps (2 items at once).

- The project is now **Disklessly** ("256G is enough"). CLI `disklessly` (short alias `dkl`), stub launcher
  `disklessly-stub`, env vars `DISKLESSLY_*`, bundle id prefix `io.github.s546126.disklessly`, Homebrew cask
  `disklessly` and formula `disklessly-cli`. The menu-bar executable is `DisklesslyApp` so it cannot collide with
  the `disklessly` CLI on case-insensitive volumes.
- Installs made under the old `isenough` / `256isenough` names keep working: existing `256isenough` data folders are
  used in place, old `.isenough-original-` backups are still recognized by `cleanup-backups`, and Keychain items
  saved under the old service name are still read.

## [0.1.0] - 2026-10-31

First public release.

### Added

- `disklessly pack` moves an app into a DMG image in your repo (a local folder,
  iCloud Drive, SMB/NFS share, WebDAV, or OpenList) and leaves a signed stub in its place.
  Opening the stub downloads, verifies, mounts, and starts the app.
- Two launch modes: `mount` runs the app from a read-only image; `restore` copies
  it back for the session under a journal and returns it to the repo after quit.
- `disklessly unpack` puts the real app back after checking its tree hash and cdhash.
  `unpack --to DIR` copies it out and keeps the stub.
- `disklessly recommend` ranks installed apps worth offloading by size and time idle.
- Several Macs can share one repo. Images are write-once and shared, and each Mac
  owns one device file. `gc` keeps every image that any device names.
- Cache quota with LRU eviction, `pin`/`unpin`, `prefetch`, `evict`, and
  `evict-local` for iCloud copies that finished uploading.
- `disklessly doctor [--fix]` with a time limit per check, and journal replay.
- `disklessly sessions` archives cold coding-agent transcripts into write-once zstd
  segments, with optional AES-GCM encryption and a SQLite search index.
- Disklessly.app: a native menu-bar app (AppKit and WebKit) that serves the
  dashboard on 127.0.0.1 and shows it in a window. It replaces the Pake wrapper.
- `disklessly ui --open` opens the dashboard in the browser; `ui --json` prints
  `{url, port, token}`.
- Readable output for `init`, `pack`, `launch`, `prefetch`, `pin`, `evict`,
  `status`, and `unpack`. `--json` keeps the machine format.
- "Did you mean" suggestions for an unknown app name.
- `version --json` reports the commit, build date, and architecture.
- Release pipeline: `scripts/build-app.sh` (universal app), `scripts/release-sign.sh`
  (Developer ID signing, notarization, stapling, tarball, DMG, SHA256SUMS), a
  tag-driven GitHub workflow, and Homebrew formula and cask templates.
- `PRIVACY.md` (no telemetry) and `THIRD_PARTY_NOTICES.md`.
- An app icon: the blue rounded "256" tile from the dashboard, drawn by
  `scripts/make-icon.sh` (CoreGraphics through `swift`, `sips`, `iconutil`) into
  `Resources/AppIcon.icns`. `scripts/build-app.sh` copies it into the bundle and
  sets `CFBundleIconFile`.
- `docs/user-guide.md`, an end-user guide in Chinese with an English section.

### Release branch highlights (`release/v0.1` compared with `main`)

- **Crash-safe pack and unpack.** `pack` swaps the stub in with an atomic
  `renamex_np(RENAME_SWAP)` under a journal and re-checks the source under the
  app lock (not a stub, not running, unchanged since it was cloned); any refusal
  leaves the original alone. `unpack` holds the app lock from preflight to
  install. `gc` and `doctor --fix` finish interrupted pack journals.
- **Exclusive repo publishing.** Images and manifests are published write-once
  (`RENAME_EXCL`, with fallbacks); a lost race is detected and the canonical copy
  is confirmed by re-reading it. Device records are keyed by image id, so two
  Macs or two install paths of the same app no longer overwrite each other.
- **Dashboard jobs.** The loopback server handles connections concurrently, and
  open, prefetch, pin, unpin, evict, restore, and unpack run as background jobs
  with per-row progress, confirmations for destructive actions, an onboarding
  view for an empty repo, search, sort and filter, and Chinese and English text.
  An expired dashboard link shows a readable page.
- **Mount-mode `launch --no-wait`** hands the post-quit detach to the detached
  watcher, so the image is detached after the app quits.
- `scripts/e2e.sh` runs end to end on macOS against fixture apps in temp folders.

- **Pinned evict:** `disklessly evict APP` refuses a pinned app unless `--force`;
  mounted, in-use, or mid-restore images are refused even with `--force`. The
  dashboard disables Evict while an app is pinned.
- **`disklessly detach APP [--force]`** detaches a mounted image now, refusing while
  the app runs.
- **Orphan mount reaper:** `disklessly reap [--dry-run]`, also run by `launch`
  (after the app opens), `gc`, and `doctor --fix`.
- **Repo-scoped stubs:** `stub.json` carries `repoId`; device claims count only
  this repo's stubs. `disklessly stub refresh --all [--adopt]` migrates old stubs.

### Changed

- `disklessly gc` now replays journals, applies repo garbage rules, and enforces
  the cache quota in one pass. `gc --dry-run` still changes nothing.
- `disklessly` with no command prints a short hint and exits 64 (EX_USAGE) instead
  of the full help. `help` groups commands by task and lists `resolve`.
- On macOS, SQLite links against the system library, so release binaries do not
  depend on Homebrew.
- Errors no longer print Foundation `userInfo`. Set `DISKLESSLY_DEBUG=1` to see it.

### Removed

- `scripts/build-ui.sh` and `scripts/build-gui.sh` (Pake, GPL-3.0).
- `serve`, `daemon`, `stub rebuild`, and `hooks` are no longer listed in help.
  `serve`, `daemon`, and `stub rebuild` now exit 3 (unsupported) instead of
  printing `ok: false` with status 0.

### Fixed

- `disklessly ui` from a copied or installed binary no longer traps in
  `Bundle.module`. The page is found through `DISKLESSLY_WEB_ROOT`,
  `<exe>/../Resources/web`, `<exe>/../share/disklessly/web`, then the SwiftPM
  resource bundle, and a clear error is printed when none exists.
- An empty mount folder left by `diskutil` detach no longer counts as mounted,
  so a launched image can be evicted or unpacked afterwards.
- `evict` refuses an image that is mounted or in use (exit 9) instead of
  deleting the DMG under a running app; the dashboard disables Evict meanwhile.
- `unpack`, `evict`, and `pin` accept a stub's path as the app.
- `status` no longer reports evicted images as cached.
- A killed but unreaped (zombie) journal owner is treated as dead, so a restore
  launch no longer waits on it forever; `launch` no longer prints `pgrep` output.
- The first `pack` or `prefetch` on a fresh state folder creates the cache folder
  before checking free space.
- Tree hashes and backend uploads stream SHA-256 instead of reading whole files.
- The dashboard's "also on" list leaves out this Mac.

## Schema compatibility

Formats on disk and in the repo carry a schema tag. A release can read every
schema listed for it. A newer schema is never written by an older release.

| Schema    | Where                                         | 0.1.0 |
|-----------|-----------------------------------------------|-------|
| `stub/1`  | `Contents/Resources/stub.json` in each stub   | reads and writes |
| `state/2` | `~/Library/Application Support/Disklessly/state.json` | reads and writes; migrates `state/1` on first load |
| `image/1` | `manifests/<imageId>.json` in the repo        | reads and writes |

After upgrading, run `disklessly install-engine`, then `disklessly stub refresh --app ID`
for each packed app so existing stubs exec the new engine.

[Unreleased]: https://github.com/s546126/disklessly/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/s546126/disklessly/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/s546126/disklessly/releases/tag/v0.1.0
