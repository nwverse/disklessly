import XCTest
@testable import DisklesslyEngine

final class UsageMapTests: XCTestCase {
    private func input() -> UsageInputs {
        var i = UsageInputs(totalBytes: 1000, freeBytes: 300)
        i.apps = [.init(name: "Big", bundleBytes: 200, cacheBytes: 50, dataBytes: 30), .init(name: "Small", bundleBytes: 10)]
        i.offloaded = [.init(name: "Off", cachedBytes: 40), .init(name: "Gone", cachedBytes: 0)]
        i.repoBytes = 20
        i.personal = [.init(name: "Movies", bytes: 100), .init(name: "Empty", bytes: 0)]
        i.library = [.init(name: "Caches", bytes: 60, kind: .cache)]
        return i
    }

    func testRootEqualsDiskAndRemainderIsSystem() {
        let tree = UsageMap.assemble(input())
        XCTAssertEqual(tree.bytes, 1000)
        let top = Dictionary(uniqueKeysWithValues: tree.children.map { ($0.key ?? $0.name, $0) })
        XCTAssertEqual(top["apps"]?.bytes, 290)
        XCTAssertEqual(top["disklessly"]?.bytes, 60)
        XCTAssertEqual(top["personal"]?.bytes, 100)
        XCTAssertEqual(top["library"]?.bytes, 60)
        XCTAssertEqual(top["free"]?.bytes, 300)
        XCTAssertEqual(top["system"]?.bytes, 700 - 290 - 60 - 100 - 60)
    }

    func testAppSplitsIntoBundleCacheAndData() {
        let tree = UsageMap.assemble(input())
        let apps = tree.children.first { $0.key == "apps" }!
        let big = apps.children.first { $0.name == "Big" }!
        XCTAssertEqual(big.children.map { $0.key }, ["bundle", "cache", "data"])
        XCTAssertEqual(big.children.map(\.bytes), [200, 50, 30])
        let small = apps.children.first { $0.name == "Small" }!
        XCTAssertEqual(small.children.map { $0.key }, ["bundle"], "an app without cache or data has only its bundle")
    }

    func testZeroBoxesAreDroppedAndTheTailIsMerged() {
        var i = UsageInputs(totalBytes: 10_000, freeBytes: 0)
        i.personal = (1...20).map { .init(name: "d\($0)", bytes: UInt64($0)) } + [.init(name: "zero", bytes: 0)]
        let personal = UsageMap.assemble(i).children.first { $0.key == "personal" }!
        XCTAssertEqual(personal.children.count, UsageMap.maxListed + 1)
        XCTAssertEqual(personal.children.last?.key, "rest")
        XCTAssertEqual(personal.children.last?.name, "6")
        XCTAssertEqual(personal.bytes, 210)
        XCTAssertFalse(personal.children.contains { $0.name == "zero" })
    }

    func testBoxesLargerThanTheDiskDoNotUnderflowTheSystemBox() {
        var i = UsageInputs(totalBytes: 100, freeBytes: 10)
        i.personal = [.init(name: "huge", bytes: 500)]
        let tree = UsageMap.assemble(i)
        XCTAssertEqual(tree.children.first { $0.key == "system" }?.bytes, 0)
    }

    func testScannerRunsOnceAndReportsTheTree() throws {
        let release = DispatchSemaphore(value: 0)
        let scanner = UsageScanner(run: { _, _ in release.wait(); return (UsageMap.assemble(UsageInputs(totalBytes: 10, freeBytes: 5)), true) })
        let engine = DisklesslyEngine(config: RuntimeConfig.environment([:]))
        XCTAssertEqual(scanner.snapshot()["state"] as? String, "idle")
        XCTAssertTrue(scanner.start(engine: engine))
        XCTAssertFalse(scanner.start(engine: engine), "a second scan does not start while one runs")
        XCTAssertEqual(scanner.snapshot()["state"] as? String, "scanning")
        release.signal()
        let deadline = Date().addingTimeInterval(5)
        while scanner.snapshot()["state"] as? String != "ready", Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let snap = scanner.snapshot()
        XCTAssertEqual(snap["state"] as? String, "ready")
        XCTAssertEqual(snap["partial"] as? Bool, true)
        XCTAssertNotNil((snap["tree"] as? [String: Any])?["children"])
    }
}
