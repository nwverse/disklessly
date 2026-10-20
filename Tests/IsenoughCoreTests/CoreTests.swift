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

    func testRestoreModeIsExplicitlyRefusedUntilRecoveryExists() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let bytes=Data("restore fixture".utf8), source=root.appendingPathComponent("image.dmg"); try bytes.write(to:source)
        let sha=try Hashing.sha256(source)
        let image=ImageManifest.Image(file:"images/a.dmg",format:"ULMO",sha256:sha,size:UInt64(bytes.count),volumeName:"A",appPathInVolume:"A.app")
        let manifest=ImageManifest(bundleId:"com.test.a",name:"A",version:"1",image:image,app:.init(originalPath:"/A.app",executable:"A",documentTypes:[],urlTypes:[]),mode:.restore)
        let config=RuntimeConfig(repoPath:root.appendingPathComponent("repo").path,cacheDir:root.appendingPathComponent("cache").path,stateDir:root.appendingPathComponent("state").path,mountRoot:root.appendingPathComponent("mount").path,stubDir:root.appendingPathComponent("apps").path)
        XCTAssertThrowsError(try IsenoughEngine(config:config).launch(manifest)) { error in
            XCTAssertEqual((error as? IsenoughError)?.errorDescription,"restore mode is disabled until durable restore recovery is implemented")
        }
    }

}
