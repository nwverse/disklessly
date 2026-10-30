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

On Linux install `libsqlite3-dev` and `g++` before `swift test`. Session tiering links the system SQLite library, and swift-crypto compiles a C++ file that needs the standard library. On macOS install Xcode Command Line Tools and build with Swift 5.9+ / Swift 6. The `isenough-stub`
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
- `isenough pack APP.app [--mode mount|restore] [--image-format ULMO|ULFO] [--no-stub] [--keep-original] [--stub-dir DIR]`: on macOS,
  create a disk image, hash it, publish the manifest, and optionally replace the app with a signed stub.
  Mount mode publishes ULMO. Restore mode uses `--image-format` when it is set, otherwise `restoreImageFormat` (default ULMO, env `ISENOUGH_RESTORE_IMAGE_FORMAT`).
  The format is not part of the image id. `UDZO` is rejected. The stub's `isenoughPath` is the stable engine copy, not the build-tree path.
  When the shared image is missing or its cloud copy is not confirmed, pack refuses (exit 5) or keeps the original and prints `originalKept`. It does not replace an app with a stub until a verified image exists.
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
- `isenough evict APP`: remove the cached image. This does not touch the copy in iCloud Drive.
- `isenough evict-local`: drop the local bytes of repo images that iCloud has fully uploaded, leaving the cloud copy in place. A file that is still uploading, mounted, or needed before the detach delay is left alone. "Cannot evict yet" is reported and is not an error. When iCloud does not report whether the upload finished, the line says `upload status is unavailable` instead of treating that as an unfinished upload, and it includes the upload percent when iCloud provides one. `pack` and `gc` run the same pass.
- `isenough gc [--include-legacy]`: adopt journals whose owner has exited and finish a clean restore-out. A live app is handed to one detached `hook watch`. The same pass evicts uploaded iCloud copies that this Mac does not need. Images packed before device files existed are kept, and named, unless `--include-legacy` is passed.
- `isenough cleanup-backups`: remove leftover `/Applications/.isenough-original-*.app` backups after checking each one against its stub and the repo image. Every verified path is deleted by one macOS administrator prompt (`osascript` … `with administrator privileges`). The command never asks for or stores a password. `.256orig.app` copies kept with `--keep-original` are not removed.
- `isenough unpack APP [--to DIR]`: put the real app back in place of the stub. The extracted tree hash and cdhash must match the manifest. `--to DIR` copies the verified app to `DIR/<Name>.app` and leaves the stub installed. `--delete-remote` is rejected. `detach APP` is not available in this build. `resolve APP` keeps, exports, or discards a bundle that changed while it was restored.
- `isenough sessions [--apply] [--days N] [--home DIR] [--encrypt]`: dry-run by default. `--apply` packs cold JSONL into write-once zstd segments under `sessions/<deviceId>/<tool>/` and removes a local file only after the index commit. `--encrypt` seals that run with AES-256-GCM.
- `isenough sessions search QUERY [--limit N]`, `sessions restore ID|PATH [--to PATH]`, `sessions reindex`, `sessions migrate`, `sessions verify --legacy`.
- `isenough sessions key init` creates the current segment key. `sessions key status` prints only the key id. A second `key init` is rejected. Encrypting without a key is rejected and names `sessions key init`.
- `isenough hooks list|enable|disable APP`: placeholder. Hook files under `stateDir/hooks/<bundleId>/` still run.
- `isenough doctor [--fix]`: each check has a timeout and prints `ok`, `warn`, `fail`, or `timed out` as soon as it finishes. A slow or stuck iCloud repository cannot block the command. `ISENOUGH_DOCTOR_TIMEOUT` is the per-check wait in seconds (default 15). The process exits 1 when any check fails or times out. A missing or older engine is `engine` / `warn` and does not by itself fail the command. The `materialized` check reports how much of an iCloud repo is still stored on this Mac (`iCloud keeps full copies: repo occupies X locally of Y`). `--json` prints one object after the checks finish. `--fix` runs recovery inside the same kind of bound.
- `isenough devices` / `devices list`: show every Mac registered in the shared repo, which images it packed, and which file is this Mac. This Mac is registered before the list is printed, and its file is filled from local stubs on that first run. Conflict copies and not-yet-downloaded device files are listed and not merged.
- `isenough devices rename NAME`: set this Mac's display name. A Mac does not rename another Mac's device file.
- `isenough devices forget DEVICEID --yes`: delete that device file. `--yes` is required. A placeholder that has not downloaded is left in place.
- `isenough recommend [--min-size SIZE] [--limit N] [--min-idle-days N]`: rank installed apps in `/Applications` and `~/Applications` that are worth offloading. Only top-level `.app` bundles are considered. Stubs, the 256isenough app, macOS system apps, Apple-signed apps under `/System`, and apps that are running are skipped. Size is allocated blocks (the same basis as `du`) with a time limit. Last use is the Spotlight attribute `kMDItemLastUsedDate` read through `NSMetadataItem`; a null date means never used. Localized tool output is not parsed. A Mac App Store receipt selects restore mode. Score is size in MiB times days idle, with a never-used bonus. The default minimum size is 100 MiB. `--json` prints `recommendations`, `warnings`, and `estimatedFreedBytes`. Poor candidates (login items, menu bar agents, running helpers, system or kernel extensions, and the toolchain, including Xcode) are warnings, as are pinned and already-packed apps. Login items are a non-empty bundled LoginItems or launchd directory, or a LaunchAgent or LaunchDaemon plist whose program is inside the app. Dot-prefixed entries, `.isenough-original-` backups, `.256orig.app` bundles, and `.256isenough-staging` directories are omitted from both lists. When those leftovers exist, the output adds one line, `N leftover backups (X) can be removed`, plus their paths. The command does not delete them. When the same bundle id, version, and architecture are already in the repo, the reason includes `already in repo, packing is instant, no upload` and the other Macs that have the image.
- `isenough backend add smb|nfs|webdav ...` / `backend list` / `backend use ID`: register a share or WebDAV repository. Passwords come from `--password-stdin` and are stored in the Keychain, not in `config.json`. See `docs/backends.md`.
- `isenough ui` serves the management page on `127.0.0.1` with a random token. The page includes the recommend list from `GET /api/recommend`. `scripts/build-ui.sh` copies the page and, when Pake is installed, builds `256isenough.app`.
- `isenough serve`, `daemon install|uninstall|status`: placeholders.
- `isenough trust APP`: not implemented.
- `isenough version`: version/schema. `isenough help`, `--help`, and `-h` print usage. Without `--json`, `devices`, `list`, `version`, `evict-local`, and `gc` print one line per item, with sizes in GiB or MiB.

