// pack needs hdiutil, codesign, and app bundles: macOS only (see docs/linux.md).
#if os(macOS)
import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

private struct PlannedFailure: Error {}

/// Fixture apps only. Everything lives under one temp root, including the stub dir.
private final class PackWorld {
    let root: URL
    let apps: URL
    let source: URL
    let bundleID = "com.example.packfoo"
    var engine: DisklesslyEngine
    var usage: UsageClass = .clean

    init(swap: Bool = true) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("disklessly-pack-\(UUID().uuidString)")
        apps = root.appendingPathComponent("Applications")
        source = apps.appendingPathComponent("PackFoo.app")
        let config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mounts").path,
            stubDir: apps.path
        )
        engine = DisklesslyEngine(config: config, faults: FaultController())
        engine.stubRootsOverride = [apps]
        engine.packSwapUnsupported = !swap
        try engine.initialize()
        try RestoreWorld.writeBundle(source, bundleID: bundleID, executable: "PackFoo", body: "real-binary", extra: "resources")
        engine.packUsageOverride = { [unowned self] _ in self.usage }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    var retained: URL { apps.appendingPathComponent("PackFoo.256orig.app") }

    /// A signed-stub stand-in at the temp name `installStub` uses.
    func stageStub() throws -> URL {
        let temp = apps.appendingPathComponent(".disklessly-\(UUID().uuidString).app")
        try RestoreWorld.writeBundle(temp, bundleID: bundleID + ".256stub", executable: "disklessly-stub", body: "stub-binary")
        let resources = temp.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let object: [String: Any] = ["schema": "stub/1", "appId": bundleID, "imageId": "img-packfoo"]
        try JSONSerialization.data(withJSONObject: object).write(to: resources.appendingPathComponent("stub.json"))
        return temp
    }

    func commit(_ temp: URL, fingerprint: String? = nil, keep: Bool = false) throws -> String? {
        let print = try fingerprint ?? TreeFingerprint.of(source)
        return try engine.commitStub(staged: temp, source: source, bundleId: bundleID, name: "PackFoo", cloneFingerprint: print, keepOriginal: keep)
    }

    func kind(_ url: URL) -> PackGuard.Kind { PackGuard.kind(url, appId: bundleID) }

    func journals() throws -> [PackJournal] { try PackJournalStore.loadAll(stateDir: engine.config.stateDir) }

    /// Hidden `.disklessly-*` names left in the stub dir.
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []).filter { $0.hasPrefix(".disklessly-") }.sorted()
    }

    func originalBody(_ url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/MacOS/PackFoo"), encoding: .utf8)
    }
}

final class PackSwapTests: XCTestCase {
    func testSwapInstallsStubAndDropsOriginal() throws {
        for swap in [true, false] {
            let world = try PackWorld(swap: swap)
            defer { world.cleanup() }
            XCTAssertNil(try world.commit(try world.stageStub()))
            XCTAssertEqual(world.kind(world.source), .stub, "swap \(swap)")
            XCTAssertEqual(world.leftovers(), [], "swap \(swap)")
            XCTAssertEqual(try world.journals().count, 0, "swap \(swap)")
        }
    }

    func testFreeLimitRefusesAThirdAppBeforeTouchingIt() throws {
        let world = try PackWorld()
        defer { world.cleanup() }
        world.engine.offloadedOverride = { ["com.example.one", "com.example.two"] }
        XCTAssertThrowsError(try world.engine.pack(world.source.path)) { error in
            guard case DisklesslyError.licenseRequired(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("license activate"), message)
        }
        XCTAssertEqual(world.kind(world.source), .original, "a refused pack leaves the app alone")
        XCTAssertEqual(world.leftovers(), [])
        XCTAssertEqual(try world.journals().count, 0)
    }

    func testKeepOriginalRetainsTheApp() throws {
        for swap in [true, false] {
            let world = try PackWorld(swap: swap)
            defer { world.cleanup() }
            XCTAssertNil(try world.commit(try world.stageStub(), keep: true))
            XCTAssertEqual(world.kind(world.source), .stub)
            XCTAssertEqual(world.kind(world.retained), .original)
            XCTAssertEqual(world.originalBody(world.retained), "real-binary")
            XCTAssertEqual(world.leftovers(), [])
        }
    }

    func testCrashAtEveryPointIsRecoveredByGC() throws {
        let points: [(swap: Bool, point: String)] = [
            (true, "pack.staged:afterJournal"),
            (true, "pack.swapped:afterMutation"),
            (true, "pack.swapped:afterJournal"),
            (true, "pack.parked:afterJournal"),
            (false, "pack.staged:afterJournal"),
            (false, "pack.originalMoved:afterMutation"),
            (false, "pack.originalMoved:afterJournal"),
            (false, "pack.parked:afterJournal"),
        ]
        for keep in [false, true] {
            for (swap, point) in points {
                let label = "\(point) swap=\(swap) keep=\(keep)"
                let world = try PackWorld(swap: swap)
                defer { world.cleanup() }
                world.engine.faults.mode = .raised
                world.engine.faults.points = [point]
                XCTAssertThrowsError(try world.commit(try world.stageStub(), keep: keep), label) { error in
                    XCTAssertTrue(error is InjectedFault, "\(label) \(error)")
                }
                world.engine.faults.mode = .off
                world.engine.faults.points = []
                XCTAssertEqual(try world.journals().count, 1, label)
                _ = try world.engine.gc()
                XCTAssertEqual(try world.journals().count, 0, label)
                let kind = world.kind(world.source)
                XCTAssertTrue(kind == .original || kind == .stub, "\(label) left \(kind)")
                if kind == .original {
                    XCTAssertEqual(world.originalBody(world.source), "real-binary", label)
                } else if keep {
                    XCTAssertEqual(world.kind(world.retained), .original, label)
                }
                XCTAssertEqual(world.leftovers(), [], label)
            }
        }
    }

