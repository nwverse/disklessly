import XCTest
import DisklesslyCore
@testable import DisklesslyEngine

final class CloudUsageTests: XCTestCase {
    private func item(_ id: String, _ bytes: UInt64, origin: String? = nil, restore: String? = nil) -> CloudUsageInputs.Item {
        CloudUsageInputs.Item(id: id, name: id, bytes: bytes, storedBytes: bytes / 2, originPath: origin, restore: restore, restoreId: id)
    }

    private func sample() -> CloudUsageInputs {
        var input = CloudUsageInputs()
        input.apps = [
            .init(item: item("Blender", 3000, origin: "/Applications/Blender.app", restore: "unpack"), bundleId: "org.blender"),
            .init(item: item("Krita", 1000, origin: "/Applications/Krita.app", restore: "unpack"), bundleId: "org.krita"),
        ]
        input.files = [item("Raw", 5000, origin: "/Users/me/Movies/Raw", restore: "fetch"), item("old.zip", 200, origin: "/Users/me/old.zip", restore: "fetch")]
        input.linked = [
            .init(id: "l1", name: "Blender", appPath: "/Applications/Blender.app", items: [item("assets", 700, origin: "/Users/me/.blender")]),
            .init(id: "l2", name: "Tool", appPath: "/Applications/Tool.app", items: [item("tooldata", 300, origin: "/Users/me/.tool")]),
        ]
        input.data = [
            .init(item: item("Krita data", 400, restore: "data/disable"), bundleId: "org.krita"),
            .init(item: item("Gone data", 50, restore: "data/disable"), bundleId: "com.gone"),
        ]
        input.sessions = [
            .init(item: item("a.jsonl", 30, origin: "/Users/me/.claude/a.jsonl"), tool: "claude"),
            .init(item: item("b.jsonl", 20), tool: "claude"),
            .init(item: item("c.jsonl", 10), tool: "codex"),
        ]
        return input
    }

    private func group(_ tree: UsageNode, _ key: String) -> UsageNode? { tree.children.first { $0.key == key } }

    func testGroupsAndSums() {
        let tree = CloudUsage.assemble(sample())
        XCTAssertEqual(tree.kind, .root)
        XCTAssertEqual(group(tree, "apps")?.bytes, 3000 + 700 + 1000 + 400)
        XCTAssertEqual(group(tree, "files")?.bytes, 5200)
        XCTAssertEqual(group(tree, "linked")?.bytes, 300, "only the bundle whose app is not packed stays in Linked")
        XCTAssertEqual(group(tree, "data")?.bytes, 50, "only data whose app is not packed stays in App data")
        XCTAssertEqual(group(tree, "sessions")?.bytes, 60)
        XCTAssertEqual(tree.bytes, 5100 + 5200 + 300 + 50 + 60)
        XCTAssertEqual(tree.children.map(\.bytes), tree.children.map(\.bytes).sorted(by: >), "largest group first")
        XCTAssertTrue(tree.children.allSatisfy { $0.kind == .offloaded })
        XCTAssertEqual(CloudUsage.storedBytes(tree), (3000 + 700 + 1000 + 400 + 5000 + 200 + 300 + 50 + 30 + 20 + 10) / 2, "stored sizes of the leaves")
    }

    func testLinkedBundlesAndDataSitUnderTheirApp() throws {
        let tree = CloudUsage.assemble(sample())
        let apps = try XCTUnwrap(group(tree, "apps"))
        let blender = try XCTUnwrap(apps.children.first { $0.name == "Blender" })
        XCTAssertEqual(blender.children.map(\.key), ["bundle", "linked"])
        XCTAssertEqual(blender.cloud?.restore, "unpack", "the app box restores the whole app")
        XCTAssertEqual(blender.cloud?.originPath, "/Applications/Blender.app")
        XCTAssertEqual(blender.children[1].cloud?.restore, "links/restore")
        XCTAssertEqual(blender.children[1].cloud?.restoreId, "l1")
        XCTAssertNotEqual(blender.children[0].cloud?.id, blender.cloud?.id, "ids stay unique in the tree")
        let krita = try XCTUnwrap(apps.children.first { $0.name == "Krita" })
        XCTAssertEqual(krita.children.map(\.key), ["bundle", "data"])
        XCTAssertEqual(krita.children[1].cloud?.restore, "data/disable")
    }

    func testSessionsAreGroupedByTool() throws {
        let sessions = try XCTUnwrap(group(CloudUsage.assemble(sample()), "sessions"))
        XCTAssertEqual(sessions.children.map(\.name), ["claude", "codex"])
        XCTAssertEqual(sessions.children.map(\.bytes), [50, 10])
        XCTAssertEqual(sessions.children[0].children.map(\.name), ["a.jsonl", "b.jsonl"])
    }

