import XCTest
import Foundation
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class PackOptimizationTests: XCTestCase {
    private final class MockRemoteBackend: StorageBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var objects: [String: Data] = [:]
        var remoteHashes: [String: String?] = [:]
        var listManifestsCalls = 0
        var downloadCalls = 0
        var progressCallbacks = 0

        func list(_ path: String) throws -> [String] {
            lock.lock(); defer { lock.unlock() }
            if path == "manifests" { listManifestsCalls += 1 }
            let prefix = path.isEmpty ? "" : (path.hasSuffix("/") ? path : path + "/")
            var names: Set<String> = []
            for key in objects.keys where key.hasPrefix(prefix) {
                let rest = key.dropFirst(prefix.count)
                if let first = rest.split(separator: "/").first {
                    names.insert(String(first))
                }
            }
            return names.sorted()
        }

        func stat(_ path: String) throws -> BackendStat? {
            lock.lock(); defer { lock.unlock() }
            guard let data = objects[path] else { return nil }
            return BackendStat(size: UInt64(data.count), modified: Date())
        }

        func statWithHash(_ path: String) throws -> (stat: BackendStat, sha256: String?)? {
            lock.lock(); defer { lock.unlock() }
            guard let data = objects[path] else { return nil }
            let stat = BackendStat(size: UInt64(data.count), modified: Date())
            if let override = remoteHashes[path] {
                return (stat, override)
            }
            return (stat, SHA256Digest.hex(data))
        }

        func get(_ path: String, range: Range<UInt64>?) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let data = objects[path] else { throw DisklesslyError.backend("missing \(path)") }
            if let range {
                let upper = min(Int(range.upperBound), data.count)
                return Int(range.lowerBound) < upper ? data.subdata(in: Int(range.lowerBound)..<upper) : Data()
            }
            return data
        }

        func put(_ path: String, data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if WriteOnceScope.exclusive, objects[path] != nil {
                throw WriteOnceConflict(path: path)
            }
            objects[path] = data
        }

        func put(_ path: String, file: URL) throws {
            let data = try Data(contentsOf: file)
            try put(path, data: data)
        }

        func put(_ path: String, file: URL, onBytes: @escaping (UInt64, UInt64) -> Void) throws {
            let total = (try? ChunkedIO.byteCount(file)) ?? 0
            if total > 0 {
                lock.lock(); progressCallbacks += 1; lock.unlock()
                onBytes(0, total)
            }
            try put(path, file: file)
            if total > 0 {
                lock.lock(); progressCallbacks += 1; lock.unlock()
                onBytes(total, total)
            }
        }

        func delete(_ path: String) throws {
            lock.lock(); defer { lock.unlock() }
            objects.removeValue(forKey: path)
        }

        func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
            lock.lock()
            downloadCalls += 1
            let data = objects[path]
            lock.unlock()
            guard let data else { throw DisklesslyError.backend("missing \(path)") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let slice = offset < UInt64(data.count) ? data.subdata(in: Int(offset)..<data.count) : Data()
            try slice.write(to: destination)
            return ResumableFile(restart: false, bytesWritten: UInt64(slice.count))
        }

        func ensureCollection(_ path: String) throws {}
        func localRoot() -> URL? { nil }

        func seed(_ path: String, data: Data) {
            lock.lock(); defer { lock.unlock() }
            objects[path] = data
        }
    }

    func testWriteOnceProbeAndConfirmCanonicalSkipDownloadWithRemoteHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-opt-wo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bytes = Data("hello remote digest".utf8)
        let sha = SHA256Digest.hex(bytes)
        let imgFile = root.appendingPathComponent("app.dmg")
        try bytes.write(to: imgFile)

        let backend = MockRemoteBackend()
        XCTAssertEqual(try WriteOnce.publishFile(backend: backend, path: "images/app.dmg", file: imgFile, sha256: sha), .written)

        let image = ImageManifest.Image(file: "images/app.dmg", format: "ULFO", sha256: sha, size: UInt64(bytes.count), volumeName: "App", appPathInVolume: "App.app")
        let manifest = ImageManifest(bundleId: "com.test.App", name: "App", version: "1.0", image: image, app: .init(originalPath: "/Applications/App.app", executable: "App", documentTypes: [], urlTypes: []))
        XCTAssertEqual(try WriteOnce.publish(backend: backend, path: "manifests/\(manifest.imageId).json", data: try manifest.encode()), .written)

        XCTAssertEqual(try WriteOnce.probe(backend, "images/app.dmg"), .sha256(sha))
        XCTAssertEqual(try WriteOnce.confirmCanonical(backend: backend, imageId: manifest.imageId, imageSha: sha), .verified)
        XCTAssertEqual(backend.downloadCalls, 0)

        // Mismatch triggers integrity failure.
        backend.remoteHashes["images/app.dmg"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try WriteOnce.confirmCanonical(backend: backend, imageId: manifest.imageId, imageSha: sha)) { err in
            XCTAssertEqual((err as? DisklesslyError)?.exitCode, 5)
        }

        // Nil remote hash falls back to downloading once.
        backend.remoteHashes["images/app.dmg"] = .some(nil)
        XCTAssertEqual(try WriteOnce.probe(backend, "images/app.dmg"), .sha256(sha))
        XCTAssertEqual(backend.downloadCalls, 1)
    }

    func testChunkedVerifyAndReadBackDigestUseRemoteHashBeforeFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-opt-chk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDir = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let backend = MockRemoteBackend()
        let chunkData = Data(repeating: 0x2A, count: 4096)
        let chunkSha = SHA256Digest.hex(chunkData)
        let chunkPath = ChunkedObjectManifest.chunkPath(sha256: chunkSha)
        backend.seed(chunkPath, data: chunkData)

        let manifest = ChunkedObjectManifest(
            codec: "none",
            sha256: chunkSha,
            totalSize: UInt64(chunkData.count),
            chunkSize: 4096,
            chunks: [.init(index: 0, path: chunkPath, sha256: chunkSha, size: UInt64(chunkData.count))]
        )
        let manifestPath = ChunkedObjectManifest.manifestPath(sha256: chunkSha)
        backend.seed(manifestPath, data: try manifest.encode())

        try ChunkedTransfer.verify(backend: backend, manifestPath: manifestPath, expected: manifest, cacheDir: cacheDir.path, minFreeBytes: 0, streams: 2)
        XCTAssertEqual(backend.downloadCalls, 0)

        backend.remoteHashes[chunkPath] = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try ChunkedTransfer.verify(backend: backend, manifestPath: manifestPath, expected: manifest, cacheDir: cacheDir.path, minFreeBytes: 0, streams: 2)) { err in
            XCTAssertEqual((err as? DisklesslyError)?.exitCode, 5)
        }

        backend.remoteHashes[chunkPath] = .some(nil)
        try ChunkedTransfer.verify(backend: backend, manifestPath: manifestPath, expected: manifest, cacheDir: cacheDir.path, minFreeBytes: 0, streams: 2)
        XCTAssertEqual(backend.downloadCalls, 1)

        // FileOffload.readBackDigest on plain remote object
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: cacheDir.path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        config.minFreeBytes = 0
        let engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        backend.seed("files/objects/obj.bin", data: chunkData)
        XCTAssertEqual(try engine.readBackDigest(backend, "files/objects/obj.bin", size: UInt64(chunkData.count)), chunkSha)
        XCTAssertEqual(backend.downloadCalls, 1)

        backend.remoteHashes["files/objects/obj.bin"] = .some(nil)
        XCTAssertEqual(try engine.readBackDigest(backend, "files/objects/obj.bin", size: UInt64(chunkData.count)), chunkSha)
        XCTAssertEqual(backend.downloadCalls, 2)
    }

    func testRcloneSHA256ValidationAndExtraction() {
        let upper = String(repeating: "AB", count: 32)
        let expected = upper.lowercased()
        XCTAssertEqual(RcloneBackend.validSHA256("  \(upper)\n"), expected)
        XCTAssertNil(RcloneBackend.validSHA256("too-short"))
        XCTAssertNil(RcloneBackend.validSHA256(String(repeating: "g", count: 64)))
        XCTAssertEqual(RcloneBackend.extractSHA256(from: ["SHA-256": upper]), expected)
        XCTAssertEqual(RcloneBackend.extractSHA256(from: ["sha256": upper] as [String: Any]), expected)
        XCTAssertNil(RcloneBackend.extractSHA256(from: ["md5": "d41d8cd98f00b204e9800998ecf8427e"]))
    }

    func testParallelReadManifestsAndPrefetchedPublish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-opt-pub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        engine.backendOverride = backend
        try engine.initialize()

        let remote = MockRemoteBackend()
        for i in 0..<6 {
            let name = "App\(i)"
            let img = ImageManifest.Image(file: "images/\(name).dmg", format: "ULFO", sha256: String(repeating: "a", count: 64), size: 12, volumeName: name, appPathInVolume: "\(name).app")
            let m = ImageManifest(bundleId: "com.test.\(name)", name: name, version: "1.0", image: img, app: .init(originalPath: "/Applications/\(name).app", executable: name, documentTypes: [], urlTypes: []))
            remote.seed("manifests/\(m.imageId).json", data: try m.encode())
        }
        remote.seed("manifests/bad.json", data: Data("{bad json".utf8))
        remote.seed("manifests/ignore.txt", data: Data("ignored".utf8))

        let listed = try engine.readManifests(remote)
        XCTAssertEqual(listed.count, 6)

        var remoteEngine = engine
        remoteEngine.backendOverride = remote
        let dmgData = Data(repeating: 0x55, count: 2048)
        let dmgFile = root.appendingPathComponent("new.dmg")
        try dmgData.write(to: dmgFile)

        remote.listManifestsCalls = 0
        var phases: [String] = []
        var byteEvents: [(UInt64, UInt64)] = []
        let request = PublishRequest(
            name: "FreshApp",
            identity: ImageIdentity(bundleId: "com.test.Fresh", version: "1.0", build: "1", architectures: ["arm64"], treeHash: String(repeating: "b", count: 64)),
            mode: .mount,
            executable: "Fresh",
            originalPath: "/Applications/Fresh.app",
            cdhash: "cd",
            postImageTreeHash: String(repeating: "b", count: 64),
            volumeName: "Fresh",
            appPathInVolume: "Fresh.app",
            imageFormat: "ULFO"
        )
        let res = try remoteEngine.publish(request, imageFile: dmgFile, prefetchedManifests: listed, progress: { phases.append($0) }, onBytes: { done, total in
            byteEvents.append((done, total))
        })
        XCTAssertTrue(res.uploaded)
        XCTAssertEqual(remote.listManifestsCalls, 0)
        XCTAssertEqual(phases, ["upload", "verify"])
        XCTAssertFalse(byteEvents.isEmpty)
        XCTAssertEqual(byteEvents.last?.0, UInt64(dmgData.count))
    }

    func testRuntimeConfigULFODefaultsAndJobStoreResetsBytesOnPhaseChange() throws {
        let cfg = RuntimeConfig.environment([:], home: "/tmp/h", platform: .macOS)
        XCTAssertEqual(cfg.imageFormat, "ULFO")
        XCTAssertEqual(cfg.restoreImageFormat, "ULFO")

        let overridden = RuntimeConfig.environment(["DISKLESSLY_IMAGE_FORMAT": "ULMO"], home: "/tmp/h", platform: .macOS)
        XCTAssertEqual(overridden.imageFormat, "ULMO")

        let legacyJSON = #"{"repoPath":"/tmp/r","cacheDir":"/tmp/c","stateDir":"/tmp/s","mountRoot":"/tmp/m","stubDir":"/Applications"}"#
        let decoded = try JSONDecoder().decode(RuntimeConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.imageFormat, "ULFO")
        XCTAssertEqual(decoded.restoreImageFormat, "ULFO")

        let store = UIJobStore(retained: 10)
        // Handshake instead of sleeps: the job holds each phase until the test has seen it.
        let gate = DispatchSemaphore(value: 0)
        let uploadSeen = DispatchSemaphore(value: 0)
        guard case .started(let job) = store.start(kind: .pack, app: "Demo", work: { progress in
            progress.phase("upload")
            progress.bytes(50, total: 100)
            _ = uploadSeen.wait(timeout: .now() + 10)
            progress.phase("verify")
            _ = gate.wait(timeout: .now() + 10)
        }) else {
            return XCTFail("expected started")
        }
        func poll(_ until: Date, _ match: (UIJobSnapshotProbe) -> Bool) -> Bool {
            while Date() < until {
                if let snap = store.job(job.id), match(UIJobSnapshotProbe(phase: snap.phase, done: snap.doneBytes, total: snap.totalBytes)) { return true }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return false
        }
        XCTAssertTrue(poll(Date().addingTimeInterval(10)) { $0.phase == "upload" && $0.done == 50 })
        uploadSeen.signal()
        XCTAssertTrue(poll(Date().addingTimeInterval(10)) { $0.phase == "verify" && $0.done == nil && $0.total == nil }, "bytes reset on phase change")
        gate.signal()
    }

    func testTrashRefusalAndUsageAnnotations() throws {
        let home = "/Users/tester"
        let protected = ["\(home)/Library/Caches/Disklessly", "\(home)/Library/Application Support/Disklessly"]
        XCTAssertNil(FileOffloadPolicy.trashRefusal(path: "\(home)/Library/Caches/go-build", home: home, protected: protected, isDirectory: true, isSymlink: false))
        XCTAssertNil(FileOffloadPolicy.trashRefusal(path: "\(home)/Library/Developer/Xcode/DerivedData", home: home, protected: protected, isDirectory: true, isSymlink: false, extraAllowedRelativePaths: [KnownLocations.derivedData]))
        XCTAssertNotNil(FileOffloadPolicy.trashRefusal(path: "\(home)/Library/Application Support/OpenLess", home: home, protected: protected, isDirectory: true, isSymlink: false))
        XCTAssertNotNil(FileOffloadPolicy.trashRefusal(path: "\(home)/Library/Caches", home: home, protected: protected, isDirectory: true, isSymlink: false))
        XCTAssertNotNil(FileOffloadPolicy.trashRefusal(path: "\(home)/Library/Caches/com.apple.Safari", home: home, protected: protected, isDirectory: true, isSymlink: false))
        XCTAssertNotNil(FileOffloadPolicy.trashRefusal(path: "\(home)/Library/Caches/Disklessly", home: home, protected: protected, isDirectory: true, isSymlink: false))
        XCTAssertNotNil(FileOffloadPolicy.trashRefusal(path: "\(home)/Library/Caches/256isenough", home: home, protected: protected, isDirectory: true, isSymlink: false))

        var node = UsageNode(name: "go-build", kind: .cache, bytes: 100)
        node.path = "\(home)/Library/Caches/go-build"
        node.refusal = "is inside ~/Library"
        node.trashRefusal = nil
        let obj = node.jsonObject()
        XCTAssertEqual(obj["canTrash"] as? Bool, true)
        XCTAssertEqual(obj["refusal"] as? String, "is inside ~/Library")

        var appNode = UsageNode(name: "OpenLess", kind: .apps, bytes: 100)
        appNode.offloaded = true
        XCTAssertEqual(appNode.jsonObject()["offloaded"] as? Bool, true)
    }

    func testLinksAppsAndCacheTrashAPI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-opt-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = root.appendingPathComponent("home")
        let goBuild = fakeHome.appendingPathComponent("Library/Caches/go-build")
        try FileManager.default.createDirectory(at: goBuild, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: goBuild.appendingPathComponent("a.o"))

        let config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.homeOverride = fakeHome.path
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions(perform: { kind, _, opts, _ in
            if kind == .trashpath, let p = opts.path { try FileManager.default.removeItem(atPath: p) }
        }))

        let appsResp = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/links/apps"))
        XCTAssertEqual(appsResp.status, 200)
        let appsObj = try JSONSerialization.jsonObject(with: appsResp.body) as? [String: Any]
        XCTAssertEqual(appsObj?["ok"] as? Bool, true)
        XCTAssertNotNil(appsObj?["apps"] as? [[String: Any]])

        let trashBody = try JSONSerialization.data(withJSONObject: ["app": goBuild.path, "path": goBuild.path])
        let trashResp = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "POST", path: "/api/trashpath", body: trashBody), context: context)
        XCTAssertEqual(trashResp.status, 202)
        let trashObj = try JSONSerialization.jsonObject(with: trashResp.body) as? [String: Any]
        let jobId = try XCTUnwrap(trashObj?["jobId"] as? String)
        XCTAssertEqual(context.jobs.wait(jobId, timeout: 5)?.state, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: goBuild.path))
    }
}

private struct UIJobSnapshotProbe {
    var phase: String?
    var done: UInt64?
    var total: UInt64?
}
