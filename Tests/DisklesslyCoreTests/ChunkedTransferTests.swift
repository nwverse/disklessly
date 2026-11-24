import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine
@testable import DisklesslySessions

final class ChunkedTransferTests: XCTestCase {
    override class func setUp() { super.setUp(); License.limitOverride = true }
    override class func tearDown() { License.limitOverride = nil; super.tearDown() }

    private var root: URL!
    private var home: URL!
    private var cacheDir: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("disklessly-chunked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: SessionPaths.canonical(root.path))
        home = root.appendingPathComponent("home")
        cacheDir = root.appendingPathComponent("cache").path
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine(backend: (any StorageBackend)? = nil) throws -> DisklesslyEngine {
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: cacheDir,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mounts").path,
            stubDir: root.appendingPathComponent("apps").path
        )
        config.minFreeBytes = 0
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.homeOverride = home.path
        engine.offloadedOverride = { [] }
        engine.fileOpenOverride = { _, _ in false }
        if let backend {
            engine.backendOverride = backend
        } else {
            try FileManager.default.createDirectory(atPath: config.repoPath, withIntermediateDirectories: true)
        }
        _ = try RepoIdentity.ensure(try engine.repo)
        return engine
    }

    /// Simulates a remote backend (`localRoot() == nil`) backed by a local folder, tracking `put` calls.
    private final class MockRemoteBackend: StorageBackend, @unchecked Sendable {
        private let inner: LocalFolderBackend
        private let lock = NSLock()
        private(set) var putPaths: [String] = []

        init(root: URL) throws {
            self.inner = try LocalFolderBackend(root: root)
        }