Errors use stable numeric codes where implemented; `--json` emits `{ "ok": false, "error": {"code", "message"} }`.

## Two Macs, one repo

The iCloud Drive folder (`…/CloudDocs/256isenough`, or any LocalFolder used the same way) is the shared repo.
`catalog/` and `devices/` are part of that layout. Two Macs of the same user can point at it.

Shared, and safe for more than one Mac to see:

- `images/` and `manifests/` are write-once. The image id is the bundle id, version, build, architecture slices, and the content tree hash (the same `BundleHasher` digest as before). The same app and version on both Macs is one image. `pack` on the second Mac verifies the stored image and does not upload again.
- `devices/<deviceId>.json` is the only file a Mac writes for itself. `deviceId` is a UUID kept in that Mac's state directory, not the hostname.
- `catalog/manifest.json` is a derived index. Manifests remain the source of truth.
- `trash/` holds images `gc` has decided are unreferenced. They stay there for 7 days.

Machine-local, and not shared through the repo:

- The device id, pins, launch state, and saved Mac App Store receipts live under the state directory (`~/Library/Application Support/256isenough/` by default).
- The image cache and mount directory stay on that Mac.
- A receipt inside an app (`Contents/_MASReceipt`) is not copied into the shared image. Restore puts back the receipt this Mac saved, and says so when it has none.

`gc` will not delete an image that any device file still names. The first command that touches the repo registers this Mac and copies image ids out of local stubs (and out of journals whose app is a stub here) into this Mac's device file. Images that nobody owns at that moment are recorded in `catalog/legacy.json` and are not deleted unless `gc --include-legacy` is passed. A Mac that has not checked in for 90 days is reported and still protects its images. A device file iCloud has not downloaded, including a `.icloud` placeholder, also protects every image. `doctor` reports conflict copies such as `devices/<id> 2.json` and does not merge them. A stub opens only the image id this Mac recorded. If the requested image is another version or architecture, launch stops with a diagnostic instead of starting that image.

