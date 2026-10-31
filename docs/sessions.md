# Agent session tiering (v2)

`disklessly sessions` plans a hot/cold split for agent JSONL transcripts. A run without `--apply` is a dry run: it prints the plan and does not upload or delete anything.

```sh
disklessly sessions [--apply] [--days N] [--home DIR] [--encrypt]
disklessly sessions search QUERY [--limit N]
disklessly sessions restore ID|PATH [--to PATH]
disklessly sessions reindex
disklessly sessions migrate
disklessly sessions verify --legacy
disklessly sessions key init
disklessly sessions key status
```

`--encrypt` applies only to that run. It requires a key from `sessions key init`. `key status` prints the key id and never the key. A second `key init` is rejected. Unknown subcommands and options exit 2.

## What is cold

Default roots:

- pi: `~/.pi/agent/sessions/**/*.jsonl`
- Claude Code: `~/.claude/projects/**/*.jsonl`
- Codex: `~/.codex/sessions/**/*.jsonl`

Set `sessionRoots` in config to replace that list (`tool`, `directory`, `suffix`). Otherwise the built-in roots are under `--home`, then config `sessionHome`, then `$HOME`. The passwd home is used only when `$HOME` is unset. `--apply` refuses when any discovered file resolves outside those roots.

A file is cold only when it is a `.jsonl`, it is not open, it was not modified in the last 24 hours, and it is older than `sessionColdDays` (default 14, `--days` overrides it). Credentials, SQLite, `state.vscdb`, `-wal`, and `-shm` files are never selected. Open files are detected with `lsof -Fn`. Paths are stored as `realpath`. On macOS that means `/private/var`, `/private/tmp`, and `/private/etc` rather than the `/var`, `/tmp`, or `/etc` alias.

## Layout

Each Mac has its own device id. One apply holds `stateDir/locks/sessions.lock`. Cold files are grouped by tool, ordered by path, and packed into one or more segments:

- A file larger than `sessionSoloBytes` (default 8 MiB) is its own segment.
- Other files share a segment while the sum of their sizes stays under `sessionSegmentMaxBytes` (default 64 MiB).
- A file larger than `sessionMaxFileBytes` (default 512 MiB) is skipped as `too large to tier`.

The object path is:

```
sessions/<deviceId>/<tool>/<yyyyMMdd'T'HHmmss'Z'>-<sha8>.tar.zst
sessions/<deviceId>/<tool>/<yyyyMMdd'T'HHmmss'Z'>-<sha8>.json
```

`<sha8>` is the first eight hex characters of the stored object's SHA-256. The tar is ustar. Inside it, `index.json` lists members and omits the segment path, the stored sha256, and the stored size, because those depend on the bytes that contain the index. The sidecar JSON next to the segment adds `segment`, `sha256`, and `bytes`.

Members are `m/<entryId>.jsonl`. `entryId` is the first 12 hex characters of `sha256(deviceId + "\n" + path + "\n" + sha256)`.

Write-once rules for both the segment and the sidecar:

- Absent: put, then read back and require the same sha256.
- Same sha256: leave it.
- Different bytes: exit 5, `refusing to overwrite`.
- iCloud placeholder: exit 5.

`sessions/<tool>/<yyyy-MM>.tar.gz` from v1 is never written and never deleted by v2, including `gc`.

## Delete protocol

For each segment:

1. Snapshot the file (stat, read, stat again). A change skips it as `changed while reading`.
2. Upload the segment and sidecar.
3. Commit the segment and its entries in SQLite with state `pendingDelete`.
4. Only then consider deleting the local file.
5. Re-stat and hash. A size, inode, mtime, or sha256 change, or an open file, sets state `keptLocal` and leaves the file (`modified after archiving` or `open`).
6. Otherwise rename to `<path>.disklessly-deleting-<txid>`, re-stat, and unlink. State becomes `archived`.

A crash after the index commit is finished by the next `sessions --apply`: pending rows are settled before new files are packed. The local file is not removed if the upload or the index commit fails.

## Index

`stateDir/sessions/index.sqlite` is schema user_version 2 (`PRAGMA journal_mode=WAL`, `synchronous=FULL`). A database newer than version 2 is refused. Search uses FTS5 when the SQLite library has it, and `LIKE` otherwise.

`sessions search` omits rows whose state is `restored`. `sessions restore` writes the JSONL back to its canonical path. Another Mac's row requires `--to PATH` (exit 2 without it). An existing destination with different bytes is exit 9. pi and Codex keep the stored mtime; Claude's mtime is set to now. After a successful restore the row stays, with state `restored`.

`sessions reindex` reads other devices' sidecars under `sessions/<uuid>/` and inserts rows this Mac does not already have. Those rows are `remote` when the device id is not this Mac.

## Encryption

`sessionEncryption` in config is `off` (default) or `aes-gcm`. `--encrypt` forces AES-256-GCM for one run. The key lives in the secret store (Keychain on macOS) under service `io.github.s546126.disklessly.sessions`. Accounts are `segment-key-<keyId>` and `segment-key-current`. The key id is 8 hex characters of `sha256(key)`.

The envelope is magic `ISEGENC1`, key id, nonce, ciphertext, and tag. The segment's associated data is the relative path with the `-sha8` token removed (`…/<stamp>.tar.zst.enc`), because the hash cannot be inside the ciphertext it names. The sidecar's associated data is its full relative path. `sessions/<deviceId>/…` objects then contain no plaintext of the transcript or of the original path.

## Migration and legacy verify

`sessions migrate` (also the first search or apply) reads `sessions-index.json` if it is still present, inserts those rows with `legacy_archive` set and `segment_id` null, and renames the file to `sessions-index.json.migrated-v2`. It does not delete it and it does not delete the monthly tar.gz.

`sessions verify --legacy` downloads each legacy archive and runs `tar -tzf`. Missing members are reported. The command does not change row state and does not repair the archive. `verify` without `--legacy` is exit 2.

Restore of a legacy row still uses `tar -xzf` on `sessions/<tool>/<yyyy-MM>.tar.gz`.
