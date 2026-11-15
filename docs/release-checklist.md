# Release checklist

Before tagging a release (for example 0.1.0):

- [x] Fold each "landing now" item that shipped into the normal docs (done on
      release/v0.1 once evict --force, detach, reap and repo-scoped stubs merged).
      `ReleaseAssetsTests.testLandingNowSectionsAreGoneOnceReleased` guards against
      the markers coming back once the CHANGELOG entry is dated.
- [x] Check every command the docs mention against `disklessly help` on the release build
      (done for 0.3.0 on 2026-11-14; see the command list in the 0.3.0 release notes).
- [x] Replace `Unreleased` in the CHANGELOG version heading with the release date
      (0.3.0 dated 2026-11-14).
