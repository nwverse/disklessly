# Agent session tiering (v2)

`disklessly sessions` plans a hot/cold split for coding-agent transcripts (JSONL, and JSON for Gemini/Qwen chats). A run without `--apply` is a dry run: it prints the plan and does not upload or delete anything.

```sh
disklessly sessions [--apply] [--days N] [--home DIR] [--encrypt] [--exclude-from FILE|-]
disklessly sessions list [--state archived|remote|restored|keptLocal|pendingDelete|all] [--tool ID] [--limit N] [--digest]
disklessly sessions status [--check-segments]
disklessly sessions search QUERY [--limit N]
disklessly sessions restore ID|PATH [--to PATH]
disklessly sessions reindex
disklessly sessions migrate
disklessly sessions verify --legacy
disklessly sessions key init
disklessly sessions key status
```

`--encrypt` applies only to that run. It requires a key from `sessions key init`. `key status` prints the key id and never the key. A second `key init` is rejected. Unknown subcommands and options exit 2.

Errors keep the usual `--json` shape `{"ok":false,"error":{"code","name","message"}}` and exit codes (2 usage, 1 failure, 4 backend).

### Backend check

`sessions --apply`, `sessions restore` (when it has to download), and `sessions reindex` first stat the repo marker `repo.json` on the active backend, with a 10 s limit. When the backend cannot be opened, does not answer in time, or has no `repo.json` (for example a local-folder repo whose disk is not mounted, which opening the folder would otherwise recreate empty), the command exits 4 with a message starting `backend unreachable` and has not uploaded, deleted, or indexed anything. The dashboard's apply makes the same check. `sessions restore` opens the backend only when it has to download, and accepts a marker on any mirror (`mirrorBackendIds`), since its reads fail over to them; apply and reindex check the primary only.

A repo without `repo.json` that `init` will not mark, because it already holds manifests or images (or an iCloud placeholder or conflict copy of `repo.json`), counts as reachable. Any other folder without the marker, such as a repo that only ever held sessions and was never initialised, is refused with a hint to run `disklessly init`, which adds the marker.

### State directory and session home

The index, locks, digests, and text files live in `stateDir`. It is `--state-dir`, else `DISKLESSLY_STATE_DIR`, else `~/Library/Application Support/Disklessly` on macOS and, on Linux, `$XDG_DATA_HOME/disklessly`, else `<passwd home>/.local/share/disklessly`. On Linux the fallback uses the passwd home (`NSHomeDirectory()`), not `$HOME`: setting only `HOME` does not move the state directory. The built-in session roots and herdr's layout file, by contrast, follow `--home`, then config `sessionHome`, then `$HOME` (see What is cold). `sessions status` prints the `stateDir` it used. To run a test copy that cannot touch the real state, set `DISKLESSLY_STATE_DIR` (or pass `--state-dir`) as well as `HOME`.

### Excluding referenced sessions

`--exclude-from FILE` (or `-` for standard input) names sessions another tool still uses. Each line is an absolute transcript path or a session id: the Claude Code file stem, or the UUID at the end of a Codex `rollout-…-<uuid>.jsonl` (any other agent: the file stem). Blank lines and lines starting with `#` are ignored. A match is reported in `skipped` with reason `referenced` and is never uploaded or deleted. A session id or path also covers the files in the folder named for that session, so Claude Code's `<sessionId>/subagents/agent-*.jsonl` stay with their session. The list is read again right before each local delete (settle, including pending rows from an earlier run); a transcript that became referenced in between keeps its local file and gets state `keptLocal` with reason `referenced`. Standard input is read once.

