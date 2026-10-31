import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

/// Evict honors pins, `detach APP`, and the orphan mount reaper.
final class LifecycleTests: XCTestCase {
    /// A fake disk-image tool and process probe. Mounts are a set of paths.
    final class FakeMounts {
        var mounted: Set<String> = []
        var listed: [String] = []
        var busy: Set<String> = []
        var detachCalls: [(String, Bool)] = []
        var failDetach = false
        var ops: MountOps {
            MountOps(
                listMounted: { [unowned self] in self.listed + Array(self.mounted) },
                isMounted: { [unowned self] in self.mounted.contains(MountReaper.canonical($0)) },
                detach: { [unowned self] path, force in
                    self.detachCalls.append((MountReaper.canonical(path), force))
                    if self.failDetach { throw DisklesslyError.diskImage("resource busy") }
                    self.mounted.remove(MountReaper.canonical(path))
                },
                usage: { [unowned self] in self.busy.contains(MountReaper.canonical($0)) ? .busy : .clean }
            )
        }
    }

    var root: URL!
    var fake: FakeMounts!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-life-\(UUID().uuidString)")
        fake = FakeMounts()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    var mountRoot: URL { root.appendingPathComponent("mnt") }

    func makeEngine() throws -> DisklesslyEngine {
        for dir in ["repo", "cache/images", "state", "mnt", "apps"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        var engine = DisklesslyEngine(config: RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: mountRoot.path, stubDir: root.appendingPathComponent("apps").path), secrets: MemorySecretStore())
        engine.mountOpsOverride = fake.ops
        return engine
    }

    func manifest(_ id: String) -> ImageManifest {
        let image = ImageManifest.Image(file: "images/\(id).dmg", format: "ULMO", sha256: String(repeating: "ab", count: 32), size: 3, volumeName: id, appPathInVolume: "\(id).app")
        return ImageManifest(bundleId: "com.example.\(id)", name: id, version: "1", image: image, app: .init(originalPath: "/Applications/\(id).app", executable: id, documentTypes: [], urlTypes: []), mode: .mount, imageId: id)
    }

    func cache(_ engine: DisklesslyEngine, _ id: String) throws -> URL {
        let url = URL(fileURLWithPath: engine.config.cacheDir).appendingPathComponent("images/\(id).dmg")
        try Data("dmg".utf8).write(to: url)
        return url
    }

    /// A mount folder under the root that the fake reports as mounted.
    func mount(_ name: String) throws -> String {
        let dir = mountRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = MountReaper.canonical(dir.path)
        fake.mounted.insert(path)
        return path
    }

    // MARK: evict

