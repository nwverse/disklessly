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
