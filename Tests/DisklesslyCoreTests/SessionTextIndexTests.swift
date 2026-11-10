import XCTest
import Foundation
import DisklesslyCore
@testable import DisklesslyEngine
@testable import DisklesslySessions

/// The plain-text session index (`<stateDir>/sessions/text/<entryId>.jsonl`).
/// All fixtures are synthetic.
final class SessionTextIndexTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_735_689_600)
    private let claudeId = "aaaaaaaa-1111-4222-8333-444444444444"
    private let codexId = "0199bbbb-cccc-7ddd-8eee-ffff00001111"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-textidx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: fixtures

    private let claudeBody = """
    {"type":"user","cwd":"/work/demo-app","timestamp":"2024-11-20T10:00:00.000Z","message":{"role":"user","content":"<system-reminder>synthetic reminder</system-reminder>add a health check endpoint"}}
    {"type":"assistant","timestamp":"2024-11-20T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"synthetic private reasoning"},{"type":"text","text":"I will add the endpoint."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/work/demo-app/server.go"}}]}}
    {"type":"user","timestamp":"2024-11-20T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"synthetic tool output"}]}}
    {"type":"user","isMeta":true,"message":{"role":"user","content":"synthetic meta caveat"}}
    {"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
    {"type":"user","message":{"role":"user","content":"<local-command-stdout>synthetic local output</local-command-stdout>"}}
    {"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"iVBORw0KGgo="}},{"type":"text","text":"and add a test"}]}}
    {"type":"assistant","timestamp":"2024-11-20T10:01:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Done, the endpoint answers 200."}]}}

    """

    private let codexBody = """
    {"timestamp":"2024-11-20T09:00:00.000Z","type":"session_meta","payload":{"id":"0199bbbb-cccc-7ddd-8eee-ffff00001111","cwd":"/work/other"}}
    {"timestamp":"2024-11-20T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /work/other\\nsynthetic rules"}]}}
    {"timestamp":"2024-11-20T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>synthetic</environment_context>"}]}}
    {"timestamp":"2024-11-20T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"synthetic developer text"}]}}
    {"timestamp":"2024-11-20T09:00:03.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"rename the config loader"}]}}
    {"timestamp":"2024-11-20T09:00:04.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"synthetic reasoning"}]}}
    {"timestamp":"2024-11-20T09:00:05.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"ls\\"]}","call_id":"c1"}}
    {"timestamp":"2024-11-20T09:00:06.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"synthetic listing"}}
    {"timestamp":"2024-11-20T09:00:07.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Renamed it to loadConfig."}]}}
    {"timestamp":"2024-11-20T09:00:07.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Renamed it to loadConfig."}}

    """

    private struct Home {
        var claude: String
        var codex: String
        var config: RuntimeConfig
    }

    private func write(_ path: String, _ body: String, daysOld: Double) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: path)
    }

    private func home(_ name: String) throws -> Home {
        let base = root.appendingPathComponent(name)
        let claude = base.appendingPathComponent("home/.claude/projects/-work-demo-app/\(claudeId).jsonl").path
        let codex = base.appendingPathComponent("home/.codex/sessions/2024/11/20/rollout-2024-11-20T09-00-00-\(codexId).jsonl").path
        try write(claude, claudeBody, daysOld: 40)
        try write(codex, codexBody, daysOld: 50)
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: base.appendingPathComponent("cache").path,
            stateDir: base.appendingPathComponent("state").path,
            mountRoot: base.appendingPathComponent("mnt").path,
            stubDir: base.appendingPathComponent("apps").path
        )
        config.sessionRoots = [
            SessionRoot(tool: "claude", directory: base.appendingPathComponent("home/.claude/projects").path),
            SessionRoot(tool: "codex", directory: base.appendingPathComponent("home/.codex/sessions").path),
        ]
        config.sessionColdDays = 14
        return Home(claude: SessionPaths.canonical(claude), codex: SessionPaths.canonical(codex), config: config)
    }

    private func markedRepo() throws -> LocalFolderBackend {
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        try backend.put("repo.json", data: Data("{\"schema\":\"repo/1\"}".utf8))
        return backend
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0A).map { line in
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }

    private func mode(_ path: String) throws -> Int {
        try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    private func segmentObjects() -> [String] {
        let base = root.appendingPathComponent("repo/sessions")
        guard let walker = FileManager.default.enumerator(atPath: base.path) else { return [] }
        return walker.compactMap { $0 as? String }.filter { $0.contains(".tar.zst") && !$0.hasSuffix(".json") && !$0.hasSuffix(".json.enc") }
    }

    private func listed(_ config: RuntimeConfig, tool: String) throws -> [String: Any] {
        let rows = try SessionArchive.listSessions(config: config, tool: tool)["entries"] as? [[String: Any]] ?? []
        return try XCTUnwrap(rows.first)
    }

    // MARK: tests

    func testClaudeTextIndexKeepsOnlyUserAndAssistantText() throws {
        let home = try home("claude")
        let report = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, tools: ["claude"], requireRepoMarker: true)
        XCTAssertEqual(report.archived.map(\.path), [home.claude])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.claude))
        let row = try listed(home.config, tool: "claude")
        let id = try XCTUnwrap(row["id"] as? String)
        let url = SessionTextIndex.url(stateDir: home.config.stateDir, id: id)
        XCTAssertEqual(try mode(url.path), 0o600)
        XCTAssertEqual(try mode(SessionTextIndex.directory(stateDir: home.config.stateDir).path), 0o700)

        let all = try lines(url)
        let header = all[0]
        XCTAssertEqual(header["type"] as? String, "disklessly-archive")
        XCTAssertEqual(header["version"] as? Int, 1)
        XCTAssertEqual(header["entryId"] as? String, id)
        XCTAssertEqual(header["deviceId"] as? String, row["deviceId"] as? String)
        XCTAssertEqual(header["sessionId"] as? String, claudeId)
        XCTAssertEqual(header["tool"] as? String, "claude")
        XCTAssertEqual(header["path"] as? String, home.claude)
        XCTAssertEqual(header["cwd"] as? String, "/work/demo-app")
        XCTAssertEqual(header["title"] as? String, row["title"] as? String)
        XCTAssertEqual(header["firstPrompt"] as? String, "add a health check endpoint")
        XCTAssertEqual(header["mtime"] as? String, "2024-11-22T00:00:00Z")
        XCTAssertEqual(header["archivedAt"] as? String, "2025-01-01T00:00:00Z")
        XCTAssertEqual((header["bytes"] as? NSNumber)?.intValue, claudeBody.utf8.count)
        XCTAssertEqual(header["segment"] as? String, row["segment"] as? String)
        XCTAssertFalse((header["segment"] as? String ?? "").isEmpty)

        let messages = all.dropFirst().map { "\($0["type"] as? String ?? ""): \($0["text"] as? String ?? "")" }
        XCTAssertEqual(messages, [
            "user: add a health check endpoint",
            "assistant: I will add the endpoint.",
            "user: and add a test",
            "assistant: Done, the endpoint answers 200.",
        ])
        XCTAssertEqual(all[1]["timestamp"] as? String, "2024-11-20T10:00:00.000Z")
        XCTAssertEqual(all[3]["timestamp"] as? String, "")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"type\":\"disklessly-archive\",\"version\":1,\"entryId\":"), text)
        XCTAssertTrue(text.contains("\n{\"type\":\"user\",\"timestamp\":\"2024-11-20T10:00:00.000Z\",\"text\":\"add a health check endpoint\"}\n"))
        for dropped in ["synthetic reminder", "synthetic private reasoning", "tool_use", "synthetic tool output", "meta caveat", "/clear", "synthetic local output", "iVBORw0KGgo"] {
            XCTAssertFalse(text.contains(dropped), dropped)
        }
    }

    func testCodexTextIndexKeepsOnlyUserAndAssistantText() throws {
        let home = try home("codex")
        _ = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, tools: ["codex"], requireRepoMarker: true)
        let row = try listed(home.config, tool: "codex")
        let url = SessionTextIndex.url(stateDir: home.config.stateDir, id: try XCTUnwrap(row["id"] as? String))
        let all = try lines(url)
        XCTAssertEqual(all[0]["sessionId"] as? String, codexId)
        XCTAssertEqual(all[0]["cwd"] as? String, "/work/other")
        XCTAssertEqual(all.dropFirst().map { $0["type"] as? String ?? "" }, ["user", "assistant"])
        XCTAssertEqual(all[1]["text"] as? String, "rename the config loader")
        XCTAssertEqual(all[1]["timestamp"] as? String, "2024-11-20T09:00:03.000Z")
        XCTAssertEqual(all[2]["text"] as? String, "Renamed it to loadConfig.")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for dropped in ["AGENTS.md", "environment_context", "developer", "synthetic reasoning", "function_call", "synthetic listing"] {
            XCTAssertFalse(text.contains(dropped), dropped)
        }
    }

    func testMessageAndFileCaps() throws {
        // One long message is cut at 32 KiB on a scalar boundary.
        let long = String(repeating: "é", count: 20_000) + " end"
        let body = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(long)\"}}\n"
        let found = SessionText.messages(tool: "claude", path: "/x.jsonl", data: Data(body.utf8))
        XCTAssertEqual(found.count, 1)
        XCTAssertLessThanOrEqual(found[0].text.utf8.count, SessionText.messageCap + " …".utf8.count)
        XCTAssertTrue(found[0].text.hasSuffix(" …"))
        XCTAssertFalse(found[0].text.contains("end"))
        XCTAssertGreaterThan(found[0].text.utf8.count, SessionDigest.messageCap)

        // The file keeps whole messages from the head and the tail.
        let messages = (0..<10).map { SessionDigest.Message(role: $0 % 2 == 0 ? "user" : "assistant", text: "m\($0)-" + String(repeating: "x", count: 97)) }
        let header = SessionText.Header(entryId: "abc", deviceId: "dev", sessionId: "s", tool: "claude", path: "/x.jsonl", cwd: "", title: "", firstPrompt: "", mtime: "", archivedAt: "", bytes: 1, segment: "")
        let data = try SessionText.render(header: header, messages: messages, fileCap: 450)
        let decoded = try data.split(separator: 0x0A).map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        let texts = decoded.dropFirst().map { ($0["type"] as? String ?? "") + ":" + String(($0["text"] as? String ?? "").prefix(2)) }
        XCTAssertEqual(texts, ["user:m0", "assistant:m1", "omitted:", "user:m8", "assistant:m9"])
        XCTAssertEqual((decoded[3]["bytes"] as? NSNumber)?.intValue, 600)
        let uncapped = try SessionText.render(header: header, messages: messages)
        XCTAssertEqual(uncapped.split(separator: 0x0A).count, 11)
    }

    func testTextIndexWriteFailureKeepsLocalFileAndUploadsNothing() throws {
        let home = try home("fail")
        let blocker = SessionTextIndex.directory(stateDir: home.config.stateDir)
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocker)
        let report = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, requireRepoMarker: true)
        XCTAssertEqual(report.archived.count, 0)
        XCTAssertEqual(Set(report.skipped.filter { $0.1 == "text index failed" }.map(\.0)), [home.claude, home.codex])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.claude))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.codex))
        XCTAssertEqual(segmentObjects(), [])
        XCTAssertEqual(report.segments, [])
        XCTAssertEqual((try SessionArchive.listSessions(config: home.config)["entries"] as? [Any])?.count, 0)
    }

    func testStatusReportsTextDirAndCount() throws {
        let home = try home("status")
        let backend = try markedRepo()
        var status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "local") { backend }
        XCTAssertEqual((status["textFiles"] as? NSNumber)?.intValue, 0)
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, requireRepoMarker: true)
        status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "local") { backend }
        XCTAssertEqual((status["textFiles"] as? NSNumber)?.intValue, 2)
        let dir = try XCTUnwrap(status["textDir"] as? String)
        XCTAssertTrue(dir.hasPrefix("/"))
        XCTAssertEqual(SessionPaths.canonical(dir), SessionPaths.canonical(SessionTextIndex.directory(stateDir: home.config.stateDir).path))
    }

    func testRestoreKeepsTextFile() throws {
        let home = try home("restore")
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["claude"], requireRepoMarker: true)
        let id = try XCTUnwrap(try listed(home.config, tool: "claude")["id"] as? String)
        let restored = try SessionArchive.restoreSession(config: home.config, backend: backend, query: id, requireRepoMarker: true)
        XCTAssertEqual(restored.path, home.claude)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.claude))
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionTextIndex.url(stateDir: home.config.stateDir, id: id).path))
    }
}
