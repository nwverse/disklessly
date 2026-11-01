import XCTest
@testable import DisklesslyEngine

final class LocalPresenceTests: XCTestCase {
    private func makeApp(_ folder: URL, _ name: String, id: String, version: String = "1.0", stub: Bool = false) throws {
        let contents = folder.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        XCTAssertTrue(info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        if stub { try Data("{}".utf8).write(to: contents.appendingPathComponent("Resources/stub.json")) }
    }

    func testClassifiesStubFullAppAndAbsent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A renamed stub, a full app reinstalled after another Mac offloaded it, and nothing.
        try makeApp(folder, "Keynote Creator Studio", id: "com.apple.Keynote.256stub", stub: true)
        try makeApp(folder, "WeChat", id: "com.tencent.xinWeChat", version: "4.1.15")
        let index = LocalAppIndex(folders: [folder.path])

        let keynote = index.presence(bundleId: "com.apple.Keynote", imageId: "k", ownImageIds: ["k"])
        XCTAssertEqual(keynote.kind, .stub)
        XCTAssertTrue(keynote.mine)

        let wechat = index.presence(bundleId: "com.tencent.xinWeChat", imageId: "w", ownImageIds: ["k"])
        XCTAssertEqual(wechat.kind, .installed)
        XCTAssertEqual(wechat.version, "4.1.15")
        XCTAssertFalse(wechat.mine)

        let obsidian = index.presence(bundleId: "md.obsidian", imageId: "o", ownImageIds: ["k"])
        XCTAssertEqual(obsidian.kind, .absent)
        XCTAssertFalse(obsidian.mine)
        XCTAssertEqual(obsidian.jsonObject["kind"] as? String, "absent")
    }

    func testStubWinsOverFullAppWithTheSameId() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeApp(folder, "Old", id: "com.example.app", version: "1")
        try makeApp(folder, "App", id: "com.example.app", stub: true)
        let presence = LocalAppIndex(folders: [folder.path]).presence(bundleId: "com.example.app", imageId: "x", ownImageIds: [])
        XCTAssertEqual(presence.kind, .stub)
        XCTAssertTrue(presence.path?.hasSuffix("App.app") ?? false)
    }
}
