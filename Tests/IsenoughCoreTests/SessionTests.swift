import XCTest
import IsenoughCore
import IsenoughEngine

final class SessionTests: XCTestCase {
    func testTieringSkipsOpenRecentAndSecretFiles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-(20 * 24 * 60 * 60))
        let recent = now.addingTimeInterval(-(2 * 60 * 60))
        let cold = SessionCandidate(path: "/h/.pi/agent/sessions/a.jsonl", tool: "pi", size: 4, modified: old, open: false, preview: "hello")
        XCTAssertTrue(SessionTiering.decide(cold, now: now, coldDays: 14).cold)
        let opened = SessionCandidate(path: cold.path, tool: "pi", size: 4, modified: old, open: true, preview: "hello")
        XCTAssertEqual(SessionTiering.decide(opened, now: now, coldDays: 14).reason, "open")
        let fresh = SessionCandidate(path: cold.path, tool: "pi", size: 4, modified: recent, open: false, preview: "hello")
        XCTAssertEqual(SessionTiering.decide(fresh, now: now, coldDays: 1).reason, "modified within 24h")
        XCTAssertTrue(SessionTiering.forbidden("/h/.codex/auth.json"))
        XCTAssertTrue(SessionTiering.forbidden("/h/.claude/state.vscdb"))
        XCTAssertTrue(SessionTiering.forbidden("/h/.claude/projects/x.sqlite"))
        XCTAssertFalse(SessionTiering.forbidden("/h/.pi/agent/sessions/a.jsonl"))
        XCTAssertFalse(OpenFileProbe.isOpen(lsofStatus: 1, lsofStdout: "lsof: unsupported\n", path: "/tmp/a.jsonl"))
        XCTAssertTrue(OpenFileProbe.isOpen(lsofStatus: 0, lsofStdout: "p123\nn/tmp/a.jsonl\n", path: "/tmp/a.jsonl"))
        XCTAssertFalse(OpenFileProbe.isOpen(lsofStatus: 0, lsofStdout: "n/tmp/other.jsonl\n", path: "/tmp/a.jsonl"))
        XCTAssertEqual(SessionTiering.monthKey(old), SessionTiering.monthKey(old))
    }

    func testDryRunLeavesFilesAndApplyPacksAMonthlyArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let sessions = home.appendingPathComponent(".pi/agent/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let oldURL = sessions.appendingPathComponent("old.jsonl")
        let freshURL = sessions.appendingPathComponent("fresh.jsonl")
        let body = Data("{\"type\":\"user\",\"text\":\"pack the blender notes\"}\n".utf8)
        try body.write(to: oldURL)
        try Data("still hot\n".utf8).write(to: freshURL)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(30 * 24 * 60 * 60))], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(2 * 60 * 60))], ofItemAtPath: freshURL.path)
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        config.sessionRoots = [SessionRoot(tool: "pi", directory: sessions.path)]
        config.sessionColdDays = 14
        let backend = try LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath))
        let dry = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, isOpen: { $0 == oldURL.path ? false : false })
        XCTAssertEqual(dry.cold, [oldURL.path])
        XCTAssertFalse(dry.applied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        let openSkip = try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, isOpen: { $0 == oldURL.path })
        XCTAssertTrue(openSkip.cold.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        let applied = try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, isOpen: { _ in false })
        XCTAssertEqual(applied.cold, [oldURL.path])
        XCTAssertTrue(applied.applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
        let found = try SessionArchive.search(config: config, query: "blender")
        XCTAssertEqual(found.count, 1)
        let remote = try backend.get(found[0].archive, range: nil)
        XCTAssertFalse(remote.isEmpty)
        let restored = try SessionArchive.restore(config: config, backend: backend, query: found[0].id)
        XCTAssertEqual(restored, oldURL.path)
        XCTAssertEqual(try Data(contentsOf: oldURL), body)
        let attrs = try FileManager.default.attributesOfItem(atPath: oldURL.path)
        let restoredMtime = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(restoredMtime.timeIntervalSince1970, found[0].modified.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(try SessionArchive.search(config: config, query: "blender").isEmpty)
    }
}
