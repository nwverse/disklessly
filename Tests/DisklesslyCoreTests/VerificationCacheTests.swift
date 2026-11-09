import XCTest
import Foundation
@testable import DisklesslyCore
@testable import DisklesslyEngine
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class VerificationCacheTests: XCTestCase {
    func testArchiveHashedOncePerFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("image.dmg")
        try Data("same-bytes".utf8).write(to: file)
        let cache = ArchiveVerificationCache()
        var hashes = 0
        let hasher: (URL) throws -> String = { url in
            hashes += 1
            return try SHA256Digest.hexFile(url)
        }
        let expected = try SHA256Digest.hexFile(file)
        for _ in 0..<10 {
            XCTAssertTrue(cache.verify(url: file, expected: expected, hasher: hasher))
        }
        XCTAssertEqual(hashes, 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: file.path)
        XCTAssertTrue(cache.verify(url: file, expected: expected, hasher: hasher))
        XCTAssertEqual(hashes, 2)
    }

    func testRepoCandidateSkippedWhenNotLocal() throws {
        let config = RuntimeConfig(repoPath: "/repo", cacheDir: "/cache", stateDir: "/state", mountRoot: "/mnt", stubDir: "/apps")
        let journal = RestoreJournal(txid: "t", appId: "com.example.App", imageId: "img", owner: ProcessOwner(pid: 1, start: 1), dest: "/Applications/App.app", staging: "/tmp/stage", imagePath: "/cache/images/img.dmg", imageFile: "images/img.dmg", appName: "App", stubBundleId: "com.example.App.256stub", executable: "App", manifestCdhash: "cd", manifestTreeHash: "tree", imageSha256: String(repeating: "a", count: 64))
        let skipped = RestoreArchive.candidates(config: config, journal: journal, isLocal: { _ in false })
        XCTAssertFalse(skipped.contains { $0.path.hasPrefix("/repo") })
        let kept = RestoreArchive.candidates(config: config, journal: journal, isLocal: { _ in true })
        XCTAssertTrue(kept.contains { $0.path.hasPrefix("/repo") })
    }

    func testPrefetchSkipsHashWithStamp() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        var hashes = 0
        world.engine.hasherOverride = { url in
            hashes += 1
            return try SHA256Digest.hexFile(url)
        }
        _ = try world.engine.prefetch(world.manifest)
        let first = hashes
        XCTAssertGreaterThan(first, 0)
        _ = try world.engine.prefetch(world.manifest)
        XCTAssertEqual(hashes, first)
        let cache = URL(fileURLWithPath: world.engine.config.cacheDir).appendingPathComponent("images/\(world.manifest.imageId).dmg")
        try Data("different-bytes".utf8).write(to: cache)
        _ = try world.engine.prefetch(world.manifest)
        XCTAssertEqual(try Data(contentsOf: cache), Data("restore-image-bytes-v1".utf8))
    }

    func testInspectUsesFingerprintWhenUnchanged() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        try world.launch(wait: true)
        XCTAssertEqual(world.outcomeName, "restoredOut", world.debugDump())
        XCTAssertEqual(world.trace.treeHashed.filter { $0 == world.dest.path }.count, 0, world.debugDump())

        world.arm("active", "afterMutation")
        XCTAssertThrowsError(try world.launch(wait: true))
        world.disarm()
        XCTAssertEqual(world.bundleID(at: world.dest), world.bundleID, world.debugDump())
        world.trace.treeHashed.removeAll()
        try Data("edited".utf8).write(to: world.dest.appendingPathComponent("Contents/MacOS/Foo"))
        try world.assertTerminalStub()
        XCTAssertGreaterThanOrEqual(world.trace.treeHashed.filter { $0 == world.dest.path }.count, 1, world.debugDump())
        XCTAssertNotNil(world.needsResolution)
    }

    func testTreeFingerprintChangesOnAppendAndRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        let original = try TreeFingerprint.of(root)
        _ = try Data(contentsOf: file)
        XCTAssertEqual(try TreeFingerprint.of(root), original)
        try Data("hello!".utf8).write(to: file)
        let appended = try TreeFingerprint.of(root)
        XCTAssertNotEqual(appended, original)
        let renamed = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: file, to: renamed)
        XCTAssertNotEqual(try TreeFingerprint.of(root), appended)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: renamed.path)
        XCTAssertNotEqual(try TreeFingerprint.of(root), appended)
    }
}
