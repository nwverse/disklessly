# Data follows the app — design

Status: **v1 shipped 2026-11-07** (`disklessly data`, `Sources/DisklesslyEngine/AppData.swift`); the rest is still a
proposal. What v1 does and how it differs from the full design below:

- Roots: only `~/Library/Application Support/<bundleId>` and `.../<app name>` (the name only when no other app in
  /Applications or ~/Applications has it), real directories, no links. Containers, HTTPStorages, WebKit and saved
  state are not touched.
- Opt-in per app with `disklessly data enable APP` (dashboard: an offloaded app's ⋯ menu, or the app's data folder
  under Other big items), only for apps offloaded on this Mac. Refused for `com.apple.*`, Disklessly itself, and
  apps with a launchd job (a `~/Library/LaunchAgents` plist naming the app, or a loaded label starting with the
  bundle id).
- Format: the roots cloned into a snapshot, then one tar+zstd archive (the `FolderArchive` of file offload), sealed
  with the image key when one exists (`.tar.zst.dkli`). No sparse bundle: every changed quit uploads the whole
  archive, and every launch downloads it. A quit with nothing changed since the data came back uploads nothing.
- Repo: `data/<deviceId>/<bundleId>/manifest.json` (`data/1`: generation, object, sha256, size, roots, fingerprint)
  and the object. The previous object is deleted once the new generation is committed.
- Gate: no process inside the stub path or the mount, no process naming a root, nothing open under a root
  (`lsof +D`). No FSEvents quiet period.
- Data-out runs after the session's supervisor sees the app quit (mount: after the detach; restore: after the
  launch returns; `hook watch` for `--no-wait` launches). The upload runs without the app lock; the commit (re-check
  gate and fingerprint, write the manifest, move the roots aside) runs under it. A launch after the session began
  cancels the move.
- Data-in runs at the start of every launch under the app lock. Any failure (no manifest, wrong generation, missing
  key, no space, a root that reappeared meanwhile) refuses the launch, so the app never starts with empty data.
- Data-out refuses when the repo's generation is not the one this Mac last had, so another copy is never
  overwritten.
- Recovery: no journal. Transactions live in `Application Support/.disklessly-data/<bundleId>--<id>/`; one with a
  `committed` marker had a verified repo copy before any root was moved aside, so a crash mid-move is finished
  (all moved) or rolled back (partly moved). Anything else there is a snapshot or download and is removed.
- `unpack` brings the data back first and turns data offload off.

The original proposal follows. The shipped part of this topic is
`disklessly caches [--apply]` (see "Step 0" below). This document is the spec for what may come after it;
docs/design.md stays the spec for everything else and wins where the two disagree.

## Problem

An offloaded app's bundle lives in the repo, but its data does not. The disk usage card shows the result: for
many large apps the bundle is the smaller half, and `~/Library/Application Support/<id>` and
`~/Library/Containers/<id>` stay on the Mac for an app opened twice a year (DAWs with sample libraries, IDEs with
indexes, chat apps with media, games with saves).

"Data follows the app" means: optionally, the app's data is packed into a **data image** in the repo, put back
before the app launches and taken away again after it quits — the same lifecycle the bundle already has.

## Step 0 (shipped): caches only

`disklessly caches` and the "Clear app caches" button in the Disk usage card empty
`~/Library/Caches/<bundleId>`, `~/Library/Caches/<app name>` and `~/Library/Containers/<bundleId>/Data/Library/Caches`
for offloaded apps that are not running. It is a dry run unless `--apply` is given. Caches are by definition
regenerable, so nothing is uploaded and nothing needs restoring. The rules it set and that this design keeps:

- Never follow a link out of `~/Library` (a planted link at `Caches/<id>` or `Containers/<id>/Data` is ignored).
- Only apps replaced by a stub on this Mac: a shared repo also lists apps another Mac offloaded.
- Refuse while the app runs: state `running`/`detaching`, an open restore journal, or a process executing the app
  (from the mount, the restored bundle, or any `<name>.app/Contents/MacOS/<exe>`). Re-checked under the per-app
  lock (`locks/app/<appId>.lock`) right before deleting, so a launch cannot start mid-clear.
