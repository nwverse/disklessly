import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DisklesslyCore

/// One-click OpenList for drives rclone does not cover (阿里云盘, 百度网盘, 夸克, 115, ...).
/// Disklessly downloads a pinned release, checks its SHA-256, runs it on 127.0.0.1 under a
/// LaunchAgent, and keeps the admin password in the Keychain. OpenList is AGPL-3.0 and is
/// downloaded from its own release page, unmodified; it is not part of the Disklessly app.
public struct OpenListService {
    public static let version = "v4.2.9"
    /// SHA-256 of the release archives (the project publishes only MD5; these were checked against it).
    static let assets: [String: (url: String, sha256: String)] = [
        "arm64": ("https://github.com/OpenListTeam/OpenList/releases/download/v4.2.9/openlist-darwin-arm64.tar.gz",
                  "dac3b46e96f18ec3a06824fbac660d3e23c8a96f0aa40bc2bf2c5fde5b1eaecf"),
        "amd64": ("https://github.com/OpenListTeam/OpenList/releases/download/v4.2.9/openlist-darwin-amd64.tar.gz",
                  "2822e7d63855deacc7b816171ca14aaaeae59fec97c955d7d4258eedbfe4b881"),
    ]
    public static let label = "io.github.s546126.disklessly.openlist"
    public static let backendId = "openlist-local"
    public static let defaultPort = 5244

    public let stateDir: String
    public let secrets: any SecretStore
    var launchAgents: URL

    public init(stateDir: String, secrets: any SecretStore, launchAgents: URL? = nil) {
        self.stateDir = stateDir
        self.secrets = secrets
        self.launchAgents = launchAgents ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    var home: URL { URL(fileURLWithPath: stateDir).appendingPathComponent("openlist") }
    var binary: URL { home.appendingPathComponent("bin/openlist") }
    var dataDir: URL { home.appendingPathComponent("data") }
    var configFile: URL { dataDir.appendingPathComponent("config.json") }
    var plist: URL { launchAgents.appendingPathComponent("\(Self.label).plist") }
    static var secretAccount: String { BackendCommands.secretAccount(type: "openlist", id: backendId) }

    public var installed: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    public var port: Int {
        guard let data = try? Data(contentsOf: configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scheme = object["scheme"] as? [String: Any],
              let port = scheme["http_port"] as? Int, port > 0 else { return Self.defaultPort }
        return port
    }

    public var url: String { "http://127.0.0.1:\(port)" }

    public func password() -> String? { try? secrets.load(service: BackendCatalog.keychainService, account: Self.secretAccount) }

    public func running(timeout: TimeInterval = 1.5) -> Bool {
        guard let ping = URL(string: url + "/ping") else { return false }
        var request = URLRequest(url: ping)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data ?? Data(), as: UTF8.self).contains("pong")
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 0.5)
        return ok
    }

    public func status() -> [String: Any] {
        ["installed": installed, "running": installed && running(), "version": Self.version, "url": url, "port": port, "backendId": Self.backendId, "hasPassword": password() != nil]
    }

    // MARK: install

