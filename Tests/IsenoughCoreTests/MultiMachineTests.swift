import XCTest
import Foundation
@testable import IsenoughCore
@testable import IsenoughEngine

final class MultiMachineTests: XCTestCase {
    func testImageIdFollowsBundleVersionBuildArchAndTreeHash() {
        let hash = String(repeating: "ab", count: 32)
        let base = ImageIdentity(bundleId: "com.example.App", version: "1.2.3", build: "45", architectures: ["x86_64", "arm64"], treeHash: hash)
        XCTAssertEqual(base.imageId(), "com.example.App-1.2.3_b45-arm64+x86_64-abababab")
        XCTAssertNotEqual(base.imageId(), ImageIdentity(bundleId: base.bundleId, version: "1.2.4", build: base.build, architectures: base.architectures, treeHash: hash).imageId())
        XCTAssertNotEqual(base.imageId(), ImageIdentity(bundleId: base.bundleId, version: base.version, build: "46", architectures: base.architectures, treeHash: hash).imageId())
        XCTAssertNotEqual(base.imageId(), ImageIdentity(bundleId: base.bundleId, version: base.version, build: base.build, architectures: ["arm64"], treeHash: hash).imageId())
        XCTAssertNotEqual(base.imageId(), ImageIdentity(bundleId: base.bundleId, version: base.version, build: base.build, architectures: base.architectures, treeHash: String(repeating: "cd", count: 32)).imageId())
        let occupied = ImageIdentity(bundleId: "other.app", version: "9", build: "1", architectures: ["arm64"], treeHash: String(repeating: "ef", count: 32))
        let lengthened = base.imageId { candidate in
            candidate == base.imageId() ? occupied : nil
        }
        XCTAssertTrue(lengthened.hasSuffix(String(hash.prefix(16))))
        XCTAssertNotEqual(lengthened, base.imageId())
    }

    func testMachOSlicesFromInjectedHeaders() {
        var thin = Data([0xCF, 0xFA, 0xED, 0xFE])
        thin.append(contentsOf: [0x0C, 0x00, 0x00, 0x01])
        thin.append(contentsOf: [0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(MachArchitectures.slices(header: thin), ["arm64e"])
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE])
        fat.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        fat.append(contentsOf: [0x01, 0x00, 0x00, 0x07])
        fat.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        fat.append(contentsOf: [UInt8](repeating: 0, count: 12))
        fat.append(contentsOf: [0x01, 0x00, 0x00, 0x0C])
        fat.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        fat.append(contentsOf: [UInt8](repeating: 0, count: 12))
        XCTAssertEqual(MachArchitectures.slices(header: fat), ["arm64", "x86_64"])
    }