    func testTheTailMergesIntoOther() throws {
        var input = CloudUsageInputs()
        input.files = (1...20).map { item("f\($0)", UInt64($0)) } + [item("zero", 0)]
        let files = try XCTUnwrap(group(CloudUsage.assemble(input), "files"))
        XCTAssertEqual(files.children.count, UsageMap.maxListed + 1)
        XCTAssertEqual(files.children.last?.key, "rest")
        XCTAssertEqual(files.children.last?.name, "6")
        XCTAssertEqual(files.bytes, 210)
        XCTAssertFalse(files.children.contains { $0.name == "zero" })
    }

    func testAnotherDevicesCopyIsNamedAndAppsOnlyOnOtherMacsAreLeftOut() throws {
        let image = ImageManifest.Image(file: "images/x.dmg", format: "ULFO", sha256: String(repeating: "a", count: 64), size: 800, volumeName: "X", appPathInVolume: "X.app")
        let manifest = ImageManifest(bundleId: "com.x", name: "X", version: "1", image: image, app: .init(originalPath: "/Applications/X.app", executable: "X", documentTypes: [], urlTypes: []))
        let stub = LocalPresence(kind: .stub, mine: true, path: "/Applications/X.app", version: nil)
        let shared = try XCTUnwrap(CloudUsage.appItem(manifest, presence: stub, cachedBytes: 100, lastUsed: nil, holders: ["Studio Mini"]))
        XCTAssertEqual(shared.item.otherDevice, "Studio Mini")
        XCTAssertEqual(shared.item.stubPath, "/Applications/X.app")
        XCTAssertEqual(shared.item.localBytes, 100)
        XCTAssertEqual(shared.item.storedBytes, 800)
        let elsewhere = LocalPresence(kind: .absent, mine: false, path: nil, version: nil)
        XCTAssertNil(CloudUsage.appItem(manifest, presence: elsewhere, cachedBytes: 0, lastUsed: nil, holders: ["Studio Mini"]), "an app packed on another Mac was never on this disk")
        let back = LocalPresence(kind: .installed, mine: true, path: "/Applications/X.app", version: "1")
        XCTAssertNil(CloudUsage.appItem(manifest, presence: back, cachedBytes: 0, lastUsed: nil, holders: []), "a restored app is on the local side")

        var input = CloudUsageInputs()
        input.apps = [shared]
        let node = try XCTUnwrap(group(CloudUsage.assemble(input), "apps")?.children.first)
        XCTAssertEqual(node.jsonObject()["otherDevice"] as? String, "Studio Mini")
    }

    func testEmptyCatalogIsAnEmptyRoot() {
        let tree = CloudUsage.assemble(CloudUsageInputs())
        XCTAssertEqual(tree.bytes, 0)
        XCTAssertTrue(tree.children.isEmpty)
        XCTAssertEqual(tree.jsonObject()["key"] as? String, "cloud")
        XCTAssertEqual(CloudUsage.storedBytes(tree), 0)
    }

    func testJSONCarriesTheCloudFields() throws {
        var input = CloudUsageInputs()
        var raw = item("Raw", 5000, origin: "/Users/me/Movies/Raw", restore: "fetch")
        raw.stubPath = "/Users/me/Movies/Raw.disklessly"
        raw.offloadedAt = Date(timeIntervalSince1970: 1_700_000_000)
        input.files = [raw]
        let leaf = try XCTUnwrap(group(CloudUsage.assemble(input), "files")?.children.first?.jsonObject())
        XCTAssertEqual(leaf["kind"] as? String, "offloaded")
        XCTAssertEqual(leaf["id"] as? String, "Raw")
        XCTAssertEqual((leaf["storedBytes"] as? NSNumber)?.intValue, 2500)
        XCTAssertEqual(leaf["originPath"] as? String, "/Users/me/Movies/Raw")
        XCTAssertEqual(leaf["stubPath"] as? String, "/Users/me/Movies/Raw.disklessly")
        XCTAssertEqual((leaf["offloadedAt"] as? NSNumber)?.intValue, 1_700_000_000)
        XCTAssertEqual((leaf["modified"] as? NSNumber)?.intValue, 1_700_000_000, "age falls back to the offload date")
        XCTAssertEqual(leaf["restore"] as? String, "fetch")
        XCTAssertEqual(input.originPaths, ["/Users/me/Movies/Raw"])
    }
}
