# Agent instructions for Disklessly

- NAMING (binding user decision, supersedes the earlier `isenough` name): the product and CLI are **Disklessly** / `disklessly`; subtitle "256G is enough". The name "wupan" was REJECTED — never use `wupan`/`Wupan`/`WUPAN` anywhere (CLI, Swift modules, targets, env vars, paths, bundle ids, headers, docs, tests). Do not reintroduce `isenough` except in the legacy-compat code that recognizes old installs.
  - CLI: `disklessly` (e.g. `disklessly pack`, `disklessly ui`), short alias `dkl`; stub launcher: `disklessly-stub`; Swift modules: `Disklessly*` (DisklesslyCore, DisklesslyEngine, DisklesslyMac, DisklesslySessions, DisklesslyStubSupport); env vars: `DISKLESSLY_*`.
  - Paths: `~/Library/Application Support/Disklessly/`, `~/Library/Caches/Disklessly/`; bundle id prefix `io.github.s546126.disklessly`; Homebrew cask `disklessly`, formula `disklessly-cli`.
  - Legacy (pre-rename) installs used `isenough` / `256isenough` (paths, `.isenough-original-` backups, `ISENOUGH_*`). Keep recognizing and migrating them; never write new data under the old names.
- docs/design.md is the spec; docs/research-cursor.md corrections are authoritative over docs/research.md.
