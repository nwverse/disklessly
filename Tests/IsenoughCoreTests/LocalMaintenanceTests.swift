import XCTest
import Foundation
@testable import IsenoughCore
@testable import IsenoughEngine

final class LocalMaintenanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEvictsOnlyAFullyUploadedIdleCopy() {
        let ready = file("images/ready.dmg", ubiquitous: true, uploaded: true, logical: 5_000, allocated: 5_000)
        let plan = LocalEviction.plan([
            ready,
            file("images/sending.dmg", ubiquitous: true, uploaded: false, uploading: true, logical: 9, allocated: 9),
            file("images/failed.dmg", ubiquitous: true, uploaded: false, uploadFailed: true, logical: 9, allocated: 9),
            file("images/partial.dmg", ubiquitous: true, uploaded: false, logical: 9, allocated: 9),
            file("images/mounted.dmg", ubiquitous: true, uploaded: true, logical: 9, allocated: 9, inUse: true),
            file("images/detach.dmg", ubiquitous: true, uploaded: true, logical: 9, allocated: 9, protectedUntil: now.addingTimeInterval(30)),
            file("images/pinned.dmg", ubiquitous: true, uploaded: true, logical: 9, allocated: 9, pinned: true),
            file("images/gone.dmg", ubiquitous: true, uploaded: true, logical: 9, allocated: 0, dataless: true),
            file("images/local.dmg", ubiquitous: false, uploaded: true, logical: 9, allocated: 9),
        ], now: now)
        XCTAssertEqual(plan.evict, ["images/ready.dmg"])
        XCTAssertTrue(plan.retryLater.allSatisfy { $0.contains("upload is not finished") })
        XCTAssertEqual(plan.retryLater.count, 3)
        XCTAssertTrue(plan.skipped.contains("images/mounted.dmg: in use on this Mac"))
        XCTAssertTrue(plan.skipped.contains("images/detach.dmg: needed until the detach delay elapses"))
        XCTAssertTrue(plan.skipped.contains("images/pinned.dmg: kept downloaded on this Mac"))
        XCTAssertTrue(plan.skipped.contains("images/gone.dmg: already evicted"))
        XCTAssertTrue(plan.skipped.contains("images/local.dmg: not in iCloud"))
        let elapsed = file("images/detach.dmg", ubiquitous: true, uploaded: true, logical: 9, allocated: 9, protectedUntil: now.addingTimeInterval(-1))
        XCTAssertEqual(LocalEviction.decide(elapsed, now: now), .evict)
    }

    func testMissingUploadStatusIsNotAnUnfinishedUpload() {
        let unknown = file("images/claude.dmg", ubiquitous: true, uploaded: false, logical: 333 * 1_048_576, allocated: 333 * 1_048_576, uploadKnown: false)
        XCTAssertEqual(LocalEviction.decide(unknown, now: now), .retryLater("upload status is unavailable"))
        let partial = file("images/wechat.dmg", ubiquitous: true, uploaded: false, uploading: true, logical: 502 * 1_048_576, allocated: 502 * 1_048_576, uploadPercent: 42)
        XCTAssertEqual(LocalEviction.decide(partial, now: now), .retryLater("upload is not finished (42% uploaded)"))
        let reported = file("images/chengguang.dmg", ubiquitous: true, uploaded: false, logical: 1_400 * 1_048_576, allocated: 1_400 * 1_048_576, uploadKnown: false, uploadPercent: 0)
        XCTAssertEqual(LocalEviction.decide(reported, now: now), .retryLater("upload status is unavailable (0% uploaded)"))
        let plan = LocalEviction.plan([unknown, partial, reported], now: now)
        XCTAssertTrue(plan.evict.isEmpty)
        XCTAssertEqual(plan.retryLater.count, 3)
    }

    func testOpenRestoreAndDetachDelayProtectTheImage() {
        let active = LocalEviction.protects(phase: .active, outcome: nil, detachAfter: nil, now: now)
        XCTAssertTrue(active.inUse)
        XCTAssertNil(active.until)
        let waiting = LocalEviction.protects(phase: .quiesced, outcome: nil, detachAfter: now.addingTimeInterval(120), now: now)
        XCTAssertTrue(waiting.inUse)
        XCTAssertEqual(waiting.until, now.addingTimeInterval(120))
        let done = LocalEviction.protects(phase: .closed, outcome: "restoredOut", detachAfter: now.addingTimeInterval(-5), now: now)
        XCTAssertFalse(done.inUse)
        XCTAssertNil(done.until)
    }

    func testCannotEvictIsRetryLater() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine = try engine(root)
        let ready = file("images/ready.dmg", ubiquitous: true, uploaded: true, logical: 8, allocated: 8)
        let stubborn = file("images/stubborn.dmg", ubiquitous: true, uploaded: true, logical: 8, allocated: 8)
        engine.materialFilesOverride = [ready, stubborn, file("images/sending.dmg", ubiquitous: true, uploaded: false, uploading: true, logical: 8, allocated: 8)]
        engine.ubiquityEvictor = { file in
            file.relativePath.hasSuffix("stubborn.dmg") ? .retryLater("cannot evict yet") : .evicted
        }
        let report = engine.evictLocalCopies(now: now)
        XCTAssertEqual(report.evicted, ["images/ready.dmg"])
        XCTAssertTrue(report.retryLater.contains { $0.contains("images/sending.dmg") && $0.contains("upload is not finished") })
        XCTAssertTrue(report.retryLater.contains { $0.contains("images/stubborn.dmg") && $0.contains("cannot evict yet") })
        XCTAssertFalse(report.evicted.contains("images/sending.dmg"))
    }

    func testDoctorReportsMaterializedBytes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine = try engine(root)
        engine.materialFilesOverride = [
            file("images/big.dmg", ubiquitous: true, uploaded: true, logical: 7 * 1_073_741_824, allocated: 7 * 1_073_741_824),
            file("images/thin.dmg", ubiquitous: true, uploaded: true, logical: 1_073_741_824, allocated: 0, dataless: true),
        ]
        let report = engine.doctor(checkTimeout: 5)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        let materialized = checks.first { $0["name"] as? String == "materialized" }
        XCTAssertEqual(materialized?["status"] as? String, "warn")
        let detail = materialized?["detail"] as? String ?? ""
        XCTAssertTrue(detail.contains("iCloud keeps full copies"))
        XCTAssertTrue(detail.contains("locally"))
        #if !os(macOS)
        XCTAssertEqual(report["ok"] as? Bool, true)
        #endif
        let summary = LocalEviction.summarize(engine.materialFilesOverride ?? [], repoLooksLikeICloud: true)
        XCTAssertEqual(summary.localBytes, 7 * 1_073_741_824)
        XCTAssertEqual(summary.logicalBytes, 8 * 1_073_741_824)
    }

    func testBackupRemovalWarningDoesNotFailThePack() {
        let path = "/Applications/.isenough-original-ABC.app"
        let warning = BackupRemoval.warning(backupPath: path)
        XCTAssertTrue(warning.contains(path))
        XCTAssertTrue(warning.contains("isenough cleanup-backups"))
        XCTAssertTrue(warning.contains("administrator prompt"))
        XCTAssertFalse(warning.lowercased().contains("password"))
    }

    func testCleanupVerifiesStubAndImageBeforeOneAdminPrompt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        let repo = root.appendingPathComponent("repo")
        let bytes = Data("image-bytes".utf8)
        let sha = SHA256Digest.hex(bytes)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "Example", appPathInVolume: "Example.app")
        let manifest = ImageManifest(bundleId: "com.example.App", name: "Example", version: "1.0", image: image, app: .init(originalPath: apps.appendingPathComponent("Example.app").path, executable: "Example", documentTypes: [], urlTypes: []))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try bytes.write(to: repo.appendingPathComponent("images/\(manifest.imageId).dmg"))
        try manifest.encode().write(to: repo.appendingPathComponent("manifests/\(manifest.imageId).json"))
        try writeStub(apps.appendingPathComponent("Example.app"), manifest: manifest)
        try writeBackup(apps.appendingPathComponent(".isenough-original-AAA.app"), bundleId: "com.example.App")
        try writeBackup(apps.appendingPathComponent(".isenough-original-BBB.app"), bundleId: "com.example.Other")

        let facts = BackupScanner.facts(roots: [apps], repoPath: repo.path)
        XCTAssertEqual(facts.count, 2)
        let removable = facts.filter { if case .remove = BackupCleanup.decide($0) { return true }; return false }
        XCTAssertEqual(removable.map(\.path), [apps.appendingPathComponent(".isenough-original-AAA.app").path])
        XCTAssertTrue(BackupCleanup.decide(facts.first { $0.bundleId == "com.example.Other" }!).keepReason.contains("no stub"))

        var engine = try engine(root, repo: repo)
        var batches: [[String]] = []
        let report = try engine.cleanupBackups(roots: [apps]) { batches.append($0) }
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0], [apps.appendingPathComponent(".isenough-original-AAA.app").path])
        XCTAssertEqual(report.removed, batches[0])
        XCTAssertTrue(report.kept.contains { $0.contains(".isenough-original-BBB.app") })

        let mismatch = BackupFact(path: "/Applications/.isenough-original-CCC.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: String(repeating: "ab", count: 32), imageObjectExists: true)
        if case .keep(let reason) = BackupCleanup.decide(mismatch) {
            XCTAssertTrue(reason.contains("image sha"))
        } else {
            XCTFail("a different image hash must be kept")
        }
        let dataless = BackupFact(path: "/Applications/.isenough-original-DDD.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: nil, imageObjectExists: true)
        XCTAssertEqual(BackupCleanup.decide(dataless), .remove)
        let missing = BackupFact(path: "/Applications/.isenough-original-EEE.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: nil, imageObjectExists: false)
        if case .keep(let reason) = BackupCleanup.decide(missing) {
            XCTAssertTrue(reason.contains("missing"))
        } else {
            XCTFail("a missing image must be kept")
        }
    }

    func testAdminScriptIsOnePromptAndQuotesEveryPath() {
        let paths = ["/Applications/My App.app", "/Applications/.isenough-original-A\"B.app"]
        let script = AdminShell.appleScript(removing: paths)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("rm -rf --"))
        XCTAssertTrue(script.contains("quoted form of"))
        XCTAssertTrue(script.contains("/Applications/My App.app"))
        XCTAssertTrue(script.contains("\\\""))
        XCTAssertFalse(script.lowercased().contains("password"))
        XCTAssertEqual(script.components(separatedBy: "do shell script").count, 2)
    }

    func testCleanupBatchesEveryVerifiedBackupIntoOneCall() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var engine = try engine(root)
        engine.backupFactsOverride = [
            BackupFact(path: "/Applications/.isenough-original-ONE.app", bundleId: "a", stubSHA: "aa", repoSHA: "aa", imageSHA: "aa", imageObjectExists: true),
            BackupFact(path: "/Applications/.isenough-original-TWO.app", bundleId: "b", stubSHA: "bb", repoSHA: "bb", imageSHA: "bb", imageObjectExists: true),
        ]
        var batches: [[String]] = []
        let report = try engine.cleanupBackups { batches.append($0) }
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].count, 2)
        XCTAssertEqual(report.removed.count, 2)
        XCTAssertTrue(report.kept.isEmpty)
    }

    private func file(_ path: String, ubiquitous: Bool, uploaded: Bool, uploading: Bool = false, uploadFailed: Bool = false, logical: UInt64, allocated: UInt64, pinned: Bool = false, dataless: Bool = false, inUse: Bool = false, protectedUntil: Date? = nil, uploadKnown: Bool = true, uploadPercent: Double? = nil) -> MaterialFile {
        MaterialFile(relativePath: path, logicalBytes: logical, allocatedBytes: allocated, ubiquitous: ubiquitous, uploaded: uploaded, uploading: uploading, uploadFailed: uploadFailed, pinned: pinned, dataless: dataless, inUse: inUse, protectedUntil: protectedUntil, uploadKnown: uploadKnown, uploadPercent: uploadPercent)
    }

    private func writeStub(_ url: URL, manifest: ImageManifest) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "\(manifest.bundleId).256stub", "CFBundleExecutable": "isenough-stub", "CFBundleName": manifest.name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let stub: [String: Any] = ["schema": "stub/1", "appId": manifest.bundleId, "imageId": manifest.imageId]
        try JSONSerialization.data(withJSONObject: stub).write(to: url.appendingPathComponent("Contents/Resources/stub.json"))
        try manifest.encode().write(to: url.appendingPathComponent("Contents/Resources/manifest.json"))
    }

    private func writeBackup(_ url: URL, bundleId: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleName": "Backup"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func engine(_ root: URL, repo: URL? = nil) throws -> IsenoughEngine {
        let repo = repo ?? root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let config = RuntimeConfig(
            repoPath: repo.path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mounts").path,
            stubDir: root.appendingPathComponent("Applications").path
        )
        return IsenoughEngine(config: config)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("isenough-local-\(UUID().uuidString)")
    }
}

private extension BackupDecision {
    var keepReason: String {
        if case .keep(let reason) = self { return reason }
        return ""
    }
}
