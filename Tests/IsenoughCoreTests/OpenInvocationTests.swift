import XCTest
@testable import IsenoughCore

final class OpenInvocationTests: XCTestCase {
    func testNeverUsesDashN() {
        let apps = ["Example.app"]
        let documents = [[], ["/tmp/a.txt"]]
        let arguments = [[], ["--flag"]]
        for already in [false, true] {
            for docs in documents {
                for args in arguments {
                    let built = OpenInvocation.arguments(app: apps[0], documents: docs, urls: [], arguments: args, alreadyRunning: already)
                    XCTAssertFalse(built.argv.contains("-n"))
                }
            }
        }
    }

    func testRunningInstanceDropsArgsWithWarning() {
        let built = OpenInvocation.arguments(app: "Keynote.app", documents: [], urls: [], arguments: ["--slide"], alreadyRunning: true)
        XCTAssertFalse(built.argv.contains("--args"))
        XCTAssertFalse(built.argv.contains("--slide"))
        XCTAssertEqual(built.warnings, ["Keynote.app is already running; launch arguments were not passed"])
        let fresh = OpenInvocation.arguments(app: "Keynote.app", documents: [], urls: [], arguments: ["--slide"], alreadyRunning: false)
        XCTAssertEqual(fresh.argv.suffix(2), ["--args", "--slide"])
        XCTAssertTrue(fresh.warnings.isEmpty)
    }

    func testDocumentsForwarded() {
        let built = OpenInvocation.arguments(app: "App.app", documents: ["/tmp/a.txt", "/tmp/b.txt"], urls: ["https://example.test"], arguments: [], alreadyRunning: true)
        XCTAssertEqual(built.argv, ["/usr/bin/open", "-a", "App.app", "/tmp/a.txt", "/tmp/b.txt", "https://example.test"])
    }
}
