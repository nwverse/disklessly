import XCTest
@testable import IsenoughCore
@testable import IsenoughEngine

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
    func testLocalBackendRangeAndTraversal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer{try? FileManager.default.removeItem(at:root)}
        let b=try LocalFolderBackend(root:root); try b.put("sub/file",data:Data("abcdef".utf8)); XCTAssertEqual(try b.get("sub/file",range:1..<4),Data("bcd".utf8)); XCTAssertEqual(try b.list("sub"),["file"]); XCTAssertThrowsError(try b.get("../escape",range:nil))
    }
    func testStubInfoAndArgumentForwarding() {
        let p=StubGenerator.infoPlist(source:["CFBundleIdentifier":"com.a","SUFeedURL":"x","CFBundleDocumentTypes":[["x":1]]],appId:"com.a")
        XCTAssertEqual(p["CFBundleIdentifier"] as? String,"com.a.256stub"); XCTAssertEqual(p["LSUIElement"] as? Bool,true); XCTAssertNil(p["SUFeedURL"]); XCTAssertEqual(StubGenerator.forwardArguments(["a b","https://x/y"]),["a b","https://x/y"])
    }
    func testFileLockSerializes() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        var lock=FileLock(path:path); try lock.lock(); XCTAssertTrue(lock.isLocked); lock.unlock(); XCTAssertFalse(lock.isLocked)
    }
}