    func testTreeHashIgnoresMacAppStoreReceipt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try bundle(root.appendingPathComponent("One.app"), receipt: Data("receipt-a".utf8))
        let second = try bundle(root.appendingPathComponent("Two.app"), receipt: Data("receipt-b".utf8))
        let changed = try bundle(root.appendingPathComponent("Three.app"), receipt: Data("receipt-a".utf8), body: Data("different".utf8))
        XCTAssertEqual(try BundleHasher.treeHash(of: first), try BundleHasher.treeHash(of: second))
        XCTAssertNotEqual(try BundleHasher.treeHash(of: first), try BundleHasher.treeHash(of: changed))
        try MASReceiptStore.preserve(from: first, bundleId: "com.example.App", stateDir: root.appendingPathComponent("state"))
        BundleHasher.removeMachineReceipt(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("Contents/_MASReceipt/receipt").path))
        let restored = root.appendingPathComponent("Restored.app")
        try FileManager.default.copyItem(at: first, to: restored)
        try FileManager.default.createDirectory(at: restored.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: restored.appendingPathComponent("Contents/_MASReceipt/receipt"))
        let warning = try MASReceiptStore.reconcile(app: restored, bundleId: "com.example.App", stateDir: root.appendingPathComponent("state"))
        XCTAssertNil(warning)
        let installed = try Data(contentsOf: restored.appendingPathComponent("Contents/_MASReceipt/receipt"))
        XCTAssertEqual(installed, Data("receipt-a".utf8))
        let plan = MASReceiptPolicy.plan(imageHadReceipt: true, localReceiptAvailable: false)
        XCTAssertFalse(plan.useImageReceipt)
        XCTAssertFalse(plan.installLocalReceipt)
        XCTAssertTrue(plan.warning?.contains("per Apple ID") == true)
    }

    func testTwoDevicesShareOneImageAndKeepSeparateState() throws {
        let world = try World()
        defer { world.cleanup() }
        let image = try world.imageFile("same-bytes")
        let first = try world.engineA.publish(world.request(version: "1.0", build: "10", arch: ["arm64"], hash: world.hash), imageFile: image, now: world.now)
        XCTAssertFalse(first.reused)
        XCTAssertTrue(first.uploaded)
        let deviceFile = world.repo.appendingPathComponent("devices/\(world.deviceId(world.engineA)).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deviceFile.path))
        let before = try Data(contentsOf: deviceFile)
        let second = try world.engineB.publish(world.request(version: "1.0", build: "10", arch: ["arm64"], hash: world.hash), imageFile: image, now: world.now.addingTimeInterval(10))
        XCTAssertTrue(second.reused)
        XCTAssertFalse(second.uploaded)
        XCTAssertEqual(second.manifest.imageId, first.manifest.imageId)
        let manifests = try FileManager.default.contentsOfDirectory(atPath: world.repo.appendingPathComponent("manifests").path)
        XCTAssertEqual(manifests.filter { $0.hasSuffix(".json") && !RepoFileNames.isConflictCopy($0) }.count, 1)
        let images = try FileManager.default.contentsOfDirectory(atPath: world.repo.appendingPathComponent("images").path)
        XCTAssertEqual(images.filter { $0.hasSuffix(".dmg") }.count, 1)
        let after = try Data(contentsOf: world.repo.appendingPathComponent("devices/\(world.deviceId(world.engineA)).json"))
        XCTAssertEqual(before, after)
        XCTAssertNotEqual(world.deviceId(world.engineA), world.deviceId(world.engineB))
        XCTAssertNotEqual(world.deviceId(world.engineA), "mini")
        let deviceNames = try FileManager.default.contentsOfDirectory(atPath: world.repo.appendingPathComponent("devices").path)
        XCTAssertFalse(deviceNames.contains { $0.contains(".tmp-") })
        let catalog = try Data(contentsOf: world.repo.appendingPathComponent("catalog/manifest.json"))
        XCTAssertTrue(String(decoding: catalog, as: UTF8.self).contains(first.manifest.imageId))
        let deviceJSON = String(decoding: after, as: UTF8.self)
        XCTAssertFalse(deviceJSON.contains("\"pinned\""))
        var state = StateStore(world.engineA.config.stateDir).read()
        var apps = state["apps"] as? [String: [String: Any]] ?? [:]
        apps["com.example.App"] = ["pinned": true, "imageId": first.manifest.imageId]
        state["apps"] = apps
        try StateStore(world.engineA.config.stateDir).write(state)
        _ = try world.engineA.publish(world.request(version: "1.0", build: "10", arch: ["arm64"], hash: world.hash), imageFile: image, now: world.now)
        let pinned = StateStore(world.engineA.config.stateDir).read()["apps"] as? [String: [String: Any]]
        XCTAssertEqual(pinned?["com.example.App"]?["pinned"] as? Bool, true)
        let otherMachine = StateStore(world.engineB.config.stateDir).read()["apps"] as? [String: [String: Any]]
        XCTAssertNotEqual(otherMachine?["com.example.App"]?["pinned"] as? Bool, true)
        let maintenance = try world.engineA.maintain(now: world.now)
        XCTAssertTrue(maintenance.trashed.isEmpty)
        XCTAssertTrue(maintenance.purged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("images/\(first.manifest.imageId).dmg").path))

        let otherVersion = try world.engineB.publish(world.request(version: "2.0", build: "20", arch: ["arm64"], hash: world.hash), imageFile: try world.imageFile("version-two"), now: world.now)
        XCTAssertFalse(otherVersion.reused)
        XCTAssertNotEqual(otherVersion.manifest.imageId, first.manifest.imageId)
        let otherArch = try world.engineA.publish(world.request(version: "1.0", build: "10", arch: ["x86_64"], hash: world.hash), imageFile: try world.imageFile("intel"), now: world.now)
        XCTAssertFalse(otherArch.reused)
        XCTAssertNotEqual(otherArch.manifest.imageId, first.manifest.imageId)
        let originalManifest = try Data(contentsOf: world.repo.appendingPathComponent("manifests/\(first.manifest.imageId).json"))
        XCTAssertThrowsError(try WriteOnce.put(backend: try LocalFolderBackend(root: world.repo), path: "manifests/\(first.manifest.imageId).json", data: Data("nope".utf8)))
        XCTAssertEqual(try Data(contentsOf: world.repo.appendingPathComponent("manifests/\(first.manifest.imageId).json")), originalManifest)
    }

    func testStubRefusesAnotherVersionAndGCRespectsDevices() throws {
        let world = try World()
        defer { world.cleanup() }
        let shared = try world.engineA.publish(world.request(version: "1.0", build: "10", arch: ["arm64"], hash: world.hash, mode: .restore), imageFile: try world.imageFile("restore"), now: world.now)
        let newer = try world.engineB.publish(world.request(version: "2.0", build: "20", arch: ["arm64"], hash: world.hash), imageFile: try world.imageFile("newer"), now: world.now)
        XCTAssertThrowsError(try world.engineA.launch(newer.manifest)) { error in
            let message = (error as? IsenoughError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Refusing to launch"))
            XCTAssertTrue(message.contains(shared.manifest.imageId))
            XCTAssertTrue(message.contains("2.0"))
        }
        let recorded = try world.engineA.ownDeviceRecord()
        if case .refused(let message) = StubLaunch.check(record: recorded, manifest: newer.manifest) {
            XCTAssertTrue(message.contains("different version or architecture"))
        } else {
            XCTFail("expected a refusal")
        }

        XCTAssertThrowsError(try world.engineA.forgetDevice(id: world.deviceId(world.engineA), confirmed: false)) { error in
            XCTAssertTrue(((error as? IsenoughError)?.errorDescription ?? "").contains("--yes"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("devices/\(world.deviceId(world.engineA)).json").path))
        try world.engineA.forgetDevice(id: world.deviceId(world.engineA), confirmed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("devices/\(world.deviceId(world.engineA)).json").path))
        let trashed = try world.engineB.maintain(now: world.now.addingTimeInterval(60))
        XCTAssertFalse(trashed.trashed.contains(newer.manifest.imageId))
        XCTAssertTrue(trashed.trashed.contains(shared.manifest.imageId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("images/\(shared.manifest.imageId).dmg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("trash/images/\(shared.manifest.imageId).dmg").path))

        let revived = DeviceRecord(deviceId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", hostname: "air", displayName: "Air", arch: "arm64", osVersion: "15.6", lastSeen: world.now, images: [
            DeviceImageRef(imageId: shared.manifest.imageId, bundleId: "com.example.App", version: "1.0", build: "10", architectures: ["arm64"], mode: "restore", packedAt: world.now)
        ])
        try AtomicFile.write(try revived.encode(), to: world.repo.appendingPathComponent("devices/\(revived.deviceId).json"))
        let restored = try world.engineB.maintain(now: world.now.addingTimeInterval(120))
        XCTAssertTrue(restored.restored.contains(shared.manifest.imageId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("images/\(shared.manifest.imageId).dmg").path))

        try world.engineB.forgetDevice(id: revived.deviceId, confirmed: true)
        _ = try world.engineB.maintain(now: world.now.addingTimeInterval(180))
        try replaceTrashDate(world.repo, imageId: shared.manifest.imageId, date: world.now.addingTimeInterval(-8 * 24 * 60 * 60))
        let purged = try world.engineB.maintain(now: world.now.addingTimeInterval(200))
        XCTAssertTrue(purged.purged.contains(shared.manifest.imageId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("trash/images/\(shared.manifest.imageId).dmg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("images/\(shared.manifest.imageId).dmg").path))
    }

    func testPlaceholderConflictAndStaleDeviceBlockDeletion() throws {
        let world = try World()
        defer { world.cleanup() }
        let published = try world.engineA.publish(world.request(version: "1.0", build: "10", arch: ["arm64"], hash: world.hash), imageFile: try world.imageFile("kept"), now: world.now)
        let stale = DeviceRecord(deviceId: "cccccccc-cccc-cccc-cccc-cccccccccccc", hostname: "old", displayName: "Old Mini", arch: "arm64", osVersion: "14.0", lastSeen: world.now.addingTimeInterval(-100 * 24 * 60 * 60), images: [
            DeviceImageRef(imageId: published.manifest.imageId, bundleId: "com.example.App", version: "1.0", build: "10", architectures: ["arm64"], mode: "mount", packedAt: world.now)
        ])
        try AtomicFile.write(try stale.encode(), to: world.repo.appendingPathComponent("devices/\(stale.deviceId).json"))
        try world.engineA.forgetDevice(id: world.deviceId(world.engineA), confirmed: true)
        let held = try world.engineB.maintain(now: world.now)
        XCTAssertTrue(held.warnings.contains { $0.contains("last seen") && $0.contains(stale.deviceId) })
        XCTAssertFalse(held.trashed.contains(published.manifest.imageId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("images/\(published.manifest.imageId).dmg").path))

        let conflict = DeviceRecord(deviceId: "dddddddd-dddd-dddd-dddd-dddddddddddd", hostname: "conflict", displayName: "Conflict", arch: "arm64", osVersion: "15.6", lastSeen: world.now, images: [
            DeviceImageRef(imageId: published.manifest.imageId, bundleId: "com.example.App", version: "1.0", build: "10", architectures: ["arm64"], mode: "mount", packedAt: world.now)
        ])
        let canonical = try Data(contentsOf: world.repo.appendingPathComponent("devices/\(stale.deviceId).json"))
        try AtomicFile.write(try conflict.encode(), to: world.repo.appendingPathComponent("devices/\(stale.deviceId) 2.json"))
        let report = world.engineB.syncReport(now: world.now)
        XCTAssertEqual(report.status, "warn")
        XCTAssertTrue(report.conflicts.contains { $0.contains(" 2.json") })
        XCTAssertEqual(try Data(contentsOf: world.repo.appendingPathComponent("devices/\(stale.deviceId).json")), canonical)
        let doctor = world.engineB.doctor(checkTimeout: 5)
        let checks = try XCTUnwrap(doctor["checks"] as? [[String: Any]])
        let conflicts = checks.first { $0["name"] as? String == "conflicts" }
        XCTAssertEqual(conflicts?["status"] as? String, "warn")
        XCTAssertTrue((conflicts?["detail"] as? String ?? "").contains("2.json"))

        try Data().write(to: world.repo.appendingPathComponent("devices/pending.json.icloud"))
        try FileManager.default.removeItem(at: world.repo.appendingPathComponent("devices/\(stale.deviceId).json"))
        try FileManager.default.removeItem(at: world.repo.appendingPathComponent("devices/\(stale.deviceId) 2.json"))
        let blocked = try world.engineB.maintain(now: world.now)
        XCTAssertTrue(blocked.warnings.contains { $0.contains("not downloaded") })
        XCTAssertFalse(blocked.trashed.contains(published.manifest.imageId))
        XCTAssertFalse(blocked.purged.contains(published.manifest.imageId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("images/\(published.manifest.imageId).dmg").path))
        XCTAssertThrowsError(try world.engineB.forgetDevice(id: "pending", confirmed: true))
    }

    func testLegacyRepoGCDeletesNothingUntilIncludeLegacy() throws {
        let world = try World()
        defer { world.cleanup() }
        let manifest = try installImage(world, bundleId: "com.legacy.App", name: "Legacy")
        let kept = try world.engineA.maintain(now: world.now)
        XCTAssertTrue(kept.trashed.isEmpty)
        XCTAssertTrue(kept.purged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent(manifest.image.file).path))
        XCTAssertTrue(kept.warnings.contains { $0.contains(manifest.imageId) && $0.contains("no owner") && $0.contains("--include-legacy") })
        let legacy = try Data(contentsOf: world.repo.appendingPathComponent(LegacyImages.path))
        XCTAssertEqual(LegacyImages.decode(legacy), [manifest.imageId])
        let listing = try world.engineA.deviceListing(now: world.now)
        XCTAssertEqual(listing.devices.map(\.deviceId), [listing.localDeviceId])
        XCTAssertTrue(listing.devices[0].images.isEmpty)
        let removed = try world.engineA.maintain(now: world.now.addingTimeInterval(10), includeLegacy: true)
        XCTAssertTrue(removed.trashed.contains(manifest.imageId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent(manifest.image.file).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent("trash/images/\(manifest.imageId).dmg").path))
    }

    func testBackfillFromStubsAndJournalsShowsSelfOnTheFirstListing() throws {
        let world = try World()
        defer { world.cleanup() }
        let stateDir = URL(fileURLWithPath: world.engineA.config.stateDir, isDirectory: true)
        let local = try LocalDeviceStore.loadOrCreate(stateDir: stateDir, suggestedName: "Air")
        let empty = DeviceRecord(deviceId: local.deviceId, hostname: "air", displayName: "Air", arch: "arm64", osVersion: "15.6", lastSeen: world.now, images: [])
        try FileManager.default.createDirectory(at: world.repo.appendingPathComponent("devices"), withIntermediateDirectories: true)
        try AtomicFile.write(try empty.encode(), to: world.repo.appendingPathComponent("devices/\(local.deviceId).json"))
        let stubbed = try installImage(world, bundleId: "com.example.Stubbed", name: "Stubbed")
        let journaled = try installImage(world, bundleId: "com.example.Journaled", name: "Journaled")
        try writeStub(URL(fileURLWithPath: world.engineA.config.stubDir).appendingPathComponent("Stubbed.app"), manifest: stubbed)
        let outside = world.root.appendingPathComponent("outside/Journaled.app")
        try writeStub(outside, manifest: journaled)
        let journal = RestoreJournal(txid: "tx-journaled", appId: journaled.bundleId, imageId: journaled.imageId, owner: ProcessOwner(pid: 1, start: 1), dest: outside.path, staging: world.root.appendingPathComponent("staging").path, imagePath: world.repo.appendingPathComponent(journaled.image.file).path, imageFile: journaled.image.file, appName: journaled.name, stubBundleId: "\(journaled.bundleId).256stub", executable: journaled.name, manifestCdhash: "cd", manifestTreeHash: world.hash, imageSha256: journaled.image.sha256)
        try JournalStore.save(journal, stateDir: world.engineA.config.stateDir)
        let listing = try world.engineA.deviceListing(now: world.now)
        XCTAssertEqual(listing.devices.count, 1)
        XCTAssertEqual(listing.localDeviceId, local.deviceId)
        let ids = Set(listing.devices[0].images.map(\.imageId))
        XCTAssertTrue(ids.contains(stubbed.imageId))
        XCTAssertTrue(ids.contains(journaled.imageId))
        let kept = try world.engineA.maintain(now: world.now)
        XCTAssertFalse(kept.trashed.contains(stubbed.imageId))
        XCTAssertFalse(kept.trashed.contains(journaled.imageId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent(stubbed.image.file).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent(journaled.image.file).path))
    }

    func testRecommendNamesOtherDevicesWhenTheImageIsAlreadyInTheRepo() throws {
        let options = RecommendOptions(minSizeBytes: 1, now: Date(timeIntervalSince1970: 1_800_000_000), repoImages: [
            RepoImagePresence(bundleId: "com.example.App", version: "1.0", build: "10", architectures: ["arm64"], imageId: "com.example.App-1.0_b10-arm64-abcdef01", devices: ["Mac mini"])
        ])
        let app = RecommendApp(path: "/Applications/Example.app", name: "Example", bundleId: "com.example.App", sizeBytes: 200 * 1024 * 1024, version: "1.0", build: "10", architectures: ["arm64"])
        let report = RecommendRanking.rank([app], options: options)
        let item = try XCTUnwrap(report.recommendations.first)
        XCTAssertTrue(item.alreadyInRepo)
        XCTAssertEqual(item.otherDevices, ["Mac mini"])
        XCTAssertTrue(item.reason.contains("already in repo, packing is instant, no upload"))
        XCTAssertTrue(item.reason.contains("Mac mini"))
        XCTAssertTrue(report.text().contains("already in repo, packing is instant, no upload"))
    }

    private func bundle(_ url: URL, receipt: Data, body: Data = Data("binary".utf8)) throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.App", "CFBundleExecutable": "App", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "10"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try body.write(to: macOS.appendingPathComponent("App"))
        try receipt.write(to: url.appendingPathComponent("Contents/_MASReceipt/receipt"))
        return url
    }

    private func replaceTrashDate(_ repo: URL, imageId: String, date: Date) throws {
        let url = repo.appendingPathComponent("trash/meta/\(imageId).json")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let object: [String: Any] = ["schema": "trash/1", "imageId": imageId, "trashedAt": formatter.string(from: date)]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func installImage(_ world: World, bundleId: String, name: String) throws -> ImageManifest {
        let bytes = Data(name.utf8)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: SHA256Digest.hex(bytes), size: UInt64(bytes.count), volumeName: name, appPathInVolume: "\(name).app")
        let manifest = ImageManifest(bundleId: bundleId, name: name, version: "1.0", image: image, app: .init(originalPath: "/Applications/\(name).app", executable: name, documentTypes: [], urlTypes: []), mode: .mount, createdAt: world.now, build: "1", architectures: ["arm64"])
        try FileManager.default.createDirectory(at: world.repo.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: world.repo.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try bytes.write(to: world.repo.appendingPathComponent(manifest.image.file))
        try manifest.encode().write(to: world.repo.appendingPathComponent("manifests/\(manifest.imageId).json"))
        return manifest
    }

    private func writeStub(_ url: URL, manifest: ImageManifest) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "\(manifest.bundleId).256stub", "CFBundleExecutable": "isenough-stub", "CFBundleName": manifest.name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let stub: [String: Any] = ["schema": "stub/1", "appId": manifest.bundleId, "imageId": manifest.imageId]
        try JSONSerialization.data(withJSONObject: stub).write(to: url.appendingPathComponent("Contents/Resources/stub.json"))
        try manifest.encode().write(to: url.appendingPathComponent("Contents/Resources/manifest.json"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("isenough-mm-\(UUID().uuidString)")
    }

    private struct World {
        var root: URL
        var repo: URL
        var engineA: IsenoughEngine
        var engineB: IsenoughEngine
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var hash = String(repeating: "ab", count: 32)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-mm-\(UUID().uuidString)")
            repo = root.appendingPathComponent("repo")
            engineA = try Self.make(root: root, repo: repo, name: "a", facts: DeviceFacts(hostname: "mini", arch: "arm64", osVersion: "15.6"))
            engineB = try Self.make(root: root, repo: repo, name: "b", facts: DeviceFacts(hostname: "air", arch: "arm64", osVersion: "15.6"))
            try engineA.initialize()
            try engineB.initialize()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func request(version: String, build: String, arch: [String], hash: String, mode: ImageManifest.Mode = .mount) -> PublishRequest {
            PublishRequest(name: "Example", identity: ImageIdentity(bundleId: "com.example.App", version: version, build: build, architectures: arch, treeHash: hash), mode: mode, executable: "Example", originalPath: "/Applications/Example.app", cdhash: "cd", postImageTreeHash: hash, volumeName: "Example", appPathInVolume: "Example.app")
        }

        func imageFile(_ name: String) throws -> URL {
            let url = root.appendingPathComponent("\(name).dmg")
            try Data(name.utf8).write(to: url)
            return url
        }

        func deviceId(_ engine: IsenoughEngine) -> String {
            LocalDeviceStore.load(stateDir: URL(fileURLWithPath: engine.config.stateDir))?.deviceId ?? ""
        }

        private static func make(root: URL, repo: URL, name: String, facts: DeviceFacts) throws -> IsenoughEngine {
            let config = RuntimeConfig(
                repoPath: repo.path,
                cacheDir: root.appendingPathComponent("cache-\(name)").path,
                stateDir: root.appendingPathComponent("state-\(name)").path,
                mountRoot: root.appendingPathComponent("mnt-\(name)").path,
                stubDir: root.appendingPathComponent("apps-\(name)").path
            )
            var engine = IsenoughEngine(config: config, secrets: MemorySecretStore())
            engine.deviceFactsOverride = facts
            engine.stubRootsOverride = [URL(fileURLWithPath: config.stubDir, isDirectory: true)]
            return engine
        }
    }
}
