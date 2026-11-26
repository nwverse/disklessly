import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class StagingReaperTests: XCTestCase {
    func testOnlyOldPartsAreReaped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reaper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = try LocalFolderBackend(root: root)
        try backend.ensureCollection("files/staging")
        try backend.ensureCollection("staging")
        try backend.put("files/staging/old.part", data: Data("x".utf8))
        try backend.put("staging/old2.part", data: Data("y".utf8))
        try backend.put("files/staging/fresh.part", data: Data("z".utf8))
        try backend.put("files/staging/keep.json", data: Data("{}".utf8))
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        for p in ["files/staging/old.part", "staging/old2.part", "files/staging/keep.json"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(p).path)
        }
        let lines = StagingReaper.reap(backend, now: Date())
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertNil(try backend.stat("files/staging/old.part"))
        XCTAssertNil(try backend.stat("staging/old2.part"))
        XCTAssertNotNil(try backend.stat("files/staging/fresh.part"))
        XCTAssertNotNil(try backend.stat("files/staging/keep.json"))
    }

    func testDriveDeletesSkipTheTrash() {
        XCTAssertEqual(RcloneBackend.deleteOverrides(type: "drive"), ["use_trash": "false"])
        XCTAssertEqual(RcloneBackend.deleteOverrides(type: "s3"), [:])
        XCTAssertEqual(RcloneBackend.withOverrides("gdrive:Disklessly/a", ["use_trash": "false"]), "gdrive,use_trash=false:Disklessly/a")
    }
}