    func testEvictRefusesPinnedUnlessForced() throws {
        let engine = try makeEngine()
        let m = manifest("pinme")
        let file = try cache(engine, "pinme")
        try StateStore(engine.config.stateDir).update { $0.apps[m.bundleId] = AppState(imageId: m.imageId, pinned: true) }
        let refusal = try XCTUnwrap(engine.evictRefusal(m, force: false))
        XCTAssertEqual(refusal.reason, "pinned")
        XCTAssertEqual(refusal.error.exitCode, 9)
        XCTAssertThrowsError(try engine.evict(m)) { XCTAssertEqual(($0 as? DisklesslyError)?.exitCode, 9) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(engine.evictRefusal(m, force: true))
        try engine.evict(m, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(StateStore(engine.config.stateDir).load().apps[m.bundleId]?.pinned, true, "--force evicts but keeps the pin")
    }

    func testEvictForceStillRefusesMountedImage() throws {
        let engine = try makeEngine()
        let m = manifest("mounted")
        let file = try cache(engine, "mounted")
        _ = try mount("mounted")
        let refusal = try XCTUnwrap(engine.evictRefusal(m, force: true))
        XCTAssertEqual(refusal.reason, "mounted")
        XCTAssertThrowsError(try engine.evict(m, force: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testQuotaEvictionNeverTouchesPinned() throws {
        var engine = try makeEngine()
        engine.config.quotaBytes = 1
        let pinned = manifest("keep")
        let loose = manifest("drop")
        let kept = try cache(engine, "keep")
        let dropped = try cache(engine, "drop")
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try StateStore(engine.config.stateDir).update { state in
            state.apps[pinned.bundleId] = AppState(imageId: "keep", state: "cached", lastUsed: old, pinned: true)
            state.apps[loose.bundleId] = AppState(imageId: "drop", state: "cached", lastUsed: old.addingTimeInterval(10))
        }
        _ = try engine.enforceCacheQuota(justUsed: nil, now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path))
    }

    // MARK: detach

    func testDetachIdleMountDetachesAndMarksCached() throws {
        let engine = try makeEngine()
        let m = manifest("idle")
        let path = try mount("idle")
        try StateStore(engine.config.stateDir).setAppState(bundleId: m.bundleId, imageId: m.imageId, state: "backoff", mountPoint: path)
        let report = try engine.detach(m)
        XCTAssertEqual(report.outcome, .detached)
        XCTAssertFalse(report.forced)
        XCTAssertEqual(fake.detachCalls.map(\.0), [path])
        XCTAssertEqual(fake.detachCalls.map(\.1), [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "empty mount folder is removed")
        let app = StateStore(engine.config.stateDir).load().apps[m.bundleId]
        XCTAssertEqual(app?.state, "cached")
        XCTAssertNil(app?.mountPoint)
    }

    func testDetachRefusesRunningAppEvenWithForce() throws {
        let engine = try makeEngine()
        let m = manifest("busy")
        let path = try mount("busy")
        fake.busy.insert(path)
        XCTAssertEqual(engine.detachRefusal(m)?.reason, "app_running")
        XCTAssertThrowsError(try engine.detach(m, force: true)) { XCTAssertEqual(($0 as? DisklesslyError)?.exitCode, 9) }
        XCTAssertTrue(fake.detachCalls.isEmpty)
        XCTAssertTrue(fake.mounted.contains(path))
    }

    func testDetachForceUsesForcedToolAndFailureIsDiskImageError() throws {
        let engine = try makeEngine()
        let m = manifest("stuck")
        _ = try mount("stuck")
        fake.failDetach = true
        XCTAssertThrowsError(try engine.detach(m)) { XCTAssertEqual(($0 as? DisklesslyError)?.exitCode, 6) }
        fake.failDetach = false
        let report = try engine.detach(m, force: true)
        XCTAssertTrue(report.forced)
        XCTAssertEqual(fake.detachCalls.map(\.1), [false, true])
    }

    func testDetachNotMountedClearsStaleRecord() throws {
        let engine = try makeEngine()
        let m = manifest("gone")
        let path = MountReaper.canonical(mountRoot.appendingPathComponent("gone").path)
        try StateStore(engine.config.stateDir).setAppState(bundleId: m.bundleId, imageId: m.imageId, state: "stuck", mountPoint: path)
        let report = try engine.detach(m)
        XCTAssertEqual(report.outcome, .notMounted)
        XCTAssertTrue(fake.detachCalls.isEmpty)
        XCTAssertEqual(StateStore(engine.config.stateDir).load().apps[m.bundleId]?.state, "cached")
    }

    func testDetachRefusesRecordedMountOutsideRoot() throws {
        let engine = try makeEngine()
        let m = manifest("elsewhere")
        let outside = root.appendingPathComponent("Volumes/elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        fake.mounted.insert(MountReaper.canonical(outside.path))
        try StateStore(engine.config.stateDir).setAppState(bundleId: m.bundleId, imageId: m.imageId, state: "running", mountPoint: outside.path)
        XCTAssertEqual(engine.detachRefusal(m)?.reason, "not_ours")
        XCTAssertThrowsError(try engine.detach(m, force: true))
        XCTAssertTrue(fake.detachCalls.isEmpty)
    }

    // MARK: reaper

    func testReaperDetachesIdleOrphansOnlyUnderMountRoot() throws {
        let engine = try makeEngine()
        let orphan = try mount("orphan")
        let busy = try mount("inuse")
        fake.busy.insert(busy)
        // Attached elsewhere: listed by hdiutil, never ours.
        fake.listed = ["/Volumes/Other", MountReaper.canonical(root.appendingPathComponent("elsewhere/x").path), MountReaper.canonical(mountRoot.path), mountRoot.appendingPathComponent("a/b").path]
        try StateStore(engine.config.stateDir).setAppState(bundleId: "com.example.orphan", imageId: "orphan", state: "running", mountPoint: orphan)

        let preview = engine.reapOrphanMounts(dryRun: true)
        XCTAssertEqual(preview.wouldDetach, [orphan])
        XCTAssertTrue(fake.detachCalls.isEmpty)

        let report = engine.reapOrphanMounts()
        XCTAssertEqual(report.detached, [orphan])
        XCTAssertEqual(report.skipped.map(\.path), [busy])
        XCTAssertEqual(fake.detachCalls.map(\.0), [orphan])
        XCTAssertEqual(fake.detachCalls.map(\.1), [false], "the reaper never forces")
        XCTAssertEqual(StateStore(engine.config.stateDir).load().apps["com.example.orphan"]?.state, "cached")
    }

    func testReaperSkipsLeasedAndLockedAndRestoreMounts() throws {
        let engine = try makeEngine()
        let leased = try mount("leased")
        let locked = try mount("locked")
        _ = try mount("restore-tx1")
        var lease = try XCTUnwrap(MountLease.tryAcquire(stateDir: engine.config.stateDir, name: "leased"))
        defer { lease.release() }
        try StateStore(engine.config.stateDir).setAppState(bundleId: "com.example.locked", imageId: "locked", state: "running", mountPoint: locked)
        let lockURL = URL(fileURLWithPath: engine.config.stateDir).appendingPathComponent("locks/app/com.example.locked.lock")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var appLock = FileLock(path: lockURL.path)
        XCTAssertTrue(try appLock.tryLock())
        defer { appLock.unlock() }
        var journal = RestoreJournal(txid: "tx1", appId: "com.example.r", imageId: "r", owner: ProcessOwner.current(), dest: "/tmp/r.app", staging: "/tmp/r.staging", imagePath: "/tmp/r.dmg", imageFile: "images/r.dmg", appName: "r", stubBundleId: "com.example.r.stub", executable: "r", manifestCdhash: "c", manifestTreeHash: "t", imageSha256: "s")
        journal.mountPath = mountRoot.appendingPathComponent("restore-tx1").path
        try JournalStore.save(journal, stateDir: engine.config.stateDir)

        let report = engine.reapOrphanMounts()
        XCTAssertTrue(report.detached.isEmpty, "\(report)")
        XCTAssertEqual(Set(report.skipped.map { ($0.path as NSString).lastPathComponent }), ["leased", "locked", "restore-tx1"])
        XCTAssertTrue(fake.detachCalls.isEmpty)
        XCTAssertTrue(fake.mounted.contains(leased))

        lease.release()
        appLock.unlock()
        let second = engine.reapOrphanMounts(excluding: ["restore-tx1"])
        XCTAssertEqual(Set(second.detached.map { ($0 as NSString).lastPathComponent }), ["leased", "locked"])
    }

    func testReaperReportsFailedDetach() throws {
        let engine = try makeEngine()
        _ = try mount("wedged")
        fake.failDetach = true
        let report = engine.reapOrphanMounts()
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.jsonObject()["ok"] as? Bool, false)
    }

    /// A mount root that is a symlink to another volume: plain folders seen
    /// through it are not mounts, and nothing hdiutil does not list is detached.
    func testReaperIgnoresPlainFoldersUnderSymlinkedRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-mnt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev")
        XCTAssertFalse(DisklesslyEngine.isActiveMountPoint(link.appendingPathComponent("null").path))
        var engine = try makeEngine()
        engine.config.mountRoot = link.path
        var detached: [String] = []
        engine.mountOpsOverride = MountOps(listMounted: { [] }, isMounted: { DisklesslyEngine.isActiveMountPoint($0) }, detach: { path, _ in detached.append(path) }, usage: { _ in .clean })
        let report = engine.reapOrphanMounts(deep: false)
        XCTAssertTrue(detached.isEmpty, "\(detached)")
        XCTAssertTrue(report.detached.isEmpty && report.failed.isEmpty, "\(report)")
    }

    func testReaperFailsClosedOnUnreadableJournal() throws {
        let engine = try makeEngine()
        let restoreMount = try mount("restore-tx9")
        let plain = try mount("plain")
        let dir = URL(fileURLWithPath: engine.config.stateDir).appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{truncated".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let report = engine.reapOrphanMounts()
        XCTAssertEqual(report.detached, [plain])
        XCTAssertEqual(report.skipped.map(\.path), [restoreMount])
        XCTAssertTrue(fake.mounted.contains(restoreMount))
    }

    func testReaperBacksOffAfterFailureAndHidesSkipsFromActionLines() throws {
        let engine = try makeEngine()
        let wedged = try mount("wedged")
        let leased = try mount("leased")
        var lease = try XCTUnwrap(MountLease.tryAcquire(stateDir: engine.config.stateDir, name: "leased"))
        defer { lease.release() }
        fake.failDetach = true
        let first = engine.reapOrphanMounts(deep: false, retryAfter: 600)
        XCTAssertEqual(first.failed.map(\.path), [wedged])
        XCTAssertEqual(first.skipped.map(\.path), [leased])
        XCTAssertEqual(first.actionLines.count, 1, "kept mounts are diagnostics, not actions")
        XCTAssertEqual(first.lines.count, 2)
        let second = engine.reapOrphanMounts(deep: false, retryAfter: 600)
        XCTAssertEqual(fake.detachCalls.count, 1, "a recent failure is not retried on launch")
        XCTAssertTrue(second.actionLines.isEmpty)
        fake.failDetach = false
        let manual = engine.reapOrphanMounts()
        XCTAssertEqual(manual.detached, [wedged], "an explicit reap still retries")
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: engine.config.stateDir).appendingPathComponent("reap-failures.json").path))
    }

    func testChildNameAndHdiutilInfoParsing() {
        XCTAssertEqual(MountReaper.childName("/tmp/root/abc", mountRoot: "/private/tmp/root"), "abc")
        XCTAssertEqual(MountReaper.childName("/private/tmp/root/abc/", mountRoot: "/tmp/root/"), "abc")
        XCTAssertNil(MountReaper.childName("/tmp/root", mountRoot: "/tmp/root"))
        XCTAssertNil(MountReaper.childName("/tmp/root/a/b", mountRoot: "/tmp/root"))
        XCTAssertNil(MountReaper.childName("/tmp/rootx/a", mountRoot: "/tmp/root"))
        XCTAssertNil(MountReaper.childName("/Volumes/X", mountRoot: ""))
        XCTAssertNil(MountReaper.childName("/a", mountRoot: "/"))
        let plist: [String: Any] = ["images": [
            ["image-path": "/c/a.dmg", "system-entities": [["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1", "mount-point": "/m/a"]]],
            ["image-path": "/c/b.dmg", "system-entities": [["dev-entry": "/dev/disk10s1", "mount-point": "/Volumes/B"]]],
        ]]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(MountReaper.mountPoints(hdiutilInfo: Data("noise\n".utf8) + data), ["/m/a", "/Volumes/B"])
        XCTAssertEqual(MountReaper.mountPoints(hdiutilInfo: Data("garbage".utf8)), [])
    }

    func testMountLeaseExcludesSecondHolder() throws {
        let state = root.appendingPathComponent("state").path
        var first = try XCTUnwrap(MountLease.tryAcquire(stateDir: state, name: "x"))
        XCTAssertNil(MountLease.tryAcquire(stateDir: state, name: "x"))
        XCTAssertNil(MountLease.acquire(stateDir: state, name: "x", waitSeconds: 0.1))
        first.release()
        var again = try XCTUnwrap(MountLease.acquire(stateDir: state, name: "x", waitSeconds: 0.1))
        again.release()
    }

    #if os(macOS)
    /// Real hdiutil: attach a tiny image under the mount root, leave it as a
    /// crashed watcher would, and let the reaper and `detach` take it down.
    func testRealAttachIsReapedAndDetached() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") else { throw XCTSkip("no hdiutil") }
        var engine = try makeEngine()
        engine.mountOpsOverride = nil
        let src = root.appendingPathComponent("src/Fixture.app/Contents")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: src.appendingPathComponent("Info.plist"))
        let dmg = root.appendingPathComponent("fixture.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-quiet", "-srcfolder", root.appendingPathComponent("src").path, "-format", "UDZO", "-volname", "Fixture", "-o", dmg.path]
        try create.run(); create.waitUntilExit()
        guard create.terminationStatus == 0 else { throw XCTSkip("hdiutil create failed (\(create.terminationStatus))") }

        func attach(_ name: String) throws -> URL {
            let mount = mountRoot.appendingPathComponent(name).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            do { try LiveDiskImage.attach(image: dmg, mountPoint: mount) } catch { throw XCTSkip("attach unavailable here: \(error)") }
            return mount
        }
        let orphan = try attach("orphan-image")
        addTeardownBlock { try? LiveDiskImage.detach(mountPoint: orphan, force: true) }
        XCTAssertTrue(DisklesslyEngine.isActiveMountPoint(orphan.path))
        XCTAssertTrue(MountOps.live.listMounted().contains { MountReaper.childName($0, mountRoot: self.mountRoot.path) == "orphan-image" })
        let report = engine.reapOrphanMounts()
        XCTAssertEqual(report.detached.map { ($0 as NSString).lastPathComponent }, ["orphan-image"], "\(report)")
        XCTAssertFalse(DisklesslyEngine.isActiveMountPoint(orphan.path))

        let m = manifest("detach-me")
        let mounted = try attach("detach-me")
        addTeardownBlock { try? LiveDiskImage.detach(mountPoint: mounted, force: true) }
        try StateStore(engine.config.stateDir).setAppState(bundleId: m.bundleId, imageId: m.imageId, state: "backoff", mountPoint: mounted.path)
        XCTAssertEqual(try engine.detach(m).outcome, .detached)
        XCTAssertFalse(DisklesslyEngine.isActiveMountPoint(mounted.path))
        XCTAssertEqual(StateStore(engine.config.stateDir).load().apps[m.bundleId]?.state, "cached")
    }
    #endif
}
