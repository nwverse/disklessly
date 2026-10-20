# Fix plan 1 — stub argv contract + cache path contract (macOS E2E red on PR #2)

Status: diagnosis only (no code changed in this step). Branch `feat/mvp`, HEAD at diagnosis `0a21c4c`.

## 1. Symptoms & evidence

Every macOS E2E run on `feat/mvp` since `b28a030` failed. Grouped by first failing assertion:

| Runs (head) | First failure |
|---|---|
| 39409648927, 39409766011 (`b28a030`, `f451956`) | build error `ImageManifest.App has no member 'appPathInVolume'` (fixed by `1d298da`) |
| 39409905209 … 39411299054 (`1d298da` … `ef06d1b`) | `FAIL: CLI pack into fake repository and Applications` (codesign `--deep`, path `//` compare; fixed by `11b7b99`, `6d075ba`) |
| 39411681853, 39411687126 (`6d075ba`), 39412171255, 39412179689 (`800965f`), 39412524894, 39412530041 (`0a21c4c`) | **identical**: `Unknown command: --doc` → `FAIL: pre-launch fetched image to isolated cache` |

Key lines from the e2e log artifact (`macos-e2e-log`) of https://github.com/s546126/256isenough/actions/runs/39412530041:

```
PASS: remote disk image exists
isenough: Optional("Unknown command: --doc")
FAIL: pre-launch fetched image to isolated cache (missing: /var/folders/n6/.../isenough-e2e.cYNcpt/cache/images/io.github.s546126.256isenough.e2efixture-1.0-e50999b0.dmg)
```

