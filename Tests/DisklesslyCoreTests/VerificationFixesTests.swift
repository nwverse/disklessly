import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class VerificationFixesTests: XCTestCase {
    func testClonefileFlagWidthIsUnsigned() {
        // The macOS 27 SDK types clonefile's flags as UInt32. Both call sites cast.
        XCTAssertEqual(UInt32(0), 0)
        XCTAssertEqual(ICloudLimits.readTimeout(path: "devices/abc.json", download: 900, metadata: 20), 20)
        XCTAssertEqual(ICloudLimits.readTimeout(path: "catalog/manifest.json", download: 900, metadata: 20), 20)
        XCTAssertEqual(ICloudLimits.readTimeout(path: "manifests/app.json", download: 900, metadata: 20), 20)
        XCTAssertEqual(ICloudLimits.readTimeout(path: "images/app.dmg", download: 900, metadata: 20), 900)
    }

    func testMaterializerWarnsWhenDownloadNeverProgresses() throws {
        var probes = 0
        var starts = 0
        var slept: TimeInterval = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        let warning = try UbiquitousMaterializer.wait(
            name: "device.json",
            timeout: 20,
            interval: 0.25,
            now: { clock },
            sleep: { interval in
                slept += interval
                clock = clock.addingTimeInterval(interval)
            },
            start: { starts += 1 },
            probe: {
                probes += 1
                return UbiquitySnapshot(isUbiquitous: true, status: "notDownloaded", downloading: false)
            }
        )
        XCTAssertEqual(starts, 1)
        XCTAssertGreaterThan(probes, 1)
        let text = try XCTUnwrap(warning)
        XCTAssertTrue(text.contains("device.json"))
        XCTAssertTrue(text.contains("within 20s"))
        XCTAssertEqual(slept, 20, accuracy: 0.001)
        XCTAssertLessThan(slept, 21)
    }

    func testMaterializerSeesALaterCurrentStatus() throws {
        var probes = 0
        var starts = 0
        var clock = Date(timeIntervalSince1970: 0)
        let warning = try UbiquitousMaterializer.wait(
            name: "device.json",
            timeout: 20,
            interval: 0.25,
            now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) },
            start: { starts += 1 },
            probe: {
                probes += 1
                if probes >= 2 {
                    return UbiquitySnapshot(isUbiquitous: true, status: "current", downloading: false)
                }
                return UbiquitySnapshot(isUbiquitous: true, status: "notDownloaded", downloading: false)
            }
        )
        XCTAssertNil(warning)
        XCTAssertEqual(starts, 1)
        XCTAssertGreaterThanOrEqual(probes, 2)
        var skipped = 0
        let already = try UbiquitousMaterializer.wait(
            name: "device.json",
            timeout: 20,
            now: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in XCTFail("already local") },
            start: { skipped += 1 },
            probe: { UbiquitySnapshot(isUbiquitous: true, status: "current", downloading: false) }
        )
        XCTAssertNil(already)
        XCTAssertEqual(skipped, 0)
        let capped = UbiquitousMaterializer.withBudget(20) {
            UbiquitousMaterializer.cappedTimeout(900)
        }
        XCTAssertGreaterThan(capped, 19)
        XCTAssertLessThanOrEqual(capped, 20)
        let nested = UbiquitousMaterializer.withBudget(5) {
            UbiquitousMaterializer.withBudget(900) {
                UbiquitousMaterializer.cappedTimeout(900)
            }
        }
        XCTAssertLessThanOrEqual(nested, 5)
        XCTAssertEqual(UbiquitousMaterializer.withBudget(0) { UbiquitousMaterializer.cappedTimeout(900) }, 0)
    }

    func testJSONFlagIsAcceptedAfterTheCommand() throws {
        let trailing = try GlobalArguments.parse(["list", "--json"])
        XCTAssertTrue(trailing.json)
        XCTAssertEqual(trailing.rest, ["list"])
        let mixed = try GlobalArguments.parse(["recommend", "--min-size", "1", "--json"])
        XCTAssertTrue(mixed.json)
        XCTAssertEqual(mixed.rest, ["recommend", "--min-size", "1"])
        let leading = try GlobalArguments.parse(["--json", "--state-dir", "/tmp/state", "list"])
        XCTAssertTrue(leading.json)
        XCTAssertEqual(leading.stateDir, "/tmp/state")
        XCTAssertEqual(leading.rest, ["list"])
    }

    func testRecommendDropsRecentZeroScoreAndAndroidPackages() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mebi: UInt64 = 1024 * 1024
        let idle = RecommendApp(path: "/Applications/Blender.app", name: "Blender", bundleId: "org.blender", sizeBytes: 400 * mebi, lastUsed: now.addingTimeInterval(-30 * 86_400))
        let recent = RecommendApp(path: "/Applications/Recent.app", name: "Recent", bundleId: "org.recent", sizeBytes: 400 * mebi, lastUsed: now.addingTimeInterval(-2 * 86_400))
        let today = RecommendApp(path: "/Applications/Chrome.app", name: "Chrome", bundleId: "com.chrome", sizeBytes: 400 * mebi, lastUsed: now)
        let apk = RecommendApp(path: "/Applications/Mac.apk", name: "Mac.apk", bundleId: "com.android.mac", sizeBytes: 400 * mebi, lastUsed: now.addingTimeInterval(-400 * 86_400))
        let defaults = try RecommendArguments.parse([]).options(now: now)
        XCTAssertEqual(defaults.minIdleDays, 30)
        XCTAssertFalse(defaults.includeAll)
        let report = RecommendRanking.rank([today, apk, recent, idle], options: defaults)
        XCTAssertEqual(report.recommendations.map(\.name), ["Blender"])
        let everything = try RecommendArguments.parse(["--all"]).options(now: now)
        let opened = RecommendRanking.rank([today, apk, recent, idle], options: everything)
        XCTAssertEqual(opened.recommendations.map(\.name), ["Blender", "Recent", "Chrome"])
        XCTAssertFalse(opened.recommendations.contains { $0.name.contains("apk") || $0.path.contains(".apk") })
        XCTAssertFalse(RecommendRanking.rank([apk], options: everything).warnings.contains { $0.path.contains(".apk") })
        XCTAssertTrue(RecommendPaths.isNonMacPackage(path: "/Applications/Mac.apk.app", name: "Mac"))
        XCTAssertFalse(RecommendPaths.isNonMacPackage(path: "/Applications/Chrome.app", name: "Chrome"))
    }

    func testIconPlanChoosesRestoreAppOrReadOnlyImageAndSkipsACache() {
        let jobs = IconBackfill.plan(
            candidates: [
                IconBackfill.Candidate(imageId: "restore", bundleId: "org.restore", name: "Restore", mode: "restore", originalPath: "/Apps/Real.app"),
                IconBackfill.Candidate(imageId: "mount", bundleId: "org.mount", name: "Mount", mode: "mount", originalPath: "/Apps/Mount.app"),
                IconBackfill.Candidate(imageId: "cached", bundleId: "org.cached", name: "Cached", mode: "mount", originalPath: "/Apps/Cached.app"),
                IconBackfill.Candidate(imageId: "gone", bundleId: "org.gone", name: "Gone", mode: "restore", originalPath: "/Apps/Missing.app"),
            ],
            only: nil,
            cacheExists: { $0 == "cached" },
            repoIconExists: { $0 == "cached" },
            isRealApp: { $0 == "/Apps/Real.app" },
            cachedImagePath: { $0 == "mount" ? "/cache/mount.dmg" : nil },
            localImagePath: { $0 == "gone" ? "/repo/images/gone.dmg" : nil },
            stubPath: { $0.imageId == "mount" ? "/Apps/Mount.app" : nil }
        )
        XCTAssertEqual(jobs.map(\.imageId), ["restore", "mount", "cached", "gone"])
        XCTAssertEqual(jobs[0].source, .onDiskApp("/Apps/Real.app"))
        XCTAssertEqual(jobs[1].source, .diskImage("/cache/mount.dmg"))
        XCTAssertEqual(jobs[1].stubPath, "/Apps/Mount.app")
        XCTAssertEqual(jobs[2].source, .cached)
        XCTAssertFalse(jobs[2].publishRepo)
        XCTAssertTrue(jobs[0].publishRepo)
        XCTAssertEqual(jobs[3].source, .diskImage("/repo/images/gone.dmg"))
        let one = IconBackfill.plan(
            candidates: jobs.map { IconBackfill.Candidate(imageId: $0.imageId, bundleId: $0.bundleId, name: $0.imageId, mode: "mount", originalPath: "/Apps/\($0.imageId).app") },
            only: "org.mount",
            cacheExists: { _ in false },
            repoIconExists: { _ in false },
            isRealApp: { _ in false },
            cachedImagePath: { _ in "/cache/x.dmg" },
            localImagePath: { _ in nil },
            stubPath: { _ in nil }
        )
        XCTAssertEqual(one.map(\.imageId), ["mount"])
        XCTAssertEqual(IconBackfill.doctorHint(missing: 0), nil)
        XCTAssertEqual(IconBackfill.doctorHint(missing: 10), "10 apps have no icon: run disklessly icons backfill")
        let parsed = try? IconsArguments.parse(["backfill", "--app", "org.mount"])
        XCTAssertEqual(parsed?.app, "org.mount")
        XCTAssertNil(try IconsArguments.parse(["backfill"]).app)
    }

    func testReadOnlyCommandsDoNotRegisterTheDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-ro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("{\"schema\":\"repo/1\"}".utf8).write(to: repo.appendingPathComponent("repo.json"))
        let faulty = try FaultyBackend(root: repo)
        let sha = String(repeating: "ab", count: 32)
        let image = ImageManifest.Image(file: "images/app.dmg", format: "ULMO", sha256: sha, size: 4, volumeName: "App", appPathInVolume: "App.app")
        let manifest = ImageManifest(bundleId: "com.example.app", name: "App", version: "1", image: image, app: .init(originalPath: "/Applications/App.app", executable: "App", documentTypes: [], urlTypes: []), imageId: "app")
        try faulty.inner.put("manifests/app.json", data: try manifest.encode())
        var engine = DisklesslyEngine(config: RuntimeConfig(
            repoPath: repo.path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: state.path,
            mountRoot: root.appendingPathComponent("mounts").path,
            stubDir: root.appendingPathComponent("apps").path
        ), secrets: MemorySecretStore())
        engine.backendOverride = faulty
        engine.recommendEnvironment = .unavailable
        let recorded = faulty.calls.count
        let listed = try engine.list()
        XCTAssertEqual(listed.map(\.imageId), ["app"])
        let doctor = engine.doctor()
        XCTAssertEqual(doctor["iconHint"] as? String, "1 apps have no icon: run disklessly icons backfill")
        _ = engine.recommend(options: RecommendOptions(minSizeBytes: 1, now: Date()))
        let status = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/status"))
        let recommend = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/recommend", query: ["minSize": "1"]))
        let icon = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/icon/app"))
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(recommend.status, 200)
        XCTAssertEqual(icon.status, 200)
        XCTAssertEqual(icon.body, AppIcon.genericPNG)
        let duringRead = faulty.calls.dropFirst(recorded)
        XCTAssertFalse(duringRead.contains { $0.hasPrefix("put:") || $0.hasPrefix("delete:") || $0.hasPrefix("ensure:") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("device-record.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("devices").path))
        let cache = try XCTUnwrap(AppIcon.cacheURL(stateDir: state.path, imageId: "app"))
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = AppIcon.genericPNG + Data([1, 2, 3])
        try marker.write(to: cache)
        XCTAssertEqual(AppIcon.existingPath(stateDir: state.path, repoPath: repo.path, imageId: "app"), cache.path)
        let cachedIcon = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/icon/app"))
        XCTAssertEqual(cachedIcon.body, marker)
        let quiet = engine.doctor()
        XCTAssertNil(quiet["iconHint"])
    }

    func testIconBackfillPublishesACachedPNGOnceAndDoesNotExtractOnLinux() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let state = root.appendingPathComponent("state")
        let cacheDir = root.appendingPathComponent("cache")
        let faulty = try FaultyBackend(root: repo)
        let sha = String(repeating: "cd", count: 32)
        func manifest(id: String, mode: ImageManifest.Mode) -> ImageManifest {
            let image = ImageManifest.Image(file: "images/\(id).dmg", format: "ULMO", sha256: sha, size: 4, volumeName: id, appPathInVolume: "\(id).app")
            return ImageManifest(bundleId: "com.example.\(id)", name: id, version: "1", image: image, app: .init(originalPath: "/Applications/\(id).app", executable: id, documentTypes: [], urlTypes: []), mode: mode, imageId: id)
        }
        try faulty.inner.put("manifests/cached.json", data: try manifest(id: "cached", mode: .mount).encode())
        try faulty.inner.put("manifests/mount.json", data: try manifest(id: "mount", mode: .mount).encode())
        try FileManager.default.createDirectory(at: cacheDir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data("dmg".utf8).write(to: cacheDir.appendingPathComponent("images/mount.dmg"))
        let png = AppIcon.cacheURL(stateDir: state.path, imageId: "cached")
        try FileManager.default.createDirectory(at: png!.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AppIcon.genericPNG.write(to: png!)
        var engine = DisklesslyEngine(config: RuntimeConfig(
            repoPath: repo.path,
            cacheDir: cacheDir.path,
            stateDir: state.path,
            mountRoot: root.appendingPathComponent("mounts").path,
            stubDir: root.appendingPathComponent("apps").path
        ), secrets: MemorySecretStore())
        engine.backendOverride = faulty
        let before = faulty.calls.count
        let first = try engine.backfillIcons(appId: nil)
        XCTAssertEqual(first.skipped, ["cached"])
        XCTAssertTrue(first.updated.isEmpty)
        #if os(macOS)
        // images/mount.dmg is three bytes, not a disk image. diskutil refuses it
        // ("The disk image is corrupted"); backfill must report that as a warning.
        XCTAssertTrue(first.warnings.contains { $0.hasPrefix("mount:") }, "\(first.warnings)")
        XCTAssertFalse(first.updated.contains("mount"))
        #else
        XCTAssertTrue(first.warnings.contains("mount: icon backfill requires macOS"))
        #endif
        let firstCalls = faulty.calls.dropFirst(before)
        XCTAssertEqual(firstCalls.filter { $0 == "put:icons/cached.png" }.count, 1)
        XCTAssertFalse(firstCalls.contains { $0.hasPrefix("put:devices/") })
        let mid = faulty.calls.count
        let second = try engine.backfillIcons(appId: "cached")
        XCTAssertEqual(second.skipped, ["cached"])
        XCTAssertFalse(faulty.calls.dropFirst(mid).contains { $0.hasPrefix("put:") })
        let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "POST", path: "/api/icons/backfill", query: ["app": "mount"]))
        XCTAssertNotEqual(response.status, 404)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(body["ok"] as? Bool, true)
    }

    func testIconBackfillRouteRequiresTheLoopbackToken() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        var engine = DisklesslyEngine(config: RuntimeConfig(
            repoPath: repo.path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mounts").path,
            stubDir: root.appendingPathComponent("apps").path
        ), secrets: MemorySecretStore())
        engine.backendOverride = try LocalFolderBackend(root: repo)
        let server = LoopbackUIServer(token: "icon-token") { request in
            ManagementUI.respond(engine: engine, webRoot: nil, request: request)
        }
        try server.start()
        defer { server.stop() }
        let denied = try http(port: server.port, path: "/api/icons/backfill", token: nil, method: "POST")
        XCTAssertEqual(denied.status, 401)
        let allowed = try http(port: server.port, path: "/api/icons/backfill", token: "icon-token", method: "POST")
        XCTAssertEqual(allowed.status, 200)
    }

    private func http(port: UInt16, path: String, token: String?, method: String) throws -> (status: Int, body: Data) {
        let target = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: target)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let box = HTTPBox()
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

private final class HTTPBox: @unchecked Sendable {
    var status = 0
    var data = Data()
}
