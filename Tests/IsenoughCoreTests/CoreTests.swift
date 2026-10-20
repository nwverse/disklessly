import XCTest
@testable import IsenoughCore
@testable import IsenoughEngine
import IsenoughStubSupport

final class CoreTests: XCTestCase {
    func testManifestRoundTripAndFormatVersioning() throws {
        let image=ImageManifest.Image(file:"images/a.dmg",format:"ULMO",sha256:String(repeating:"a",count:64),size:3,volumeName:"A",appPathInVolume:"A.app")
        let app=ImageManifest.App(originalPath:"/Applications/A.app",executable:"A",documentTypes:[],urlTypes:[])
        let m=ImageManifest(bundleId:"com.test.a",name:"A",version:"1.0",image:image,app:app,createdAt:Date(timeIntervalSince1970:1_700_000_000))
        XCTAssertEqual(try ImageManifest.decode(m.encode()),m)
        var bad=m; bad.image.format="ULFO"; XCTAssertThrowsError(try bad.validate())
    }
    func testLRUAndPins() {
        let now=Date(); let xs=[CacheEntry(id:"new",size:8,lastUsed:now),CacheEntry(id:"old",size:8,lastUsed:now.addingTimeInterval(-5)),CacheEntry(id:"pin",size:40,lastUsed:now.addingTimeInterval(-10),pinned:true)]
        XCTAssertEqual(CachePolicy.evictionPlan(xs,quota:10),["old","new"])
    }
    func testStateMachineRejectsIllegalTransitions() throws {
        XCTAssertEqual(try StateMachine.transition(.remote,.fetch),.downloading)
        XCTAssertThrowsError(try StateMachine.transition(.remote,.detach))
    }
    func testStateStoreRunningToCachedTransition() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=StateStore(root.path), now=Date(timeIntervalSince1970:1_700_000_000)
        try store.setAppState(bundleId:"com.test.app",imageId:"image-1",state:"running",mountPoint:"/mnt/image-1",lastUsed:now)
        try store.setAppState(bundleId:"com.test.app",imageId:"image-1",state:"cached",lastUsed:now.addingTimeInterval(1))
        let result=store.read(), apps=result["apps"] as! [String:[String:Any]]
        XCTAssertEqual(apps["com.test.app"]?["state"] as? String,"cached")
        XCTAssertNil(apps["com.test.app"]?["mountPoint"])
        XCTAssertNotNil(apps["com.test.app"]?["lastUsed"])
    }
    func testLocalBackendRangeAndTraversal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer{try? FileManager.default.removeItem(at:root)}
        let b=try LocalFolderBackend(root:root); try b.put("sub/file",data:Data("abcdef".utf8)); XCTAssertEqual(try b.get("sub/file",range:1..<4),Data("bcd".utf8)); XCTAssertEqual(try b.list("sub"),["file"]); XCTAssertThrowsError(try b.get("../escape",range:nil))
    }
    func testPrefetchCachesPublishedImageBytesWithoutReencoding() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repo=root.appendingPathComponent("repo"), cache=root.appendingPathComponent("cache")
        let config=RuntimeConfig(repoPath:repo.path,cacheDir:cache.path,stateDir:root.appendingPathComponent("state").path,mountRoot:root.appendingPathComponent("mounts").path,stubDir:root.appendingPathComponent("apps").path)
        let engine=IsenoughEngine(config:config)
        try engine.initialize()
        let bytes=Data("published disk image bytes".utf8)
        let imageURL=root.appendingPathComponent("source.dmg")
        try bytes.write(to:imageURL)
        let sha=try Hashing.sha256(imageURL)
        let image=ImageManifest.Image(file:"images/test.dmg",format:"ULMO",sha256:sha,size:UInt64(bytes.count),volumeName:"Test",appPathInVolume:"Test.app")
        let manifest=ImageManifest(bundleId:"com.test.app",name:"Test",version:"1",image:image,app:.init(originalPath:"/Applications/Test.app",executable:"Test",documentTypes:[],urlTypes:[]))
        try LocalFolderBackend(root:repo).put(image.file,data:bytes)
        let fetched=try engine.prefetch(manifest)
        XCTAssertEqual(try Data(contentsOf:fetched),bytes)
        XCTAssertEqual(fetched.path,cache.appendingPathComponent("images/\(manifest.imageId).dmg").path)
    }
    func testStubInfoAndArgumentForwarding() {
        let p=StubGenerator.infoPlist(source:["CFBundleIdentifier":"com.a","SUFeedURL":"x","CFBundleDocumentTypes":[["x":1]]],appId:"com.a")
        XCTAssertEqual(p["CFBundleIdentifier"] as? String,"com.a.256stub"); XCTAssertEqual(p["LSUIElement"] as? Bool,true); XCTAssertNil(p["SUFeedURL"]); 
    }
    func testStubPathComparisonNormalizesRedundantSeparators() {
        XCTAssertTrue(StubGenerator.pathsReferToSameLocation("/var/folders/ab/app/Test.app", "/var/folders//ab/app/Test.app"))
        XCTAssertTrue(StubGenerator.pathsReferToSameLocation("/tmp/./Test.app", "/tmp/Test.app"))
        XCTAssertFalse(StubGenerator.pathsReferToSameLocation("/tmp/Test.app", "/Applications/Test.app"))
    }
    func testFileLockSerializes() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        var lock=FileLock(path:path); try lock.lock(); XCTAssertTrue(lock.isLocked); lock.unlock(); XCTAssertFalse(lock.isLocked)
    }
    func testStubArgvClassificationAndLaunchRoundTrip() throws {
        let cwd=URL(fileURLWithPath:"/w")
        let built=try StubArgv.build(appId:"com.a",rawArguments:["--doc","/a b/\"$ü.txt","https://h/p?q=1","file:///y%20z.txt","rel.txt","--arg","$ \"🙂"],cwd:cwd)
        XCTAssertEqual(Array(built.prefix(2)),["launch","com.a"])
        let parsed=try LaunchArguments.parse(Array(built.dropFirst()))
        XCTAssertEqual(parsed.documents,["/a b/\"$ü.txt","/y z.txt","/w/rel.txt"])
        XCTAssertEqual(parsed.urls,["https://h/p?q=1"])
        XCTAssertEqual(parsed.arguments,["$ \"🙂"])
        XCTAssertThrowsError(try StubArgv.build(appId:"com.a",rawArguments:["--doc"],cwd:cwd))
    }
    func testLaunchParserRejectsMalformedOptions() {
        for args in [["app","--bogus"],["app","--doc"],["--doc","x"]] { XCTAssertThrowsError(try LaunchArguments.parse(args)) }
    }
    func testCachePathNaming() {
        let p=CachePaths(cacheDir:"/c",mountRoot:"/m")
        XCTAssertEqual(p.image("id").path,"/c/images/id.dmg")
        XCTAssertEqual(p.partial("id").path,"/c/partial/id.dmg.part")
        XCTAssertEqual(p.mount("id").path,"/m/id")
    }
    func testLauncherLookupPriorityAndSelfRejection() throws {
        let cli=URL(fileURLWithPath:"/bin/isenough")
        let found=try StubGenerator.locateLauncher(cliExecutable:cli,environment:["ISENOUGH_STUB_BINARY":"/custom/stub"],isExecutable:{$0 == "/custom/stub"})
        XCTAssertEqual(found.path,"/custom/stub")
        XCTAssertThrowsError(try StubGenerator.locateLauncher(cliExecutable:cli,environment:[:],isExecutable:{$0 == "/bin/isenough"}))
    }

    /// The previous placeholder asserted that restore launch threw
    /// "restore mode is disabled until durable restore recovery is implemented".
    /// Recovery now exists, so this test requires the journaled transaction instead:
    /// detach happens before `active`, and mount-mode launch still refuses on Linux
    /// without creating a restore journal or a mount session.
    func testRestoreModeRunsJournalDetachesBeforeActiveAndSkipsMountRecovery() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        try world.launch(wait: true)
        let events = world.engine.restore.events
        guard let detachAt = events.firstIndex(of: "detach"), let activeAt = events.firstIndex(of: "active") else {
            XCTFail("expected detach and active events, got \(events)")
            return
        }
        XCTAssertLessThan(detachAt, activeAt)
        XCTAssertFalse(world.engine.restore.events.contains("mount-adopt"))
        let state = try Data(contentsOf: world.stateURL)
        let text = String(decoding: state, as: UTF8.self)
        XCTAssertFalse(text.contains("mountPoint"))
        XCTAssertFalse(text.contains("\"mounts\""))
        XCTAssertEqual(world.outcomeName, "restoredOut")
        XCTAssertTrue(world.journals().isEmpty)
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
        var mountManifest = world.manifest
        mountManifest.mode = .mount
        XCTAssertThrowsError(try world.engine.launch(mountManifest)) { error in
            XCTAssertEqual((error as? IsenoughError)?.errorDescription, "launch requires macOS hdiutil and Launch Services")
        }
        XCTAssertTrue(world.journals().isEmpty)
    }

    func testStubArgvKeepsFlagShapedNamesAfterSeparator() throws {
        let cwd = URL(fileURLWithPath: "/w")
        let built = try StubArgv.build(appId: "com.a", rawArguments: ["--", "-NSnotes.txt", "keep.txt"], cwd: cwd)
        XCTAssertEqual(built, ["launch", "com.a", "--doc", "/w/-NSnotes.txt", "--doc", "/w/keep.txt"])
    }

    func testFileURLPercentDecodesOnce() throws {
        let cwd = URL(fileURLWithPath: "/w")
        let built = try StubArgv.build(appId: "com.a", rawArguments: ["file:///w/a%2520b.txt"], cwd: cwd)
        XCTAssertEqual(built, ["launch", "com.a", "--doc", "/w/a%20b.txt"])
        let parsed = try LaunchArguments.parse(Array(built.dropFirst()))
        XCTAssertEqual(parsed.documents, ["/w/a%20b.txt"])
    }

    func testInvalidStubBinaryOverrideDoesNotFallBack() {
        let cli = URL(fileURLWithPath: "/bin/isenough")
        XCTAssertThrowsError(try StubGenerator.locateLauncher(cliExecutable: cli, environment: ["ISENOUGH_STUB_BINARY": "/missing/stub"], isExecutable: { $0 == "/bin/isenough-stub" })) { error in
            let usage = error as? IsenoughError
            XCTAssertEqual(usage?.exitCode, 2)
            XCTAssertEqual(usage?.errorDescription, "ISENOUGH_STUB_BINARY is not executable: /missing/stub")
        }
    }

    func testLocateLauncherSiblingWhenEnvUnset() throws {
        let cli = URL(fileURLWithPath: "/opt/isenough")
        let found = try StubGenerator.locateLauncher(cliExecutable: cli, environment: [:], isExecutable: { $0 == "/opt/isenough-stub" })
        XCTAssertEqual(found.path, "/opt/isenough-stub")
    }

    func testLocateLauncherRejectsSelfIdentity() {
        let cli = URL(fileURLWithPath: "/opt/isenough")
        XCTAssertThrowsError(try StubGenerator.locateLauncher(cliExecutable: cli, environment: ["ISENOUGH_STUB_BINARY": "/opt/isenough"], isExecutable: { _ in true })) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 1)
            XCTAssertEqual((error as? IsenoughError)?.errorDescription, "Refusing to use CLI as isenough-stub launcher")
        }
    }

    func testCLITopLevelUnknownOptionIsUsageError() {
        XCTAssertThrowsError(try GlobalArguments.parse(["--doc", "x"])) { error in
            XCTAssertEqual((error as? IsenoughError)?.errorDescription, "Unknown option: --doc")
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 2)
        }
        XCTAssertThrowsError(try GlobalArguments.parse(["--config"])) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 2)
        }
        let parsed = try? GlobalArguments.parse(["--json", "--state-dir", "/tmp/state", "launch", "com.a"])
        XCTAssertEqual(parsed?.json, true)
        XCTAssertEqual(parsed?.stateDir, "/tmp/state")
        XCTAssertEqual(parsed?.rest, ["launch", "com.a"])
    }

    func testStubArgvResolveCLIPrecedence() throws {
        let home = "/home/u"
        let envWins = try StubArgv.resolveCLI(environment: ["ISENOUGH_CLI": "/env/isenough"], stubInfo: ["isenoughPath": "/stub/isenough"], path: "/opt/bin", home: home, isExecutable: { _ in true })
        XCTAssertEqual(envWins.path, "/env/isenough")
        let stubWins = try StubArgv.resolveCLI(environment: [:], stubInfo: ["isenoughPath": "/stub/isenough"], path: "/opt/bin", home: home, isExecutable: { $0 == "/stub/isenough" || $0 == "/opt/bin/isenough" })
        XCTAssertEqual(stubWins.path, "/stub/isenough")
        let pathWins = try StubArgv.resolveCLI(environment: [:], stubInfo: [:], path: "/opt/bin:/usr/bin", home: home, isExecutable: { $0 == "/usr/bin/isenough" })
        XCTAssertEqual(pathWins.path, "/usr/bin/isenough")
        let fallback = try StubArgv.resolveCLI(environment: [:], stubInfo: [:], path: "", home: home, isExecutable: { $0 == "/opt/homebrew/bin/isenough" })
        XCTAssertEqual(fallback.path, "/opt/homebrew/bin/isenough")
        XCTAssertThrowsError(try StubArgv.resolveCLI(environment: [:], stubInfo: [:], path: "", home: home, isExecutable: { _ in false }))
    }

    func testImageNamingUsesImageId() throws {
        let sha = String(repeating: "ab", count: 32)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: 4, volumeName: "A", appPathInVolume: "A.app")
        let manifest = ImageManifest(bundleId: "com.a", name: "A", version: "1.2", image: image, app: .init(originalPath: "/Applications/A.app", executable: "A", documentTypes: [], urlTypes: []))
        XCTAssertEqual(manifest.imageId, "com.a-1.2-abababab")
        XCTAssertEqual(manifest.image.file, "images/\(manifest.imageId).dmg")
        let paths = CachePaths(cacheDir: "/c", mountRoot: "/m")
        XCTAssertEqual(paths.image(manifest.imageId).path, "/c/images/\(manifest.imageId).dmg")
        XCTAssertEqual(paths.partial(manifest.imageId).path, "/c/partial/\(manifest.imageId).dmg.part")
        XCTAssertEqual(paths.mount(manifest.imageId).path, "/m/\(manifest.imageId)")
        XCTAssertEqual(try ImageManifest.decode(manifest.encode()).imageId, manifest.imageId)
    }

    func testSHA256DigestMatchesReferenceVectors() {
        XCTAssertEqual(SHA256Digest.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testPrefetchReplacesStaleCacheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let cache = root.appendingPathComponent("cache")
        let config = RuntimeConfig(repoPath: repo.path, cacheDir: cache.path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        let engine = IsenoughEngine(config: config)
        try engine.initialize()
        let bytes = Data("published disk image bytes".utf8)
        let source = root.appendingPathComponent("source.dmg")
        try bytes.write(to: source)
        let sha = try Hashing.sha256(source)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "Test", appPathInVolume: "Test.app")
        let manifest = ImageManifest(bundleId: "com.test.app", name: "Test", version: "1", image: image, app: .init(originalPath: "/Applications/Test.app", executable: "Test", documentTypes: [], urlTypes: []))
        try LocalFolderBackend(root: repo).put(manifest.image.file, data: bytes)
        let cacheImage = cache.appendingPathComponent("images/\(manifest.imageId).dmg")
        try FileManager.default.createDirectory(at: cacheImage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: cacheImage)
        let partial = cache.appendingPathComponent("partial/\(manifest.imageId).dmg.part")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial)
        let fetched = try engine.prefetch(manifest)
        XCTAssertEqual(try Data(contentsOf: fetched), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testPrefetchRejectsCorruptRemote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let cache = root.appendingPathComponent("cache")
        let config = RuntimeConfig(repoPath: repo.path, cacheDir: cache.path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        let engine = IsenoughEngine(config: config)
        try engine.initialize()
        let bytes = Data("published disk image bytes".utf8)
        let source = root.appendingPathComponent("source.dmg")
        try bytes.write(to: source)
        let sha = try Hashing.sha256(source)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "Test", appPathInVolume: "Test.app")
        let manifest = ImageManifest(bundleId: "com.test.app", name: "Test", version: "1", image: image, app: .init(originalPath: "/Applications/Test.app", executable: "Test", documentTypes: [], urlTypes: []))
        try LocalFolderBackend(root: repo).put(manifest.image.file, data: bytes + Data("corruption".utf8))
        XCTAssertThrowsError(try engine.prefetch(manifest)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 5)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("images/\(manifest.imageId).dmg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("partial/\(manifest.imageId).dmg.part").path))
    }

    func testFileLockTryLockContendsOnLinux() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        var held = FileLock(path: path)
        XCTAssertTrue(try held.tryLock())
        var other = FileLock(path: path)
        #if os(Linux)
        XCTAssertFalse(try other.tryLock())
        #endif
        held.unlock()
        XCTAssertTrue(try other.tryLock())
        other.unlock()
    }

}
