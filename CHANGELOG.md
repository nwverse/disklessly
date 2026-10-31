# Changelog

All notable changes to Disklessly (`disklessly`) are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Free version limit and license codes. The free version offloads up to 2 apps at once; `disklessly license
  [status|activate CODE|deactivate]` and a License card in the dashboard manage an Ed25519-signed code that is
  verified offline. Only `pack` checks the limit (exit code 15, `license_required` in the dashboard API).
  Buyout and time-limited promo codes. `disklessly-license` is a maintainer tool that makes the key pair and
  issues codes; it is not part of any release artifact.

### Changed

- The project is now **Disklessly** ("256G is enough"). CLI `disklessly` (short alias `dkl`), stub launcher
  `disklessly-stub`, env vars `DISKLESSLY_*`, bundle id prefix `io.github.s546126.disklessly`, Homebrew cask
  `disklessly` and formula `disklessly-cli`. The menu-bar executable is `DisklesslyApp` so it cannot collide with
  the `disklessly` CLI on case-insensitive volumes.
- Installs made under the old `isenough` / `256isenough` names keep working: existing `256isenough` data folders are
  used in place, old `.isenough-original-` backups are still recognized by `cleanup-backups`, and Keychain items
  saved under the old service name are still read.

## [0.1.0] - Unreleased

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

[Unreleased]: https://github.com/s546126/disklessly/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/s546126/disklessly/releases/tag/v0.1.0