- Empty the folder, keep the folder (owner, mode and ACLs of a container's `Caches` stay as the sandbox made them).
- Application Support and container data outside `Data/Library/Caches` are never touched.

## Goals and non-goals

Goals

- Opt-in per app (`disklessly data enable APP`), never on by default and never inferred by `recommend`.
- Data is **per device**: two Macs that share a repo never see or overwrite each other's data.
- Never lose data: the local copy is deleted only after the image holding it is verified in the repo, and a crash at
  any point leaves either the local folders or a verified image — recovery knows which from the journal.
- Works with both mount and restore modes.

Non-goals

- Syncing data between Macs. This is offload, not sync. (A user who wants their Mac A data on Mac B can `export`
  later; that is a separate feature.)
- Apps that keep data outside the two well-known folders (`~/Documents/<App>`, `~/Music/...`, group containers,
  Keychain, `defaults` domains). `Preferences/<id>.plist` stays on disk: it is small and `cfprefsd` owns it.
- Apple apps and apps whose data is SIP/TCC-protected beyond what the user can grant (Mail, Messages, Photos,
  Safari). `data enable` refuses them by bundle id prefix `com.apple.` and by a denylist.

## What is packed

Per app, the **data roots** are, if present and real directories (no links, same rule as Step 0):

| Root | Notes |
|---|---|
| `~/Library/Application Support/<bundleId>` | |
| `~/Library/Application Support/<app name>` | only if no other installed app claims the same name (same matching as `UsageScan`) |
| `~/Library/Containers/<bundleId>` | whole container minus `Data/Library/Caches`; needs Full Disk Access or App Management, see TCC |
| `~/Library/HTTPStorages/<bundleId>`, `~/Library/WebKit/<bundleId>`, `~/Library/Saved Application State/<bundleId>.savedState` | small, but an app may refuse to start or lose its session without them |

Caches are excluded (they are cleared by Step 0 instead). Group containers
(`~/Library/Group Containers/<team>.<group>`) are **never** packed: they are shared with other apps, widgets and
extensions of the same team, which may run while the main app is offloaded.

The roots are recorded in the data manifest at enable time and only those roots are ever moved; a root that
appears later is picked up only by an explicit `data refresh APP`.

## Repo layout: per-device data images

```
data/<deviceId>/<bundleId>/manifest.json          data/1 manifest, written only by that device
data/<deviceId>/<bundleId>/<dataImageId>.sparsebundle  (or .dmg, see format)
```

- The path contains the device id from `device.json`, never the hostname. A Mac only ever reads and writes under its
  own `data/<deviceId>/`. `gc` on another Mac treats `data/<otherDeviceId>/` as opaque: it does not delete it, and
  the existing 90-day stale-device rule extends to it (forgetting a device with `devices forget --yes` lists its data
  images and their size first, and deletes them only with an extra `--delete-data`).
- One app on one device has at most one **current** data image plus the previous one while a new one is uploaded
  (generation swap, below). Older generations go to the repo trash and follow the existing 7-day purge.
- The bundle image stays shared and content-addressed. Data images are not: they change on every quit.
- Format: a sparse bundle (`UDSB`) encrypted with the same device key scheme as session archives
  (DisklesslySessions `SegmentCrypto`), because app data holds tokens and personal content and the repo may be on a
  NAS or WebDAV server. Sparse bundles upload changed bands only, which matters for a 20 GB DAW library that changed
  by a few MB. iCloud backend: bands are files, so they evict and download like any other repo file.

`data/1` manifest:

```json
{ "schema": "data/1", "deviceId": "6F1C…", "bundleId": "com.example.Foo", "generation": 12,
  "image": { "file": "<dataImageId>.sparsebundle", "treeHash": "…", "bytes": 21474836480 },
  "roots": ["Application Support/com.example.Foo", "Containers/com.example.Foo"],
  "packedAt": "…", "packedFromBuild": "1234" }
```

`treeHash` uses the existing `BundleHasher` digest over the image's contents, so verify-before-delete works the
same way as for bundles.

## Lifecycle

Data has its own small state per app on this device, stored next to the app record in `state.json`:
`local` (folders on disk, normal) → `packing` → `offloaded` (only in the repo) → `restoring` → `local` …

### Before launch (data-in)

Runs inside the existing pre-launch hook (§5.2 of design.md), under the same `L1` app lock, **before** the bundle is
mounted or restored, so the app never starts without its data:

1. If data state is `local`, nothing to do (data was never taken away, or a previous data-out did not finish).
2. Fetch the current data image (cache admission and free-space claims as in §6.1; data images are never LRU-evicted
   while `restoring`).
3. Verify `treeHash`. Mismatch → stop the launch with `EX_INTEGRITY`; the folders are still absent, nothing is
   half-written.
4. Copy each root into `~/Library/.disklessly-staging/<txid>/<root>` (same volume as the destination), verify, then
   `rename(2)` into place. A destination that already exists (the app or a helper recreated it while offloaded) is
   **not** merged: it is moved to `retained/<appId>/data-<ts>/` and recorded as `needsResolution`, and the launch is
   refused like a retained bundle (§5.8.7) until the user picks one.
5. State → `local`, then the normal launch continues.

### After quit (data-out)

The mount-mode supervisor and restore-out already wait for the app to quit (§5.4, §5.8.3). Data-out runs **after**
the bundle has been detached or restored out, and only when the data quiesce gate (below) passes:

1. Quiesce gate (helpers, below). Not clean → data stays `local` and the supervisor retries with the existing
   backoff; the bundle side is not affected.
2. Snapshot: `clonefile(2)` each root into staging (APFS, instant, and the app's folders keep working if a helper
   writes during upload). Non-APFS home volume → plain copy.
3. Write the snapshot into the next-generation data image, compute `treeHash`, upload, verify in the repo
   (same evidence as `publish` for bundles), then write `manifest.json` with `generation + 1`.
4. Re-check the gate. If anything wrote to a root since the snapshot (compare a recursive `mtime`/inode fingerprint
   taken at step 2), discard the new generation and stay `local`: the next quit tries again.
5. Delete the local roots (the clones in staging first, then the live folders) and set state `offloaded`.

Only step 5 removes data, and only after a verified upload of a snapshot that is still identical to the live folders.

### Mount mode vs restore mode

| | mount | restore |
|---|---|---|
| When data-in runs | before `hdiutil attach` | before restore-in's `prepared` phase |
| When data-out runs | after a verified detach (state `cached`) | after restore-out reaches `retired` |
| Usage root for the gate | the data roots (below), not `<mnt>` | the data roots, not `<dest>` |
| Relaunch during the detach delay | data is still `local`: nothing to do | same |

Data and bundle are separate transactions with separate journals: a bundle that cannot be detached does not hold
data hostage and vice versa. The only ordering rule is data-in before launch and data-out after the bundle is gone.

`unpack APP` (bring the app back for good) does data-in and then disables data offload for that app.

## Background helpers that keep writing after quit

The hard part. Many apps leave something running after the main window closes: login items and
`SMAppService` agents (`~/Library/LaunchAgents`, `Contents/Library/LoginItems`), XPC services, File Provider and
Finder Sync extensions, `cfprefsd` flushing preferences, Spotlight importers, crash reporters, updaters (Sparkle's
`Autoupdate`), Electron's GPU/renderer processes that linger for seconds.

The data quiesce gate is **clean twice**, as for bundles (§5.9), but the usage root is the set of data roots:

1. No process of the app's bundle id, and no process whose executable lies inside the app bundle (main, helpers,
   XPC services, login items), using the existing `ProcessProbe` passes plus a `pgrep`-style scan for the bundle path.
