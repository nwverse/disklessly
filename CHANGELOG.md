# Changelog

All notable changes to Disklessly (`disklessly`) are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.4] - 2026-11-26

- Large folder offloads no longer hold the whole stream in memory. Each streaming read returned an autoreleased
  buffer that a long loop on a background thread never freed: a 32 GB folder pushed the process to 19 GB and
  filled the disk with swap. Reads in the archive, zstd, chunk and SSH loops now run in an autorelease pool.
- Google Drive deletes are final (`use_trash=false`). They used to land in Drive's trash and keep counting
  against the quota for 30 days, although Disklessly already keeps its own `trash/` with a grace period.
- `gc` removes upload parts (`files/staging/*.part`, `staging/*.part`) older than a day. A process killed
  mid-upload left them behind; on one Drive they had grown to 40 GB. `gc --dry-run` lists them.
- The menu-bar app no longer quits silently when a child process or connection closes while it is writing
  (SIGPIPE). This happened when an upload failed early, for example on a full cloud drive. The app and CLI now
  ignore SIGPIPE, and writes into rclone's stdin fail with an error instead of raising an exception.
- A full cloud drive (Google Drive `storageQuotaExceeded` and similar) is reported as "the cloud drive is full"
  instead of "cannot reach the repo" or "The file couldn't be saved": when an upload fails, the upload's own error
  is reported rather than the broken pipe the archiver hits after it.
- Linked bundles whose paths nest (`~/.vphone` and `~/.vphone/machines/…`) offload only the outer folder,
  rather than archiving it while the inner one is being offloaded at the same time.

## [0.3.3] - 2026-11-24

- Hidden usage ("对账"): the dashboard's Not measured box is broken into other users' folders, local snapshots and
  purgeable space (only when snapshots exist), the Spotlight index, and the remainder (likely the Spotlight index or
  folders the scan could not read). New `disklessly reconcile [--json]` prints the same breakdown and safe next steps.
- Per-item actions, each with its own confirmation and never part of a bulk clean: thin local snapshots
  (`tmutil thinlocalsnapshots`), measure the Spotlight index with one administrator prompt, and rebuild it
  (`mdutil -E`) only when it is abnormally large (over max(20 GB, 5% of used)).
- AI model folders (Hugging Face, Ollama, LM Studio, PyTorch Hub, Whisper) are listed locally with size, last change and
  whether their tool is running; idle ones can be offloaded or moved to the Trash. The same list now drives remote
  machine scans (LM Studio, PyTorch Hub and Whisper added there too).
- Fixed: remote clean on a Mac host (no `/proc`) now detects files in use with `lsof` instead of deleting them.
- Fixed: bringing back a chunked offloaded folder failed with "File exists"; concurrent linked-bundle offload and
  chunked transfers could crash ("closure argument was escaped"); bringing back a folder could kill the process with
  SIGPIPE when tar stopped reading at the end-of-archive marker; `pack` listed repo manifests three times.

## [0.3.2] - 2026-11-23

- The app is now shipped as a signed, notarized `Disklessly-<version>.dmg`, and the Homebrew cask is
  published: `brew install --cask nwverse/tap/disklessly`. The macOS CLI tarball is signed and
  notarized too, so the formula no longer needs the quarantine workaround.
- `pack` is faster: app images default to LZFSE (`ULFO`; `--image-format ULMO` or
  `DISKLESSLY_IMAGE_FORMAT=ULMO` restores LZMA), repo manifests are read in parallel and reused across
  pack, publish, and catalog rewrite, and uploads are verified against the SHA-256 the backend reports
  (Google Drive) instead of downloading the image again. Backends without a hash still download to verify.
- Pack progress shows each stage (check, hash, archive, encrypt, upload with bytes, verify, stub), and the
  dashboard shows a live upload percentage.
- Large offloaded files and folder archives are split into content-addressed chunks
  (`files/chunks/`, `files/objects/<sha256>.chunks.json`) and uploaded, verified, and downloaded over
  several streams.
- Linked bundles: bind extra folders or files to an app from the dashboard (searchable app picker) so
  they are offloaded and restored with it and come back automatically when its stub launches.
