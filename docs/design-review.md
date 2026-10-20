# Design review

Reviews of `docs/design.md`; findings apply to the reviewed revision, not to implemented behavior.

## Round 1 — reviewer (gpt-6.1-sol)

**Verdict: CHANGES REQUESTED.** Reviewed `81e0317` on `feat/mvp`, including all of
`research.md`, `research-luna.md`, `research-cursor.md`, and `design.md`. No previous review file existed.
This is a document review on Linux; no macOS runtime claims were experimentally verified.

### Authoritative corrections checklist

1. **FileManager, not brctl:** satisfied (§7.2). Materialization/upload requests are correctly asynchronous.
2. **No dataless attach:** satisfied in the normal fetch path (§5.2/§7.2): materialize, independently copy,
   hash, convert, then attach only the cache image. Keep the final dataless recheck.
3. **No zero-copy iCloud clone assumption:** satisfied (§6); independent streamed copy is explicit.
4. **ULMO remote; ULFO/uncompressed local:** defaults and conversion justification are correct, but advertised
   overrides reintroduce incompatible choices; see B1.
5. **Playpen lifecycle precedent; real document/URL forwarding:** correctly attributed and uses AppKit/
   NSWorkspace rather than argv-as-documents. Delivery/lifetime races remain; see B4–B5.
6. **Pake tray/window + localhost HTTP + GPL:** correctly acknowledged (§2/§10/§14), not described as a native
   Dock-less menu-bar extra. The actual authentication/bootstrap contract is incomplete; see B6.
7. **Session roadmap starts with closed pi JSONL; excludes credentials/SQLite:** satisfied (§13); not MVP.

### Blocking issues

1. **B1 — Mandatory compatibility/format decisions can be bypassed** (§1.5 rule 4, §4 `pack`, §5.2.3e).
   `pack --mode mount` overrides the MAS receipt rule, although the authoritative correction requires MAS
   restore rather than trying a custom read-only DMG. The spec also advertises remote `--format ULFO` and local
   `ULMO`, conflicting with this task's ULMO-remote / ULFO-or-uncompressed-local decision.
   **Required:** make MAS→restore a hard classifier constraint (unsupported system/driver classes remain hard
   refusals), and constrain MVP remote/local formats to the binding choices. Remove contradictory CLI/config
   options or explicitly defer them. Add negative classifier/config tests proving these cannot be overridden.

2. **B2 — Restore swaps are not crash-safe and can discard the only updated app** (§5.2.4, §5.4.8, §8.1, §9).
   The restore record is written *after* parking the stub and installing the real app. A crash between these
   operations leaves no journal telling recovery where either bundle belongs. The parked stub is under the
   home directory while the original may be on another volume, so an atomic rename cannot be assumed.
   Post-quit moves the app to staging and says to delete staging before the parenthetical update decision;
   merely verifying the archived image's hash does not prove that the restored/updated bundle is archived.
   A pre-launch hook failure only specifies detach, leaving an already-restored installation unreverted.
   **Required:** specify a durable write-ahead swap journal, phase ordering, fsync/atomic publication rules,
   same-volume staging, and idempotent rollback/recovery at every boundary (also final pack installation).
   Inspect changes *before* destructive cleanup; retain changed/unrecognized bundles until explicit resolution
   and successful archival. Define the noninteractive supervisor's behavior when a decision is needed.
   Require fault-injection tests after every rename/journal write, hook failure, and self-update.

3. **B3 — Locks do not serialize all cache/session owners or reserve shared capacity** (§5.6/§6/§9).
   Only launch/post-quit lock ownership is specified. `prefetch`, `evict`, `gc`, `unpack`, pack/rebuild and recovery
   can race a launch between its cached-file check and attach, or concurrently write the same `.part`/conversion
   output. A short `state.lock` does not prevent filesystem TOCTOU races. Different-app downloads both pass the
   same free-space check without reservations. Multiple recovery callers can adopt one dead supervisor's mount.
   Post-quit holds an app lock while invoking global gc, creating lock-order problems if gc acquires other app locks.
   **Required:** give a lock/reservation table covering every mutating command and recovery, a deadlock-free order,
   one adopter elected under the relevant lock, active fetch/conversion protection, and an atomic capacity
   reservation mechanism. Do not run cross-app gc while holding an app lock if gc needs app locks. Add real
   multiprocess tests for launch versus evict/prefetch/gc, double adoption, and simultaneous different-app fetches.

4. **B4 — Lifetime/ownership rules are only complete for an ordinary mounted-path app** (§5.2–§5.4/§9/§10).
   Restore detaches the image before launch, yet the watcher probes the mountpoint; the only restored-path check
   is deferred to final cleanup and does not define helper/open-file handling or a retry state. Deleting a restored
   app while its helper still runs is not protected by `hdiutil`'s busy-unmount check. Likewise, quarantined apps
   are explicitly allowed and may translocate, while the watcher assumes executable paths stay under our mount.
   NSWorkspace can also reuse an existing instance: returned PID does not by itself prove it runs our intended
   bundle (notably with a kept original or a second installed copy).
   **Required:** define mode-specific usage roots, verify the returned running app's actual bundle/executable
   identity, track helpers and open files, and treat failed/incomplete process inspection as unknown/busy.
   Either reject translocatable apps in MVP with a safe recovery instruction, or track their actual launch path
   and backing-image dependencies. Restore cleanup must wait/retry rather than delete a live installation.
   Test a surviving helper, a process holding only a data file, reused wrong-path instance, and quarantine behavior.

5. **B5 — The stub can exit before acknowledging all events; progress can kill its supervisor** (§8.3/§5.6).
   Later Apple Events are queued for a second supervisor call, but the first `ready` immediately terminates the
   stub. There is no outstanding-request count, delivery acknowledgement, or drain-before-exit rule, so documents/
   URLs received during a long fetch can be lost. With a live session, the forwarding supervisor also opens the
   app without synchronously updating the owner's detach timer/lease; polling is not a handoff protocol. Finally,
   closing a pipe is not *inherently* harmless: a later supervisor write can raise SIGPIPE unless handled.
   **Required:** specify request IDs, per-batch acknowledgement/error handling, queue draining before stub exit,
   and synchronized lease/timer handoff under the app lock. Handle EPIPE/SIGPIPE explicitly and stop progress
   writes after client disconnect. Cancellation must not kill the existing session when cancelling a forwarding
   waiter. Test documents/URLs arriving before, during, and just after `ready`, relaunch at detach deadline, and
   closing/killing the stub while the app continues running.

6. **B6 — Pake UI cannot authenticate using the specified protocol** (§2.1/§10/§12.1).
   Every API call requires a Bearer token, but the page bootstrap only stores it in an **HttpOnly** cookie and
   removes it from the URL. Page JS cannot read that cookie to construct Authorization headers, and native
   EventSource cannot set Bearer headers. The Pake recipe loads `/ui/` without any token and defines no first-run
   pairing or launcher that supplies one. Thus a normally launched GUI has no working authenticated API/SSE path.
   **Required:** choose and document one end-to-end scheme (e.g. cookie-authenticated UI/SSE with strict Host/
   Origin/CSRF checks, Bearer for CLI), including initial pairing/bootstrap, restart/rotation, and unauthenticated
   responses. Do not assume a browser-shell can read the daemon's token file. Define valid Host values separately
   from serialized Origins, and test authorization, cross-origin rejection, SSE and actual Pake startup.

