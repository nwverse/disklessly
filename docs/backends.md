# Backends

`disklessly` talks to a repository through `StorageBackend` (`list`, `stat`, `get`, `put`, `delete`). The local folder and an iCloud Drive folder are the file-backed form of that interface. SMB, NFS, and WebDAV use the same methods.

Image **creation** stays on `hdiutil create -format ULMO` (and `hdiutil convert` when a local ULFO/UDRO copy is required). `diskutil image create` is not used: its scrubbing and ownership do not match `hdiutil create`. Attach and detach already prefer `diskutil image` when that subcommand exists.

## SMB and NFS

```sh
disklessly backend add smb --host nas.local --share apps --user alice --mount /Volumes/apps --id nas --password-stdin
disklessly backend add nfs --host nas.local --export /export/apps --mount /Volumes/nfs --id nfs
```

The password is read from stdin and stored in the Keychain (`io.github.s546126.disklessly`, plus an SMB internet password so `mount_smbfs -N` can find it). It is not written to `config.json` and it is not placed on the mount command line. `--password` is rejected.

If the mount point is already `smbfs` or `nfs` (`stat -f %T`, a format code, 3 second cap), disklessly uses that directory and does not mount again. Otherwise it runs:

- `/sbin/mount_smbfs -N //user@host/share <mount>`
- `/sbin/mount_nfs host:/export <mount>`

There is no disk-image `--noautoopen` flag on these commands. A temp directory stands in for a mounted share in tests. A probe failure is `EX_BACKEND` (offline). `delete` of the share root is refused. `evict` removes only the local cache file and checks that the remote object is still there.

## WebDAV

```sh
disklessly backend add webdav --url https://nas.example/dav/Disklessly --user alice --id dav --password-stdin
```

`PROPFIND` lists and stats. `GET` with `Range: bytes=N-` resumes a `.part` in the cache. A `200` response to a ranged GET is the whole object and replaces the partial. After the bytes are on disk, the cache file's sha256 must match the manifest. `PUT` goes to `.<name>.tmp-<uuid>`, then `MOVE` with `Overwrite: F`, then a re-read hash. Basic credentials come from the Keychain. A connection failure is `EX_BACKEND`.

## OpenList

Supported API: **OpenList 3 and AList 3** (`/api/auth/login`, `/api/fs/list`, `/api/fs/get`, `/api/fs/put`, `/api/fs/remove`, `/api/fs/mkdir`). AList 2 is not supported.

```sh
disklessly backend add openlist --url http://nas.local:5244 --root /Disklessly --user alice --id ol --password-stdin
```

The password is stored in the Keychain. A successful login stores the token there as well (`openlist-token:…`). A 401 logs in again. `fs/get` returns `raw_url`; the download uses the same ranged GET and sha256 check as WebDAV. The raw URL does not receive the API token. `fs/put` uploads with `File-Path` and `As-Task: false`, then re-reads the object and checks the hash.

### One-click OpenList

