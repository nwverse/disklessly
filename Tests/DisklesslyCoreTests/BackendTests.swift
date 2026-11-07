import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DisklesslyCore
import DisklesslyEngine

final class ScriptedHTTP: HTTPTransport {
    struct Call {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data?
    }
    var calls: [Call] = []
    var steps: [(String, HTTPResponse)] = []
    func send(method: String, url: URL, headers: [String: String], body: Data?) throws -> HTTPResponse {
        calls.append(Call(method: method, url: url.absoluteString, headers: headers, body: body))
        guard !steps.isEmpty else { throw URLError(.cannotConnectToHost) }
        let step = steps.removeFirst()
        guard step.0 == method else { throw DisklesslyError.failure("expected \(step.0) got \(method)") }
        return step.1
    }
}

final class OfflineHTTP: HTTPTransport {
    func send(method: String, url: URL, headers: [String: String], body: Data?) throws -> HTTPResponse {
        throw URLError(.cannotConnectToHost)
    }
}

final class BackendTests: XCTestCase {
    private let secret = "session-secret-9f3a"

    func testDefaultsAndOldConfigDecode() throws {
        let config = RuntimeConfig(repoPath: "/r", cacheDir: "/c", stateDir: "/s", mountRoot: "/m", stubDir: "/a")
        XCTAssertEqual(config.quotaBytes, 20 * 1024 * 1024 * 1024)
        XCTAssertEqual(config.minFreeBytes, 15 * 1024 * 1024 * 1024)
        XCTAssertEqual(config.detachDelaySeconds, 120)
        XCTAssertEqual(config.signIdentity, "-")
        XCTAssertTrue(SpaceFloor.admits(freeBytes: 40, incoming: 10, floor: 15))
        XCTAssertFalse(SpaceFloor.admits(freeBytes: 20, incoming: 10, floor: 15))
        XCTAssertEqual(SigningIdentity.resolve(configured: "-", environment: [:]), "-")
        XCTAssertEqual(SigningIdentity.resolve(configured: "-", environment: ["DISKLESSLY_SIGN_IDENTITY": "Developer ID Application: Example"]), "Developer ID Application: Example")
        let old = Data(#"{"schema":"config/1","backend":"local","repoPath":"/r","cacheDir":"/c","stateDir":"/s","mountRoot":"/m","stubDir":"/a","quotaBytes":1,"detachDelaySeconds":9}"#.utf8)
        let decoded = try JSONDecoder().decode(RuntimeConfig.self, from: old)
        XCTAssertEqual(decoded.quotaBytes, 1)
        XCTAssertEqual(decoded.detachDelaySeconds, 9)
        XCTAssertEqual(decoded.minFreeBytes, 15 * 1024 * 1024 * 1024)
        XCTAssertEqual(decoded.signIdentity, "-")
        XCTAssertTrue(decoded.backends.isEmpty)
        let round = try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(round.repoPath, "/r")
        XCTAssertEqual(round.minFreeBytes, config.minFreeBytes)
    }

    func testShareMountCommandOmitsKeychainSecret() throws {
        let smb = ShareSpec(kind: "smb", host: "nas.local", share: "apps", user: "alice", mountPoint: "/Volumes/apps", alreadyMounted: false)
        let command = try XCTUnwrap(ShareMount.command(smb))
        XCTAssertEqual(command.executable, "/sbin/mount_smbfs")
        XCTAssertEqual(command.arguments, ["-N", "//alice@nas.local/apps", "/Volumes/apps"])
        XCTAssertFalse(command.rendered.contains(secret))
        XCTAssertNil(ShareMount.command(ShareSpec(kind: "smb", host: "nas.local", share: "apps", user: "alice", mountPoint: "/Volumes/apps", alreadyMounted: true)))
        let nfs = try XCTUnwrap(ShareMount.command(ShareSpec(kind: "nfs", host: "nas.local", share: "/export/apps", user: nil, mountPoint: "/Volumes/nfs", alreadyMounted: false)))
        XCTAssertEqual(nfs.arguments, ["nas.local:/export/apps", "/Volumes/nfs"])
        XCTAssertEqual(ShareMount.filesystemType(statExit: 0, statStdout: "smbfs\n"), "smbfs")
        XCTAssertEqual(ShareMount.filesystemType(statExit: 0, statStdout: "nfs\n"), "nfs")
        XCTAssertNil(ShareMount.filesystemType(statExit: 0, statStdout: "apfs\n"))
        XCTAssertNil(ShareMount.filesystemType(statExit: 1, statStdout: "无法识别映像"))
        XCTAssertThrowsError(try ShareMount.validate(user: "alice:\(secret)", host: "nas.local", share: "apps"))
    }

    func testBackendAddKeepsSecretOutOfConfig() throws {
        var draft = try BackendCommands.parseAdd(["smb", "--host", "nas.local", "--share", "apps", "--user", "alice", "--mount", "/Volumes/apps", "--id", "nas", "--password-stdin"])
        XCTAssertTrue(draft.readPasswordFromStdin)
        draft.password = secret
        let store = MemorySecretStore()
        let endpoint = try BackendCatalog.store(draft, secrets: store)
        var config = RuntimeConfig(repoPath: "/r", cacheDir: "/c", stateDir: "/s", mountRoot: "/m", stubDir: "/a")
        config.remember(endpoint)
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("password"))
        XCTAssertEqual(try store.load(service: BackendCatalog.keychainService, account: "smb:nas"), secret)
        XCTAssertEqual(store.mountCredentials.first?.host, "nas.local")
        XCTAssertEqual(store.mountCredentials.first?.secret, secret)
        XCTAssertThrowsError(try BackendCommands.parseAdd(["webdav", "--url", "https://dav.example/repo", "--password", secret])) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }
        let web = try BackendCommands.parseAdd(["webdav", "--url", "https://dav.example/repo", "--user", "alice", "--id", "dav"])
        XCTAssertEqual(web.user, "alice")
        XCTAssertNil(web.password)
    }

    func testMountedShareUsesTempDirAndRefusesRootDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let share = try MountedShareBackend(root: root, probe: { true })
        try share.put("images/a.dmg", data: Data("remote-bytes".utf8))
        XCTAssertEqual(try share.list("images"), ["a.dmg"])
        XCTAssertEqual(try share.stat("images/a.dmg")?.size, 12)
        XCTAssertEqual(try share.get("images/a.dmg", range: 0..<6), Data("remote".utf8))
        let cache = root.appendingPathComponent("not-on-share")
        try Data("remote-bytes".utf8).write(to: cache)
        try CacheEviction.evictLocal(cacheFile: cache) { try share.stat("images/a.dmg") != nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertNotNil(try share.stat("images/a.dmg"))
        XCTAssertThrowsError(try share.delete("")) { error in XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2) }
        XCTAssertThrowsError(try share.delete("."))
        let offline = try MountedShareBackend(root: root, probe: { false })
        XCTAssertThrowsError(try offline.list("")) { error in XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4) }
        XCTAssertNotNil(try share.stat("images/a.dmg"))
    }

    func testAlreadyMountedShareDoesNotRunMount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var ran = false
        let opener = ShareOpener(isMounted: { _ in true }, run: { _ in ran = true })
        let endpoint = BackendEndpoint(id: "nas", type: "smb", host: "nas.local", share: "apps", user: "alice", mountPoint: root.path, url: "smb://nas.local/apps")
        let store = MemorySecretStore()
        try store.save(service: BackendCatalog.keychainService, account: "smb:nas", secret: secret)
        let backend = try BackendFactory.open(endpoint, secrets: store, opener: opener)
        XCTAssertFalse(ran)
        try backend.put("images/a.dmg", data: Data("zz".utf8))
        XCTAssertEqual(try backend.get("images/a.dmg", range: nil), Data("zz".utf8))
        var calls = 0
        let missing = ShareOpener(isMounted: { _ in
            calls += 1
            return false
        }, run: { command in
            XCTAssertFalse(command.rendered.contains(self.secret))
            XCTAssertEqual(command.arguments.first, "-N")
        })
        XCTAssertThrowsError(try BackendFactory.open(endpoint, secrets: store, opener: missing)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
        }
        XCTAssertGreaterThan(calls, 0)
    }

    func testWebDAVPutListRangeAndRestart() throws {
        let script = ScriptedHTTP()
        let bytes = Data("abcdefghijklmnopqrstuvwxyz".utf8)
        let listXML = """
        <?xml version="1.0"?><multistatus xmlns="DAV:"><response><href>/dav/images/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/dav/images/a.dmg</href><propstat><prop><getcontentlength>26</getcontentlength><resourcetype></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>
        """.data(using: .utf8)!
        script.steps = [("PROPFIND", HTTPResponse(status: 207, body: listXML))]
        let backend = WebDAVBackend(baseURL: URL(string: "http://127.0.0.1:9/dav/")!, user: "alice", password: secret, transport: script)
        XCTAssertEqual(try backend.list("images"), ["a.dmg"])
        let auth = try XCTUnwrap(script.calls.first?.headers["Authorization"])
        XCTAssertEqual(auth, BasicAuth.header(user: "alice", password: secret))
        XCTAssertFalse(script.calls.contains { $0.url.contains(secret) })

        script.steps = [
            ("PUT", HTTPResponse(status: 201)),
            ("MOVE", HTTPResponse(status: 204)),
            ("GET", HTTPResponse(status: 200, body: bytes)),
        ]
        try backend.put("images/a.dmg", data: bytes)
        XCTAssertEqual(script.calls[1].method, "PUT")
        XCTAssertTrue(script.calls[1].url.contains("/.a.dmg.tmp-"))
        XCTAssertEqual(script.calls[2].headers["Overwrite"], "F")
        XCTAssertFalse(script.calls[2].headers.values.contains { $0.contains(secret) })

        script.steps = [("GET", HTTPResponse(status: 206, body: Data("xyz".utf8)))]
        let resumed = try backend.getResumable("images/a.dmg", offset: 23)
        XCTAssertFalse(resumed.restart)
        XCTAssertEqual(resumed.data, Data("xyz".utf8))
        XCTAssertEqual(script.calls.last?.headers["Range"], "bytes=23-")

        script.steps = [("GET", HTTPResponse(status: 200, body: bytes))]
        let restart = try backend.getResumable("images/a.dmg", offset: 4)
        XCTAssertTrue(restart.restart)
        XCTAssertEqual(restart.data, bytes)
        script.steps = [("PROPFIND", HTTPResponse(status: 207, body: listXML))]
        XCTAssertEqual(try backend.entries("images"), [BackendEntry(name: "a.dmg", isDirectory: false, size: 26)])
        XCTAssertThrowsError(try backend.delete("")) { error in XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2) }
        let offline = WebDAVBackend(baseURL: URL(string: "http://127.0.0.1:9/dav/")!, user: nil, password: nil, transport: OfflineHTTP())
        XCTAssertThrowsError(try offline.stat("images/a.dmg")) { error in XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4) }
    }

    func testResumableFetchVerifiesHashAgainstFixtureServer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/webdav_fixture.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [fixture.path, root.appendingPathComponent("dav").path, "alice", secret]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate() }
        let port = try readLine(output.fileHandleForReading)
        let backend = WebDAVBackend(
            baseURL: URL(string: "http://127.0.0.1:\(port)/dav/")!,
            user: "alice",
            password: secret,
            transport: URLSessionTransport(origin: "127.0.0.1")
        )
        let bytes = Data("abcdefghijklmnopqrstuvwxyz".utf8)
        try backend.ensureCollection("images")
        try backend.put("images/a.dmg", data: bytes)
        XCTAssertEqual(try backend.list("images"), ["a.dmg"])
        XCTAssertEqual(try backend.stat("images/a.dmg")?.size, 26)
        let destination = cache.appendingPathComponent("images/a.dmg")
        let partial = cache.appendingPathComponent("partial/a.dmg.part")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abcdef".utf8).write(to: partial)
        try CacheFetcher.materialize(backend: backend, remote: "images/a.dmg", destination: destination, partial: partial, expectedSize: 26, expectedSHA256: SHA256Digest.hex(bytes))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try backend.delete("images/a.dmg")
        XCTAssertNil(try backend.stat("images/a.dmg"))
        process.terminate()
        process.waitUntilExit()
        let dead = WebDAVBackend(baseURL: URL(string: "http://127.0.0.1:\(port)/dav/")!, user: "alice", password: secret, transport: URLSessionTransport())
        XCTAssertThrowsError(try dead.list("images")) { error in XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4) }
    }

    func testPrefetchStillRejectsACorruptRemoteAndAFullDiskFloor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        config.minFreeBytes = 0
        let engine = DisklesslyEngine(config: config)
        try engine.initialize()
        let bytes = Data("published disk image bytes".utf8)
        let source = root.appendingPathComponent("source.dmg")
        try bytes.write(to: source)
        let sha = SHA256Digest.hex(bytes)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "Test", appPathInVolume: "Test.app")
        let manifest = ImageManifest(bundleId: "com.test.app", name: "Test", version: "1", image: image, app: .init(originalPath: "/Applications/Test.app", executable: "Test", documentTypes: [], urlTypes: []))
        try LocalFolderBackend(root: root.appendingPathComponent("repo")).put(manifest.image.file, data: bytes + Data("corruption".utf8))
        XCTAssertThrowsError(try engine.prefetch(manifest)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5)
        }
        config.minFreeBytes = .max
        var blocked = DisklesslyEngine(config: config)
        blocked.backendOverride = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        try LocalFolderBackend(root: root.appendingPathComponent("repo")).put(manifest.image.file, data: bytes)
        XCTAssertThrowsError(try blocked.prefetch(manifest)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 8)
        }
        XCTAssertEqual(try blocked.repo.stat(manifest.image.file)?.size, UInt64(bytes.count))
    }

    private func readLine(_ handle: FileHandle) throws -> String {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.contains(10) { break }
        }
        let text = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = text.split(separator: "\n").first, !port.isEmpty else {
            throw DisklesslyError.failure("fixture did not print a port")
        }
        return String(port)
    }
}