    static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    /// Downloads and verifies the release, sets up a localhost-only config and admin password,
    /// and starts it. Returns the endpoint to store (not activated).
    @discardableResult
    public func install(progress: (String) -> Void = { _ in }) throws -> BackendEndpoint {
        #if os(macOS)
        let fm = FileManager.default
        guard let asset = Self.assets[Self.hostArch] else { throw DisklesslyError.unsupported("no OpenList build for this Mac") }
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if !installed || installedVersion() != Self.version {
            progress("download")
            let staging = home.appendingPathComponent("staging-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let archive = staging.appendingPathComponent("openlist.tar.gz")
            try Self.download(asset.url, to: archive)
            progress("verify")
            let digest = try SHA256Digest.hexFile(archive)
            guard digest == asset.sha256 else {
                throw DisklesslyError.integrity("OpenList download does not match the pinned SHA-256 (got \(digest))")
            }
            try Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
            let extracted = staging.appendingPathComponent("openlist")
            guard fm.isExecutableFile(atPath: extracted.path) else { throw DisklesslyError.failure("the OpenList archive has no openlist binary") }
            if running() { try? stop() }
            try? fm.removeItem(at: binary)
            try fm.moveItem(at: extracted, to: binary)
            try (Data(Self.version.utf8)).write(to: home.appendingPathComponent("bin/VERSION"))
        }
        progress("configure")
        try writeConfig(port: try choosePort())
        if password() == nil || !fm.fileExists(atPath: dataDir.appendingPathComponent("data.db").path) {
            try firstBoot()
        }
        progress("start")
        try start()
        return BackendEndpoint(id: Self.backendId, type: "openlist", user: "admin", url: url, root: "/")
        #else
        throw DisklesslyError.unsupported("one-click OpenList is macOS only; run OpenList yourself and use disklessly backend add openlist")
        #endif
    }

    func installedVersion() -> String? {
        (try? String(contentsOf: home.appendingPathComponent("bin/VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps the current port when this install already has one; otherwise 5244, or the next free one.
    func choosePort() throws -> Int {
        if FileManager.default.fileExists(atPath: configFile.path) { return port }
        for candidate in Self.defaultPort..<(Self.defaultPort + 50) where Self.portIsFree(candidate) { return candidate }
        throw DisklesslyError.failure("no free port for OpenList near \(Self.defaultPort)")
    }

    static func portIsFree(_ port: Int) -> Bool {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Merges into an existing config so OpenList's own settings survive; always binds 127.0.0.1
    /// and leaves its S3, FTP and SFTP servers off.
    func writeConfig(port: Int) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { object = saved }
        var scheme = object["scheme"] as? [String: Any] ?? [:]
        scheme["address"] = "127.0.0.1"
        scheme["http_port"] = port
        scheme["https_port"] = -1
        object["scheme"] = scheme
        for service in ["s3", "ftp", "sftp"] {
            var section = object[service] as? [String: Any] ?? [:]
            section["enable"] = false
            object[service] = section
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configFile, options: .atomic)
    }

    /// OpenList creates the admin user on first start only when `OPENLIST_ADMIN_PASSWORD` is set,
    /// so the password never appears on a command line or in a file.
    func firstBoot() throws {
        let secret = Self.randomPassword()
        if password() == nil || !FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("data.db").path) {
            try secrets.save(service: BackendCatalog.keychainService, account: Self.secretAccount, secret: secret)
        }
        guard let stored = password() else { throw DisklesslyError.failure("could not keep the OpenList password in the Keychain") }
        if running() { try? stop() }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["server", "--data", dataDir.path]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENLIST_ADMIN_PASSWORD"] = stored
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        guard waitUntilRunning(seconds: 40) else { throw DisklesslyError.failure("OpenList did not start on \(url)") }
    }

    static func randomPassword() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    func waitUntilRunning(seconds: Int) -> Bool {
        for _ in 0..<(seconds * 2) {
            if running(timeout: 0.5) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: launchd

    func plistObject() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [binary.path, "server", "--data", dataDir.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "StandardOutPath": home.appendingPathComponent("openlist.log").path,
            "StandardErrorPath": home.appendingPathComponent("openlist.log").path,
        ]
    }

    public func start() throws {
        #if os(macOS)
        guard installed else { throw DisklesslyError.usage("OpenList is not installed; run disklessly openlist install") }
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plistObject(), format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = try? Self.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.label)"])
        try Self.run("/bin/launchctl", ["bootstrap", domain, plist.path])
        guard waitUntilRunning(seconds: 40) else { throw DisklesslyError.failure("OpenList did not start on \(url); see \(home.appendingPathComponent("openlist.log").path)") }
        #endif
    }

    public func stop() throws {
        #if os(macOS)
        _ = try? Self.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.label)"])
        #endif
    }

    /// Stops it and removes the program and the LaunchAgent. Its data (drives you added) stays
    /// unless `purge`.
    public func uninstall(purge: Bool) throws {
        try stop()
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        if purge {
            // The Keychain item stays; the next install finds no data.db and replaces it.
            try? FileManager.default.removeItem(at: home)
        }
    }

    // MARK: helpers

    static func download(_ address: String, to destination: URL) throws {
        guard let url = URL(string: address) else { throw DisklesslyError.usage("bad URL \(address)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200, let location else {
                failure = DisklesslyError.backend("download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(address)")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch { failure = error }
        }.resume()
        done.wait()
        if let failure { throw failure }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DisklesslyError.failure("\(tool) \(args.first ?? "") failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
