import XCTest
@testable import DisklesslyEngine

final class BundleProcessesTests: XCTestCase {
    func testStopQuitsProcessesInsideTheBundleOnly() throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bp-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Helper Host.app")
        let helpers = bundle.appendingPathComponent("Contents/Library/LoginItems")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A copied /bin/sleep can be killed for running outside /bin, so build a tiny binary.
        let source = root.appendingPathComponent("wait.c")
        try "#include <unistd.h>\nint main(void){sleep(60);return 0;}\n".write(to: source, atomically: true, encoding: .utf8)
        let inside = helpers.appendingPathComponent("helper")
        let cc = try Process.run(URL(fileURLWithPath: "/usr/bin/cc"), arguments: ["-o", inside.path, source.path])
        cc.waitUntilExit()
        try XCTSkipUnless(cc.terminationStatus == 0, "no C compiler")
        let outside = root.appendingPathComponent("wait-outside")
        try FileManager.default.copyItem(at: inside, to: outside)
        let a = try Process.run(inside, arguments: ["60"])
        let b = try Process.run(outside, arguments: ["60"])
        defer { if b.isRunning { b.terminate() } }
        var tries = 0
        while BundleProcesses.pids(inBundle: bundle.path).isEmpty && tries < 50 { usleep(100_000); tries += 1 }
        XCTAssertEqual(BundleProcesses.pids(inBundle: bundle.path), [a.processIdentifier])
        XCTAssertEqual(try BundleProcesses.stop(bundlePath: bundle.path, grace: 5), 1)
        a.waitUntilExit()
        XCTAssertTrue(BundleProcesses.pids(inBundle: bundle.path).isEmpty, "\(BundleProcesses.pids(inBundle: bundle.path))")
        XCTAssertTrue(b.isRunning)
        XCTAssertEqual(try BundleProcesses.stop(bundlePath: bundle.path), 0)
        #endif
    }
}