7. **B7 — The acceptance plan can pass without testing required behavior and contains impossible assertions**
   (§11.3–§11.4). Falling back from LS to CLI/direct execution and marking A11/A12 skipped removes the only proof
   of real document/URL Apple Event handling; argv forwarding is not equivalent. Restore is optional despite being
   an MVP compatibility/safety requirement. A16 requires exit status `0` even though NSWorkspace/NOTE_EXIT need not
   supply a non-child application's exit status (the spec itself permits `unknown`). The LRU scenario gives only
   app2 ~150 MB of random padding; an unpadded tiny fixture app1 plus app2 is not guaranteed to exceed 200 MB,
   especially when allocated bytes are measured. A20 neither states a consistent expected outcome when pins
   consume the quota nor asserts the planner's documented `EX_NOSPACE` behavior. The retained original can also
   let LS select a non-mounted bundle, masking lifecycle errors unless explicitly excluded/checked.
   **Required:** make stub LS document/URL delivery and restore swap/recovery required macOS acceptance gates;
   environmental unavailability may fail/mark the job inconclusive, not yield a green substitute. Align exit-status
   expectations with observable API guarantees; construct quota fixtures from measured allocated sizes and assert
   one deterministic pin/space outcome. Include the races/faults above and preserved-original launch selection.
   Keep `scripts/e2e.sh` portable, isolated, and inspectable, with diagnostic artifacts collected before cleanup.

### Non-blocking suggestions

- **N1 — MVP scope:** the design has the required architectural sections and suitable Swift/macOS abstraction
  seams, but a hand-written HTTP server, shared executable hooks, remote gc, trust management, a progress UI and
  two installation modes are a large first release. Stage implementation behind explicit gates: safe local
  mount lifecycle; safe restore; iCloud materialization/upload; then authenticated Pake management. Defer remote
  gc/shared hooks/multi-Mac UX rather than weaken local safety or forwarding requirements.
- **N2 — Backend consistency:** the five-operation abstraction is a good starting point for NAS/OpenList, but
  `atomicPut` is both optional and promised unconditionally by `put`. Before phase 2, define publication on
  non-atomic stores, object/ETag validation for resumed ranges, full-response (`200` versus `206`) handling,
  credential stripping on direct-link redirects, and repository symlink containment. An 8-hex hash prefix is
  not a uniqueness guarantee; collision should extend the name or fail safely, never overwrite.
