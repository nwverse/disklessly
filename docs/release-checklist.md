# Release checklist

Before tagging a release (for example 0.1.0):

- [ ] Fold each "landing now" item that shipped into the normal docs, and remove
      the items that did not ship. The marked sections are:
      README.md `## In this release (landing now)`,
      CHANGELOG.md `### In this release (landing now)`,
      docs/user-guide.md `## 本版本新增（开发中）` and `### New in this release (landing now)`.
      `ReleaseAssetsTests.testLandingNowSectionsAreGoneOnceReleased` fails once the
      CHANGELOG entry has a date and any of these markers remain.
- [ ] Check every command the docs mention against `isenough help` on the release build.
- [ ] Replace `Unreleased` in the CHANGELOG version heading with the release date.
