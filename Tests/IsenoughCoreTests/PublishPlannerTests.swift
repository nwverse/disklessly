import XCTest
import Foundation
@testable import IsenoughCore
@testable import IsenoughEngine

final class PublishPlannerTests: XCTestCase {
    func testDecisionTable() {
        let hash = String(repeating: "ab", count: 32)
        let other = String(repeating: "cd", count: 32)
        let identity = ImageIdentity(bundleId: "com.example.App", version: "1.0", build: "1", architectures: ["arm64"], treeHash: hash)
        let manifest = sampleManifest(identity: identity, sha: hash)
        let rows: [(String, ImageEvidence, Bool, PublishDecision)] = [
            ("trash", .absent, true, .refuse("image \(manifest.imageId) is in the trash. Run isenough gc before packing again; a reference restores it. The original app was not changed.", code: 5)),
            ("missing", .absent, false, .refuse("manifest \(manifest.imageId) exists but its image is missing and may still be syncing from another Mac. The original app was not changed. Retry later.", code: 5)),
            ("placeholder-yes", .placeholder(cloudConfirmed: true), false, .reuse(manifest, .dispose)),
            ("placeholder-no", .placeholder(cloudConfirmed: false), false, .reuse(manifest, .keep(reason: "cloud copy not confirmed"))),
            ("local-uploaded", .local(sha256: hash, uploaded: true), false, .reuse(manifest, .dispose)),
            ("local-unknown", .local(sha256: hash, uploaded: nil), false, .reuse(manifest, .dispose)),
            ("local-uploading", .local(sha256: hash, uploaded: false), false, .reuse(manifest, .keep(reason: "image is still uploading"))),
            ("sha-mismatch", .local(sha256: other, uploaded: nil), false, .refuse("image \(manifest.image.file) is already in the repo but its sha256 does not match the manifest. Refusing to overwrite it.", code: 5)),
            ("unreadable", .unreadable("stat failed"), false, .refuse("stat failed", code: 4)),
        ]
        XCTAssertEqual(rows.count, 9)
        for row in rows {
            let decision = PublishPlanner.decide(identity: identity, manifests: [manifest], evidence: { _ in row.1 }, inTrash: { _ in row.2 })
            XCTAssertEqual(decision, row.3, row.0)
        }

        let fresh = ImageIdentity(bundleId: "com.example.New", version: "1.0", build: "1", architectures: ["arm64"], treeHash: hash)
        let freshId = fresh.imageId { _ in nil }
        let tableB: [(String, ImageEvidence, PublishDecision)] = [
            ("create", .absent, .create(imageId: freshId)),
            ("placeholder", .placeholder(cloudConfirmed: true), .refuse("images/\(freshId).dmg is an iCloud placeholder. Refusing to overwrite it.", code: 5)),
            ("local", .local(sha256: hash, uploaded: nil), .refuse("images/\(freshId).dmg already exists. Refusing to overwrite it.", code: 5)),
            ("unreadable", .unreadable("boom"), .refuse("boom", code: 4)),
        ]
        XCTAssertEqual(tableB.count, 4)
        for row in tableB {
            let decision = PublishPlanner.decide(identity: fresh, manifests: [], evidence: { _ in row.1 }, inTrash: { _ in false })
            XCTAssertEqual(decision, row.2, row.0)
        }
    }

