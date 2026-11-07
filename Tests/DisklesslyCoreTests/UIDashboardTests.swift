import XCTest
import Foundation
import DisklesslyCore
import DisklesslyEngine
import DisklesslySessions

/// JSON the dashboard page needs: backend health with latency and timeout, endpoint
/// states, cache levels and the free-floor marker, session tiers, and pinned evict.
final class UIDashboardTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let config: RuntimeConfig
        let engine: DisklesslyEngine
        let manifest: ImageManifest

        init(backends: [BackendEndpoint] = [], activeId: String? = nil, installPath: String = "/Users/me/Applications/Test.app") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-dash-\(UUID().uuidString)")
            let repo = root.appendingPathComponent("repo")
            var config = RuntimeConfig(repoPath: repo.path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
            config.backends = backends
            config.activeBackendId = activeId
            self.config = config
            var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
            engine.backendOverride = try LocalFolderBackend(root: repo)
            engine.recommendEnvironment = .unavailable
            try engine.initialize()
            let bytes = Data("remote image".utf8)
            let image = ImageManifest.Image(file: "images/test.dmg", format: "ULMO", sha256: SHA256Digest.hex(bytes), size: UInt64(bytes.count), volumeName: "Test", appPathInVolume: "Test.app")
            manifest = ImageManifest(bundleId: "com.test.app", name: "Test", version: "1", image: image, app: .init(originalPath: installPath, executable: "Test", documentTypes: [], urlTypes: []))
            try LocalFolderBackend(root: repo).put("manifests/\(manifest.imageId).json", data: try manifest.encode())
            self.engine = engine
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func get(_ path: String, query: [String: String] = [:], context: ManagementUIContext) throws -> [String: Any] {
            let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: path, query: query), context: context)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        }

        func post(_ path: String, body: [String: Any], context: ManagementUIContext) throws -> (status: Int, object: [String: Any]) {
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "POST", path: path, body: data), context: context)
            return (response.status, try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
        }
    }

    func testLicenseEndpointsReportFreeAndRefuseBadCodes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in })
        let free = try fixture.get("/api/license", context: context)
        XCTAssertEqual(free["state"] as? String, "free")
        XCTAssertEqual(free["freeLimit"] as? Int, License.freeAppLimit)
        let bad = try fixture.post("/api/license/activate", body: ["code": "not a code"], context: context)
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(try fixture.get("/api/license", context: context)["state"] as? String, "free", "a refused code changes nothing")
        let none = try fixture.post("/api/license/activate", body: [:], context: context)
        XCTAssertEqual(none.status, 400)
        let removed = try fixture.post("/api/license/deactivate", body: [:], context: context)
        XCTAssertEqual(removed.object["state"] as? String, "free")
    }

    func testStatusCarriesHealthEndpointsCacheAndInstallPath() throws {
        let fixture = try Fixture(backends: [
            BackendEndpoint(id: "office", type: "webdav", url: "https://dav.example.lan/apps"),
            BackendEndpoint(id: "nas", type: "smb", host: "nas.local", share: "apps", mountPoint: "/Volumes/apps"),
            BackendEndpoint(id: "usb", type: "local", root: "/Volumes/Archive"),
        ], activeId: "nas")
        defer { fixture.cleanup() }
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in })
        let status = try fixture.get("/api/status", context: context)

        let backend = try XCTUnwrap(status["backend"] as? [String: Any])
        XCTAssertEqual(backend["health"] as? String, "ok")
        XCTAssertEqual(backend["kind"] as? String, "smb")
        XCTAssertEqual(backend["location"] as? String, "remote")
        XCTAssertEqual(backend["activeId"] as? String, "nas")
        XCTAssertEqual(backend["activePlace"] as? String, "nas.local/apps")
        XCTAssertNotNil(backend["latencyMs"] as? NSNumber)
        XCTAssertEqual((backend["timeoutMs"] as? NSNumber)?.intValue, 5000)
        XCTAssertEqual(backend["timedOut"] as? Bool, false)
        let endpoints = try XCTUnwrap(backend["endpoints"] as? [[String: Any]])
        XCTAssertEqual(endpoints.map { $0["id"] as? String }, ["office", "nas", "usb"])
        XCTAssertEqual(endpoints.map { $0["state"] as? String }, ["standby", "active", "local"])
        XCTAssertEqual(endpoints.first?["place"] as? String, "https://dav.example.lan/apps")

        let cache = try XCTUnwrap(status["cache"] as? [String: Any])
        XCTAssertEqual(cache["level"] as? String, "ok")
        XCTAssertNotNil(cache["diskFreeBytes"] as? NSNumber)
        XCTAssertEqual((cache["quotaLeftBytes"] as? NSNumber)?.uint64Value, fixture.config.quotaBytes)
        XCTAssertEqual((cache["detachDelaySeconds"] as? NSNumber)?.uint64Value, fixture.config.detachDelaySeconds)

        let app = try XCTUnwrap((status["apps"] as? [[String: Any]])?.first)
        XCTAssertEqual(app["installPath"] as? String, "/Users/me/Applications/Test.app")
        XCTAssertNotNil(status["generatedAt"] as? String)
    }

    func testPlainFolderRepoListsOneActiveLocalEndpoint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in })
        let backend = try XCTUnwrap(try fixture.get("/api/status", context: context)["backend"] as? [String: Any])
        XCTAssertEqual(backend["location"] as? String, "local")
        let endpoints = try XCTUnwrap(backend["endpoints"] as? [[String: Any]])
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?["state"] as? String, "active")
        XCTAssertEqual(endpoints.first?["place"] as? String, fixture.config.repoPath)
    }

    func testHealthProbeTimesOutWithoutBlockingAndRecovers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let release = DispatchSemaphore(value: 0)
        let probe = BackendHealthProbe(timeout: 0.3, maxAge: 60, slowMs: 200) { _ in
            _ = release.wait(timeout: .now() + 5)
            return nil
        }
        let started = Date()
        let first = probe.current(fixture.engine)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(first.status, "offline")
        XCTAssertTrue(first.timedOut)
        XCTAssertNil(first.latencyMs)
        // A refresh within maxAge reuses the timeout instead of waiting again.
        let again = Date()
        XCTAssertTrue(probe.current(fixture.engine).timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.2)
        // The late answer replaces the timeout once it lands.
        release.signal()
        var recovered = probe.current(fixture.engine)
        for _ in 0..<100 where recovered.timedOut {
            Thread.sleep(forTimeInterval: 0.02)
            recovered = probe.current(fixture.engine)
        }
        XCTAssertFalse(recovered.timedOut)
        XCTAssertEqual(recovered.status, "degraded", "a probe slower than slowMs reads as degraded")
        XCTAssertGreaterThanOrEqual(recovered.latencyMs ?? 0, 300)
    }

    func testHungProbeAnswersAtOnceAfterMaxAgeAndRetryStartsANewProbe() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let calls = Answers(["hang", "ok"])
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = BackendHealthProbe(timeout: 0.3, maxAge: 0.05) { _ in
            if calls.next() == "hang" { _ = release.wait(timeout: .now() + 30) }
            return nil
        }
        XCTAssertTrue(probe.current(fixture.engine).timedOut, "the first caller waits one timeout")
        // Past maxAge with the probe still hung: every refresh answers at once.
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.1)
            let started = Date()
            let result = probe.current(fixture.engine)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.15)
            XCTAssertTrue(result.timedOut)
            XCTAssertEqual(result.status, "offline")
        }
        // Retry (fresh) does not join the hung probe; a recovered backend reads ok.
        let retried = probe.current(fixture.engine, fresh: true)
        XCTAssertFalse(retried.timedOut)
        XCTAssertEqual(retried.status, "ok")
    }

    func testHealthStatesAndFreshProbe() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let answers = Answers(["ok", "missing", "throw"])
        let probe = BackendHealthProbe(timeout: 2, maxAge: 60) { _ in
            switch answers.next() {
            case "missing": return "repo.json is not in the backend"
            case "throw": throw DisklesslyError.backend("share is not mounted")
            default: return nil
            }
        }
        XCTAssertEqual(probe.current(fixture.engine).status, "ok")
        XCTAssertEqual(probe.current(fixture.engine).status, "ok", "cached within maxAge")
        XCTAssertEqual(probe.current(fixture.engine, fresh: true).status, "missing")
        let offline = probe.current(fixture.engine, fresh: true)
        XCTAssertEqual(offline.status, "offline")
        XCTAssertFalse(offline.timedOut)
        XCTAssertTrue(offline.detail.contains("share is not mounted"))

        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in }, health: probe)
        let health = try fixture.get("/api/health", context: context)
        XCTAssertEqual(health["ok"] as? Bool, true)
        XCTAssertEqual(health["health"] as? String, "offline")
    }

    func testFloorMarkerIsWhereCacheGrowthHitsTheDiskFloor() {
        let GiB: UInt64 = 1 << 30
        // 12 GiB cached, 50 GiB free, keep 8 GiB: the floor binds at 54 GiB of a 64 GiB quota.
        XCTAssertEqual(ManagementUI.floorMarker(used: 12 * GiB, diskFree: 50 * GiB, floor: 8 * GiB, quota: 64 * GiB), 54 * GiB)
        // Plenty of disk: the floor never binds before the quota, so no marker.
        XCTAssertNil(ManagementUI.floorMarker(used: 12 * GiB, diskFree: 500 * GiB, floor: 8 * GiB, quota: 64 * GiB))
        // Disk already below the floor: clamped to zero.
        XCTAssertEqual(ManagementUI.floorMarker(used: 2 * GiB, diskFree: 1 * GiB, floor: 8 * GiB, quota: 64 * GiB), 0)
        XCTAssertNil(ManagementUI.floorMarker(used: 0, diskFree: 1, floor: 0, quota: 64 * GiB))
        XCTAssertNil(ManagementUI.floorMarker(used: 0, diskFree: 1, floor: 8, quota: 0))
    }

    func testCacheLevelThresholds() {
        XCTAssertEqual(ManagementUI.cacheLevel(used: 79, quota: 100), "ok")
        XCTAssertEqual(ManagementUI.cacheLevel(used: 80, quota: 100), "near")
        XCTAssertEqual(ManagementUI.cacheLevel(used: 94, quota: 100), "near")
        XCTAssertEqual(ManagementUI.cacheLevel(used: 95, quota: 100), "critical")
        XCTAssertEqual(ManagementUI.cacheLevel(used: 5, quota: 0), "ok")
    }

    func testOffloadedSessionsAreAlwaysCold() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ManagementUI.sessionAgeDays(modified: now.addingTimeInterval(-21 * 86_400), now: now), 21)
        XCTAssertEqual(ManagementUI.sessionAgeDays(modified: now.addingTimeInterval(3600), now: now), 0)

        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // Only cold files are archived; even an entry archived with a short --cold-days stays cold.
        let entries = [
            SessionIndexEntry(id: "w", tool: "pi", path: "/tmp/recent.jsonl", sha256: "a", size: 1, modified: Date().addingTimeInterval(-2 * 86_400), archive: "a.tar", member: "w", preview: ""),
            SessionIndexEntry(id: "c", tool: "pi", path: "/tmp/cold.jsonl", sha256: "b", size: 1, modified: Date().addingTimeInterval(-30 * 86_400), archive: "a.tar", member: "c", preview: ""),
        ]
        try SessionArchive.saveIndex(SessionIndex(entries: entries), stateDir: fixture.config.stateDir)
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in })
        let sessions = try XCTUnwrap(try fixture.get("/api/status", context: context)["sessions"] as? [String: Any])
        let rows = try XCTUnwrap(sessions["offloaded"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["tier"] as? String }), ["cold"])
        XCTAssertEqual((rows.first { $0["id"] as? String == "c" }?["ageDays"] as? NSNumber)?.intValue, 30)
    }

    /// `disklessly sessions --apply` writes the SQLite index; the dashboard must list
    /// those entries (restored ones excluded) without migrating or creating files.
    func testSessionsComeFromTheSQLiteIndex() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in })
        let sqlite = URL(fileURLWithPath: fixture.config.stateDir).appendingPathComponent("sessions/index.sqlite")
        let empty = try XCTUnwrap(try fixture.get("/api/status", context: context)["sessions"] as? [String: Any])
        XCTAssertEqual((empty["offloaded"] as? [Any])?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sqlite.path), "status must not create the session index")

        let mtime = Int64(Date().addingTimeInterval(-21 * 86_400).timeIntervalSince1970 * 1_000_000_000)
        func row(_ id: String, _ state: String) -> SessionEntryRow {
            SessionEntryRow(id: id, segmentId: nil, legacyArchive: "sessions/\(id).tar.gz", member: "m/\(id).jsonl", deviceId: "d", tool: "pi", path: "/tmp/\(id).jsonl", sha256: id, size: 1, mtimeNs: mtime, ino: nil, preview: "", archivedAt: "2026-01-01T00:00:00Z", state: state)
        }
        try SessionIndexDB(stateDir: fixture.config.stateDir).insert(entries: [row("kept", "deleted"), row("back", "restored")])
        let sessions = try XCTUnwrap(try fixture.get("/api/status", context: context)["sessions"] as? [String: Any])
        let rows = try XCTUnwrap(sessions["offloaded"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["kept"])
        XCTAssertEqual((rows.first?["ageDays"] as? NSNumber)?.intValue, 21)
    }

    /// An unreachable backend (e.g. a WebDAV host that never answers) must not leave
    /// /api/status blocked on the app listing: an offline probe skips it.
    func testOfflineProbeSkipsTheAppListing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        struct Down: Error {}
        let probe = BackendHealthProbe(timeout: 0.3, maxAge: 60) { _ in throw Down() }
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in }, health: probe)
        let status = try fixture.get("/api/status", context: context)
        XCTAssertEqual(status["appsErrorCode"] as? String, "offline")
        XCTAssertFalse((status["appsError"] as? String ?? "").isEmpty)
        XCTAssertEqual((status["apps"] as? [Any])?.count, 0, "the manifest in the repo is not listed while offline")
        XCTAssertEqual((status["backend"] as? [String: Any])?["health"] as? String, "offline")
    }

    func testSessionPathsAreShownRelativeToHome() {
        XCTAssertEqual(ManagementUI.homeRelative("/Users/me/Projects/a.jsonl", home: "/Users/me"), "~/Projects/a.jsonl")
        XCTAssertEqual(ManagementUI.homeRelative("/private/tmp/h/.pi/s.jsonl", home: "/tmp/h"), "~/.pi/s.jsonl")
        XCTAssertEqual(ManagementUI.homeRelative("/Users/meow/a", home: "/Users/me"), "/Users/meow/a")
    }

    func testScanRootsOverrideReplacesApplicationFolders() {
        XCTAssertNil(ScanRoots.override([:]))
        XCTAssertEqual(ScanRoots.override(["DISKLESSLY_SCAN_ROOTS": "/tmp/a:/tmp/b"])?.map(\.path), ["/tmp/a", "/tmp/b"])
    }

    func testAppsErrorCarriesTheServerErrorCode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions { _, _, _ in })
        let healthy = try fixture.get("/api/status", context: context)
        XCTAssertEqual(healthy["appsError"] as? String, "")
        XCTAssertEqual(healthy["appsErrorCode"] as? String, "")

        // An undecodable manifest is skipped, not an app-list failure.
        try LocalFolderBackend(root: URL(fileURLWithPath: fixture.config.repoPath)).put("manifests/broken.json", data: Data("not json".utf8))
        let skipped = try fixture.get("/api/status", context: context)
        XCTAssertEqual(skipped["appsErrorCode"] as? String, "")
        XCTAssertEqual((skipped["apps"] as? [[String: Any]])?.count, 1)

        // A listing that fails at the backend is coded `offline`, the same as API failures.
        var engine = fixture.engine
        engine.backendOverride = try FaultyBackend(root: URL(fileURLWithPath: fixture.config.repoPath), failList: ["manifests"])
        let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/status"), context: context)
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertFalse((status["appsError"] as? String ?? "").isEmpty)
        XCTAssertEqual(status["appsErrorCode"] as? String, "offline")
    }

    func testPinnedEvictIsRefusedUnlessForced() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try StateStore(fixture.config.stateDir).update { state in
            var item = state.apps[fixture.manifest.bundleId] ?? AppState()
            item.pinned = true
            state.apps[fixture.manifest.bundleId] = item
        }
        let context = ManagementUIContext(platform: .macOS)
        let refused = try fixture.post("/api/evict", body: ["app": "Test", "force": false], context: context)
        XCTAssertEqual(refused.status, 202)
        let job = try XCTUnwrap(context.jobs.wait(try XCTUnwrap(refused.object["jobId"] as? String), timeout: 10))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.errorCode, "pinned")
        // Without a force field the default is false too.
        let implicit = try fixture.post("/api/evict", body: ["app": "Test"], context: context)
        XCTAssertEqual(context.jobs.wait(try XCTUnwrap(implicit.object["jobId"] as? String), timeout: 10)?.errorCode, "pinned")
        let forced = try fixture.post("/api/evict", body: ["app": "Test", "force": true], context: context)
        XCTAssertEqual(context.jobs.wait(try XCTUnwrap(forced.object["jobId"] as? String), timeout: 10)?.state, .done)
    }

    func testForceFlagReachesActions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let seen = Answers([])
        let context = ManagementUIContext(platform: .macOS, actions: ManagementActions(perform: { kind, app, options, _ in
            seen.record("\(kind.rawValue):\(app):\(options.force)")
        }))
        let plain = try fixture.post("/api/evict", body: ["app": "Test"], context: context)
        _ = context.jobs.wait(try XCTUnwrap(plain.object["jobId"] as? String), timeout: 5)
        let forced = try fixture.post("/api/evict", body: ["app": "Test", "force": true], context: context)
        _ = context.jobs.wait(try XCTUnwrap(forced.object["jobId"] as? String), timeout: 5)
        XCTAssertEqual(seen.recorded, ["evict:Test:false", "evict:Test:true"])
        XCTAssertEqual(ManagementUI.errorInfo(UIJobError.pinned("Test")).code, "pinned")
    }
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]
    private var log: [String] = []
    init(_ queue: [String]) { self.queue = queue }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? "ok" : queue.removeFirst()
    }
    func record(_ value: String) { lock.lock(); log.append(value); lock.unlock() }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return log }
}
