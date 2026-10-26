import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IsenoughCore
import IsenoughEngine

final class UIServerTests: XCTestCase {
    func testLoopbackRequiresToken() throws {
        let server = LoopbackUIServer(token: "ui-token-9f3a") { request in
            UIResponse.json(["ok": true, "path": request.path])
        }
        try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)
        let denied = try request(port: server.port, path: "/api/status", token: nil)
        XCTAssertEqual(denied.status, 401)
        XCTAssertFalse(String(decoding: denied.body, as: UTF8.self).contains("\"path\""))
        let allowed = try request(port: server.port, path: "/api/status?token=ui-token-9f3a", token: nil)
        XCTAssertEqual(allowed.status, 200)
        let bearer = try request(port: server.port, path: "/api/status", token: "ui-token-9f3a")
        XCTAssertEqual(bearer.status, 200)
    }

    func testPageInjectsTokenAndApiPinsEvicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let web = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<link rel=\"stylesheet\" href=\"style.css\"><script type=\"module\" src=\"app.js\"></script>".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("console.log('ui')".utf8).write(to: web.appendingPathComponent("app.js"))
        try Data("body{}".utf8).write(to: web.appendingPathComponent("style.css"))
        let repo = root.appendingPathComponent("repo")
        let cache = root.appendingPathComponent("cache")
        var config = RuntimeConfig(repoPath: repo.path, cacheDir: cache.path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        config.backends = [BackendEndpoint(id: "nas", type: "smb", host: "nas.local", mountPoint: "/Volumes/apps")]
        config.activeBackendId = "nas"
        var engine = IsenoughEngine(config: config, secrets: MemorySecretStore())
        engine.backendOverride = try LocalFolderBackend(root: repo)
        try engine.initialize()
        let bytes = Data("cached image".utf8)
        let sha = SHA256Digest.hex(bytes)
        let image = ImageManifest.Image(file: "images/test.dmg", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "Test", appPathInVolume: "Test.app")
        let manifest = ImageManifest(bundleId: "com.test.app", name: "Test", version: "1", image: image, app: .init(originalPath: "/Applications/Test.app", executable: "Test", documentTypes: [], urlTypes: []))
        try LocalFolderBackend(root: repo).put("manifests/\(manifest.imageId).json", data: try manifest.encode())
        let cached = cache.appendingPathComponent("images/\(manifest.imageId).dmg")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: cached)
        let entry = SessionIndexEntry(id: "abc123", tool: "pi", path: "/tmp/session.jsonl", sha256: sha, size: 4, modified: Date(timeIntervalSince1970: 1_700_000_000), archive: "sessions/pi/2023-11.tar.gz", member: "pi/abc-session.jsonl", preview: "blender notes")
        try SessionArchive.saveIndex(SessionIndex(entries: [entry]), stateDir: config.stateDir)
        let server = LoopbackUIServer(token: "page-token") { request in
            ManagementUI.respond(engine: engine, webRoot: web, request: request)
        }
        try server.start()
        defer { server.stop() }
        let page = try request(port: server.port, path: "/?token=page-token", token: nil)
        XCTAssertEqual(page.status, 200)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("app.js?token=page-token"))
        XCTAssertTrue(html.contains("style.css?token=page-token"))
        let script = try request(port: server.port, path: "/app.js?token=page-token", token: nil)
        XCTAssertEqual(script.status, 200)
        XCTAssertEqual(String(decoding: script.body, as: UTF8.self), "console.log('ui')")
        let status = try request(port: server.port, path: "/api/status", token: "page-token")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: status.body) as? [String: Any])
        let apps = try XCTUnwrap(object["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.first?["name"] as? String, "Test")
        XCTAssertEqual(apps.first?["cached"] as? Bool, true)
        XCTAssertEqual(apps.first?["remote"] as? Bool, false)
        XCTAssertEqual(apps.first?["pinned"] as? Bool, false)
        XCTAssertEqual(apps.first?["restored"] as? Bool, false)
        let backend = try XCTUnwrap(object["backend"] as? [String: Any])
        XCTAssertEqual(backend["health"] as? String, "ok")
        XCTAssertEqual(backend["activeId"] as? String, "nas")
        let sessions = try XCTUnwrap(object["sessions"] as? [String: Any])
        let offloaded = try XCTUnwrap(sessions["offloaded"] as? [[String: Any]])
        XCTAssertEqual(offloaded.first?["tier"] as? String, "cold")
        XCTAssertEqual(offloaded.first?["preview"] as? String, "blender notes")
        let cacheInfo = try XCTUnwrap(object["cache"] as? [String: Any])
        XCTAssertGreaterThan((cacheInfo["usedBytes"] as? NSNumber)?.uint64Value ?? 0, 0)
        XCTAssertEqual((cacheInfo["quotaBytes"] as? NSNumber)?.uint64Value, 20 * 1024 * 1024 * 1024)
        let pin = try request(port: server.port, path: "/api/pin", token: "page-token", method: "POST", body: Data("{\"app\":\"Test\"}".utf8))
        XCTAssertEqual(pin.status, 200)
        let pinned = StateStore(config.stateDir).read()["apps"] as? [String: [String: Any]]
        XCTAssertEqual(pinned?["com.test.app"]?["pinned"] as? Bool, true)
        let evict = try request(port: server.port, path: "/api/evict", token: "page-token", method: "POST", body: Data("{\"app\":\"Test\"}".utf8))
        XCTAssertEqual(evict.status, 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("manifests/\(manifest.imageId).json").path))
        let restore = try request(port: server.port, path: "/api/restore", token: "page-token", method: "POST", body: Data("{\"app\":\"Test\"}".utf8))
        let restoreBody = try XCTUnwrap(JSONSerialization.jsonObject(with: restore.body) as? [String: Any])
        XCTAssertEqual(restoreBody["ok"] as? Bool, false)
        XCTAssertFalse((restoreBody["error"] as? String ?? "").isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("manifests/\(manifest.imageId).json").path))
    }

    func testShippedPageKeepsTokenAndLocalAssets() throws {
        let web = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/isenough/web")
        let html = try String(contentsOf: web.appendingPathComponent("index.html"), encoding: .utf8)
        let css = try String(contentsOf: web.appendingPathComponent("style.css"), encoding: .utf8)
        let js = try String(contentsOf: web.appendingPathComponent("app.js"), encoding: .utf8)
        XCTAssertLessThan(html.range(of: "id=\"banner\"").map { $0.lowerBound } ?? html.endIndex, html.range(of: "class=\"grid\"").map { $0.lowerBound } ?? html.startIndex)
        XCTAssertTrue(html.contains("href=\"style.css\""))
        XCTAssertTrue(html.contains("src=\"app.js\""))
        XCTAssertTrue(html.contains("id=\"recommend-section\""))
        XCTAssertTrue(html.contains("id=\"banner\""))
        XCTAssertTrue(html.contains("role=\"alert\""))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(css.contains("http://"))
        XCTAssertFalse(css.contains("https://"))
        XCTAssertTrue(css.contains("font-size: 52px"))
        XCTAssertTrue(css.contains("min-height: 44px"))
        XCTAssertTrue(html.contains("id=\"recommend-leftovers\""))
        XCTAssertTrue(js.contains("值得卸载"))
        XCTAssertTrue(js.contains("Worth offloading"))
        XCTAssertTrue(js.contains("残留备份"))
        XCTAssertTrue(js.contains("can be removed"))
        XCTAssertTrue(js.contains("Removing them needs an administrator."))
        XCTAssertTrue(js.contains("/api/recommend"))
        XCTAssertTrue(js.contains("清除缓存"))
        XCTAssertTrue(js.contains("运行正常"))
        XCTAssertTrue(js.contains("已缓存"))
        XCTAssertTrue(js.contains("远端"))
        XCTAssertTrue(js.contains("已固定"))
        XCTAssertTrue(js.contains("if (pct >= 95) return \"hot\""))
        XCTAssertTrue(js.contains("if (pct >= 80) return \"warn\""))
        XCTAssertFalse(js.contains("innerHTML"))
        let remote = js.replacingOccurrences(of: "http://www.w3.org/2000/svg", with: "")
        XCTAssertFalse(remote.contains("http://"))
        XCTAssertFalse(remote.contains("https://"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let config = RuntimeConfig(repoPath: repo.path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        var engine = IsenoughEngine(config: config, secrets: MemorySecretStore())
        engine.backendOverride = try LocalFolderBackend(root: repo)
        try engine.initialize()
        let server = LoopbackUIServer(token: "page-token") { request in
            ManagementUI.respond(engine: engine, webRoot: web, request: request)
        }
        try server.start()
        defer { server.stop() }
        let page = try request(port: server.port, path: "/?token=page-token", token: nil)
        XCTAssertEqual(page.status, 200)
        let served = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(served.contains("app.js?token=page-token"))
        XCTAssertTrue(served.contains("style.css?token=page-token"))
        XCTAssertTrue(served.contains("id=\"banner\""))
        let style = try request(port: server.port, path: "/style.css?token=page-token", token: nil)
        XCTAssertEqual(style.status, 200)
        XCTAssertTrue(String(decoding: style.body, as: UTF8.self).contains("font-size: 52px"))
        let script = try request(port: server.port, path: "/app.js?token=page-token", token: nil)
        XCTAssertEqual(script.status, 200)
        XCTAssertTrue(String(decoding: script.body, as: UTF8.self).contains("清除缓存"))
        let status = try request(port: server.port, path: "/api/status", token: "page-token")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: status.body) as? [String: Any])
        let cacheInfo = try XCTUnwrap(object["cache"] as? [String: Any])
        XCTAssertNotNil(cacheInfo["minFreeBytes"])
        XCTAssertNotNil(cacheInfo["quotaBytes"])
        XCTAssertNotNil(cacheInfo["detachDelaySeconds"])
        let backend = try XCTUnwrap(object["backend"] as? [String: Any])
        XCTAssertEqual(backend["health"] as? String, "ok")
    }

    private func request(port: UInt16, path: String, token: String?, method: String = "GET", body: Data? = nil) throws -> (status: Int, body: Data) {
        let target = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.data = data ?? Data()
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        return (box.status, box.data)
    }
}

private final class ResponseBox: @unchecked Sendable {
    var status = 0
    var data = Data()
}
