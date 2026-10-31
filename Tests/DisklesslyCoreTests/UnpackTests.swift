import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class UnpackTests: XCTestCase {
    func testUnpackReplacesStubWithVerifiedApp() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        try markStub(world)
        try world.engine.register(world.manifest, backend: try world.engine.repo, now: Date(timeIntervalSince1970: 1_700_000_000))
        let image = URL(fileURLWithPath: world.engine.config.repoPath).appendingPathComponent(world.manifest.image.file)
        let before = try Data(contentsOf: image)
        try world.engine.unpack(world.manifest)
        XCTAssertEqual(world.bundleID(at: world.dest), world.bundleID)
        XCTAssertEqual(try BundleHasher.treeHash(of: world.dest), world.manifest.app.treeHash)
        let journalDir = URL(fileURLWithPath: world.engine.config.stateDir).appendingPathComponent("unpack-journals")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: journalDir.path)) ?? []
        XCTAssertEqual(names, [])
        let state = StateStore(world.engine.config.stateDir).load()
        XCTAssertEqual(state.apps[world.bundleID]?.state, "unpacked")
        let record = try world.engine.ownDeviceRecord()
        XCTAssertFalse(record?.images.contains { $0.bundleId == world.bundleID } ?? false)
        XCTAssertEqual(try Data(contentsOf: image), before)
    }

    func testUnpackRefusesWhenTreeHashMismatch() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        try markStub(world)
        world.trace.corruptExtraction = true
        XCTAssertThrowsError(try world.engine.unpack(world.manifest)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5)
        }
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
        let parent = world.dest.deletingLastPathComponent()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".disklessly-unpack-") })
    }

    func testUnpackFaultAtEveryPhaseRecovers() throws {
        let phases = ["prepared", "extracted", "stubParked", "installed", "stubDeleted"]
        let edges = ["afterJournal", "afterMutation"]
        for phase in phases {
            for edge in edges {
                let world = try RestoreWorld()
                defer { world.cleanup() }
                try markStub(world)
                world.engine.faults.mode = .raised
                world.engine.faults.points = ["unpack.\(phase):\(edge)"]
                XCTAssertThrowsError(try world.engine.unpack(world.manifest), "\(phase) \(edge)") { error in
                    XCTAssertTrue(error is InjectedFault, "\(phase) \(edge) \(error)")
                }
                world.engine.faults.mode = .off
                world.engine.faults.points = []
                _ = try world.engine.recoverUnpackJournals()
                let id = world.bundleID(at: world.dest)
                XCTAssertTrue(id == world.bundleID || id == world.stubBundleID, "\(phase) \(edge) left \(id ?? "nothing")")
                if id == world.bundleID {
                    XCTAssertEqual(try BundleHasher.treeHash(of: world.dest), world.manifest.app.treeHash, "\(phase) \(edge)")
                }
                let before = id
                let second = try world.engine.recoverUnpackJournals()
                XCTAssertEqual(world.bundleID(at: world.dest), before, "\(phase) \(edge)")
                XCTAssertTrue(second.isEmpty || second.allSatisfy { $0.hasPrefix("noop ") }, "\(phase) \(edge) \(second)")
            }
        }
    }

    func testUnpackRefusesWhileRestoreActive() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.engine.faults.mode = .raised
        world.engine.faults.points = ["active:afterJournal"]
        XCTAssertThrowsError(try world.launch(wait: true))
        world.engine.faults.mode = .off
        world.engine.faults.points = []
        let before = world.bundleID(at: world.dest)
        XCTAssertThrowsError(try world.engine.unpack(world.manifest)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 9)
        }
        XCTAssertEqual(world.bundleID(at: world.dest), before)
    }

    func testUnpackToDirLeavesStub() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        try markStub(world)
        try world.engine.register(world.manifest, backend: try world.engine.repo, now: Date(timeIntervalSince1970: 1_700_000_000))
        let before = try world.engine.ownDeviceRecord()
        let directory = world.root.appendingPathComponent("exported")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try world.engine.unpack(world.manifest, to: directory.path)
        let copied = directory.appendingPathComponent("Foo.app")
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
        XCTAssertEqual(world.bundleID(at: copied), world.bundleID)
        XCTAssertEqual(try BundleHasher.treeHash(of: copied), world.manifest.app.treeHash)
        let after = try world.engine.ownDeviceRecord()
        XCTAssertEqual(after?.images.map(\.imageId), before?.images.map(\.imageId))
        XCTAssertThrowsError(try world.engine.unpack(world.manifest, to: directory.path)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
    }

    func testUnpackRecoveryTable() {
        XCTAssertEqual(UnpackRecovery.decide(phase: "prepared", destIsStub: true, destIsApp: false, appNewVerified: false, parkedStubExists: false), .rollback)
        XCTAssertEqual(UnpackRecovery.decide(phase: "extracted", destIsStub: true, destIsApp: false, appNewVerified: true, parkedStubExists: false), .rollback)
        XCTAssertEqual(UnpackRecovery.decide(phase: "stubParked", destIsStub: false, destIsApp: false, appNewVerified: true, parkedStubExists: true), .installAndFinish)
        XCTAssertEqual(UnpackRecovery.decide(phase: "stubParked", destIsStub: false, destIsApp: false, appNewVerified: false, parkedStubExists: true), .restoreStub)
        XCTAssertEqual(UnpackRecovery.decide(phase: "installed", destIsStub: false, destIsApp: true, appNewVerified: false, parkedStubExists: true), .deleteParkedStub)
        XCTAssertEqual(UnpackRecovery.decide(phase: "stubDeleted", destIsStub: false, destIsApp: true, appNewVerified: false, parkedStubExists: false), .deleteParkedStub)
        XCTAssertEqual(UnpackRecovery.decide(phase: "prepared", destIsStub: false, destIsApp: false, appNewVerified: false, parkedStubExists: false), .needsAttention)
        XCTAssertEqual(UnpackRecovery.decide(phase: "stubParked", destIsStub: true, destIsApp: false, appNewVerified: true, parkedStubExists: false), .needsAttention)
        XCTAssertEqual(UnpackRecovery.decide(phase: "installed", destIsStub: false, destIsApp: false, appNewVerified: false, parkedStubExists: false), .needsAttention)
        XCTAssertThrowsError(try UnpackArguments.parse(["App", "--delete-remote"])) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }
    }

    private func markStub(_ world: RestoreWorld) throws {
        let resources = world.dest.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let object: [String: Any] = ["schema": "stub/1", "appId": world.bundleID, "imageId": world.manifest.imageId]
        try JSONSerialization.data(withJSONObject: object).write(to: resources.appendingPathComponent("stub.json"))
    }
}
