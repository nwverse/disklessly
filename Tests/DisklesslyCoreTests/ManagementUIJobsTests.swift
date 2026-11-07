import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DisklesslyCore
import DisklesslyEngine

/// Background jobs, error codes, and the recommend cache behind `disklessly ui`.
final class ManagementUIJobsTests: XCTestCase {
    func testJobLifecycleKeepsStatusResponsiveAndRejectsSecondJob() throws {
        let world = try World()
        defer { world.cleanup() }
        let release = DispatchSemaphore(value: 0)
        let calls = CallLog()
        let context = ManagementUIContext(actions: ManagementActions { kind, app, progress in
            calls.append("\(kind.rawValue):\(app)")
            progress.phase("download")
            _ = release.wait(timeout: .now() + 10)
            progress.phase("open")
        })
        let server = world.server(context: context)
        try server.start()
        defer { server.stop() }

        let started = try world.post(server, "/api/launch", app: "Test")
        XCTAssertEqual(started.status, 202)
        let jobId = try XCTUnwrap(started.object["jobId"] as? String)
        XCTAssertEqual(started.object["state"] as? String, "running")

        // Phase is visible while the action runs.
        var job: [String: Any] = [:]
        for _ in 0..<100 {
            job = try world.get(server, "/api/jobs/\(jobId)").object
            if job["phase"] as? String == "download" { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(job["state"] as? String, "running")
        XCTAssertEqual(job["phase"] as? String, "download")
        XCTAssertEqual(job["kind"] as? String, "launch")

        // The dashboard answers during the long action and lists the job.
        let clock = Date()
        let status = try world.get(server, "/api/status")
        XCTAssertEqual(status.status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(clock), 2)
        let active = try XCTUnwrap(status.object["jobs"] as? [[String: Any]])
        XCTAssertEqual(active.first?["id"] as? String, jobId)

        // A second action on the same app is refused with the running job's id.
        let second = try world.post(server, "/api/evict", app: "test")
        XCTAssertEqual(second.status, 409)
        XCTAssertEqual((second.object["error"] as? [String: Any])?["code"] as? String, "busy")
        XCTAssertEqual(second.object["jobId"] as? String, jobId)

        release.signal()
        let finished = try XCTUnwrap(context.jobs.wait(jobId, timeout: 5))
        XCTAssertEqual(finished.state, .done)
        XCTAssertEqual(finished.phase, "open")
        let polled = try world.get(server, "/api/jobs/\(jobId)").object
        XCTAssertEqual(polled["state"] as? String, "done")
        XCTAssertNil(polled["error"])
        XCTAssertEqual(calls.values, ["launch:Test"])
        XCTAssertEqual((try world.get(server, "/api/status").object["jobs"] as? [[String: Any]])?.count, 0)

        let missing = try world.get(server, "/api/jobs/nope")
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual((missing.object["error"] as? [String: Any])?["code"] as? String, "unknown_job")
        let noApp = try world.post(server, "/api/prefetch", app: "")
        XCTAssertEqual(noApp.status, 400)
    }

    func testEveryActionPathStartsAJob() throws {
        let world = try World()
        defer { world.cleanup() }
        let calls = CallLog()
        let context = ManagementUIContext(actions: ManagementActions { kind, app, _ in calls.append("\(kind.rawValue):\(app)") })
        let server = world.server(context: context)
        try server.start()
        defer { server.stop() }
        for kind in UIJobKind.allCases where kind != .pack && !kind.isDev {
            let started = try world.post(server, "/api/\(kind.rawValue)", app: "App-\(kind.rawValue)")
            XCTAssertEqual(started.status, 202, kind.rawValue)
            let id = try XCTUnwrap(started.object["jobId"] as? String)
            XCTAssertEqual(context.jobs.wait(id, timeout: 5)?.state, .done)
        }
        XCTAssertEqual(Set(calls.values), Set(UIJobKind.allCases.filter { $0 != .pack && !$0.isDev }.map { "\($0.rawValue):App-\($0.rawValue)" }))
    }

    func testPackJobNeedsAnInstalledAppPathAndPassesItOn() throws {
        let world = try World()
        defer { world.cleanup() }
        let seen = CallLog()
        let context = ManagementUIContext(actions: ManagementActions(perform: { kind, app, options, _ in seen.append("\(kind.rawValue):\(app):\(options.path ?? "-")") }))
        let server = world.server(context: context)
        try server.start()
        defer { server.stop() }
        func post(_ body: [String: Any]) throws -> (status: Int, object: [String: Any]) {
            try world.postRaw(server, "/api/pack", body: try JSONSerialization.data(withJSONObject: body))
        }
        XCTAssertEqual(try post(["app": "X"]).status, 400, "no path")
        XCTAssertEqual(try post(["app": "X", "path": "/tmp/X.app"]).status, 400, "outside Applications")
        XCTAssertEqual(try post(["app": "X", "path": "/Applications/../tmp/X.app"]).status, 400, "traversal")
        XCTAssertEqual(try post(["app": "X", "path": "/Applications"]).status, 400, "not an app")
        XCTAssertEqual(try post(["app": "X", "path": "/Applications/Nope-\(UUID().uuidString).app"]).status, 400, "missing")
        let installed = try FileManager.default.contentsOfDirectory(atPath: "/Applications").first { $0.hasSuffix(".app") }
        let name = try XCTUnwrap(installed, "no app installed in /Applications")
        let started = try post(["app": "X", "path": "/Applications/\(name)"])
        XCTAssertEqual(started.status, 202)
        let id = try XCTUnwrap(started.object["jobId"] as? String)
        XCTAssertEqual(context.jobs.wait(id, timeout: 5)?.state, .done)
        XCTAssertEqual(seen.values, ["pack:X:/Applications/\(name)"])
    }

    func testFailedJobsCarryStableCodes() throws {
        let world = try World()
        defer { world.cleanup() }
        let context = ManagementUIContext(actions: ManagementActions { _, app, _ in
            switch app {
            case "integrity": throw DisklesslyError.integrity("sha256 mismatch")
            case "space": throw DisklesslyError.noSpace("free space would fall below the floor")
            case "offline": throw DisklesslyError.backend("SMB share is not mounted")
            case "busy": throw DisklesslyError.busy("restore transaction in progress")
            default: throw UIJobError.unknownApp(app)
            }
        })
        let server = world.server(context: context)
        try server.start()
        defer { server.stop() }
        for (app, code) in [("integrity", "integrity"), ("space", "no_space"), ("offline", "offline"), ("busy", "busy"), ("Ghost", "unknown_app")] {
            let id = try XCTUnwrap(try world.post(server, "/api/prefetch", app: app).object["jobId"] as? String)
            XCTAssertEqual(context.jobs.wait(id, timeout: 5)?.state, .failed)
            let job = try world.get(server, "/api/jobs/\(id)").object
            XCTAssertEqual(job["state"] as? String, "failed")
            let error = try XCTUnwrap(job["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, code, app)
            XCTAssertFalse((error["message"] as? String ?? "").isEmpty)
        }
    }

    func testErrorCodeMapping() {
        let cases: [(Error, String)] = [
            (UIJobError.unknownApp("X"), "unknown_app"),
            (DisklesslyError.backend("down"), "offline"),
            (DisklesslyError.integrity("bad"), "integrity"),
            (DisklesslyError.noSpace("full"), "no_space"),
            (DisklesslyError.busy("busy"), "busy"),
            (DisklesslyError.usage("bad"), "bad_request"),
            (DisklesslyError.unsupported("linux"), "unsupported"),
            (DisklesslyError.resolution("pick"), "needs_resolution"),
            (DisklesslyError.diskImage("hdiutil"), "failed"),
            (DisklesslyError.failure("x"), "failed"),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), "offline"),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), "no_space"),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), "no_space"),
            (NSError(domain: "other", code: 1), "failed"),
        ]
        for (error, code) in cases {
            let info = ManagementUI.errorInfo(error)
            XCTAssertEqual(info.code, code, "\(error)")
            XCTAssertFalse(info.message.isEmpty, "\(error)")
        }
        XCTAssertEqual(ManagementUI.errorInfo(UIJobError.unknownApp("Blender")).message, "Unknown app: Blender")
    }

    func testRecommendIsCachedUntilRescan() throws {
        let world = try World()
        defer { world.cleanup() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let context = ManagementUIContext(actions: ManagementActions { _, _, _ in }, now: { clock })
        let server = world.server(context: context)
        try server.start()
        defer { server.stop() }

        let first = try world.get(server, "/api/recommend").object
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual(first["cached"] as? Bool, false)
        let firstStamp = try XCTUnwrap(first["scannedAt"] as? String)
        clock = clock.addingTimeInterval(600)
        let second = try world.get(server, "/api/recommend").object
        XCTAssertEqual(second["cached"] as? Bool, true)
        XCTAssertEqual(second["scannedAt"] as? String, firstStamp)
        let rescanned = try world.get(server, "/api/recommend?rescan=1").object
        XCTAssertEqual(rescanned["cached"] as? Bool, false)
        XCTAssertNotEqual(rescanned["scannedAt"] as? String, firstStamp)
        let other = try world.get(server, "/api/recommend?limit=1").object
        XCTAssertEqual(other["cached"] as? Bool, false, "different options are a different scan")
        let bad = try world.get(server, "/api/recommend?limit=abc")
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual((bad.object["error"] as? [String: Any])?["code"] as? String, "bad_request")

        var scans = 0
        let direct = ManagementUIContext()
        for rescan in [false, false, true, false] {
            _ = direct.recommendations(key: "k", rescan: rescan) {
                scans += 1
                return ["n": scans]
            }
        }
        XCTAssertEqual(scans, 2)
    }

    func testStatusRowsCarryStateLastUsedAndImageSize() throws {
        let world = try World()
        defer { world.cleanup() }
        let used = Date(timeIntervalSince1970: 1_750_000_000)
        try StateStore(world.config.stateDir).update { state in
            state.apps["com.test.app"] = AppState(imageId: world.manifest.imageId, state: "cached", lastUsed: used, needsResolution: ["reason": .string("diverged")])
        }
        let server = world.server(context: ManagementUIContext(actions: ManagementActions { _, _, _ in }))
        try server.start()
        defer { server.stop() }
        let status = try world.get(server, "/api/status").object
        let row = try XCTUnwrap((status["apps"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["state"] as? String, "needsResolution")
        XCTAssertEqual(row["needsResolution"] as? Bool, true)
        XCTAssertEqual(row["mounted"] as? Bool, false)
        XCTAssertEqual(row["lastUsed"] as? String, ISO8601DateFormatter().string(from: used))
        XCTAssertEqual((row["imageBytes"] as? NSNumber)?.uint64Value, world.manifest.image.size)
        XCTAssertEqual(row["remote"] as? Bool, true)
    }

    func testJobStoreDropsOldFinishedJobs() {
        let store = UIJobStore(retained: 3)
        var ids: [String] = []
        for index in 0..<6 {
            if case .started(let job) = store.start(kind: .prefetch, app: "a\(index)", work: { _ in }) {
                ids.append(job.id)
                _ = store.wait(job.id, timeout: 5)
            }
        }
        XCTAssertEqual(ids.count, 6)
        XCTAssertLessThanOrEqual(store.all().count, 4)
        XCTAssertNotNil(store.job(ids[5]))
        XCTAssertNil(store.job(ids[0]))
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Temp repo with one remote manifest; nothing touches /Applications or the user's state.
private struct World {
    let root: URL
    let config: RuntimeConfig
    let engine: DisklesslyEngine
    let manifest: ImageManifest
    let token = "jobs-token"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-jobs-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        config = RuntimeConfig(repoPath: repo.path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.backendOverride = try LocalFolderBackend(root: repo)
        engine.recommendEnvironment = .unavailable
        try engine.initialize()
        let bytes = Data("remote image".utf8)
        let image = ImageManifest.Image(file: "images/test.dmg", format: "ULMO", sha256: SHA256Digest.hex(bytes), size: UInt64(bytes.count), volumeName: "Test", appPathInVolume: "Test.app")
        manifest = ImageManifest(bundleId: "com.test.app", name: "Test", version: "1", image: image, app: .init(originalPath: "/Applications/Test.app", executable: "Test", documentTypes: [], urlTypes: []))
        try LocalFolderBackend(root: repo).put("manifests/\(manifest.imageId).json", data: try manifest.encode())
        self.engine = engine
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func server(context: ManagementUIContext) -> LoopbackUIServer {
        let engine = self.engine
        return LoopbackUIServer(token: token) { request in
            ManagementUI.respond(engine: engine, webRoot: nil, request: request, context: context)
        }
    }

    func get(_ server: LoopbackUIServer, _ path: String) throws -> (status: Int, object: [String: Any]) {
        try send(server, path, method: "GET", body: nil)
    }

    func post(_ server: LoopbackUIServer, _ path: String, app: String) throws -> (status: Int, object: [String: Any]) {
        try send(server, path, method: "POST", body: try JSONSerialization.data(withJSONObject: ["app": app]))
    }

    func postRaw(_ server: LoopbackUIServer, _ path: String, body: Data) throws -> (status: Int, object: [String: Any]) {
        try send(server, path, method: "POST", body: body)
    }

    private func send(_ server: LoopbackUIServer, _ path: String, method: String, body: Data?) throws -> (status: Int, object: [String: Any]) {
        let target = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(path)"))
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.data = data ?? Data()
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        let object = (try? JSONSerialization.jsonObject(with: box.data)) as? [String: Any] ?? [:]
        return (box.status, object)
    }
}

private final class Box: @unchecked Sendable {
    var status = 0
    var data = Data()
}
