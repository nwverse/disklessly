import XCTest
import Foundation
@testable import IsenoughCore

final class PublishExclusiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-excl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPublishExclusiveNeverReplacesAnExistingFile() throws {
        let dest = root.appendingPathComponent("images/a.dmg")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: dest)
        let temp = root.appendingPathComponent("images/.a.dmg.tmp")
        try Data("second".utf8).write(to: temp)
        XCTAssertThrowsError(try ChunkedIO.publishExclusive(temp: temp, dest: dest)) { error in
            XCTAssertEqual(error as? WriteOnceConflict, WriteOnceConflict(path: dest.path))
        }
        XCTAssertEqual(try Data(contentsOf: dest), Data("first".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))

        let fresh = root.appendingPathComponent("images/b.dmg")
        let temp2 = root.appendingPathComponent("images/.b.dmg.tmp")
        try Data("bee".utf8).write(to: temp2)
        try ChunkedIO.publishExclusive(temp: temp2, dest: fresh)
        XCTAssertEqual(try Data(contentsOf: fresh), Data("bee".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp2.path))
    }

    func testLocalFolderPutOnlyRefusesInsideWriteOnceScope() throws {
        let backend = try LocalFolderBackend(root: root)
        try backend.put("devices/x.json", data: Data("1".utf8))
        // Mutable paths keep replace semantics.
        try backend.put("devices/x.json", data: Data("2".utf8))
        XCTAssertEqual(try backend.get("devices/x.json", range: nil), Data("2".utf8))
        XCTAssertThrowsError(try WriteOnceScope.run { try backend.put("devices/x.json", data: Data("3".utf8)) }) { error in
            XCTAssertTrue(error is WriteOnceConflict)
        }
        XCTAssertEqual(try backend.get("devices/x.json", range: nil), Data("2".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("devices").path)
        XCTAssertEqual(names, ["x.json"], "no temp file is left behind")
    }

    func testWriteOncePutReportsReusedAndConflict() throws {
        let backend = try LocalFolderBackend(root: root)
        XCTAssertEqual(try WriteOnce.publish(backend: backend, path: "manifests/m.json", data: Data("m".utf8)), .written)
        XCTAssertEqual(try WriteOnce.publish(backend: backend, path: "manifests/m.json", data: Data("m".utf8)), .reused)
        guard case .conflict = try WriteOnce.publish(backend: backend, path: "manifests/m.json", data: Data("other".utf8)) else {
            return XCTFail("different bytes must be a conflict")
        }
        XCTAssertThrowsError(try WriteOnce.put(backend: backend, path: "manifests/m.json", data: Data("other".utf8))) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 5)
        }
        XCTAssertEqual(try backend.get("manifests/m.json", range: nil), Data("m".utf8))
    }

    /// Two writers race for one write-once path with different bytes. Both see the
    /// path absent (the probe is forced to pass), so the exclusive publish decides.
    func testConcurrentPutsOfOnePathHaveExactlyOneWinner() throws {
        let backend = try LocalFolderBackend(root: root)
        let path = "images/race.dmg"
        let rounds = 20
        for round in 0..<rounds {
            let target = "\(path).\(round)"
            let a = root.appendingPathComponent("a-\(round).bin")
            let b = root.appendingPathComponent("b-\(round).bin")
            let bytesA = Data(repeating: 0xA1, count: 256 * 1024 + round)
            let bytesB = Data(repeating: 0xB2, count: 256 * 1024 + round)
            try bytesA.write(to: a)
            try bytesB.write(to: b)
            let shaA = SHA256Digest.hex(bytesA)
            let shaB = SHA256Digest.hex(bytesB)
            let gate = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var results: [String: Result<WriteOnceResult, Error>] = [:]
            for (name, file, sha) in [("a", a, shaA), ("b", b, shaB)] {
                gate.enter()
                DispatchQueue.global().async {
                    start.wait()
                    let result = Result { try WriteOnce.publishFile(backend: backend, path: target, file: file, sha256: sha) }
                    lock.lock(); results[name] = result; lock.unlock()
                    gate.leave()
                }
            }
            start.signal()
            start.signal()
            gate.wait()
            let outcomes = try results.mapValues { try $0.get() }
            let winners = outcomes.filter { $0.value == .written }.map(\.key)
            let losers = outcomes.filter { if case .conflict = $0.value { return true }; return false }.map(\.key)
            XCTAssertEqual(winners.count, 1, "round \(round): \(outcomes)")
            XCTAssertEqual(losers.count, 1, "round \(round): \(outcomes)")
            let stored = try Data(contentsOf: root.appendingPathComponent(target))
            XCTAssertEqual(stored, winners.first == "a" ? bytesA : bytesB, "the winner's bytes stay intact")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path).filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [])
    }

    /// The race inside `publish` itself: the loser saw `.absent`, then hit EEXIST.
    func testLoserOfTheExclusiveRenameGetsConflictWithoutOverwriting() throws {
        let backend = RacingBackend(inner: try LocalFolderBackend(root: root))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        let path = "images/late.dmg"
        let mine = root.appendingPathComponent("mine.bin")
        try Data("mine".utf8).write(to: mine)
        backend.beforePut = { try Data("theirs".utf8).write(to: self.root.appendingPathComponent(path)) }
        let result = try WriteOnce.publishFile(backend: backend, path: path, file: mine, sha256: SHA256Digest.hex(Data("mine".utf8)))
        guard case .conflict = result else { return XCTFail("expected a conflict, got \(result)") }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("theirs".utf8))

        let same = "images/same.dmg"
        backend.beforePut = { try Data("mine".utf8).write(to: self.root.appendingPathComponent(same)) }
        XCTAssertEqual(try WriteOnce.publishFile(backend: backend, path: same, file: mine, sha256: SHA256Digest.hex(Data("mine".utf8))), .reused)
    }

    func testConfirmCanonical() throws {
        let backend = try LocalFolderBackend(root: root)
        let bytes = Data("dmg-bytes".utf8)
        let sha = SHA256Digest.hex(bytes)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "V", appPathInVolume: "V.app")
        let manifest = ImageManifest(bundleId: "com.example.V", name: "V", version: "1", image: image, app: .init(originalPath: "/Applications/V.app", executable: "V", documentTypes: [], urlTypes: []))
        XCTAssertThrowsError(try WriteOnce.confirmCanonical(backend: backend, imageId: manifest.imageId, imageSha: sha))
        try WriteOnce.put(backend: backend, path: manifest.image.file, data: bytes)
        try WriteOnce.put(backend: backend, path: "manifests/\(manifest.imageId).json", data: try manifest.encode())
        XCTAssertEqual(try WriteOnce.confirmCanonical(backend: backend, imageId: manifest.imageId, imageSha: sha), .verified)
        XCTAssertThrowsError(try WriteOnce.confirmCanonical(backend: backend, imageId: manifest.imageId, imageSha: String(repeating: "0", count: 64))) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 5)
        }
    }

    func testProbeWithoutLocalRootStreamsThroughDownload() throws {
        let inner = try LocalFolderBackend(root: root)
        let bytes = Data(repeating: 7, count: 3 * ChunkedIO.chunkSize + 11)
        try inner.put("images/big.dmg", data: bytes)
        let remote = RemoteOnlyBackend(inner: inner)
        XCTAssertEqual(try WriteOnce.probe(remote, "images/big.dmg"), .sha256(SHA256Digest.hex(bytes)))
        XCTAssertFalse(remote.calls.contains("get:images/big.dmg"), "the image is not buffered with get")
        XCTAssertTrue(remote.calls.contains("download:images/big.dmg"))
        XCTAssertEqual(try WriteOnce.probe(remote, "images/none.dmg"), .absent)
    }
}

