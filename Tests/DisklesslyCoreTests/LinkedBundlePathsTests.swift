import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class LinkedBundlePathsTests: XCTestCase {
    func testNestedPathIsDroppedInFavorOfItsParent() {
        let paths = ["/Users/u/.vphone/machines/wechat-ipad", "/Users/u/.vphone"]
        XCTAssertEqual(DisklesslyEngine.outermostPaths(paths), ["/Users/u/.vphone"])
    }

    func testSiblingsAndPrefixLookalikesStay() {
        let paths = ["/Users/u/.vphone", "/Users/u/.vphone2", "/Users/u/Library/App"]
        XCTAssertEqual(DisklesslyEngine.outermostPaths(paths), paths)
    }

    func testDuplicatesCollapseAndTrailingSlashIsIgnored() {
        XCTAssertEqual(DisklesslyEngine.outermostPaths(["/a/b", "/a/b/", "/a/b/c"]), ["/a/b"])
    }
}

final class RcloneErrorClassifyTests: XCTestCase {
    func testDriveQuotaErrorBecomesNoSpace() {
        let e = RcloneBackend.classify("rclone rcat failed (exit 1): googleapi: Error 403: The user's Drive storage quota has been exceeded., storageQuotaExceeded")
        guard case .noSpace(let text) = e else { return XCTFail("\(e)") }
        XCTAssertTrue(text.hasPrefix("the cloud drive is full"))
    }

    func testOtherErrorsStayBackend() {
        XCTAssertEqual(RcloneBackend.classify("rclone stat failed: timeout"), .backend("rclone stat failed: timeout"))
    }
}

final class RcloneStreamingFailureTests: XCTestCase {
    /// rclone refusing the upload closes its stdin; the caller must see rclone's error, not EPIPE.
    func testEarlyRcloneExitWinsOverTheBrokenPipe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rclone-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("rclone")
        try "#!/bin/sh\necho 'googleapi: Error 403: storageQuotaExceeded' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let config = dir.appendingPathComponent("rclone.conf")
        try "".write(to: config, atomically: true, encoding: .utf8)
        _ = signal(SIGPIPE, SIG_IGN)
        let result = try RcloneTool.run(binary: fake, config: config.path, ["rcat", "x:y"], streaming: { handle in
            let block = Data(count: 1 << 20)
            for _ in 0..<256 { try handle.write(contentsOf: block) }
        })
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("storageQuotaExceeded"))
    }
}
