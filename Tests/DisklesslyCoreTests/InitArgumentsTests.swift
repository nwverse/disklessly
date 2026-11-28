import XCTest
import DisklesslyCore

final class InitArgumentsTests: XCTestCase {
    func testParsesSupportedOptions() throws {
        XCTAssertEqual(
            try InitArguments.parse(["--backend", "local", "--root", "/Volumes/NAS/Disklessly", "--cache-dir", "/tmp/cache", "--quota", "200M"]),
            InitArguments(backend: "local", root: "/Volumes/NAS/Disklessly", cacheDir: "/tmp/cache", quotaBytes: 200 * 1024 * 1024)
        )
    }

    func testRejectsMissingUnknownPositionalAndEqualsSyntax() {
        let rejected: [([String], String)] = [
            (["--backend"], "--backend requires a value"),
            (["--root"], "--root requires a value"),
            (["--cache-dir"], "--cache-dir requires a value"),
            (["--quota"], "--quota requires a value"),
            (["--root", "--cache-dir", "/tmp/cache"], "--root requires a value"),
            (["--repo", "/tmp/repo"], "Unknown option: --repo"),
            (["/tmp/repo"], "init does not take a positional argument: /tmp/repo"),
            (["--root=/Volumes/NAS/Disklessly"], "Unknown option: --root=/Volumes/NAS/Disklessly"),
            (["--quota", "soon"], "invalid size: soon"),
        ]
        for (arguments, message) in rejected {
            XCTAssertThrowsError(try InitArguments.parse(arguments), "\(arguments)") { error in
                XCTAssertEqual(error as? DisklesslyError, .usage(message))
            }
        }
    }
}
