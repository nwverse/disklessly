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

## Defaults

Unless the config or environment already sets them: cache quota 20 GiB, free-space floor 15 GiB (`ISENOUGH_MIN_FREE_BYTES`), detach delay 120 s, ad-hoc signing (`-`, override with `ISENOUGH_SIGN_IDENTITY`). Fetching refuses with `EX_NOSPACE` (8) when the download would leave less than the floor free.
