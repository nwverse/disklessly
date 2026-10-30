# Release checklist

Before tagging a release (for example 0.1.0):

- [x] Fold each "landing now" item that shipped into the normal docs (done on
      release/v0.1 once evict --force, detach, reap and repo-scoped stubs merged).
      `ReleaseAssetsTests.testLandingNowSectionsAreGoneOnceReleased` guards against
      the markers coming back once the CHANGELOG entry is dated.
- [ ] Check every command the docs mention against `isenough help` on the release build.
- [ ] Replace `Unreleased` in the CHANGELOG version heading with the release date.
