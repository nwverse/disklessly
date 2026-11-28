# Disklessly on Linux

Status: the Linux build is a CLI for the parts that do not need macOS. Offloading
apps stays macOS only for now. This page covers what the Linux build does, where it
keeps things, and a design note for offloading AppImage files later.

## What runs on Linux

| Command | Linux | Notes |
|---|---|---|
| `files`, `offload PATH...`, `fetch PLACEHOLDER...` | yes | scan large idle files/folders in `$HOME`, offload as verified `.tar.zst`/`.bin` objects, leave `.disklessly` placeholders and cold-folder links |
| `containers …` | yes | list, offload, restore, clean, and forget images from Docker, rootless Docker, Docker Desktop for Linux, and Podman's Docker-compatible socket |
| `sessions …` | yes | archive, search, restore, reindex, verify, `key init/status`, `--encrypt` |
| `ui [--open]` | yes | dashboard with sessions, disk usage, devices, license; app panels are hidden |
| `backend add/list/use`, `cloud …`, `rclone …` | yes | SMB and NFS shares must already be mounted (`--mount DIR`); WebDAV, OpenList, and rclone remotes connect directly |
| `devices`, `license`, `init`, `list`, `status`, `version`, `help` | yes | `list`/`status` show images that Macs offloaded into a shared repo |
| `pack`, `launch`, `restore`, `unpack`, `recommend`, `prefetch`, `pin`, `unpin`, `evict`, `detach`, `reap`, `evict-local`, `cleanup-backups`, `gc`, `doctor`, `resolve`, `hook`, `icons`, `install-engine`, `stub`, `dev`, `data`, `caches`, `openlist` | no | exit 3 (`EX_UNSUPPORTED`) with "… is macOS only" |

`gc` is refused because it trashes and purges images in the repo. A Linux machine
sharing a repo with Macs should not rewrite the Macs' images.

The dashboard's `/api/status` reports `"platform": "linux"`. The page hides the app
list, onboarding, recommendations, and cache card, and the server answers the app
routes (`POST /api/<job>`, `/api/recommend`, `/api/icons/backfill`) with 501.

## Folders

XDG base directories, lower-case `disklessly`:

| What | Default | Override |
|---|---|---|
| State (config, session index, license, device id) | `${XDG_DATA_HOME:-~/.local/share}/disklessly` | `DISKLESSLY_STATE_DIR`, `--state-dir` |
| Cache | `${XDG_CACHE_HOME:-~/.cache}/disklessly` | `DISKLESSLY_CACHE_DIR` |
| Repo | `<state>/repo` (there is no iCloud Drive) | `init --root DIR`, `backend add`, `DISKLESSLY_REPO_PATH` |
| Secrets file | `${XDG_CONFIG_HOME:-~/.config}/disklessly/secrets.json` | `DISKLESSLY_SECRET_STORE` |

`init` creates the state, cache, and repo folders only. `init --backend icloud` is refused.

## Container images

`containers` looks for these local Unix sockets:

| Engine | Socket | Data |
|---|---|---|
| Docker Engine | `/var/run/docker.sock` | `/var/lib/docker` |
| rootless Docker | `$XDG_RUNTIME_DIR/docker.sock` | `${XDG_DATA_HOME:-~/.local/share}/docker` |
| Docker Desktop for Linux | `~/.docker/desktop/docker.sock` | `~/.docker/desktop/vms` |
| rootless Podman | `$XDG_RUNTIME_DIR/podman/podman.sock` | `${XDG_DATA_HOME:-~/.local/share}/containers` |
| rootful Podman | `/run/podman/podman.sock` | `/var/lib/containers` |

If `DOCKER_HOST` is `unix:///path/to/socket` and that socket is not already
listed, it is scanned as `Docker Engine (DOCKER_HOST)`. `tcp://` and `ssh://`
values are ignored because Disklessly only manages local images. Podman is
reached through its Docker-compatible API, so the `docker` CLI must be installed.
Restoring an image saved from a custom endpoint requires the same `DOCKER_HOST`
to be set.

When a data folder such as `/var/lib/docker` cannot be read (normally because it
is root-owned), Disklessly asks `docker system df` for the engine's size. If
that also fails, the size is shown as unavailable instead of `0 B`. If no
engine is found, the error names the sockets that were tried.

## Secrets

Backend passwords and the session encryption key go to:

1. The Secret Service (GNOME Keyring, KWallet) through `secret-tool`, in a desktop
   session: `secret-tool` on `PATH`, `DBUS_SESSION_BUS_ADDRESS` set, and `DISPLAY` or
   `WAYLAND_DISPLAY` set. SSH logins usually get a D-Bus address from pam_systemd but
   no display, and use the file. The secret is written to `secret-tool`'s stdin, never
   its arguments. A call that fails or does not answer in 15 s (a locked keyring)
   falls back to the file for the rest of the run.
2. Otherwise `secrets.json`, created 0600 in a 0700 folder and replaced atomically.

Reads check the Secret Service first and then the file, so a secret saved before
the keyring became reachable is still found. `DISKLESSLY_SECRET_STORE=file` or
`=secret-tool` forces one.

The session key does not sync anywhere on Linux (on macOS it is an iCloud Keychain
item). If you archive with `--encrypt`, back up the key: losing `secrets.json` (or the
keyring item `service io.github.s546126.disklessly.sessions`) means the encrypted
segments cannot be read back.

