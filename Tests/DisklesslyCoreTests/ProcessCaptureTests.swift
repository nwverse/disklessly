import Foundation
import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class ProcessCaptureTests: XCTestCase {
    func testDrainsLargeStdoutAndStderrConcurrently() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "yes o | head -c 1048576; yes e | head -c 1048576 >&2"]

        let result = try ProcessCapture.run(process, timeout: 10)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 1_048_576)
        XCTAssertEqual(result.stderr.count, 1_048_576)
    }

    func testTimeoutTerminatesTheChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]
        let started = Date()

        let result = try ProcessCapture.run(process, timeout: 0.25)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(process.isRunning)
    }

    #if os(macOS)
    func testShareOpenerConsumesLargeMountOutput() throws {
        try ShareOpener.system.run(ShareMountCommand(
            executable: "/bin/sh",
            arguments: ["-c", "yes x | head -c 1048576"]
        ))
    }
    #endif

    func testTarListDrainsAListingLargerThanThePipeBuffer() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tar") else {
            throw XCTSkip("tar is not installed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-tar-list-\(UUID().uuidString)")
        let members = root.appendingPathComponent("members")
        let archive = root.appendingPathComponent("members.tar.gz")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: members, withIntermediateDirectories: true)
        for index in 0..<1_100 {
            let name = String(format: "%012x-%048d.jsonl", index, index)
            try Data().write(to: members.appendingPathComponent(name))
        }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", members.path, "."]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let listing = try SessionTierV2.tarList(archive)

        XCTAssertGreaterThan(listing.count, 1_000)
        XCTAssertTrue(listing.contains { $0.hasSuffix(".jsonl") })
    }
}
