import XCTest
@testable import IsenoughCore
@testable import IsenoughEngine

private struct PlannedFailure: Error {}

final class UnpackSafetyTests: XCTestCase {
    private let failurePoints = [
        "unpack.stubParked.beforeMutation",
        "unpack.stubParked.afterMutation",
        "unpack.installed.beforeMutation",
        "unpack.installed.afterMutation",
        "unpack.stubDeleted.beforeMutation",
        "unpack.stubDeleted.afterMutation",
        "unpack.closed.beforeMutation",
    ]

    /// An ordinary failure past `stubParked` must leave dest holding the stub or the
    /// verified app, and must not strand anything that blocks the next unpack.
    func testFailureAfterStubParkedLeavesStubOrApp() throws {
        for point in failurePoints {
            let world = try makeWorld()
            defer { world.cleanup() }
            world.engine.failureInjector = { name in if name == point { throw PlannedFailure() } }
            XCTAssertThrowsError(try world.engine.unpack(world.manifest), point)
            assertDestIsStubOrApp(world, point)
            world.engine.failureInjector = nil
            _ = try world.engine.recoverUnpackJournals()
            assertDestIsStubOrApp(world, point)
            XCTAssertTrue(world.engine.unpackAttentionLines().isEmpty, "\(point) \(world.engine.unpackAttentionLines())")
            XCTAssertFalse(stagingLeft(world), point)
        }
    }

    /// When finishing the install fails too, the stub goes back.
    func testFailedInstallDuringSettlePutsStubBack() throws {
        for point in ["unpack.stubParked.afterMutation", "unpack.installed.beforeMutation"] {
            let world = try makeWorld()
            defer { world.cleanup() }
            world.engine.failureInjector = { name in
                if name == point || name == "unpack.recover.install" { throw PlannedFailure() }
            }
            XCTAssertThrowsError(try world.engine.unpack(world.manifest), point)
            XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID, point)
            XCTAssertFalse(stagingLeft(world), point)
            XCTAssertEqual(try UnpackStore.loadAll(stateDir: world.engine.config.stateDir).count, 0, point)
            // The next unpack starts clean and succeeds.
            world.engine.failureInjector = nil
            try world.engine.unpack(world.manifest)
            XCTAssertEqual(world.bundleID(at: world.dest), world.bundleID, point)
        }
    }

    func testUnpackHoldsTheAppLockUntilInstall() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let lockPath = URL(fileURLWithPath: world.engine.config.stateDir).appendingPathComponent("locks/app/\(world.bundleID).lock").path
        var heldAt: [String: Bool] = [:]
        world.engine.failureInjector = { name in
            guard name.hasSuffix(".beforeMutation") else { return }
            var probe = FileLock(path: lockPath)
            let free = try probe.tryLock()
            probe.unlock()
            heldAt[name] = !free
        }
        try world.engine.unpack(world.manifest)
        XCTAssertEqual(heldAt["unpack.stubParked.beforeMutation"], true)
        XCTAssertEqual(heldAt["unpack.installed.beforeMutation"], true)
        var after = FileLock(path: lockPath)
        XCTAssertTrue(try after.tryLock())
        after.unlock()
    }

    func testRecoveryLeavesAJournalWhoseUnpackIsStillRunning() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        var notes: [String] = []
        let engine = world.engine
        world.engine.failureInjector = { name in
            if name == "unpack.installed.beforeMutation" { notes = try engine.recoverUnpackJournals() }
        }
        try world.engine.unpack(world.manifest)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes.allSatisfy { $0.contains("still running") }, "\(notes)")
        XCTAssertEqual(world.bundleID(at: world.dest), world.bundleID)
    }

    /// Dest stops being the stub after preflight. The re-check before parking refuses
    /// and leaves whatever is at dest alone.
    func testStubIsCheckedAgainBeforeItIsMoved() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let dest = world.dest
        let extract = world.engine.services.extract
        world.engine.services.extract = { mount, path, target in
            try extract(mount, path, target)
            try FileManager.default.removeItem(at: dest)
            try RestoreWorld.writeBundle(dest, bundleID: "com.example.other", executable: "Other", body: "someone else")
        }
        XCTAssertThrowsError(try world.engine.unpack(world.manifest)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 5)
        }
        XCTAssertEqual(world.bundleID(at: dest), "com.example.other")
        XCTAssertFalse(stagingLeft(world))
        XCTAssertEqual(try UnpackStore.loadAll(stateDir: world.engine.config.stateDir).count, 0)
    }

    func testAppStartedDuringExtractionStopsTheUnpack() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let extract = world.engine.services.extract
        let trace = world.trace
        world.engine.services.extract = { mount, path, target in
            try extract(mount, path, target)
            trace.probe = .busy
        }
        world.engine.services.probe = { _ in trace.probe }
        XCTAssertThrowsError(try world.engine.unpack(world.manifest)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 9)
        }
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
        XCTAssertFalse(stagingLeft(world))
    }

    private func makeWorld() throws -> RestoreWorld {
        let world = try RestoreWorld()
        let resources = world.dest.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let object: [String: Any] = ["schema": "stub/1", "appId": world.bundleID, "imageId": world.manifest.imageId]
        try JSONSerialization.data(withJSONObject: object).write(to: resources.appendingPathComponent("stub.json"))
        world.trace.probe = .clean
        return world
    }

    private func assertDestIsStubOrApp(_ world: RestoreWorld, _ point: String, file: StaticString = #filePath, line: UInt = #line) {
        let id = world.bundleID(at: world.dest)
        XCTAssertTrue(id == world.bundleID || id == world.stubBundleID, "\(point) left \(id ?? "nothing")", file: file, line: line)
        if id == world.bundleID {
            XCTAssertEqual(try? BundleHasher.treeHash(of: world.dest), world.manifest.app.treeHash, point, file: file, line: line)
        }
    }

    private func stagingLeft(_ world: RestoreWorld) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: world.dest.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.hasPrefix(".isenough-unpack-") }
    }
}
