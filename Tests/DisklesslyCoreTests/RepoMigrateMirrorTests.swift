import XCTest
import Foundation
@testable import DisklesslyCore
@testable import DisklesslyEngine

/// Repo copies (`RepoCopier`), migrate-on-switch, and mirrors with read failover.
final class RepoMigrateMirrorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func folder(_ name: String) throws -> LocalFolderBackend {
        try LocalFolderBackend(root: root.appendingPathComponent(name))
    }

    private func staging() -> URL { root.appendingPathComponent("staging-\(UUID().uuidString)") }

    @discardableResult
    private func addImage(_ backend: LocalFolderBackend, id: String, bytes: Data, recordedSha: String? = nil) throws -> ImageManifest {
        let image = ImageManifest.Image(file: "images/\(id).dmg", format: "ULMO", sha256: recordedSha ?? SHA256Digest.hex(bytes), size: UInt64(bytes.count), volumeName: id, appPathInVolume: "\(id).app")
        let manifest = ImageManifest(bundleId: "com.test.\(id)", name: id, version: "1", image: image,
                                     app: .init(originalPath: "/Applications/\(id).app", executable: id, documentTypes: [], urlTypes: []),
                                     imageId: id)
        try backend.put("images/\(id).dmg", data: bytes)
        try backend.put("manifests/\(id).json", data: try manifest.encode())
        return manifest
    }

    /// A repo with an id, two images, device and session files, and junk that must not travel.
    private func populatedRepo(_ name: String) throws -> (LocalFolderBackend, String) {
        let repo = try folder(name)
        let id = try XCTUnwrap(RepoIdentity.ensure(repo))
        try addImage(repo, id: "alpha", bytes: Data(repeating: 1, count: 300_000))
        try addImage(repo, id: "beta", bytes: Data("beta image".utf8))
        try repo.put("devices/mac-1.json", data: Data(#"{"name":"one"}"#.utf8))
        try repo.put("sessions/dev/claude/seg-1.tar.zst", data: Data(repeating: 7, count: 5_000))
        try repo.put("catalog/manifest.json", data: Data("{}".utf8))
        try repo.ensureCollection("trash")
        // Transient names: staging siblings, our temp files, locks, conflict copies.
        try repo.put("images/.alpha.dmg.tmp-1234", data: Data("partial".utf8))
        try repo.put("disklessly-staging", data: Data("x".utf8))
        try repo.put("locks/repo.lock", data: Data("x".utf8))
        try repo.put("manifests/alpha 2.json", data: Data("conflict".utf8))
        return (repo, id)
    }

    private func makeEngine(repo: String, backends: [BackendEndpoint] = [], active: String? = nil) throws -> DisklesslyEngine {
        var config = RuntimeConfig(repoPath: root.appendingPathComponent(repo).path,
                                   cacheDir: root.appendingPathComponent("cache").path,
                                   stateDir: root.appendingPathComponent("state").path,
                                   mountRoot: root.appendingPathComponent("mnt").path,
                                   stubDir: root.appendingPathComponent("apps").path)
        config.backends = backends
        config.activeBackendId = active
        return DisklesslyEngine(config: config, secrets: MemorySecretStore())
    }

    private func localEndpoint(_ id: String, folder name: String) -> BackendEndpoint {
        let path = root.appendingPathComponent(name).path
        return BackendEndpoint(id: id, type: "local", mountPoint: path, root: path)
    }

    private func savedConfig(_ engine: DisklesslyEngine) throws -> RuntimeConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: engine.config.stateDir).appendingPathComponent("config.json"))
        return try JSONDecoder().decode(RuntimeConfig.self, from: data)
    }

    // MARK: - RepoCopier

    func testCopyCopiesEverythingButTransientsAndCarriesTheRepoId() throws {
        let (source, id) = try populatedRepo("old")
        let destination = try folder("new")
        var events: [RepoCopyProgress] = []
        let report = try RepoCopier(source: source, destination: destination, staging: staging()).run { events.append($0) }

        XCTAssertEqual(report.failed, [:])
        XCTAssertEqual(Set(report.copied), ["repo.json", "images/alpha.dmg", "images/beta.dmg", "manifests/alpha.json", "manifests/beta.json",
                                            "devices/mac-1.json", "sessions/dev/claude/seg-1.tar.zst", "catalog/manifest.json"])
        XCTAssertEqual(report.copied.last, "repo.json", "repo identity is written last")
        XCTAssertLessThan(report.copied.firstIndex(of: "images/alpha.dmg")!, report.copied.firstIndex(of: "manifests/alpha.json")!)
        XCTAssertEqual(RepoIdentity.read(destination), id)
        XCTAssertEqual(try destination.get("images/alpha.dmg", range: nil), try source.get("images/alpha.dmg", range: nil))
        XCTAssertNil(try destination.stat("images/.alpha.dmg.tmp-1234"))
        XCTAssertNil(try destination.stat("disklessly-staging"))
        XCTAssertNil(try destination.stat("locks/repo.lock"))
        XCTAssertNil(try destination.stat("manifests/alpha 2.json"))
        XCTAssertNotNil(try destination.stat("trash"), "empty folders are recreated")
        let last = try XCTUnwrap(events.last)
        XCTAssertEqual(last.phase, "done")
        XCTAssertEqual(last.filesDone, last.filesTotal)
        XCTAssertEqual(last.bytesDone, last.bytesTotal)
        XCTAssertGreaterThan(last.bytesTotal, 300_000)
        XCTAssertTrue(events.contains { $0.currentPath == "images/alpha.dmg" })
        XCTAssertEqual(try RepoCopier(source: source, destination: destination, staging: staging()).verify(), [])
    }

    func testRerunSkipsIdenticalAndRecopiesChangedSmallFiles() throws {
        let (source, _) = try populatedRepo("old")
        let destination = try folder("new")
        let copier = RepoCopier(source: source, destination: destination, staging: staging())
        _ = try copier.run()
        let again = try copier.run()
        XCTAssertEqual(again.copied, [])
        XCTAssertEqual(again.failed, [:])
        XCTAssertEqual(again.skipped.count, 8)

        // Same size, different content: small files compare by content.
        try source.put("devices/mac-1.json", data: Data(#"{"name":"two"}"#.utf8))
        let third = try copier.run()
        XCTAssertEqual(third.copied, ["devices/mac-1.json"])
        XCTAssertEqual(try destination.get("devices/mac-1.json", range: nil), Data(#"{"name":"two"}"#.utf8))
    }

    func testInterruptedCopyResumesWithTheRest() throws {
        let (source, _) = try populatedRepo("old")
        let destination = try folder("new")
        // A previous run got as far as one image, and left a short copy of the other.
        try destination.put("images/alpha.dmg", data: try source.get("images/alpha.dmg", range: nil))
        try destination.put("images/beta.dmg", data: Data("bet".utf8))
        let report = try RepoCopier(source: source, destination: destination, staging: staging()).run()
        XCTAssertEqual(report.failed, [:])
        XCTAssertTrue(report.skipped.contains("images/alpha.dmg"))
        XCTAssertTrue(report.copied.contains("images/beta.dmg"))
        XCTAssertEqual(try destination.get("images/beta.dmg", range: nil), Data("beta image".utf8))
    }

    func testImageThatDoesNotMatchItsManifestIsNotCopied() throws {
        let source = try folder("old")
        try RepoIdentity.ensure(source)
        try addImage(source, id: "bad", bytes: Data("corrupt bytes".utf8), recordedSha: String(repeating: "a", count: 64))
        let destination = try folder("new")
        let copier = RepoCopier(source: source, destination: destination, staging: staging())
        let report = try copier.run()
        XCTAssertNotNil(report.failed["images/bad.dmg"])
        XCTAssertNil(try destination.stat("images/bad.dmg"))
        XCTAssertFalse(try copier.verify().isEmpty)
    }

    func testCopyRefusesADestinationThatIsAnotherRepo() throws {
        let (source, _) = try populatedRepo("old")
        let (other, otherId) = try populatedRepo("other")
        XCTAssertThrowsError(try RepoCopier(source: source, destination: other, staging: staging()).run())
        XCTAssertEqual(RepoIdentity.read(other), otherId)
    }

    func testFreshRepoWithOnlyIdentityHasNoContent() throws {
        let repo = try folder("fresh")
        try RepoIdentity.ensure(repo)
        for dir in ["images", "manifests", "catalog", "devices", "trash"] { try repo.ensureCollection(dir) }
        XCTAssertFalse(try RepoCopier.hasContent(repo))
        try repo.put("sessions/dev/codex/seg.tar.zst", data: Data("s".utf8))
        XCTAssertTrue(try RepoCopier.hasContent(repo), "archived sessions alone still need moving")
    }

    func testICloudPlaceholdersAreCopiedByTheirLogicalName() throws {
        let repo = try folder("icloud")
        try repo.put("images/.evicted.dmg.icloud", data: Data("placeholder".utf8))
        try repo.put("images/kept.dmg", data: Data("kept".utf8))
        let paths = try RepoCopier.scan(repo).items.map(\.path)
        XCTAssertEqual(Set(paths), ["images/evicted.dmg", "images/kept.dmg"])
        XCTAssertFalse(RepoCopier.isTransient(".evicted.dmg.icloud"))
        XCTAssertTrue(RepoCopier.isTransient(".evicted.dmg.tmp-ABC"))
    }

    // MARK: - Switch with migrate

    func testSwitchWithMigrateKeepsRepoIdAndFlipsConfig() throws {
        let (_, id) = try populatedRepo("old")
        var engine = try makeEngine(repo: "old", backends: [localEndpoint("nas", folder: "new")])
        try engine.saveConfig()
        var phases: [String] = []
        let report = try engine.switchRepo(to: "nas", migrate: true, keepOldAsMirror: true) { phases.append($0.phase) }

        XCTAssertTrue(report.migrated)
        XCTAssertEqual(report.keptAsMirror, "default")
        XCTAssertEqual(engine.config.activeBackendId, "nas")
        XCTAssertEqual(engine.config.mirrorBackendIds, ["default"])
        XCTAssertEqual(engine.repoIdentity(), id, "the new repo is the same repo, so stubs keep working")
        let saved = try savedConfig(engine)
        XCTAssertEqual(saved.activeBackendId, "nas")
        XCTAssertEqual(saved.mirrorBackendIds, ["default"])
        XCTAssertEqual(try engine.list().map(\.imageId).sorted(), ["alpha", "beta"])
        XCTAssertTrue(phases.contains("copy"))
        XCTAssertTrue(phases.contains("verify"))
        XCTAssertEqual(phases.last, "done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.repoSyncStaging.path), "staging is cleaned up")
    }

    func testFailedMigrationLeavesConfigOnTheOldRepo() throws {
        _ = try populatedRepo("old")
        // `images` is a plain file on the destination, so no image can be written there.
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: broken.appendingPathComponent("images"))
        var engine = try makeEngine(repo: "old", backends: [localEndpoint("nas", folder: "broken")])
        try engine.saveConfig()

        XCTAssertThrowsError(try engine.switchRepo(to: "nas", migrate: true, keepOldAsMirror: true))
        XCTAssertNil(engine.config.activeBackendId)
        XCTAssertEqual(engine.config.mirrorBackendIds, [])
        XCTAssertNil(try savedConfig(engine).activeBackendId)
    }

    func testEmptyOldRepoSwitchesWithoutCopying() throws {
        let old = try folder("old")
        try RepoIdentity.ensure(old)
        var engine = try makeEngine(repo: "old", backends: [localEndpoint("nas", folder: "new")])
        let report = try engine.switchRepo(to: "nas", migrate: true)
        XCTAssertFalse(report.migrated)
        XCTAssertEqual(engine.config.activeBackendId, "nas")
        XCTAssertNotNil(RepoIdentity.read(try folder("new")), "prepareRepo still sets up the new repo")
    }

    // MARK: - Mirrors

    func testReadsFailOverToAMirrorThatHasTheObject() throws {
        let (primary, _) = try populatedRepo("primary")
        _ = try RepoCopier(source: primary, destination: try folder("mirror"), staging: staging()).run()
        try primary.delete("images/beta.dmg")

        var engine = try makeEngine(repo: "primary", backends: [localEndpoint("backup", folder: "mirror")])
        try engine.addMirror("backup")
        let backend = try engine.repo
        let failover = try XCTUnwrap(backend as? FailoverBackend)
        XCTAssertEqual(try backend.get("images/beta.dmg", range: nil), Data("beta image".utf8))
        XCTAssertEqual(failover.lastServedBy, "backup")
        XCTAssertNil(try backend.stat("images/beta.dmg"), "a primary that says 'not there' is believed for stat")

        // The launch path: CacheFetcher downloads straight from the repo and checks the sha.
        let manifest = try XCTUnwrap(try engine.list().first { $0.imageId == "beta" })
        let destination = root.appendingPathComponent("cache-out/beta.dmg")
        try CacheFetcher.materialize(backend: backend, remote: manifest.image.file, destination: destination,
                                     partial: root.appendingPathComponent("cache-out/beta.partial"),
                                     expectedSize: manifest.image.size, expectedSHA256: manifest.image.sha256)
        XCTAssertEqual(try Data(contentsOf: destination), Data("beta image".utf8))

        // Writes stay on the primary.
        try backend.put("devices/new.json", data: Data("{}".utf8))
        XCTAssertNotNil(try primary.stat("devices/new.json"))
        XCTAssertNil(try folder("mirror").stat("devices/new.json"))
    }

    func testUnreachablePrimaryListsFromTheMirror() throws {
        let mirror = try folder("mirror")
        try addImage(mirror, id: "gamma", bytes: Data("g".utf8))
        let primary = try FaultyBackend(root: root.appendingPathComponent("primary"), failList: ["manifests"], failGet: ["manifests"])
        let backend = FailoverBackend(primary: primary, mirrors: [(id: "m", open: { mirror }), (id: "dead", open: { throw DisklesslyError.backend("offline") })])
        XCTAssertEqual(try backend.list("manifests"), ["gamma.json"])
        XCTAssertEqual(backend.lastServedBy, "m")
    }

    func testNoMirrorsMeansTheRawBackend() throws {
        let engine = try makeEngine(repo: "primary")
        XCTAssertTrue(try engine.repo is LocalFolderBackend)
    }

    func testSyncMirrorsRecordsStatus() throws {
        _ = try populatedRepo("primary")
        var engine = try makeEngine(repo: "primary", backends: [localEndpoint("backup", folder: "mirror"), localEndpoint("gone", folder: "gone")])
        try engine.addMirror("backup")
        XCTAssertThrowsError(try engine.addMirror("default"), "the active repo cannot be its own mirror")
        XCTAssertThrowsError(try engine.addMirror("nope"))
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let results = try engine.syncMirrors(now: { stamp })
        XCTAssertEqual(results["backup"]?.ok, true)
        XCTAssertEqual(results["backup"]?.copied, 8)
        XCTAssertEqual(RepoIdentity.read(try folder("mirror")), engine.repoIdentity())

        let listing = engine.mirrorListing()
        XCTAssertEqual(listing.count, 1)
        XCTAssertEqual(listing.first?["id"] as? String, "backup")
        let last = try XCTUnwrap(listing.first?["lastSync"] as? [String: Any])
        XCTAssertEqual(last["ok"] as? Bool, true)
        XCTAssertEqual(last["lastSyncAt"] as? String, ISO8601DateFormatter().string(from: stamp))

        let second = try engine.syncMirrors()
        XCTAssertEqual(second["backup"]?.copied, 0)
        XCTAssertEqual(second["backup"]?.skipped, 8)
        try engine.removeMirror("backup")
        XCTAssertEqual(try savedConfig(engine).mirrorBackendIds, [])
    }

    func testMirrorRoutes() throws {
        _ = try populatedRepo("primary")
        var engine = try makeEngine(repo: "primary", backends: [localEndpoint("backup", folder: "mirror")])
        try engine.saveConfig()
        let context = ManagementUIContext()
        func post(_ path: String, _ body: [String: Any]) throws -> (Int, [String: Any]) {
            let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "POST", path: path, body: try JSONSerialization.data(withJSONObject: body)), context: context)
            return (response.status, try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
        }
        let (status, added) = try post("/api/cloud/mirrors", ["action": "add", "id": "backup"])
        XCTAssertEqual(status, 200)
        let cloud = try XCTUnwrap(added["cloud"] as? [String: Any])
        XCTAssertEqual((cloud["mirrors"] as? [[String: Any]])?.first?["id"] as? String, "backup")
        XCTAssertEqual(cloud["activeId"] as? String, "default")
        engine.config = try XCTUnwrap(context.updatedConfig())

        let (syncStatus, _) = try post("/api/cloud/mirrors/sync", [:])
        XCTAssertEqual(syncStatus, 202)
        let task = try waitForTask(context)
        XCTAssertEqual(task["state"] as? String, "done", "\(task)")
        XCTAssertEqual(task["action"] as? String, "mirror-sync")
        XCTAssertEqual(task["allOk"] as? Bool, true)
        XCTAssertNotNil(task["id"] as? String)
    }

    func testMigrateRouteRunsAsATaskAndSwitches() throws {
        let (_, id) = try populatedRepo("old")
        var engine = try makeEngine(repo: "old", backends: [localEndpoint("nas", folder: "new")])
        try engine.saveConfig()
        let context = ManagementUIContext()
        let body = try JSONSerialization.data(withJSONObject: ["id": "nas", "migrate": true, "keepOldAsMirror": true])
        let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "POST", path: "/api/cloud/use", body: body), context: context)
        XCTAssertEqual(response.status, 202)
        let started = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertFalse((started["taskId"] as? String ?? "").isEmpty)
        let task = try waitForTask(context)
        XCTAssertEqual(task["state"] as? String, "done", "\(task)")
        XCTAssertEqual(task["migrated"] as? Bool, true)
        XCTAssertEqual(task["keptAsMirror"] as? String, "default")
        let updated = try XCTUnwrap(context.updatedConfig())
        XCTAssertEqual(updated.activeBackendId, "nas")
        engine.config = updated
        XCTAssertEqual(engine.repoIdentity(), id)
    }

    private func waitForTask(_ context: ManagementUIContext, timeout: TimeInterval = 30) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = context.cloud.snapshot()
            if let state = snapshot["state"] as? String, state != "running" { return snapshot }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("cloud task did not finish")
        return [:]
    }

    // MARK: - Config

    func testMirrorIdsRoundTripAndStayOutOfOldConfigs() throws {
        var config = RuntimeConfig(repoPath: "/r", cacheDir: "/c", stateDir: "/s", mountRoot: "/m", stubDir: "/a")
        let plain = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(plain.contains("mirrorBackendIds"))
        XCTAssertEqual(try JSONDecoder().decode(RuntimeConfig.self, from: Data(plain.utf8)).mirrorBackendIds, [])
        config.mirrorBackendIds = ["default", "nas"]
        let decoded = try JSONDecoder().decode(RuntimeConfig.self, from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded.mirrorBackendIds, ["default", "nas"])
    }
}
