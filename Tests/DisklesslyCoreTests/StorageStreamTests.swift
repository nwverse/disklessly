import XCTest
import Foundation
@testable import DisklesslyCore

final class StorageStreamTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLocalPutStreamThenMoveKeepsNoStagingCopy() throws {
        let backend = try LocalFolderBackend(root: root)
        try backend.putStream("files/staging/a.part") { handle in
            try handle.write(contentsOf: Data("streamed".utf8))
        }
        XCTAssertEqual(try backend.get("files/staging/a.part", range: nil), Data("streamed".utf8))
        try backend.move("files/staging/a.part", to: "files/objects/abc.bin")
        XCTAssertNil(try backend.stat("files/staging/a.part"))
        XCTAssertEqual(try backend.get("files/objects/abc.bin", range: nil), Data("streamed".utf8))
    }

    func testLocalMoveNeverReplacesExistingObject() throws {
        let backend = try LocalFolderBackend(root: root)
        try backend.put("files/objects/x.bin", data: Data("old".utf8))
        try backend.putStream("files/staging/b.part") { try $0.write(contentsOf: Data("new".utf8)) }
        XCTAssertThrowsError(try backend.move("files/staging/b.part", to: "files/objects/x.bin"))
        XCTAssertEqual(try backend.get("files/objects/x.bin", range: nil), Data("old".utf8))
    }
}
