# Offloading large files and folders

Disklessly moves any large file or folder into the repo, not only apps, and leaves a small placeholder in its place.

## Commands

```sh
disklessly files [--min-size 500M] [--min-idle-days 30] [--limit 40]   # what is worth offloading
disklessly offload ~/Downloads/movie.mov "~/Documents/Old Project"     # move into the repo
disklessly fetch ~/Downloads/movie.mov.disklessly                       # bring it back
```

The dashboard lists the same items under **Worth offloading → Large files and folders** and gives each one an
**Offload now** button. You can bring an item back in three ways: double-click its placeholder, right-click it in Finder and
choose **Services → Bring back with Disklessly**, or run `disklessly fetch`. Right-click any file or folder and choose
**Services → Offload with Disklessly** to offload it from Finder.

## What happens

1. **Checks.** Disklessly refuses:
   - anything outside the home folder, and `~/Library`, `~/Applications`, `~/.Trash` and `~/Public`;
   - the standard folders themselves (`~/Downloads`), though what is inside them is allowed;
   - app bundles and anything inside one (use `pack` for apps);
   - photo and music libraries, VM bundles and disks (`.utm`, `.vmwarevm`, `.pvm`, `.vmdk`, `.qcow2`, …) and sparse images;
   - symbolic links, existing placeholders, and anything that holds Disklessly's own repo, cache or state;
   - items in iCloud Drive (iCloud already offloads them, and deleting one deletes it on every device).

   A file that any process has open (`lsof`), or a folder with an open file inside (`lsof +D`), is refused with exit 9.
2. **Free limit.** Offloaded files and folders count toward the free limit together with offloaded apps. See below.
3. **Object.** A file is uploaded as it is. A folder is archived into the cache with `tar`, compressed with zstd as it
   streams, and uploaded as one `.tar.zst`. The repo path is content-addressed: `files/objects/<sha256>.bin` or
   `files/objects/<sha256>.tar.zst`. The object is published write-once, so an existing object with other bytes is
   never overwritten.
4. **Verify.** The repo copy is hashed again: in place for a file-backed repo (local folder, iCloud, SMB/NFS), or after
   one download into the cache for WebDAV and OpenList, so that needs the stored size free there. The original is
   deleted only when that hash matches. Before deleting, Disklessly checks again that the original did not change (size, mtime and inode; for a
   folder, the tree) and that nothing opened it during the upload.
5. **Placeholder.** `Name.ext.disklessly` is a small JSON file (`schema: file/1`) with:
   - the id, kind, name and logical size;
   - the object path, its sha256 and stored size;
   - the repo id, the original path, the mtime and permissions.

   It gets the Finder tag `Disklessly`. It is written before the original is removed. The original is first renamed
   aside (`.Name.disklessly-removing-…`) and then deleted. If the delete stops halfway, for example on a locked file,
   the placeholder stays, because the repo copy is complete, and Disklessly reports the leftover. If Disklessly crashes
   between writing the placeholder and the rename, both are left. For a file, `fetch` then keeps the original once
   it matches the hash. For a folder, `fetch` refuses with "already exists"; delete the placeholder yourself.
6. **Registry.** `<stateDir>/files/offloaded.json` lists the placeholders on this Mac. It is used for counting. The
   placeholder itself is the source of truth, so a placeholder copied to another Mac that uses the same repo can be
   fetched there.

`fetch` downloads into a hidden staging file next to the placeholder, which checks the size and sha256, and refuses
if the free space would drop below the floor. A folder is extracted into a fresh staging folder. tar runs without
`-P`, so absolute paths and `..` entries are refused. Disklessly then checks that the archive held exactly that one
folder and renames it into place. It never replaces an existing item of the same name. A placeholder that names
another repo is refused.

## Space

- If the repo is a local folder on the same disk, offloading frees no space. Disklessly says so.
- If the repo is in iCloud Drive, Disklessly asks iCloud to evict its local copy of the object after the upload. If
  iCloud has not finished uploading, run `disklessly evict-local` later.
- Archiving a folder temporarily needs about its size free in the cache folder, above `DISKLESSLY_MIN_FREE_BYTES`.

## Recommendations

The large-file scan walks the home folder in the background (`POST /api/files/scan`, `GET /api/files`). It has a
timeout and keeps what it found. It lists files of at least 500 MiB whose last use is older than 30 days. The last use
is the newest of Spotlight's `kMDItemLastUsedDate`, the mtime and the atime, so a file some tool rewrote yesterday is
not idle. It also lists whole folders, at least two levels down (`~/Documents/Old Project`), when they are that large
and nothing in them was changed or read in that time. Then nothing inside such a folder is listed separately.

The scan skips:

- `~/Library` (app data such as Apple `container` images, Docker, caches and Mail), `~/Applications`, `~/.Trash`;
- hidden items. A folder that holds a hidden folder is never listed whole;
- source checkouts (`.git`, `.hg`, `.svn`);
- package-manager and build folders (`node_modules`, `Pods`, `DerivedData`, `.build`, `target`, `venv`, `vendor`, …);
- iCloud items and `.icloud` placeholders, other volumes and symlinks;
- the Disklessly repo, cache and state;
- app bundles, photo and music libraries, VM bundles and disks, partial downloads;
- files that are open, such as a running VM's disk.

## Free limit

Offloaded files and folders count toward the free limit together with apps: **2 items at once**, apps and files
combined. The decision was to count them. A free version that offloads unlimited files would make the app limit
meaningless, because the largest savings are often files. A placeholder you delete no longer counts. Bringing files
back is always free.

## Not yet

- **Extended attributes of single files.** Finder tags and comments on a file do not survive the round trip,
  because the file is stored as plain bytes. A folder keeps them, because tar stores them.
- **Encryption.** Image encryption has not landed. File objects are stored as they are, so a repo on a shared server
  can read them. When image encryption lands, file objects should use the same key and AES-GCM framing (`codec`
  gains an encrypted variant and the placeholder schema stays `file/1` with a new field).
- **Repo cleanup.** Fetching does not delete the repo object, which keeps it write-once and lets another Mac's
  placeholder still work. `gc` does not collect unreferenced `files/objects` yet.

## Finder integration: Services now, Finder Sync later

The right-click entries are **NSServices** declared in `Info.plist` and handled by the menu-bar app
(`offloadFiles:` and `fetchFiles:` in `AppDelegate`). The `.disklessly` type is exported as
`io.github.s546126.disklessly.placeholder`, and Disklessly.app is its owner, so a double-click opens it and brings
the file back.

Services need no extension, no extra signing and no separate process. The cost is that macOS files them under
**Services**, or **Quick Actions** on newer systems. macOS also registers them only once the app sits in
`/Applications` and has been launched once. Some systems show them only after you turn them on in **System Settings →
Keyboard → Keyboard Shortcuts → Services → Files and Folders**.

A **Finder Sync extension** would be the better long-term choice:

- top-level context-menu items (no Services submenu);
- badges on placeholders;
- a toolbar button;
- offload and fetch without the app being frontmost.

It needs a sandboxed app extension target, an Xcode project or a hand-assembled `.appex` with its own entitlements,
and an app group to talk to the menu-bar app. The repo has none of these yet. Revisit it when the app moves to an
Xcode project.
