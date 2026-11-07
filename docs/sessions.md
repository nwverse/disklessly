# Agent session tiering (v2)

`disklessly sessions` plans a hot/cold split for coding-agent transcripts (JSONL, and JSON for Gemini/Qwen chats). A run without `--apply` is a dry run: it prints the plan and does not upload or delete anything.

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

Members are `m/<entryId>.jsonl` (also for a `.json` transcript; the restore path comes from the index). `entryId` is the first 12 hex characters of `sha256(deviceId + "\n" + path + "\n" + sha256)`.

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

`stateDir/sessions/index.sqlite` is schema user_version 3 (`PRAGMA journal_mode=WAL`, `synchronous=FULL`, 5 s busy timeout). A database newer than version 3 is refused. Opening a version 2 index migrates it in one transaction: `entries` gets `digest TEXT NOT NULL DEFAULT ''`, and `entries_fts` is rebuilt as `(id, path, preview, digest)` from `entries` (FTS5 cannot add a column). Rows archived before that keep an empty digest. Any open does this, including the dashboard's read of the archived list. Search uses FTS5 when the SQLite library has it, and `LIKE` over path, preview, and digest otherwise.

`sessions search` omits rows whose state is `restored`. `sessions restore` writes the JSONL back to its canonical path. Another Mac's row requires `--to PATH` (exit 2 without it). An existing destination with different bytes is exit 9. pi and Codex keep the stored mtime; Claude's mtime is set to now. After a successful restore the row stays, with state `restored`.

`sessions reindex` reads other devices' sidecars under `sessions/<uuid>/` and inserts rows this Mac does not already have. Those rows are `remote` when the device id is not this Mac.

## Encryption

`sessionEncryption` in config is `off` (default) or `aes-gcm`. `--encrypt` forces AES-256-GCM for one run. The key lives in the secret store (Keychain on macOS) under service `io.github.s546126.disklessly.sessions`. Accounts are `segment-key-<keyId>` and `segment-key-current`. The key id is 8 hex characters of `sha256(key)`.

The envelope is magic `ISEGENC1`, key id, nonce, ciphertext, and tag. The segment's associated data is the relative path with the `-sha8` token removed (`…/<stamp>.tar.zst.enc`), because the hash cannot be inside the ciphertext it names. The sidecar's associated data is its full relative path. `sessions/<deviceId>/…` objects then contain no plaintext of the transcript or of the original path.

## Migration and legacy verify

`sessions migrate` (also the first search or apply) reads `sessions-index.json` if it is still present, inserts those rows with `legacy_archive` set and `segment_id` null, and renames the file to `sessions-index.json.migrated-v2`. It does not delete it and it does not delete the monthly tar.gz.

`sessions verify --legacy` downloads each legacy archive and runs `tar -tzf`. Missing members are reported. The command does not change row state and does not repair the archive. `verify` without `--legacy` is exit 2.

Restore of a legacy row still uses `tar -xzf` on `sessions/<tool>/<yyyy-MM>.tar.gz`.
