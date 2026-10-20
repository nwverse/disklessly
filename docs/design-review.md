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
