import XCTest
import Foundation
@testable import IsenoughCore
@testable import IsenoughEngine

final class DoctorTests: XCTestCase {
    func testTimeoutEnvironment() {
        XCTAssertEqual(DoctorLimits.timeout(environment: [:]), 15)
        XCTAssertEqual(DoctorLimits.timeout(environment: ["ISENOUGH_DOCTOR_TIMEOUT": "12"]), 12)
        XCTAssertEqual(DoctorLimits.timeout(environment: ["ISENOUGH_DOCTOR_TIMEOUT": "0.2"]), 15)
        XCTAssertEqual(DoctorLimits.timeout(environment: ["ISENOUGH_DOCTOR_TIMEOUT": "nope"]), 15)
    }

    func testLinesUseStableStatusWords() {
        let okLine = DoctorFormatting.line(["name": "config", "status": "ok", "detail": ""])
        let badLine = DoctorFormatting.line(["name": "repo", "status": "timed out", "detail": "checking repository timed out"])
        XCTAssertEqual(String(okLine.prefix(9)), "ok       ")
        XCTAssertEqual(String(badLine.prefix(9)), "timed out")
        XCTAssertTrue(badLine.contains(" repo"))
        XCTAssertTrue(badLine.contains("timed out"))
    }

    func testHealthyTreeReportsEachCheck() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try preparedEngine(root: root, writeRepoJSON: true)
        let names = box()
        let report = engine.doctor { check in names.items.append(check["name"] as? String ?? "") }
        XCTAssertEqual(names.items, ["config", "journals", "repo", "backend", "conflicts", "materialized", "free-space", "mounts", "engine", "disk-image"])
        let checks = try checksByName(report)
        XCTAssertEqual(checks["config"]?["status"] as? String, "ok")
        XCTAssertEqual(checks["journals"]?["status"] as? String, "ok")
        XCTAssertEqual(checks["repo"]?["status"] as? String, "ok")
        XCTAssertEqual(checks["backend"]?["status"] as? String, "ok")
        XCTAssertEqual(checks["materialized"]?["status"] as? String, "ok")
        XCTAssertTrue((checks["materialized"]?["detail"] as? String ?? "").contains("not in iCloud"))
        XCTAssertEqual(checks["mounts"]?["status"] as? String, "ok")
        let free = checks["free-space"]?["status"] as? String
        XCTAssertTrue(free == "ok" || free == "warn")
        XCTAssertEqual(checks["engine"]?["status"] as? String, "warn")
        XCTAssertTrue((checks["engine"]?["detail"] as? String ?? "").contains("missing"))
        #if os(macOS)
        let disk = checks["disk-image"]?["status"] as? String
        XCTAssertTrue(disk == "ok" || disk == "warn" || disk == "fail" || disk == "timed out")
        #else
        XCTAssertEqual(checks["disk-image"]?["status"] as? String, "warn")
        XCTAssertEqual(report["ok"] as? Bool, true)
        #endif
        XCTAssertEqual(report["issues"] as? [String] ?? ["missing"], [])
        XCTAssertEqual(report["repo"] as? Bool, true)
    }

    func testMissingRepositoryWarnsAndDoesNotFail() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine = try preparedEngine(root: root, writeRepoJSON: false)
        engine.config.repoPath = root.appendingPathComponent("missing-repo").path
        let report = engine.doctor()
        let checks = try checksByName(report)
        XCTAssertEqual(checks["repo"]?["status"] as? String, "warn")
        XCTAssertEqual(checks["backend"]?["status"] as? String, "warn")
        XCTAssertEqual(report["repo"] as? Bool, false)
        XCTAssertEqual(report["issues"] as? [String] ?? ["missing"], [])
        #if !os(macOS)
        XCTAssertEqual(report["ok"] as? Bool, true)
        #endif
    }

    func testMissingCacheDirectoryWarnsWithVolumeFreeSpace() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine = try preparedEngine(root: root, writeRepoJSON: true)
        engine.config.cacheDir = root.appendingPathComponent("no-cache-yet").path
        let report = engine.doctor()
        let checks = try checksByName(report)
        XCTAssertEqual(checks["free-space"]?["status"] as? String, "warn")
        let detail = checks["free-space"]?["detail"] as? String ?? ""
        XCTAssertTrue(detail.contains("cache directory is missing"))
        XCTAssertTrue(detail.contains("free"))
    }

    func testFreeSpaceBelowFloorWarns() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine = try preparedEngine(root: root, writeRepoJSON: true)
        engine.config.minFreeBytes = UInt64.max
        let report = engine.doctor()
        let checks = try checksByName(report)
        XCTAssertEqual(checks["free-space"]?["status"] as? String, "warn")
        XCTAssertTrue((checks["free-space"]?["detail"] as? String ?? "").contains("floor"))
    }

    func testStaleMirrorFailsJournals() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try preparedEngine(root: root, writeRepoJSON: true)
        var object = StateStore(engine.config.stateDir).read()
        object["restored"] = ["com.example.bar": ["dest": root.appendingPathComponent("apps/Bar.app").path, "staging": root.appendingPathComponent("missing-staging").path]]
        try StateStore(engine.config.stateDir).write(object)
        let report = engine.doctor()
        let checks = try checksByName(report)
        XCTAssertEqual(checks["journals"]?["status"] as? String, "fail")
        let issues = try XCTUnwrap(report["issues"] as? [String])
        XCTAssertTrue(issues.contains { $0.contains("com.example.bar") && $0.contains("no journal") })
        XCTAssertEqual(report["ok"] as? Bool, false)
    }

    func testStuckRepositoryProbeTimesOutAndLaterChecksStillRun() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine = try preparedEngine(root: root, writeRepoJSON: true)
        engine.config.repoPath = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/256isenough"
        let calls = box()
        engine.doctorRepositoryProbe = { _ in
            calls.items.append("hit")
            Thread.sleep(forTimeInterval: 1)
            return true
        }
        let started = Date()
        let report = engine.doctor(checkTimeout: 0.25)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let checks = try checksByName(report)
        XCTAssertEqual(checks["repo"]?["status"] as? String, "timed out")
        let detail = checks["repo"]?["detail"] as? String ?? ""
        XCTAssertTrue(detail.contains("timed out"))
        XCTAssertTrue(detail.contains("ISENOUGH_DOCTOR_TIMEOUT"))
        XCTAssertTrue(detail.contains("Files and Folders"))
        XCTAssertEqual(checks["backend"]?["status"] as? String, "warn")
        XCTAssertNotNil(checks["free-space"])
        XCTAssertNotNil(checks["disk-image"])
        XCTAssertEqual(report["ok"] as? Bool, false)
        XCTAssertEqual(report["repo"] as? Bool, false)
        XCTAssertFalse(calls.items.isEmpty)
        let line = DoctorFormatting.line(checks["repo"] ?? [:])
        XCTAssertTrue(line.hasPrefix("timed out"))
    }

    func testFixCheckRunsBeforeJournals() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try preparedEngine(root: root, writeRepoJSON: true)
        let names = box()
        let report = engine.doctor(fix: true) { check in names.items.append(check["name"] as? String ?? "") }
        XCTAssertEqual(Array(names.items.prefix(2)), ["config", "fix"])
        let checks = try checksByName(report)
        XCTAssertEqual(checks["fix"]?["status"] as? String, "ok")
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-doctor-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func preparedEngine(root: URL, writeRepoJSON: Bool) throws -> IsenoughEngine {
        let repo = root.appendingPathComponent("repo")
        let cache = root.appendingPathComponent("cache")
        let mounts = root.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        if writeRepoJSON {
            try Data("{\"schema\":\"repo/1\"}".utf8).write(to: repo.appendingPathComponent("repo.json"))
        }
        let config = RuntimeConfig(
            repoPath: repo.path,
            cacheDir: cache.path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: mounts.path,
            stubDir: root.appendingPathComponent("apps").path
        )
        return IsenoughEngine(config: config)
    }

    private func checksByName(_ report: [String: Any]) throws -> [String: [String: Any]] {
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        var map: [String: [String: Any]] = [:]
        for check in checks {
            map[check["name"] as? String ?? ""] = check
        }
        return map
    }

    private func box() -> NameBox { NameBox() }
}

private final class NameBox: @unchecked Sendable {
    var items: [String] = []
}