    func testCrashBetweenRenamesBringsTheOriginalBack() throws {
        let world = try PackWorld(swap: false)
        defer { world.cleanup() }
        world.engine.faults.mode = .raised
        world.engine.faults.points = ["pack.originalMoved:afterMutation"]
        XCTAssertThrowsError(try world.commit(try world.stageStub()))
        world.engine.faults.mode = .off
        XCTAssertEqual(world.kind(world.source), .absent)
        let lines = try world.engine.gc()
        XCTAssertTrue(lines.contains { $0.hasPrefix("restored original") }, "\(lines)")
        XCTAssertEqual(world.kind(world.source), .original)
        XCTAssertEqual(world.originalBody(world.source), "real-binary")
        XCTAssertEqual(world.leftovers(), [])
    }

    func testDoctorFixRecoversPackJournals() throws {
        let world = try PackWorld(swap: false)
        defer { world.cleanup() }
        world.engine.faults.mode = .raised
        world.engine.faults.points = ["pack.originalMoved:afterJournal"]
        XCTAssertThrowsError(try world.commit(try world.stageStub()))
        world.engine.faults.mode = .off
        _ = try world.engine.recoverLocalJournals()
        XCTAssertEqual(world.kind(world.source), .original)
        XCTAssertEqual(try world.journals().count, 0)
    }

    func testOrdinaryFailureAtEveryPointKeepsTheOriginal() throws {
        let points: [(swap: Bool, point: String, keep: Bool)] = [
            (true, "pack.staged", false),
            (true, "pack.swapped", false),
            (true, "pack.retain", true),
            (false, "pack.staged", false),
            (false, "pack.originalMoved", false),
            (false, "pack.retain", true),
        ]
        for (swap, point, keep) in points {
            let label = "\(point) swap=\(swap)"
            let world = try PackWorld(swap: swap)
            defer { world.cleanup() }
            world.engine.failureInjector = { name in if name == point { throw PlannedFailure() } }
            XCTAssertThrowsError(try world.commit(try world.stageStub(), keep: keep), label)
            XCTAssertEqual(world.kind(world.source), .original, label)
            XCTAssertEqual(world.originalBody(world.source), "real-binary", label)
            XCTAssertEqual(world.leftovers(), [], label)
            XCTAssertEqual(try world.journals().count, 0, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.retained.path), label)
        }
    }

    func testAbortsWhenSourceChangesAfterClone() throws {
        let world = try PackWorld()
        defer { world.cleanup() }
        let fingerprint = try TreeFingerprint.of(world.source)
        // An updater rewrites the app while the image is being built.
        try Data("real-binary-v2".utf8).write(to: world.source.appendingPathComponent("Contents/Resources/update.txt"))
        let temp = try world.stageStub()
        XCTAssertThrowsError(try world.commit(temp, fingerprint: fingerprint)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 9, "\(error)")
        }
        XCTAssertEqual(world.kind(world.source), .original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.source.appendingPathComponent("Contents/Resources/update.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertEqual(world.leftovers(), [])
        XCTAssertEqual(try world.journals().count, 0)
    }

    func testAbortsWhenTheAppIsRunning() throws {
        let world = try PackWorld()
        defer { world.cleanup() }
        let fingerprint = try TreeFingerprint.of(world.source)
        world.usage = .busy
        XCTAssertThrowsError(try world.commit(try world.stageStub(), fingerprint: fingerprint)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 9, "\(error)")
        }
        XCTAssertEqual(world.kind(world.source), .original)
        XCTAssertEqual(world.leftovers(), [])
    }

    func testAbortsWhileARestoreNeedsResolution() throws {
        let world = try PackWorld()
        defer { world.cleanup() }
        let fingerprint = try TreeFingerprint.of(world.source)
        try StateStore(world.engine.config.stateDir).update { state in
            var app = state.apps[world.bundleID] ?? AppState()
            app.needsResolution = ["retainedPath": .string("/nowhere"), "treeHash": .string("x")]
            state.apps[world.bundleID] = app
        }
        XCTAssertThrowsError(try world.commit(try world.stageStub(), fingerprint: fingerprint))
        XCTAssertEqual(world.kind(world.source), .original)
        XCTAssertEqual(world.leftovers(), [])
    }

    func testRefusesAStubAsTheSource() throws {
        let world = try PackWorld()
        defer { world.cleanup() }
        XCTAssertNil(try world.commit(try world.stageStub()))
        XCTAssertEqual(world.kind(world.source), .stub)
        XCTAssertThrowsError(try PackGuard.refuseStub(world.source, bundleId: world.bundleID + ".256stub")) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }
        XCTAssertThrowsError(try PackGuard.refuseStub(world.source, bundleId: world.bundleID))
        // A second swap over the stub is refused and the stub stays.
        let second = try world.stageStub()
        XCTAssertThrowsError(try world.commit(second, fingerprint: TreeFingerprint.of(world.source)))
        XCTAssertEqual(world.kind(world.source), .stub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testRecoveryLeavesAPackThatIsStillRunning() throws {
        let world = try PackWorld()
        defer { world.cleanup() }
        var notes: [String] = []
        let engine = world.engine
        world.engine.failureInjector = { name in
            if name == "pack.swapped" { notes = try engine.recoverPackJournals() }
        }
        XCTAssertNil(try world.commit(try world.stageStub()))
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes.allSatisfy { $0.contains("still running") }, "\(notes)")
        XCTAssertEqual(world.kind(world.source), .stub)
    }
}
#endif