2. No open file descriptor, cwd or mapping under any data root (`PROC_PIDLISTFDS` pass of §5.9).
3. No `launchd` job whose `Program`/`BundleProgram` points into the bundle or whose label starts with the bundle id
   (`launchctl print gui/<uid>` parse). A loaded login item that is idle still counts: it can start at any time and
   would find its data gone.
4. No write under the roots for `quietSeconds` (default 30) measured by FSEvents.

Apps that fail (3) permanently — they ship a login item the user keeps enabled — cannot use data offload; `data
enable` runs the gate once and refuses with the helper's label so the user can turn it off in System Settings →
General → Login Items. Data offload never unloads, kills or edits another app's launchd jobs.

If a helper starts while data is `offloaded` it finds no folders and usually recreates empty ones. That is detected at
the next data-in (step 4: the destination exists) and handled as `needsResolution`, never by a silent merge.

## TCC and containers

Since macOS 14, reading or writing another app's `~/Library/Containers/<id>` from a non-sandboxed process prompts
"Disklessly would like to access data from other apps" (App Data protection; to verify: the exact TCC service name,
whether moving a whole container away is gated the same way as reading it, and whether macOS 15/26 tightened it).
Full Disk Access covers it. Rules:

- The prompt is tied to the responsible process. The CLI run from Terminal inherits Terminal's grant, the menu-bar
  app has its own. Data offload for containers is therefore offered **only from the menu-bar app / dashboard**,
  which asks once (via a deliberate probe read at `data enable`) and stores nothing about the answer — TCC is the
  source of truth.
- A denied or revoked grant must fail closed and early: `data enable` refuses containerised apps without it, and
  data-out checks access to every root **before** the snapshot. A container we cannot read is left `local`; a
  container we could read at snapshot but cannot delete afterwards is left in place and the new generation is
  discarded (never "uploaded but not deleted" as a steady state, because the next data-in would see it as a conflict).
