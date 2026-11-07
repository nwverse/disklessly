import XCTest
import Foundation
import DisklesslyCore
@testable import DisklesslyEngine
@testable import DisklesslySessions

/// Broader agent discovery, the per-agent plan, the transcript digest, and the
/// schema 3 index. Every test works in a temporary home.
final class SessionScanTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var oldDate: Date { now.addingTimeInterval(-(40 * 24 * 60 * 60)) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-scan-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func put(_ relative: String, _ body: String, modified: Date? = nil) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified ?? oldDate], ofItemAtPath: url.path)
        return SessionPaths.canonical(url.path)
    }

    private func makeConfig() -> RuntimeConfig {
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        config.sessionHome = home.path
        config.sessionColdDays = 14
        return config
    }

    // MARK: discovery

    func testDefaultRootsFindEveryAgentLayout() throws {
        let expected: [String: String] = [
            try put(".claude/projects/-Users-me-app/a1.jsonl", "{}\n"): "claude",
            try put(".claude/projects/-Users-me-app/a1/subagents/agent-1.jsonl", "{}\n"): "claude",
            try put(".codex/sessions/2026/01/02/rollout-1.jsonl", "{}\n"): "codex",
            try put(".codex/archived_sessions/rollout-0.jsonl", "{}\n"): "codex",
            try put(".pi/agent/sessions/--Users-me--/1_x.jsonl", "{}\n"): "pi",
            try put(".omp/agent/sessions/--Users-me--/1_y.jsonl", "{}\n"): "omp",
            try put(".gemini/tmp/abc123/chats/session-1.json", "{\"messages\":[]}"): "gemini",
            try put(".factory/sessions/-Users-me/s1.jsonl", "{}\n"): "factory",
            try put(".qwen/projects/p/chats/q1.jsonl", "{}\n"): "qwen",
            try put(".qwen/tmp/h/chats/session-2.json", "{}"): "qwen",
            try put(".kimi/sessions/w/s/wire.jsonl", "{}\n"): "kimi",
            try put(".kimi-code/sessions/w/s/agents/a/wire.jsonl", "{}\n"): "kimi",
            try put(".copilot/session-state/s1/events.jsonl", "{}\n"): "copilot",
            try put(".local/share/goose/sessions/g1.jsonl", "{}\n"): "goose",
            try put(".grok/sessions/g/updates.jsonl", "{}\n"): "grok",
            try put(".cursor/projects/Users-me/agent-transcripts/u1/u1.jsonl", "{}\n"): "cursor",
            try put(".openclaw/agents/alice/sessions/o1.jsonl", "{}\n"): "openclaw",
        ]
        // Not transcripts: wrong suffix, outside the required folder, settings, secrets, SQLite.
        try put(".claude/projects/-Users-me-app/a1/custom-title.json", "{}")
        try put(".claude.json", "{}")
        try put(".claude/.credentials.json", "{}")
        try put(".codex/auth.json", "{}")
        try put(".codex/state_5.sqlite", "x")
        try put(".gemini/tmp/abc123/logs.json", "[]")
        try put(".gemini/tmp/abc123/chats/session-1.json.tmp", "{}")
        try put(".factory/sessions/-Users-me/s1.settings.json", "{}")
        try put(".kimi/sessions/w/s/state.json", "{}")
        try put(".cursor/projects/Users-me/other/notes.jsonl", "{}\n")
        try put(".cursor/extensions/ext/package.jsonl", "{}\n")
        try put(".local/share/goose/sessions/sessions.db", "x")
        let excludedButListed = [
            try put(".pi/agent/sessions/--Users-me--/auth-token.jsonl", "{}\n"),
            try put(".qwen/tmp/h/chats/session-2.meta.json", "{}"),
        ]

        let roots = SessionRoot.defaults(home: SessionPaths.canonical(home.path), platform: .macOS)
        let found = try SessionArchive.scan(roots: roots, isOpen: { _ in false })
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0.tool) })
        for (path, tool) in expected {
            XCTAssertEqual(byPath[path], tool, path)
        }
        let unexpected = Set(byPath.keys).subtracting(expected.keys).subtracting(excludedButListed)
        XCTAssertEqual(unexpected, [])
        for path in excludedButListed {
            XCTAssertFalse(SessionTiering.decide(found.first { $0.path == path }!, now: now, coldDays: 14).cold, path)
        }

        // Linux has no ~/Library and adds Claude Code's XDG folder.
        let linux = SessionRoot.defaults(home: "/home/u", platform: .linux)
        XCTAssertFalse(linux.contains { $0.directory.contains("/Library/") })
        XCTAssertTrue(linux.contains { $0.tool == "claude" && $0.directory == "/home/u/.config/claude-code/projects" })
        XCTAssertTrue(SessionRoot.defaults(home: "/Users/u", platform: .macOS).allSatisfy { !$0.directory.contains("claude-code-sessions") })
    }

    func testOverlappingRootsListAFileOnce() throws {
        let path = try put("sessions/a/one.jsonl", "{}\n")
        let roots = [
            SessionRoot(tool: "pi", directory: home.appendingPathComponent("sessions").path),
            SessionRoot(tool: "other", directory: home.appendingPathComponent("sessions/a").path),
        ]
        let found = try SessionArchive.scan(roots: roots, isOpen: { _ in false })
        XCTAssertEqual(found.map(\.path), [path])
        XCTAssertEqual(found.map(\.tool), ["pi"])
    }

    func testConfiguredRootsStillReplaceDefaultsAndDecodeOldConfig() throws {
        let legacy = Data(#"{"tool":"pi","directory":"/x","suffix":".jsonl"}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionRoot.self, from: legacy)
        XCTAssertEqual(decoded.allSuffixes, [".jsonl"])
        XCTAssertNil(decoded.requireComponent)
        let multi = SessionRoot(tool: "x", directory: "/x", suffix: ".jsonl", suffixes: [".json", ".jsonl"])
        XCTAssertEqual(multi.allSuffixes, [".jsonl", ".json"])

        try put(".pi/agent/sessions/a.jsonl", "{}\n")
        let custom = try put("elsewhere/b.json", "{}")
        var config = makeConfig()
        config.sessionRoots = [SessionRoot(tool: "mine", directory: home.appendingPathComponent("elsewhere").path, suffix: ".json")]
        let plan = try SessionArchive.plan(config: config, now: now)
        XCTAssertEqual(plan.tools.map(\.tool), ["mine"])
        XCTAssertEqual(plan.tool("mine")?.files, 1)
        XCTAssertEqual(try SessionArchive.tier(config: config, backend: LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath)), now: now).cold, [custom])
    }

    func testExclusionList() {
        let blocked = [
            "/h/.claude.json", "/h/.claude/.credentials.json", "/h/.codex/auth.json", "/h/.pi/agent/auth.json",
            "/h/.codex/state_5.sqlite", "/h/.codex/logs_2.sqlite-wal", "/h/.codex/logs_2.sqlite-shm", "/h/x/state.vscdb",
            "/h/x/sessions.db", "/h/s/oauth_tokens.json", "/h/s/my-credentials.jsonl", "/h/s/a.settings.json", "/h/s/a.meta.json",
            "/h/s/a.json.tmp", "/h/s/notes.md", "/h/s/settings.json", "/h/s/.hidden.jsonl", "/h/s/a.jsonl.disklessly-deleting-1234",
        ]
        for path in blocked { XCTAssertTrue(SessionTiering.forbidden(path), path) }
        let allowed = ["/h/.claude/projects/p/abc.jsonl", "/h/.gemini/tmp/x/chats/session-1.json", "/h/.codex/sessions/rollout-1.jsonl"]
        for path in allowed { XCTAssertFalse(SessionTiering.forbidden(path), path) }
    }

    // MARK: plan

    func testPlanCountsPerAgent() throws {
        let fresh = now.addingTimeInterval(-3600)
        let middle = now.addingTimeInterval(-(5 * 24 * 60 * 60))
        let oldest = now.addingTimeInterval(-(90 * 24 * 60 * 60))
        try put(".claude/projects/p/cold1.jsonl", String(repeating: "a", count: 100), modified: oldest)
        try put(".claude/projects/p/cold2.jsonl", String(repeating: "b", count: 50))
        try put(".claude/projects/p/warm.jsonl", String(repeating: "c", count: 30), modified: middle)
        try put(".claude/projects/p/hot.jsonl", String(repeating: "d", count: 20), modified: fresh)
        let open = try put(".claude/projects/p/open.jsonl", String(repeating: "e", count: 10))
        try put(".claude/projects/p/big.jsonl", String(repeating: "f", count: 2_000))
        try put(".codex/auth.json", "{}")
        try put(".codex/sessions/r.jsonl", String(repeating: "g", count: 7))
        var config = makeConfig()
        config.sessionMaxFileBytes = 1_000

        let plan = try SessionArchive.plan(config: config, now: now, openAmong: { Set($0.filter { $0 == open }) })
        let claude = try XCTUnwrap(plan.tool("claude"))
        XCTAssertEqual(claude.files, 6)
        XCTAssertEqual(claude.bytes, 100 + 50 + 30 + 20 + 10 + 2_000)
        XCTAssertEqual(claude.coldFiles, 2)
        XCTAssertEqual(claude.coldBytes, 150)
        XCTAssertEqual(claude.openFiles, 1)
        XCTAssertEqual(claude.tooLargeFiles, 1)
        XCTAssertEqual(claude.tooLargeBytes, 2_000)
        XCTAssertEqual(claude.oldest, oldest)
        XCTAssertEqual(claude.newest, fresh)
        let codex = try XCTUnwrap(plan.tool("codex"))
        XCTAssertEqual(codex.files, 1)
        XCTAssertEqual(codex.coldBytes, 7)
        XCTAssertEqual(plan.coldFiles, 3)
        XCTAssertEqual(plan.tool("gemini")?.files, 0)
        XCTAssertEqual(plan.tool("gemini")?.presentRoots, [])

        let days3 = try SessionArchive.plan(config: config, now: now, coldDays: 3, openAmong: { Set($0.filter { $0 == open }) })
        XCTAssertEqual(days3.tool("claude")?.coldFiles, 3)

        let json = plan.jsonObject()
        XCTAssertEqual((json["days"] as? NSNumber)?.intValue, 14)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let row = try XCTUnwrap(tools.first { $0["tool"] as? String == "claude" })
        XCTAssertEqual(row["label"] as? String, "Claude Code")
        XCTAssertEqual((row["coldBytes"] as? NSNumber)?.intValue, 150)
        XCTAssertEqual((row["hotFiles"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual(row["present"] as? Bool, true)
        XCTAssertNotNil(row["oldest"] as? String)
        XCTAssertNil(tools.first { $0["tool"] as? String == "gemini" }?["oldest"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        // Planning writes nothing.
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.stateDir))
    }

    func testApplyLimitedToSelectedToolsWritesDigest() throws {
        let claudeBody = """
        {"type":"user","message":{"role":"user","content":"rename the blender addon"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Renamed it to quickpack."}]}}

        """
        let claudePath = try put(".claude/projects/p/c.jsonl", claudeBody)
        let piPath = try put(".pi/agent/sessions/x/p.jsonl", "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"pi only\"}}\n")
        let config = makeConfig()
        let backend = try LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath))

        XCTAssertThrowsError(try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, tools: [])) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }
        XCTAssertThrowsError(try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, tools: ["nope"])) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }

        let report = try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, tools: ["claude"])
        XCTAssertEqual(report.cold, [claudePath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: piPath))

        let database = try SessionIndexDB(stateDir: config.stateDir)
        let row = try XCTUnwrap(database.allEntries().first)
        XCTAssertEqual(row.digest, "**User:** rename the blender addon\n\n**Assistant:** Renamed it to quickpack.")
        let markdown = try String(contentsOf: SessionArchive.digestURL(config: config, id: row.id), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Renamed it to quickpack."))
        XCTAssertTrue(markdown.contains(claudePath))
        XCTAssertEqual(try SessionArchive.search(config: config, query: "quickpack").map(\.path), [claudePath])
        XCTAssertEqual(try database.search(query: "quickpack", limit: 5), [row.id])

        // The archived bytes are the original transcript, not the digest.
        let restored = try SessionArchive.restore(config: config, backend: backend, query: claudePath)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: restored), encoding: .utf8), claudeBody)
    }

    // MARK: digest

    func testClaudeDigestKeepsPromptsAndFinalAnswers() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta caveat"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the build <system-reminder>secret noise</system-reminder>"},{"type":"image","source":{"type":"base64","data":"AAAA"}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"error: boom"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed the missing import."}]}}"#,
            #"{"type":"summary","summary":"x"}"#,
            "not json",
        ]
        let digest = SessionDigest.digest(tool: "claude", path: "/x.jsonl", data: Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(digest, "**User:** fix the build\n\n**Assistant:** Fixed the missing import.")
    }

    func testCodexDigest() {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s","cwd":"/x"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"dev rules"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /x"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<external_apps_open_page>{}</external_apps_open_page>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"add a plan api"}]}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"zzz"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"ok"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working on it."}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added sessionPlan."}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"add a plan api"}}"#,
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertEqual(SessionDigest.detect(tool: "custom", path: "/r.jsonl", data: data), .codex)
        XCTAssertEqual(SessionDigest.digest(tool: "codex", path: "/r.jsonl", data: data), "**User:** add a plan api\n\n**Assistant:** Added sessionPlan.")
        let eventsOnly = Data([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"old style"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"answer"}}"#,
        ].joined(separator: "\n").utf8)
        XCTAssertEqual(SessionDigest.digest(tool: "codex", path: "/r.jsonl", data: eventsOnly), "**User:** old style\n\n**Assistant:** answer")
    }

    func testPiDigest() {
        let lines = [
            #"{"type":"session","version":3,"id":"s","cwd":"/x"}"#,
            #"{"type":"message","message":{"role":"system","content":"You are pi"}}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"list files"}]}}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."},{"type":"toolCall","name":"ls"}]}}"#,
            #"{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"a b c"}]}}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Three files."}]}}"#,
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertEqual(SessionDigest.detect(tool: "custom", path: "/p.jsonl", data: data), .pi)
        XCTAssertEqual(SessionDigest.digest(tool: "pi", path: "/p.jsonl", data: data), "**User:** list files\n\n**Assistant:** Three files.")
    }

    func testGeminiDigest() {
        let json = #"""
        {"sessionId":"s","messages":[
          {"type":"user","content":"explain the cache"},
          {"type":"gemini","content":"","toolCalls":[{"name":"read_file"}]},
          {"type":"info","content":"Request cancelled"},
          {"type":"gemini","content":[{"text":"It is an LRU."}]}
        ]}
        """#
        let data = Data(json.utf8)
        XCTAssertEqual(SessionDigest.detect(tool: "custom", path: "/s.json", data: data), .gemini)
        XCTAssertEqual(SessionDigest.digest(tool: "gemini", path: "/s.json", data: data), "**User:** explain the cache\n\n**Assistant:** It is an LRU.")
    }

    func testGenericDigest() {
        let lines = [
            #"{"role":"user","message":{"content":[{"type":"text","text":"cursor prompt"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"tool_use","text":"skip me"},{"type":"text","text":"cursor answer"}]}}"#,
            #"{"type":"turn_ended","status":"ok"}"#,
            #"{"role":"user","content":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg== look"}"#,
        ]
        let digest = SessionDigest.digest(tool: "cursor", path: "/c.jsonl", data: Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(digest, "**User:** cursor prompt\n\n**Assistant:** cursor answer\n\n**User:** [binary] look")
    }

    func testDigestFallsBackToGenericWhenTheMappedFormatFindsNothing() {
        // Claude-shaped records under a tool mapped to the pi extractor.
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"droid prompt"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"droid answer"}]}}"#,
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertTrue(SessionDigest.messages(format: .pi, data: data).isEmpty)
        XCTAssertEqual(SessionDigest.digest(tool: "factory", path: "/f.jsonl", data: data), "**User:** droid prompt\n\n**Assistant:** droid answer")
    }

    func testDigestCapKeepsHeadAndTailOnScalarBoundaries() {
        var lines: [String] = []
        for index in 0..<400 {
            lines.append(#"{"type":"user","message":{"role":"user","content":"第\#(index)个问题：压缩成短文本"}}"#)
            lines.append(#"{"type":"assistant","message":{"role":"assistant","content":"回答\#(index)"}}"#)
        }
        let data = Data(lines.joined(separator: "\n").utf8)
        let digest = SessionDigest.digest(tool: "claude", path: "/x.jsonl", data: data, cap: 2_048)
        XCTAssertLessThanOrEqual(digest.utf8.count, 2_048)
        XCTAssertTrue(digest.hasPrefix("**User:** 第0个问题"))
        XCTAssertTrue(digest.hasSuffix("回答399"))
        XCTAssertTrue(digest.contains("bytes omitted"))
        XCTAssertFalse(digest.contains("\u{FFFD}"))
        XCTAssertEqual(SessionDigest.digest(tool: "claude", path: "/x.jsonl", data: data, cap: 2_048), digest)

        let long = String(repeating: "长", count: 5_000)
        let one = SessionDigest.digest(tool: "claude", path: "/x.jsonl", data: Data(#"{"type":"user","message":{"role":"user","content":"\#(long)"}}"#.utf8))
        XCTAssertLessThanOrEqual(one.utf8.count, SessionDigest.messageCap + 32)
        XCTAssertFalse(one.contains("\u{FFFD}"))
    }

    // MARK: schema

    func testSchemaTwoIndexMigratesToThree() throws {
        let stateDir = root.appendingPathComponent("state")
        let directory = stateDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite").path
        let v2 = """
        CREATE TABLE segments(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, device_id TEXT NOT NULL, tool TEXT NOT NULL, created_at TEXT NOT NULL, bytes INTEGER NOT NULL, codec TEXT NOT NULL, encrypted INTEGER NOT NULL, key_id TEXT);
        CREATE TABLE entries(id TEXT PRIMARY KEY, segment_id TEXT, legacy_archive TEXT, member TEXT NOT NULL, device_id TEXT NOT NULL, tool TEXT NOT NULL, path TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, ino INTEGER, preview TEXT NOT NULL, archived_at TEXT NOT NULL, state TEXT NOT NULL);
        CREATE INDEX entries_path ON entries(path);
        CREATE VIRTUAL TABLE entries_fts USING fts5(id UNINDEXED, path, preview);
        INSERT INTO entries VALUES('old1', NULL, NULL, 'm/old1.jsonl', 'dev', 'pi', '/h/old.jsonl', 'ab', 3, 1, NULL, 'oldpreviewword', '2025-01-01T00:00:00Z', 'archived');
        INSERT INTO entries_fts(id, path, preview) VALUES('old1', '/h/old.jsonl', 'oldpreviewword');
        PRAGMA user_version = 2;
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, v2]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let database = try SessionIndexDB(stateDir: stateDir.path)
        XCTAssertEqual(try database.userVersion(), 3)
        XCTAssertEqual(try database.allEntries().map(\.digest), [""])
        XCTAssertEqual(try database.search(query: "oldpreviewword", limit: 5), ["old1"])
        try database.insert(entries: [SessionEntryRow(id: "new1", segmentId: nil, legacyArchive: nil, member: "m/new1.jsonl", deviceId: "dev", tool: "claude", path: "/h/new.jsonl", sha256: "cd", size: 4, mtimeNs: 2, ino: nil, preview: "p", archivedAt: "2026-01-01T00:00:00Z", state: "archived", digest: "**User:** zebracorn question")])
        XCTAssertEqual(try database.search(query: "zebracorn", limit: 5), ["new1"])
        database.ftsAvailable = false
        XCTAssertEqual(try database.search(query: "zebracorn", limit: 5), ["new1"])
        XCTAssertEqual(try database.digest(id: "new1"), "**User:** zebracorn question")

        // Opening again is a no-op at version 3.
        let reopened = try SessionIndexDB(stateDir: stateDir.path)
        XCTAssertEqual(try reopened.userVersion(), 3)
        XCTAssertEqual(try reopened.allEntries().count, 2)
    }
}
