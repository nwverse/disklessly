# Agent session tiering

`isenough sessions` plans a hot/cold split for agent JSONL transcripts. The first run, and every run without `--apply`, is a dry run: it prints the plan and does not upload or delete anything.

```sh
isenough sessions                 # dry run
isenough sessions --apply         # pack cold files and remove the local copies
isenough sessions --days 14       # untouched for this many days (default 14)
isenough sessions search blender
isenough sessions restore <id|path>
```

Default roots:

- pi: `~/.pi/agent/sessions/**/*.jsonl`
- Claude Code: `~/.claude/projects/**/*.jsonl`
- Codex: `~/.codex/sessions/**/*.jsonl`

Set `sessionRoots` in config to replace that list (`tool`, `directory`, `suffix`). A file is cold only when it is a `.jsonl`, it is not open, it was not modified in the last 24 hours, and it is older than `sessionColdDays`. Credentials, SQLite, `state.vscdb`, `-wal`, and `-shm` files are never selected. Open files are detected with `lsof -Fn` (a machine record `n<path>`). A translated lsof sentence is not a match.

Cold files for the same tool and UTC month are packed into `sessions/<tool>/<yyyy-MM>.tar.gz` on the active backend (gzip tar; image creation is unrelated and still uses `hdiutil create`). The upload is hashed before the local file is removed. The searchable index is `sessions-index.json` in the state directory. Restore writes the JSONL back to its original path. pi and Codex keep the stored mtime; Claude's mtime is set to now so a cleanup sweep does not delete it immediately.
