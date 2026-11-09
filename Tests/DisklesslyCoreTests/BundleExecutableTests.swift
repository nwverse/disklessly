import XCTest
@testable import DisklesslyCore

final class BundleExecutableTests: XCTestCase {
    func testMissingExecutableKeyFallsBackToTheBundleNamedBinary() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("exec-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Muse.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: macOS.appendingPathComponent("Muse"))
        XCTAssertEqual(BundleExecutable.name(info: [:], app: app), "Muse")
        XCTAssertEqual(BundleExecutable.name(info: ["CFBundleExecutable": "Declared"], app: app), "Declared")
        XCTAssertEqual(BundleExecutable.name(info: ["CFBundleExecutable": ""], app: app), "Muse")
    }

    func testNoBinaryAtAllGivesAnEmptyNameNotADirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("exec-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Empty.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        XCTAssertEqual(BundleExecutable.name(info: [:], app: app), "")
    }

    func testPackCopyNamedDifferentlyStillFindsTheBinaryByBundleName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("exec-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("checked-Muse.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: macOS.appendingPathComponent("Muse"))
        try Data("helper".utf8).write(to: macOS.appendingPathComponent("EndoCrashpadHandler"))
        XCTAssertEqual(BundleExecutable.name(info: ["CFBundleName": "Muse"], app: app), "Muse")
    }
}

final class FoldedRecommendTests: XCTestCase {
    func testBelowThresholdAppsAreFoldedNotHiddenAndOrderedByUseAndSize() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let big = RecommendApp(path: "/Applications/Big.app", name: "Big", bundleId: "x.big", sizeBytes: 500 * 1024 * 1024, lastUsed: now, useCount: 1)
        let small = RecommendApp(path: "/Applications/Small.app", name: "Small", bundleId: "x.small", sizeBytes: 10 * 1024 * 1024, lastUsed: now, useCount: 900)
        let tiny = RecommendApp(path: "/Applications/Tiny.app", name: "Tiny", bundleId: "x.tiny", sizeBytes: 5 * 1024 * 1024, lastUsed: now, useCount: 2)
        let report = RecommendRanking.rank([big, small, tiny], options: RecommendOptions(now: now))
        XCTAssertFalse(report.recommendations.contains { $0.name == "Small" || $0.name == "Tiny" })
        // Big is over the threshold but used today: folded too, never hidden.
        XCTAssertEqual(report.folded.map(\.name).sorted(), ["Big", "Small", "Tiny"])
        XCTAssertTrue(report.folded.allSatisfy { $0.folded })
        XCTAssertEqual(report.folded.first(where: { $0.name == "Small" })?.useCount, 900)
    }

    func testRunningAppsAreFoldedNotHidden() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let running = RecommendApp(path: "/Applications/Busy.app", name: "Busy", bundleId: "x.busy", sizeBytes: 900 * 1024 * 1024, lastUsed: nil, running: true)
        let report = RecommendRanking.rank([running], options: RecommendOptions(now: now))
        XCTAssertTrue(report.recommendations.isEmpty)
        XCTAssertEqual(report.folded.map(\.name), ["Busy"])
    }
}