After `pack`, iCloud Drive still has a full local copy of each uploaded image until that copy is evicted. `pack` and `gc` call `FileManager.evictUbiquitousItem` (not `brctl`, which macOS 14 removed) for images whose upload has finished and that this Mac is not using. A file that is still uploading is never evicted. If the system cannot evict it yet, the command says so and exits successfully. `isenough evict-local` runs that pass on its own.

Packing an app that root owns can leave `/Applications/.isenough-original-<id>.app` behind when the last delete is denied. The image and the stub are already in place, so `pack` prints that path and tells you to run `isenough cleanup-backups`, and it exits 0. That command checks the stub and the image hash, then removes every verified backup with a single administrator prompt.

`recommend` says `already in repo, packing is instant, no upload` when the installed app's bundle id, version, and architecture are already in the repo, and it names the other Macs that have that image. `isenough ui` shows the same devices next to the app list.

## Hooks and lifecycle

The target lifecycle is pre-launch materialize → verify SHA-256 → attach read-only → forward documents/URLs →
watch app and dependents → post-quit hook → delayed detach → update LRU. Cache LRU eviction against `quotaBytes` is implemented.
Admission claims, a secure stub control protocol, and process-wide dependent detection are not. Do not use it to remove a
production app until the remaining safeguards are macOS acceptance-tested. The current `pack` default does not move the original unless stub
creation succeeds; use `--keep-original` to retain it. A pack that reuses an image whose upload is not confirmed keeps the original next to the stub.

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

## Data safety

- **P0-1, shared images.** `images/` and `manifests/` are write-once. A second Mac does not publish over an image that is missing, still a placeholder, or whose bytes do not match the manifest. Pack then exits 5 and leaves the original app in place, or it reuses a confirmed image. When the cloud copy exists but is not confirmed uploaded, pack reuses the image, keeps the original, and reports `originalKept` with the reason. `gc` does not delete an image that any visible device file still names, and a device file that has not downloaded blocks deletion.
- **P0-2, sessions.** Cold transcripts are stored as per-device write-once zstd segments (`sessions/<deviceId>/<tool>/<stamp>-<sha8>.tar.zst`). A different byte string at that path is refused. The SQLite index is committed with state `pendingDelete` before the local file is removed. A file that changes after the snapshot is kept, with reason `modified after archiving`.
- **Old session archives.** `sessions/<tool>/<yyyy-MM>.tar.gz` from the v1 layout is never overwritten and never deleted. `sessions verify --legacy` only reports members that are missing from those archives. `sessions migrate` renames the local `sessions-index.json` to `sessions-index.json.migrated-v2` and leaves the tar.gz in the repo.

## Limitations

iCloud materialization is still best-effort. Capacity admission claims from the design are not implemented. Cache LRU eviction is implemented. There is no secure stub control protocol and no process-wide dependent detection. Restore mode has a journal and a detached post-quit watcher; it is still young.
`TreeFingerprint` can miss a content change that does not change size or mtime. Set `ISENOUGH_PARANOID_INSPECT=1` to force a full tree hash on inspect. `ISENOUGH_PARANOID_VERIFY=1` forces a full image hash even when the cache stamp matches.
ULMO creation and hdiutil attach have not been run on this Linux host. Mount and restore modes must be validated on
macOS. Never attach a dataless iCloud DMG: wait until the file is fully materialized before hashing or attaching.

## Manual macOS checks

1. `swift build`, `swift test`, and `bash scripts/e2e.sh` pass.
2. On a real iCloud repo, Mac A packs and the network drops before the upload finishes. Mac B packs the same version: expect `originalKept` or exit 5, and the original app still present. After the network returns, B packs again and reuses the image.
3. Xcode in restore mode with `--image-format ULFO`: post-quit within 90 seconds, and the watcher hashes the DMG at most once.
4. `sessions key init` and `sessions --apply --encrypt`: another Mac can `reindex` and `restore --to`.
5. A sample of 1699 real session files compresses at least 2.4×, and `sessions search` returns in under 100 ms.
6. Finder, the Dock, and the `isenough ui` app list show the original icons for Keynote, Xcode, and Obsidian stubs. A stub that is removed and later installed again still has its icon (`stub refresh` backfills one that is missing).
