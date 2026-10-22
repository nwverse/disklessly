# Agent instructions for 256isenough

- NAMING (binding user decision): the project/CLI name is `isenough` (product: 256isenough). The name "wupan" was REJECTED — never use `wupan`/`Wupan`/`WUPAN` anywhere (CLI, Swift modules, targets, env vars, paths, bundle ids, headers, docs, tests).
  - CLI: `isenough` (e.g. `isenough serve`, `isenough pack`); stub launcher: `isenough-stub`; Swift modules: `Isenough*` (IsenoughCore, IsenoughEngine, IsenoughMac, IsenoughServer); env vars: `ISENOUGH_*`.
  - Paths: `~/Library/Application Support/256isenough/`, `~/Library/Caches/256isenough/`; bundle id prefix `io.github.s546126.256isenough`.
- docs/design.md is the spec; docs/research-cursor.md corrections are authoritative over docs/research.md.
