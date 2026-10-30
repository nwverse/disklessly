import XCTest
import Foundation
@testable import IsenoughCore
@testable import IsenoughEngine

final class DeviceImageRefTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var engine: IsenoughEngine!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let bundleId = "com.example.Twin"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-refs-\(UUID().uuidString)")
        repo = root.appendingPathComponent("repo")
        let config = RuntimeConfig(
            repoPath: repo.path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mnt").path,
            stubDir: root.appendingPathComponent("apps").path
        )
        engine = IsenoughEngine(config: config, secrets: MemorySecretStore())
        engine.deviceFactsOverride = DeviceFacts(hostname: "mini", arch: "arm64", osVersion: "15.6")
        engine.stubRootsOverride = [URL(fileURLWithPath: config.stubDir, isDirectory: true)]
        try engine.initialize()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(version: String, hash: String, originalPath: String) -> PublishRequest {
        PublishRequest(name: "Twin", identity: ImageIdentity(bundleId: bundleId, version: version, build: version, architectures: ["arm64"], treeHash: hash), mode: .mount, executable: "Twin", originalPath: originalPath, cdhash: "cd", postImageTreeHash: hash, volumeName: "Twin", appPathInVolume: "Twin.app")
    }

    private func imageFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).dmg")
        try Data(name.utf8).write(to: url)
        return url
    }

    private func ownRecord() throws -> DeviceRecord {
        let id = LocalDeviceStore.load(stateDir: URL(fileURLWithPath: engine.config.stateDir))!.deviceId
        return try DeviceRecord.decode(Data(contentsOf: repo.appendingPathComponent("devices/\(id).json")))
    }

    func testTwoImagesWithOneBundleIdKeepBothRefsAndGCKeepsBoth() throws {
        let first = try engine.publish(request(version: "1.0", hash: String(repeating: "aa", count: 32), originalPath: "/Applications/Twin.app"), imageFile: try imageFile("one"), now: now)
        let second = try engine.publish(request(version: "2.0", hash: String(repeating: "bb", count: 32), originalPath: "/Users/me/Applications/Twin.app"), imageFile: try imageFile("two"), now: now.addingTimeInterval(10))
        XCTAssertNotEqual(first.manifest.imageId, second.manifest.imageId)

        let record = try ownRecord()
        XCTAssertEqual(Set(record.images.map(\.imageId)), [first.manifest.imageId, second.manifest.imageId])
        XCTAssertEqual(record.images(forBundleId: bundleId).map(\.imageId), [second.manifest.imageId, first.manifest.imageId])
        XCTAssertEqual(record.currentImage(bundleId: bundleId)?.imageId, second.manifest.imageId)

        let report = try engine.gcDryRun(now: now.addingTimeInterval(60))
        XCTAssertFalse(report.trash.contains(first.manifest.imageId))
        XCTAssertFalse(report.trash.contains(second.manifest.imageId))

        // Each stub launches its own image.
        XCTAssertEqual(StubLaunch.check(record: record, manifest: first.manifest), .allowed)
        XCTAssertEqual(StubLaunch.check(record: record, manifest: second.manifest), .allowed)

        // A later device write (no explicit change) keeps both.
        try engine.ensureDevice(now: now.addingTimeInterval(20))
        XCTAssertEqual(Set(try ownRecord().images.map(\.imageId)), [first.manifest.imageId, second.manifest.imageId])

        // Unregistering one image leaves the other.
        try engine.unregister(bundleId: bundleId, imageId: first.manifest.imageId, now: now.addingTimeInterval(30))
        XCTAssertEqual(try ownRecord().images.map(\.imageId), [second.manifest.imageId])
    }

    func testRepackAtTheSamePathReplacesOnlyThatRef() throws {
        let path = "/Applications/Twin.app"
        let old = try engine.publish(request(version: "1.0", hash: String(repeating: "aa", count: 32), originalPath: path), imageFile: try imageFile("old"), now: now)
        let other = try engine.publish(request(version: "1.5", hash: String(repeating: "cc", count: 32), originalPath: "/Volumes/Ext/Twin.app"), imageFile: try imageFile("other"), now: now.addingTimeInterval(5))
        let new = try engine.publish(request(version: "2.0", hash: String(repeating: "bb", count: 32), originalPath: path), imageFile: try imageFile("new"), now: now.addingTimeInterval(10))
        let ids = Set(try ownRecord().images.map(\.imageId))
        XCTAssertEqual(ids, [other.manifest.imageId, new.manifest.imageId])
        XCTAssertFalse(ids.contains(old.manifest.imageId))
    }

    func testStubOnDiskKeepsItsImageReferenced() throws {
        let a = try engine.publish(request(version: "1.0", hash: String(repeating: "aa", count: 32), originalPath: "/Applications/Twin.app"), imageFile: try imageFile("a"), now: now)
        // A stub for `a` sits in the stub dir under another name.
        let stub = URL(fileURLWithPath: engine.config.stubDir).appendingPathComponent("Twin Copy.app")
        try writeStub(stub, manifest: a.manifest)
        let b = try engine.publish(request(version: "2.0", hash: String(repeating: "bb", count: 32), originalPath: "/Applications/Twin.app"), imageFile: try imageFile("b"), now: now.addingTimeInterval(10))
        // Same install path replaced the ref, but the stub on disk claims `a` back.
        try engine.ensureDevice(now: now.addingTimeInterval(20))
        let ids = Set(try ownRecord().images.map(\.imageId))
        XCTAssertEqual(ids, [a.manifest.imageId, b.manifest.imageId])
        // A bundle-only unregister (today's unpack call) keeps the image a stub still needs.
        try engine.unregister(bundleId: bundleId, now: now.addingTimeInterval(30))
        XCTAssertEqual(try ownRecord().images.map(\.imageId), [a.manifest.imageId])
    }

    func testOldDeviceRecordWithoutImageIdStillDecodes() throws {
        let json = """
        {"schema":"device/1","deviceId":"aaaa-1111","hostname":"mini","displayName":"Mini","arch":"arm64","osVersion":"15.6","lastSeen":"2027-01-15T08:00:00Z",
         "images":[{"bundleId":"com.example.Old","version":"1.0","build":"1","architectures":["arm64"],"mode":"mount","packedAt":"2027-01-15T08:00:00Z"},
                   {"imageId":"com.example.New-1.0_b1-arm64-abcdabcd","bundleId":"com.example.New","version":"1.0","build":"1","architectures":["arm64"],"mode":"mount","packedAt":"2027-01-15T08:00:00Z"}]}
        """
        let record = try DeviceRecord.decode(Data(json.utf8))
        XCTAssertEqual(record.images.count, 2)
        XCTAssertEqual(record.images[0].imageId, "")
        XCTAssertNil(record.images[0].installPath)
        XCTAssertEqual(record.images[1].imageId, "com.example.New-1.0_b1-arm64-abcdabcd")
        let roundTrip = try DeviceRecord.decode(try record.encode())
        XCTAssertEqual(roundTrip, record)
        XCTAssertFalse(String(decoding: try record.encode(), as: UTF8.self).contains("installPath"))
    }

    private func writeStub(_ url: URL, manifest: ImageManifest) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "\(manifest.bundleId).256stub", "CFBundleExecutable": "isenough-stub", "CFBundleName": manifest.name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let stub: [String: Any] = ["schema": "stub/1", "appId": manifest.bundleId, "imageId": manifest.imageId]
        try JSONSerialization.data(withJSONObject: stub).write(to: url.appendingPathComponent("Contents/Resources/stub.json"))
        try manifest.encode().write(to: url.appendingPathComponent("Contents/Resources/manifest.json"))
    }
}
