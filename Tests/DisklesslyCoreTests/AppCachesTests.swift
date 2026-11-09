import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

/// `disklessly caches`: which folders count as an offloaded app's caches, and the
/// rule that a running app's caches stay.
final class AppCachesTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    var library: URL { home.appendingPathComponent("Library") }
    let fm = FileManager.default

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("disklessly-caches-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func write(_ relative: String, bytes: Int = 5000) throws -> URL {
        let url = library.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func makeEngine(_ apps: [(id: String, name: String)]) throws -> DisklesslyEngine {
        let repo = root.appendingPathComponent("repo")
        let config = RuntimeConfig(repoPath: repo.path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        let backend = try LocalFolderBackend(root: repo)
        engine.backendOverride = backend
        try engine.initialize()
        for app in apps {
            let image = ImageManifest.Image(file: "images/\(app.name).dmg", format: "ULMO", sha256: String(repeating: "ab", count: 32), size: 3, volumeName: app.name, appPathInVolume: "\(app.name).app")
            let manifest = ImageManifest(bundleId: app.id, name: app.name, version: "1", image: image, app: .init(originalPath: "/Applications/\(app.name).app", executable: app.name, documentTypes: [], urlTypes: []))
            try backend.put("manifests/\(manifest.imageId).json", data: try manifest.encode())
        }
        engine.appRunningOverride = { _ in false }
        let ids = Set(apps.map(\.id))
        engine.offloadedOverride = { ids }
        return engine
    }

    // MARK: finder

    func testCandidatesAreBundleIdNameAndContainerCaches() {
        let paths = AppCaches.candidates(bundleId: "com.example.Foo", name: "Foo", home: "/Users/me")
        XCTAssertEqual(paths, [
            "/Users/me/Library/Caches/com.example.Foo",
            "/Users/me/Library/Caches/Foo",
            "/Users/me/Library/Containers/com.example.Foo/Data/Library/Caches",
        ])
        XCTAssertFalse(paths.contains { $0.contains("Application Support") })
    }

    func testCandidatesRejectNamesThatLeaveTheCachesFolder() {
        for bad in ["", ".", "..", "a/b", "../Application Support", " Foo"] {
            let paths = AppCaches.candidates(bundleId: bad, name: bad, home: "/Users/me")
            XCTAssertEqual(paths, [], "\(bad.debugDescription) must not name a cache folder")
        }
        XCTAssertEqual(AppCaches.candidates(bundleId: "com.x", name: "com.x", home: "/h"), ["/h/Library/Caches/com.x", "/h/Library/Containers/com.x/Data/Library/Caches"], "the same folder is listed once")
    }

    func testFinderReturnsExistingNonEmptyFoldersOnly() throws {
        try write("Caches/com.example.Foo/blob")
        try write("Caches/Foo/http/data")
        try fm.createDirectory(at: library.appendingPathComponent("Containers/com.example.Foo/Data/Library/Caches"), withIntermediateDirectories: true)
        try write("Application Support/com.example.Foo/db.sqlite")
        let found = AppCaches.folders(bundleId: "com.example.Foo", name: "Foo", home: home.path)
        XCTAssertEqual(found.map(\.path), [library.appendingPathComponent("Caches/com.example.Foo").path, library.appendingPathComponent("Caches/Foo").path], "the empty container cache is not listed")
        XCTAssertTrue(found.allSatisfy { $0.bytes >= 5000 })
        XCTAssertEqual(AppCaches.folders(bundleId: "com.example.None", name: "None", home: home.path), [])
    }

    func testFinderIgnoresSymlinkedCacheFolders() throws {
        let elsewhere = try write("Application Support/com.example.Foo/precious")
        try fm.createDirectory(at: library.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: library.appendingPathComponent("Caches/com.example.Foo"), withDestinationURL: elsewhere.deletingLastPathComponent())
        // A container whose Data is a link (as some apps do for group containers) is not followed either.
        try fm.createDirectory(at: library.appendingPathComponent("Containers/com.example.Foo"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: library.appendingPathComponent("Containers/com.example.Foo/Data"), withDestinationURL: library.appendingPathComponent("Application Support"))
        XCTAssertEqual(AppCaches.folders(bundleId: "com.example.Foo", name: "Foo", home: home.path), [])
    }

    // MARK: clearing

    func testDryRunChangesNothingAndApplyEmptiesOnlyCaches() throws {
        let engine = try makeEngine([("com.example.Foo", "Foo")])
        let blob = try write("Caches/com.example.Foo/blob")
        let containerCache = try write("Containers/com.example.Foo/Data/Library/Caches/thumbs/1.png")
        let support = try write("Application Support/com.example.Foo/db.sqlite")
        let documents = try write("Containers/com.example.Foo/Data/Documents/note.txt")

        let dry = try engine.clearAppCaches(apply: false, home: home.path)
        XCTAssertFalse(dry.applied)
        XCTAssertEqual(dry.entries.first?.folders.count, 2)
        XCTAssertGreaterThanOrEqual(dry.freedBytes, 10_000)
        XCTAssertTrue(fm.fileExists(atPath: blob.path), "a dry run deletes nothing")

        let applied = try engine.clearAppCaches(apply: true, home: home.path)
        XCTAssertTrue(applied.applied)
        XCTAssertEqual(applied.failed, [])
        XCTAssertEqual(applied.freedBytes, dry.freedBytes)
        XCTAssertFalse(fm.fileExists(atPath: blob.path))
        XCTAssertFalse(fm.fileExists(atPath: containerCache.path))
        XCTAssertTrue(fm.fileExists(atPath: library.appendingPathComponent("Caches/com.example.Foo").path), "the folder itself stays")
        XCTAssertTrue(fm.fileExists(atPath: library.appendingPathComponent("Containers/com.example.Foo/Data/Library/Caches").path))
        XCTAssertTrue(fm.fileExists(atPath: support.path), "Application Support is never touched")
        XCTAssertTrue(fm.fileExists(atPath: documents.path), "container data outside Caches is never touched")
    }

    func testAppsOnlyAnotherMacOffloadedAreLeftAlone() throws {
        var engine = try makeEngine([("com.example.Foo", "Foo"), ("com.example.Here", "Here")])
        engine.offloadedOverride = { ["com.example.Foo"] }
        let foo = try write("Caches/com.example.Foo/blob")
        let here = try write("Caches/com.example.Here/blob")
        let report = try engine.clearAppCaches(apply: true, home: home.path)
        XCTAssertEqual(report.entries.map(\.bundleId), ["com.example.Foo"])
        XCTAssertFalse(fm.fileExists(atPath: foo.path))
        XCTAssertTrue(fm.fileExists(atPath: here.path), "an app installed on this Mac keeps its caches even if the repo has its image")
    }

    func testRefusesWhileTheAppRuns() throws {
        var engine = try makeEngine([("com.example.Foo", "Foo"), ("com.example.Bar", "Bar")])
        engine.appRunningOverride = { $0.bundleId == "com.example.Foo" }
        let fooBlob = try write("Caches/com.example.Foo/blob")
        let barBlob = try write("Caches/com.example.Bar/blob")

        let report = try engine.clearAppCaches(apply: true, home: home.path)
        let foo = try XCTUnwrap(report.entries.first { $0.bundleId == "com.example.Foo" })
        XCTAssertNotNil(foo.refusal)
        XCTAssertTrue(fm.fileExists(atPath: fooBlob.path), "a running app keeps its caches")
        XCTAssertFalse(fm.fileExists(atPath: barBlob.path), "other apps are still cleared")
        XCTAssertLessThan(report.freedBytes, foo.bytes + 10_000)
        XCTAssertTrue(report.text.contains("Foo"))
        XCTAssertTrue(report.text.contains("skipped"))
    }

    func testRefusesWhileStateSaysRunning() throws {
        let engine = try makeEngine([("com.example.Foo", "Foo")])
        let blob = try write("Caches/com.example.Foo/blob")
        let manifest = try XCTUnwrap(engine.list().first)
        for state in ["running", "detaching"] {
            try StateStore(engine.config.stateDir).update { $0.apps[manifest.bundleId] = AppState(imageId: manifest.imageId, state: state) }
            XCTAssertNotNil(engine.cacheClearRefusal(manifest), state)
            let report = try engine.clearAppCaches(apply: true, home: home.path)
            XCTAssertEqual(report.freedBytes, 0)
            XCTAssertTrue(fm.fileExists(atPath: blob.path), "\(state): caches stay")
        }
        try StateStore(engine.config.stateDir).update { $0.apps[manifest.bundleId] = AppState(imageId: manifest.imageId, state: "cached") }
        XCTAssertNil(engine.cacheClearRefusal(manifest))
    }

    func testDashboardRoutesMeasureAndClear() throws {
        let engine = try makeEngine([("com.example.Foo", "Foo")])
        let blob = try write("Caches/Foo/blob")
        let context = ManagementUIContext()
        context.home = home.path

        let measured = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/caches"), context: context)
        XCTAssertEqual(measured.status, 200)
        let dry = try XCTUnwrap(JSONSerialization.jsonObject(with: measured.body) as? [String: Any])
        XCTAssertEqual(dry["applied"] as? Bool, false)
        XCTAssertTrue(fm.fileExists(atPath: blob.path))

        let cleared = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "POST", path: "/api/caches/clear"), context: context)
        XCTAssertEqual(cleared.status, 200)
        let wet = try XCTUnwrap(JSONSerialization.jsonObject(with: cleared.body) as? [String: Any])
        XCTAssertEqual(wet["applied"] as? Bool, true)
        XCTAssertFalse(fm.fileExists(atPath: blob.path))
    }
}