        func list(_ path: String) throws -> [String] { try inner.list(path) }
        func entries(_ path: String) throws -> [BackendEntry] { try inner.entries(path) }
        func stat(_ path: String) throws -> BackendStat? { try inner.stat(path) }
        func get(_ path: String, range: Range<UInt64>?) throws -> Data { try inner.get(path, range: range) }
        func put(_ path: String, data: Data) throws {
            lock.lock(); putPaths.append(path); lock.unlock()
            try inner.put(path, data: data)
        }
        func put(_ path: String, file: URL) throws {
            lock.lock(); putPaths.append(path); lock.unlock()
            try inner.put(path, file: file)
        }
        func delete(_ path: String) throws { try inner.delete(path) }
        func ensureCollection(_ path: String) throws { try inner.ensureCollection(path) }
        func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody {
            try inner.getResumable(path, offset: offset)
        }
        func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
            try inner.download(path, to: destination, offset: offset)
        }
        func move(_ from: String, to: String) throws { try inner.move(from, to: to) }
        func localRoot() -> URL? { nil }
    }

    // MARK: Zstd parallel streaming

    func testZstdStreamParallelMultiFrameRoundTrip() throws {
        // Test empty input, small input, and >9 MiB multi-block input (multiple 4 MiB frames).
        for size in [0, 128, 9 * 1024 * 1024 + 12345] {
            var payload = Data(count: size)
            payload.withUnsafeMutableBytes { raw in
                for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: (i &* 1315423911) >> 17) }
            }
            let src = root.appendingPathComponent("zstd-in-\(size).bin")
            let zst = root.appendingPathComponent("zstd-out-\(size).zst")
            let out = root.appendingPathComponent("zstd-dec-\(size).bin")
            try payload.write(to: src)
            FileManager.default.createFile(atPath: zst.path, contents: nil)
            FileManager.default.createFile(atPath: out.path, contents: nil)

            let inHandle = try FileHandle(forReadingFrom: src)
            let zstWrite = try FileHandle(forWritingTo: zst)
            try ZstdStream.compress(from: inHandle, to: zstWrite, level: 3, workers: 4)
            try inHandle.close()
            try zstWrite.close()

            let zstRead = try FileHandle(forReadingFrom: zst)
            let outWrite = try FileHandle(forWritingTo: out)
            try ZstdStream.decompress(from: zstRead, to: outWrite)
            try zstRead.close()
            try outWrite.close()

            let decoded = try Data(contentsOf: out)
            XCTAssertEqual(decoded, payload, "mismatch for size \(size)")
        }
    }

    // MARK: Manifest & Placeholder validation

    func testChunkedManifestEncodeDecodeAndValidation() throws {
        let shaA = String(repeating: "a", count: 64)
        let shaB = String(repeating: "b", count: 64)
        let shaWhole = String(repeating: "c", count: 64)
        let manifest = ChunkedObjectManifest(
            codec: "tar+zstd",
            sha256: shaWhole,
            totalSize: 150,
            chunkSize: 100,
            chunks: [
                .init(index: 0, path: ChunkedObjectManifest.chunkPath(sha256: shaA), sha256: shaA, size: 100),
                .init(index: 1, path: ChunkedObjectManifest.chunkPath(sha256: shaB), sha256: shaB, size: 50),
            ]
        )
        let encoded = try manifest.encode()
        let decoded = try ChunkedObjectManifest.decode(encoded)
        XCTAssertEqual(decoded, manifest)

        var badIndex = manifest
        badIndex.chunks[1].index = 2
        XCTAssertThrowsError(try badIndex.validate())

        var badSum = manifest
        badSum.totalSize = 999
        XCTAssertThrowsError(try badSum.validate())

        var badPath = manifest
        badPath.chunks[0].path = "files/chunks/wrong.bin"
        XCTAssertThrowsError(try badPath.validate())

        var badHash = manifest
        badHash.chunks[0].sha256 = "not-hex"
        XCTAssertThrowsError(try badHash.validate())
    }

    func testFilePlaceholderChunkedAndLegacyValidation() {
        let sha = String(repeating: "d", count: 64)
        let chunkedFolder = FilePlaceholder(
            id: "1", kind: .folder, name: "vm", size: 500,
            object: FilePlaceholder.chunkedObjectPath(sha256: sha),
            codec: "tar+zstd+chunks", sha256: sha, storedSize: 300,
            repoId: nil, originalPath: "/tmp/vm", createdAt: Date()
        )
        XCTAssertTrue(chunkedFolder.isChunked)
        XCTAssertNoThrow(try chunkedFolder.validate())

        let legacyFile = FilePlaceholder(
            id: "2", kind: .file, name: "blob.bin", size: 500,
            object: FilePlaceholder.objectPath(sha256: sha, kind: .file),
            codec: "none", sha256: sha, storedSize: 500,
            repoId: nil, originalPath: "/tmp/blob.bin", createdAt: Date()
        )
        XCTAssertFalse(legacyFile.isChunked)
        XCTAssertNoThrow(try legacyFile.validate())

        let badCodec = FilePlaceholder(
            id: "3", kind: .folder, name: "vm", size: 500,
            object: FilePlaceholder.chunkedObjectPath(sha256: sha),
            codec: "none+chunks", sha256: sha, storedSize: 300,
            repoId: nil, originalPath: "/tmp/vm", createdAt: Date()
        )
        XCTAssertThrowsError(try badCodec.validate())
    }

    func testRcloneUploadOverridesAndRepoCopierOrder() {
        XCTAssertEqual(RcloneBackend.uploadOverrides(type: "drive"), ["chunk_size": "64M"])
        XCTAssertEqual(RcloneBackend.uploadOverrides(type: "s3"), ["chunk_size": "64M", "upload_concurrency": "4"])
        XCTAssertEqual(RcloneBackend.uploadOverrides(type: "azureblob"), ["chunk_size": "64M", "upload_concurrency": "4"])
        XCTAssertEqual(RcloneBackend.uploadOverrides(type: "b2"), ["chunk_size": "64M"])
        XCTAssertEqual(RcloneBackend.uploadOverrides(type: "dropbox"), [:])

        XCTAssertTrue(RepoCopier.order("files/chunks/\(String(repeating: "a", count: 64)).bin")
                      < RepoCopier.order("files/objects/\(String(repeating: "b", count: 64)).chunks.json"))
        XCTAssertFalse(RepoCopier.isTransient("\(String(repeating: "a", count: 64)).bin"))
    }

    // MARK: End-to-end chunked upload, dedup, resume, verify, integrity, download

    func testChunkedFileOffloadDedupResumeCorruptionAndFetch() throws {
        let remoteRoot = root.appendingPathComponent("remote-repo")
        let mockBackend = try MockRemoteBackend(root: remoteRoot)
        let engine = try makeEngine(backend: mockBackend)

        // Two identical 128 KiB blocks + one unique 40 KiB tail -> 3 logical chunks, only 2 unique chunks in repo.
        let chunkSize: UInt64 = 128 * 1024
        let blockA = Data(repeating: 0x5A, count: Int(chunkSize))
        let tail = Data((0..<(40 * 1024)).map { UInt8($0 & 0xff) })
        var original = Data()
        original.append(blockA)
        original.append(blockA)
        original.append(tail)

        let src = home.appendingPathComponent("Downloads/repeated.img")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: src)

        setenv("DISKLESSLY_FORCE_CHUNKS", "1", 1)
        setenv("DISKLESSLY_CHUNK_SIZE_BYTES", String(chunkSize), 1)
        setenv("DISKLESSLY_UPLOAD_STREAMS", "3", 1)
        defer {
            unsetenv("DISKLESSLY_FORCE_CHUNKS")
            unsetenv("DISKLESSLY_CHUNK_SIZE_BYTES")
            unsetenv("DISKLESSLY_UPLOAD_STREAMS")
        }

        // Pre-populate blockA chunk in repo to exercise resume skipping already-present chunks.
        let shaA = SHA256Digest.hex(blockA)
        try mockBackend.ensureCollection("files/chunks")
        try mockBackend.put(ChunkedObjectManifest.chunkPath(sha256: shaA), data: blockA)
        let prePutCount = mockBackend.putPaths.count

        let offload = try engine.offloadFile(src.path)
        XCTAssertTrue(offload.placeholder.isChunked)
        XCTAssertEqual(offload.placeholder.codec, "none+chunks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: offload.placeholderPath))

        // Only tail chunk + manifest JSON should have been put during offload (blockA existed & second blockA deduped).
        let newPuts = Array(mockBackend.putPaths.dropFirst(prePutCount))
        let tailPath = ChunkedObjectManifest.chunkPath(sha256: SHA256Digest.hex(tail))
        XCTAssertTrue(newPuts.contains(tailPath))
        XCTAssertFalse(newPuts.contains(ChunkedObjectManifest.chunkPath(sha256: shaA)))
        XCTAssertTrue(newPuts.contains(offload.placeholder.object))

        let manifestData = try mockBackend.get(offload.placeholder.object, range: nil)
        let manifest = try ChunkedObjectManifest.decode(manifestData)
        XCTAssertEqual(manifest.chunks.count, 3)
        XCTAssertEqual(manifest.chunks[0].sha256, shaA)
        XCTAssertEqual(manifest.chunks[1].sha256, shaA)

        // Fetching reassembles exact original bytes and clears placeholder.
        let fetched = try engine.fetchFile(offload.placeholderPath)
        XCTAssertEqual(try Data(contentsOf: fetched), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: offload.placeholderPath))

        // Re-offload reusing existing chunks + corrupt one chunk to ensure ChunkedTransfer.download catches integrity failures.
        let offload2 = try engine.offloadFile(src.path)
        let corruptTarget = remoteRoot.appendingPathComponent(tailPath)
        var corrupted = try Data(contentsOf: corruptTarget)
        corrupted[0] ^= 0xff
        try corrupted.write(to: corruptTarget)

        XCTAssertThrowsError(try engine.fetchFile(offload2.placeholderPath)) { error in
            guard case DisklesslyError.integrity = error else {
                XCTFail("expected integrity error, got \(error)")
                return
            }
        }
    }

    func testChunkedFolderAndLinkedBundleConcurrentOffloadRestore() throws {
        let remoteRoot = root.appendingPathComponent("remote-repo")
        let mockBackend = try MockRemoteBackend(root: remoteRoot)
        let engine = try makeEngine(backend: mockBackend)

        let dir1 = home.appendingPathComponent("Projects/BundleOne")
        let file2 = home.appendingPathComponent("Projects/large.bin")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        let data1 = Data(repeating: 0x33, count: 220 * 1024)
        let data2 = Data((0..<(200 * 1024)).map { UInt8(($0 &* 7) & 0xff) })
        try data1.write(to: dir1.appendingPathComponent("payload.dat"))
        try data2.write(to: file2)

        setenv("DISKLESSLY_FORCE_CHUNKS", "1", 1)
        setenv("DISKLESSLY_CHUNK_SIZE_BYTES", String(64 * 1024), 1)
        setenv("DISKLESSLY_UPLOAD_STREAMS", "2", 1)
        defer {
            unsetenv("DISKLESSLY_FORCE_CHUNKS")
            unsetenv("DISKLESSLY_CHUNK_SIZE_BYTES")
            unsetenv("DISKLESSLY_UPLOAD_STREAMS")
        }

        // The app path is only the bundle key here: it is not created on disk, so offload skips
        // the app pack step (an empty folder is not a valid .app and pack would refuse it) and the
        // test exercises just the concurrent linked-path offload/restore.
        let fakeApp = root.appendingPathComponent("apps/Dummy.app")
        // Bundle has two linked paths, triggering concurrent LinkedBundlesEngine execution.
        let bundle = try engine.linkedBundleStore.link(appPath: fakeApp.path, appName: "Dummy", extraPath: dir1.path)
        _ = try engine.linkedBundleStore.link(appPath: fakeApp.path, appName: "Dummy", extraPath: file2.path)

        var lastProgress: (UInt64, UInt64) = (0, 0)
        try engine.offloadLinkedBundle(id: bundle.id, onBytes: { done, total in
            lastProgress = (done, total)
        })

        XCTAssertGreaterThan(lastProgress.0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FilePlaceholder.placeholderURL(for: dir1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: FilePlaceholder.placeholderURL(for: file2).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2.path))

        try engine.restoreLinkedBundle(id: bundle.id)
        XCTAssertEqual(try Data(contentsOf: dir1.appendingPathComponent("payload.dat")), data1)
        XCTAssertEqual(try Data(contentsOf: file2), data2)
    }
}