/// Runs `beforePut` right before the put, after WriteOnce probed the path as absent.
private final class RacingBackend: StorageBackend {
    let inner: LocalFolderBackend
    var beforePut: () throws -> Void = {}
    init(inner: LocalFolderBackend) { self.inner = inner }
    func list(_ path: String) throws -> [String] { try inner.list(path) }
    func stat(_ path: String) throws -> BackendStat? { try inner.stat(path) }
    func get(_ path: String, range: Range<UInt64>?) throws -> Data { try inner.get(path, range: range) }
    func put(_ path: String, data: Data) throws { try beforePut(); try inner.put(path, data: data) }
    func put(_ path: String, file: URL) throws { try beforePut(); try inner.put(path, file: file) }
    func delete(_ path: String) throws { try inner.delete(path) }
    func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile { try inner.download(path, to: destination, offset: offset) }
    func localRoot() -> URL? { inner.localRoot() }
    func ensureCollection(_ path: String) throws { try inner.ensureCollection(path) }
}

/// A backend with no local directory, like WebDAV.
private final class RemoteOnlyBackend: StorageBackend {
    let inner: LocalFolderBackend
    var calls: [String] = []
    init(inner: LocalFolderBackend) { self.inner = inner }
    func list(_ path: String) throws -> [String] { try inner.list(path) }
    func stat(_ path: String) throws -> BackendStat? { try inner.stat(path) }
    func get(_ path: String, range: Range<UInt64>?) throws -> Data { calls.append("get:\(path)"); return try inner.get(path, range: range) }
    func put(_ path: String, data: Data) throws { try inner.put(path, data: data) }
    func delete(_ path: String) throws { try inner.delete(path) }
    func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        calls.append("download:\(path)")
        return try inner.download(path, to: destination, offset: offset)
    }
    func localRoot() -> URL? { nil }
}
