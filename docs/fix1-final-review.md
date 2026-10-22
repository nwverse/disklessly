# Fix1 final review

Reviewed `0a21c4c..f7358f7ed371bf2010eaab699e1b09921c355be2` against
`docs/fix-plan-1.md`, including its CI contract amendments.
Scope: RC1–RC3, argv/cache interfaces and assertion preservation only.
F-B1 remains deferred and is not assessed here.

**Overall: RC1–RC3 PASS; full interface-contract sign-off NOT SATISFIED.**

| Item | Verdict | Evidence |
| --- | --- | --- |
| 1. RC1: real launcher installed | PASS | `installStub` copies `locateLauncher` output, rejects CLI identity before signing, and writes `stub.json`. E2E compares signed executable code sections against launcher and CLI (appropriate codesign amendment). |
| 2. RC2: cache path and launch use | PASS | `prefetch` publishes verified bytes at `<cache>/images/<imageId>.dmg` through `<cache>/partial/<imageId>.dmg.part`; launch attaches the returned URL. E2E verifies this path, hash and read-only mount. |
| 3. RC3: content-derived remote names | PASS | Pack hashes the DMG first, derives `imageId` from bundle/version/sha8, then publishes `images/<imageId>.dmg` and `manifests/<imageId>.json`; E2E checks both names. |
| 4. Consistent interfaces and Linux tests | PARTIAL / FAIL | Main E2E argv and cache paths agree across stub, CLI, engine and harness; Linux tests pass. Edge-case contract violations and missing planned regressions remain below. |
| 5. Assertion preservation | PASS | No E2E assertion removed, skipped or weakened. Bounded waits replace sleeps; mount and state checks are stronger. The obsolete identity-forwarding unit assertion is replaced by real stub-builder/parser assertions, not loss of forwarding coverage. No deferred skips were needed. |
| 6. Rejected-name absence | QUALIFIED | Tracked-tree case-insensitive scan finds only the pre-existing prohibition in `AGENTS.md:3`; no implementation, test or other documentation occurrences. Literal zero occurrences is therefore not met; no new occurrence was introduced. |

## Interface findings

- **P2 — `--` does not fully end option/noise parsing.**
  `Sources/IsenoughStubSupport/StubArgv.swift:13–14` drops LS-noise-shaped
  filenames even after the separator. Linux reproduction:
  `build(appId:"com.a", rawArguments:["--","-NSnotes.txt","keep.txt"], cwd:/w)`
  returns only `["launch","com.a"]`, instead of two document pairs.
  Gate noise filtering on option parsing and add a regression test (§3.3).
- **P2 — file URLs are decoded twice.** `StubArgv.swift:17` applies
  `removingPercentEncoding` to `URL.path`, which is already decoded.
  Linux reproduction: `file:///w/a%2520b.txt` becomes `/w/a b.txt`, not
  `/w/a%20b.txt`. Forward `URL.path` without decoding again and test literal
  percent escapes (§3.3; wrong-file delivery).
- **P2 — invalid explicit launcher override silently falls back.**
  `Sources/IsenoughEngine/Engine.swift:62–63` searches both candidates for an
  executable. With an invalid `ISENOUGH_STUB_BINARY` and a valid sibling it
  succeeds; §3.1 requires a usage error for the invalid explicit override.
  Validate the override separately and test fallback/self-identity explicitly.

The planned top-level usage-parser, CLI resolution precedence, sha8 naming,
stale-cache replacement and corrupt-remote cleanup unit cases are also absent
or incomplete (§5). Existing cache-byte/path and argv tests are useful but do
not cover these findings. This is not an F-B1 issue.

## Verification

- GitHub Actions [39449847781](https://github.com/s546126/256isenough/actions/runs/39449847781):
  confirmed success at reviewed HEAD; all macOS E2E assertions completed.
- Official `swift:6.1`, Linux aarch64: `swift test` with read-only source mount
  and container-local scratch path: **14 tests, 0 failures**. Container removed.
- `bash -n scripts/e2e.sh`: pass. No implementation/test files changed by review.
- Logs retained under `/tmp/ci-logs/`; no Mac accessed outside GitHub Actions.
