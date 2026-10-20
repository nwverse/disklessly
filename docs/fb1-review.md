# F-B1 implementation review

## Verdict: NOT SATISFIED

Reviewed `feat/mvp` at `4ee74a3` (before this documentation commit). Scope: F-B1 / R3-B4 and the
final check in `docs/design-review.md:694–766`; restore adoption and WAL contracts in
`docs/design.md` §§5.6.4b, 5.8.1–3, 5.8.6 and acceptance tests A33/A33b/A34d.
The final review's phase-aware requirement overrides the unconditional active-layout precondition
still printed in §5.6.4b. This is an implementation review, not approval of that stale precondition.

**The restore transaction/recovery implementation is absent**, rather than merely using the wrong
layout predicate. There is no `RestoreRecovery.decide`, restore journal model/runner, restore-in/out
phase dispatcher, durable restored-session mirror, or restore fault-injection test. Fixing CLI/stub
argument forwarding or the cache miss cannot establish F-B1 closure.

### Implementation evidence (line numbers at reviewed HEAD)

- `Sources/IsenoughCore/Core.swift:14–42`: manifest supports `mode: restore`, but its app metadata
  has neither bundle cdhash nor tree hash. Image SHA-256 is not a bundle custody/deletion check.
- `Sources/IsenoughEngine/Engine.swift:68–87`: `pack` chooses/persists mode; this does not implement
  restore execution. `launch` at **155–166 never dispatches on mode**: it prefetches, attaches an image,
  opens the mounted app, polls `pgrep`, then attempts detach. No temporary bundle swap or recovery runs.
- `Sources/isenough/main.swift:48–51`: `restore` is an alias for that same `engine.launch`.
  `gc` at **54** just emits success; `doctor` at **55** has no layout diagnosis/repair;
  `resolve` at **60** is unsupported. No CLI recovery entry point exists.
- `Sources/IsenoughEngine/Engine.swift:35–40`: `StateStore` is generic JSON atomic writing, not a
  journal or L3-locked, fsynced terminal transaction. `initialize` at **61–67** does not replay journals.
- `Sources/IsenoughEngine/Engine.swift:90–134`: `installStub` moves original/temp/backup bundles
  during **pack**, with in-process error rollback, not restore WAL or process-death recovery.
- `Sources/IsenoughCore/Core.swift:53–72,91–107`: generic mount-like lifecycle and a lock primitive
  do not supply restore phases, owner election, or recovery. The engine does not use that lock.

## Per-phase layout, validation, action and coverage

Notation: `D` = controlled destination; `S` = same-volume transaction staging directory;
`T` = identified stub; `N` = `S/app.new`; `O` = `S/app.old`; `R` = recorded retained bundle.
`A` = restored real bundle (possibly updated); `∅` = absent. Unmentioned staging bundle roles
must be absent, not silently ignored. Paths, parent custody, bundle roles and identities must be
validated before any operation; bundle id alone cannot authorize deleting a real bundle.
Each WAL phase permits **both the pre-effect and post-effect layout** because journaling precedes
mutation. A copy can also be incomplete. The expected layouts below are requirements, **not observed
behavior**. “Missing [E]” in the code-check column refers to the actual launch path at
`Sources/IsenoughEngine/Engine.swift:155–166`, which has no phase/layout check at all.
“All absent [T]” refers to the full current test suite and E2E evidence detailed below.

