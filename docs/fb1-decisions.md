# F-B1 decisions

The restore design in `docs/design.md` §§5.6.4b and 5.8 leaves a few choices open. These are the choices this implementation makes. The pure decision function is `RestoreRecovery.decide`; the runner is `RestoreCoordinator`.

1. **`ownerAlive` means a different live process.** The process that currently holds the journal passes `false` and is allowed to act. A live foreign owner is `noopLiveOwner` with no rename, delete, or mirror write, including when the layout is ambiguous. A missing journal is not covered by that no-op: a stale `state.restored` mirror is retired only when the destination is the stub and staging is gone, and is otherwise rejected.

2. **Early phases accept an undone layout.** `prepared`, `extracted`, and `stubParked` treat "stub still at the destination and staging absent or empty" as a valid pre-effect, so rollback is idempotent. `installed` does too. `active` and later do not: losing the restored bundle there is a reject, not a silent rollback.

3. **cdhash.** On macOS, `codesign -dvvv` `CDHash` (lowercased) wins when it succeeds. Unsigned bundles and Linux use the sha256 of `Contents/MacOS/<CFBundleExecutable>`. Tree hash is sha256 over sorted relative paths, type, mode, symlink target, and file bytes. Extraction markers live in the staging directory, never inside the bundle.

4. **Clean twice.** The default probe interval is 5 seconds (`ISENOUGH_PROBE_INTERVAL`, and `RestoreCoordinator.probeIntervalOverride` in tests). `0` is allowed. The streak is in memory and resets when the phase changes or the probe is not clean. Destination renames (`moveAppAside`, `restoreStub`, `regenerateStub`) and `deleteIdenticalCopy` require a clean probe and a streak of at least 2. Rolling back `prepared` / `extracted` / `stubParked`, and the pre-effect of `installed`, does not. `installed` plus a clean streak is a restore-out whose outcome is `rolledBack`, and it skips the detach delay. A normal quit from `active` waits `ISENOUGH_DETACH_DELAY` unless `pendingOutcome` is already `rolledBack`.

5. **Faults live in `stateDir/config.json`.** `faults` is a list of `"<phase>:<beforeJournal|afterJournal|afterMutation>"`. `faultMode` is `kill` (SIGKILL) or `raised` / `throw` (`InjectedFault`). The keys are read only when present, so an in-process test fault is not cleared by a config that never mentioned faults. `gc` and `launch` must not run while a kill fault is still configured.

6. **`active` does not move a bundle.** Its mutation is the `state.restored` mirror. The mirror may lag the journal; recovery trusts the journal and rewrites the mirror after it claims a dead owner.

7. **Replacements are watched.** Same bundle id and a different inode or cdhash at the controlled destination is not a reject and is not deleted merely because the bundle id matches. Deletion requires an unchanged inspection (cdhash, tree hash, and bundle id) plus a verified archive (cache `images/<imageId>.dmg` or the repo image, sha256). Otherwise the bundle is retained under `stateDir/retained/<appId>/<txid>-<name>.app` and launch fails with `EX_RESOLUTION` (14) until `resolve`.

8. **Stub identity is the bundle id `*.256stub`, not the inode.** Regeneration allocates a new inode. Recovery will rebuild a stub only onto an empty destination, from the journal plus `locateLauncher` (or a tiny shell launcher if that lookup fails), and `codesign --sign -` on macOS. It never overwrites a non-empty destination. A missing parked stub at `appMoved` / `stubBack` is regenerable; a foreign bundle in that role is a reject.

9. **Ambiguous layouts are frozen.** Symlinks, path escapes, duplicate roles, and unexpected staging names produce `reject` and a `doctor` repair string. Nothing is deleted. The repair is to move the unexpected items out of staging and run `isenough gc`.

10. **`launch` follows `manifest.mode`. `restore` forces restore mode** on a copy of the manifest. `--permanent` is not part of this slice; `LaunchArguments` reports it as an unknown option (`EX_USAGE`).

