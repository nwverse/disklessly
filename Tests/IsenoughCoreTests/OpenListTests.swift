import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IsenoughCore
import IsenoughEngine

final class OpenListTests: XCTestCase {
    private let secret = "openlist-secret-9f3a"

    func testAddStoresTokenMaterialOnlyInTheKeychain() throws {
        var draft = try BackendCommands.parseAdd(["openlist", "--url", "http://nas.local:5244", "--root", "/256isenough", "--user", "alice", "--id", "ol", "--password-stdin"])
        draft.password = secret
        let store = MemorySecretStore()
        let endpoint = try BackendCatalog.store(draft, secrets: store)
        var config = RuntimeConfig(repoPath: "/r", cacheDir: "/c", stateDir: "/s", mountRoot: "/m", stubDir: "/a")
        config.remember(endpoint)
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertEqual(endpoint.root, "/256isenough")
        XCTAssertEqual(endpoint.type, "openlist")
        XCTAssertEqual(try store.load(service: BackendCatalog.keychainService, account: "openlist:ol"), secret)
        XCTAssertEqual(OpenListAPI.supportedVersions.contains("AList 3"), true)
        XCTAssertThrowsError(try BackendCommands.parseAdd(["openlist", "--url", "http://nas.local:5244"]))
    }

    func testFixtureLoginListPutAndResumableDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openlist_fixture.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [fixture.path, root.appendingPathComponent("remote").path, "alice", secret]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate() }
        let port = try readLine(output.fileHandleForReading)
        let store = MemorySecretStore()
        try store.save(service: BackendCatalog.keychainService, account: "openlist:ol", secret: secret)
        try store.save(service: BackendCatalog.keychainService, account: "openlist-token:openlist:ol", secret: "stale-token")
        let backend = OpenListBackend(
            baseURL: URL(string: "http://127.0.0.1:\(port)/")!,
            root: "/repo",
            user: "alice",
            password: secret,
            transport: URLSessionTransport(origin: "127.0.0.1"),
            secrets: store,
            secretAccount: "openlist:ol"
        )
        let bytes = Data("abcdefghijklmnopqrstuvwxyz".utf8)
        try backend.ensureCollection("images")
        try backend.put("images/a.dmg", data: bytes)
        XCTAssertEqual(try backend.list("images"), ["a.dmg"])
        XCTAssertEqual(try backend.stat("images/a.dmg")?.size, 26)
        XCTAssertEqual(try store.load(service: BackendCatalog.keychainService, account: "openlist-token:openlist:ol"), "openlist-token-fixture")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(BackendEndpoint(id: "ol", type: "openlist", user: "alice", url: "http://127.0.0.1:\(port)/", root: "/repo")), as: UTF8.self).contains(secret))
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
        XCTAssertThrowsError(try backend.list("images")) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 4)
        }
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
        guard let port = String(decoding: buffer, as: UTF8.self).split(separator: "\n").first, !port.isEmpty else {
            throw IsenoughError.failure("fixture did not print a port")
        }
        return String(port)
    }
}
