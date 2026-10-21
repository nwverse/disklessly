# 256isenough

**中文简介：** 将不常用的 macOS 应用打包到远端，只在启动时下载到本机运行；目标是节省本地磁盘空间。

256isenough (`isenough`) is an experimental macOS diskless-app manager. The design is specified in
[`docs/design.md`](docs/design.md); this repository currently contains an early MVP scaffold, not all of
that production design. Remote DMGs are intended to be ULMO; local macOS cache conversion targets ULFO.
LocalFolder is the portable backend and can simulate an iCloud repository. macOS-only disk image and
Launch Services operations are guarded from Linux builds.

## Build and test

```sh
swift build
swift test
# Optional Linux container:
docker run --rm -v "$PWD":/src -w /src swift:6.1 swift test
```

On macOS install Xcode Command Line Tools and build with Swift 5.9+ / Swift 6. The `isenough-stub`
product is copied into a generated stub and ad-hoc signed; a Developer ID signing flow is not yet provided.
GUI recipe: `scripts/build-gui.sh` (Pake; see `gui/README.md`). Pake is GPL-3.0 and generated app distribution
needs a licensing decision. This repository's own code is MIT (`LICENSE`).

## Configuration

The CLI accepts `--config PATH`, `--state-dir PATH`, `--json`. Environment overrides are useful for isolated
fixtures and e2e runs:

- `ISENOUGH_REPO_PATH` (default iCloud Drive repo path)
- `ISENOUGH_CACHE_DIR`, `ISENOUGH_STATE_DIR`, `ISENOUGH_MOUNT_ROOT`, `ISENOUGH_STUB_DIR`
- `ISENOUGH_DETACH_DELAY` (seconds)

`init` creates repository directories and a local config. Explicit flags `init --root DIR --cache-dir DIR`
are available. Local backend is the usable MVP backend. iCloud's FileManager materialization/upload status
adapter is not implemented yet.

## Commands

- `isenough init [--backend local|icloud] [--root DIR] [--cache-dir DIR]`: initialize repo and paths.
- `isenough pack APP.app [--mode mount|restore] [--no-stub] [--keep-original] [--stub-dir DIR]`: on macOS,
  create an ULMO image, hash it, publish manifest, and optionally replace the app with a signed stub.
- `isenough list [--json]`: list manifests.
- `isenough status [APP] [--json]`: local paths and state summary.
- `isenough prefetch APP`: verify and cache image (ULFO conversion on macOS).
- `isenough launch APP [--doc PATH]... [--url URL]... [--no-wait]`: mount read-only, open app with supplied args,
  optionally wait and detach after configured delay. `--no-wait` returns after open; it does not yet install a
  background post-quit watcher.
- `isenough pin APP` / `unpin APP`: persist the pin state (pin also prefetches).
- `isenough evict APP`: remove cached image.
- `isenough gc`: currently a safe no-op placeholder.
- `isenough restore APP`, `unpack APP`, `detach APP`, `resolve APP`: recognized surface, not implemented.
- `isenough stub rebuild APP`: placeholder.
- `isenough hooks list|enable|disable APP`: placeholder.
- `isenough doctor`: basic path/platform check.
- `isenough backend add smb|nfs|webdav ...` / `backend list` / `backend use ID`: register a share or WebDAV repository. Passwords come from `--password-stdin` and are stored in the Keychain, not in `config.json`. See `docs/backends.md`.
- `isenough serve [--port PORT]`, `daemon install|uninstall|status`: placeholders; HTTP daemon is not shipped.
- `isenough trust APP`: not implemented.
- `isenough version`: version/schema.

Errors use stable numeric codes where implemented; `--json` emits `{ "ok": false, "error": {"code", "message"} }`.

## Hooks and lifecycle

The target lifecycle is pre-launch materialize → verify SHA-256 → attach read-only → forward documents/URLs →
watch app and dependents → post-quit hook → delayed detach → update LRU. In this implementation, pre/post hook
execution, robust NSWorkspace Apple Event handling, leases, safe process probing, restore-mode transaction journal,
crash recovery and full LRU accounting remain gaps. Do not use it to remove a production app until those safeguards
are implemented and macOS acceptance-tested. The current `pack` default does not move the original unless stub
creation succeeds; use `--keep-original` to retain it.

## Non-interactive cycle (current scope)

For a test Mac fixture, use isolated roots; `pack --no-stub` leaves the source intact, then:

```sh
export ISENOUGH_REPO_PATH="$PWD/.e2e/repo"
export ISENOUGH_CACHE_DIR="$PWD/.e2e/cache"
export ISENOUGH_STATE_DIR="$PWD/.e2e/state"
export ISENOUGH_MOUNT_ROOT="$PWD/.e2e/mnt"
export ISENOUGH_STUB_DIR="$PWD/.e2e/stubs"
export ISENOUGH_DETACH_DELAY=0
.build/debug/isenough init --backend local
.build/debug/isenough pack /path/to/Fixture.app --no-stub
.build/debug/isenough list --json
.build/debug/isenough launch com.example.Fixture --no-wait
```

This does **not** yet provide a safe end-to-end stub->quit->detach automation cycle: non-interactive long-lived
watching and fixture hold controls are deferred. The macOS harness is intended to expose these gaps rather than
make production use safe. Run it on any Mac with `bash scripts/e2e.sh`; it builds a fixture app and uses only
isolated temporary repository/cache/state/mount/Applications directories.

## Limitations

No reliable iCloud backend, capacity claims/locking in engine, cache LRU persistence, user hook lifecycle, secure
stub control protocol, fully functional GUI server, restore-mode safeguards or process-wide dependent detection.
ULMO creation and hdiutil attach have not been run on this Linux host. Mount and restore modes must be validated on
macOS. Never attach a dataless iCloud DMG: implement FileManager startDownloadingUbiquitousItem and wait for a fully
materialized/current file before hashing/attach. No session tiering is included (future design only).
