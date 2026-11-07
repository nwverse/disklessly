import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

/// Installs made before the rename to Disklessly used `isenough` / `256isenough` names.
final class LegacyNameTests: XCTestCase {
    func testOldAndNewBackupNamesAreBothLeftovers() {
        for name in [".isenough-original-ABC.app", ".disklessly-original-ABC.app", ".isenough-x.app", ".256isenough-staging", ".disklessly-staging", "Foo.256orig.app"] {
            XCTAssertTrue(RecommendPaths.isLeftoverBackupName(name), name)
        }
        XCTAssertFalse(RecommendPaths.isLeftoverBackupName("Keynote.app"))
        XCTAssertFalse(RecommendPaths.isLeftoverBackupName(".DS_Store"))
    }

    func testCleanupDoesNotRejectAnOldNamedBackupByName() {
        let fact = BackupFact(path: "/Applications/.isenough-original-ABC.app", bundleId: "com.apple.Keynote", stubSHA: nil, repoSHA: nil, imageSHA: nil, imageObjectExists: false, imagePlaceholder: false)
        if case .keep(let reason) = BackupCleanup.decide(fact) {
            XCTAssertFalse(reason.contains("not a Disklessly original backup"), reason)
        }
        let other = BackupFact(path: "/Applications/Foo.app", bundleId: "com.example.Foo", stubSHA: nil, repoSHA: nil, imageSHA: nil, imageObjectExists: false, imagePlaceholder: false)
        XCTAssertEqual(BackupCleanup.decide(other), .keep("not a Disklessly original backup"))
    }

    func testExistingOldFoldersAreKeptButNewInstallsUseNewNames() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        let fresh = RuntimeConfig.environment([:], home: home, platform: .macOS)
        XCTAssertEqual(fresh.stateDir, "\(home)/Library/Application Support/Disklessly")
        XCTAssertEqual(fresh.cacheDir, "\(home)/Library/Caches/Disklessly")
        XCTAssertEqual(fresh.mountRoot, "\(home)/Library/Caches/Disklessly/mnt")

        for parent in ["Library/Application Support", "Library/Caches"] {
            try fm.createDirectory(atPath: "\(home)/\(parent)/256isenough", withIntermediateDirectories: true)
        }
        let old = RuntimeConfig.environment([:], home: home, platform: .macOS)
        XCTAssertEqual(old.stateDir, "\(home)/Library/Application Support/256isenough")
        XCTAssertEqual(old.cacheDir, "\(home)/Library/Caches/256isenough")
        XCTAssertEqual(old.mountRoot, "\(home)/Library/Caches/256isenough/mnt")

        // Once the new folder exists it wins, and an explicit override always wins.
        try fm.createDirectory(atPath: "\(home)/Library/Application Support/Disklessly", withIntermediateDirectories: true)
        XCTAssertEqual(RuntimeConfig.environment([:], home: home, platform: .macOS).stateDir, "\(home)/Library/Application Support/Disklessly")
        XCTAssertEqual(RuntimeConfig.environment(["DISKLESSLY_STATE_DIR": "/tmp/x"], home: home, platform: .macOS).stateDir, "/tmp/x")
    }
}
