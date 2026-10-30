import XCTest
import Foundation
@testable import IsenoughCore

final class BackupCleanupShaTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-bsha-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let sha = String(repeating: "cd", count: 32)

    func testNilShaIsNotVerified() {
        let fact = BackupFact(path: "/Applications/.isenough-original-A.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: nil, imageObjectExists: true)
        guard case .keep(let reason) = BackupCleanup.decide(fact) else { return XCTFail("nil sha must keep the backup") }
        XCTAssertTrue(reason.contains("image unverified"))
    }

    func testPlaceholderNeedsMatchingSize() {
        let confirmed = BackupFact(path: "/Applications/.isenough-original-B.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: nil, imageObjectExists: true, imagePlaceholder: true, placeholderSize: 4096, repoSize: 4096)
        XCTAssertEqual(BackupCleanup.decide(confirmed), .remove)
        let wrongSize = BackupFact(path: "/Applications/.isenough-original-C.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: nil, imageObjectExists: true, imagePlaceholder: true, placeholderSize: 10, repoSize: 4096)
        XCTAssertEqual(BackupCleanup.decide(wrongSize), .keep(BackupCleanup.unverifiedReason))
        let unknownSize = BackupFact(path: "/Applications/.isenough-original-D.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: nil, imageObjectExists: true, imagePlaceholder: true, placeholderSize: nil, repoSize: 4096)
        XCTAssertEqual(BackupCleanup.decide(unknownSize), .keep(BackupCleanup.unverifiedReason))
        // A size match only counts for a placeholder, not for an unreadable local file.
        let notPlaceholder = BackupFact(path: "/Applications/.isenough-original-E.app", bundleId: "com.example.App", stubSHA: sha, repoSHA: sha, imageSHA: nil, imageObjectExists: true, imagePlaceholder: false, placeholderSize: 4096, repoSize: 4096)
        XCTAssertEqual(BackupCleanup.decide(notPlaceholder), .keep(BackupCleanup.unverifiedReason))
    }

    func testCleanupKeepsBackupWhenTheDMGIsZeroBytes() throws {
        let apps = root.appendingPathComponent("Applications")
        let repo = root.appendingPathComponent("repo")
        let (manifest, _) = try seed(apps: apps, repo: repo, bytes: Data("real-image".utf8))
        // The DMG in the repo is now empty.
        try Data().write(to: repo.appendingPathComponent("images/\(manifest.imageId).dmg"))
        let facts = BackupScanner.facts(roots: [apps], repoPath: repo.path)
        XCTAssertEqual(facts.count, 1)
        XCTAssertNil(facts[0].imageSHA)
        XCTAssertTrue(facts[0].imageObjectExists)
        XCTAssertEqual(BackupCleanup.decide(facts[0]), .keep(BackupCleanup.unverifiedReason))
    }

    func testCleanupUsesICloudPlaceholderSize() throws {
        let apps = root.appendingPathComponent("Applications")
        let repo = root.appendingPathComponent("repo")
        let bytes = Data("evicted-image".utf8)
        let (manifest, _) = try seed(apps: apps, repo: repo, bytes: bytes)
        let image = repo.appendingPathComponent("images/\(manifest.imageId).dmg")
        try FileManager.default.removeItem(at: image)
        let placeholder = repo.appendingPathComponent("images/.\(manifest.imageId).dmg.icloud")
        let plist: [String: Any] = ["NSURLNameKey": "\(manifest.imageId).dmg", "NSURLFileSizeKey": bytes.count]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: placeholder)
        let facts = BackupScanner.facts(roots: [apps], repoPath: repo.path)
        XCTAssertEqual(facts.first?.imagePlaceholder, true)
        XCTAssertEqual(facts.first?.placeholderSize, UInt64(bytes.count))
        XCTAssertEqual(facts.first.map(BackupCleanup.decide), .remove)

        let wrong: [String: Any] = ["NSURLNameKey": "\(manifest.imageId).dmg", "NSURLFileSizeKey": bytes.count + 1]
        try PropertyListSerialization.data(fromPropertyList: wrong, format: .binary, options: 0).write(to: placeholder)
        let again = BackupScanner.facts(roots: [apps], repoPath: repo.path)
        XCTAssertEqual(again.first.map(BackupCleanup.decide), .keep(BackupCleanup.unverifiedReason))
    }

    private func seed(apps: URL, repo: URL, bytes: Data) throws -> (ImageManifest, URL) {
        let sha = SHA256Digest.hex(bytes)
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "Example", appPathInVolume: "Example.app")
        let manifest = ImageManifest(bundleId: "com.example.App", name: "Example", version: "1.0", image: image, app: .init(originalPath: apps.appendingPathComponent("Example.app").path, executable: "Example", documentTypes: [], urlTypes: []))
        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("images"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try bytes.write(to: repo.appendingPathComponent("images/\(manifest.imageId).dmg"))
        try manifest.encode().write(to: repo.appendingPathComponent("manifests/\(manifest.imageId).json"))
        let stub = apps.appendingPathComponent("Example.app")
        try fm.createDirectory(at: stub.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let stubPlist: [String: Any] = ["CFBundleIdentifier": "com.example.App.256stub", "CFBundleExecutable": "isenough-stub"]
        try PropertyListSerialization.data(fromPropertyList: stubPlist, format: .xml, options: 0).write(to: stub.appendingPathComponent("Contents/Info.plist"))
        let stubJSON: [String: Any] = ["schema": "stub/1", "appId": "com.example.App", "imageId": manifest.imageId]
        try JSONSerialization.data(withJSONObject: stubJSON).write(to: stub.appendingPathComponent("Contents/Resources/stub.json"))
        try manifest.encode().write(to: stub.appendingPathComponent("Contents/Resources/manifest.json"))
        let backup = apps.appendingPathComponent(".isenough-original-AAA.app")
        try fm.createDirectory(at: backup.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.App", "CFBundleExecutable": "Example"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: backup.appendingPathComponent("Contents/Info.plist"))
        return (manifest, backup)
    }
}
