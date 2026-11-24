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

    func testSystemPartsSplitTheLeftoverAndKeepActions() {
        var i = UsageInputs(totalBytes: 1000, freeBytes: 300)
        i.personal = [.init(name: "Documents", bytes: 100)]
        i.system = [
            .init(name: "macOS", bytes: 200, key: "macos"),
            .init(name: "Homebrew", bytes: 50, key: "homebrew", action: UsageCleanup.homebrew),
        ]
        let tree = UsageMap.assemble(i)
        let system = tree.children.first { $0.key == "system" }!
        // used 700 - measured 100 = 600: 200 + 50 measured, 350 not measured.
        XCTAssertEqual(system.bytes, 600)
        XCTAssertEqual(system.children.compactMap(\.key), ["macos", "homebrew", "unmeasured"])
        XCTAssertEqual(system.children.first { $0.key == "unmeasured" }?.bytes, 350)
        XCTAssertEqual(system.children.first { $0.key == "homebrew" }?.action, UsageCleanup.homebrew)
        XCTAssertEqual(system.children.first { $0.key == "homebrew" }?.jsonObject()["action"] as? String, "brew-cleanup")
    }

    func testWithoutSystemPartsTheBoxStaysWhole() {
        let tree = UsageMap.assemble(UsageInputs(totalBytes: 1000, freeBytes: 400))
        let system = tree.children.first { $0.key == "system" }!
        XCTAssertEqual(system.bytes, 600)
        XCTAssertTrue(system.children.isEmpty)
    }

    func testModifiedIsTheNewestTimeUnderABox() throws {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        var i = UsageInputs(totalBytes: 1000, freeBytes: 100)
        var movies = UsageInputs.Entry(name: "Movies", bytes: 300, kind: .personal)
        movies.path = "/Users/me/Movies"
        movies.modified = old
        var code = UsageInputs.Entry(name: "code", bytes: 200, kind: .personal)
        code.path = "/Users/me/code"
        code.modified = new
        i.personal = [movies, code]
        let personal = try XCTUnwrap(UsageMap.assemble(i).children.first { $0.key == "personal" })
        XCTAssertEqual(personal.modified, new, "a group takes its newest child")
        XCTAssertEqual(personal.children.first { $0.name == "Movies" }?.jsonObject()["modified"] as? NSNumber, NSNumber(value: 1_600_000_000))
    }

    func testDirectoryScanCarriesEachEntrysOwnModificationTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-usage-mtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64 * 1024).write(to: folder.appendingPathComponent("inside.bin"))
        let file = root.appendingPathComponent("file.bin")
        try Data(repeating: 2, count: 64 * 1024).write(to: file)
        let fileTime = Date(timeIntervalSince1970: 1_650_000_000)
        let folderTime = Date(timeIntervalSince1970: 1_550_000_000)
        try FileManager.default.setAttributes([.modificationDate: fileTime], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: folderTime], ofItemAtPath: folder.path)
        let children = UsageMap.scanDirectory(root.path) { _ in nil }
        let fileNode = try XCTUnwrap(children.first { $0.name == "file.bin" })
        let folderNode = try XCTUnwrap(children.first { $0.name == "Folder" })
        XCTAssertEqual(fileNode.modified?.timeIntervalSince1970 ?? 0, fileTime.timeIntervalSince1970, accuracy: 1)
        // du sizes the folder, so its age is its own mtime, not that of the file inside.
        XCTAssertEqual(folderNode.modified?.timeIntervalSince1970 ?? 0, folderTime.timeIntervalSince1970, accuracy: 1)
    }

    func testOffloadedCountComesFromOriginPaths() throws {
        var i = UsageInputs(totalBytes: 1000, freeBytes: 100)
        var movies = UsageInputs.Entry(name: "Movies", bytes: 300, kind: .personal)
        movies.path = "/Users/me/Movies"
        var code = UsageInputs.Entry(name: "code", bytes: 200, kind: .personal)
        code.path = "/Users/me/code"
        i.personal = [movies, code]
        i.apps = [.init(name: "Krita", bundleBytes: 1, path: "/Applications/Krita.app", offloaded: true)]
        let tree = UsageMap.countOffloaded(UsageMap.assemble(i), originPaths: [
            "/Users/me/Movies/Raw", "/Users/me/Movies/2019/clip.mov", "/Users/me/Moviesish", "/Applications/Krita.app",
        ])
        let personal = try XCTUnwrap(tree.children.first { $0.key == "personal" })
        XCTAssertEqual(personal.children.first { $0.name == "Movies" }?.offloadedCount, 2, "a sibling with the same prefix does not count")
        XCTAssertEqual(personal.children.first { $0.name == "code" }?.offloadedCount, 0)
        XCTAssertEqual(personal.offloadedCount, 2, "a group without a path sums its children")
        XCTAssertEqual(tree.children.first { $0.key == "apps" }?.offloadedCount, 1, "a stub app counts its own origin")
        XCTAssertEqual((personal.children.first { $0.name == "Movies" }?.jsonObject()["offloadedCount"] as? NSNumber)?.intValue, 2)
        XCTAssertNil(personal.children.first { $0.name == "code" }?.jsonObject()["offloadedCount"])
    }
}
