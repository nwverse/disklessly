import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import IsenoughCore

final class PackPreflightTests: XCTestCase {
    func testSpaceFormulaExactBoundary() {
        let mebi = UInt64(1024 * 1024)
        let gibi = mebi * 1024
        let allocated = 1000 * mebi
        let minFree = 15 * gibi
        let probe = PackPreflight.space(appAllocated: allocated, free: 0, cloneSupported: false, repoOnSameVolume: true, minFree: minFree)
        let need = probe.need
        let enough = PackPreflight.space(appAllocated: allocated, free: need, cloneSupported: false, repoOnSameVolume: true, minFree: minFree)
        XCTAssertNil(enough.error)
        XCTAssertEqual(enough.need, need)
        let short = PackPreflight.space(appAllocated: allocated, free: need - 1, cloneSupported: false, repoOnSameVolume: true, minFree: minFree)
        XCTAssertEqual(short.error?.exitCode, 8)
        XCTAssertTrue(short.error?.errorDescription?.contains(String(need)) == true)
    }

    func testCloneRemovesStagingTerm() {
        let allocated: UInt64 = 1000 * 1024 * 1024
        let minFree: UInt64 = 15 * 1024 * 1024 * 1024
        let copied = PackPreflight.space(appAllocated: allocated, free: 0, cloneSupported: false, repoOnSameVolume: false, minFree: minFree)
        let cloned = PackPreflight.space(appAllocated: allocated, free: 0, cloneSupported: true, repoOnSameVolume: false, minFree: minFree)
        XCTAssertEqual(copied.need - cloned.need, allocated)
    }

    func testRunningUnknownIsBusy() {
        XCTAssertEqual(PackPreflight.running(.unknown)?.exitCode, 9)
        XCTAssertEqual(PackPreflight.running(.busy)?.exitCode, 9)
        XCTAssertEqual(PackPreflight.running(.held)?.exitCode, 9)
        XCTAssertNil(PackPreflight.running(.clean))
    }

    func testAllocatedSizeOfTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-alloc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["a.bin", "nested/b.bin", "nested/c.bin"]
        for name in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 3000).write(to: url)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.bin"), withDestinationURL: root.appendingPathComponent("a.bin"))
        var expected: UInt64 = 0
        for name in files {
            var info = stat()
            XCTAssertEqual(lstat(root.appendingPathComponent(name).path, &info), 0)
            expected += UInt64(info.st_blocks) * 512
        }
        XCTAssertEqual(AllocatedSize.tree(root), expected)
    }

    func testPackModeValidation() throws {
        XCTAssertThrowsError(try PackArguments.parse(["App.app", "--mode", "mnt"])) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 2)
            XCTAssertTrue(((error as? IsenoughError)?.errorDescription ?? "").contains("invalid --mode"))
        }
        XCTAssertThrowsError(try PackArguments.parse(["App.app", "--mode"])) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 2)
        }
        XCTAssertThrowsError(try PackArguments.parse(["App.app", "--bogus"])) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 2)
            XCTAssertTrue(((error as? IsenoughError)?.errorDescription ?? "").contains("unknown pack option"))
        }
        let parsed = try PackArguments.parse(["App.app", "--image-format", "ulfo", "--mode", "restore"])
        XCTAssertEqual(parsed.imageFormat, "ULFO")
        XCTAssertEqual(parsed.mode, .restore)
    }

    func testManifestAcceptsULFO() throws {
        let image = ImageManifest.Image(file: "images/a.dmg", format: "ULFO", sha256: String(repeating: "a", count: 64), size: 3, volumeName: "A", appPathInVolume: "A.app")
        let app = ImageManifest.App(originalPath: "/Applications/A.app", executable: "A", documentTypes: [], urlTypes: [])
        let manifest = ImageManifest(bundleId: "com.test.a", name: "A", version: "1.0", image: image, app: app)
        XCTAssertNoThrow(try manifest.validate())
        var rejected = manifest
        rejected.image.format = "UDZO"
        XCTAssertThrowsError(try rejected.validate())
    }
}
