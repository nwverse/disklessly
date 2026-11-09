import XCTest
import DisklesslyCore
@testable import DisklesslyEngine

/// These tests cover the macOS dashboard, also when they run on Linux.
private let macContext = ManagementUIContext(platform: .macOS)

final class IconTests: XCTestCase {
    func testPlistIconKeys() {
        XCTAssertEqual(
            AppIcon.plistKeys(["CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon"]),
            AppIcon.PlistKeys(file: "AppIcon", name: "AppIcon")
        )
        XCTAssertEqual(AppIcon.icnsFileName("AppIcon"), "AppIcon.icns")
        XCTAssertEqual(AppIcon.icnsFileName("AppIcon.icns"), "AppIcon.icns")
        XCTAssertEqual(AppIcon.plistKeys(["CFBundleIconFile": "  ", "CFBundleIconName": ""]), AppIcon.PlistKeys(file: nil, name: nil))
        XCTAssertEqual(AppIcon.plistKeys(["CFBundleIconName": "AssetIcon"]).name, "AssetIcon")
        XCTAssertNil(AppIcon.plistKeys(["CFBundleIconFile": 1]).file)
    }

    func testIconCachePathAndBundleLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageId = "com.example.App-1.0_b1-arm64-abcdef12"
        let cache = AppIcon.cacheURL(stateDir: root.appendingPathComponent("state").path, imageId: imageId)
        XCTAssertEqual(cache?.lastPathComponent, imageId + ".png")
        XCTAssertEqual(cache?.deletingLastPathComponent().lastPathComponent, "icons")
        XCTAssertEqual(AppIcon.repoRelativePath(imageId: imageId), "icons/\(imageId).png")
        XCTAssertNil(AppIcon.cacheURL(stateDir: root.path, imageId: "../secret"))
        XCTAssertNil(AppIcon.imageId(apiPath: "/api/icon/../secret"))
        XCTAssertEqual(AppIcon.imageId(apiPath: "/api/icon/\(imageId)"), imageId)
        XCTAssertNil(AppIcon.imageId(apiPath: "/api/status"))

        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let icns = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        try Data("icns".utf8).write(to: icns)
        XCTAssertEqual(AppIcon.icnsURL(app: app, fileKey: "AppIcon")?.path, icns.path)
        XCTAssertNil(AppIcon.icnsURL(app: app, fileKey: "Missing"))
    }

    func testIconAPIRouteUsesCacheThenGeneric() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-icon-api-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mnt").path,
            stubDir: root.appendingPathComponent("apps").path
        )
        let engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        let missing = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/icon/com.example.Missing-1_b1-arm64-aaaaaaaa", query: [:], headers: [:], body: Data()), context: macContext)
        XCTAssertEqual(missing.status, 200)
        XCTAssertEqual(missing.contentType, "image/png")
        XCTAssertEqual(missing.body, AppIcon.genericPNG)
        XCTAssertTrue(missing.body.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))

        let imageId = "com.example.Cached-1_b1-arm64-bbbbbbbb"
        let cache = try XCTUnwrap(AppIcon.cacheURL(stateDir: config.stateDir, imageId: imageId))
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        var png = AppIcon.genericPNG
        png.append(contentsOf: [1, 2, 3, 4])
        try png.write(to: cache)
        let hit = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/icon/\(imageId)", query: [:], headers: [:], body: Data()), context: macContext)
        XCTAssertEqual(hit.status, 200)
        XCTAssertEqual(hit.body, png)

        let escaped = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/icon/..%2Fsecret", query: [:], headers: [:], body: Data()), context: macContext)
        XCTAssertEqual(escaped.status, 404)
    }

    func testIconsRefreshArgumentsParse() throws {
        XCTAssertTrue(try IconsArguments.parse(["refresh"]).refresh)
        XCTAssertFalse(try IconsArguments.parse(["backfill"]).refresh)
        XCTAssertThrowsError(try IconsArguments.parse(["refresh", "--app", "org.x"]))
        XCTAssertThrowsError(try IconsArguments.parse([]))
    }

    #if os(macOS)
    func testRebadgeFromCacheRebuildsStubIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-rebadge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state").path
        let imageId = "com.example.Rebadge-1.0-arm64-abcdef12"
        let cache = try XCTUnwrap(AppIcon.cacheURL(stateDir: stateDir, imageId: imageId))
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A 1x1 PNG is enough for NSImage to load the cache.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="))
        try png.write(to: cache)
        let stub = root.appendingPathComponent("Rebadge.app")
        try FileManager.default.createDirectory(at: stub.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        XCTAssertTrue(try StubIcon.rebadgeFromCache(stub: stub, imageId: imageId, stateDir: stateDir))
        let icns = stub.appendingPathComponent("Contents/Resources/AppIcon.icns")
        XCTAssertGreaterThan((try? Data(contentsOf: icns))?.count ?? 0, 0)
        XCTAssertFalse(try StubIcon.rebadgeFromCache(stub: stub, imageId: "com.example.Missing-1.0-arm64-00000000", stateDir: stateDir))
    }
    #endif
}
