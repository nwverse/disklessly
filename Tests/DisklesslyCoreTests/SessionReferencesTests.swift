import XCTest
import Foundation
import DisklesslyCore
@testable import DisklesslyEngine
@testable import DisklesslySessions

/// The built-in reference scan (running agents, herdr's layout), the restore
/// race guard, and the side-effect-free status open. All fixtures are synthetic.
final class SessionReferencesTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_735_689_600)
    private let claudeId = "11111111-2222-4333-8444-555555555555"
    private let codexId = "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000"

    private struct Home {
        var base: URL
        var claude: String
        var codex: String
        var pi: String
        var config: RuntimeConfig
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SessionReferences.processListOverride = { [] }
        SessionReferences.herdrFileOverride = nil
        SessionTierV2.beforePlaceForTesting = nil
    }

    override func tearDownWithError() throws {
        SessionReferences.processListOverride = nil
        SessionReferences.herdrFileOverride = nil
        SessionTierV2.beforePlaceForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ body: String, daysOld: Double) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: path)
    }

    private func home() throws -> Home {
        let base = root.appendingPathComponent("a")
        let claude = base.appendingPathComponent("home/.claude/projects/-work-demo/\(claudeId).jsonl").path
        let codex = base.appendingPathComponent("home/.codex/sessions/2024/11/20/rollout-2024-11-20T10-00-00-\(codexId).jsonl").path
        let pi = base.appendingPathComponent("home/.pi/agent/sessions/plain.jsonl").path
        try write(claude, "{\"type\":\"user\",\"cwd\":\"/work/demo\",\"message\":{\"role\":\"user\",\"content\":\"synthetic prompt\"}}\n", daysOld: 40)
        try write(codex, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(codexId)\",\"cwd\":\"/work/other\"}}\n", daysOld: 50)
        try write(pi, "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"pi prompt\"}}\n", daysOld: 60)
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: base.appendingPathComponent("cache").path,
            stateDir: base.appendingPathComponent("state").path,
            mountRoot: base.appendingPathComponent("mnt").path,
            stubDir: base.appendingPathComponent("apps").path
        )
        config.sessionHome = base.appendingPathComponent("home").path
        config.sessionRoots = [
            SessionRoot(tool: "claude", directory: base.appendingPathComponent("home/.claude/projects").path),
            SessionRoot(tool: "codex", directory: base.appendingPathComponent("home/.codex/sessions").path),
            SessionRoot(tool: "pi", directory: base.appendingPathComponent("home/.pi/agent/sessions").path),
        ]
        config.sessionColdDays = 14
        return Home(base: base, claude: SessionPaths.canonical(claude), codex: SessionPaths.canonical(codex), pi: SessionPaths.canonical(pi), config: config)
    }

    private func markedRepo() throws -> LocalFolderBackend {
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        try backend.put("repo.json", data: Data("{\"schema\":\"repo/1\"}".utf8))
        return backend
    }

    private func state(_ config: RuntimeConfig, _ path: String) throws -> String? {
        let list = try SessionArchive.listSessions(config: config)
        return (list["entries"] as? [[String: Any]] ?? []).first { $0["path"] as? String == path }?["state"] as? String
    }

    // MARK: scan

    func testCommandLinesAndHerdrLayout() throws {
        let found = SessionReferences.commandLines([
            ["claude --resume \(claudeId.uppercased())", "120"],
            ["/usr/bin/sleep", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"],
            ["node", "/opt/tool/codex.js", "resume", codexId],
            ["viewer", "--file=/work/logs/kept.jsonl", "relative/other.jsonl"],
        ])
        XCTAssertEqual(found.ids, [claudeId, codexId])
        XCTAssertTrue(found.paths.contains("/work/logs/kept.jsonl"))
        XCTAssertFalse(found.paths.contains { $0.hasSuffix("other.jsonl") })

        let herdr = root.appendingPathComponent("session.json")
        try Data("{\"panes\":[{\"cmd\":\"agent\",\"session\":\"\(codexId)\",\"log\":\"\\/work\\/x\\/pane.jsonl\"}]}".utf8).write(to: herdr)
        let layout = SessionReferences.herdr(path: herdr.path)
        XCTAssertEqual(layout.ids, [codexId])
        XCTAssertTrue(layout.paths.contains("/work/x/pane.jsonl"))
        XCTAssertEqual(SessionReferences.herdr(path: root.appendingPathComponent("absent.json").path), SessionExclusions())
    }

    func testReferencedByRunningAgentAtPlanTime() throws {
        let home = try home()
        SessionReferences.processListOverride = { [["claude --resume \(self.claudeId)", "120"]] }
        let herdrDir = home.base.appendingPathComponent("home/.config/herdr")
        try FileManager.default.createDirectory(at: herdrDir, withIntermediateDirectories: true)
        try Data("{\"tabs\":[{\"path\":\"\(home.codex)\"}]}".utf8).write(to: herdrDir.appendingPathComponent("session.json"))

        let dry = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now)
        XCTAssertEqual(dry.cold, [home.pi])
        let report = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, requireRepoMarker: true)
        XCTAssertTrue(report.skipped.contains { $0.0 == home.claude && $0.1 == "referenced" })
        XCTAssertTrue(report.skipped.contains { $0.0 == home.codex && $0.1 == "referenced" })
        XCTAssertEqual(report.archived.map(\.path), [home.pi])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.claude))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
    }

    func testReferencedOnlyAfterUploadKeepsLocalFile() throws {
        let home = try home()
        var uploaded = false
        let piPath = home.pi
        SessionReferences.processListOverride = { uploaded ? [["viewer", piPath]] : [] }
        let report = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, tools: ["pi"], afterIndexCommit: { uploaded = true }, requireRepoMarker: true)
        XCTAssertEqual(report.segments.count, 1)
        XCTAssertEqual(report.archived.count, 0)
        XCTAssertTrue(report.keptLocal.contains { $0.0 == home.pi && $0.1 == "referenced" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.pi))
        XCTAssertEqual(try state(home.config, home.pi), "keptLocal")
    }

    func testProcessListingFailureDeletesNothing() throws {
        let home = try home()
        struct NoListing: Error {}
        SessionReferences.processListOverride = { throw NoListing() }
        let report = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, requireRepoMarker: true)
        XCTAssertEqual(report.archived.count, 0)
        XCTAssertEqual(report.segments.count, 3)
        XCTAssertEqual(Set(report.keptLocal.map(\.0)), [home.claude, home.codex, home.pi])
        XCTAssertTrue(report.keptLocal.allSatisfy { $0.1 == "reference check failed" })
        for path in [home.claude, home.codex, home.pi] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try state(home.config, path), "keptLocal")
        }

        // A failure that only shows at delete time keeps the rest of the run local too.
        try write(home.pi + ".2.jsonl", "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"second\"}}\n", daysOld: 60)
        var calls = 0
        SessionReferences.processListOverride = {
            calls += 1
            if calls > 1 { throw NoListing() }
            return []
        }
        let later = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        XCTAssertEqual(later.archived.count, 0)
        XCTAssertTrue(later.keptLocal.allSatisfy { $0.1 == "reference check failed" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.pi + ".2.jsonl"))
    }

    func testDashboardApplyHonoursReferences() throws {
        let home = try home()
        _ = try markedRepo()
        SessionReferences.processListOverride = { [["codex", "resume", self.codexId]] }
        let engine = DisklesslyEngine(config: home.config, secrets: MemorySecretStore())
        let report = try engine.sessionApply(tools: nil, now: now)
        XCTAssertTrue(report.skipped.contains { $0.0 == home.codex && $0.1 == "referenced" })
        XCTAssertFalse(report.archived.contains { $0.path == home.codex })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
    }

    // MARK: restore race

    func testRestoreRefusesFileThatAppearsDuringDownload() throws {
        let home = try home()
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
        let racing = Data("{\"written\":\"meanwhile\"}\n".utf8)
        SessionTierV2.beforePlaceForTesting = { destination in try? racing.write(to: URL(fileURLWithPath: destination)) }
        XCTAssertThrowsError(try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 9)
            XCTAssertTrue(String(describing: error).contains("aside before restoring"))
        }
        XCTAssertEqual(FileManager.default.contents(atPath: home.pi), racing)
        XCTAssertNotEqual(try state(home.config, home.pi), "restored")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: (home.pi as NSString).deletingLastPathComponent).filter { $0.contains("disklessly-restore") }
        XCTAssertEqual(leftovers, [])
    }

    func testRestoreWaitsForNoArchiveRun() throws {
        let home = try home()
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        var lock = FileLock(path: URL(fileURLWithPath: home.config.stateDir).appendingPathComponent("locks/sessions.lock").path)
        XCTAssertTrue(try lock.tryLock())
        XCTAssertThrowsError(try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 9)
        }
        lock.unlock()
        XCTAssertEqual(try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi).path, home.pi)
    }

    // MARK: status

    func testStatusDoesNotCreateMissingLocalRepo() throws {
        var home = try home()
        let missing = root.appendingPathComponent("unmounted/Disklessly")
        home.config.repoPath = missing.path
        let engine = DisklesslyEngine(config: home.config, secrets: MemorySecretStore())
        let status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "local") { try engine.openExistingBackend() }
        let info = try XCTUnwrap(status["backend"] as? [String: Any])
        XCTAssertEqual(info["reachable"] as? Bool, false)
        XCTAssertTrue((info["error"] as? String ?? "").contains("does not exist"))
        XCTAssertEqual(status["stateDir"] as? String, SessionPaths.canonical(home.config.stateDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unmounted").path))
        XCTAssertThrowsError(try engine.sessionApply(tools: nil, now: now)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unmounted").path))
    }
}
