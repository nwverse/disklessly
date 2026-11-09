import XCTest
@testable import DisklesslyEngine

final class BigItemsTests: XCTestCase {
    func testCleanEmptiesARebuildableCacheButKeepsTheFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-big-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/go-build")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("00"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("00/a"))
        try Data(repeating: 2, count: 4096).write(to: cache.appendingPathComponent("trim.txt"))
        let done = try BigItems.clean("cache-go-build", home: home.path)
        XCTAssertEqual(done.items, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testUnknownCacheIsRefused() {
        XCTAssertThrowsError(try BigItems.clean("cache-nope", home: "/nonexistent"))
        XCTAssertTrue(UsageCleanup.known("cache-npm"))
        XCTAssertTrue(UsageCleanup.known(UsageCleanup.derivedData))
        XCTAssertFalse(UsageCleanup.known("rm-rf"))
    }

    func testLargeChildrenSortsAndFilters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-big-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, size) in [("small", 1024), ("big", 256 * 1024), ("bigger", 512 * 1024)] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: folder.appendingPathComponent("f"))
        }
        let found = BigItems.largeChildren(of: root, minimum: 100 * 1024, deadline: Date().addingTimeInterval(30))
        XCTAssertEqual(found.map(\.0.lastPathComponent), ["bigger", "big"])
    }
}
