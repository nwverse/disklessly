import XCTest
import Foundation
@testable import DisklesslyCore
@testable import DisklesslyEngine
import DisklesslySessions

final class StreamingUploadTests: XCTestCase {
    // Offloads go through the free-limit check, which is switched off by default for now.
    override class func setUp() { super.setUp(); License.limitOverride = true }
    override class func tearDown() { License.limitOverride = nil; super.tearDown() }

    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("disklessly-stream-up-\(UUID().uuidString)")
        root = URL(fileURLWithPath: SessionPaths.canonical(root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func engine() throws -> DisklesslyEngine {
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        config.minFreeBytes = 0
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.homeOverride = home.path
        engine.offloadedOverride = { [] }
        engine.fileOpenOverride = { _, _ in false }
        try FileManager.default.createDirectory(atPath: config.repoPath, withIntermediateDirectories: true)
        _ = try RepoIdentity.ensure(try engine.repo)
        return engine
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        }
        try data.write(to: url)
    }

    private func hexOf(_ data: Data) -> String { SHA256Digest.hex(data) }

    // MARK: Backend

    func testPutStreamThenMovePreservesBytesAndSha() throws {
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("backend"))
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sha = hexOf(payload)
        try backend.putStream("files/staging/one.part") { handle in
            // Write in pieces, as the archive writer does.
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 4096, payload.count)
                try handle.write(contentsOf: payload.subdata(in: offset..<end))
                offset = end
            }
        }
        let object = "files/objects/\(sha).bin"
        try backend.move("files/staging/one.part", to: object)

        let stored = try backend.get(object, range: nil)
        XCTAssertEqual(stored, payload)
        XCTAssertEqual(hexOf(stored), sha)
    }

    func testStagingObjectIsGoneAfterMove() throws {
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("backend"))
        try backend.putStream("files/staging/two.part") { try $0.write(contentsOf: Data("staged".utf8)) }
        XCTAssertNotNil(try backend.stat("files/staging/two.part"))
        try backend.move("files/staging/two.part", to: "files/objects/two.bin")
        XCTAssertNil(try backend.stat("files/staging/two.part"), "the staging name must not remain after the move")
        XCTAssertEqual(try backend.get("files/objects/two.bin", range: nil), Data("staged".utf8))
    }

    // MARK: Reuse

    func testSameShaObjectIsReusedAndStagingIsDeleted() throws {
        let engine = try engine()
        let backend = try engine.repo
        try backend.ensureCollection("files")
        try backend.ensureCollection("files/objects")
        try backend.ensureCollection("files/staging")

        let payload = Data("identical archive bytes".utf8)
        let sha = hexOf(payload)
        let object = FilePlaceholder.objectPath(sha256: sha, kind: .folder)
        try backend.put(object, data: payload)

        let staging = "files/staging/reuse-\(UUID().uuidString.lowercased()).part"
        try backend.putStream(staging) { try $0.write(contentsOf: payload) }
        let reused = try engine.publishStreamed(backend, staging: staging, object: object, sha: sha, stored: UInt64(payload.count))

        XCTAssertTrue(reused, "an existing object with the same sha is reused")
        XCTAssertNil(try backend.stat(staging), "the duplicate staging copy is deleted")
        XCTAssertEqual(try backend.get(object, range: nil), payload)
    }

    func testDifferentBytesAtTheObjectNameAreNeverOverwritten() throws {
        let engine = try engine()
        let backend = try engine.repo
        try backend.ensureCollection("files/objects")
        try backend.ensureCollection("files/staging")

        let payload = Data("the real archive".utf8)
        let sha = hexOf(payload)
        let object = FilePlaceholder.objectPath(sha256: sha, kind: .folder)
        // Someone else's bytes sit under this name.
        try backend.put(object, data: Data("other bytes".utf8))

        let staging = "files/staging/clash-\(UUID().uuidString.lowercased()).part"
        try backend.putStream(staging) { try $0.write(contentsOf: payload) }
        XCTAssertThrowsError(try engine.publishStreamed(backend, staging: staging, object: object, sha: sha, stored: UInt64(payload.count)))
        XCTAssertEqual(try backend.get(object, range: nil), Data("other bytes".utf8), "the existing object is untouched")
        XCTAssertNil(try backend.stat(staging), "the staging copy is cleaned up")
    }

    // MARK: Folder offload

    func testFolderOffloadLeavesNoArchiveInTheCache() throws {
        let engine = try engine()
        try write("Documents/Streamed/a.txt", bytes: 2_000)
        try write("Documents/Streamed/nested/b.bin", bytes: 150_000)
        let folder = home.appendingPathComponent("Documents/Streamed")

        let result = try engine.offloadFile(folder.path)
        XCTAssertEqual(result.placeholder.kind, .folder)

        let cacheDir = root.appendingPathComponent("cache").path
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir)) ?? []
        XCTAssertTrue(cached.filter { $0.hasSuffix(".zst") || $0.hasPrefix("offload-") }.isEmpty, "no archive may be written to the cache: \(cached)")

        let repoPath = root.appendingPathComponent("repo").path
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: repoPath + "/files/staging")) ?? []
        XCTAssertTrue(staged.isEmpty, "no staging object may remain: \(staged)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoPath + "/" + result.placeholder.object))
    }
}