- The background supervisor (`hook watch`) runs as the CLI binary. Its responsible process is the stub that launched
  it, which is not the TCC-granted app (to verify: how TCC attributes a detached `hook watch`). Data-out for
  containers would therefore be handed to the menu-bar app over a new local channel (none exists today; the
  dashboard's loopback server serves the page, not the engine). If the menu-bar app is not running, data stays
  `local` and the dashboard shows "waiting to offload data".
- Never touch `Data/Library/Preferences` symlinks or the container's `.com.apple.containermanagerd.metadata.plist`
  separately: the container directory moves as one unit, with its metadata, or not at all. Data-in restores it with
  the original owner and mode; `containermanagerd` re-validates it on next launch.
- Step 0 already reads containers only "when readable": a denied `contentsOfDirectory` skips the folder.
- Name matching (`Caches/<app name>`, `Application Support/<app name>`) can collide with another app that uses the
  same folder name. Step 0 accepts that for caches (regenerable); data offload must not, hence the "no other
  installed app claims the name" rule above.

## Two Macs, one repo

- Data images are keyed by `deviceId`, so Mac A's quit never overwrites Mac B's data, and Mac B launching the app
  never downloads Mac A's data. Each Mac's app behaves as if it had never been offloaded on the other one.
- The bundle image is shared and may be a newer build than the one that wrote the data (`packedFromBuild`). A data
  image from a newer build than the bundle about to launch is refused (`needsResolution`, "data was written by
  Foo 5.1; this Mac would launch 5.0"); older data is fine, apps migrate forward.
- A Mac restored from Time Machine or migrated keeps its old `deviceId` only if `device.json` came along. If both the
  old and the new Mac end up with the same id, the device-file `lastSeen`/hostname check already warns; data
  offload additionally refuses data-out when the repo's current generation is newer than the one this Mac last
  wrote (someone else wrote under our id), so neither copy is overwritten.
- `devices forget` and the 90-day stale rule never delete data images without the explicit `--delete-data`.

## Crash recovery with journals

Both directions are journaled transactions in `journals/<txid>.json` with the existing rules (WAL before effect,
same-volume staging, idempotent phases, never delete the only copy). New kinds `data-in` and `data-out`.

data-out

| Phase | Effect | Recovery |
|---|---|---|
| `quiesced` | gate clean twice | re-run the gate; busy → close journal, stay `local` |
| `snapshotted` | clones in `staging/<txid>/` + fingerprint | delete clones, close journal, stay `local` |
| `uploaded` | new generation image in repo, verified | if verification cannot be proven → delete clones, keep `local`, leave the image for gc |
| `committed` | `manifest.json` generation + 1 written | continue to `removed` only if the fingerprint still matches; else roll back to previous generation (rewrite manifest) and stay `local` |
| `removed` | live roots and clones deleted; state `offloaded` | finish deleting; the image is verified, so this is safe |
| `closed` | journal removed | — |

data-in

| Phase | Effect | Recovery |
|---|---|---|
| `fetched` | image in cache, verified | refetch |
| `staged` | roots copied into `staging/<txid>/` and verified | delete staging, retry from `fetched` |
| `installed` | each root renamed into place (journal lists which ones are done) | rename the remaining ones; a destination that appeared meanwhile → `retained/`, `needsResolution` |
| `closed` | state `local`, staging removed | — |

A crash in data-in leaves the app unlaunched (the launch only continues after `closed`), so a half-installed set of
roots is never seen by the app. `doctor --fix` and `gc` replay these journals like the restore and unpack journals
today. Data state `packing`/`restoring` without an open journal is reset by re-deriving from the disk: roots present
→ `local`; absent and a verified current generation exists → `offloaded`; absent and no image → error shown by
`doctor`, nothing deleted.

## CLI and dashboard (proposed)

```
disklessly data enable APP | disable APP     # disable = data-in now, then stop offloading data
disklessly data status [APP]                 # state, generation, local vs repo bytes, last gate result
disklessly data refresh APP                  # re-detect roots
```

Dashboard: an app row gets a "Data: on this Mac / in repo / waiting (helper running)" line; the Disk usage card's
data box for an offloaded app links to `data enable`.

## Open questions

- Data images for apps in `restore` mode are mostly the same bytes every quit; is a sparse bundle with band-level
  upload enough, or do we need content-defined chunking like the session archives?
- Does `containermanagerd` accept a container that was moved away and back while the app was not running on every
  supported macOS? Needs a test matrix (14, 15, 26) before containers are enabled at all; Application Support only
  could ship first.
- How long should data-out wait for an Electron app's lingering helpers before giving up for this quit?

## Test plan (when implemented)

- Pure: root detection and the link rule (as in `AppCachesTests`), journal phase tables with the existing
  fault-injection harness (§5.8.6) for every phase in both directions, the newer-build refusal, the same-device-id
  refusal.
- Gate: a fake process table with a lingering helper, a loaded launchd job, and an FSEvents write after the snapshot.
- Two engines on one `LocalFolderBackend` repo with different device ids: neither sees the other's data.
