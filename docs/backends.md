# Backends

`isenough` talks to a repository through `StorageBackend` (`list`, `stat`, `get`, `put`, `delete`). The local folder and an iCloud Drive folder are the file-backed form of that interface. SMB, NFS, and WebDAV use the same methods.

Image **creation** stays on `hdiutil create -format ULMO` (and `hdiutil convert` when a local ULFO/UDRO copy is required). `diskutil image create` is not used: its scrubbing and ownership do not match `hdiutil create`. Attach and detach already prefer `diskutil image` when that subcommand exists.

## SMB and NFS

```sh
isenough backend add smb --host nas.local --share apps --user alice --mount /Volumes/apps --id nas --password-stdin
isenough backend add nfs --host nas.local --export /export/apps --mount /Volumes/nfs --id nfs
```

The password is read from stdin and stored in the Keychain (`io.github.s546126.256isenough`, plus an SMB internet password so `mount_smbfs -N` can find it). It is not written to `config.json` and it is not placed on the mount command line. `--password` is rejected.

If the mount point is already `smbfs` or `nfs` (`stat -f %T`, a format code, 3 second cap), isenough uses that directory and does not mount again. Otherwise it runs:

- `/sbin/mount_smbfs -N //user@host/share <mount>`
- `/sbin/mount_nfs host:/export <mount>`

There is no disk-image `--noautoopen` flag on these commands. A temp directory stands in for a mounted share in tests. A probe failure is `EX_BACKEND` (offline). `delete` of the share root is refused. `evict` removes only the local cache file and checks that the remote object is still there.

## WebDAV

```sh
isenough backend add webdav --url https://nas.example/dav/256isenough --user alice --id dav --password-stdin
```

`PROPFIND` lists and stats. `GET` with `Range: bytes=N-` resumes a `.part` in the cache. A `200` response to a ranged GET is the whole object and replaces the partial. After the bytes are on disk, the cache file's sha256 must match the manifest. `PUT` goes to `.<name>.tmp-<uuid>`, then `MOVE` with `Overwrite: F`, then a re-read hash. Basic credentials come from the Keychain. A connection failure is `EX_BACKEND`.

## OpenList

Supported API: **OpenList 3 and AList 3** (`/api/auth/login`, `/api/fs/list`, `/api/fs/get`, `/api/fs/put`, `/api/fs/remove`, `/api/fs/mkdir`). AList 2 is not supported.

```sh
isenough backend add openlist --url http://nas.local:5244 --root /256isenough --user alice --id ol --password-stdin
```

The password is stored in the Keychain. A successful login stores the token there as well (`openlist-token:…`). A 401 logs in again. `fs/get` returns `raw_url`; the download uses the same ranged GET and sha256 check as WebDAV. The raw URL does not receive the API token. `fs/put` uploads with `File-Path` and `As-Task: false`, then re-reads the object and checks the hash.

## iCloud Drive

`icloud` is a file-backed repository, same layout as `local`, with two extra behaviors:

- Before a file is read, an evicted ubiquitous item is downloaded with `FileManager.startDownloadingUbiquitousItem`. The wait is bounded (`ISENOUGH_ICLOUD_DOWNLOAD_TIMEOUT`, default 900 seconds) and the error includes the last download status.
- Directory listings and `stat` are bounded (`ISENOUGH_ICLOUD_LIST_TIMEOUT`, default 20 seconds). On macOS the listing is coordinated with `NSFileCoordinator` and `.immediatelyAvailableMetadataOnly`, so a slow manifest listing does not wait for every placeholder to download.

A stub launched from Finder or LaunchServices has been observed to block for minutes inside the iCloud file provider even when the same folder lists immediately from Terminal. isenough cannot cancel that stuck system call. The timeout only returns the caller an error. If that happens, grant the launching app access to the repo in System Settings → Privacy & Security → Files and Folders, and Full Disk Access when the folder is outside your home. A path under `Mobile Documents/com~apple~CloudDocs` uses this backend even when the saved type is `local`.

## Defaults

Unless the config or environment already sets them: cache quota 20 GiB, free-space floor 15 GiB (`ISENOUGH_MIN_FREE_BYTES`), detach delay 120 s, ad-hoc signing (`-`, override with `ISENOUGH_SIGN_IDENTITY`). Fetching refuses with `EX_NOSPACE` (8) when the download would leave less than the floor free.
