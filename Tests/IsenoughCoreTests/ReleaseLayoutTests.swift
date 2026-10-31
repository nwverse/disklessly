import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import IsenoughCore

/// Runs a copy of the built `isenough` outside `.build`, the way a release or
/// Homebrew install lays it out, so `Bundle.module` can never be the web root.
final class ReleaseLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCopiedBinaryServesUIFromResourcesSibling() throws {
        let binary = try installCopy(webAt: "Resources/web")
        let (url, process) = try startUI(binary)
        defer { stop(process) }
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:"), url)
        XCTAssertTrue(url.contains("/?token="), url)
        XCTAssertTrue(process.isRunning, "isenough ui exited after printing its URL")
        let page = try fetch(url)
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.body.contains("<html") || page.body.contains("<!doctype") || page.body.contains("<!DOCTYPE"), page.body)
    }

    func testCopiedBinaryServesUIFromShareSibling() throws {
        let binary = try installCopy(webAt: "share/isenough/web")
        let (url, process) = try startUI(binary)
        defer { stop(process) }
        XCTAssertEqual(try fetch(url).status, 200)
    }

    func testMissingWebRootIsAnErrorNotATrap() throws {
        let binary = try installCopy(webAt: nil)
        let result = try run(binary, ["ui", "--json"])
        XCTAssertEqual(result.reason, .exit, "isenough ui crashed instead of reporting the missing page")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.out.contains("index.html") || result.err.contains("index.html"), result.out + result.err)
    }

    func testNoArgumentsExits64WithHint() throws {
        let result = try run(try cliBinary(), [])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.err.contains("isenough help"), result.err)
        XCTAssertFalse(result.out.contains("Environment overrides"), "no-argument run should not dump the full help")
    }

    func testGcJsonRuns() throws {
        let binary = try cliBinary()
        XCTAssertEqual(try run(binary, ["init", "--json"]).status, 0)
        let result = try run(binary, ["gc", "--json"])
        XCTAssertEqual(result.status, 0, result.err)
        let object = try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertNotNil(object?["lines"] as? [String])
    }

    func testHelpIsGroupedAndHidesPlaceholders() throws {
        let result = try run(try cliBinary(), ["help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.out.contains("Usage:"))
        XCTAssertTrue(result.out.contains("resolve APP"))
        XCTAssertTrue(result.out.contains("Get started"))
        XCTAssertTrue(result.out.contains("ui [--open]"))
        for hidden in ["hooks", "serve", "daemon", "stub rebuild"] {
            XCTAssertFalse(result.out.contains(hidden), "help still lists \(hidden)")
        }
    }

    func testPlaceholderCommandsExitUnsupported() throws {
        let binary = try cliBinary()
        for arguments in [["serve"], ["daemon", "status"], ["stub", "rebuild", "X"]] {
            let result = try run(binary, arguments)
            XCTAssertEqual(result.status, 3, "\(arguments) should exit 3 (unsupported): \(result.out)\(result.err)")
        }
    }

    func testVersionJsonHasBuildMetadata() throws {
        let result = try run(try cliBinary(), ["version", "--json"])
        XCTAssertEqual(result.status, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        for key in ["version", "commit", "buildDate", "arch", "revision", "schema"] {
            XCTAssertNotNil(object[key], "version --json lacks \(key)")
        }
        let schemas = object["schemas"] as? [String: String]
        XCTAssertEqual(schemas?["stub"], "stub/1")
        XCTAssertEqual(schemas?["state"], "state/2")
        XCTAssertEqual(schemas?["image"], "image/1")
    }

    func testUnknownAppIsUsageErrorWithoutUserInfo() throws {
        let binary = try cliBinary()
        XCTAssertEqual(try run(binary, ["init"]).status, 0)
        let result = try run(binary, ["launch", "NoSuchApp"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.err.contains("Unknown app: NoSuchApp"), result.err)
        XCTAssertFalse(result.err.contains("details:"))
    }

    // MARK: - helpers

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ISENOUGH_WEB_ROOT")
        env.removeValue(forKey: "ISENOUGH_CONFIG")
        env.removeValue(forKey: "ISENOUGH_DEBUG")
        env["ISENOUGH_REPO_PATH"] = root.appendingPathComponent("repo").path
        env["ISENOUGH_CACHE_DIR"] = root.appendingPathComponent("cache").path
        env["ISENOUGH_STATE_DIR"] = root.appendingPathComponent("state").path
        env["ISENOUGH_MOUNT_ROOT"] = root.appendingPathComponent("mnt").path
        env["ISENOUGH_STUB_DIR"] = root.appendingPathComponent("apps").path
        return env
    }

    /// Copies the CLI to `<root>/release/bin/isenough` with the page at `<root>/release/<webAt>`.
    private func installCopy(webAt: String?) throws -> URL {
        let fm = FileManager.default
        let release = root.appendingPathComponent("release")
        let bin = release.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let copy = bin.appendingPathComponent("isenough")
        try fm.copyItem(at: try cliBinary(), to: copy)
        if let webAt {
            let dest = release.appendingPathComponent(webAt)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: webSource(), to: dest)
        }
        XCTAssertFalse(fm.fileExists(atPath: bin.appendingPathComponent("256isenough_isenough.bundle").path))
        return copy
    }

    private func webSource() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let web = url.appendingPathComponent("Sources/isenough/web")
            if FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path) { return web }
            url.deleteLastPathComponent()
        }
        throw IsenoughError.failure("Sources/isenough/web not found")
    }

    private func startUI(_ binary: URL) throws -> (String, Process) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["ui", "--json"]
        process.environment = environment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let lock = NSLock()
        var buffer = Data()
        let gotLine = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            buffer.append(chunk)
            let complete = buffer.contains(UInt8(ascii: "\n")) || chunk.isEmpty
            lock.unlock()
            if complete {
                handle.readabilityHandler = nil
                gotLine.signal()
            }
        }
        try process.run()
        let waited = gotLine.wait(timeout: .now() + 30)
        lock.lock()
        let text = String(data: buffer, encoding: .utf8) ?? ""
        lock.unlock()
        guard waited == .success, let line = text.split(separator: "\n").first,
              let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let url = object["url"] as? String else {
            stop(process)
            let err = String(data: stderr.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            XCTFail("isenough ui --json printed no URL. stdout: \(text) stderr: \(err) reason: \(process.terminationReason.rawValue)")
            throw IsenoughError.failure("no UI URL")
        }
        XCTAssertNotNil(object["port"] as? Int)
        XCTAssertFalse((object["token"] as? String ?? "").isEmpty)
        return (url, process)
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        // The server handles SIGTERM, stops listening, and exits 0.
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func fetch(_ url: String) throws -> (status: Int, body: String) {
        guard let target = URL(string: url) else { throw IsenoughError.failure("bad URL \(url)") }
        let done = DispatchSemaphore(value: 0)
        var result: (Int, String) = (0, "")
        let task = URLSession(configuration: .ephemeral).dataTask(with: target) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 15)
        return result
    }

    private func cliBinary() throws -> URL {
        let fm = FileManager.default
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let sibling = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("isenough")
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                for config in ["debug", "release"] {
                    let candidate = url.appendingPathComponent(".build/\(config)/isenough")
                    if fm.isExecutableFile(atPath: candidate.path) { return candidate }
                }
            }
            url.deleteLastPathComponent()
        }
        throw IsenoughError.failure("isenough binary was not built")
    }

    private func run(_ binary: URL, _ arguments: [String]) throws -> (status: Int32, reason: Process.TerminationReason, out: String, err: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, process.terminationReason, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
