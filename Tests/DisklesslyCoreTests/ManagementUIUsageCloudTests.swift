import XCTest
import Foundation
import DisklesslyCore
@testable import DisklesslyEngine

/// `GET /api/usage/cloud`: the cloud side of the usage map, read from the local catalog only.
final class ManagementUIUsageCloudTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-usage-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func engine() -> DisklesslyEngine {
        // The repo path does not exist: any backend call would fail or hang, so the route must not make one.
        let config = RuntimeConfig(repoPath: root.appendingPathComponent("no-repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        return DisklesslyEngine(config: config, secrets: MemorySecretStore())
    }

    private func get(_ engine: DisklesslyEngine, _ path: String, context: ManagementUIContext) throws -> (status: Int, object: [String: Any]) {
        let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: path), context: context)
        return (response.status, try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
    }

    func testShapeFromTheLocalCatalogWithoutTouchingTheBackend() throws {
        let engine = engine()
        let state = engine.config.stateDir
        // One offloaded folder: its placeholder on disk and the registry row.
        let original = root.appendingPathComponent("Movies/Raw")
        let placeholderURL = FilePlaceholder.placeholderURL(for: original)
        try FileManager.default.createDirectory(at: placeholderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let placeholder = FilePlaceholder(id: "f1", kind: .folder, name: "Raw", size: 5000, object: FilePlaceholder.objectPath(sha256: String(repeating: "b", count: 64), kind: .folder), codec: "tar+zstd", sha256: String(repeating: "b", count: 64), storedSize: 1200, repoId: nil, originalPath: original.path, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try placeholder.encode().write(to: placeholderURL)
        try OffloadedFileRegistry.update(stateDir: state) { records in
            records.append(OffloadedFileRecord(id: "f1", placeholderPath: placeholderURL.path, name: "Raw", kind: .folder, size: 5000, object: placeholder.object, createdAt: placeholder.createdAt))
        }

        let probed = Counter()
        let context = ManagementUIContext(platform: .macOS, health: BackendHealthProbe(timeout: 0.2, check: { _ in probed.add(); return nil }))
        var app = CloudUsageInputs.Item(id: "img1", name: "Krita", bytes: 3000, storedBytes: 900, originPath: "/Applications/Krita.app", restore: "unpack", restoreId: "Krita")
        app.otherDevice = "Studio Mini"
        context.setCloudCatalog(CloudAppCatalog(apps: [.init(item: app, bundleId: "org.krita")], listedAt: Date()))

        let started = Date()
        let (status, object) = try get(engine, "/api/usage/cloud", context: context)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "answers from local state at once")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(probed.value, 0, "no health probe and no listing")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertNotNil(object["generatedAt"] as? String)
        XCTAssertEqual(object["reachable"] as? Bool, true, "unknown health is not reported as offline")
        XCTAssertEqual((object["totalBytes"] as? NSNumber)?.intValue, 8000)
        XCTAssertEqual((object["storedBytes"] as? NSNumber)?.intValue, 2100)
        let tree = try XCTUnwrap(object["tree"] as? [String: Any])
        XCTAssertEqual(tree["key"] as? String, "cloud")
        let groups = try XCTUnwrap(tree["children"] as? [[String: Any]])
        XCTAssertEqual(groups.compactMap { $0["key"] as? String }, ["files", "apps"])
        let raw = try XCTUnwrap((groups[0]["children"] as? [[String: Any]])?.first)
        XCTAssertEqual(raw["originPath"] as? String, original.path)
        XCTAssertEqual(raw["stubPath"] as? String, placeholderURL.path)
        XCTAssertEqual(raw["restore"] as? String, "fetch")
        XCTAssertEqual((raw["storedBytes"] as? NSNumber)?.intValue, 1200, "stored size read from the placeholder")
        let krita = try XCTUnwrap((groups[1]["children"] as? [[String: Any]])?.first)
        XCTAssertEqual(krita["otherDevice"] as? String, "Studio Mini")
        XCTAssertEqual(krita["restoreId"] as? String, "Krita")
    }

    func testEmptyCatalogAndOfflineHealth() throws {
        let engine = engine()
        let context = ManagementUIContext(platform: .macOS, health: BackendHealthProbe(timeout: 0.2, check: { _ in throw DisklesslyError.usage("down") }))
        _ = context.health.current(engine)
        let (status, object) = try get(engine, "/api/usage/cloud", context: context)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(object["reachable"] as? Bool, false)
        XCTAssertEqual(object["health"] as? String, "offline")
        XCTAssertEqual((object["totalBytes"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(((object["tree"] as? [String: Any])?["children"] as? [Any])?.count ?? 0, 0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
