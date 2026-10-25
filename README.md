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

`init` creates repository directories and writes `<stateDir>/config.json`. Later commands load that file
unless `--config` or `ISENOUGH_CONFIG` is set. Explicit `ISENOUGH_*` path overrides win over the file.
`init --backend icloud` stores `backend: icloud`, and `status` reports that value. Without the flag,
`backend` stays `local` even when the default repository path is under iCloud Drive; opening the
repository still uses the iCloud folder backend when the path looks like iCloud. iCloud materialization
and upload-status handling are not implemented yet. `init`, `pack`, `launch`, and `install-engine` also
copy this `isenough` binary to `<stateDir>/bin/isenough` and write `isenough.stamp` (`version`, `revision`).

## Commands

- `isenough init [--backend local|icloud] [--root DIR] [--cache-dir DIR]`: initialize repo and paths. `--backend` is stored in `config.json` and shown by `status`.
- `isenough install-engine`: refresh `<stateDir>/bin/isenough` and `isenough.stamp` from the binary you just ran.
- `isenough pack APP.app [--mode mount|restore] [--no-stub] [--keep-original] [--stub-dir DIR]`: on macOS,
  create an ULMO image, hash it, publish manifest, and optionally replace the app with a signed stub.
  The stub's `isenoughPath` is the stable engine copy, not the build-tree path.
- `isenough stub refresh --app ID`: rewrite installed stubs so they exec that stable engine, and re-sign them on macOS. `stub rebuild` is still a placeholder.
- `isenough list [--json]`: list manifests.
- `isenough status [APP] [--json]`: local paths and state summary, including the stored `backend`.
- `isenough prefetch APP`: verify and cache image (the cached bytes stay the published ULMO image).
- `isenough launch APP [--doc PATH]... [--url URL]... [--no-wait]`: mount mode attaches read-only and opens the app.
  Restore mode runs the journaled transaction. The default waits until the journal closes. The post-quit
  watcher is a detached `isenough hook watch` in its own session, so it keeps running after the stub exits.
  `--no-wait` returns after that watcher is installed; it does not wait for quit.
- `isenough restore APP`: same launch path with restore mode forced.
- `isenough pin APP` / `unpin APP`: persist the pin state (pin also prefetches).
- `isenough evict APP`: remove cached image.
- `isenough gc`: adopt journals whose owner has exited and finish a clean restore-out. A live app is handed to one detached `hook watch`.
- `isenough unpack APP`, `detach APP`: not available in this build. `resolve APP` keeps, exports, or discards a bundle that changed while it was restored.
- `isenough hooks list|enable|disable APP`: placeholder. Hook files under `stateDir/hooks/<bundleId>/` still run.
- `isenough doctor [--fix]`: each check has a timeout and prints `ok`, `warn`, `fail`, or `timed out` as soon as it finishes. A slow or stuck iCloud repository cannot block the command. `ISENOUGH_DOCTOR_TIMEOUT` is the per-check wait in seconds (default 15). The process exits 1 when any check fails or times out. A missing or older engine is `engine` / `warn` and does not by itself fail the command. `--json` prints one object after the checks finish. `--fix` runs recovery inside the same kind of bound.
- `isenough backend add smb|nfs|webdav ...` / `backend list` / `backend use ID`: register a share or WebDAV repository. Passwords come from `--password-stdin` and are stored in the Keychain, not in `config.json`. See `docs/backends.md`.
- `isenough ui` serves the management page on `127.0.0.1` with a random token. `scripts/build-ui.sh` copies the page and, when Pake is installed, builds `256isenough.app`.
- `isenough serve`, `daemon install|uninstall|status`: placeholders.
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

`bash scripts/e2e.sh` on a Mac builds a fixture app and uses only isolated temporary repository, cache, state,
mount, and Applications directories. The restore cases launch the generated stub and require the journal to
reach `restoredOut` after the fixture quits. That harness is not a substitute for trying this on an app you
can reinstall.

## Limitations

No reliable iCloud materialization, capacity claims/locking in the engine, cache LRU eviction, a secure
stub control protocol, or process-wide dependent detection. Restore mode has a journal and a detached
post-quit watcher; it is still young.
ULMO creation and hdiutil attach have not been run on this Linux host. Mount and restore modes must be validated on
macOS. Never attach a dataless iCloud DMG: implement FileManager startDownloadingUbiquitousItem and wait for a fully
materialized/current file before hashing/attach. No session tiering is included (future design only).
