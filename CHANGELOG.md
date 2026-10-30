# Changelog

All notable changes to 256isenough (`isenough`) are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased

First public release.

### Added

- `isenough pack` moves an app into a DMG image in your repo (a local folder,
  iCloud Drive, SMB/NFS share, WebDAV, or OpenList) and leaves a signed stub in its place.
  Opening the stub downloads, verifies, mounts, and starts the app.
- Two launch modes: `mount` runs the app from a read-only image; `restore` copies
  it back for the session under a journal and returns it to the repo after quit.
- `isenough unpack` puts the real app back after checking its tree hash and cdhash.
  `unpack --to DIR` copies it out and keeps the stub.
- `isenough recommend` ranks installed apps worth offloading by size and time idle.
- Several Macs can share one repo. Images are write-once and shared, and each Mac
  owns one device file. `gc` keeps every image that any device names.
- Cache quota with LRU eviction, `pin`/`unpin`, `prefetch`, `evict`, and
  `evict-local` for iCloud copies that finished uploading.
- `isenough doctor [--fix]` with a time limit per check, and journal replay.
- `isenough sessions` archives cold coding-agent transcripts into write-once zstd
  segments, with optional AES-GCM encryption and a SQLite search index.
- 256isenough.app: a native menu-bar app (AppKit and WebKit) that serves the
  dashboard on 127.0.0.1 and shows it in a window. It replaces the Pake wrapper.
- `isenough ui --open` opens the dashboard in the browser; `ui --json` prints
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

### In this release (landing now)

Planned for 0.1 and not in every build yet (`isenough detach` currently reports
"not available in this build"). Fold these into Added or remove them before
tagging; see `docs/release-checklist.md`.

- `isenough evict APP --force` and `isenough detach APP`.
- Reaping of images left mounted after their app quit.
- Stubs scoped to the repo that packed them.

### Changed

- `isenough gc` now replays journals, applies repo garbage rules, and enforces
  the cache quota in one pass. `gc --dry-run` still changes nothing.
- `isenough` with no command prints a short hint and exits 64 (EX_USAGE) instead
  of the full help. `help` groups commands by task and lists `resolve`.
- On macOS, SQLite links against the system library, so release binaries do not
  depend on Homebrew.
- Errors no longer print Foundation `userInfo`. Set `ISENOUGH_DEBUG=1` to see it.

### Removed

- `scripts/build-ui.sh` and `scripts/build-gui.sh` (Pake, GPL-3.0).
- `serve`, `daemon`, `stub rebuild`, and `hooks` are no longer listed in help.
  `serve`, `daemon`, and `stub rebuild` now exit 3 (unsupported) instead of
  printing `ok: false` with status 0.

### Fixed

- `isenough ui` from a copied or installed binary no longer traps in
  `Bundle.module`. The page is found through `ISENOUGH_WEB_ROOT`,
  `<exe>/../Resources/web`, `<exe>/../share/isenough/web`, then the SwiftPM
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
| `state/2` | `~/Library/Application Support/256isenough/state.json` | reads and writes; migrates `state/1` on first load |
| `image/1` | `manifests/<imageId>.json` in the repo        | reads and writes |

After upgrading, run `isenough install-engine`, then `isenough stub refresh --app ID`
for each packed app so existing stubs exec the new engine.

[Unreleased]: https://github.com/s546126/256isenough/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/s546126/256isenough/releases/tag/v0.1.0