Every archive path (the CLI `sessions --apply`, the dashboard's apply, and the settling of pending rows) also runs a built-in reference scan, with the same matching as `--exclude-from`:

- The current user's processes: on Linux `/proc/<pid>/cmdline` of processes owned by the current uid, on macOS `ps -axww -o args=`. Every UUID on a command line that contains `claude` or `codex` counts as a session id, and every absolute `.jsonl` path on any command line counts as a path.
- herdr's saved layout, `<home>/.config/herdr/session.json` (`<home>` as for the built-in roots): every UUID and every absolute `.jsonl` path in it.

The scan runs when the plan is made (a match is in `skipped` with reason `referenced`) and again right before each local delete, together with the `--exclude-from` list, so an agent resumed during a long upload keeps its file (`keptLocal`, `referenced`). When the process list cannot be read at all (no `/proc` and `ps` fails), the run still uploads, but no local file is deleted: those rows become `keptLocal` with reason `reference check failed` and are settled by a later run.

The `--apply` report adds `archived`, the transcripts this run removed locally after their archive was verified (including pendingDelete rows an earlier, interrupted run left behind), and `uploadedBytes`, the sum of their original sizes. A file uploaded but then kept local is in `keptLocal` and counts in neither:

```json
{"ok": true, "applied": true, "cold": ["…"], "skipped": [{"path": "…", "reason": "referenced"}],
 "keptLocal": [], "segments": ["sessions/<deviceId>/claude/work-demo-app/2024-11/20250101T000000Z-1a2b3c4d.tar.zst"],
 "uploadedBytes": 2048, "archived": [{"id": "0123456789ab", "path": "/home/me/.claude/projects/-work-demo-app/<uuid>.jsonl", "sessionId": "<uuid>", "bytes": 2048}]}
```

### List

`sessions list` reads the local index only (it never opens the backend). `--state` defaults to `all`; `--tool` keeps one agent; `--limit` keeps the first N; `--digest` adds each row's digest. Rows are ordered by transcript mtime, newest first:

```json
{"ok": true, "deviceId": "<uuid>", "entries": [{
  "id": "0123456789ab", "deviceId": "<uuid>", "local": true, "tool": "claude",
  "path": "/home/me/.claude/projects/-work-demo-app/<uuid>.jsonl", "sessionId": "<uuid>",
  "cwd": "/work/demo-app", "project": "work-demo-app", "month": "2024-11",
  "mtime": "2024-11-22T00:00:00Z", "archivedAt": "2025-01-01T00:00:00Z", "bytes": 2048,
  "state": "archived", "title": "add a health check endpoint", "firstPrompt": "add a health check endpoint",
  "segment": "sessions/<uuid>/claude/work-demo-app/2024-11/20250101T000000Z-1a2b3c4d.tar.zst", "encrypted": false}]}
```

`local` is whether the row's device is this machine. `title` is the agent's own title or the first prompt (one line, 80 characters); `firstPrompt` is the first prompt the user typed, skipping injected context, at most 500 characters, empty when unknown. `project` is the partition folder of the segment (see Layout), or the key the row's `cwd` would get for a segment in the flat layout. `month` is `yyyy-MM` of the mtime in UTC. `segment` is the repo-relative object (a v1 row shows its monthly tar.gz), empty when there is none.

### Status

`sessions status` always exits 0 when the local index opens, also with the backend down:

```json
{"ok": true, "deviceId": "<uuid>", "stateDir": "/home/me/.local/share/disklessly",
 "backend": {"id": "fakecloud", "type": "rclone", "reachable": true, "latencyMs": 120, "error": ""},
 "counts": {"archived": 12, "remote": 3, "restored": 1, "keptLocal": 0, "pendingDelete": 0},
 "archivedBytes": 1048576, "textDir": "/home/me/.local/share/disklessly/sessions/text", "textFiles": 12,
 "segments": {"total": 5, "checked": 5, "missing": [], "unchecked": [], "timedOut": false}}
```

`reachable` is the same `repo.json` check as above; `error` gives the reason when it is false. The check has no side effects: a local or iCloud repo whose folder is missing (a disk that is not mounted) is reported `reachable: false` and the folder is not created. `sessions --apply`, `restore`, `reindex`, and the dashboard open the repo the same way, so a missing folder is exit 4 there and is not recreated empty. `stateDir` is the absolute state directory in use. `archivedBytes` sums the sizes of rows in state `archived`. `segments.total` counts the objects referenced by `archived` and `remote` rows; with `--check-segments` and a reachable backend each one is stat'ed and the ones the backend says are absent are listed in `missing` (otherwise `checked` is 0). A stat that fails (timeout, 5xx, dropped connection) is not proof of absence: that path goes to `unchecked`. The whole check stops after 60 s; paths not reached by then are also `unchecked` and `timedOut` is true. `checked` counts the paths that answered. `textDir` is the absolute path of the plain-text session index (see below) and `textFiles` the number of `.jsonl` files in it.

## What is cold

Default roots (tool id, folder, files). The list follows the session locations that
[cass](https://github.com/Dicklesworthstone/coding_agent_session_search) reads, limited to
agents that write one append-only transcript file per session:

| Tool id | Agent | Folder | Files |
|---|---|---|---|
| `pi` | pi | `~/.pi/agent/sessions` | `**/*.jsonl` |
| `claude` | Claude Code | `~/.claude/projects` | `**/*.jsonl` (includes `<session>/subagents/`) |
| `claude` | Claude Code (Linux, XDG) | `~/.config/claude-code/projects` | `**/*.jsonl` |
| `codex` | Codex | `~/.codex/sessions`, `~/.codex/archived_sessions` | `**/*.jsonl` |
| `omp` | Oh My Pi | `~/.omp/agent/sessions` | `**/*.jsonl` |
| `gemini` | Gemini CLI | `~/.gemini/tmp` | `*/chats/*.json`, `*/chats/*.jsonl` |
| `factory` | Factory Droid | `~/.factory/sessions` | `**/*.jsonl` |
| `qwen` | Qwen Code | `~/.qwen/projects`; `~/.qwen/tmp` | `**/*.jsonl`; `*/chats/*.json` |
| `kimi` | Kimi Code | `~/.kimi/sessions`, `~/.kimi-code/sessions` | `**/*.jsonl` |
| `copilot` | Copilot CLI | `~/.copilot/session-state` | `**/*.jsonl` |
| `goose` | Goose (before 1.20) | `~/.local/share/goose/sessions`, `~/.goose/sessions` | `**/*.jsonl` |
| `grok` | Grok | `~/.grok/sessions` | `**/*.jsonl` |
| `vibe` | Mistral Vibe | `~/.vibe/logs/session` | `**/*.jsonl` |
| `kiro` | Kiro CLI | `~/.kiro/sessions/cli` | `**/*.jsonl` |
| `openclaw` | OpenClaw | `~/.openclaw/agents` | `*/sessions/**/*.jsonl` |
| `prime` | Prime | `~/.prime/agent/sessions` | `**/*.jsonl` |
| `cursor` | Cursor agent | `~/.cursor/projects` | `*/agent-transcripts/**/*.jsonl` |

Not tiered:

- Claude desktop `~/Library/Application Support/Claude/claude-code-sessions` and `local-agent-mode-sessions`. They hold
  JSON state that the app rewrites in place (title, model, turn counters; written through `*.json.tmp`) and
  plugin manifests. They are not transcripts; the transcript of a desktop Code session is the
  `~/.claude/projects` JSONL that `cliSessionId` names.
- OpenCode `storage/` (one JSON file per message part, not per session), and agents that keep sessions only
  in SQLite: OpenCode 1.2+, Goose 1.20+, Crush, Hermes, Devin, Shelley.
- Anything in a hidden folder or with a hidden name under a root (the scan skips dot entries).
- The rest of `~/.cursor` (mostly extensions).

Set `sessionRoots` in config to replace that list. Each root has `tool`, `directory`, `suffix`, and
optionally `suffixes` (extra suffixes, e.g. `[".jsonl", ".json"]`) and `requireComponent` (a folder
name that must appear between `directory` and the file, e.g. `chats`). Old configs with only `suffix`
still load. Otherwise the built-in roots are under `--home`, then config `sessionHome`, then `$HOME`. The passwd home is used only when `$HOME` is unset. `--apply` refuses when any discovered file resolves outside those roots. When roots overlap, the first root that lists a file owns it.

A file is cold only when it is a transcript (`.jsonl` or `.json`), it is not open, it was not modified in the last 24 hours, and it is older than `sessionColdDays` (default 14, `--days` overrides it). These names are never selected, whatever the root says: credentials and tokens (`.claude.json`, `.credentials.json`, `auth.json`, `config.toml`, and any name containing `auth`, `token`, `credential`, `secret`, `password`, or `apikey`), sidecars and state (`settings.json`, `*.settings.json`, `*.meta.json`, `config.json`, `state.json`, `manifest.json`, `sessions.json`, `models.json`), hidden names, and SQLite (`.sqlite`, `.db`, `state.vscdb`, `-wal`, `-shm`). Only files that are cold by name and age are passed to the open-file probe. Open files are detected with `lsof -Fn`. Paths are stored as `realpath`. On macOS that means `/private/var`, `/private/tmp`, and `/private/etc` rather than the `/var`, `/tmp`, or `/etc` alias.

## Per-agent plan

`DisklesslyEngine.sessionPlan(days:home:now:)` (and `SessionArchive.plan`) is the dry run the dashboard
shows before the user picks agents. It reads only the agents' folders: no index, lock, or repo is opened,
and nothing is written. It uses the same roots, scan, and cold rules as `--apply`; open files are asked
about in one batched `lsof` run per 200 paths. `jsonObject()`:

```json
{
  "days": 14, "protectHours": 24, "generatedAt": "2026-11-07T09:00:00Z",
  "totals": {"files": 410, "bytes": 762194203, "coldFiles": 217, "coldBytes": 108196188},
  "tools": [
    {"tool": "claude", "label": "Claude Code", "present": true,
     "roots": [{"directory": "/Users/me/.claude/projects", "suffixes": [".jsonl"], "requireComponent": "", "exists": true}],
     "files": 332, "bytes": 695402337, "coldFiles": 195, "coldBytes": 104733388,
     "hotFiles": 137, "hotBytes": 590668949, "openFiles": 0, "tooLargeFiles": 0, "tooLargeBytes": 0,
     "excludedFiles": 0, "oldest": "2026-10-18T07:39:30Z", "newest": "2026-11-07T08:56:25Z"}
  ]
}
```

Every configured tool is listed, also when its folder is missing (`present: false`, no `oldest`/`newest`).
`coldFiles` are the files `--apply` would archive now; files that are old enough but open count as
`openFiles`, and files over `sessionMaxFileBytes` as `tooLargeFiles`. `excludedFiles` are names under a
root that are not transcripts.

`DisklesslyEngine.sessionApply(tools:days:home:encrypt:now:)` archives only the selected tool ids
(`SessionArchive.tier(..., tools:)`). Nil means every root; an empty set or an id with no root is
exit 2. Pending rows from earlier runs are settled whatever the selection. The result is a
`SessionReport`, whose `jsonObject()` is what `disklessly sessions --apply` prints.

## Digest

When a session is archived, Disklessly also keeps a short text digest of it (no model, no network; the
same bytes always give the same digest). It has every user prompt and the last assistant text of each
turn, as `**User:** …` / `**Assistant:** …` paragraphs. Tool calls and results, reasoning, images,
`data:` URIs and long base64 runs, and injected text (`<system-reminder>`, `<environment_context>`,
AGENTS.md instructions, slash-command echoes, a message that is a single `<tag>…</tag>` block) are
dropped. One message is cut at 1,500 bytes; the whole digest at 8 KiB, keeping the head (3/5) and the
tail with `… [N bytes omitted] …` between. Cuts fall on Unicode scalar boundaries.

Extractors: Claude Code JSONL (`claude`), Codex rollouts (`codex`: `response_item` messages, else
`event_msg` user/agent messages), pi JSONL (`pi`, `omp`, `prime`, `factory`), Gemini/Qwen chat JSON
(`gemini`), and a generic one that reads `text`/`content` strings with a `role`/`type` of user or
assistant. A custom tool id is sniffed from the content.

The digest is stored in the index (`entries.digest`, also in the FTS table, so `sessions search` finds
words from it) and written as `stateDir/sessions/digests/<entryId>.md` with the tool, path, mtime, and
sha256. It is never uploaded and it never replaces the transcript: the segment holds the original
bytes, and `sessions restore` puts those back. A failed `.md` write does not stop the run.

## Plain-text index

Every transcript of this device that is archived also gets a plain-text file,
`stateDir/sessions/text/<entryId>.jsonl`, so other tools can search archived sessions with ordinary
file tools without the backend. `stateDir` is `DISKLESSLY_STATE_DIR` or `--state-dir`, by default
`~/Library/Application Support/Disklessly` on macOS and `$XDG_DATA_HOME/disklessly` (else
`~/.local/share/disklessly`) on Linux. The directory is mode 0700 and each file 0600; a file is written
to a temporary name, fsynced, and renamed into place. It is never uploaded.

The first line is a header:

```json
{"type":"disklessly-archive","version":1,"entryId":"<12 hex>","deviceId":"<uuid>","sessionId":"<id>",
 "tool":"claude","path":"/abs/original.jsonl","cwd":"/work/demo","title":"…","firstPrompt":"…",
 "mtime":"2024-11-22T00:00:00Z","archivedAt":"2025-01-01T00:00:00Z","bytes":1234,
 "segment":"sessions/<device>/claude/<project>/<yyyy-MM>/<…>.tar.zst"}
```

Each following line is one user or assistant message, in transcript order:
`{"type":"user"|"assistant","timestamp":"<RFC 3339 or empty>","text":"…"}`. The same extractors and
filters as the digest are used (tool calls and results, reasoning, images, `data:` URIs and long base64
runs, and injected blocks are dropped), but every message is kept: one message is cut at 32 KiB, and
when the message lines of a file (as written, JSON escaping included) pass 1 MiB, whole messages are
kept from the head (up to half) and the tail, with `{"type":"omitted","bytes":N}` between them, where
`N` is the message text left out. Cuts fall on Unicode scalar boundaries.

The file is written from the snapshot bytes before anything is uploaded (with `segment` and
`archivedAt` empty) and rewritten with them once the segment is committed, before the local delete. If
the first write fails, that transcript is skipped with reason `text index failed`: nothing is uploaded
for it and the local file stays. A file that already exists for the same entry id (same bytes) is not
rewritten before the upload, so its header keeps the segment of the stored copy. A `pendingDelete` row
left by an earlier run without a text file gets one from the local file (or from the
`.disklessly-deleting-*` copy an interrupted delete left) before the delete, or stays pending with
`text index failed`. `sessions restore` leaves the text file in place (a consumer sees the session is
back because the original path exists again). Rows of other devices (from `reindex`) have no text file.

At the end of every `sessions --apply`, also one that fails, the directory is tidied: there is one file
per session path of this device, the one of its newest index row (a row that is not `restored` wins
over a restored one). Files with no index row (the run failed or stopped after the first write), files
of an older version of a session that was restored, continued and archived again, and leftover temp
files are removed, and a kept file whose header still has no `segment` or `archivedAt` gets them from
its row.

## Layout

Each Mac has its own device id. One apply holds `stateDir/locks/sessions.lock`. Cold files are grouped by tool, project, and month, ordered by path, and packed into one or more segments:

- A file larger than `sessionSoloBytes` (default 8 MiB) is its own segment.
- Other files share a segment while the sum of their sizes stays under `sessionSegmentMaxBytes` (default 64 MiB).
- A file larger than `sessionMaxFileBytes` (default 512 MiB) is skipped as `too large to tier`.

The object path is:

```
sessions/<deviceId>/<tool>/<project>/<yyyy-MM>/<yyyyMMdd'T'HHmmss'Z'>-<sha8>.tar.zst[.enc]
sessions/<deviceId>/<tool>/<project>/<yyyy-MM>/<yyyyMMdd'T'HHmmss'Z'>-<sha8>.json[.enc]
```

`<project>` comes from the working directory the transcript records (Claude Code `cwd`, Codex `session_meta.payload.cwd`, pi's header `cwd`): a Claude-style slug where every character outside `[A-Za-z0-9]` becomes `-` and leading dashes are trimmed, at most 48 characters, followed by `-` and the first 8 hex characters of `sha256(cwd)` when it was cut. It is `_unknown` when the transcript names no working directory. For an encrypted segment it is `p-` and the first 12 hex characters of `sha256(cwd)`, so object names carry no plaintext path. `<yyyy-MM>` is the month of the transcript's mtime in UTC.

Segments written before this layout sit directly in `sessions/<deviceId>/<tool>/`. They stay where they are and are still read, restored, and reindexed.

`<sha8>` is the first eight hex characters of the stored object's SHA-256. The tar is ustar. Inside it, `index.json` lists members and omits the segment path, the stored sha256, and the stored size, because those depend on the bytes that contain the index. It records `project` and `month`, and each member has `cwd`, `title`, and `firstPrompt` next to `id`, `path`, `sha256`, `size`, `mtimeNs`, and `preview`. The sidecar JSON next to the segment adds `segment`, `sha256`, and `bytes` (an encrypted sidecar is sealed as a whole, so these fields are not readable without the key).

Members are `m/<entryId>.jsonl` (also for a `.json` transcript; the restore path comes from the index). `entryId` is the first 12 hex characters of `sha256(deviceId + "\n" + path + "\n" + sha256)`. Restoring a transcript and archiving the same bytes again gives the same id; the new segment's row replaces the old one.

Write-once rules for both the segment and the sidecar:

- Absent: put, then read back and require the same sha256.
- Same sha256: leave it.
- Different bytes: exit 5, `refusing to overwrite`.
- iCloud placeholder: exit 5.

`sessions/<tool>/<yyyy-MM>.tar.gz` from v1 is never written and never deleted by v2, including `gc`.

## Delete protocol

For each segment:

1. Snapshot the file (stat, read, stat again). A change skips it as `changed while reading`. Write the plain-text index from those bytes; a failure skips it as `text index failed`.
2. Upload the segment and sidecar.
3. Commit the segment and its entries in SQLite with state `pendingDelete`.
4. Only then consider deleting the local file.
5. Re-read the `--exclude-from` list and rerun the reference scan; a match sets state `keptLocal` and leaves the file (`referenced`), and a failed process listing does the same with `reference check failed`. Re-stat and hash. A size, inode, mtime, or sha256 change, or an open file, sets state `keptLocal` and leaves the file (`modified after archiving` or `open`).
6. Otherwise rename to `<path>.disklessly-deleting-<txid>`, re-stat, and unlink. State becomes `archived`.

A crash after the index commit is finished by the next `sessions --apply`: pending rows are settled before new files are packed. The local file is not removed if the upload or the index commit fails.

## Index

`stateDir/sessions/index.sqlite` is schema user_version 4 (`PRAGMA journal_mode=WAL`, `synchronous=FULL`, 5 s busy timeout). A database newer than version 4 is refused. Opening a version 2 index migrates it in one transaction: `entries` gets `digest TEXT NOT NULL DEFAULT ''`, and `entries_fts` is rebuilt as `(id, path, preview, digest)` from `entries` (FTS5 cannot add a column). Rows archived before that keep an empty digest. Opening a version 3 index (also right after the step from 2) adds `cwd TEXT NOT NULL DEFAULT ''` and `first_prompt TEXT NOT NULL DEFAULT ''` to `entries` in a second transaction; older rows keep them empty. Any open does this, including the dashboard's read of the archived list. Search uses FTS5 when the SQLite library has it, and `LIKE` over path, preview, and digest otherwise.

`sessions search` omits rows whose state is `restored`. Each hit has `id`, `tool`, `path`, `preview`, and `title`, plus `deviceId`, `state`, `mtime`, `bytes`, `cwd`, and `sessionId`. `sessions restore` writes the JSONL back to its canonical path and prints `{"ok": true, "path": …, "id": …, "sessionId": …}`. Another Mac's row requires `--to PATH` (exit 2 without it). An existing destination with different bytes is exit 9. A restore holds `stateDir/locks/sessions.lock` (exit 9 while an apply holds it) and checks the destination again when it puts the file in place: the file is published without replacing anything, so a file that appeared during the download is left alone and the restore fails with the same exit 9 error. pi and Codex keep the stored mtime; Claude's mtime is set to now. After a successful restore the row stays, with state `restored`. Because pi and Codex get their old mtime back, a restored transcript that has not changed is skipped by `--apply` (reason `restored`) until it has been back for `sessionColdDays` (by the file's status-change time, which the restore sets). When it is archived again, unchanged, it settles against the segment that already holds it: nothing is uploaded and no orphan object is left. A transcript kept local after upload (`referenced`, `open`) is settled the same way later. When a path was archived more than once (restored, changed, archived again), restore by path takes this machine's newest row that is not already restored; an entry id always names one row.

`sessions reindex` walks `sessions/<uuid>/` recursively and reads every sidecar, in the flat layout and in the partitioned one, and inserts rows this Mac does not already have. Those rows are `remote` when the device id is not this Mac. Their title, first prompt, and working directory come from the sidecar when it has them.

## Encryption

`sessionEncryption` in config is `off` (default) or `aes-gcm`. `--encrypt` forces AES-256-GCM for one run. The key lives in the secret store (Keychain on macOS) under service `io.github.s546126.disklessly.sessions`. Accounts are `segment-key-<keyId>` and `segment-key-current`. The key id is 8 hex characters of `sha256(key)`.

The envelope is magic `ISEGENC1`, key id, nonce, ciphertext, and tag. The segment's associated data is the relative path with the `-sha8` token removed (`…/<stamp>.tar.zst.enc`), because the hash cannot be inside the ciphertext it names. The sidecar's associated data is its full relative path. `sessions/<deviceId>/…` objects then contain no plaintext of the transcript or of the original path.

## Migration and legacy verify

`sessions migrate` (also the first search or apply) reads `sessions-index.json` if it is still present, inserts those rows with `legacy_archive` set and `segment_id` null, and renames the file to `sessions-index.json.migrated-v2`. It does not delete it and it does not delete the monthly tar.gz.

`sessions verify --legacy` downloads each legacy archive and runs `tar -tzf`. Missing members are reported. The command does not change row state and does not repair the archive. `verify` without `--legacy` is exit 2.

Restore of a legacy row still uses `tar -xzf` on `sessions/<tool>/<yyyy-MM>.tar.gz`.
