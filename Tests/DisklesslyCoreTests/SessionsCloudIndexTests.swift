import XCTest
import Foundation
import DisklesslyCore
@testable import DisklesslyEngine
@testable import DisklesslySessions

/// `sessions list`, `status`, `--exclude-from`, the partitioned segment layout,
/// the repo-marker guard, and schema 4. All fixtures are synthetic.
final class SessionsCloudIndexTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_735_689_600)
    private let claudeId = "11111111-2222-4333-8444-555555555555"
    private let codexId = "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-cloudidx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: fixtures

    private struct Home {
        var claude: String
        var codex: String
        var pi: String
        var config: RuntimeConfig
    }

    private func claudeBody(cwd: String, prompt: String) -> String {
        """
        {"type":"user","cwd":"\(cwd)","message":{"role":"user","content":"\(prompt)"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}

        """
    }

    private func codexBody(cwd: String, prompt: String) -> String {
        """
        {"type":"session_meta","payload":{"id":"\(codexId)","cwd":"\(cwd)"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>synthetic</environment_context>"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\(prompt)"}]}}

        """
    }

    private func write(_ path: String, _ body: String, daysOld: Double) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: path)
    }

    private func home(_ name: String) throws -> Home {
        let base = root.appendingPathComponent(name)
        let claudeDir = base.appendingPathComponent("home/.claude/projects/-work-demo-app")
        let codexDir = base.appendingPathComponent("home/.codex/sessions/2024/11/20")
        let piDir = base.appendingPathComponent("home/.pi/agent/sessions")
        let claude = claudeDir.appendingPathComponent("\(claudeId).jsonl").path
        let codex = codexDir.appendingPathComponent("rollout-2024-11-20T10-00-00-\(codexId).jsonl").path
        let pi = piDir.appendingPathComponent("plain.jsonl").path
        try write(claude, claudeBody(cwd: "/work/demo-app", prompt: "add a health check endpoint"), daysOld: 40)
        try write(codex, codexBody(cwd: "/work/other", prompt: "rename the config loader"), daysOld: 50)
        try write(pi, "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"pi prompt\"}}\n", daysOld: 60)
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
            SessionRoot(tool: "pi", directory: piDir.path),
        ]
        config.sessionColdDays = 14
        return Home(claude: SessionPaths.canonical(claude), codex: SessionPaths.canonical(codex), pi: SessionPaths.canonical(pi), config: config)
    }

    /// A repo with its `repo.json` marker, as `init` leaves it.
    private func markedRepo(_ name: String = "repo") throws -> LocalFolderBackend {
        let backend = try LocalFolderBackend(root: root.appendingPathComponent(name))
        try backend.put("repo.json", data: Data("{\"schema\":\"repo/1\"}".utf8))
        return backend
    }

    private func entries(_ object: [String: Any]) -> [[String: Any]] {
        object["entries"] as? [[String: Any]] ?? []
    }

    // MARK: list

    func testListReportsEveryContractField() throws {
        let home = try home("a")
        let backend = try markedRepo()
        let report = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, requireRepoMarker: true)
        XCTAssertEqual(report.archived.count, 3)
        XCTAssertEqual(report.uploadedBytes, report.archived.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(Set(report.archived.map(\.sessionId)), [claudeId, codexId, "plain"])
        let json = report.jsonObject()
        XCTAssertNotNil(json["uploadedBytes"] as? NSNumber)
        XCTAssertEqual((json["archived"] as? [[String: Any]])?.count, 3)

        let listed = try SessionArchive.listSessions(config: home.config)
        XCTAssertEqual(listed["ok"] as? Bool, true)
        let deviceId = try XCTUnwrap(listed["deviceId"] as? String)
        let rows = entries(listed)
        XCTAssertEqual(rows.map { $0["path"] as? String }, [home.claude, home.codex, home.pi], "newest mtime first")
        let claude = rows[0]
        let keys = ["id", "deviceId", "local", "tool", "path", "sessionId", "cwd", "project", "month", "mtime", "archivedAt", "bytes", "state", "title", "firstPrompt", "segment", "encrypted"]
        XCTAssertEqual(Set(claude.keys), Set(keys))
        XCTAssertEqual((claude["id"] as? String)?.count, 12)
        XCTAssertEqual(claude["deviceId"] as? String, deviceId)
        XCTAssertEqual(claude["local"] as? Bool, true)
        XCTAssertEqual(claude["tool"] as? String, "claude")
        XCTAssertEqual(claude["sessionId"] as? String, claudeId)
        XCTAssertEqual(claude["cwd"] as? String, "/work/demo-app")
        XCTAssertEqual(claude["project"] as? String, "work-demo-app")
        XCTAssertEqual(claude["month"] as? String, "2024-11")
        XCTAssertEqual(claude["mtime"] as? String, "2024-11-22T00:00:00Z")
        XCTAssertEqual(claude["archivedAt"] as? String, "2025-01-01T00:00:00Z")
        XCTAssertEqual((claude["bytes"] as? NSNumber)?.intValue, claudeBody(cwd: "/work/demo-app", prompt: "add a health check endpoint").utf8.count)
        XCTAssertEqual(claude["state"] as? String, "archived")
        XCTAssertEqual(claude["title"] as? String, "add a health check endpoint")
        XCTAssertEqual(claude["firstPrompt"] as? String, "add a health check endpoint")
        XCTAssertEqual(claude["encrypted"] as? Bool, false)
        let segment = try XCTUnwrap(claude["segment"] as? String)
        XCTAssertTrue(segment.hasPrefix("sessions/\(deviceId)/claude/work-demo-app/2024-11/"), segment)
        XCTAssertTrue(segment.hasSuffix(".tar.zst"))

        let codex = rows[1]
        XCTAssertEqual(codex["sessionId"] as? String, codexId)
        XCTAssertEqual(codex["cwd"] as? String, "/work/other")
        XCTAssertEqual(codex["firstPrompt"] as? String, "rename the config loader")
        let pi = rows[2]
        XCTAssertEqual(pi["project"] as? String, SessionIdentity.unknownProject)
        XCTAssertEqual(pi["cwd"] as? String, "")

        XCTAssertNil(claude["digest"])
        let digested = entries(try SessionArchive.listSessions(config: home.config, includeDigest: true))
        XCTAssertTrue((digested[0]["digest"] as? String)?.contains("health check") ?? false)
        XCTAssertEqual(entries(try SessionArchive.listSessions(config: home.config, tool: "codex")).count, 1)
        XCTAssertEqual(entries(try SessionArchive.listSessions(config: home.config, limit: 2)).count, 2)
        XCTAssertEqual(entries(try SessionArchive.listSessions(config: home.config, state: "restored")).count, 0)
        XCTAssertThrowsError(try SessionArchive.listSessions(config: home.config, state: "bogus")) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }
    }

    func testListAndExcludeArgumentsParse() throws {
        let list = try SessionsArguments.parse(["list", "--state", "remote", "--tool", "codex", "--limit", "5", "--digest"])
        XCTAssertEqual(list.command, .list)
        XCTAssertEqual(list.state, "remote")
        XCTAssertEqual(list.tool, "codex")
        XCTAssertEqual(list.limit, 5)
        XCTAssertTrue(list.digest)
        XCTAssertEqual(try SessionsArguments.parse(["list"]).state, "all")
        XCTAssertThrowsError(try SessionsArguments.parse(["list", "--state", "gone"]))
        XCTAssertTrue(try SessionsArguments.parse(["status", "--check-segments"]).checkSegments)
        XCTAssertEqual(try SessionsArguments.parse(["--apply", "--exclude-from", "-"]).excludeFrom, "-")
        XCTAssertEqual(try SessionsArguments.parse(["--exclude-from", "/tmp/refs.txt", "--days", "3"]).excludeFrom, "/tmp/refs.txt")
        XCTAssertThrowsError(try SessionsArguments.parse(["--exclude-from"]))
    }

    // MARK: status

    func testStatusReachableCountsAndMissingSegments() throws {
        let home = try home("a")
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, requireRepoMarker: true)
        var status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "local", checkSegments: true) { backend }
        XCTAssertEqual(status["ok"] as? Bool, true)
        let info = try XCTUnwrap(status["backend"] as? [String: Any])
        XCTAssertEqual(info["reachable"] as? Bool, true)
        XCTAssertEqual(info["error"] as? String, "")
        XCTAssertEqual(info["id"] as? String, "default")
        XCTAssertEqual(info["type"] as? String, "local")
        XCTAssertNotNil(info["latencyMs"] as? Int)
        let counts = try XCTUnwrap(status["counts"] as? [String: Any])
        XCTAssertEqual(Set(counts.keys), ["archived", "remote", "restored", "keptLocal", "pendingDelete"])
        XCTAssertEqual((counts["archived"] as? NSNumber)?.intValue, 3)
        XCTAssertGreaterThan((status["archivedBytes"] as? NSNumber)?.intValue ?? 0, 0)
        var segments = try XCTUnwrap(status["segments"] as? [String: Any])
        XCTAssertEqual(segments["total"] as? Int, 3)
        XCTAssertEqual(segments["checked"] as? Int, 3)
        XCTAssertEqual(segments["missing"] as? [String], [])

        let gone = try XCTUnwrap(entries(try SessionArchive.listSessions(config: home.config, tool: "pi")).first?["segment"] as? String)
        try FileManager.default.removeItem(at: root.appendingPathComponent("repo").appendingPathComponent(gone))
        status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "local", checkSegments: true) { backend }
        segments = try XCTUnwrap(status["segments"] as? [String: Any])
        XCTAssertEqual(segments["missing"] as? [String], [gone])
    }

    func testStatusUnreachableStillSucceeds() throws {
        let home = try home("a")
        _ = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, requireRepoMarker: true)
        let empty = try LocalFolderBackend(root: root.appendingPathComponent("unmounted"))
        var status = try SessionArchive.sessionStatus(config: home.config, backendId: "usb", backendType: "local", checkSegments: true) { empty }
        var info = try XCTUnwrap(status["backend"] as? [String: Any])
        XCTAssertEqual(info["reachable"] as? Bool, false)
        XCTAssertTrue((info["error"] as? String ?? "").hasPrefix("repo.json is not in the backend"))
        XCTAssertTrue((info["error"] as? String ?? "").contains("disklessly init"))
        XCTAssertEqual((status["segments"] as? [String: Any])?["checked"] as? Int, 0)
        XCTAssertEqual(((status["counts"] as? [String: Any])?["archived"] as? NSNumber)?.intValue, 3)

        status = try SessionArchive.sessionStatus(config: home.config, backendId: "nas", backendType: "webdav") {
            throw DisklesslyError.backend("connection refused")
        }
        info = try XCTUnwrap(status["backend"] as? [String: Any])
        XCTAssertEqual(info["reachable"] as? Bool, false)
        XCTAssertEqual(info["error"] as? String, "connection refused")

        let started = Date()
        status = try SessionArchive.sessionStatus(config: home.config, backendId: "slow", backendType: "rclone", timeout: 0.3) {
            Thread.sleep(forTimeInterval: 3)
            return empty
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertEqual((status["backend"] as? [String: Any])?["reachable"] as? Bool, false)
    }

    // MARK: exclude-from

    func testExcludeFromByIdAndByPath() throws {
        let home = try home("a")
        let backend = try markedRepo()
        let list = SessionExclusions.parse("""
        # still referenced by a running tool
        \(claudeId)

        \(home.codex)
        """)
        XCTAssertEqual(list.ids, [claudeId])
        let dry = try SessionArchive.tier(config: home.config, backend: backend, now: now, exclusions: { list })
        XCTAssertEqual(dry.cold, [home.pi])
        XCTAssertTrue(dry.skipped.contains { $0.0 == home.claude && $0.1 == "referenced" })
        XCTAssertTrue(dry.skipped.contains { $0.0 == home.codex && $0.1 == "referenced" })

        let report = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, exclusions: { list }, requireRepoMarker: true)
        XCTAssertEqual(report.archived.map(\.path), [home.pi])
        XCTAssertTrue(report.skipped.contains { $0.0 == home.claude && $0.1 == "referenced" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.claude))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
        XCTAssertEqual(entries(try SessionArchive.listSessions(config: home.config)).map { $0["path"] as? String }, [home.pi])

        // The codex rollout's trailing UUID works as its session id too.
        XCTAssertTrue(SessionExclusions.parse(codexId.uppercased()).matches(tool: "codex", path: home.codex))
    }

    func testExcludeListIsCheckedAgainBeforeDelete() throws {
        let home = try home("a")
        let backend = try markedRepo()
        var calls = 0
        let report = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, exclusions: {
            calls += 1
            // Empty while the run picks files; the pi session is referenced by the time it would be deleted.
            return calls == 1 ? SessionExclusions() : SessionExclusions(paths: [home.pi])
        }, requireRepoMarker: true)
        XCTAssertGreaterThan(calls, 1)
        XCTAssertTrue(report.keptLocal.contains { $0.0 == home.pi && $0.1 == "referenced" })
        XCTAssertFalse(report.archived.contains { $0.path == home.pi })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.pi))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.claude))
        let pi = entries(try SessionArchive.listSessions(config: home.config, tool: "pi"))
        XCTAssertEqual(pi.first?["state"] as? String, "keptLocal")
        // The pi file was uploaded but kept local, so its size is not counted.
        XCTAssertEqual(report.uploadedBytes, report.archived.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(report.archived.count, 2)

        // Archived later, the kept-local file settles against the segment already stored.
        let objects = try segmentObjects()
        let later = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        XCTAssertEqual(later.archived.map(\.path), [home.pi])
        XCTAssertEqual(later.segments, [])
        XCTAssertEqual(try segmentObjects(), objects)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
    }

    /// Stored segment objects (not sidecars) in the test repo.
    private func segmentObjects() throws -> [String] {
        let base = root.appendingPathComponent("repo/sessions")
        guard let walker = FileManager.default.enumerator(atPath: base.path) else { return [] }
        return walker.compactMap { $0 as? String }.filter { $0.contains(".tar.zst") && !$0.hasSuffix(".json") && !$0.hasSuffix(".json.enc") }.sorted()
    }

    func testExcludedSessionIdCoversClaudeSubagents() throws {
        let home = try home("a")
        let folder = (home.claude as NSString).deletingPathExtension
        let subagent = folder + "/subagents/agent-abc.jsonl"
        try write(subagent, claudeBody(cwd: "/work/demo-app", prompt: "subagent task"), daysOld: 40)
        let byId = SessionExclusions.parse(claudeId)
        XCTAssertTrue(byId.matches(tool: "claude", path: subagent))
        XCTAssertTrue(SessionExclusions.parse(home.claude).matches(tool: "claude", path: subagent))
        XCTAssertFalse(SessionExclusions.parse(codexId).matches(tool: "claude", path: subagent))

        let report = try SessionArchive.tier(config: home.config, backend: try markedRepo(), now: now, apply: true, tools: ["claude"], exclusions: { byId }, requireRepoMarker: true)
        XCTAssertEqual(report.archived, [])
        XCTAssertTrue(report.skipped.contains { $0.0 == SessionPaths.canonical(subagent) && $0.1 == "referenced" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: subagent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.claude))
    }

    // MARK: report

    func testPendingRowsSettledByALaterRunAreReportedArchived() throws {
        let home = try home("a")
        let backend = try markedRepo()
        struct Killed: Error {}
        XCTAssertThrowsError(try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["pi"], afterIndexCommit: { throw Killed() }, requireRepoMarker: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.pi))
        XCTAssertEqual(entries(try SessionArchive.listSessions(config: home.config, state: "pendingDelete")).count, 1)

        let size = Int64(try FileManager.default.attributesOfItem(atPath: home.pi)[.size] as? NSNumber ?? 0)
        let report = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["codex"], requireRepoMarker: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
        XCTAssertEqual(Set(report.archived.map(\.path)), [home.pi, home.codex])
        XCTAssertEqual(report.archived.first { $0.path == home.pi }?.bytes, size)
        XCTAssertEqual(report.uploadedBytes, report.archived.reduce(0) { $0 + $1.bytes })
    }

    // MARK: repo marker guard

    func testApplyRefusedWhenRepoMarkerMissing() throws {
        let home = try home("a")
        let repo = root.appendingPathComponent("gone")
        let backend = try LocalFolderBackend(root: repo)
        XCTAssertThrowsError(try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, requireRepoMarker: true)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
            XCTAssertTrue(((error as? DisklesslyError)?.errorDescription ?? "").hasPrefix("backend unreachable"))
        }
        for path in [home.claude, home.codex, home.pi] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("sessions").path))
        XCTAssertTrue(entries(try SessionArchive.listSessions(config: home.config)).isEmpty)
    }

    func testReindexAndRestoreRefuseUnreachableRepo() throws {
        let home = try home("a")
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, requireRepoMarker: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("repo/repo.json"))
        XCTAssertThrowsError(try SessionArchive.reindex(config: home.config, backend: backend, secrets: MemorySecretStore(), requireRepoMarker: true)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
            XCTAssertTrue(((error as? DisklesslyError)?.errorDescription ?? "").hasPrefix("backend unreachable"))
        }
        XCTAssertThrowsError(try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi, requireRepoMarker: true)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
            XCTAssertTrue(((error as? DisklesslyError)?.errorDescription ?? "").hasPrefix("backend unreachable"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
    }

    func testRepoWithContentButNoMarkerIsUsable() throws {
        // `RepoIdentity.ensure` will not add a marker to a repo that has images,
        // so the guard must not refuse such a repo forever.
        let home = try home("a")
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        try backend.put("manifests/app.json", data: Data("{}".utf8))
        XCTAssertNil(try RepoIdentity.ensure(backend))
        let report = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        XCTAssertEqual(report.archived.map(\.path), [home.pi])
        let status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "local") { backend }
        XCTAssertEqual((status["backend"] as? [String: Any])?["reachable"] as? Bool, true)

        // A sessions-only folder without a marker is refused with a hint; `init` marks it.
        let sessionsOnly = try LocalFolderBackend(root: root.appendingPathComponent("sessions-only"))
        try sessionsOnly.put("sessions/x.json", data: Data("{}".utf8))
        XCTAssertThrowsError(try SessionBackendCheck.require(sessionsOnly)) { error in
            XCTAssertTrue(((error as? DisklesslyError)?.errorDescription ?? "").contains("disklessly init"))
        }
        XCTAssertNotNil(try RepoIdentity.ensure(sessionsOnly))
        XCTAssertNoThrow(try SessionBackendCheck.require(sessionsOnly))
    }

    func testRestoreReadsFromMirrorWhenPrimaryHasNoMarker() throws {
        let home = try home("a")
        let mirror = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: mirror, now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        // The primary's disk is gone; opening the folder recreated it empty.
        let primary = try LocalFolderBackend(root: root.appendingPathComponent("unplugged"))
        let failover = FailoverBackend(primary: primary, mirrors: [(id: "mirror", open: { mirror })])
        XCTAssertThrowsError(try SessionBackendCheck.require(failover))
        let restored = try SessionArchive.restoreSession(config: home.config, backend: failover, query: home.pi, requireRepoMarker: true)
        XCTAssertEqual(restored.path, home.pi)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.pi))
        // Apply still writes to the primary only, so it is refused there.
        XCTAssertThrowsError(try SessionArchive.tier(config: home.config, backend: failover, now: now, apply: true, tools: ["codex"], requireRepoMarker: true)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
        }
    }

    func testRestoreOfFileAlreadyInPlaceNeedsNoBackend() throws {
        let home = try home("a")
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        _ = try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi, requireRepoMarker: true)
        var opened = false
        let again = try SessionArchive.restoreSession(config: home.config, open: {
            opened = true
            throw DisklesslyError.backend("backend unreachable: no credentials")
        }, query: home.pi, requireRepoMarker: true)
        XCTAssertFalse(opened)
        XCTAssertEqual(again.path, home.pi)
    }

    func testCheckSegmentsReportsStatErrorsAsUnchecked() throws {
        let home = try home("a")
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, requireRepoMarker: true)
        let flaky = FaultyBackend(inner: backend, failStat: ["sessions"])
        var status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "rclone", checkSegments: true) { flaky }
        var segments = try XCTUnwrap(status["segments"] as? [String: Any])
        XCTAssertEqual((status["backend"] as? [String: Any])?["reachable"] as? Bool, true)
        XCTAssertEqual(segments["missing"] as? [String], [])
        XCTAssertEqual(segments["checked"] as? Int, 0)
        XCTAssertEqual((segments["unchecked"] as? [String])?.count, 3)

        // Stats that outlast the overall limit leave the rest unchecked.
        let slow = SlowStat(backend)
        let started = Date()
        status = try SessionArchive.sessionStatus(config: home.config, backendId: "default", backendType: "rclone", checkSegments: true, segmentTimeout: 0.5) { slow }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        segments = try XCTUnwrap(status["segments"] as? [String: Any])
        XCTAssertEqual(segments["timedOut"] as? Bool, true)
        XCTAssertEqual(segments["missing"] as? [String], [])
        XCTAssertEqual((segments["checked"] as? Int ?? 0) + ((segments["unchecked"] as? [String])?.count ?? 0), 3)
        XCTAssertGreaterThan((segments["unchecked"] as? [String])?.count ?? 0, 0)
    }

    func testSameSegmentCommittedTwiceKeepsOneRow() throws {
        let database = try SessionIndexDB(stateDir: root.appendingPathComponent("state").path)
        let segment = SessionSegmentRow(id: String(repeating: "a", count: 64), path: "sessions/d/pi/_unknown/2024-11/s-aaaaaaaa.tar.zst", deviceId: "d", tool: "pi", createdAt: "2025-01-01T00:00:00Z", bytes: 10, codec: "zstd-3", encrypted: false, keyId: nil)
        func entry(_ state: String) -> SessionEntryRow {
            SessionEntryRow(id: "0123456789ab", segmentId: segment.id, legacyArchive: nil, member: "m/0123456789ab.jsonl", deviceId: "d", tool: "pi", path: "/h/plain.jsonl", sha256: "b", size: 1, mtimeNs: 1, ino: 1, preview: "", archivedAt: segment.createdAt, state: state)
        }
        try database.commit(segment: segment, entries: [entry("pendingDelete")])
        try database.setState(id: "0123456789ab", state: "restored")
        XCTAssertNoThrow(try database.commit(segment: segment, entries: [entry("pendingDelete")]))
        XCTAssertEqual(try database.allEntries().map(\.state), ["pendingDelete"])
        XCTAssertEqual(try database.segmentPaths().count, 1)
    }

    // MARK: layout and reindex

    func testProjectKeysAndSessionIds() {
        XCTAssertEqual(SessionIdentity.projectKey(cwd: "/Users/me/src/my_app.v2", encrypted: false), "Users-me-src-my-app-v2")
        XCTAssertEqual(SessionIdentity.projectKey(cwd: nil, encrypted: false), "_unknown")
        XCTAssertEqual(SessionIdentity.projectKey(cwd: "", encrypted: true), "_unknown")
        let long = "/" + String(repeating: "a", count: 80)
        let cut = SessionIdentity.projectKey(cwd: long, encrypted: false)
        XCTAssertEqual(cut, String(repeating: "a", count: 48) + "-" + SHA256Digest.hex(Data(long.utf8)).prefix(8))
        let sealed = SessionIdentity.projectKey(cwd: "/work/secret-project", encrypted: true)
        XCTAssertEqual(sealed, "p-" + SHA256Digest.hex(Data("/work/secret-project".utf8)).prefix(12))
        XCTAssertEqual(SessionIdentity.sessionId(tool: "claude", path: "/h/.claude/projects/p/\(claudeId).jsonl"), claudeId)
        XCTAssertEqual(SessionIdentity.sessionId(tool: "codex", path: "/h/.codex/sessions/rollout-2024-11-20T10-00-00-\(codexId).jsonl"), codexId)
        XCTAssertEqual(SessionIdentity.sessionId(tool: "pi", path: "/h/x/plain.jsonl"), "plain")
        let prompt = SessionDigest.firstPrompt(tool: "codex", path: "/x.jsonl", data: Data(codexBody(cwd: "/w", prompt: "real ask").utf8))
        XCTAssertEqual(prompt, "real ask")
        let longPrompt = String(repeating: "word ", count: 180)
        XCTAssertEqual(SessionDigest.firstPrompt(tool: "claude", path: "/x.jsonl", data: Data(claudeBody(cwd: "/w", prompt: longPrompt).utf8)).count, 500)
    }

    func testEncryptedSegmentsUseHashedProjectKey() throws {
        let home = try home("a")
        var config = home.config
        config.sessionEncryption = "aes-gcm"
        let secrets = MemorySecretStore()
        _ = try SessionKeyStore.create(secrets: secrets)
        let report = try SessionArchive.tier(config: config, backend: try markedRepo(), now: now, apply: true, secrets: secrets, encrypt: true, requireRepoMarker: true)
        let key = SessionIdentity.projectKey(cwd: "/work/demo-app", encrypted: true)
        XCTAssertTrue(report.segments.contains { $0.contains("/claude/\(key)/2024-11/") && $0.hasSuffix(".tar.zst.enc") }, "\(report.segments)")
        XCTAssertFalse(report.segments.contains { $0.contains("demo-app") })
        let claude = entries(try SessionArchive.listSessions(config: config, tool: "claude"))[0]
        XCTAssertEqual(claude["encrypted"] as? Bool, true)
        XCTAssertEqual(claude["project"] as? String, key)
        let restored = try SessionArchive.restoreSession(config: config, backend: try LocalFolderBackend(root: root.appendingPathComponent("repo")), query: home.claude, secrets: secrets)
        XCTAssertEqual(restored.sessionId, claudeId)
    }

    func testReindexReadsFlatAndPartitionedLayouts() throws {
        let a = try home("a")
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: a.config, backend: backend, now: now, apply: true, requireRepoMarker: true)

        // A segment in the flat layout of earlier versions, from a third device.
        let oldDevice = "aaaaaaaa-bbbb-4ccc-8ddd-000000000001"
        let body = Data(claudeBody(cwd: "/work/legacy", prompt: "old layout prompt").utf8)
        let member = SessionMemberDraft(entryId: SegmentWriter.entryId(deviceId: oldDevice, path: "/old/home/s.jsonl", sha256: SHA256Digest.hex(body)), path: "/old/home/s.jsonl", sha256: SHA256Digest.hex(body), size: Int64(body.count), mtimeNs: 1_700_000_000_000_000_000, ino: 1, preview: "raw preview", bytes: body, tool: "claude")
        let flat = try SegmentWriter.build(deviceId: oldDevice, tool: "claude", now: now, members: [member], key: nil)
        XCTAssertEqual(flat.relativePath.split(separator: "/").count, 4)
        try backend.put(flat.relativePath, data: flat.stored)
        try backend.put(flat.sidecarPath, data: flat.sidecar)

        let b = try home("b")
        let added = try SessionArchive.reindex(config: b.config, backend: backend, secrets: MemorySecretStore(), requireRepoMarker: true)
        XCTAssertEqual(added, 4)
        let rows = entries(try SessionArchive.listSessions(config: b.config, state: "remote"))
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0["local"] as? Bool == false })
        let claude = try XCTUnwrap(rows.first { $0["path"] as? String == a.claude })
        XCTAssertEqual(claude["cwd"] as? String, "/work/demo-app")
        XCTAssertEqual(claude["title"] as? String, "add a health check endpoint")
        XCTAssertEqual(claude["firstPrompt"] as? String, "add a health check endpoint")
        XCTAssertEqual(claude["project"] as? String, "work-demo-app")
        let legacy = try XCTUnwrap(rows.first { $0["path"] as? String == "/old/home/s.jsonl" })
        XCTAssertEqual(legacy["segment"] as? String, flat.relativePath)
        XCTAssertEqual(legacy["title"] as? String, "raw preview")
        XCTAssertEqual(legacy["project"] as? String, "_unknown")
        XCTAssertEqual(try SessionArchive.reindex(config: b.config, backend: backend, secrets: MemorySecretStore(), requireRepoMarker: true), 0)
    }

    // MARK: restore and archive again

    func testRestoreThenArchiveUnchangedFileAgain() throws {
        let home = try home("a")
        let backend = try markedRepo()
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now, apply: true, tools: ["pi"], requireRepoMarker: true)
        let first = try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi, requireRepoMarker: true)
        XCTAssertEqual(first.path, home.pi)
        XCTAssertEqual(first.sessionId, "plain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.pi))

        // pi keeps the archived mtime on restore, so the file looks cold at once.
        // It stays local until it has been back for the cold period.
        let soon = try SessionArchive.tier(config: home.config, backend: backend, now: now.addingTimeInterval(60), apply: true, tools: ["pi"], requireRepoMarker: true)
        XCTAssertEqual(soon.archived, [])
        XCTAssertTrue(soon.skipped.contains { $0.0 == home.pi && $0.1 == "restored" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.pi))
        XCTAssertEqual(entries(try SessionArchive.listSessions(config: home.config, tool: "pi")).first?["state"] as? String, "restored")

        // After the cold period the same bytes settle against the stored segment:
        // nothing is uploaded again and no orphan copy is left.
        let objects = try segmentObjects()
        let later = Date().addingTimeInterval(Double(home.config.sessionColdDays + 1) * 86_400)
        let again = try SessionArchive.tier(config: home.config, backend: backend, now: later, apply: true, tools: ["pi"], requireRepoMarker: true)
        XCTAssertEqual(again.archived.map(\.id), [first.id])
        XCTAssertEqual(again.segments, [])
        XCTAssertEqual(try segmentObjects(), objects)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.pi))
        let rows = entries(try SessionArchive.listSessions(config: home.config, tool: "pi"))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["state"] as? String, "archived")
        XCTAssertNoThrow(try SessionArchive.tier(config: home.config, backend: backend, now: later.addingTimeInterval(60), apply: true, requireRepoMarker: true))

        // Restored, changed, archived again: the path now has two rows and restore takes the newest.
        _ = try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi)
        try write(home.pi, "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"pi prompt v2\"}}\n", daysOld: 30)
        _ = try SessionArchive.tier(config: home.config, backend: backend, now: now.addingTimeInterval(180), apply: true, tools: ["pi"], requireRepoMarker: true)
        XCTAssertEqual(entries(try SessionArchive.listSessions(config: home.config, tool: "pi")).count, 2)
        let newest = try SessionArchive.restoreSession(config: home.config, backend: backend, query: home.pi)
        XCTAssertNotEqual(newest.id, first.id)
        XCTAssertTrue(try String(contentsOfFile: home.pi, encoding: .utf8).contains("pi prompt v2"))
    }

    // MARK: schema 4

    func testSchemaThreeIndexMigratesToFour() throws {
        let stateDir = root.appendingPathComponent("state")
        let directory = stateDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite").path
        let v3 = """
        CREATE TABLE segments(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, device_id TEXT NOT NULL, tool TEXT NOT NULL, created_at TEXT NOT NULL, bytes INTEGER NOT NULL, codec TEXT NOT NULL, encrypted INTEGER NOT NULL, key_id TEXT);
        CREATE TABLE entries(id TEXT PRIMARY KEY, segment_id TEXT, legacy_archive TEXT, member TEXT NOT NULL, device_id TEXT NOT NULL, tool TEXT NOT NULL, path TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, ino INTEGER, preview TEXT NOT NULL, archived_at TEXT NOT NULL, state TEXT NOT NULL, digest TEXT NOT NULL DEFAULT '');
        CREATE INDEX entries_path ON entries(path);
        CREATE VIRTUAL TABLE entries_fts USING fts5(id UNINDEXED, path, preview, digest);
        INSERT INTO entries VALUES('v3row', NULL, NULL, 'm/v3row.jsonl', 'dev', 'pi', '/h/v3.jsonl', 'ab', 3, 1, NULL, 'threepreview', '2025-01-01T00:00:00Z', 'archived', '**User:** hello');
        INSERT INTO entries_fts(id, path, preview, digest) VALUES('v3row', '/h/v3.jsonl', 'threepreview', '**User:** hello');
        PRAGMA user_version = 3;
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, v3]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let database = try SessionIndexDB(stateDir: stateDir.path)
        XCTAssertEqual(try database.userVersion(), 4)
        let rows = try database.allEntries()
        XCTAssertEqual(rows.map(\.id), ["v3row"])
        XCTAssertEqual(rows.map(\.digest), ["**User:** hello"])
        XCTAssertEqual(rows.map(\.cwd), [""])
        XCTAssertEqual(rows.map(\.firstPrompt), [""])
        XCTAssertEqual(try database.search(query: "threepreview", limit: 5), ["v3row"])
        try database.insert(entries: [SessionEntryRow(id: "v4row", segmentId: nil, legacyArchive: nil, member: "m/v4row.jsonl", deviceId: "dev", tool: "claude", path: "/h/v4.jsonl", sha256: "cd", size: 4, mtimeNs: 2, ino: nil, preview: "p", archivedAt: "2026-01-01T00:00:00Z", state: "archived", cwd: "/work/x", firstPrompt: "first ask")])
        let reopened = try SessionIndexDB(stateDir: stateDir.path)
        XCTAssertEqual(try reopened.userVersion(), 4)
        let v4 = try XCTUnwrap(try reopened.allEntries().first { $0.id == "v4row" })
        XCTAssertEqual(v4.cwd, "/work/x")
        XCTAssertEqual(v4.firstPrompt, "first ask")
    }
}

/// Stats sleep, so an overall limit is reached partway through a segment check.
private final class SlowStat: StorageBackend {
    let inner: LocalFolderBackend
    init(_ inner: LocalFolderBackend) { self.inner = inner }
    func list(_ path: String) throws -> [String] { try inner.list(path) }
    func stat(_ path: String) throws -> BackendStat? {
        if path.hasPrefix("sessions/") { Thread.sleep(forTimeInterval: 0.4) }
        return try inner.stat(path)
    }
    func get(_ path: String, range: Range<UInt64>?) throws -> Data { try inner.get(path, range: range) }
    func put(_ path: String, data: Data) throws { try inner.put(path, data: data) }
    func delete(_ path: String) throws { try inner.delete(path) }
    func localRoot() -> URL? { inner.localRoot() }
}