    func testReuseWithMissingImageRefuses() throws {
        var world = try World()
        defer { world.cleanup() }
        let image = try world.imageFile("same")
        let first = try world.engineA.publish(world.request(), imageFile: image, now: world.now)
        try FileManager.default.removeItem(at: world.repo.appendingPathComponent(first.manifest.image.file))
        let faulty = try FaultyBackend(root: world.repo)
        world.engineB.backendOverride = faulty
        XCTAssertThrowsError(try world.engineB.publish(world.request(), imageFile: image, now: world.now)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 5)
            XCTAssertTrue(((error as? IsenoughError)?.errorDescription ?? "").contains("missing"))
        }
        XCTAssertFalse(faulty.calls.contains { $0.hasPrefix("put:") })
        let device = world.repo.appendingPathComponent("devices/\(world.deviceId(world.engineB)).json")
        if FileManager.default.fileExists(atPath: device.path) {
            let record = try DeviceRecord.decode(Data(contentsOf: device))
            XCTAssertFalse(record.images.contains { $0.imageId == first.manifest.imageId })
        }
    }

    func testReuseWithUnconfirmedPlaceholderKeepsOriginal() throws {
        var world = try World()
        defer { world.cleanup() }
        let image = try world.imageFile("same")
        let first = try world.engineA.publish(world.request(), imageFile: image, now: world.now)
        world.engineA.imageEvidenceOverride = { _ in .placeholder(cloudConfirmed: false) }
        let second = try world.engineA.publish(world.request(), imageFile: image, now: world.now.addingTimeInterval(10))
        XCTAssertTrue(second.reused)
        XCTAssertEqual(second.manifest.imageId, first.manifest.imageId)
        XCTAssertNotNil(second.originalKept)
    }

    func testReuseWhenImageTrashedPointsToGc() throws {
        let world = try World()
        defer { world.cleanup() }
        let image = try world.imageFile("same")
        let first = try world.engineA.publish(world.request(), imageFile: image, now: world.now)
        let destination = world.repo.appendingPathComponent("trash/images/\(first.manifest.imageId).dmg")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: world.repo.appendingPathComponent(first.manifest.image.file), to: destination)
        XCTAssertThrowsError(try world.engineB.publish(world.request(), imageFile: image, now: world.now)) { error in
            let message = (error as? IsenoughError)?.errorDescription ?? ""
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 5)
            XCTAssertTrue(message.contains("isenough gc"))
        }
    }

    private func sampleManifest(identity: ImageIdentity, sha: String) -> ImageManifest {
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: 4, volumeName: "Example", appPathInVolume: "Example.app")
        let app = ImageManifest.App(originalPath: "/Applications/Example.app", executable: "Example", documentTypes: [], urlTypes: [], cdhash: "cd", treeHash: identity.treeHash)
        return ImageManifest(bundleId: identity.bundleId, name: "Example", version: identity.version, image: image, app: app, mode: .mount, createdAt: Date(timeIntervalSince1970: 1_800_000_000), build: identity.build, architectures: identity.architectures, contentTreeHash: identity.treeHash)
    }

    private struct World {
        var root: URL
        var repo: URL
        var engineA: IsenoughEngine
        var engineB: IsenoughEngine
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var hash = String(repeating: "ab", count: 32)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-pub-\(UUID().uuidString)")
            repo = root.appendingPathComponent("repo")
            engineA = try Self.make(root: root, repo: repo, name: "a")
            engineB = try Self.make(root: root, repo: repo, name: "b")
            try engineA.initialize()
            try engineB.initialize()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func request() -> PublishRequest {
            PublishRequest(name: "Example", identity: ImageIdentity(bundleId: "com.example.App", version: "1.0", build: "10", architectures: ["arm64"], treeHash: hash), mode: .mount, executable: "Example", originalPath: "/Applications/Example.app", cdhash: "cd", postImageTreeHash: hash, volumeName: "Example", appPathInVolume: "Example.app")
        }

        func imageFile(_ name: String) throws -> URL {
            let url = root.appendingPathComponent("\(name).dmg")
            try Data(name.utf8).write(to: url)
            return url
        }

        func deviceId(_ engine: IsenoughEngine) -> String {
            LocalDeviceStore.load(stateDir: URL(fileURLWithPath: engine.config.stateDir))?.deviceId ?? ""
        }

        private static func make(root: URL, repo: URL, name: String) throws -> IsenoughEngine {
            let config = RuntimeConfig(
                repoPath: repo.path,
                cacheDir: root.appendingPathComponent("cache-\(name)").path,
                stateDir: root.appendingPathComponent("state-\(name)").path,
                mountRoot: root.appendingPathComponent("mnt-\(name)").path,
                stubDir: root.appendingPathComponent("apps-\(name)").path
            )
            var engine = IsenoughEngine(config: config, secrets: MemorySecretStore())
            engine.deviceFactsOverride = DeviceFacts(hostname: name, arch: "arm64", osVersion: "15.6")
            engine.stubRootsOverride = []
            return engine
        }
    }
}