`disklessly openlist install` (or the dashboard's Cloud drives card) downloads the pinned OpenList release for this Mac from GitHub, checks its SHA-256, and keeps it under `<stateDir>/openlist/`. It listens on 127.0.0.1 only (S3, FTP and SFTP off), runs as the LaunchAgent `io.github.s546126.disklessly.openlist`, and its admin password is generated once and stored in the Keychain (`disklessly openlist password`). Install stores the backend `openlist-local` without switching the repo; add your drives on its admin page, then `disklessly backend use openlist-local` (or `openlist install --use`). `openlist uninstall [--purge]` removes the LaunchAgent and binary; `--purge` also removes its data.

## rclone (Google Drive, Dropbox, OneDrive, Box, pCloud, ...)

Disklessly.app ships rclone next to the `disklessly` CLI, and the stable engine copy under `<stateDir>/bin` gets a copy beside it. Without the app, rclone is found through `DISKLESSLY_RCLONE`, `PATH`, or Homebrew. Disklessly keeps its own config at `<stateDir>/rclone/rclone.conf` and never reads `~/.config/rclone`.

```bash
disklessly cloud connect gdrive            # opens the sign-in page; stores backend rclone-gdrive
disklessly backend use rclone-gdrive       # make it the repo (or: cloud connect gdrive --use)
disklessly cloud list
disklessly rclone lsd gdrive:              # any rclone command with Disklessly's config
disklessly backend add rclone --remote NAME [--root DIR] [--id ID]   # a remote made with `disklessly rclone config`
disklessly backend use default             # back to iCloud Drive / the local folder
```

The repo lives in `Disklessly/` on the drive unless `--root` says otherwise. Google Drive is connected with the `drive.file` scope, so Disklessly sees only files it created. Each call runs one rclone command (`lsjson`, `cat --offset --count`, `rcat`, `copyto`, `deletefile`, `mkdir`); nothing runs in the background. A fresh whole-file download uses `--multi-thread-streams 8`; a resumed one appends the rest with `cat --offset`. A plain switch (`backend use`) does not move apps already offloaded: their launchers keep pointing at the old repo until you switch back. To take them along, migrate instead (see [Moving to another repo](#moving-to-another-repo)).

## iCloud Drive

`icloud` is a file-backed repository, same layout as `local`, with two extra behaviors:

- Before a file is read, an evicted ubiquitous item is downloaded with `FileManager.startDownloadingUbiquitousItem`. The wait is bounded (`DISKLESSLY_ICLOUD_DOWNLOAD_TIMEOUT`, default 900 seconds) and the error includes the last download status.
- Directory listings and `stat` are bounded (`DISKLESSLY_ICLOUD_LIST_TIMEOUT`, default 20 seconds). On macOS the listing is coordinated with `NSFileCoordinator` and `.immediatelyAvailableMetadataOnly`, so a slow manifest listing does not wait for every placeholder to download.

A stub launched from Finder or LaunchServices has been observed to block for minutes inside the iCloud file provider even when the same folder lists immediately from Terminal. disklessly cannot cancel that stuck system call. The timeout only returns the caller an error. If that happens, grant the launching app access to the repo in System Settings → Privacy & Security → Files and Folders, and Full Disk Access when the folder is outside your home. A path under `Mobile Documents/com~apple~CloudDocs` uses this backend even when the saved type is `local`.

## Moving to another repo

`disklessly repo migrate --to ID|default [--keep-old-as-mirror]` copies the current repo onto backend `ID` and only then makes it the repo. In the dashboard this is `POST /api/cloud/use` with `"migrate": true`.

- Every object is copied: images, manifests, catalog, device files, archived sessions, trash, and `repo.json`. Because `repo.json` comes along, the new repo has the same `repoId`, so stubs already in `/Applications` keep launching from it.
- Objects go through one staging file under the cache dir (`<cacheDir>/repo-sync`), one at a time, so a multi-GB image is never held in memory and the staging volume needs free space for the largest object plus 256 MiB.
- Images are checked against the sha256 in their manifest before upload, and every upload's size is checked on the destination. Images go first, then manifests, catalog and device files, then `repo.json`, so the new repo never lists an app whose image is not there yet.
- Our own staging files (`.x.tmp-…`), `locks/`, and conflict copies (`x 2.json`) are skipped. iCloud placeholders (`.x.dmg.icloud`) are copied by their real name; iCloud downloads them on read.
- The copy runs twice (the second pass picks up anything another Mac wrote meanwhile) and is then verified: every manifest and its image must be on the destination with the recorded size. If anything fails, the config stays on the old repo. Running the command again resumes: objects already there with the same size (large files) or the same bytes (small files) are skipped.
- A destination that already holds a different repo (another `repoId` with images or manifests) is refused.
- An old repo with nothing but `repo.json` and empty folders switches at once. `--no-copy` switches without copying, like `backend use`.

## Mirrors

`mirrorBackendIds` in the config lists extra copies of the repo (backend ids, or `default` for the folder at `repoPath`). The active repo is never one of them.

```
disklessly repo mirror add nas          # keep a second copy on backend nas
disklessly repo mirror sync             # copy the repo onto every mirror (same rules as migrate)
disklessly repo mirror [list]           # mirrors and their last sync
disklessly repo mirror remove nas       # stop using it; its files stay
```

- Reads fail over. `get` and `download` (manifests, images, session archives) try each mirror in order when the active repo errors or lacks the object, so an offloaded app still launches when the cloud drive is down. `list` and `stat` fail over only when the active repo errors: a repo that answers "not there" is believed, so a publish never skips an upload because an old copy sits on a mirror.
- Writes and deletes go to the active repo only. Mirrors catch up on `repo mirror sync` (or `POST /api/cloud/mirrors/sync` in the dashboard).
- A mirror is opened only when a read needs it; one that cannot be opened (offline share, missing secret) is skipped.
- Each sync's result is kept in `<stateDir>/mirrors.json` (time, ok, objects copied, unchanged, failed, bytes).
- `repo migrate --keep-old-as-mirror` turns the old repo into a mirror after the move.

## Defaults

Unless the config or environment already sets them: cache quota 20 GiB, free-space floor 15 GiB (`DISKLESSLY_MIN_FREE_BYTES`), detach delay 120 s, ad-hoc signing (`-`, override with `DISKLESSLY_SIGN_IDENTITY`). Fetching refuses with `EX_NOSPACE` (8) when the download would leave less than the floor free.