## Sessions

Same as macOS (`docs/sessions.md`). Open files are detected with `lsof`; when lsof is
missing, the `/proc/<pid>/fd` links of the user's processes are used instead, and if
neither works every file counts as open, so nothing is archived. Files changed in the
last 24 hours are never archived.

## Disk usage

The usage map on Linux measures the file system that holds `$HOME` (often its own
partition) and splits it into:

- **Apps**: `/opt/<name>`, Flatpak apps (`/var/lib/flatpak/app/<id>`,
  `~/.local/share/flatpak/app/<id>`), Snap packages (the `.snap` files in
  `/var/lib/snapd/snaps`; `/snap` itself is squashfs mounts and is not walked). Each
  app claims its data by name: `~/.var/app/<id>` for Flatpak, `~/snap/<name>` for Snap,
  `~/.cache/<name>`, `~/.local/share/<name>`, `~/.config/<name>` for `/opt`.
- **Disklessly**: the cache, state, and repo folders.
- **Personal files**: everything else directly in `~`.
- **App data**: what no app claimed in `~/.cache`, `~/.local`, `~/.config`, `~/.var`, `~/snap`.
- **System & other** is whatever the disk uses beyond that.

## Build and release

```bash
scripts/linux-test.sh          # swift build + swift test + scripts/linux-smoke.sh in swift:6.0
scripts/release-linux.sh       # dist/disklessly-<ver>-linux-<arch>.tar.gz
```

Both use Docker or Apple's `container`. The release builds in `swift:6.0-rhel-ubi9`
with the Swift runtime linked statically, so the binary needs only glibc ≥ 2.34,
libsqlite3, and libcurl and libxml2 (for FoundationNetworking/FoundationXML). Minimal
container images may lack the last two: `apt-get install libsqlite3-0 libcurl4 libxml2`. The tarball holds `bin/disklessly` and `share/disklessly/web` (the dashboard
page, found relative to the binary).

---

## Design note: offloading AppImage files

Not built. This is the plan for the first Linux app format to offload. Claims marked
*(unverified)* need checking on real distros before code depends on them.

### Why AppImage first

An AppImage is one executable file (an ELF runtime plus a squashfs image). Moving it
out and back is a file copy, with no package manager database to keep consistent.
Flatpak and Snap apps live in system-managed stores (ostree deploys, snapd revisions)
whose managers would see a removed app as broken; `.deb`/`.rpm` files are spread over
`/usr` and owned by dpkg/rpm. Those are out of scope.

### Finding candidates

- Folders: `~/Applications` (the AppImageLauncher and Gear Lever default), `~/.local/bin`,
  `~/Downloads`, and any folder in `$PATH` the user owns. A file is an AppImage when it
  has the ELF magic and the AppImage type-2 magic `AI\x02` at offset 8.
- Desktop integration: `~/.local/share/applications/*.desktop` whose `Exec=` points at
  the file (AppImageLauncher writes `appimagekit_<md5>-<name>.desktop`) *(unverified
  naming across AppImageLauncher versions)*.
- Idle time: atime is often `relatime`/`noatime`, so record our own last-launch time
  once the stub exists; before that, fall back to mtime and say so in `recommend`.

### Image format

No DMG and no new container: the repo stores the AppImage itself, content-addressed
like today's images (`images/<imageId>.AppImage`, sha256 in the manifest). It is
already a compressed squashfs, so recompressing gains little. The manifest gets
`format: "AppImage"`, the original path, the `.desktop` file it came with, and the icon.

### Stub

Replace the file at its original path with a small shell script of the same name,
mode 0755:

```sh
#!/bin/sh
# disklessly stub for <name>; the real AppImage is in the repo.
exec disklessly launch --image <imageId> -- "$@"
```

The `.desktop` file keeps its `Exec=` path, so menus and docks keep working. Icons
come from the AppImage's `.DirIcon` (extract with `--appimage-extract .DirIcon`, or read
the squashfs offset from `--appimage-offset` and unpack without running the payload)
and are saved next to the manifest, as `AppIcon` does on macOS.

### Launch

1. Fetch `images/<imageId>.AppImage` into the cache (resumable, verify sha256).
2. `chmod 0755` and `exec` it with the original arguments and `APPIMAGE`/`ARGV0` unset,
   so the runtime sets them for the cached path *(unverified that apps reading
   `$APPIMAGE` for self-update tolerate the cache path)*.
3. Keep the cached copy until the cache quota evicts it, like a mount-mode image.

AppImages need FUSE 2 (`libfuse.so.2`) to mount themselves. Newer distros ship only
FUSE 3, so check for it and fall back to `--appimage-extract-and-run` with a warning
*(unverified for static-runtime AppImages, which embed their own FUSE)*.

### Updates and conflicts

- Self-updating AppImages (AppImageUpdate, zsync) replace the file they were started
  from. Started from the cache, an update lands there and the repo copy goes stale.
  Detect a changed sha256 after the app exits and offer `resolve --keep-updated`, as
  macOS does for restore mode.
- If the original path holds a real AppImage again (the user downloaded a new one),
  the stub is gone: treat it like a foreign app and do not overwrite.

### Out of scope for the first version

Flatpak, Snap, distro packages, `/opt` folders, and system-wide `/usr/local` installs.
