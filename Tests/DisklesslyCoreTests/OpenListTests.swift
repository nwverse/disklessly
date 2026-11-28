import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DisklesslyCore
import DisklesslyEngine

final class OpenListTests: XCTestCase {
    private let secret = "openlist-secret-9f3a"

    func testAddStoresTokenMaterialOnlyInTheKeychain() throws {
        var draft = try BackendCommands.parseAdd(["openlist", "--url", "http://nas.local:5244", "--root", "/Disklessly", "--user", "alice", "--id", "ol", "--password-stdin"])
        draft.password = secret
        let store = MemorySecretStore()
        let endpoint = try BackendCatalog.store(draft, secrets: store)
        var config = RuntimeConfig(repoPath: "/r", cacheDir: "/c", stateDir: "/s", mountRoot: "/m", stubDir: "/a")
        config.remember(endpoint)
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertEqual(endpoint.root, "/Disklessly")
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
        XCTAssertEqual(try backend.entries(""), [BackendEntry(name: "images", isDirectory: true)])
        XCTAssertEqual(try backend.entries("images"), [BackendEntry(name: "a.dmg", isDirectory: false, size: 26)])
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
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
        }
    }

    func testUploadJSONErrorFailsBeforeVerificationAndPreservesObject() throws {
        let transport = StatefulOpenListHTTP()
        transport.object = Data("OLD-REMOTE-CONTENT".utf8)
        transport.uploadResponse = transport.json(code: 500, message: "quota exceeded")
        let backend = try openListBackend(transport)

        XCTAssertThrowsError(try backend.put("folder/object.bin", data: Data("NEW-UPLOAD-CONTENT".utf8))) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
            XCTAssertTrue(error.localizedDescription.contains("quota exceeded"))
        }
        XCTAssertEqual(transport.object, Data("OLD-REMOTE-CONTENT".utf8))
        XCTAssertEqual(transport.putCount, 1)
        XCTAssertEqual(transport.metadataGetCount, 0)
        XCTAssertEqual(transport.removeCount, 0)
    }

    func testUploadHashMismatchDoesNotDeletePreviousObject() throws {
        let transport = StatefulOpenListHTTP()
        transport.object = Data("OLD-REMOTE-CONTENT".utf8)
        transport.acceptUpload = false
        let backend = try openListBackend(transport)

        XCTAssertThrowsError(try backend.put("folder/object.bin", data: Data("NEW-UPLOAD-CONTENT".utf8))) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5)
        }
        XCTAssertEqual(transport.object, Data("OLD-REMOTE-CONTENT".utf8))
        XCTAssertEqual(transport.removeCount, 0)
    }

    func testRestartRangeClampsUInt64Bounds() throws {
        let transport = StatefulOpenListHTTP()
        transport.object = Data("abc".utf8)
        let backend = try openListBackend(transport)

        XCTAssertEqual(try backend.get("object", range: 1..<UInt64.max), Data("bc".utf8))
        XCTAssertEqual(transport.calls.first { $0.method == "GET" }?.headers["Range"], "bytes=1-")
    }

    func testWriteOnceRefusesExistingObjectWithoutUpload() throws {
        let transport = StatefulOpenListHTTP()
        let backend = try openListBackend(transport)
        try backend.put("objects/x", data: Data("old".utf8))
        let uploadsBefore = transport.putCount

        XCTAssertThrowsError(try WriteOnceScope.run { try backend.put("objects/x", data: Data("new".utf8)) }) { error in
            XCTAssertEqual(error as? WriteOnceConflict, WriteOnceConflict(path: "objects/x"))
        }
        XCTAssertEqual(transport.object, Data("old".utf8))
        XCTAssertEqual(transport.putCount, uploadsBefore)
    }

    func testWriteOnceFailsClosedWhenObjectIsAbsent() throws {
        let transport = StatefulOpenListHTTP()
        let backend = try openListBackend(transport)

        XCTAssertThrowsError(try WriteOnceScope.run { try backend.put("objects/x", data: Data("new".utf8)) }) { error in
            guard let error = error as? DisklesslyError,
                  case .unsupported(let message) = error else {
                return XCTFail("expected unsupported, got \(error)")
            }
            XCTAssertTrue(message.contains("atomically"))
        }
        XCTAssertNil(transport.object)
        XCTAssertEqual(transport.putCount, 0)
    }

    func testConcurrentWriteOnceClientsFailClosedBeforeUpload() throws {
        let transport = StatefulOpenListHTTP()
        let first = try openListBackend(transport)
        let second = try openListBackend(transport)
        let gate = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var outcomes: [Result<WriteOnceResult, Error>] = []

        for backend in [first, second] {
            gate.enter()
            DispatchQueue.global().async {
                start.wait()
                let outcome = Result { try WriteOnce.publish(backend: backend, path: "objects/x", data: Data("new".utf8)) }
                resultLock.lock()
                outcomes.append(outcome)
                resultLock.unlock()
                gate.leave()
            }
        }
        start.signal()
        start.signal()
        gate.wait()

        XCTAssertEqual(outcomes.count, 2)
        for outcome in outcomes {
            guard case .failure(let error) = outcome,
                  let error = error as? DisklesslyError,
                  case .unsupported = error else {
                return XCTFail("expected both clients to fail closed, got \(outcomes)")
            }
        }
        XCTAssertNil(transport.object)
        XCTAssertEqual(transport.putCount, 0)
    }

    private func openListBackend(_ transport: StatefulOpenListHTTP) throws -> OpenListBackend {
        let store = MemorySecretStore()
        try store.save(service: BackendCatalog.keychainService, account: "openlist-token:openlist:ol", secret: "fixture-token")
        return OpenListBackend(
            baseURL: URL(string: "https://openlist.invalid/")!,
            root: "/repo",
            user: "alice",
            password: secret,
            transport: transport,
            secrets: store,
            secretAccount: "openlist:ol"
        )
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
            throw DisklesslyError.failure("fixture did not print a port")
        }
        return String(port)
    }
}

