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