The same pair occurs in runs 39412524894, 39412179689 and 39411687126 (see
https://github.com/s546126/256isenough/actions/runs/39412179689, …/39411687126). The "DMG missing from cache"
failure and the "Unknown command: --doc" failure are **not two alternating bugs**: they are one failure. The
error is printed by the CLI, and the cache assertion fails *because* launch (and therefore prefetch) never ran.
The step-level log only shows the `FAIL:` line (stderr of the stub goes to the log file), which is why fix rounds
alternated between "fix the stub argv" (`800965f`) and "fix the cache file" (`0a21c4c`). Neither touched the
real defect, so the output did not change at all between `6d075ba`, `800965f` and `0a21c4c`.

Note also `Optional("…")` in the message: `IsenoughError.errorDescription` is `String?` and is interpolated
unwrapped in `Sources/isenough/main.swift` (cosmetic, but misleading in logs).

## 2. Root cause(s)

### RC1 (primary, blocks everything): the "stub" executable is a copy of the CLI
`Engine.installStub` (Sources/IsenoughEngine/Engine.swift:101-103):
```swift
let executable=Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0])
let stubExecutable=temp.appendingPathComponent("Contents/MacOS/isenough-stub")
try FileManager.default.copyItem(at:executable,to:stubExecutable)
```
`installStub` runs inside the `isenough` CLI process, so `Bundle.main.executableURL` is
`.build/debug/isenough`. The generated `Fixture.app/Contents/MacOS/isenough-stub` **is the CLI binary**. The
e2e runs `"$STUB/Contents/MacOS/isenough-stub" --doc "$TMP/docs/open-me.txt"`, i.e. the CLI with argv
`["--doc", path]`. The CLI's global-flag loop (`main.swift:73-78`) breaks on the unknown `--doc`, then takes it
as the command → `default: throw .usage("Unknown command: --doc")`, exit 2. `Sources/isenough-stub/main.swift`
is never executed; commit `800965f` changed dead code. All e2e checks pass up to here because `codesign` and
`assert_file` only check that *some* executable named `isenough-stub` exists.

### RC2 (secondary): cache-miss assertion is a consequence, not a cause
`prefetch` writes `<cacheDir>/images/<manifest.imageId>.dmg`, exactly the path e2e asserts
(`$ISENOUGH_CACHE_DIR/images/$IMAGE_ID.dmg`). The path contract already matches; it was simply never reached.
`0a21c4c` (drop ULFO conversion) did not change the observable result.

### RC3 (latent, naming): remote image name ≠ imageId
`pack` names the remote file and manifest with a **UUID** suffix
(`id="\(bid)-\(version)-\(UUID…prefix(8))"`, Engine.swift:76) while `ImageManifest.imageId` is
`<bundleId>-<version>-<sha8>` (Core.swift:35). So `images/<bid>-1.0-<uuid8>.dmg` and
`manifests/<bid>-1.0-<uuid8>.json` contain a manifest whose `imageId` is `<bid>-1.0-<sha8>`. Design §3.1 says
`images/<bundleId>-<version>-<sha8>.dmg`. Fetch works (it reads `image.file`), but every name derived from the
file name (evict, gc, manifest lookup) disagrees with names derived from `imageId`.

### Next blockers once RC1 is fixed (will turn the run red again later in the same script)
- **B1 doc delivery**: `launch` runs `open -a <app> <docs…>`. Launch Services delivers documents as an `odoc`
  Apple event, not argv, and LS-launched apps do not inherit the caller's environment. The bash fixture
  (`printf '%s\n' "$@" > "${ISENOUGH_E2E_ARGV:?}"`) gets neither the env var nor the document → it exits, and
  `fixture process launched and recorded arguments` fails.
- **B2 no lifecycle state**: `launch` never writes `state.json`; `lastUsed` / `cached` assertions must fail.
- **B3 timing**: post-quit detach takes ≥ 2 s poll + 1 s delay + `hdiutil detach`; e2e checks after a fixed
  `sleep 3` → flaky. (A bounded poll is a wait, not a loosening.)
- **B4 cache install**: `moveItem(tmp → cache)` fails if a stale/corrupt file is already at the cache path;
  the error string uses `\\(…)` so it prints literally `\(cache.path)`.
- **B5 parser leniency**: `launch` silently ignores unknown options and a trailing `--doc` without value;
  this hid RC1-type mistakes. It must reject them with `EX_USAGE`.
- **B6 path canonicalisation**: `mktemp -d "${TMPDIR}/…"` yields `/var/folders/…/T//isenough-e2e.X` (double
  slash, `/var` → `/private/var` symlink). `hdiutil info` and `/sbin/mount` report the realpath
  `/private/var/folders/…/T/isenough-e2e.X/mounts/<imageId>`, so `grep -F "$MOUNT"` with the raw path can never
  match, even when attach works.
- **B7 volume layout**: `hdiutil create -srcfolder <X.app>` — whether the volume root holds `X.app` or its
  `Contents/` is not something we should depend on. `appPathInVolume` must be guaranteed by packing from a staging
  folder that *contains* `X.app` (design §4 `pack`: "via staging folder").

## 3. Exact interface contract

### 3.1 Binaries
| Binary | SwiftPM product | Installed where | Who writes it |
|---|---|---|---|
| CLI | `isenough` | `.build/<cfg>/isenough` (CI), `~/.local/bin/isenough` (user) | build |
| Launcher | `isenough-stub` | `.build/<cfg>/isenough-stub`; copied into `<Stub>.app/Contents/MacOS/isenough-stub` | `pack` / `installStub` |

`installStub` copies the **launcher** binary, never the running CLI. Launcher lookup order
(pure function `StubGenerator.locateLauncher(cliExecutable:environment:isExecutable:)`):
1. `$ISENOUGH_STUB_BINARY` if set (must exist, else `EX_USAGE`);
2. `<dirname(realpath(cli executable))>/isenough-stub` (SwiftPM side-by-side, Homebrew/`~/.local/bin` installs);
3. otherwise `EX_FAILURE "isenough-stub launcher binary not found next to <cli>"`.
Sanity: refuse (`EX_FAILURE`) if the resolved launcher realpath equals the CLI realpath.

### 3.2 Stub bundle resources
- `Contents/Resources/manifest.json` — the image manifest (existing; `bundleId`, `imageId`).
- `Contents/Resources/stub.json` (new, design §8.1):
  `{"schema":"stub/1","appId":"<bundleId>","imageId":"<imageId>","isenoughPath":"<realpath of CLI>","stubVersion":1}`.

CLI lookup in the stub (`StubArgv.resolveCLI`), first executable hit wins:
`$ISENOUGH_CLI` → `stub.json.isenoughPath` → each `$PATH` entry + `/isenough` → `~/.local/bin/isenough`,
`/usr/local/bin/isenough`, `/opt/homebrew/bin/isenough`. (LS-launched stubs get a minimal PATH, so `PATH` alone
is not sufficient in production; in CI both stub.json and PATH point to `.build/debug/isenough`.)

### 3.3 Stub → CLI argv (MVP, argv-based; the §8.3 control-fd protocol is a later milestone)
The stub execs the CLI directly via `Process`/`posix_spawn` with an argv **array** (no shell → no quoting or
escaping layer; spaces, quotes, `$`, unicode pass through byte-for-byte):
```
argv[0] = <cli path>
argv[1] = "launch"
argv[2] = <appId>                    # manifest bundleId, e.g. io.github.s546126.256isenough.e2efixture
then, in original order, one pair per item:
  "--doc" <absolute file path>
  "--url" <url string>
  "--arg" <opaque argument>          # forwarded to the real app via `open --args`
```
Example (e2e): stub invoked as `isenough-stub --doc "/private/var/…/docs/open me.txt"` execs
`["/…/.build/debug/isenough","launch","io.github.s546126.256isenough.e2efixture","--doc","/private/var/…/docs/open me.txt"]`.

Stub raw-argv classification (pure `StubArgv.build(appId:rawArguments:cwd:) throws -> [String]`):
- explicit `--doc X` / `--url X` / `--arg X` pairs pass through (missing value → stub exits 2 with message);
- `--` ends option parsing; everything after is classified like bare tokens;
- drop LS/AppKit noise: tokens starting with `-psn_`; `-NS*` / `-Apple*` flags together with their value;
- bare token with a URL scheme (`^[A-Za-z][A-Za-z0-9+.-]*:` and not starting with `/`) → `--url`
  (`file://` URLs are converted to their path and become `--doc`);
- any other bare token → `--doc <absolute path>` (relative paths resolved against cwd, standardized);
- documents vs URLs are therefore always disambiguated by the flag, never by the CLI guessing.
The stub never prepends its own flags before `launch`; global CLI flags are not used by the stub.
The stub waits for the CLI and exits with the CLI's exit status (0 on success).

### 3.4 CLI grammar that must accept it (`launch` / `restore`)
```
isenough [--json] [--config PATH] [--state-dir PATH] launch <app> [--doc PATH]... [--url URL]... [--arg ARG]... [--no-wait]
```
- `<app>` must be the first token after `launch`; a token starting with `--` there → `EX_USAGE "launch requires app"`.
- options may repeat and interleave; order of docs/urls is preserved.
- unknown option, or `--doc`/`--url`/`--arg` without value → `EX_USAGE` (exit 2) — no silent ignore.
- top level: unknown global flag (e.g. `--doc` as first token) → `EX_USAGE "Unknown option: --doc"`, not
  "Unknown command". Error text printed unwrapped (`e.errorDescription ?? "\(e)"`), no `Optional(…)`.
Implemented as a pure function `LaunchArguments.parse(_ args:[String]) throws -> LaunchArguments`
(`app`, `documents`, `urls`, `arguments`, `wait`) in IsenoughEngine so it is Linux-testable; the inverse
`LaunchArguments.argv` is used by the stub builder tests for round-trip.

Delivery to the real app (engine `launch`, macOS):
`/usr/bin/open -n -a <mnt>/<appPathInVolume> [<doc>…] [<url>…] [--args <arg>…]` — documents/URLs go through
Launch Services (`odoc`/`GURL`), not the app's argv. LS does **not** propagate the caller's environment.

### 3.5 Environment variables
| Var | Read by | Meaning |
|---|---|---|
| `ISENOUGH_REPO_PATH`, `ISENOUGH_CACHE_DIR`, `ISENOUGH_STATE_DIR`, `ISENOUGH_MOUNT_ROOT`, `ISENOUGH_STUB_DIR`, `ISENOUGH_CONFIG` | CLI (`RuntimeConfig.environment()`) | existing overrides (unchanged) |
| `ISENOUGH_DETACH_DELAY` | CLI | seconds between app quit and detach (e2e: 1) |
| `ISENOUGH_STUB_BINARY` (new) | CLI `pack` / `installStub` | explicit launcher binary to copy into stubs |
| `ISENOUGH_CLI` (new) | stub | explicit CLI path (highest priority) |
The stub passes its environment through unchanged (`Process` inherits it), so e2e's `ISENOUGH_*` reach the CLI.
The *real app* does not see them (LS launch) — see §4 e2e fixture.

### 3.6 Cache / repo layout and names (`<id>` = `ImageManifest.imageId` = `<bundleId>-<version>-<sha8>`)
`sha8` = first 8 hex chars of the sha256 of the published ULMO image. One id is used for every name:

| Item | Exact path | Writer | Readers |
|---|---|---|---|
| remote image | `<repo>/images/<id>.dmg` (= `manifest.image.file`, relative `images/<id>.dmg`) | `pack` | `prefetch`, e2e (`REMOTE_IMAGE` from `image.file`) |
| manifest | `<repo>/manifests/<id>.json` | `pack` | `list`/`find`, e2e |
| pack staging | `<cacheDir>/pack-<uuid>/src/<App>.app` + `<cacheDir>/pack-<uuid>/image.dmg` | `pack` (deleted on exit) | `pack` |
| partial download | `<cacheDir>/partial/<id>.dmg.part` | `prefetch` | `prefetch` (deleted on failure) |
| published cache image | `<cacheDir>/images/<id>.dmg`, byte-identical to remote (ULMO, sha == manifest) | `prefetch` (rename from `.part`) | `launch`/attach, `evict`, `pin`, e2e `CACHE_IMAGE` |
| mount point | `realpath(<mountRoot>)/<id>` (default mountRoot `<cacheDir>/mnt`) | `launch` (`hdiutil attach -mountpoint`) | `launch` (pgrep, detach), state, e2e `MOUNT` |
| real app in volume | `<mount>/<appPathInVolume>` (= original `<App>.app` name) | `pack` (staging layout) | `launch` |
| state | `<stateDir>/state.json`: `apps[<bundleId>] = {imageId, state, lastUsed, pinned, mountPoint?}` | `launch`, `pin` | `status`, e2e |
`pack` order: hdiutil create → sha256 → derive `<id>` → `put images/<id>.dmg` → `put manifests/<id>.json`
→ stub. MVP deviation from §5.2e (recorded): no ULFO conversion; cache keeps the verified ULMO bytes, which
is what the e2e sha assertion requires.

## 4. Files & precise changes

**Sources/IsenoughEngine/Engine.swift**
- `StubGenerator`: add `locateLauncher(cliExecutable:environment:isExecutable:) throws -> URL` (§3.1) and
  `stubInfo(manifest:cliPath:) -> [String:Any]` (stub.json). Replace `forwardArguments` identity with real logic
  or delete it (tests updated).
- New pure `LaunchArguments` (struct + `parse` + `argv`) per §3.4.
- `installStub`: copy `locateLauncher(...)` result (not `Bundle.main.executableURL`); write `stub.json`
  with `isenoughPath` = CLI realpath; after copy assert the copied file is not byte-identical to the CLI.
- `pack`: stage `<App>.app` into `pack-<uuid>/src/` (`ditto`), `hdiutil create -srcfolder src -format ULMO`
  to `pack-<uuid>/image.dmg`; compute sha; build manifest; name remote/manifest from `manifest.imageId`
  (removes UUID-based `id`, RC3).
- `prefetch`: stream to `partial/<id>.dmg.part`, verify size+sha256 of the part file (not via a second temp
  copy), `removeItem` existing invalid cache file, then rename; fix `\\(` interpolation (B4).
- `launch`: canonicalize `mountRoot` (`resolvingSymlinksInPath` after createDirectory); attach with
  `-plist` and record mount; open with `/usr/bin/open -n -a <app> docs… urls… [--args …]`; write state
  (`state:"running"`, `lastUsed`) before waiting, and after detach `state:"cached"`, `lastUsed`, no mountPoint
  (B2). Wait loop: `pgrep -f` with the canonical executable path. Detach failure → `state:"backoff"` + stderr
  message (no `try?` swallow).

**Sources/isenough/main.swift**
- Global-flag loop: unknown `--x` before the command → `EX_USAGE "Unknown option: --x"`.
- `launch`/`restore`: use `LaunchArguments.parse`; pass `arguments` through.
- Error printing: `e.errorDescription ?? String(describing:e)` (no `Optional(...)`).
- usage text: add `--arg`.

**Sources/isenough-stub/main.swift**
- Move argv building/CLI resolution into a small pure helper compiled into the stub (keep the stub
  dependency-free: put `StubArgv` in a new tiny target `IsenoughStubSupport` with no deps, used by both
  `isenough-stub` and the tests; Package.swift adds it). Stub: read manifest + stub.json, `StubArgv.build`,
  `StubArgv.resolveCLI`, exec, propagate exit status, log the exact argv to stderr on failure.

**Package.swift**: add target `IsenoughStubSupport`; `isenough-stub` depends on it; test target depends on it.

**scripts/e2e.sh** (assertions only tightened or made deterministic; none removed)
- Fixture app: replace the bash executable with a ~40-line AppKit Swift fixture compiled by `swiftc` in the
  script (`Tests/Fixtures/E2EApp/main.swift`). It implements `application(_:open:)` and
  `applicationDidFinishLaunching`, and appends argv + every opened URL path to the file named by Info.plist key
  `IsenoughE2EOutput` and writes its pid to `IsenoughE2EPidFile` (baked at fixture-creation time, because LS
  does not pass env, design §11 E2E). Wait for it with a bounded poll after receiving the first `odoc`.
- Canonicalize `TMP` right after `mktemp`: `TMP="$(cd "$TMP" && pwd -P)"` (removes `//` and `/var` symlink, B6).
- New assertion after pack: stub executable is the launcher, not the CLI:
  `cmp -s "$STUB/Contents/MacOS/isenough-stub" "$ROOT/.build/debug/isenough-stub"` and
  `! cmp -s … "$ROOT/.build/debug/isenough"`; `stub.json` exists with `isenoughPath`.
- New assertion: image naming — `IMAGE_FILE == "images/$IMAGE_ID.dmg"` and manifest file is `manifests/$IMAGE_ID.json`.
- Replace fixed `sleep 4` / `sleep 3` with `wait_for <timeout> <predicate>` (poll 0.2 s, timeout 60 s for
  fetch/attach/launch, 30 s for detach); on timeout fail with the same message plus `tail -20` of the log.
  Also fail fast if the stub process exits non-zero before the cache file appears (print its stderr).
- Mount check: `hdiutil info` output captured to its own file and grepped (not the whole log, which already
  contains `$MOUNT` from earlier commands → false positive); compare with canonical `MOUNT`.
- Assert `state.json` contains `"state" : "cached"` for the bundle id (not just the substring `cached`, which
  also matches the cache dir path `…/cache/…`).

**.github/workflows/macos-e2e.yml**
- On failure also `cat` the e2e log (bounded, `tail -200`) into the step output so the cause is visible
  without downloading the artifact; keep the artifact upload.
- `swift build` builds both products (already); e2e builds `-c debug` → `.build/debug/isenough-stub` exists.

## 5. Unit tests to add (Tests/IsenoughCoreTests, Linux-runnable via `docker run --rm -v "$PWD":/src -w /src swift:6.1 swift test`)
1. `testStubArgvBuildsLaunchCommand`: `StubArgv.build(appId:"com.a", raw:["--doc","/a b/c.txt"])` ==
   `["launch","com.a","--doc","/a b/c.txt"]` (first two tokens fixed, order preserved).
2. `testStubArgvClassifiesBareTokens`: `["/x.txt","https://h/p?q=1","file:///y%20z.txt","rel.txt","-psn_0_123",
   "-NSDocumentRevisionsDebugMode","YES"]` with cwd `/w` → docs `/x.txt`,`/y z.txt`,`/w/rel.txt`; url
   `https://h/p?q=1`; psn/NS noise dropped.
3. `testStubArgvRejectsDanglingFlag`: `["--doc"]` throws.
4. `testLaunchArgumentsRoundTrip`: for several inputs (spaces, quotes, `$`, unicode, leading `-` in a doc
   path after `--doc`) `LaunchArguments.parse(Array(StubArgv.build(...).dropFirst()))` reproduces documents,
   urls, arguments exactly.
5. `testLaunchArgumentsRejectsUnknownAndMissing`: `["app","--bogus"]`, `["app","--doc"]`, `["--doc","x"]`
   → `IsenoughError.usage`.
6. `testCLITopLevelUnknownOptionIsUsageError` (via the pure global-flag parser extracted from main.swift).
7. `testLocateLauncherPrefersEnvThenSibling`: injected `isExecutable` closure; env override wins; sibling of CLI
   realpath next; equal-to-CLI → throws; none → throws.
8. `testImageNamingUsesImageId`: manifest built from sha `"ab"*32` → `imageId == "<bid>-<ver>-abababab"`,
   `image.file == "images/\(imageId).dmg"`, and helpers `CachePaths(config).image(id)`, `.partial(id)`,
   `.mount(id)` return `<cache>/images/<id>.dmg`, `<cache>/partial/<id>.dmg.part`, `<mountRoot>/<id>`.
   (Requires `pack` to compute sha before building names — `ImageManifest.Image.file` set from `imageId`.)
9. `testPrefetchReplacesStaleCacheFile`: LocalFolderBackend fixture; pre-create a wrong-content cache file →
   prefetch succeeds, bytes equal remote; partial file removed.
10. `testPrefetchRejectsCorruptRemote`: append bytes to remote → `.integrity`, no cache file, no partial left.
Keep `testPrefetchCachesPublishedImageBytesWithoutReencoding`.

## 6. Verification plan
1. Local (Linux, Docker): `swift build` + `swift test` all green (stub/macOS code compiled out where `#if os`).
2. Push to `feat/mvp`; macOS E2E must pass **every** existing assertion in order, unchanged in meaning:
   build → init → pack+stub → stub executable exists → codesign verify → manifest → remote image →
   **pre-launch fetched image to isolated cache** → cached sha256 == remote → attached at expected mount point →
   mounted read-only → fixture launched and recorded arguments → document forwarded to real app → post-quit
   detach after delay → state persisted → `lastUsed` → state back to `cached` → second prefetch no re-fetch →
   pin + gc keeps pinned image → corrupt remote rejected → `PASS: all macOS end-to-end assertions completed`.
   Plus the new ones (§4): stub binary is the launcher; image/manifest names use `imageId`.
3. Nothing loosened: no assertion removed, no `|| true` added to assertions, fixed sleeps become bounded waits
   with explicit timeouts that still fail the run.
4. Regression guard for RC1: the e2e `cmp` check and unit test 7 fail if the CLI is ever copied as the stub again.

## F-B1 fix items (from sol review)

Review baseline: `4ee74a3`; verdict **NOT SATISFIED**. See `docs/fb1-review.md` for all twelve
phase layouts and current file:line evidence. This is missing implementation, not a one-line
replacement of an unconditional predicate. Suggested new files below do not yet exist.

1. **Implement durable restore WAL and a real mode branch.** In `Sources/IsenoughCore/RestoreJournal.swift`
   (new), model restore-in/out phases, transaction paths, stub/destination identity, owner pid+start,
   inspection/retention snapshot and terminal outcome/time. In
   `Sources/IsenoughEngine/RestoreTransaction.swift` (new), implement restore-in/out with same-volume
   staging, journal-before-effect, file/directory fsync and idempotent phase replay; journal rollback too.
   Change `IsenoughEngine.launch` in `Engine.swift` to dispatch on manifest mode instead of mounting every
   app. Do not advertise safe temporary restore while that branch is absent; refuse it explicitly until
   implemented. Add Linux temporary-directory/fake-platform tests proving restore mode invokes the
   transaction and detaches the extraction image before active, never the mount-session recovery path.

2. **Put layout validation inside a pure per-phase decision function.** Add
   `Sources/IsenoughCore/RestoreRecovery.swift`: `RestoreRecovery.decide(phase, layout, probe, ownerAlive)`.
   Accept both sides of each WAL mutation as enumerated in `docs/fb1-review.md`, including incomplete
   owned extraction, absent destination before install, parked vs installed stub, moved app, already
   disposed/retained app, and retired/partially closed cleanup. Verify recorded paths/parent custody,
   stub identities and source/destination roles; reject symlink/path escapes, duplicates, wrong bundles,
   unexplained missing copies or ambiguous layouts without moving/deleting evidence. No global
   active-layout prerequisite or manifest-cdhash prerequisite for watching a replacement. Explicitly
   recognize/rebuild missing or corrupt regenerable stubs without overwriting an unknown destination.
   Wire decisions to the new engine runner; add Linux table tests for every phase × owner alive/dead ×
   busy/unknown/held/clean × each valid pre/post layout and invalid layout. Assert no effect on rejection,
   live-owner no-op and no destination rename without the applicable clean-twice gate under L1.

3. **Implement single-owner recovery and restore-specific waiting.** Add an engine recovery coordinator
   (e.g. `Sources/IsenoughEngine/RecoveryCoordinator.swift`) using `FileLock` for L1 and pid+start checks.
   Under L1, re-read journal, elect only for a dead owner and publish journal owner before mirror;
   short-lived callers that must wait spawn/record one detached `hook watch` child before unlocking.
   Wire startup/launch/`gc` and `hook watch` in `Sources/isenough/main.swift`; keep status read-only.
   Validate installed pre-effect rollback separately from post-effect adoption, active delay/hooks,
   quiesced/inspected re-probe and appMoved-or-later staging usage. Busy/unknown/held must wait without
   destructive action; never require an attached image. Add Linux fake-clock/probe tests for clean-twice,
   owner change, new usage between phases and hook epochs, plus multiprocess two-adopter/dead-child tests.

4. **Preserve atomic updater replacements and make deletion independently safe.** Extend
   `ImageManifest.App` in `Sources/IsenoughCore/Core.swift` and pack in `Engine.swift` with cdhash and tree
   hash; add `BundleHasher` and injectable archive/identity verification. A changed inode or cdhash at
   the controlled destination with established stub/path custody must be watched conservatively, not
   rejected as moved and not treated as deletable merely because bundle id matches. Re-inspect before
   disposal; delete only after matching cdhash AND tree hash and proving a verified cached/uploaded
   source. Otherwise retain the bundle (including cross-volume fallback to preserved staging), journal
   its identity/location, then set `needsResolution`. Block launches until explicit resolution and
   diagnose truly ambiguous layouts with a concrete repair path, not a generic success from `doctor`.
   Add Linux fake-verifier tests for atomic inode+signature replacement followed by owner death,
   tree-only hook mutation, corrupt/missing archive, repeated retain replay and tampered path identity;
   assert no updated/only copy is lost.

5. **Make `retired`/`closed` and mirror reconciliation durable and idempotent.** Extend `StateStore` and
   the restore runner: one L3 write removes `state.restored[appId]`, assigns terminal outcome, resolution
   snapshot, app/cache LRU time where appropriate and final app state. Persist journaled values so
   replay does not invent a later outcome/time; fsync before closing. Close only after durable retirement,
   never remove retained staging evidence. Reconcile a missing-journal mirror only with the verified
   installed stub and no staging; otherwise block/diagnose. Ensure launch/status/evict/unpack/resolve
   consume the same restored/journal/resolution truth. Linux tests must cover before/after retirement
   state write, state-write-to-journal-removal window, partially removed staging, absent journal mirror
   variants and at least three repeated recoveries with identical final state and no repeated hooks.

6. **Add the full Linux fault matrix, not just decision-table assertions.** Add
   `Tests/IsenoughCoreTests/RestoreRecoveryTests.swift` and `RestoreTransactionTests.swift` using fake
   signing/probe/archive adapters and real temporary directories or a fake FS. Inject
   `beforeJournal`, `afterJournal`, `afterMutation` for every restore-in/out phase, abandon the runner
   without automatic cleanup, reopen durable artifacts, recover and recover again. Include each rename,
   partial extraction, disposition/retention move and deletion, retirement and close boundary. Assert
   recognized clean layouts finish, exactly one stub/real bundle occupies destination, every original or
   updated bundle remains accounted for or has independently verified archive evidence, restored mirror
   is retired, outcome assigned once, journal closed and subsequent recovery a no-op. Non-clean usage
   must remain recoverably waiting; ambiguous layouts must remain unchanged with actionable diagnostics.
   Run with official `swift:6.1` Docker `swift test` on Linux (isolated scratch path, `--rm`).

7. **Implement and run the real macOS gates exclusively in GitHub Actions.** Extend `scripts/e2e.sh`
   (or a dedicated restore harness invoked by `.github/workflows/macos-e2e.yml`) with a restore fixture
   and test-hook build. A33 must kill a child at every journal-write/rename/state-retirement boundary on
   APFS and run repeated recovery. A33b must kill the installed/active owner with app/helper alive,
   start two recovery callers, verify one watcher/journal owner, no early swap, then one post-quit hook
   execution and eventual stub restoration/retirement/closure. Use the explicitly parked stub for join
   assertions, not the destination real app. A34d must replace the destination with a genuinely signed
   updated bundle, kill the supervisor, then prove adoption while busy, retention when clean, durable
   `needsResolution` and refusal to launch until resolution. Test missing/corrupt-stub regeneration.
   Keep a clean release build separate from fault-enabled builds. Preserve all existing E2E assertions;
   do not equate mount-only E2E success with F-B1 closure. Attach bounded logs/artifacts and require
   passing macOS runs before declaring F-B1 satisfied. Never run against a remote/personal Mac.

## CI round 1 — diagnosis

Run 39445816989 (HEAD `7e7ad60`), log `/tmp/ci-logs/39445816989.log`.

### Evidence
- Build + unit tests green; E2E: `PASS fixture packed and stub generated`, `PASS stub executable exists`,
  `FAIL stub contains launcher binary` (scripts/e2e.sh:75, `cmp -s <stub>/Contents/MacOS/isenough-stub
  .build/debug/isenough-stub`). `pack` itself exited 0, so `locateLauncher` found and copied a launcher
  (it refuses the CLI path) and `codesign --verify --strict` inside `installStub` passed.
- `installStub` (Engine.swift ~l.115-121) copies the launcher, then runs
  `codesign --force --sign - <temp>.app`.

### Root cause
The RC1 fix is correct; the new e2e assertion is unsatisfiable. Signing a bundle *always* signs its main
executable (`CFBundleExecutable` = `isenough-stub`): the bundle's code signature is the LC_CODE_SIGNATURE blob
embedded in that Mach-O (with Info.plist + CodeResources hashes bound into it, identifier = bundle id).
`--force` replaces the linker ad-hoc signature, so the copied file is byte-different from
`.build/debug/isenough-stub` by construction. The Engine comment "Sign only the outer app bundle" is wrong
in the same way (there is no outer-only signature). Byte equality was never a valid contract.

### Exact changes
1. **scripts/e2e.sh** (replace l.75-76; assertion is made correct, not removed): compare code, not the
   signature. Helper `code_text() { /usr/bin/otool -t "$1" | tail -n +2; }` (`__TEXT,__text` is untouched
   by codesign; skip line 1 = file path). Assert
   `cmp -s <(code_text "$STUB/Contents/MacOS/isenough-stub") <(code_text "$ROOT/.build/debug/isenough-stub")`
   → `stub contains launcher binary`, and the same `cmp` against `.build/debug/isenough` must FAIL →
   `stub is not CLI binary`.
   On failure, append `otool -t | head -5` of both files and `codesign -dvvv "$STUB"` to `$LOG` and print
   `tail -20 $LOG` so the next red run is self-explanatory.
2. **Sources/IsenoughEngine/Engine.swift `installStub`**: fix the comment only ("signing the bundle
   re-signs the main executable `isenough-stub` in place; no --deep needed because there are no nested
   code items"). Keep the post-copy "not byte-identical to the CLI" guard but run it **before** codesign
   (compare the copied file vs CLI file right after `copyItem`), since after signing it is trivially true.
3. No Linux-testable change; no unit test changes required.

### Contract amendment (§3.1 / e2e list)
"Stub executable is the launcher" := the `__TEXT,__text` contents (`otool -t`) of
`<Stub>.app/Contents/MacOS/isenough-stub` equal those of the built `isenough-stub` and differ from the
built `isenough`. The stub executable bytes are expected to differ from the build product because `pack`
ad-hoc re-signs the generated bundle (G5 is about the *real* app, which stays byte-identical in the image).