private final class StatefulOpenListHTTP: HTTPTransport {
    struct Call {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data?
    }

    let rawURL = "https://objects.invalid/object"
    var object: Data?
    var uploadResponse: HTTPResponse?
    var acceptUpload = true
    private(set) var calls: [Call] = []
    private(set) var putCount = 0
    private(set) var metadataGetCount = 0
    private(set) var removeCount = 0
    private let lock = NSLock()

    func send(method: String, url: URL, headers: [String: String], body: Data?) throws -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(method: method, url: url.absoluteString, headers: headers, body: body))
        let path = url.path
        if method == "PUT" && path == "/api/fs/put" {
            putCount += 1
            if let uploadResponse { return uploadResponse }
            if acceptUpload { object = body ?? Data() }
            return json(code: 200, message: "success")
        }
        if method == "POST" && path == "/api/fs/get" {
            metadataGetCount += 1
            guard let object else { return json(code: 500, message: "not found") }
            return json(code: 200, message: "success", data: ["size": NSNumber(value: object.count), "raw_url": rawURL])
        }
        if method == "POST" && path == "/api/fs/remove" {
            removeCount += 1
            object = nil
            return json(code: 200, message: "success")
        }
        if method == "GET" && url.absoluteString == rawURL {
            guard let object else { return HTTPResponse(status: 404) }
            return HTTPResponse(status: 200, body: object)
        }
        if method == "POST" && path == "/api/auth/login" {
            return json(code: 200, message: "success", data: ["token": "fixture-token"])
        }
        return HTTPResponse(status: 404)
    }

    func json(code: Int, message: String, data: Any? = nil) -> HTTPResponse {
        var payload: [String: Any] = ["code": code, "message": message]
        if let data { payload["data"] = data }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }
}