| Phase | Expected accepted layout (pre-effect → post-effect) | Code check (file:line) | Required rollback / forward action (actual: none) | Test |
|---|---|---|---|---|
| `prepared` | `D=T`; `S` absent → empty transaction-owned `S`; no parked stub/real app | Missing [E] | Roll back owned staging; preserve destination stub; terminal `rolledBack`/close | All absent [T] |
| `extracted` | `D=T`, `S` present, `N` absent → incomplete extraction or verified `N=A`; no `S/stub.app`/`O` | Missing [E] | Roll back uninstalled extraction; only remove data established as our extraction, not an unexplained bundle; preserve `T` | All absent [T] |
| `stubParked` | `D=T`, verified `N=A`, parked stub absent → `D=∅`, `S/stub.app=T`, `N=A` | Missing [E] | Pre-effect: leave stub; post-effect: rename identified parked stub back, dispose owned extraction, retire rollback | All absent [T] |
| `installed` | `D=∅`, `N=A`, parked `T` → `D=A`, `N=∅`, parked `T` | Missing [E] | Pre-effect: safely roll back uninstalled layout. Post-effect: busy/unknown/held → promote/adopt active and watch; clean twice → journaled restore-out with `rolledBack` | All absent [T] |
| `active` | `D=A`, parked `T`, `N/O` absent; journal owner/identities published before restored-state mirror; mirror may lag. Atomic updater replacement may change `A` inode/cdhash | Missing [E] | Elect owner, conservatively watch replacement; clean twice plus delay/hooks → restore-out; do not demand original manifest cdhash before watching | All absent [T] |
| `quiesced` | `D=A`, parked `T`; no bundle move; clean observation may have become stale | Missing [E] | Re-probe clean twice; busy/unknown/held → active/waiting without rename; clean → inspection | All absent [T] |
| `inspected` | Same bundle positions; changed/hash snapshot absent/stale → durable inspection snapshot | Missing [E] | Re-probe and recompute cdhash + tree hash; record changed/custody, then proceed only if clean | All absent [T] |
| `appMoved` | `D=A`, `O=∅`, parked `T` → `D=∅`, `O=A`, parked `T` | Missing [E] | Validate which side of rename exists; pre-effect requires clean destination; post-effect probe staging, wait if non-clean; continue forward, no unconditional `D=A` check | All absent [T] |
| `stubBack` | `D=∅`, `O=A`, parked `T` → `D=T`, `O=A`, parked stub absent | Missing [E] | Validate source/destination stub identity; restore or recognize installed stub; regenerate missing/corrupt stub safely from manifest; probe `O` before disposal | All absent [T] |
| `disposed` | `D=T`, parked stub absent, `O=A` → `O=∅`; unchanged copy deleted only with matching hashes and archive evidence, otherwise `R=A` (or preserved staging) with durable resolution snapshot | Missing [E] | Re-probe staging before destructive action; recognize pre/post deletion or retention; never delete an update based on bundle id or stale hash alone | All absent [T] |
| `retired` | `D=T`; `O` absent or explicitly retained in staging; changed bundle preserved at recorded location. Restored mirror/outcome before state write → atomically retired state after write; journal still exists | Missing [E]; state writer only `Engine.swift:35–40` | Assign terminal fields idempotently under L3, remove restored mirror, publish resolution/outcome/LRU as applicable; then close, no active-layout prerequisite | All absent [T] |
| `closed` | Terminal stub/retention layout; `S` may exist → removed (except retained evidence); journal exists → removed only after durable retirement | Missing [E] | Finish safe leftover cleanup, never remove retained evidence; repeated recovery is a no-op | All absent [T] |

The action column is the required behavior; **none of these actions or checks currently executes**.
In particular, `prepared`/`extracted` require a destination stub, `stubParked`/`installed` can have an
empty destination, and restore-out ends with a destination stub and no parked stub. An active-layout
check before dispatch would reject valid crashes in those phases even once a runner is introduced.

## Test evidence and gaps

**[T] No per-phase coverage exists.** `Tests/IsenoughCoreTests/CoreTests.swift:5–56` contains eight
unit tests: manifest round-trip/format, LRU/pins, two generic lifecycle assertions, local backend,
prefetch bytes, stub plist/argument passthrough, path comparison and single-lock acquire/release.
None constructs a restore-mode session, journal, partial layout, replacement bundle or owner death.
The lock test at lines 52–55 does not exercise competing adopters or even two contenders.

`scripts/e2e.sh:70` packs the plain fixture without `--mode restore`; lines 87–116 exercise a
mount-based launch/quit path. The script contains no restore WAL fault loop, journal-write/rename
boundary assertions, restored-state retirement, updated-bundle retention or recovery idempotence.
`.github/workflows/macos-e2e.yml` builds, runs that unit suite and invokes that script; it does not
supply a separate A33/A33b/A34d implementation. Thus even a green current E2E would not prove F-B1.

Linux verification performed with the available official Swift 6.1 image:

```sh
docker run --rm --network none -v "$PWD":/src:ro -w /src swift:6.1 \
  swift test --scratch-path /tmp/isenough-fb1-build
```

Result: **8 XCTest tests passed, 0 failures** (Swift Testing separately reports 0 tests).
Full log: `/tmp/ci-logs/fb1-swift-test.log`. Read-only source mount and container-local scratch build;
container automatically removed. No macOS command, remote Mac access or CI run was performed for
this review; the supplied failing CI run is context, not independent restore test evidence.

### Blocking gaps

1. **No restore execution or WAL recovery.** All twelve phases lack actual checks/actions; `restore`
   silently follows mount launch. Open journals cannot be replayed by startup, launch or `gc`.
2. **No phase-aware custody validation.** Need pre/post-effect variants including incomplete extraction,
   missing destination, installed-vs-parked stub and disposed/retired layouts, with unknown/mismatched
   layouts blocked without data loss and an explicit diagnostic/repair path.
3. **No safe replacement adoption/disposal.** Need to watch an atomic update at the controlled destination
   without requiring the old inode/cdhash, then preserve it unless independently proven archived and
   byte-identical; store durable retention and `needsResolution` evidence.
4. **No synchronized adoption/usage gate.** Need L1 election, pid+start ownership and journal-first handoff,
   restore-mode destination/staging probe, non-clean waiting and current-owner clean-twice authorization.
5. **No terminal replay or boundary tests.** Need idempotent `retired`/`closed`, mirror reconciliation,
   Linux fault-matrix coverage and real APFS/macOS acceptance evidence for A33/A33b/A34d.

Concrete numbered implementation/test work is appended to `docs/fix-plan-1.md` under
“F-B1 fix items (from sol review)”. F-B1 remains blocking for safe temporary restore; this review
makes no changes to executable code and does not claim any phase is implemented.
