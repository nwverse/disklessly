import XCTest
import Foundation
import DisklesslySessions
@testable import DisklesslyEngine

/// bsdtar stops reading at the end-of-archive blocks. Bytes after them (record padding, or more)
/// must not kill the process with SIGPIPE while they are written into tar's stdin.
final class FolderArchiveExtractTests: XCTestCase {
    func testTrailingBytesAfterTheEndOfArchiveDoNotRaiseSIGPIPE() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-tar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src/Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("f.txt"))

        let tarFile = root.appendingPathComponent("a.tar")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", tarFile.path, "-C", src.deletingLastPathComponent().path, "Folder"]
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        // 32 MiB after the archive: far more than a pipe buffer, so tar exits while it is still being written.
        let padded = try Data(contentsOf: tarFile) + Data(count: 32 << 20)
        try padded.write(to: tarFile)

        let archive = root.appendingPathComponent("a.tar.zst")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let input = try FileHandle(forReadingFrom: tarFile), output = try FileHandle(forWritingTo: archive)
        try ZstdStream.compress(from: input, to: output)
        try input.close(); try output.close()

        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FolderArchive.extract(archive: archive, into: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Folder/f.txt"), encoding: .utf8), "hello")
    }
}
