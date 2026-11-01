import XCTest
import Foundation
import DisklesslyCore
@testable import DisklesslyEngine

final class ReviewFollowupsTests: XCTestCase {
    func testGcDryRunPrintsTrashLegacyAndLruWithoutMoving() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-dry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mnt").path,
            stubDir: root.appendingPathComponent("apps").path
        )
        config.quotaBytes = 1
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.deviceFactsOverride = DeviceFacts(hostname: "mini", arch: "x86_64", osVersion: "test")
        engine.stubRootsOverride = [URL(fileURLWithPath: config.stubDir, isDirectory: true)]
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: config.stubDir), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: config.repoPath), withIntermediateDirectories: true)
        try engine.ensureDevice()
        let images = URL(fileURLWithPath: config.repoPath).appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let orphan = images.appendingPathComponent("orphan.dmg")
        let legacy = images.appendingPathComponent("old.dmg")
        try Data("orphan".utf8).write(to: orphan)
        try Data("old".utf8).write(to: legacy)
        try engine.repo.put(LegacyImages.path, data: try LegacyImages.encode(["old"]))
        let cached = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/cached.dmg")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 8192).write(to: cached)

        let plan = try engine.gcDryRun()
        XCTAssertEqual(plan.trash, ["orphan"])
        XCTAssertEqual(plan.legacy, ["old"])
        XCTAssertTrue(plan.lru.contains("cached"))
        let text = plan.text()
        XCTAssertTrue(text.contains("trash candidate  orphan"))
        XCTAssertTrue(text.contains("legacy  old"))
        XCTAssertTrue(text.contains("lru  cached"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: config.repoPath).appendingPathComponent("trash/images/orphan.dmg").path))
        XCTAssertNil(StateStore(config.stateDir).load().cache["cached"]?.bytes)

        let report = engine.doctor(fix: true)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        let fix = checks.first { $0["name"] as? String == "fix" }
        XCTAssertEqual(fix?["status"] as? String, "ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: config.repoPath).appendingPathComponent("trash/images/orphan.dmg").path))
    }

    // gc and icons are macOS only; LinuxSupportTests checks the refusal.
    #if os(macOS)
    func testGcAndIconsHelpPrintUsage() throws {
        let binary = try cliBinary()
        let gc = try run(binary, ["gc", "--help"])
        XCTAssertEqual(gc.status, 0)
        XCTAssertTrue(gc.out.contains("Usage:"))
        XCTAssertTrue(gc.out.contains("gc [--dry-run]"))
        let icons = try run(binary, ["icons", "backfill", "--help"])
        XCTAssertEqual(icons.status, 0)
        XCTAssertTrue(icons.out.contains("Usage:"))
        XCTAssertTrue(icons.out.contains("icons backfill"))
        XCTAssertFalse(icons.err.contains("Unknown option"))
    }

    func testGcDryRunCommandDoesNotCreateDeviceOrTrashFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-dry-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let binary = try cliBinary()
        var environment = ProcessInfo.processInfo.environment
        environment["DISKLESSLY_REPO_PATH"] = repo.path
        environment["DISKLESSLY_CACHE_DIR"] = cache.path
        environment["DISKLESSLY_STATE_DIR"] = root.appendingPathComponent("state").path
        environment["DISKLESSLY_MOUNT_ROOT"] = root.appendingPathComponent("mnt").path
        environment["DISKLESSLY_STUB_DIR"] = root.appendingPathComponent("apps").path
        environment["DISKLESSLY_QUOTA_BYTES"] = "1"
        let result = try run(binary, ["gc", "--dry-run"], environment: environment)
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("trash candidates"))
        XCTAssertTrue(result.out.contains("legacy"))
        XCTAssertTrue(result.out.contains("lru"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("devices").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("trash").path))
    }
    #endif

    private func cliBinary() throws -> URL {
        let fm = FileManager.default
        // Prefer this build's binary: walking `.build` can meet a stale `Release/disklessly`.
        if let built = builtCLISibling() { return built }
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                let root = url.appendingPathComponent(".build")
                if let found = fm.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "disklessly" && fm.isExecutableFile(atPath: $0.path) }) {
                    return found
                }
            }
            url.deleteLastPathComponent()
        }
        throw DisklesslyError.failure("disklessly binary was not built")
    }

    private func run(_ binary: URL, _ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }
}
