import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

extension RestoreWorld {
    /// A Mach-O the stub rebuild can copy and sign. Lives inside this world's temp root.
    func fakeLauncher() throws -> URL {
        let fm = FileManager.default
        let url = root.appendingPathComponent("bin/disklessly-stub")
        if fm.isExecutableFile(atPath: url.path) { return url }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(macOS)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url)
        #else
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        #endif
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Point stub rebuilds at `fakeLauncher()` instead of the test runner's directory.
    func useFakeLauncher() throws {
        let launcher = try fakeLauncher()
        let config = engine.config
        engine.restore.services.buildStub = { dest, journal in
            try StubRebuilder.write(at: dest, journal: journal, config: config, environment: ["DISKLESSLY_STUB_BINARY": launcher.path], cli: URL(fileURLWithPath: "/nonexistent/disklessly"))
        }
    }

    /// Leave a restore journal in `stubBack` with the parked stub deleted, so the
    /// next recovery step has to rebuild the stub.
    func strandWithoutParkedStub() throws -> RestoreJournal {
        arm("stubBack", "afterJournal")
        XCTAssertThrowsError(try launch(wait: true))
        disarm()
        let journal = try XCTUnwrap(journals().first)
        XCTAssertEqual(journal.phase, .stubBack)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: journal.staging).appendingPathComponent("stub.app"))
        return journal
    }
}

final class StubRebuilderTests: XCTestCase {
    func testMissingLauncherReportsNeedsAttentionAndWritesNothing() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        let journal = try world.strandWithoutParkedStub()
        let config = world.engine.config
        world.engine.restore.services.buildStub = { dest, journal in
            try StubRebuilder.write(at: dest, journal: journal, config: config, environment: [:], cli: URL(fileURLWithPath: "/nonexistent/disklessly"))
        }
        let result = try world.recover(wait: true)
        guard case .rejected(let message) = result else {
            XCTFail("expected needs attention, got \(result)")
            return
        }
        XCTAssertTrue(message.contains("needs attention"), message)
        XCTAssertTrue(world.engine.restore.events.contains("stubRegenerationFailed"))
        XCTAssertFalse(world.engine.restore.events.contains("stubRegenerated"))
        // No placeholder stub at dest, and the app is still safe in staging.
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.dest.path))
        let old = URL(fileURLWithPath: journal.staging).appendingPathComponent("app.old")
        XCTAssertEqual(world.bundleID(at: old), world.bundleID)
        XCTAssertEqual(world.journals().first?.waitReason, "needsAttention")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: world.dest.deletingLastPathComponent().path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".disklessly-stub-") }, "\(leftovers)")
    }

    func testRebuildNeverWritesAnExitZeroLauncher() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        let journal = try world.strandWithoutParkedStub()
        let dest = world.root.appendingPathComponent("Applications/Other.app")
        XCTAssertThrowsError(try StubRebuilder.write(at: dest, journal: journal, config: world.engine.config, environment: [:], cli: URL(fileURLWithPath: "/nonexistent/disklessly")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testRebuildEmbedsLocalManifestWithoutReadingRepo() throws {
        #if !os(macOS)
        throw XCTSkip("stubs are macOS app bundles; the Linux build writes none")
        #endif
        let world = try RestoreWorld()
        defer { world.cleanup() }
        let journal = try world.strandWithoutParkedStub()
        // The repo copy is gone. The rebuild uses the copy staged with the journal.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: world.engine.config.repoPath).appendingPathComponent("manifests"))
        let launcher = try world.fakeLauncher()
        try StubRebuilder.write(at: world.dest, journal: journal, config: world.engine.config, environment: ["DISKLESSLY_STUB_BINARY": launcher.path], cli: URL(fileURLWithPath: "/nonexistent/disklessly"))
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
        let embedded = try ImageManifest.decode(Data(contentsOf: world.dest.appendingPathComponent("Contents/Resources/manifest.json")))
        XCTAssertEqual(embedded.imageId, world.manifest.imageId)
        XCTAssertEqual(embedded.bundleId, world.bundleID)
        let exe = world.dest.appendingPathComponent("Contents/MacOS/disklessly-stub")
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: exe.path, andPath: launcher.path) || FileManager.default.isExecutableFile(atPath: exe.path))
        XCTAssertFalse((try? String(contentsOf: exe, encoding: .utf8))?.contains("exit 0") ?? false)
        #if os(macOS)
        XCTAssertTrue(BundleHasher.signatureValid(world.dest))
        #endif
    }

    func testRebuildFallsBackToCachedManifest() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        let journal = try world.strandWithoutParkedStub()
        try FileManager.default.removeItem(at: URL(fileURLWithPath: journal.staging).appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: world.engine.config.repoPath).appendingPathComponent("manifests"))
        XCTAssertNotNil(StubRebuilder.manifestData(journal: journal, config: world.engine.config))
        let cached = StubManifestCache.url(imageId: journal.imageId, cacheDir: world.engine.config.cacheDir)
        try FileManager.default.removeItem(at: cached)
        XCTAssertNil(StubRebuilder.manifestData(journal: journal, config: world.engine.config))
        let launcher = try world.fakeLauncher()
        XCTAssertThrowsError(try StubRebuilder.write(at: world.dest, journal: journal, config: world.engine.config, environment: ["DISKLESSLY_STUB_BINARY": launcher.path], cli: URL(fileURLWithPath: "/nonexistent/disklessly")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.dest.path))
    }

    #if os(macOS)
    func testCodesignFailureIsReportedAndLeavesDestEmpty() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        let journal = try world.strandWithoutParkedStub()
        var config = world.engine.config
        config.signIdentity = "disklessly test identity that does not exist"
        let launcher = try world.fakeLauncher()
        XCTAssertThrowsError(try StubRebuilder.write(at: world.dest, journal: journal, config: config, environment: ["DISKLESSLY_STUB_BINARY": launcher.path], cli: URL(fileURLWithPath: "/nonexistent/disklessly")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.dest.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: world.dest.deletingLastPathComponent().path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".disklessly-stub-") }, "\(leftovers)")
    }
    #endif
}
