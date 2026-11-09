import XCTest
import DisklesslyCore
import DisklesslyEngine
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SessionTests: XCTestCase {
    func testTieringSkipsOpenRecentAndSecretFiles() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-(20 * 24 * 60 * 60))
        let recent = now.addingTimeInterval(-(2 * 60 * 60))
        let cold = SessionCandidate(path: "/h/.pi/agent/sessions/a.jsonl", tool: "pi", size: 4, modified: old, open: false, preview: "hello")
        XCTAssertTrue(SessionTiering.decide(cold, now: now, coldDays: 14).cold)
        let opened = SessionCandidate(path: cold.path, tool: "pi", size: 4, modified: old, open: true, preview: "hello")
        XCTAssertEqual(SessionTiering.decide(opened, now: now, coldDays: 14).reason, "open")
        let fresh = SessionCandidate(path: cold.path, tool: "pi", size: 4, modified: recent, open: false, preview: "hello")
        XCTAssertEqual(SessionTiering.decide(fresh, now: now, coldDays: 1).reason, "modified within 24h")
        let observer = SessionCandidate(path: "/h/.claude/projects/-Users-x--claude-mem-observer-sessions/a.jsonl", tool: "claude", size: 4, modified: now.addingTimeInterval(-(5 * 24 * 60 * 60)), open: false, preview: "hi")
        XCTAssertTrue(SessionTiering.decide(observer, now: now, coldDays: 14).cold)
        XCTAssertEqual(SessionTiering.threshold(for: observer.path, default: 14), 3)
        XCTAssertEqual(SessionTiering.decide(cold, now: now, coldDays: 14).reason, "cold")
        XCTAssertEqual(SessionTiering.threshold(for: "/h/.claude/projects/-Users-x-claude-mem-observer-sessions-foo/a.jsonl", default: 14), 14)
        XCTAssertTrue(SessionTiering.forbidden("/h/.codex/auth.json"))
        XCTAssertTrue(SessionTiering.forbidden("/h/.claude/state.vscdb"))
        XCTAssertTrue(SessionTiering.forbidden("/h/.claude/projects/x.sqlite"))
        XCTAssertFalse(SessionTiering.forbidden("/h/.pi/agent/sessions/a.jsonl"))
        XCTAssertFalse(OpenFileProbe.isOpen(lsofStatus: 1, lsofStdout: "lsof: unsupported\n", path: "/tmp/a.jsonl"))
        XCTAssertTrue(OpenFileProbe.isOpen(lsofStatus: 0, lsofStdout: "p123\nn/tmp/a.jsonl\n", path: "/tmp/a.jsonl"))
        XCTAssertFalse(OpenFileProbe.isOpen(lsofStatus: 0, lsofStdout: "n/tmp/other.jsonl\n", path: "/tmp/a.jsonl"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let viaReal = real.appendingPathComponent("a.jsonl").path
        let viaLink = link.appendingPathComponent("a.jsonl").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: viaReal))
        XCTAssertEqual(SessionPaths.canonical(viaLink), SessionPaths.canonical(viaReal))
        XCTAssertTrue(OpenFileProbe.isOpen(lsofStatus: 0, lsofStdout: "n\(viaLink)\n", path: viaReal))
        XCTAssertFalse(OpenFileProbe.isOpen(lsofStatus: 0, lsofStdout: "n\(viaReal).other\n", path: viaLink))
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
        let oldPath = SessionPaths.canonical(oldURL.path)
        let freshPath = SessionPaths.canonical(freshURL.path)
        let backend = try LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath))
        let dry = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, isOpen: { _ in false })
        XCTAssertEqual(dry.cold, [oldPath])
        XCTAssertEqual(SessionPaths.canonical(oldURL.path), dry.cold[0])
        XCTAssertFalse(dry.applied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPath))
        let openSkip = try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, isOpen: { $0 == oldPath })
        XCTAssertTrue(openSkip.cold.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPath))
        let applied = try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, isOpen: { _ in false })
        XCTAssertEqual(applied.cold, [oldPath])
        XCTAssertTrue(applied.applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshPath))
        let found = try SessionArchive.search(config: config, query: "blender")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].path, oldPath)
        let byAlias = try SessionArchive.search(config: config, query: oldURL.path)
        XCTAssertEqual(byAlias.map(\.path), [oldPath])
        let remote = try backend.get(found[0].archive, range: nil)
        XCTAssertFalse(remote.isEmpty)
        let restored = try SessionArchive.restore(config: config, backend: backend, query: oldURL.path)
        XCTAssertEqual(restored, oldPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restored)), body)
        let attrs = try FileManager.default.attributesOfItem(atPath: restored)
        let restoredMtime = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(restoredMtime.timeIntervalSince1970, found[0].modified.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(try SessionArchive.search(config: config, query: "blender").isEmpty)
    }

    func testHomeEnvironmentControlsSessionDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let realHome = root.appendingPathComponent("real-home")
        let alias = root.appendingPathComponent("alias-home")
        let sessions = realHome.appendingPathComponent(".pi/agent/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realHome)
        let oldURL = sessions.appendingPathComponent("old.jsonl")
        try Data("{\"text\":\"from home\"}\n".utf8).write(to: oldURL)
        let decoyDir = root.appendingPathComponent("other-home/.pi/agent/sessions")
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
        let decoy = decoyDir.appendingPathComponent("decoy.jsonl")
        try Data("{\"text\":\"not this home\"}\n".utf8).write(to: decoy)
        let now = Date()
        let oldDate = now.addingTimeInterval(-(30 * 24 * 60 * 60))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: decoy.path)
        let oldPath = SessionPaths.canonical(oldURL.path)
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        let backend = try LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath))
        XCTAssertEqual(SessionPaths.homeDirectory(environment: ["HOME": alias.path]), SessionPaths.canonical(alias.path))
        XCTAssertEqual(SessionPaths.homeDirectory(environment: ["HOME": ""]), SessionPaths.canonical(NSHomeDirectory()))
        XCTAssertEqual(SessionPaths.homeDirectory(environment: [:]), SessionPaths.canonical(NSHomeDirectory()))
        let fromHome = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, environment: ["HOME": alias.path])
        XCTAssertEqual(fromHome.cold, [oldPath])
        let listed = fromHome.cold + fromHome.skipped.map(\.0)
        XCTAssertTrue(listed.allSatisfy { SessionPaths.contains(realHome.path, path: $0) })
        XCTAssertFalse(listed.contains { $0.contains("other-home") })
        let decoyHome = decoyDir.deletingLastPathComponent().path
        config.sessionHome = alias.path
        let fromConfig = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, environment: ["HOME": decoyHome])
        XCTAssertEqual(fromConfig.cold, [oldPath])
        config.sessionHome = decoyHome
        let fromFlag = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, home: alias.path, environment: ["HOME": decoyHome])
        XCTAssertEqual(fromFlag.cold, [oldPath])
        let roots = [SessionRoot(tool: "pi", directory: sessions.path)]
        XCTAssertEqual(SessionArchive.pathsOutsideRoots([decoy.path], roots: roots), [SessionPaths.canonical(decoy.path)])
        XCTAssertTrue(SessionArchive.pathsOutsideRoots([oldURL.path], roots: roots).isEmpty)
    }

    /// A home passed as a symlink must be reported as the target directory.
    /// The expected path is POSIX `realpath`, not `URL.path`, so a `/var` alias
    /// has to come back as `/private/var` on macOS and a custom symlink has to
    /// resolve on Linux too.
    func testSymlinkedHomeIsReportedAsTheRealpath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let realHome = root.appendingPathComponent("real-home")
        let alias = root.appendingPathComponent("alias-home")
        let sessions = realHome.appendingPathComponent(".pi/agent/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realHome)
        let oldURL = sessions.appendingPathComponent("old.jsonl")
        let body = Data("{\"text\":\"canonical home\"}\n".utf8)
        try body.write(to: oldURL)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(30 * 24 * 60 * 60))], ofItemAtPath: oldURL.path)
        let aliasFile = alias.appendingPathComponent(".pi/agent/sessions/old.jsonl").path
        let expected = try Self.posixRealpath(aliasFile)
        XCTAssertFalse(expected.contains("/alias-home"))
        XCTAssertTrue(expected.hasSuffix("/real-home/.pi/agent/sessions/old.jsonl"))
        XCTAssertEqual(SessionPaths.canonical(aliasFile), expected)
        XCTAssertEqual(SessionPaths.canonical(oldURL.path), expected)
        let missing = alias.appendingPathComponent(".pi/agent/sessions/gone.jsonl").path
        let missingExpected = try Self.posixRealpath(alias.appendingPathComponent(".pi/agent/sessions").path) + "/gone.jsonl"
        XCTAssertEqual(SessionPaths.canonical(missing), missingExpected)
        XCTAssertFalse(SessionPaths.canonical(missing).contains("/alias-home"))

        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        let backend = try LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath))
        let fromHome = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, environment: ["HOME": alias.path])
        XCTAssertEqual(fromHome.cold, [expected])
        config.sessionHome = alias.path
        let fromConfig = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, environment: ["HOME": "/no/such-home"])
        XCTAssertEqual(fromConfig.cold, [expected])
        config.sessionHome = nil
        let fromFlag = try SessionArchive.tier(config: config, backend: backend, now: now, apply: false, home: alias.path, environment: ["HOME": "/no/such-home"])
        XCTAssertEqual(fromFlag.cold, [expected])
        let aliasRoot = [SessionRoot(tool: "pi", directory: alias.appendingPathComponent(".pi/agent/sessions").path)]
        XCTAssertTrue(SessionArchive.pathsOutsideRoots([oldURL.path, aliasFile], roots: aliasRoot).isEmpty)
        let realRoot = [SessionRoot(tool: "pi", directory: sessions.path)]
        XCTAssertTrue(SessionArchive.pathsOutsideRoots([aliasFile], roots: realRoot).isEmpty)
        let outside = root.appendingPathComponent("outside.jsonl").path
        XCTAssertEqual(SessionArchive.pathsOutsideRoots([outside], roots: realRoot), [SessionPaths.canonical(outside)])

        let applied = try SessionArchive.tier(config: config, backend: backend, now: now, apply: true, home: alias.path, environment: ["HOME": "/no/such-home"])
        XCTAssertEqual(applied.cold, [expected])
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected))
        let indexed = try SessionArchive.search(config: config, query: aliasFile)
        XCTAssertEqual(indexed.map(\.path), [expected])
        let restored = try SessionArchive.restore(config: config, backend: backend, query: aliasFile)
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restored)), body)
    }

    /// Independent of `SessionPaths`, so a canonicalizer that keeps the symlink spelling fails here.
    private static func posixRealpath(_ path: String) throws -> String {
        try path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else {
                throw DisklesslyError.failure("realpath failed for \(path)")
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    func testApplyRefusesACandidateOutsideTheConfiguredRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("home/.pi/agent/sessions")
        let outsideDir = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let outside = outsideDir.appendingPathComponent("secret.jsonl")
        let body = Data("do not pack\n".utf8)
        try body.write(to: outside)
        let link = sessions.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let kept = sessions.appendingPathComponent("kept.jsonl")
        try Data("kept\n".utf8).write(to: kept)
        let now = Date()
        let oldDate = now.addingTimeInterval(-(30 * 24 * 60 * 60))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: outside.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: kept.path)
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        config.sessionRoots = [SessionRoot(tool: "pi", directory: sessions.path)]
        let backend = try LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath))
        XCTAssertThrowsError(try SessionArchive.tier(config: config, backend: backend, now: now, apply: true)) { error in
            XCTAssertTrue(((error as? DisklesslyError)?.errorDescription ?? "").contains("outside the configured roots"))
        }
        XCTAssertEqual(try Data(contentsOf: outside), body)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("repo/sessions").path))
    }
}
