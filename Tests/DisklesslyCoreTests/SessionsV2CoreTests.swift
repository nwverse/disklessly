import XCTest
import Crypto
import Foundation
import DisklesslyCore
@testable import DisklesslySessions

final class SessionsV2CoreTests: XCTestCase {
    func testTarRoundTripAndSystemTarCompat() throws {
        let body = Data("hello session\n".utf8)
        let archive = try TarWriter.archive([
            (name: "index.json", data: Data("{\"schema\":\"session-segment/1\"}".utf8), mtime: Date(timeIntervalSince1970: 1_700_000_000)),
            (name: "m/abc.jsonl", data: body, mtime: Date(timeIntervalSince1970: 1_700_000_100)),
        ])
        let listed = try systemTarList(archive)
        XCTAssertEqual(listed, ["index.json", "m/abc.jsonl"])
        let read = try TarReader.entries(archive)
        XCTAssertEqual(read.map(\.name), ["index.json", "m/abc.jsonl"])
        XCTAssertEqual(read[1].data, body)
        var directory = archive
        directory[156] = UInt8(ascii: "5")
        XCTAssertThrowsError(try TarReader.entries(directory)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5)
        }
    }

    func testZstdRoundTripAndRatio() throws {
        let pad = String(repeating: "alpha beta gamma delta ", count: 30)
        var text = ""
        for index in 0..<2000 {
            text += "{\"n\":\(index),\"text\":\"\(pad) \(index % 5)\"}\n"
        }
        let input = Data(text.utf8)
        XCTAssertGreaterThan(input.count, 800_000)
        let compressed = try Zstd.compress(input, level: 3)
        XCTAssertGreaterThanOrEqual(Double(input.count) / Double(compressed.count), 2.4)
        let restored = try Zstd.decompress(compressed, maxBytes: input.count + 10)
        XCTAssertEqual(restored, input)
        XCTAssertThrowsError(try Zstd.decompress(compressed, maxBytes: 64)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5)
        }
    }

    func testCryptoRoundTripAADBinding() throws {
        let key = SymmetricKey(size: .bits256)
        let id = SegmentCrypto.keyId(for: key)
        let plain = Data("segment-bytes".utf8)
        let aad = Data("sessions/dev/claude/file.tar.zst".utf8)
        let envelope = try SegmentCrypto.seal(plain: plain, key: key, aad: aad)
        let opened = try SegmentCrypto.open(envelope: envelope, keyring: [id: key], aad: aad)
        XCTAssertEqual(opened, plain)
        XCTAssertThrowsError(try SegmentCrypto.open(envelope: envelope, keyring: [id: key], aad: Data("other".utf8)))
        var flipped = envelope
        flipped[flipped.count - 20] ^= 0x01
        XCTAssertThrowsError(try SegmentCrypto.open(envelope: flipped, keyring: [id: key], aad: aad))
        XCTAssertThrowsError(try SegmentCrypto.open(envelope: envelope, keyring: [:], aad: aad)) { error in
            let message = (error as? DisklesslyError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("unknown key \(id)"))
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5)
        }
    }

    func testIndexSchemaAndFtsFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-idx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try SessionIndexDB(stateDir: root.path)
        var rows: [SessionEntryRow] = []
        for index in 0..<2000 {
            let preview = index == 1337 ? "unique needleword in the preview" : "ordinary row \(index)"
            rows.append(SessionEntryRow(id: String(format: "id%04d", index), segmentId: nil, legacyArchive: nil, member: "m/\(index).jsonl", deviceId: "dev", tool: "claude", path: "/tmp/p/\(index).jsonl", sha256: String(repeating: "ab", count: 32), size: 10, mtimeNs: 1, ino: nil, preview: preview, archivedAt: "2025-01-01T00:00:00Z", state: "archived"))
        }
        try db.insert(entries: rows)
        let started = Date()
        let found = try db.search(query: "needleword", limit: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(found, ["id1337"])
        db.ftsAvailable = false
        XCTAssertEqual(try db.search(query: "needleword", limit: 10), ["id1337"])
    }

    func testIndexRefusesNewerUserVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-idx-new-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, "PRAGMA user_version = 4;"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try SessionIndexDB(stateDir: root.path)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 3)
        }
    }

    private func systemTarList(_ data: Data) throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-tar-\(UUID().uuidString).tar")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text.split(separator: "\n").map(String.init)
    }
}