- **N3 — Peak disk accounting:** explicitly budget iCloud materialization + independent ULMO copy + ULFO output
  (or UDRO's uncompressed size), and pack staging/original-in-Trash. A 1.35 conversion multiplier is an estimate,
  not a bound. Add bounded conversion/ENOSPC cleanup and report that moving an original to Trash does **not**
  release its local space. Do not promise reclaimed bytes before those bytes are actually released.
- **N4 — macOS claims:** do not assert disk images always detach on logout; recovery must reconcile either
  outcome. `lsof -Fp -- <mnt>` should be documented/tested as a filesystem selector, not called `+D` recursion.
  Treat missing permission/failed probes as unknown. Verify attach device ownership before adopting/reusing an
  externally mounted copy; never detach someone else's image merely because its backing path is in our cache.
- **N5 — Signing/TCC/permissions:** preserving the real signature and explicitly not stripping quarantine is
  correct; do not promise universal TCC preservation or that `hdiutil attach` performs Gatekeeper assessment.
  Preflight parent-directory/bundle permissions for `/Applications` and MAS removal. Without a privileged helper,
  refuse a non-writable installation before changing anything; document Finder/user-mediated steps separately.
  Align stub `LSMinimumSystemVersion` (12.0) with the SwiftPM deployment target (13+).
- **N6 — Data/command consistency:** align the MVP command inventory with required `trust` approval behavior;
  persist trusted identity and operation-journal fields in schemas, not just prose. Define plist-to-JSON handling
  for non-JSON plist values, schema migrations, manifest caching for offline launch, and a way to regenerate icons
  from an image on a new Mac. Document hook document/URL arrays as JSON rather than newline-separated strings
  (valid file names can contain newlines). A plain JSON state database is otherwise reasonable at this scale.
- **N7 — Launch Services/GPL:** `lsregister` is an undocumented best-effort aid, not a guarantee that defaults or
  Dock pins survive replacement with a different bundle ID. Include a manual compatibility checklist for default
  document handlers, URL schemes, Dock pins and TCC. The Pake licensing discussion correctly identifies GPL-3.0;
  retain notices and provide the exact corresponding wrapper source/build instructions before distribution.

## Round 1 — author response (claude-opus-5-5)

All seven blocking issues are accepted; `docs/design.md` is revised (rev. r1). Section references point to the new text.

### Blocking issues

- **B1 — accepted.** §1.5 rule 4: overrides only go one way. `--mode restore` can upgrade `mount` to `restore`;
  nothing can downgrade. MAS receipt, helper, login item and launchd-plist hits are always `restore`, and rule-1
  hits are always `unsupported`. `--mode mount` is now just an assertion: it fails with `EX_UNSUPPORTED` when it
  does not match the classifier. `--force` never changes the mode, and config has no mount allow-list. §3.6: the
  remote format is always ULMO. `pack --format` and `pack.remoteFormat` are removed. `cache.localFormat` accepts
  only ULFO (default) or UDRO, and a manifest whose format is not ULMO is refused. The conversion cost is
  justified in §3.6 and §5.2.3e. Negative tests are listed in §11.1 (Classifier row) and checked by e2e A30.
- **B2 — accepted.** New §5.8 adds a write-ahead journal for every bundle move: pack install, restore-in,
  restore-out, unpack, `restore --permanent` and stub rebuild. The journal is written and fsynced before each
  effect. Staging is on the same volume (`<dest-parent>/.256isenough-staging/<txid>`), so the in-home `parked/`
  directory is gone. Phases are idempotent, and each phase has a table entry for forward or rollback recovery.
  Restore-out checks cdhash and a new tree hash (`app.treeHash`) **before** any removal. A bundle is deleted
  only if it matches a cached or uploaded image. Otherwise it goes to `retained/` and gets `needsResolution`.
  Supervisors never prompt; the user decides with `isenough resolve`. A hook failure or an identity failure now
  fully rolls back, journaled (§5.2.5/6). Permission preflight refuses non-writable destinations before changing
  anything (N5). Fault-injection tests cover every journal and mutation point plus hook failure and self-update
  (§5.8.6, §11.2, e2e A33/A34).
- **B3 — accepted.** §5.6 is rewritten:
  - Four locks: global shared, app, image and state.
  - A fixed global order (L0 → L1 by appId → L2 by imageId → L3). Lower locks are never acquired late.
  - A per-command lock table covering launch, join, post-quit, prefetch, pin, evict, gc, unpack, restore, pack,
    recovery and serve.
  - Cache check and attach now happen under one image-lock hold.
  - gc runs only after the app lock is released and uses non-blocking try-locks.
  - Exactly one adopter is elected under L1+L3 using owner (pid, start time).
  
  New §6.1 adds atomic capacity reservations stored in `state.json` with peak budgeting
  (materialization + copy + local image). Dead owners' reservations are reaped. Multiprocess tests are in §11.2
  and e2e A21–A23.
- **B4 — accepted.** New §5.9 defines usage roots per mode. Restore mode watches the restored bundle, not the
  detached mountpoint. The probe adds open-file/mapped-file checks, a backing-image check and a launchd check.
  Any probe failure counts as `unknown`, which is treated as busy. Restore cleanup waits indefinitely and has no
  force option. Quarantined bundles are **rejected** in MVP, with a manual recovery instruction (we do not track
  translocation). Every NSRunningApplication returned by NSWorkspace is checked against the intended bundle path
  and the executable root. Already-running instances from other paths are refused. Kept originals move to
  `retained/`. Tests: §11.2 probe tests and e2e A26–A29, A32.
- **B5 — accepted.** §8.3 adds a bidirectional socketpair protocol with these parts:
  - Request IDs, plus a per-batch ack/error sent only after NSWorkspace's completion handler returns.
  - Queueing before `ready`.
  - A drain sequence (quiet period → `bye` → `done`). The run loop stops only after `done`, so later events
    relaunch the stub, which then joins the session.
  
  Joining a session is synchronized under the app lock (§5.6.3): the joiner cancels the timer, sets
  `joinPending` and adds its lease itself, and the owner re-reads the session after taking the lock (§5.4).
  SIGPIPE is ignored, EPIPE or EOF marks the client as gone, and progress writes stop. Cancel is a message, not
  a signal; a joiner's cancel never affects the session. Tests: §11.1 StubProtocol and e2e A11b, A22, A24.
- **B6 — accepted.** New §10.1 defines two credentials:
  - The CLI uses a Bearer token from a 0600 file.
  - The Pake UI pairs once with a one-time code (`isenough serve pair`) and then gets an HttpOnly session cookie
    plus a CSRF token, which it can re-fetch with `GET /api/session`. SSE is authenticated by the cookie.
  
  Allowed Host values and serialized Origins are listed separately. The doc also specifies the
  401/403/421 responses, rotation and revocation, and server-side session hashes that survive restarts. No token
  appears in URLs, and the shell never reads the daemon's token file. Cookie persistence in Pake's WKWebView is
  an explicit assumption checked by the Pake startup job; if it fails, the fallback is to re-pair. Tests: §11.1
  API row, e2e step 14, and the manual `gui.yml` Pake startup check.
- **B7 — accepted.** §11.3 changes:
  - LS document and URL delivery (A11/A12, with the fixture logging `via:"appleEvent"`) and restore
    swap/recovery (A30–A33) are required gates. An unavailable environment exits `2` (inconclusive), which CI
    treats as a failure; the skip fallback is removed.
  - A16 now expects `ISENOUGH_EXIT_STATUS=unknown|crash`, with no numeric status.
  - The LRU and pin fixtures compute the quota from measured allocated sizes. A20 asserts one deterministic
    outcome (pinned app1 kept, app2 evicted, `launch app2` → `EX_NOSPACE`).
  - A10 also checks that LS resolved the mounted path (preserved originals are in `retained/`).
  - Diagnostics are collected before cleanup, and the CI artifact upload runs `always()`.

### Non-blocking suggestions

- **N1 adopted:** MVP implementation gates G-a…G-d (§12.1). Shared repo hooks and `gc --remote` are deferred to v2.
- **N2 adopted:** §7.1 adds a publication rule for non-atomic stores (manifest = publication), ETag/size checks
  on resume, `200` vs `206` handling, credential stripping on cross-host redirects, symlink containment, and
  `<sha8>` collision extension that never overwrites.
- **N3 adopted:** §6.1 adds peak budgeting, bounded convert/ENOSPC cleanup, and a note that the Trash frees no
  space until emptied.
- **N4 adopted:** logout detach is not assumed, `lsof` is documented as a filesystem selector, probe failures
  count as unknown, and device/mountpoint ownership is verified before reuse, adoption or detach.
- **N5 adopted:** no claim that TCC is universally preserved or that attach runs Gatekeeper. Destination
  permissions are preflighted. Stub `LSMinimumSystemVersion` is now 13.0.
- **N6 adopted:** `trust` and `resolve` are in the MVP command list. Schemas now include `trusted`,
  `reservations`, journals, `treeHash` and leases. The doc defines plist Date/Data → JSON, the migration
  policy, the manifest cache and icon regeneration. Hook documents and URLs are passed as a JSON file
  (`ISENOUGH_ARGS_FILE`).
- **N7 adopted:** `lsregister` is treated as best-effort, a manual compatibility checklist is added, and GPL
  notice and corresponding-source obligations are covered for Pake distribution.

No issue was rejected. One judgement call: for B4 I chose **rejecting** quarantined apps rather than tracking
translocated paths. Translocation paths are opaque and their lifetime is not documented, so tracking them safely
costs more than the MVP is worth. Users can clear quarantine themselves after Gatekeeper approval.

## Round 2 — reviewer (gpt-6.1-sol)

**Verdict: CHANGES REQUESTED.** Reviewed `32980d9` on `feat/mvp`, reading all three research documents,
`design.md` rev. r1, and the round-1 review/response. This is a design review on Linux; no macOS runtime tests
were run. Most round-1 changes are substantive, but the remaining contradictions below prevent implementation
from following one safe, testable contract.

### Authoritative corrections checklist

1. **FileManager instead of brctl:** satisfied (§7.2); download/upload completion is asynchronous.
2. **Materialize → independent copy → SHA-256 → attach:** satisfied (§5.2/§7.2); repo DMGs are never attached.
3. **No iCloud clone/evict zero-copy assumption:** satisfied (§6.2); cache bytes are independently copied.
4. **Remote ULMO, local ULFO/UDRO with conversion justification:** satisfied, including negative config tests.
   Round-1 B1 is fixed; MAS→restore and unsupported classes also cannot be overridden.
5. **Playpen lifecycle precedent, not AppPorts' immediate exit/URL loss:** correctly distinguished. Native
   document/URL forwarding is specified, but its shutdown protocol still loses events (R2-B2).
6. **Pake tray/window, localhost HTTP, GPL-3.0:** satisfied. Round-1 B6's unreadable-cookie/Bearer bootstrap is
   fixed by pairing, cookie-authenticated UI/SSE, and separate CLI Bearer authentication.
7. **Session roadmap starts with closed pi JSONL, excludes credentials/SQLite:** satisfied (§13); not MVP.

### Blocking issues

1. **R2-B1 — The usage probe counts the image's own attachment as app use** (§5.9, lines 744–754).
   The unconditional backing-image/device `lsof` pass treats any holder as busy. A normally attached image has
   disk-image infrastructure holding its backing DMG open (the research explicitly describes
   `diskimages-helper` reading/mapping it). That holder cannot disappear *before* detach. Thus an ordinary app
   quitting need never reach `idle`, and A15/A17 cannot pass. This is not a reason to weaken unknown→busy for
   genuinely uninspectable app processes.
   **Required:** distinguish attachment infrastructure from dependent app/helper/file users. Define a narrow,
   verified exclusion for the exact attachment's infrastructure, or use backing-file checks only for an explicitly
   tracked exceptional/translocated dependency. Do not exclude arbitrary same-named processes. Test an attached
   image with no app (probe clean), an app/helper/data-file holder (busy), and detach after those users exit.

2. **R2-B2 — `bye/done` still has an event-loss window, and joiners have a different protocol** (§8.3/§5.6.3).
   After the stub sends `bye`, a new Apple Event can arrive while it waits for `done`. The new `open` necessarily
   follows `bye` on the ordered socket; it cannot be "sent first" retroactively. The supervisor only accepts until
   `bye`, and the stub terminates on `done`, despite the new outstanding request. Keeping the run loop alive does
   not make macOS re-deliver an event already dispatched to that process. Separately, §5.6.3's joiner acks and exits
   immediately, while §8.3 requires `ready` then a `bye/done` exchange and treats EOF as supervisor failure.
   **Required:** specify one owner/joiner client protocol. A batch arriving after `bye` must be explicitly handed
   to a new joiner/connection and acknowledged before termination (or use another concrete lossless closing
   strategy); never terminate with outstanding batches. Define handshake timeout/error behavior. Add deterministic
   tests injecting an event after `bye` is sent, before/after its receipt, and before `done`, including a live-session
   joiner receiving several batches. Quiet-period tests alone do not cover this race. Round-1 B5 remains open.

3. **R2-B3 — Capacity math contradicts both its accounting and the required LRU acceptance test** (§6.1/§11.3.7).
   `used` already includes allocated partials, while every live reservation continues to reserve the *whole* peak;
   `free` likewise already decreased by those allocated bytes. Adding full reservations again double-counts work
   in progress. More decisively, the quota is charged `M+C+L`, but A19 chooses `Q` from final cache sizes only.
   A padded, incompressible app2 can have `C ≈ A2` and estimated `L ≥ 2C`, so its cold fetch cannot fit in
   `Q = A2 + A1/2` even with app1 evicted. The promised successful launch and pin scenario are not executable
   under the specified reservation algorithm.
   **Required:** separate final cache-quota admission from transient per-volume free-space reservations, or define
   an equally consistent explicit policy. Reserve only *remaining* incremental allocations as bytes materialize;
   avoid counting completed images in both `used` and reservations. Budget retained iCloud bytes accurately when
   eviction is unavailable. Align A19/A20 with that policy and add tests advancing two concurrent fetches through
   materialization/copy/conversion, not just testing reservation creation on an empty cache. Round-1 B7 is partly
   fixed (LS/restore gates and exit-status expectations), but its quota acceptance gate remains broken.

4. **R2-B4 — The lock specification is internally incompatible during fetch and space reclamation**
   (§5.2.3/§5.6.1–2/§6.1). L2 is held throughout fetch/convert/attach in both the pre-launch steps and lock table,
   yet §5.6.1 forbids holding it during download and backend writes. Capacity admission happens *after* taking
   L1+L2 and calls a gc pass that needs other L1 locks, violating the declared order. The generic instruction to
   release everything and restart does not specify how the active partial/reservation remains protected, or how a
   space-making restart avoids reacquiring the same locks and failing the same order again. This leaves round-1
   B3 without one implementable algorithm.
   **Required:** choose a single lock hold boundary for slow fetches and explicitly place admission/victim cleanup
   relative to it. If releasing locks, persist a claim that other fetchers/evictors honor, and revalidate on reacquire;
   alternatively perform reclamation before taking image locks with a defined retry path. Reconcile prose and
   tables. Add a multiprocess low-space test that actually requires evicting another app while launching, with the
   lock-order checker enabled; the operation must succeed or return EX_NOSPACE without deadlock/restart livelock.

5. **R2-B5 — `needsResolution` relaunch has no valid restore transaction** (§3.5/§5.8.1–3).
   Changed bundles are safely retained before deletion now: this fixes the main round-1 B2 data-loss issue.
   However, the unresolved stub is promised to restore/launch that retained bundle instead of the image, while
   `restore-in` unconditionally verifies its cdhash+tree hash against the *old image manifest*. A genuinely updated
   bundle fails this check. There is also no recorded retained-source path/expected identity transaction contract
   for selecting it, crash recovery, subsequent changes, and eventual cleanup. Implementers must either reject
   the promised launch or bypass the verifier without a specified replacement trust rule.
   **Required:** either block unresolved launches with a clear resolution-required error (safe MVP), or fully define
   a retained-source transaction with durable source path, verified snapshot identity, trust approval when needed,
   and no deletion until archival/resolution. Test relaunch after A34, a second update, and crash during that
   relaunch. Include local pre-launch hooks modifying the restored bundle before failing: rollback must compare
   the tree hash, not rely on §5.2.5's claim that cdhash alone suffices because nothing was launched.

6. **R2-B6 — Failed detach and detach-backoff relaunch have no coherent terminal state** (§5.4/§5.6.3).
   §5.4 marks `detaching`, releases L1 between retries, and says a relaunch wins. §5.6.3 instead makes `detaching`
   unjoinable and assumes acquiring L1 means the session is gone; during backoff it is still present. At retry
   exhaustion the spec says mark `stuck`, but then its unconditional step 6 removes the mount/session and step 8
   exits success, with no requirement that detach actually succeeded. Losing this record would also defeat cache
   eviction protection for a still-attached image.
   **Required:** explicitly branch on successful detach, retryable failure, and stuck. Preserve ownership/session
   and cache protection on failure; return/report the failure rather than falling through successful cleanup.
   Define how a joiner cancels backoff and safely returns a detaching/stuck-but-attached session to running, or
   waits without opening another session. Specify whether post-quit hooks rerun. Test busy detach across multiple
   retries, relaunch during a released-lock interval, exhaustion, and later successful recovery.

### Non-blocking suggestions

- **N1 — Scope and sequencing:** the G-a…G-d staging is useful. Resolve the above state-machine contradictions
  before building the HTTP server; defer optional infrastructure rather than dilute required hooks/forwarding.
- **N2 — Probe permissions:** exercise real non-root `libproc`/`lsof` behavior on the macOS runner early. Other-user
  processes, permission errors and persistent registered login items may intentionally keep restore sessions open
  indefinitely; diagnostics should distinguish these from live app users. Avoid assuming a registered launchd
  program is necessarily running, or describing arbitrary bundles as small for recursive `lsof +D`.
- **N3 — Backend phase 2:** the range/redirect/containment/collision additions improve the abstraction. Clarify how
  a non-atomic store promotes a temporary object to the path in `image.file` and publishes a complete manifest;
  do not advertise WebDAV MOVE as universally atomic. This is not a blocker for the two MVP folder backends.
- **N4 — macOS claims:** preserving the real signature, refusing quarantine, best-effort LS cleanup, and manual
  TCC/default-handler checks are appropriate. Moving a kept original to `retained/` does not itself guarantee LS
  forgets it; explicit-path launches plus returned-instance checks, not LS's preferred URL alone, are authoritative.
- **N5 — Test isolation:** the portable e2e contract is substantially better. Unregister fixture paths *before*
  detach in trap cleanup, clear `quit-now` before each relaunch, and allow for the two clean probes (≥5 s apart)
  when asserting the 1 s idle observation. These are small acceptance-script details, not additional blockers.

## Round 2 — author response (claude-opus-5-5)

All six blocking issues are accepted and fixed in `design.md` rev. r2. I disagree with none of them. In two places
I describe a limit plainly instead of claiming it away: the OS-level exit window for Apple Events (R2-B2), and the
fallback estimate for old manifests (R2-B3).

### Blocking issues

1. **R2-B1 (probe counted attachment infrastructure) — fixed, §5.9.** A *dependent user* is now defined as a
   process that executes from, maps, holds open, or has its cwd on a file **inside the usage root**. Matching is by
   path realpath and by the mounted filesystem's `st_dev`. Explicitly tracked dependents also count. The normal
   probe no longer looks at holders of the backing DMG or `devEntry`. Holders of those are recorded once after
   attach as an `infra` baseline. That baseline is limited to verified Apple platform binaries and is used only to
   explain detach errors, never to block `idle`. Backing-file reasoning is used only for tracked
   translocated/wrong-path pids, and those are checked by pid liveness (`trackedDependents`).
   - **Kept:** unknown→busy for same-uid EPERM.
   - **Probe mechanism:** the in-process `libproc` probe (fds, cwd, mapped regions) replaces `lsof +D` (N2). `lsof`
     on the filesystem stays as a cross-check.
   - **Tests:** pure `UsageProbe` tests; macOS `MountUsageProbe` (attached image with no user → clean although
     infrastructure holds the DMG; file/mmap/helper → busy; then detach succeeds); e2e A27b; A15 required.

2. **R2-B2 (`bye/done` event loss; joiner protocol) — fixed, §8.3, §5.6.3.**
   - **One protocol:** owner and joiner supervisors now speak exactly the same protocol, and the stub cannot tell
     them apart. Supervisors read fd 3 until EOF, keep accepting `open` after `bye`, and send `done(gen,lastReq)`
     only when every `req ≤ lastReq` is acked.
   - **Generations:** an event that arrives after `bye` is sent as a new `open`, which invalidates the close
     (`gen += 1`). A stale `done` is ignored and a fresh `bye` follows.
   - **Exit:** on a matching `done` the stub does a final zero-timeout run-loop drain and calls `exit(0)` in the same
     main-thread turn. So no event dispatched to our handlers is ever dropped, and the stub never exits with
     outstanding batches.
   - **Timeouts and EOF:** heartbeat/handshake timeouts are defined. On EOF with outstanding batches, the stub
     spawns one new supervisor and re-sends the unacked batches (at-least-once).
   - **Joiners:** a joiner that finds the session gone turns into an owner in the same process.
   - **Remaining limit:** the microsecond mach-queue window between the final drain and `exit` is the same for any
     exiting process. It is now listed as residual risk §14.1-9, not denied.
   - **Tests:** deterministic tests for the four injection points (before/after the supervisor reads `bye`,
     before/after `done`, during the drain), a joiner with several batches across two generations, and respawn.
     Also e2e A11c, which holds at `bye`/`done` for both owner and joiner stubs and is a required gate.

3. **R2-B3 (capacity double counting; A19 infeasible) — fixed, §6.1, §3.2, §11.3.7.** Two separate checks:
   - **Quota admission on final sizes:** `usedFinal + Σ claims.F + F_X ≤ quota`.
   - **Per-volume free-space admission on transient bytes:** `Σ remaining + planned_X ≤ free − minFree`.
   - **No double counting:** `remaining = planned − allocated` is updated as bytes materialize, and in-flight files
     are not in `usedFinal`. When a fetch completes, one L3 write moves the bytes from the claim to `usedFinal`.
   - **Measured local size:** `F` is measured by `pack` (`image.localSizes`). Old manifests fall back to a
     pessimistic estimate; if the real size turns out larger, the launch still succeeds and the next quota pass
     corrects it.
   - **iCloud copies that cannot be evicted:** these bytes are budgeted in free space, not in the quota, and reported
     by `doctor`.
   - **A19/A20:** recomputed from the measured `F2` with incompressible padding (`Q = F2 + A1/2`), so the scenario is
     now runnable.
   - **Tests:** `CapacityPlanner` tests move two concurrent claims through materialize/copy/evict/convert/done on a
     fake volume, plus the persistent-`M` and under-estimate cases.

4. **R2-B4 (lock hold conflict, reclamation order) — fixed, §5.6.1–2, §5.2.3.** One hold boundary: L2(img) is held
   for the whole fetch, verify, convert and attach decision of *that* image, and never while waiting on anything
   else. The r1 sentence that contradicted this is withdrawn, and the prose and lock table now agree.
   - **Order:** admission and reclamation run holding L0(sh)+own L1 and *no* L2, before L2 is taken.
   - **Victims:** victim locks are taken **only with try-lock**, which is allowed out of order because it never
     waits. Busy victims are skipped.
   - **No restart path:** "release everything and restart" no longer exists. Every reclamation round either deletes
     a victim or ends in `EX_NOSPACE`, so it cannot livelock.
   - **Claims:** the persisted claim protects capacity after L1 is released (prefetch). A launch that sees a live
     claim for the same image skips admission and waits on L2.
   - **Tests:** a new multiprocess low-space test with the lock-order checker enabled (§11.2).

5. **R2-B5 (`needsResolution` relaunch) — fixed by the safe MVP option, §5.8.1, §5.8.7.**
   - **Launch is blocked:** an app with `needsResolution` refuses to launch with the new `EX_RESOLUTION` (14), before
     changing anything. The r1 promise to launch the retained bundle is withdrawn.
   - **Durable record:** the record (`retainedPath`, tree hash, cdhash, Team ID, `fromImageId`, txid) is written to
     the journal and to state.
   - **`resolve` is journaled:** `--keep-updated` re-verifies the tree hash against the record, requires `--trust`
     when the identity changed, and packs a new image. It moves the bundle to the Trash only after that image is
     verified in cache or uploaded. `--discard` and `--export` are also available. A crash in any phase leaves the
     app blocked and never without a copy.
   - **Rollback checks the tree hash:** hook-failure rollback now always compares cdhash **and** tree hash. The
     "cdhash alone suffices" claim is removed.
   - **Tests:** A34b (blocked relaunch, second update, crash at each resolve phase) and A34c (a pre-launch hook that
     modifies the bundle), plus a `preLaunchHookMutates` fault point.
   - **Later:** "launch retained" is sketched as a v1 option with its own trust rule.

6. **R2-B6 (detach failure states) — fixed, §5.4, §5.4.1, §5.6.4.** Step 4 now ends in exactly one of four
   outcomes: detached, retryable failure (`backoff`), exhausted (`stuck`), or ownership mismatch (`stuck`). Success
   is confirmed by re-querying `hdiutil info`.
   - **Ownership kept:** `backoff` and `stuck` keep the mount record, owner, and cache protection. Eviction also
     refuses any image that `hdiutil info` still shows as attached.
   - **Exit status:** on `stuck` the supervisor exits `EX_DISKIMAGE` instead of falling through to cleanup. Cleanup
     and `lastUsedAt` run only after a verified detach.
   - **Revive:** a joiner takes L1 and revives an `idle`/`backoff`/`stuck` session to `running` (new epoch,
     adopting it if the owner is dead). It never opens a second session. The backoff owner re-checks under L1
     before every attempt, so it cannot detach a revived session.
   - **Hooks:** post-quit hooks run exactly once per epoch, so retries do not rerun them. Pre-launch hooks rerun
     only when a stub revives a session into a new epoch.
   - **Retries after `stuck`:** daemon/gc/`isenough detach [--force|--forget]`, or the next launch.
   - **Tests:** pure `DetachMachine` tests and e2e A27c (busy ×2 → detach; revive during backoff; exhaustion → exit 6
     with the record kept and evict refused; later `isenough detach` succeeds).

### Non-blocking suggestions
- **N1:** adopted. Within G-a the pure state machines (stub close, detach, capacity, lock checker) come first. The
  HTTP server waits until G-d.
- **N2:** adopted.
  - Permission classes: other-uid EPERM is ignored in mount mode (the 0700 per-user mountpoint plus `-owners on`
    means other users cannot reach it) and is `unknown` in restore mode.
  - A registered but not running launchd job gives `held`, not "in use".
  - `lsof +D` is dropped, and so is the "bundles are small" claim.
  - The probe tests run on the non-root runner early and save EPERM artifacts.
- **N3:** adopted (§7.1/§7.4). Non-atomic stores now upload to a temp name, verify, then rename to the final path
  (or upload directly to it). Publication is still defined by writing the manifest last. WebDAV `MOVE` is no longer
  advertised as atomic.
- **N4:** adopted (§5.9, §11.3). Moving originals to `retained/` is best effort. Opening by explicit path and
  checking `proc_pidpath` of the returned instance is authoritative; LS's preferred URL is only logged.
- **N5:** adopted (§11.3). The trap now runs `lsregister -u` before detach, `quit-now` is cleared before each
  relaunch, and A15 waits for the two clean probes.

## Round 3 — reviewer (gpt-6.1-sol)

**Verdict: CHANGES REQUESTED.** Reviewed `033039a` on `feat/mvp`, including all of `research.md`,
`research-luna.md`, `research-cursor.md`, `design.md` rev. r2, and both previous reviews/author responses.
This is a document review on Linux; no macOS runtime behavior was experimentally verified.

### Authoritative corrections checklist

1. **FileManager instead of brctl:** satisfied (§7.2); asynchronous download/upload completion is explicit.
2. **Never attach dataless repo images:** satisfied (§5.2/§7.2): materialize/current check, independent copy,
   SHA-256 verification, conversion, then attach only the verified local image.
3. **No clone/evict zero-copy assumption:** satisfied (§6.2); streamed independent cache copy is mandatory.
4. **Remote ULMO; local ULFO/UDRO:** satisfied, including conversion-cost justification and negative tests.
5. **Playpen lifecycle precedent; document/URL forwarding:** correctly distinguished from AppPorts. Native
   AppKit/NSWorkspace forwarding is specified, but contradictory joiner shutdown instructions remain (R3-B1).
6. **Pake tray/window + localhost HTTP + GPL-3.0:** satisfied (§2/§10/§12/§14), including pairing, cookie/SSE
   authentication, separate CLI Bearer authentication, and corresponding-source obligations.
7. **Session roadmap starts with closed pi JSONL; excludes credentials and SQLite:** satisfied (§13), not MVP.

### Previous-round disposition

R2-B1's backing-image self-dependency is fixed. R2-B3's quota/transient double counting and infeasible LRU
scenario are fixed. R2-B4's lock hold contradiction and reclamation order are fixed, but the prefetch claim
handoff has a remaining race (R3-B3). R2-B5's unresolved-launch promise is correctly replaced by a hard block;
its acceptance fixture still cannot exercise the promised successful resolution (R3-B6). R2-B6's mounted-session
backoff/stuck branches now preserve ownership and cache protection. R2-B2's generation protocol is substantially
improved in §8.3, but §5.6.3 still instructs a joiner to exit before that protocol completes (R3-B1).
Restore-mode recovery and the revised probe's permission policy need explicit executable contracts (R3-B2/B4).

### Blocking issues

1. **R3-B1 — Joiners still have two incompatible shutdown rules** (§5.6.3 step 3 versus §8.3).
   §8.3 correctly requires both owner and joiner to keep reading after `bye`, accept later generations, and never
   close first; a joiner exits only on EOF after acknowledgements. §5.6.3 instead explicitly says, "After `bye`
   the joiner sends `done` and exits." Following that rule can terminate the transport with a late `open` already
   queued after `bye`, invoking crash/respawn behavior during an ordinary successful close. It also prevents the
   specified single-connection, multi-generation joiner tests from following one contract.
   **Required:** remove the exit-on-`done` instruction everywhere (including abbreviated diagrams where relevant);
   make EOF-after-drain the one joiner exit condition, with §8.3 authoritative. Keep the deterministic test where
   `open(gen+1)` follows `bye(gen)` on a live-session joiner's connection, and assert that this same joiner accepts
   and acknowledges it without respawn. The protocol-level race fix is otherwise sound; the acknowledged residual
   OS termination window is not an additional blocker.

2. **R3-B2 — The restore usage probe can never become clean on an ordinary non-root Mac** (§5.9 passes 1–3).
   The probe enumerates *every* PID and treats any root/other-user EPERM as `unknown` in restore mode, indefinitely
   blocking cleanup. A non-root process cannot inspect the fds/mapped regions of all system/root processes;
   ordinary unrelated protected system processes therefore suffice to strand even the simple A31 restore fixture.
   Merely logging this as a permission limitation does not make temporary restore implementable. The mount-mode
   claim that 0700 excludes other users also does not exclude root; root access must not be justified by DAC alone.
   **Required:** define a realistic supported inspection boundary and a justified treatment of unrelated protected
   platform processes, separately from relevant app/helper users. Preserve unknown→busy for genuinely unresolved
   potential dependents; do not blanket-ignore arbitrary inaccessible helpers. If complete proof is unavailable
   under the no-privilege constraint, state the supported assumptions/restrictions and fail unsupported preflight
   rather than promise temporary cleanup that can never occur. Run the real non-root probe against the normal
   macOS process population and require both an idle mounted fixture and an idle restored fixture to become clean,
   while a relevant unreadable holder remains conservatively blocked.

3. **R3-B3 — A live prefetch claim does not establish who owns the fetch lock/work** (§5.2.3b–c, §5.6.2, §6.1).
   Prefetch writes its claim under L1, releases L1, and only then takes L2. A launch can take L1 in that gap, see
   the live claim, skip admission, and acquire L2 *before* prefetch. The text assumes it will wait and find a complete
   image, but that ordering is not guaranteed. The launch then performs the fetch using capacity owned by the
   prefetch PID. If prefetch dies, dead-owner reaping can release that capacity while the launch still writes,
   allowing another image to be admitted without the required reservation. L2 serializes bytes, not claim ownership.
   **Required:** make claim publication and worker/lock ownership a coherent handoff. For example, prefetch can
   acquire L2 while still holding L1 and release L1 only after it owns both the claim and L2; alternatively specify
   an atomic ownership-transfer/re-admission protocol. Every actual writer must have a live claim owned by that
   writer, and reapers must not free an active writer's reservation. Add deterministic multiprocess tests pausing
   prefetch between claim publication and L2 acquisition, launching concurrently, and killing prefetch at that point;
   verify accounting and completion with a third different-app admission.

4. **R3-B4 — Restore orphan recovery still requires an attachment that restore deliberately removed**
   (§3.5 `restored`, §5.8.2 `active`, §5.6.4, §9). Restore-in detaches the image before launching and records the
   active session in `restored`/its open journal. Recovery of that `active` journal points to §5.6.4, whose adopter
   must verify an attached `devEntry`, cache image and `mnt/<imageId>` before adoption. Those do not exist for an
   active restored app. §9's mount reconciliation/drop-if-not-attached rule is likewise not a restore recovery
   algorithm. Thus killing the supervisor after restore launch leaves no specified way for gc/another supervisor
   to adopt the live restored session, watch its helpers, and eventually restore the parked stub safely.
   **Required:** add a separate restore-session adoption branch, elected under L1, based on the durable journal,
   destination/staging identities, owner pid/start, and mode-specific usage probe—not an attached-image check.
   Specify active-and-busy, active-and-clean, and partially swapped outcomes, including ownership publication and
   exactly when recovery waits versus runs restore-out. Add a required real macOS test: launch restored fixture,
   kill its supervisor while app/helper remains alive, run two recovery callers, verify one adopter and no early
   swap, then quit all users and verify stub reinstatement, hooks policy and journal closure.

5. **R3-B5 — Successful restore cleanup is not connected to a terminal session state** (§5.4 steps 4–7).
   Step 4 defines `detached/backoff/stuck` outcomes for mount mode. Its restore alternative runs restore-out,
   but assigns no outcome. Step 5 is expressly "only after outcome detached" and removes only a mount/session
   record; it does not specify removing `state.restored[appId]`. §5.8.3 closes the journal without specifying this
   state cleanup either. Implementing these literally can leave a restored-session reference to a deleted journal,
   and a subsequent launch/evict/recovery sees a stale active session. This is distinct from safe bundle retention,
   which is now properly specified.
   **Required:** define restore-out success as an explicit terminal outcome, atomically retire the restored/session
   references after durable swap completion, update LRU consistently, and retain a recoverable journal until that
   state publication is durable. Busy/unknown/held and `needsResolution` outcomes must remain distinguishable.
   Extend restore fault tests across the journal-close/state-retirement boundary and assert a second launch,
   status, evict and repeated recovery all see the correct terminal state.

6. **R3-B6 — The required update-resolution acceptance gate uses an invalid update fixture** (§11.3 A34/A34b,
   §5.8.7). A34 merely writes a file into the signed bundle. That can invalidate its resource seal without changing
   its executable's cdhash; cdhash is not a hash of the live bundle tree. A34b nevertheless expects a changed
   cdhash and successful `resolve --keep-updated --trust`, while resolve correctly requires a valid code signature.
   Trust approval cannot repair an invalid signature, and the engine must not re-sign real apps. The required
   green acceptance sequence is therefore not supplied by the stated fixture.
   **Required:** separate two tests: (a) an invalid bundle mutation is retained, keep-updated is refused without
   deleting it, and export/discard remains available; (b) a genuine simulated update replaces the fixture with a
   newly valid, test-harness-signed bundle having a changed cdhash, so explicit ad-hoc trust approval and successful
   resolution can be tested. Re-signing belongs only to fixture construction, never the engine. Keep tree-hash-only
   hook mutation coverage as a separate rollback test.

### Non-blocking suggestions

- **N1 — Scope:** the required sections and abstraction seams are present, and G-a…G-d remain a useful sequence.
  The MVP is nevertheless substantial; prioritize the real non-root usage probe and both lifecycle modes before
  implementing the HTTP server. Deferring optional features is preferable to weakening required safety gates.
- **N2 — Diagram drift:** §5.7 still describes argv document forwarding and an events FIFO, while §8.3 mandates
  socketpair NDJSON and no document argv. Update the diagram to avoid reviving the obsolete implementation.
- **N3 — Claims and macOS details:** validate the `libproc` fd-info calls against the actual SDK (fd-specific vnode
  information uses `proc_pidfdinfo`), handle process-exit races separately from EPERM, and preserve diagnostics.
  Do not require a nonempty userspace infrastructure baseline on OS versions using an in-kernel image path.
- **N4 — Portable test hooks:** A11c's environment-variable hold switch must reach an LS-launched stub explicitly
  (e.g. isolated fixture resource/test config); an environment variable exported by the script is not generally
  inherited through Launch Services. Keep hook configuration isolated and unavailable in release builds.
- **N5 — Distribution/phase 2:** the Pake license discussion, trust anchor, quarantine refusal, best-effort LS
  cleanup and backend publication rules are appropriate. Treat TCC/default-handler continuity as compatibility
  observations, not guarantees; test actual iCloud APIs manually on supported releases after the fake-backend CI.

## Round 3 — author response (claude-opus-5-5)

All six blocking issues are accepted and resolved in `docs/design.md` rev. r3. All non-blocking suggestions
(N1–N5) are adopted.

### Blocking issues

1. **R3-B1 — joiner shutdown.** Accepted. §5.6.3 step 3 now says the opposite of r2: `bye` does not end a joiner. It
   answers `done(g, r)`, keeps reading, and accepts and acks later generations. Its **only** exit condition is EOF
   on fd 3 after every batch it received has been acked. §8.3 is named as the authoritative source, and its
   supervisor-rules paragraph repeats the rule. The §5.7 diagram no longer shows `done` → exit for the supervisor.
   It shows the stub's final drain → `exit` → EOF, and a note gives the owner/joiner EOF behaviour (N2, below).
   New deterministic `StubProtocol` test: `open(gen+1)` arrives on a live-session joiner's connection after its
   `done(gen)`. The same joiner pid acks it, there is no respawn, and the joiner exits only after EOF. A11c now
   asserts the same pid on real processes.
2. **R3-B2 — restore probe on a non-root Mac.** Accepted. §5.9 pass 3 is rewritten as a *supported inspection
   boundary*:
   - Pass 1 (`proc_pidpath`) covers every uid, root included. Per-fd, cwd and region info is used only for our
     own uid, with `proc_pidfdinfo` named correctly (N3).
   - A process that exits during the probe (`ESRCH`, or its start time changed) is skipped. It is handled
     separately from `EPERM` (N3).
   - Each uninspectable pid falls into one class: **own** → unknown; **related** → unknown; **platform**
     (Apple-anchored, sealed system volume) → ignored; **unrelated** (valid signature, other Team ID) → ignored;
     **unverifiable signature** → unknown. "Related" means one of: executes from the root; listed in the new
     `manifest.app.related` (declared helpers and launchd labels); same Team ID; or listed in a user
     `relatedExecutables` config entry.
   - **Mount mode** no longer argues from DAC. The 0700 argument is withdrawn. The completeness proof is the
     kernel's: a non-forced unmount fails `EBUSY` for any holder of any uid, and that failure maps to `backoff`.
   - **Restore mode** states assumption A-R and its documented restriction.
   - Unsupported preflight: `pack` classifies apps with `KeepAlive`/`RunAtLoad` embedded daemons as
     `unsupported`. restore-in refuses (`EX_UNSUPPORTED`) if a related uninspectable process is already running.
   - New required §11.2 test runs the real non-root probe against the runner's full process population:
     - an idle mounted fixture and an idle restored fixture both become clean;
     - a harness-started root `relatedExecutables` helper holding a file stays `unknown` and blocks cleanup;
     - a platform root holder is caught by the kernel unmount gate;
     - the exit-race and classifier cases are covered.
3. **R3-B3 — prefetch claim handoff.** Accepted, using the option you proposed.
   - Prefetch now takes L2(img) **while still holding L1** (legal order) and releases L1 only after it owns both
     the claim and L2 (§5.6.2).
   - Invariant (§5.2.3c, §6.1): the only writer of an image holds L2 **and** owns a live claim. Claims are never
     transferred. A launch that waited for a failed or dead prefetch re-admits under its own pid while holding L1.
   - Reaping a dead claim requires L2 plus a dead-owner check under L3, so an active writer's reservation can
     never be freed.
   - Tests: a pure interleaving model (§6.1 e) and real multiprocess tests (§11.2). The real tests hold prefetch
     at claim publication, kill it after it takes L2, and run a third-app admission that must not get the
     reservation early.
4. **R3-B4 — restore orphan adoption.** Accepted. §5.6.4 now has two separate branches.
   - (a) Mount sessions: the attachment check, unchanged.
   - (b) Restore sessions: driven by the open restore journal, not by an attached image. The adopter checks that
     `destId`/`stubId` (inode identities, new in §3.5) or bundle id + cdhash match the expected layout, checks the
     owner pid/start, and runs the restore-mode probe.
   - A phase × probe table gives the action for each case: rollback before `installed`; adopt-and-wait when busy
     at `installed`/`active`; restore-out only after two clean probes under the current owner; forward
     continuation for partially swapped restore-out phases.
   - Single-adopter election rewrites the journal owner first (WAL rule), then the state mirror. Short-lived
     adopters such as `gc` hand ownership to a detached `isenough hook watch` process (new internal command).
   - §9 restore recovery no longer uses the attachment check.
   - The table is a pure function, `RestoreRecovery.decide`. It is enumerated exhaustively with the invariant
     "no rename of dest unless the probe was clean twice under the current owner".
   - New required A33b: kill the supervisor while the app and its helper live, run two concurrent `gc`. Expected:
     one adopter, no early swap, a joining document delivered once; after quit, the stub is reinstated, hooks ran
     once and the journal is closed. A variant kills at `installed`.
5. **R3-B5 — restore-out terminal outcome.** Accepted.
   - §5.4 step 4 now lists restore outcomes: **waiting(busy|unknown|held)** (non-terminal, joinable) and
     **restoredOut / restoredOutRetained** (terminal). Step 5 is now explicitly mount-only.
   - §5.8.3 adds a `retired` phase before `closed`. In one durable L3 write it:
     - removes `state.restored[appId]`;
     - sets `needsResolution` if the bundle was retained;
     - sets `lastOutcome` (`restoredOut`, `restoredOutRetained`, or `rolledBack` for hook rollback);
     - updates `lastUsedAt` and the per-app state.
   - The journal is removed only after that write, so every crash point is recoverable.
   - A `restored` entry whose journal is missing is retired only if the stub is verifiably back in place.
     Otherwise `doctor` reports it.
   - The views now agree: launch, status, evict and recovery all read the same terminal state.
   - New fault points: `disposed:after`, `retired:before/after`, `closed:before`. After each, a second launch,
     status, evict and repeated `gc` must show the same terminal state (A31, A33).
6. **R3-B6 — update fixture.** Accepted. Split into separate tests:
   - (a) **A34 `restore_invalid_mutation`**: an in-place write breaks the seal and the cdhash is unchanged. The
     bundle is retained. `--keep-updated` is refused with or without `--trust` (`EX_INTEGRITY`, strict static
     validation, §5.8.7); `--trust` cannot override an invalid signature. Export (and discard) stay available.
   - (b) **A34d `restore_signed_update`** (required): the *test harness* replaces the bundle with a v1.1 fixture
     that it ad-hoc signs itself, so the cdhash really changes. The test covers refusal without `--trust`,
     success with `--trust`, Trash-only-after-verify, crash per resolve phase, and a later discard.
   - The engine never re-signs apps; a log grep asserts this.
   - A34c remains the tree-hash-only (cdhash-equal) rollback test.

### Non-blocking suggestions
- **N1:** adopted. The G-a/G-b priority note in §12.1 says the real non-root probe is the first macOS-runner
  deliverable, and both lifecycle modes come before any server work.
- **N2:** adopted. §5.7 now shows the socketpair NDJSON `--control-fd 3` spawn, documents only in `open`
  messages, the joiner branch, and EOF-based exit. Argv documents and the FIFO are removed.
- **N3:** adopted. `proc_pidfdinfo` is named; `ESRCH`/exit races are separate from `EPERM`; diagnostics are kept
  in `details.uninspectable`. The `infra` baseline may be empty (§5.9 pass 6, §11.2).
- **N4:** adopted. Test hold points and faults no longer come from environment variables. They come from a
  `test-hooks.json` resource in the *test* stub bundle and from `testHooks`/`faults` keys in the isolated
  `$E2E_DIR` config. They are compiled only with `-D ISENOUGH_TEST_HOOKS`, and CI checks that release binaries
  do not contain them.
- **N5:** adopted. New §14.1 risk 13 treats TCC, default handlers and Dock pins as compatibility observations.
  Real iCloud API behaviour is tested manually (G-c) after the fake-backend CI.
