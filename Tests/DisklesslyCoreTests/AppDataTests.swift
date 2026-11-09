import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

/// Data follows the app (v1): Application Support goes to the repo after a quit and comes
/// back before a launch, and the app is never opened without it.
final class AppDataTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    var support: URL { home.appendingPathComponent("Library/Application Support") }
    let fm = FileManager.default
    var running = false

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("disklessly-appdata-\(UUID().uuidString)")
        running = false
    }

    override func tearDown() {
        AppDataEviction.hook = nil
        try? fm.removeItem(at: root)
    }

    func makeEngine(secrets: MemorySecretStore = MemorySecretStore(), repo: URL? = nil, state: String = "state") throws -> (DisklesslyEngine, ImageManifest) {
        let repo = repo ?? root.appendingPathComponent("repo")
        var config = RuntimeConfig(repoPath: repo.path, cacheDir: root.appendingPathComponent("cache-\(state)").path, stateDir: root.appendingPathComponent(state).path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        config.minFreeBytes = 0  // the test disk may be below the default floor
        var engine = DisklesslyEngine(config: config, secrets: secrets)
        let backend = try LocalFolderBackend(root: repo)
        engine.backendOverride = backend
        engine.homeOverride = home.path
        try engine.initialize()
        let image = ImageManifest.Image(file: "images/Foo.dmg", format: "ULMO", sha256: String(repeating: "ab", count: 32), size: 3, volumeName: "Foo", appPathInVolume: "Foo.app")
        let manifest = ImageManifest(bundleId: "com.example.foo", name: "Foo", version: "1", image: image, app: .init(originalPath: root.appendingPathComponent("apps/Foo.app").path, executable: "Foo", documentTypes: [], urlTypes: []))
        try backend.put("manifests/\(manifest.imageId).json", data: try manifest.encode())
        engine.appRunningOverride = { [unowned self] _ in self.running }
        engine.offloadedOverride = { ["com.example.foo"] }
        engine.fileOpenOverride = { _, _ in false }
        return (engine, manifest)
    }

    func writeData() throws {
        let a = support.appendingPathComponent("com.example.foo")
        let b = support.appendingPathComponent("Foo/sub")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: a.appendingPathComponent("prefs.json"))
        try Data(repeating: 3, count: 200_000).write(to: b.appendingPathComponent("disk.img"))
        try fm.createSymbolicLink(atPath: b.appendingPathComponent("link").path, withDestinationPath: "disk.img")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.appendingPathComponent("prefs.json").path)
    }

    func testEnableMovesDataOutAndLaunchBringsItBackIntact() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        let before = try TreeFingerprintNoInode.of(support)
        let status = try engine.appDataEnable(manifest)
        XCTAssertEqual(status.record.state, .offloaded)
        XCTAssertEqual(status.record.generation, 1)
        XCTAssertEqual(Set(status.record.roots), ["com.example.foo", "Foo"])
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("com.example.foo").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("Foo").path))
        let objects = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("repo/data").path)
        XCTAssertEqual(objects.count, 1) // one device folder

        try engine.restore.withLock(manifest.bundleId) { try engine.appDataBeforeLaunch(manifest) }
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).state, .local)
        XCTAssertEqual(try TreeFingerprintNoInode.of(support), before)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("com.example.foo/prefs.json"), encoding: .utf8), "settings")
        let mode = try fm.attributesOfItem(atPath: support.appendingPathComponent("com.example.foo/prefs.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: support.appendingPathComponent("Foo/sub/link").path), "disk.img")
        let leftovers = (try? fm.contentsOfDirectory(atPath: support.appendingPathComponent(".disklessly-data").path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testUnchangedDataIsNotUploadedAgainAndChangedDataMakesANewGeneration() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        try engine.appDataIn(manifest)
        try engine.appDataOut(manifest, since: Date())
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).generation, 1, "unchanged: same generation")
        try engine.appDataIn(manifest)
        try Data("changed".utf8).write(to: support.appendingPathComponent("com.example.foo/prefs.json"))
        try engine.appDataOut(manifest, since: Date())
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).generation, 2)
        let dir = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("repo/data").path).first!
        let files = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("repo/data/\(dir)/com.example.foo").path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".tar.zst") }.count, 1, "the previous generation's object is removed")
        try engine.appDataIn(manifest)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("com.example.foo/prefs.json"), encoding: .utf8), "changed")
    }

    func testRunningAppKeepsItsDataAndANewLaunchCancelsAnOlderQuit() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        running = true
        let status = try engine.appDataEnable(manifest)
        XCTAssertTrue(status.record.enabled)
        XCTAssertEqual(status.record.state, .local)
        XCTAssertNotNil(status.record.lastError)
        running = false
        let since = Date().addingTimeInterval(-60)
        try engine.appDataStore.update(manifest.bundleId) { $0.launchedAt = Date() }
        XCTAssertThrowsError(try engine.appDataOut(manifest, since: since))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("com.example.foo/prefs.json").path))
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).state, .local)
    }

    func testLaunchIsRefusedWhenTheDataCannotComeBack() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        // The object disappears from the repo (offline drive, wrong repo...).
        let dir = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("repo/data").path).first!
        let folder = root.appendingPathComponent("repo/data/\(dir)/com.example.foo")
        for file in try fm.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".tar.zst") {
            try fm.removeItem(at: folder.appendingPathComponent(file))
        }
        XCTAssertThrowsError(try engine.restore.withLock(manifest.bundleId) { try engine.appDataBeforeLaunch(manifest) })
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).state, .offloaded)
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("com.example.foo").path))
    }

    func testAFolderThatAppearedMeanwhileStopsTheLaunchAndIsNotMerged() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        let intruder = support.appendingPathComponent("com.example.foo")
        try fm.createDirectory(at: intruder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: intruder.appendingPathComponent("fresh.json"))
        XCTAssertThrowsError(try engine.appDataIn(manifest))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: intruder.path), ["fresh.json"])
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("Foo").path))
    }

    func testDataOutRefusesWhenTheRepoHoldsAGenerationThisMacDidNotSee() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        try engine.appDataIn(manifest)
        try engine.appDataStore.update(manifest.bundleId) { $0.generation = 0 } // as if another copy wrote under our id
        try Data("x".utf8).write(to: support.appendingPathComponent("com.example.foo/prefs.json"))
        XCTAssertThrowsError(try engine.appDataOut(manifest, since: Date()))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("com.example.foo/prefs.json").path))
    }

    func testEncryptedWhenAnImageKeyExists() throws {
        try writeData()
        let secrets = MemorySecretStore()
        _ = try ImageKeyStore.create(secrets: secrets)
        let (engine, manifest) = try makeEngine(secrets: secrets)
        _ = try engine.appDataEnable(manifest)
        let dir = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("repo/data").path).first!
        let files = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("repo/data/\(dir)/com.example.foo").path)
        XCTAssertTrue(files.contains { $0.hasSuffix(".tar.zst.dkli") }, "\(files)")
        try engine.appDataIn(manifest)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("com.example.foo/prefs.json"), encoding: .utf8), "settings")
    }

    func testRecoveryFinishesAMoveThatCrashedAfterTheCommit() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        try engine.appDataIn(manifest)
        try Data("v2".utf8).write(to: support.appendingPathComponent("com.example.foo/prefs.json"))
        try engine.appDataOut(manifest, since: Date())
        // Simulate: manifest at generation 2 committed and roots moved aside, but the record still says local at 1.
        try engine.appDataIn(manifest)
        try engine.appDataStore.update(manifest.bundleId) { $0.generation = 2 }
        let tx = support.appendingPathComponent(".disklessly-data/com.example.foo--crash")
        try fm.createDirectory(at: tx.appendingPathComponent("aside"), withIntermediateDirectories: true)
        try Data("2".utf8).write(to: tx.appendingPathComponent("committed"))
        for name in ["com.example.foo", "Foo"] {
            try fm.moveItem(at: support.appendingPathComponent(name), to: tx.appendingPathComponent("aside/\(name)"))
        }
        try engine.appDataStore.update(manifest.bundleId) { $0.generation = 1 }
        try engine.appDataRecover(manifest.bundleId)
        let record = engine.appDataStore.record(manifest.bundleId)
        XCTAssertEqual(record.state, .offloaded)
        XCTAssertEqual(record.generation, 2)
        XCTAssertFalse(fm.fileExists(atPath: tx.path))
        try engine.appDataIn(manifest)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("com.example.foo/prefs.json"), encoding: .utf8), "v2")
    }

    func testRecoveryPutsBackAPartlyMovedSet() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        try engine.appDataIn(manifest)
        let tx = support.appendingPathComponent(".disklessly-data/com.example.foo--crash")
        try fm.createDirectory(at: tx.appendingPathComponent("aside"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: tx.appendingPathComponent("committed"))
        try fm.moveItem(at: support.appendingPathComponent("Foo"), to: tx.appendingPathComponent("aside/Foo"))
        try engine.appDataRecover(manifest.bundleId)
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("Foo/sub/disk.img").path))
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).state, .local)
    }

    func testRecoveryKeepsBothWhenAMovedRootWasRecreatedAndStopsUntilResolved() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        try engine.appDataIn(manifest)
        let tx = support.appendingPathComponent(".disklessly-data/com.example.foo--crash")
        try fm.createDirectory(at: tx.appendingPathComponent("aside"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: tx.appendingPathComponent("committed"))
        try fm.moveItem(at: support.appendingPathComponent("Foo"), to: tx.appendingPathComponent("aside/Foo"))
        try fm.createDirectory(at: support.appendingPathComponent("Foo"), withIntermediateDirectories: true) // a helper made it again
        try engine.appDataRecover(manifest.bundleId)
        XCTAssertTrue(fm.fileExists(atPath: tx.appendingPathComponent("aside/Foo/sub/disk.img").path), "the moved copy is kept")
        XCTAssertNotNil(engine.appDataStore.record(manifest.bundleId).conflict)
        XCTAssertThrowsError(try engine.appDataOut(manifest, since: Date()))
        XCTAssertThrowsError(try engine.appDataIn(manifest))
        // The user keeps the moved copy and deletes the transaction folder.
        try fm.removeItem(at: support.appendingPathComponent("Foo"))
        try fm.moveItem(at: tx.appendingPathComponent("aside/Foo"), to: support.appendingPathComponent("Foo"))
        try fm.removeItem(at: tx)
        try engine.appDataRecover(manifest.bundleId)
        XCTAssertNil(engine.appDataStore.record(manifest.bundleId).conflict)
        try engine.appDataOut(manifest, since: Date())
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).state, .offloaded)
    }

    func testTwoMacsOnOneRepoKeepTheirOwnData() throws {
        try writeData()
        let repo = root.appendingPathComponent("repo")
        let (a, manifest) = try makeEngine(repo: repo, state: "stateA")
        _ = try a.appDataEnable(manifest)
        // Mac B has its own Foo data.
        try writeData()
        try Data("mac b".utf8).write(to: support.appendingPathComponent("com.example.foo/prefs.json"))
        let (b, _) = try makeEngine(repo: repo, state: "stateB")
        _ = try b.appDataEnable(manifest)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: repo.appendingPathComponent("data").path).count, 2)
        try a.appDataIn(manifest)
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("com.example.foo/prefs.json"), encoding: .utf8), "settings")
    }

    func testRefusedEvictionStaysPendingAndIsRetriedOnStatus() throws {
        try writeData()
        var refuse = true
        var attempts: [URL] = []
        AppDataEviction.hook = { url in
            attempts.append(url)
            if refuse { throw CocoaError(.fileWriteNoPermission) }
        }
        let (engine, manifest) = try makeEngine()
        let status = try engine.appDataEnable(manifest)
        XCTAssertEqual(status.record.state, .offloaded, "a refused eviction does not fail the offload")
        let pending = try XCTUnwrap(engine.appDataStore.record(manifest.bundleId).pendingEvict)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(status.jsonObject()["localCopyStillHere"] as? Bool, true)
        XCTAssertFalse(attempts.isEmpty)

        attempts.removeAll()
        _ = try engine.appDataStatus() // still refused: stays pending
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).pendingEvict, pending)
        XCTAssertEqual(attempts.count, 1)

        refuse = false
        let after = try XCTUnwrap(try engine.appDataStatus().first { $0.appId == manifest.bundleId })
        XCTAssertNil(after.record.pendingEvict)
        XCTAssertNil(after.jsonObject()["localCopyStillHere"])
        XCTAssertTrue(attempts.last?.path.hasSuffix(pending[0]) ?? false)
    }

    func testPendingEvictRoundTripsAndOlderRecordsStillDecode() throws {
        var record = AppDataRecord()
        record.pendingEvict = ["data/d/com.example.foo/abc.tar.zst"]
        let decoded = try JSONDecoder().decode(AppDataRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.pendingEvict, record.pendingEvict)
        let older = Data("{\"enabled\":true,\"state\":\"offloaded\",\"generation\":1,\"roots\":[],\"bytes\":0}".utf8)
        XCTAssertNil(try JSONDecoder().decode(AppDataRecord.self, from: older).pendingEvict)
    }

    func testRefusesAppleAppsAndAppsWithALaunchAgent() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        var apple = manifest
        apple.bundleId = "com.apple.Pages"
        XCTAssertNotNil(engine.appDataRefusal(apple))
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("<plist><string>\(manifest.app.originalPath)/Contents/MacOS/helper</string></plist>".utf8).write(to: agents.appendingPathComponent("com.other.helper.plist"))
        XCTAssertNotNil(engine.appDataRefusal(manifest))
        XCTAssertThrowsError(try engine.appDataEnable(manifest))
    }

    func testALoginItemThatStartsTheAppItselfIsAllowed() throws {
        try writeData()
        let (engine, manifest) = try makeEngine()
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "Foo", "RunAtLoad": true,
                                    "ProgramArguments": [manifest.app.originalPath + "/Contents/MacOS/" + manifest.app.executable]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agents.appendingPathComponent("Foo.plist"))
        XCTAssertNil(engine.appDataLaunchAgent(manifest), "the stub brings the data back before the app starts")
        let helper: [String: Any] = ["Label": "FooHelper", "ProgramArguments": [manifest.app.originalPath + "/Contents/MacOS/helper"]]
        try PropertyListSerialization.data(fromPropertyList: helper, format: .xml, options: 0).write(to: agents.appendingPathComponent("FooHelper.plist"))
        XCTAssertEqual(engine.appDataLaunchAgent(manifest), "FooHelper")
    }

    /// An enabled app whose data is local again, with changes since its last upload.
    func enabledLocalWithChanges() throws -> (DisklesslyEngine, ImageManifest) {
        try writeData()
        let (engine, manifest) = try makeEngine()
        _ = try engine.appDataEnable(manifest)
        try engine.appDataIn(manifest)
        try Data("changed".utf8).write(to: support.appendingPathComponent("com.example.foo/prefs.json"))
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).state, .local)
        return (engine, manifest)
    }

    func testQuitKeepLeavesTheDataLocalAndUploadsNothing() throws {
        let (base, manifest) = try enabledLocalWithChanges()
        var engine = base
        engine.quitChooser = { name in
            XCTAssertEqual(name, "Foo")
            return .keep
        }
        engine.appDataAfterQuit(appId: manifest.bundleId, since: Date())
        let record = engine.appDataStore.record(manifest.bundleId)
        XCTAssertEqual(record.state, .local)
        XCTAssertTrue(record.enabled)
        XCTAssertNil(record.lastError)
        XCTAssertEqual(record.generation, 1, "nothing was uploaded")
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("com.example.foo/prefs.json"), encoding: .utf8), "changed")
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("Foo/sub/disk.img").path))
    }

    func testQuitPutBackUploadsAndRemovesTheLocalFolders() throws {
        let (base, manifest) = try enabledLocalWithChanges()
        var engine = base
        engine.quitChooser = { _ in .putBack }
        engine.appDataAfterQuit(appId: manifest.bundleId, since: Date())
        let record = engine.appDataStore.record(manifest.bundleId)
        XCTAssertEqual(record.state, .offloaded)
        XCTAssertEqual(record.generation, 2, "the changed data is a new generation")
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("com.example.foo").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("Foo").path))
    }

    func testQuitAskOffDisablesThePromptAndPutsBack() throws {
        setenv("DISKLESSLY_QUIT_ASK", "0", 1)
        defer { unsetenv("DISKLESSLY_QUIT_ASK") }
        let (base, manifest) = try enabledLocalWithChanges()
        var engine = base
        engine.quitChooser = nil
        XCTAssertEqual(engine.quitChoice(appName: "Foo"), .putBack)
        engine.appDataAfterQuit(appId: manifest.bundleId, since: Date())
        XCTAssertEqual(engine.appDataStore.record(manifest.bundleId).state, .offloaded)
    }

    func testQuitPromptReadsTheDialogAnswer() {
        let put = AppDataQuitPrompt.putBackLabel
        let keep = AppDataQuitPrompt.keepLabel
        XCTAssertEqual(AppDataQuitPrompt.choice(fromOutput: "button returned:\(put)\n", exitStatus: 0), .putBack)
        XCTAssertEqual(AppDataQuitPrompt.choice(fromOutput: "button returned:\(keep)\n", exitStatus: 0), .keep)
        XCTAssertEqual(AppDataQuitPrompt.choice(fromOutput: "", exitStatus: 1), .keep, "cancelled")
        XCTAssertEqual(AppDataQuitPrompt.choice(fromOutput: "button returned:\(put), gave up:true\n", exitStatus: 0), .putBack, "timed out")
        XCTAssertTrue(AppDataQuitPrompt.script(app: "Foo").contains("giving up after 60"))
    }
}

/// The tree fingerprint without inode numbers, which change on a round trip.
enum TreeFingerprintNoInode {
    static func of(_ root: URL) throws -> [String] {
        var lines: [String] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root.path) else { return [] }
        for case let path as String in walker where !path.hasPrefix(".disklessly-data") {
            let attrs = try fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let type = attrs[.type] as? FileAttributeType
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            lines.append("\(path)|\(type?.rawValue ?? "")|\(size)|\(mode)|\(type == .typeDirectory ? 0 : Int(date))")
        }
        return lines.sorted()
    }
}
