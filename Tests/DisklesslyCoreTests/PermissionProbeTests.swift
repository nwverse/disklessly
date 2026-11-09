import XCTest
@testable import DisklesslyEngine

final class PermissionProbeTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func app(_ name: String) throws {
        let contents = dir + "/\(name).app/Contents"
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: contents + "/Info.plist"))
    }

    func testAppManagementProbesOnlyOtherTeamsApps() throws {
        for name in ["Ours", "AdHoc", "Other", "Third"] { try app(name) }
        try app(".hidden-original")
        let teams = ["Ours": "MYTEAM", "Other": "OTHER1", "Third": "OTHER2", ".hidden-original": "OTHER3"]
        let targets = PermissionProbe.appManagementTargets(applications: [dir], ownTeamId: "MYTEAM") { path in
            teams[URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent]
        }
        XCTAssertEqual(targets.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent },
                       ["Other.app", "Third.app"], "our own, ad-hoc and hidden backups prove nothing")
        XCTAssertTrue(targets.allSatisfy { $0.hasSuffix("/Contents/Info.plist") })
    }

    func testAppManagementTargetsAreCapped() throws {
        for i in 0..<6 { try app("A\(i)") }
        XCTAssertEqual(PermissionProbe.appManagementTargets(applications: [dir], ownTeamId: nil, teamId: { _ in "T" }, limit: 3).count, 3)
    }

    func testAppManagementIsUnknownWithoutTargets() {
        XCTAssertEqual(PermissionProbe.appManagement(applications: [dir], ownTeamId: nil), .unknown)
    }

    func testFullDiskAccessTriesEachProtectedFileInTurn() throws {
        let missing = dir + "/missing.db", readable = dir + "/readable.db", locked = dir + "/locked"
        XCTAssertEqual(PermissionProbe.fullDiskAccess(candidates: [missing]), .unknown, "nothing to test")
        try Data().write(to: URL(fileURLWithPath: readable))
        XCTAssertEqual(PermissionProbe.fullDiskAccess(candidates: [missing, readable]), .granted, "a missing file is skipped")
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: locked + "/f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked + "/f")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked + "/f") }
        if getuid() != 0 {
            XCTAssertEqual(PermissionProbe.fullDiskAccess(candidates: [missing, locked + "/f", readable]), .denied, "the first file that exists decides")
        }
        XCTAssertTrue(PermissionProbe.fullDiskAccessCandidates(home: dir).contains("/Library/Application Support/com.apple.TCC/TCC.db"))
    }

    func testSettingsLinksPointAtTheRightPanes() {
        XCTAssertTrue(MacPermission.appManagement.settingsURLs.allSatisfy { $0.absoluteString.hasSuffix("Privacy_AppBundles") })
        XCTAssertTrue(MacPermission.fullDiskAccess.settingsURLs.allSatisfy { $0.absoluteString.hasSuffix("Privacy_AllFiles") })
        XCTAssertTrue(MacPermission.appManagement.required)
        XCTAssertFalse(MacPermission.fullDiskAccess.required)
    }
}