- Dashboard treemap: folders load on demand and in parallel, results are cached, expanded subtrees
  survive refreshes, app icons are drawn in their boxes, and deleting or offloading an item refreshes
  only the affected folder instead of returning to the top.
- Rebuildable caches (`~/Library/Caches/<third-party>`, Xcode `DerivedData`) can be moved to the Trash
  from the map; `Application Support`, Apple caches, and Disklessly's own folders stay protected, and
  `~/Library` still cannot be offloaded. Right-clicking an app that is already a stub explains that the
  remaining space is its data and offers to reveal or offload that data.

## [0.3.1] - 2026-11-21

- Offloading (`pack`, file/folder offload, app data offload, container image offload, and upload
  verification) now caps its transient staging space reserve at 256 MiB instead of applying the full
  15 GiB download floor (`minFreeBytes`), so users can still offload items to free space when their
  disk is already below 15 GiB free. Downloads and restores still enforce the full `minFreeBytes` floor.
- The dashboard's disk usage map is now a nested treemap (squarified, like WinDirStat or WizTree)
  instead of a four-row flame chart: each box's area is its size, boxes with room show their
  children under a title strip, and the map keeps about a 16:9 shape and redraws when the window
  is resized. Click to zoom, the path above, the hover line and the right-click menu work as before.
- The usage map is polished: labels and sizes are drawn only when they fit whole, free space sits in one
  strip along an edge, boxes snap to whole pixels, keyboard focus survives a zoom (Escape zooms out), and
  narrow windows get a taller map with one less nesting level.

## [0.3.0] - 2026-11-14

- Every session archive path (CLI apply, dashboard apply, settling pending rows) scans the user's
  running processes and herdr's saved layout for referenced session ids and `.jsonl` paths, at plan
  time and again before each local delete. A failed process listing keeps every local file of the
  run (`reference check failed`).
- `sessions status` and the sessions commands no longer create a missing local repo folder; it is
  reported unreachable. Status adds `stateDir`.
- `sessions restore` takes the sessions lock and never replaces a file that appeared during the
  download (exit 9).
- Archived sessions of this device get a local plain-text index, `stateDir/sessions/text/<entryId>.jsonl`
  (a header line, then one line per user or assistant message), written before the local file is
  deleted and never uploaded. A transcript whose text file cannot be written is skipped (`text index
  failed`) and stays local. `sessions status` adds `textDir` and `textFiles`. Each apply keeps one
  text file per session (the newest archived version) and removes files left by failed runs.
- `sessions list` prints the archived-session index with session ids, working directories, titles,
  first prompts, and segment paths; `sessions status` reports index counts and whether the backend's
  `repo.json` answers (`--check-segments` stats every referenced segment).
- `sessions --exclude-from FILE|-` keeps referenced sessions local; the list is checked again before
  each local delete. The `--apply` report adds `uploadedBytes` and `archived`.
- New segments are filed under `sessions/<device>/<tool>/<project>/<yyyy-MM>/`; `reindex` reads this
  and the earlier flat layout. The session index is schema 4 (`cwd`, `first_prompt`).
- `sessions --apply`, `restore`, and `reindex` exit 4 (`backend unreachable`) when the repo marker
  cannot be read, before anything is uploaded or deleted, instead of filling a missing or unmounted
  folder or reporting an empty reindex.
- Archiving a restored, unchanged session again no longer fails with a duplicate index id, and restore
  by path picks the newest archived copy. A restored pi or Codex session is no longer archived again
  on the next run (it stays local for the cold period), and an unchanged re-archive reuses the stored
  segment instead of uploading an orphan copy.
- Excluding a Claude Code session also keeps its `subagents/` transcripts. `sessions restore` can read
  from a mirror when the primary has no marker and opens no backend when the file is already in place.
  A repo with images or manifests but no `repo.json` still counts as reachable.
- `sessions status --check-segments` reports failed stats as `unchecked` (never `missing`) and stops
  after 60 s.
- First release under the proprietary license (copyright Shengtao Lin, all rights reserved).
  The repository history before this release was squashed into a single commit.
