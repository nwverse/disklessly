import XCTest
@testable import IsenoughCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A journal owner that was killed but not yet reaped is a zombie. It must not
/// keep the restore coordinator in `noopLiveOwner` forever (e2e A33 hang).
final class ZombieOwnerTests: XCTestCase {
    func testUnreapedChildIsNotAlive() throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup("exit 0"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sh", nil, nil, argv, nil), 0)
        defer { var status: Int32 = 0; waitpid(pid, &status, 0) }
        let owner = ProcessOwner(pid: pid, start: ProcessStart.ticks(for: pid))
        // Wait for the child to exit; it stays a zombie until waitpid.
        let deadline = Date().addingTimeInterval(5)
        while !ProcessStart.isZombie(pid), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(ProcessStart.isZombie(pid))
        XCTAssertEqual(kill(pid, 0), 0, "a zombie still answers kill(pid, 0)")
        XCTAssertFalse(ProcessStart.isAlive(owner))
        XCTAssertTrue(ProcessStart.isAlive(ProcessOwner.current()))
    }
}
