import XCTest
import Foundation
@testable import IsenoughCore
@testable import IsenoughEngine
import IsenoughStubSupport

/// Stub claims are scoped to the repo that packed them (`repoId` in `stub.json`).
final class StubRepoIdentityTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-stubid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// One Mac using `repo`. `apps` is that Mac's Applications folder, shared by
    /// every engine in a test the way `/Applications` is shared on a real Mac.
    private func makeEngine(mac: String, repo: String, apps: URL? = nil) throws -> IsenoughEngine {
        let macRoot = root.appendingPathComponent(mac)
        let config = RuntimeConfig(
            repoPath: root.appendingPathComponent(repo).path,
            cacheDir: macRoot.appendingPathComponent("cache-\(repo)").path,
            stateDir: macRoot.appendingPathComponent("state-\(repo)").path,
            mountRoot: macRoot.appendingPathComponent("mnt").path,
            stubDir: (apps ?? macRoot.appendingPathComponent("apps")).path
        )
        var engine = IsenoughEngine(config: config, secrets: MemorySecretStore())
        engine.deviceFactsOverride = DeviceFacts(hostname: mac, arch: "arm64", osVersion: "15.6")
        engine.stubRootsOverride = [URL(fileURLWithPath: config.stubDir, isDirectory: true)]
        try engine.initialize()
        return engine
    }

    private func publish(_ engine: IsenoughEngine, bundleId: String, name: String, hash: String) throws -> ImageManifest {
        let request = PublishRequest(name: name, identity: ImageIdentity(bundleId: bundleId, version: "1.0", build: "1", architectures: ["arm64"], treeHash: String(repeating: hash, count: 32)), mode: .mount, executable: name, originalPath: root.appendingPathComponent("Applications/\(name).app").path, cdhash: "cd", postImageTreeHash: String(repeating: hash, count: 32), volumeName: name, appPathInVolume: "\(name).app")
        let image = root.appendingPathComponent("\(UUID().uuidString).dmg")
        try Data(name.utf8).write(to: image)
        return try engine.publish(request, imageFile: image, now: now).manifest
    }

    @discardableResult
    private func writeStub(in apps: URL, name: String, manifest: ImageManifest, repoId: String?, embed: Bool = true) throws -> URL {
        let url = apps.appendingPathComponent("\(name).app")
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "\(manifest.bundleId).256stub", "CFBundleExecutable": "isenough-stub", "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        #if os(macOS)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/isenough-stub"))
        #endif
        var stub: [String: Any] = ["schema": "stub/1", "appId": manifest.bundleId, "imageId": manifest.imageId, "isenoughPath": "/old/isenough", "stubVersion": 1]
        if let repoId { stub["repoId"] = repoId }
        try JSONSerialization.data(withJSONObject: stub).write(to: url.appendingPathComponent("Contents/Resources/stub.json"))
        if embed { try manifest.encode().write(to: url.appendingPathComponent("Contents/Resources/manifest.json")) }
        return url
    }

    private func record(_ engine: IsenoughEngine) throws -> DeviceRecord {
        let id = try XCTUnwrap(LocalDeviceStore.load(stateDir: URL(fileURLWithPath: engine.config.stateDir))).deviceId
        return try DeviceRecord.decode(Data(contentsOf: URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("devices/\(id).json")))
    }

    private func repoJSON(_ engine: IsenoughEngine) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("repo.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func stubJSON(_ bundle: URL) throws -> [String: Any] {
        try XCTUnwrap(StubIdentity.readObject(bundle: bundle))
    }

    // MARK: - StubIdentity rules

    func testStubIdentityOwnershipRules() {
        let mine = StubIdentity(appId: "a", imageId: "i", repoId: "R1")
        let theirs = StubIdentity(appId: "a", imageId: "i", repoId: "R2")
        let legacy = StubIdentity(appId: "a", imageId: "i", repoId: nil)
        XCTAssertTrue(mine.belongs(toRepo: "R1", imageInRepo: false))
        XCTAssertTrue(mine.belongs(toRepo: "R1", imageInRepo: true))
        XCTAssertFalse(theirs.belongs(toRepo: "R1", imageInRepo: true), "a stub naming another repo is never claimed")
        XCTAssertTrue(legacy.belongs(toRepo: "R1", imageInRepo: true))
        XCTAssertFalse(legacy.belongs(toRepo: "R1", imageInRepo: false))
        // Repo id unknown: only the manifest test applies.
        XCTAssertTrue(theirs.belongs(toRepo: nil, imageInRepo: true))
        XCTAssertFalse(theirs.belongs(toRepo: nil, imageInRepo: false))
        XCTAssertTrue(theirs.isForeign(toRepo: "R1"))
        XCTAssertFalse(legacy.isForeign(toRepo: "R1"))
        XCTAssertFalse(mine.isForeign(toRepo: nil))
        XCTAssertTrue(StubIdentity(object: ["repoId": "", "imageId": "x"]).isLegacy, "an empty repoId is legacy")
    }

    func testStubInfoCarriesRepoIdOnlyWhenKnown() throws {
        let engine = try makeEngine(mac: "mini", repo: "repo")
        let manifest = try publish(engine, bundleId: "com.example.Info", name: "Info", hash: "11")
        let scoped = StubGenerator.stubInfo(manifest: manifest, cliPath: "/x/isenough", repoId: "R1")
        XCTAssertEqual(scoped["repoId"] as? String, "R1")
        XCTAssertEqual(scoped["imageId"] as? String, manifest.imageId)
        XCTAssertNil(StubGenerator.stubInfo(manifest: manifest, cliPath: "/x/isenough")["repoId"])
        XCTAssertNil(StubGenerator.stubInfo(manifest: manifest, cliPath: "/x/isenough", repoId: "")["repoId"])
    }

    // MARK: - repo.json

    func testInitWritesRepoIdAndTwoMacsShareIt() throws {
        let a = try makeEngine(mac: "mac-a", repo: "shared")
        let b = try makeEngine(mac: "mac-b", repo: "shared")
        let idA = try XCTUnwrap(a.repoIdentity())
        let idB = try XCTUnwrap(b.repoIdentity())
        XCTAssertEqual(idA, idB, "two Macs on the same repo see the same repoId")
        XCTAssertEqual(try repoJSON(a)["repoId"] as? String, idA)
        XCTAssertEqual(try repoJSON(a)["schema"] as? String, "repo/1")

        let other = try makeEngine(mac: "mac-a", repo: "other")
        XCTAssertNotEqual(other.repoIdentity(), idA)
    }

    func testLegacyRepoJSONGetsRepoIdOnlyFromExplicitCommandsAndKeepsOtherKeys() throws {
        let engine = try makeEngine(mac: "mini", repo: "legacy")
        let url = URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("repo.json")
        let legacy = Data(#"{"schema":"repo/1","layoutVersion":1,"note":"keep me"}"#.utf8)
        try legacy.write(to: url)
        XCTAssertNil(RepoIdentity.read(try engine.repo))
        // Routine commands only read, so two Macs never race to mint ids.
        try engine.ensureDevice(now: now)
        _ = try publish(engine, bundleId: "com.example.Routine", name: "Routine", hash: "01")
        XCTAssertNil(engine.repoIdentity())
        XCTAssertEqual(try Data(contentsOf: url), legacy)

        let id = try XCTUnwrap(try engine.ensureRepoIdentity())
        let object = try repoJSON(engine)
        XCTAssertEqual(object["repoId"] as? String, id)
        XCTAssertEqual(object["note"] as? String, "keep me")
        XCTAssertEqual(object["layoutVersion"] as? Int, 1)
        // Stable after that.
        XCTAssertEqual(try engine.ensureRepoIdentity(), id)
        try engine.initialize()
        XCTAssertEqual(engine.repoIdentity(), id)
    }

    /// An evicted iCloud `repo.json` shows up only as `.repo.json.icloud`.
    func testICloudPlaceholderRepoJSONIsNeverReplaced() throws {
        let engine = try makeEngine(mac: "mini", repo: "evicted")
        let repo = URL(fileURLWithPath: engine.config.repoPath)
        XCTAssertNotNil(engine.repoIdentity())
        try FileManager.default.removeItem(at: repo.appendingPathComponent("repo.json"))
        let placeholder = repo.appendingPathComponent(".repo.json.icloud")
        try Data("placeholder".utf8).write(to: placeholder)
        XCTAssertNil(try engine.ensureRepoIdentity())
        try engine.initialize()
        try engine.ensureDevice(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("repo.json").path), "no new repo.json beside the placeholder")
        XCTAssertNil(engine.repoIdentity())
        XCTAssertEqual(try Data(contentsOf: placeholder), Data("placeholder".utf8))
    }

    /// `repo.json` missing while the repo already holds manifests: it may not have
    /// synced yet, so no new id is minted.
    func testMissingRepoJSONInARepoWithContentIsNotRecreated() throws {
        let engine = try makeEngine(mac: "mini", repo: "unsynced")
        _ = try publish(engine, bundleId: "com.example.Unsynced", name: "Unsynced", hash: "02")
        let url = URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("repo.json")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(try engine.ensureRepoIdentity())
        try engine.initialize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnreadableRepoJSONIsNeverOverwritten() throws {
        let engine = try makeEngine(mac: "mini", repo: "broken")
        let url = URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("repo.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(engine.repoIdentity())
        XCTAssertNil(try engine.ensureRepoIdentity())
        try engine.ensureDevice(now: now)
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    }

    // MARK: - Claims

    /// The reported bug: an isolated test repo scanning the user's real
    /// Applications folder claimed stubs (Keynote, Numbers, ...) of the real repo.
    func testForeignRepoStubsAreNotClaimed() throws {
        let apps = root.appendingPathComponent("Applications")
        let real = try makeEngine(mac: "mini", repo: "real", apps: apps)
        let realId = try XCTUnwrap(real.repoIdentity())
        let keynote = try publish(real, bundleId: "com.apple.iWork.Keynote", name: "Keynote", hash: "aa")
        let numbers = try publish(real, bundleId: "com.apple.iWork.Numbers", name: "Numbers", hash: "bb")
        try writeStub(in: apps, name: "Keynote", manifest: keynote, repoId: realId)
        // A legacy stub of the real repo (written before repoId existed).
        try writeStub(in: apps, name: "Numbers", manifest: numbers, repoId: nil)

        let isolated = try makeEngine(mac: "mini", repo: "isolated", apps: apps)
        try isolated.ensureDevice(now: now)
        XCTAssertEqual(try record(isolated).images, [], "the isolated repo claims none of the real repo's stubs")

        // The real repo still claims both.
        try real.ensureDevice(now: now)
        XCTAssertEqual(Set(try record(real).images.map(\.imageId)), [keynote.imageId, numbers.imageId])
    }

    func testLegacyStubIsClaimedOnlyWhenItsManifestIsInThisRepo() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let elsewhere = try makeEngine(mac: "mini", repo: "elsewhere", apps: root.appendingPathComponent("elsewhere-apps"))
        let ours = try publish(engine, bundleId: "com.example.Ours", name: "Ours", hash: "cc")
        let stray = try publish(elsewhere, bundleId: "com.example.Stray", name: "Stray", hash: "dd")
        // Unregister `ours` so only the stub can bring it back.
        try engine.unregister(bundleId: ours.bundleId, imageId: ours.imageId, now: now)
        XCTAssertEqual(try record(engine).images, [])

        try writeStub(in: apps, name: "Ours", manifest: ours, repoId: nil, embed: false)
        try writeStub(in: apps, name: "Stray", manifest: stray, repoId: nil)
        try engine.ensureDevice(now: now)
        XCTAssertEqual(try record(engine).images.map(\.imageId), [ours.imageId])
    }

    func testOwnStubIsClaimedEvenWithoutAManifestHere() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let id = try XCTUnwrap(engine.repoIdentity())
        let manifest = try publish(engine, bundleId: "com.example.Gone", name: "Gone", hash: "ee")
        try engine.unregister(bundleId: manifest.bundleId, imageId: manifest.imageId, now: now)
        // The manifest is not readable (iCloud placeholder, partial sync), but the
        // stub names this repo, so its image stays protected.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("manifests/\(manifest.imageId).json"))
        try writeStub(in: apps, name: "Gone", manifest: manifest, repoId: id, embed: false)
        try engine.ensureDevice(now: now)
        XCTAssertEqual(try record(engine).images.map(\.imageId), [manifest.imageId])
    }

    func testTwoMacsOnOneRepoBothClaimStubsStampedByEither() throws {
        let a = try makeEngine(mac: "mac-a", repo: "shared")
        let b = try makeEngine(mac: "mac-b", repo: "shared")
        let id = try XCTUnwrap(a.repoIdentity())
        let manifest = try publish(a, bundleId: "com.example.Shared", name: "Shared", hash: "ff")
        // Mac B installed a stub for the same image (for example a later rebuild).
        try FileManager.default.removeItem(at: URL(fileURLWithPath: a.config.repoPath).appendingPathComponent("manifests/\(manifest.imageId).json"))
        try writeStub(in: URL(fileURLWithPath: b.config.stubDir), name: "Shared", manifest: manifest, repoId: id, embed: false)
        try b.ensureDevice(now: now)
        XCTAssertEqual(try record(b).images.map(\.imageId), [manifest.imageId])
        XCTAssertEqual(try record(a).images.map(\.imageId), [manifest.imageId])
    }

    func testOlderEngineForeignClaimsArePrunedFromTheDeviceFile() throws {
        let apps = root.appendingPathComponent("Applications")
        let real = try makeEngine(mac: "mini", repo: "real", apps: apps)
        let pages = try publish(real, bundleId: "com.apple.iWork.Pages", name: "Pages", hash: "12")
        let stub = try writeStub(in: apps, name: "Pages", manifest: pages, repoId: nil)

        let isolated = try makeEngine(mac: "mini", repo: "isolated", apps: apps)
        let ours = try publish(isolated, bundleId: "com.example.Mine", name: "Mine", hash: "34")
        // What an older engine wrote: a claim for the real repo's stub.
        var contaminated = try record(isolated)
        contaminated.images.append(DeviceImageRef(imageId: pages.imageId, bundleId: pages.bundleId, version: pages.version, build: pages.build, architectures: pages.architectures, mode: "mount", packedAt: now, installPath: stub.path))
        let data = try contaminated.encode()
        try data.write(to: URL(fileURLWithPath: isolated.config.repoPath).appendingPathComponent("devices/\(contaminated.deviceId).json"))
        try data.write(to: URL(fileURLWithPath: isolated.config.stateDir).appendingPathComponent("device-record.json"))

        try isolated.ensureDevice(now: now)
        XCTAssertEqual(try record(isolated).images.map(\.imageId), [ours.imageId])
        // The real repo's own record is untouched.
        try real.ensureDevice(now: now)
        XCTAssertEqual(try record(real).images.map(\.imageId), [pages.imageId])
    }

    func testRefOfThisRepoIsNotPrunedEvenIfTheStubAtItsPathIsForeign() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let manifest = try publish(engine, bundleId: "com.example.Kept", name: "Kept", hash: "56")
        // A foreign stub now sits where this repo's ref points, but this repo
        // still has the image, so the ref keeps its GC protection.
        var ref = try XCTUnwrap(record(engine).images.first)
        ref.installPath = try writeStub(in: apps, name: "Kept", manifest: manifest, repoId: "SOMEONE-ELSE").path
        var updated = try record(engine)
        updated.images = [ref]
        let data = try updated.encode()
        try data.write(to: URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("devices/\(updated.deviceId).json"))
        try data.write(to: URL(fileURLWithPath: engine.config.stateDir).appendingPathComponent("device-record.json"))
        try engine.ensureDevice(now: now)
        XCTAssertEqual(try record(engine).images.map(\.imageId), [manifest.imageId])
    }

    // MARK: - Trash

    /// What another Mac's `gc` does before this Mac's device file has synced.
    private func trashFromAnotherMac(_ engine: IsenoughEngine, imageId: String) throws {
        let repo = URL(fileURLWithPath: engine.config.repoPath)
        let fm = FileManager.default
        for dir in ["trash/images", "trash/manifests", "trash/meta"] {
            try fm.createDirectory(at: repo.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fm.moveItem(at: repo.appendingPathComponent("images/\(imageId).dmg"), to: repo.appendingPathComponent("trash/images/\(imageId).dmg"))
        try fm.moveItem(at: repo.appendingPathComponent("manifests/\(imageId).json"), to: repo.appendingPathComponent("trash/manifests/\(imageId).json"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let meta: [String: Any] = ["schema": "trash/1", "imageId": imageId, "trashedAt": formatter.string(from: now)]
        try JSONSerialization.data(withJSONObject: meta).write(to: repo.appendingPathComponent("trash/meta/\(imageId).json"))
    }

    func testTrashedImageOfALegacyStubKeepsItsRefAndIsRestoredByGC() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let manifest = try publish(engine, bundleId: "com.example.Trashed", name: "Trashed", hash: "61")
        // A stub packed before repoId existed sits where the ref points.
        let stub = try writeStub(in: apps, name: "Trashed", manifest: manifest, repoId: nil)
        XCTAssertEqual(try record(engine).images.first?.installPath, stub.path)
        try trashFromAnotherMac(engine, imageId: manifest.imageId)

        try engine.ensureDevice(now: now)
        XCTAssertEqual(try record(engine).images.map(\.imageId), [manifest.imageId], "a trashed image is still this repo's; its ref is not expelled")
        let report = try engine.maintain(now: now.addingTimeInterval(60))
        XCTAssertEqual(report.restored, [manifest.imageId])
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("images/\(manifest.imageId).dmg").path))
    }

    func testLegacyStubOfATrashedImageIsStillClaimed() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let manifest = try publish(engine, bundleId: "com.example.Claimed", name: "Claimed", hash: "62")
        try engine.unregister(bundleId: manifest.bundleId, imageId: manifest.imageId, now: now)
        try trashFromAnotherMac(engine, imageId: manifest.imageId)
        try writeStub(in: apps, name: "Claimed", manifest: manifest, repoId: nil, embed: false)
        try engine.ensureDevice(now: now)
        XCTAssertEqual(try record(engine).images.map(\.imageId), [manifest.imageId])
    }

    // MARK: - Migration

    #if os(macOS)
    func testRefreshAllStampsLegacyStubsOfThisRepoAndLeavesOthersAlone() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let other = try makeEngine(mac: "mini", repo: "other", apps: root.appendingPathComponent("other-apps"))
        let id = try XCTUnwrap(engine.repoIdentity())
        let otherId = try XCTUnwrap(other.repoIdentity())
        let ours = try publish(engine, bundleId: "com.example.Legacy", name: "Legacy", hash: "78")
        let theirs = try publish(other, bundleId: "com.example.Theirs", name: "Theirs", hash: "9a")
        let strayManifest = try publish(other, bundleId: "com.example.Stray", name: "Stray", hash: "bc")
        let legacy = try writeStub(in: apps, name: "Legacy", manifest: ours, repoId: nil)
        let foreign = try writeStub(in: apps, name: "Theirs", manifest: theirs, repoId: otherId)
        let stray = try writeStub(in: apps, name: "Stray", manifest: strayManifest, repoId: nil)

        let report = try engine.refreshOwnedStubs(appId: nil)
        XCTAssertEqual(report.updated, [legacy.path])
        XCTAssertEqual(Set(report.foreign), [foreign.path, stray.path])
        XCTAssertEqual(try stubJSON(legacy)["repoId"] as? String, id)
        XCTAssertEqual(try stubJSON(legacy)["imageId"] as? String, ours.imageId)
        XCTAssertNotEqual(try stubJSON(legacy)["isenoughPath"] as? String, "/old/isenough")
        XCTAssertEqual(try stubJSON(foreign)["repoId"] as? String, otherId)
        XCTAssertEqual(try stubJSON(foreign)["isenoughPath"] as? String, "/old/isenough")
        XCTAssertNil(try stubJSON(stray)["repoId"])

        // `stub refresh --app` stamps too, and never rewrites another repo's id.
        try writeStub(in: apps, name: "Legacy", manifest: ours, repoId: nil)
        _ = try engine.refreshStubs(appId: ours.bundleId)
        XCTAssertEqual(try stubJSON(legacy)["repoId"] as? String, id)
    }

    /// `repo.json` was recreated (or two Macs minted different ids) after stubs
    /// were stamped. Those stubs are not claimed, but gc keeps their images and
    /// `--adopt` restamps them.
    func testStubsStampedWithAnOldRepoIdAreKeptByGCAndCanBeAdopted() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let oldId = try XCTUnwrap(engine.repoIdentity())
        let manifest = try publish(engine, bundleId: "com.example.Drift", name: "Drift", hash: "63")
        let stub = try writeStub(in: apps, name: "Drift", manifest: manifest, repoId: oldId)
        var object = try repoJSON(engine)
        object["repoId"] = "NEW-ID"
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("repo.json"))
        try engine.unregister(bundleId: manifest.bundleId, imageId: manifest.imageId, now: now)

        try engine.ensureDevice(now: now)
        XCTAssertEqual(try record(engine).images, [])
        let gc = try engine.maintain(now: now.addingTimeInterval(60))
        XCTAssertFalse(gc.trashed.contains(manifest.imageId))
        XCTAssertTrue(gc.kept.contains(manifest.imageId))
        XCTAssertTrue(gc.warnings.contains { $0.contains(manifest.imageId) && $0.contains("--adopt") })

        let report = try engine.refreshOwnedStubs(appId: nil)
        XCTAssertEqual(report.mismatched, [stub.path])
        XCTAssertEqual(report.foreign, [])
        XCTAssertEqual(try stubJSON(stub)["repoId"] as? String, oldId)

        let adopted = try engine.refreshOwnedStubs(appId: nil, adopt: true)
        XCTAssertEqual(adopted.updated, [stub.path])
        XCTAssertEqual(try stubJSON(stub)["repoId"] as? String, "NEW-ID")
        XCTAssertEqual(try record(engine).images.map(\.imageId), [manifest.imageId])
    }

    func testRefreshAppLeavesAnotherReposStubAlone() throws {
        let apps = root.appendingPathComponent("Applications")
        let engine = try makeEngine(mac: "mini", repo: "repo", apps: apps)
        let manifest = try publish(engine, bundleId: "com.example.Other", name: "Other", hash: "64")
        let stub = try writeStub(in: apps, name: "Other", manifest: manifest, repoId: "SOMEONE-ELSE")
        // The image is in this repo, so it is mismatched rather than foreign.
        let report = try engine.refreshStubs(appId: manifest.bundleId)
        XCTAssertEqual(report.updated, [])
        XCTAssertEqual(report.mismatched, [stub.path])
        XCTAssertEqual(try stubJSON(stub)["isenoughPath"] as? String, "/old/isenough")

        let other = try makeEngine(mac: "mini", repo: "other", apps: root.appendingPathComponent("other-apps"))
        let theirs = try publish(other, bundleId: "com.example.Theirs", name: "Theirs", hash: "65")
        let foreign = try writeStub(in: apps, name: "Theirs", manifest: theirs, repoId: other.repoIdentity())
        let second = try engine.refreshStubs(appId: theirs.bundleId)
        XCTAssertEqual(second.foreign, [foreign.path])
        XCTAssertEqual(try stubJSON(foreign)["isenoughPath"] as? String, "/old/isenough")
    }

    func testRecoveryRebuiltStubCarriesTheReplacedStubsRepoId() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        // The stub being replaced names its repo.
        let id = "REPO-OF-THE-STUB"
        let stubJSONURL = world.dest.appendingPathComponent("Contents/Resources/stub.json")
        try FileManager.default.createDirectory(at: stubJSONURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["schema": "stub/1", "appId": world.bundleID, "repoId": id]).write(to: stubJSONURL)
        var journal = try world.strandWithoutParkedStub()
        XCTAssertEqual(journal.stubRepoId, id, "the journal keeps the replaced stub's repo")
        let launcher = try world.fakeLauncher()
        // The configured repo changed before recovery; the rebuilt stub still names the journal's repo.
        var switched = world.engine.config
        switched.repoPath = root.appendingPathComponent("elsewhere").path
        try StubRebuilder.write(at: world.dest, journal: journal, config: switched, environment: ["ISENOUGH_STUB_BINARY": launcher.path], cli: URL(fileURLWithPath: "/nonexistent/isenough"))
        XCTAssertEqual(try stubJSON(world.dest)["repoId"] as? String, id)

        // Unknown repo (legacy stub, older journal): a legacy stub, not a guess.
        try FileManager.default.removeItem(at: world.dest)
        journal.stubRepoId = nil
        try StubRebuilder.write(at: world.dest, journal: journal, config: world.engine.config, environment: ["ISENOUGH_STUB_BINARY": launcher.path], cli: URL(fileURLWithPath: "/nonexistent/isenough"))
        XCTAssertNil(try stubJSON(world.dest)["repoId"])
    }
    #endif
}
