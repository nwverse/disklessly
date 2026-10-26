import XCTest
import Foundation
import IsenoughCore
@testable import IsenoughEngine
@testable import IsenoughSessions

final class SessionsV2Tests: XCTestCase {
    func testTwoMachinesSameMonthBothRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-two-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let homeA = try plant(root.appendingPathComponent("a"), name: "a.jsonl", body: "machine-a-bytes\n", now: now)
        let homeB = try plant(root.appendingPathComponent("b"), name: "b.jsonl", body: "machine-b-bytes\n", now: now)
        let backend = try LocalFolderBackend(root: repo)
        let configA = config(root, name: "a", sessions: homeA.sessions)
        let configB = config(root, name: "b", sessions: homeB.sessions)
        let first = try SessionArchive.tier(config: configA, backend: backend, now: now, apply: true)
        XCTAssertEqual(first.segments.count, 1)
        let firstBytes = try Data(contentsOf: repo.appendingPathComponent(first.segments[0]))
        let second = try SessionArchive.tier(config: configB, backend: backend, now: now, apply: true)
        XCTAssertEqual(second.segments.count, 1)
        XCTAssertNotEqual(first.segments[0], second.segments[0])
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(first.segments[0])), firstBytes)
        let restoredA = try SessionArchive.restore(config: configA, backend: backend, query: homeA.path)
        let restoredB = try SessionArchive.restore(config: configB, backend: backend, query: homeB.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restoredA)), Data("machine-a-bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restoredB)), Data("machine-b-bytes\n".utf8))
    }

    func testIndexCommittedBeforeDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let planted = try plant(root, name: "cold.jsonl", body: "keep-until-commit\n", now: now)
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        let configuration = config(root, name: "state", sessions: planted.sessions)
        XCTAssertThrowsError(try SessionArchive.tier(config: configuration, backend: backend, now: now, apply: true, afterIndexCommit: {
            throw IsenoughError.failure("injected")
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted.path))
        let database = try SessionIndexDB(stateDir: configuration.stateDir)
        XCTAssertEqual(try database.allEntries().map(\.state), ["pendingDelete"])
        _ = try SessionArchive.tier(config: configuration, backend: backend, now: now, apply: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planted.path))
        XCTAssertEqual(try database.allEntries().map(\.state), ["archived"])
    }

    func testAppendAfterArchiveKeepsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-append-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let planted = try plant(root, name: "cold.jsonl", body: "original\n", now: now)
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        let report = try SessionArchive.tier(config: config(root, name: "state", sessions: planted.sessions), backend: backend, now: now, apply: true, beforeDelete: { path in
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("extra\n".utf8))
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted.path))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: planted.path), encoding: .utf8), "original\nextra\n")
        XCTAssertTrue(report.keptLocal.contains { $0.0 == planted.path && $0.1 == "modified after archiving" })
        let archived = try Data(contentsOf: root.appendingPathComponent("repo").appendingPathComponent(report.segments[0]))
        let plain = try Zstd.decompress(archived, maxBytes: 1_048_576)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("extra"))
    }

    func testSegmentWriteRefusesExistingDifferentBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-clash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let planted = try plant(root, name: "cold.jsonl", body: "stable-bytes\n", now: now)
        let configuration = config(root, name: "state", sessions: planted.sessions)
        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: configuration.stateDir), suggestedName: "mac")
        let data = try Data(contentsOf: URL(fileURLWithPath: planted.path))
        let finger = try FileFingerprint.of(url: URL(fileURLWithPath: planted.path))
        let member = SessionMemberDraft(
            entryId: SegmentWriter.entryId(deviceId: device.deviceId, path: planted.path, sha256: SHA256Digest.hex(data)),
            path: planted.path,
            sha256: SHA256Digest.hex(data),
            size: Int64(finger.size),
            mtimeNs: finger.mtimeNs,
            ino: Int64(finger.ino),
            preview: SessionTiering.preview(of: data),
            bytes: data,
            tool: "pi"
        )
        let built = try SegmentWriter.build(deviceId: device.deviceId, tool: "pi", now: now, members: [member], key: nil)
        let clash = root.appendingPathComponent("repo").appendingPathComponent(built.relativePath)
        try FileManager.default.createDirectory(at: clash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("different".utf8).write(to: clash)
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        XCTAssertThrowsError(try SessionArchive.tier(config: configuration, backend: backend, now: now, apply: true)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 5)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: planted.path)), data)
    }

    func testBackendFailureDeletesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-put-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let planted = try plant(root, name: "cold.jsonl", body: "stays\n", now: now)
        let configuration = config(root, name: "state", sessions: planted.sessions)
        let backend = try FaultyBackend(root: root.appendingPathComponent("repo"), failPut: ["sessions/"])
        XCTAssertThrowsError(try SessionArchive.tier(config: configuration, backend: backend, now: now, apply: true)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 4)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: planted.path)), Data("stays\n".utf8))
        let database = try SessionIndexDB(stateDir: configuration.stateDir)
        XCTAssertTrue(try database.allEntries().isEmpty)
    }

    func testEncryptedRepoHasNoPlaintext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-enc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let body = "prefix CANARY-7f3a suffix\n"
        let planted = try plant(root, name: "cold.jsonl", body: body, now: now)
        var configuration = config(root, name: "state", sessions: planted.sessions)
        configuration.sessionEncryption = "aes-gcm"
        let secrets = MemorySecretStore()
        _ = try SessionKeyStore.create(secrets: secrets)
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        let report = try SessionArchive.tier(config: configuration, backend: backend, now: now, apply: true, secrets: secrets, encrypt: true)
        let repo = root.appendingPathComponent("repo")
        let leaked = try plaintextHits(repo, needles: ["CANARY", (planted.path as NSString).lastPathComponent])
        XCTAssertEqual(leaked, [])
        let restored = try SessionArchive.restore(config: configuration, backend: backend, query: planted.path, secrets: secrets)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: restored), encoding: .utf8), body)
        XCTAssertFalse(report.segments.isEmpty)
    }

    func testMigrationFromV1KeepsOldArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let planted = try plant(root, name: "old.jsonl", body: "legacy-body\n", now: now)
        let configuration = config(root, name: "state", sessions: planted.sessions)
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        let archive = "sessions/pi/2025-01.tar.gz"
        var index = SessionIndex()
        let candidate = SessionCandidate(path: planted.path, tool: "pi", size: UInt64("legacy-body\n".utf8.count), modified: now.addingTimeInterval(-(40 * 24 * 60 * 60)), open: false, preview: "legacy-body")
        try SessionArchive.publishLegacy(archive: archive, files: [candidate], backend: backend, index: &index)
        try SessionArchive.saveIndex(index, stateDir: configuration.stateDir)
        let archived = root.appendingPathComponent("repo").appendingPathComponent(archive)
        let before = try Data(contentsOf: archived)
        _ = try SessionArchive.search(config: configuration, query: "legacy-body")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.stateDir + "/sessions-index.json.migrated-v2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.stateDir + "/sessions-index.json"))
        XCTAssertEqual(try Data(contentsOf: archived), before)
        try FileManager.default.removeItem(atPath: planted.path)
        let restored = try SessionArchive.restore(config: configuration, backend: backend, query: planted.path)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: restored), encoding: .utf8), "legacy-body\n")
        let fresh = try plant(root, name: "fresh.jsonl", body: "new-tier\n", now: now)
        _ = fresh
        let report = try SessionArchive.tier(config: configuration, backend: backend, now: now, apply: true)
        XCTAssertTrue(report.segments.allSatisfy { !$0.hasPrefix("sessions/pi/") })
        XCTAssertEqual(try Data(contentsOf: archived), before)
    }

    func testReindexSeesOtherDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-re-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let planted = try plant(root.appendingPathComponent("a"), name: "a.jsonl", body: "from-a\n", now: now)
        let repo = root.appendingPathComponent("repo")
        let backend = try LocalFolderBackend(root: repo)
        let configA = config(root, name: "a", sessions: planted.sessions)
        let configB = config(root, name: "b", sessions: root.appendingPathComponent("b-sessions"))
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: configB.stubDir), withIntermediateDirectories: true)
        _ = try SessionArchive.tier(config: configA, backend: backend, now: now, apply: true)
        let added = try SessionArchive.reindex(config: configB, backend: backend, secrets: MemorySecretStore())
        XCTAssertGreaterThan(added, 0)
        let found = try SessionArchive.search(config: configB, query: "from-a")
        XCTAssertEqual(found.count, 1)
        XCTAssertThrowsError(try SessionArchive.restore(config: configB, backend: backend, query: planted.path)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 2)
        }
    }

    func testSessionsLockBusy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-v2-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let planted = try plant(root, name: "cold.jsonl", body: "locked\n", now: now)
        let configuration = config(root, name: "state", sessions: planted.sessions)
        let directory = URL(fileURLWithPath: configuration.stateDir).appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var held = FileLock(path: directory.appendingPathComponent("sessions.lock").path)
        XCTAssertTrue(try held.tryLock())
        defer { held.unlock() }
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        XCTAssertThrowsError(try SessionArchive.tier(config: configuration, backend: backend, now: now, apply: true)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 9)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted.path))
    }

    private struct Planted {
        var sessions: URL
        var path: String
    }

    private func plant(_ root: URL, name: String, body: String, now: Date) throws -> Planted {
        let sessions = root.appendingPathComponent("home/.pi/agent/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent(name)
        try Data(body.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(40 * 24 * 60 * 60))], ofItemAtPath: file.path)
        return Planted(sessions: sessions, path: SessionPaths.canonical(file.path))
    }

    private func config(_ root: URL, name: String, sessions: URL) -> RuntimeConfig {
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: root.appendingPathComponent("cache-\(name)").path,
            stateDir: root.appendingPathComponent("state-\(name)").path,
            mountRoot: root.appendingPathComponent("mnt-\(name)").path,
            stubDir: root.appendingPathComponent("apps-\(name)").path
        )
        config.sessionRoots = [SessionRoot(tool: "pi", directory: sessions.path)]
        config.sessionColdDays = 14
        return config
    }

    private func plaintextHits(_ root: URL, needles: [String]) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var hits: [String] = []
        for case let url as URL in enumerator {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if needles.contains(where: { text.contains($0) }) { hits.append(url.path) }
        }
        return hits
    }
}