11. **Hooks** are `stateDir/hooks/<bundleId>/{pre-launch,post-quit}` and the matching `.d` directories. A non-zero pre-launch sets `pendingOutcome=rolledBack`, runs restore-out, and returns `EX_HOOK` (10). Post-quit runs once per epoch, and only after a successful open (`didLaunch`). A pre-launch failure therefore does not run post-quit. If the bundle changed and the pending outcome is `rolledBack`, the stored outcome stays `rolledBack` and `needsResolution` is still set.

12. **Retirement is one `state.json` write** (`applyRetirement`): drop `restored[appId]`, set `lastOutcome` `{name, at, txid}`, set `needsResolution` or clear it, and update `lastUsed` only when the outcome is not `rolledBack`. The outcome and timestamp are stored on the journal before that write. Replay uses those values and does not invent a later time. `retired` is journaled, the state write is fsynced, `closed` is journaled, then staging (unless the retained path is inside it) and the journal are removed.

13. **The disk image is detached during `extracted`, before `stubParked`.** `mountPath` is saved on the journal before `hdiutil attach`, so a crash during attach still has a path to detach. Restore recovery never reads `state.mounts` and never asks `hdiutil` for an attachment list.

14. **`gc` finishes a clean recovery in-process.** Only `busy`, `unknown`, `held`, and `delay` are handed to a detached `isenough hook watch --app <id>`. The watcher is spawned with `posix_spawn` and `POSIX_SPAWN_SETSID` (glibc `0x80`, Darwin `0x0400`) so it does not depend on python3. A second caller that sees that live owner returns without mutating.

15. **File URLs are decoded once.** `StubArgv` uses `URL.path` and does not call `removingPercentEncoding`. `file:///w/a%2520b.txt` is `/w/a%20b.txt`. `file:///y%20z.txt` stays `/y z.txt`.

16. **`--` ends Launch Services noise filtering.** Before the separator, `-psn_*`, `-NS*`, and `-Apple*` are dropped. After it, `-NSnotes.txt` is a document. An invalid `ISENOUGH_STUB_BINARY` is `EX_USAGE` and does not fall back to a sibling. A resolved launcher whose real path is the CLI is `EX_FAILURE`.

17. **`resolve --keep-updated` repacks on macOS only.** Linux returns `EX_UNSUPPORTED` and does not clear the resolution record. `--discard` and `--export` work on both. An invalid code signature is `EX_INTEGRITY` and is not discarded by the keep-updated path. A cdhash change without `--trust` is `EX_USAGE`.

18. **`find` prefers the pinned image.** `manifest(named:)` uses an explicit image id, then `state.apps[id].imageId`, then the bundle id or display name. `doctor --fix` runs `gc` and then reports. `doctor` is not a generic success: open journals with rejected layouts, stale mirrors, and `needsResolution` are issues.

19. **A crash at `active` before `open` still finishes as `restoredOut`** when the bundle is unchanged, because forward completed. `rolledBack` is reserved for the installed-phase clean path, an explicit pre-launch rollback, and a changed bundle whose pending outcome was already `rolledBack`. `lastUsed` moves only for outcomes other than `rolledBack`.

20. **The placeholder unit assertion was replaced.** `testRestoreModeIsExplicitlyRefusedUntilRecoveryExists` required the string "restore mode is disabled until durable restore recovery is implemented". That refusal was the stand-in until this recovery existed. The replacement, `testRestoreModeRunsJournalDetachesBeforeActiveAndSkipsMountRecovery`, requires the journaled transaction, detach-before-active, no mount session, and the unchanged Linux mount-mode error "launch requires macOS hdiutil and Launch Services". No other existing assertion was removed or weakened.

21. **The in-use probe ignores our own launcher.** `ps` matches the destination path in both `/var/...` and `/private/var/...` spellings. A command counts only when it is not an ancestor of the caller and its executable is not `isenough` or `isenough-stub`. The stub that is performing the launch lives at `<dest>/Contents/MacOS/isenough-stub`, so its argv contains the destination; that is not a foreign user. The restored app and helpers such as `tail -f <dest>/Contents/Info.plist` still count as busy.
