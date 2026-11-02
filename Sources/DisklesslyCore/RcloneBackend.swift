import Foundation

/// Finds the rclone binary. The Mac app ships one next to the `disklessly` executable.
public enum RcloneTool {
    /// Pinned in `scripts/fetch-rclone.sh`; shown in `disklessly cloud status`.
    public static let bundledVersion = "v1.75.2"

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath(),
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        if let override = environment["DISKLESSLY_RCLONE"], !override.isEmpty {
            return isExecutable(override) ? URL(fileURLWithPath: override) : nil
        }
        let dir = executable.deletingLastPathComponent()
        var candidates = [dir.appendingPathComponent("rclone").path, dir.deletingLastPathComponent().appendingPathComponent("Helpers/rclone").path]
        let path = environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/rclone" }
        // The app bundle, for an engine copy that has no rclone beside it.
        let home = environment["HOME"] ?? NSHomeDirectory()
        candidates += ["/Applications/Disklessly.app/Contents/MacOS/rclone", "\(home)/Applications/Disklessly.app/Contents/MacOS/rclone"]
        candidates += ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    public static func require() throws -> URL {
        guard let found = locate() else {
            throw DisklesslyError.unsupported("rclone is not available; reinstall Disklessly or set DISKLESSLY_RCLONE")
        }
        return found
    }

    /// `<stateDir>/rclone/rclone.conf`. Disklessly keeps its own config so it never touches
    /// the user's `~/.config/rclone`.
    public static func configPath(stateDir: String) -> String {
        (stateDir as NSString).appendingPathComponent("rclone/rclone.conf")
    }

    /// Cloud drives the dashboard can connect in one click. `extra` is passed to
    /// `rclone config create`. Google Drive asks only for files rclone itself creates.
    public static let providers: [(id: String, type: String, name: String, extra: [String])] = [
        ("gdrive", "drive", "Google Drive", ["scope", "drive.file"]),
        ("dropbox", "dropbox", "Dropbox", []),
        ("onedrive", "onedrive", "OneDrive", []),
        ("box", "box", "Box", []),
        ("pcloud", "pcloud", "pCloud", []),
    ]

    /// Disklessly's own Google OAuth client, so Google Drive does not share rclone's rate-limited
    /// one. `DISKLESSLY_GDRIVE_CLIENT_ID` and `_SECRET` win; otherwise the app bundle's
    /// `Contents/Resources/google-oauth.json` (`{"client_id", "client_secret"}`, added by
    /// scripts/build-app.sh). A desktop client's secret is not confidential, but it stays out of git.
    public static func googleClient(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()) -> (id: String, secret: String)? {
        if let id = environment["DISKLESSLY_GDRIVE_CLIENT_ID"], let secret = environment["DISKLESSLY_GDRIVE_CLIENT_SECRET"], !id.isEmpty, !secret.isEmpty {
            return (id, secret)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let files = [contents.appendingPathComponent("Resources/google-oauth.json").path,
                     "/Applications/Disklessly.app/Contents/Resources/google-oauth.json",
                     "\(home)/Applications/Disklessly.app/Contents/Resources/google-oauth.json"]
        for file in files {
            guard let data = FileManager.default.contents(atPath: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = object["client_id"] as? String, let secret = object["client_secret"] as? String,
                  !id.isEmpty, !secret.isEmpty else { continue }
            return (id, secret)
        }
        return nil
    }

    /// `rclone config create` arguments for `provider` beyond its type.
    public static func createArguments(provider id: String, googleClient: (id: String, secret: String)? = googleClient()) -> [String] {
        guard let provider = providers.first(where: { $0.id == id }) else { return [] }
        var extra = provider.extra
        if provider.type == "drive", let googleClient {
            extra += ["client_id", googleClient.id, "client_secret", googleClient.secret]
        }
        return extra
    }

    public struct Result {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
    }

    /// Runs rclone with Disklessly's config. `stdoutFile` receives stdout (appended) instead of memory.
    /// `timeout` terminates rclone when it is still running after that many seconds.
    @discardableResult
    public static func run(binary: URL, config: String, _ args: [String], input: Data? = nil, stdoutFile: URL? = nil, timeout: TimeInterval? = nil) throws -> Result {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--config", config] + args
        var environment = ProcessInfo.processInfo.environment
        environment["RCLONE_CONFIG"] = config
        process.environment = environment
        let errPipe = Pipe()
        process.standardError = errPipe
        let outPipe = Pipe()
        var outHandle: FileHandle?
        if let stdoutFile {
            if !FileManager.default.fileExists(atPath: stdoutFile.path) {
                FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: stdoutFile)
            try handle.seekToEnd()
            process.standardOutput = handle
            outHandle = handle
        } else {
            process.standardOutput = outPipe
        }
        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        try process.run()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
        }
        // Drain both pipes on their own threads so a full pipe never blocks rclone.
        var out = Data(), err = Data()
        let group = DispatchGroup()
        if stdoutFile == nil {
            group.enter()
            DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        }
        group.enter()
        DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        group.wait()
        try? outHandle?.close()
        return Result(status: process.terminationStatus, stdout: out, stderr: String(decoding: err, as: UTF8.self))
    }

    /// Remote names in Disklessly's rclone config, without the trailing colon.
    public static func remotes(binary: URL, config: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: config) else { return [] }
        let result = try run(binary: binary, config: config, ["listremotes"])
        guard result.status == 0 else { throw DisklesslyError.backend("rclone listremotes failed: \(lastLine(result.stderr))") }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 }
    }

    /// `rclone version`'s first line, e.g. "rclone v1.75.2".
    public static func version(binary: URL) -> String? {
        guard let result = try? run(binary: binary, config: "/dev/null", ["version"], timeout: 10), result.status == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }

    /// Remote names Disklessly accepts: letters, digits, `-` and `_`.
    public static func validRemoteName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    public static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// A repo on any rclone remote (Google Drive, Dropbox, OneDrive, S3, ...), driven through the
/// rclone CLI. Nothing runs in the background between calls.
public struct RcloneBackend: StorageBackend {
    public let binary: URL
    public let config: String
    public let remote: String
    public let root: String
    /// Parallel streams for whole-file downloads (`--multi-thread-streams`).
    public var streams: Int

    public init(binary: URL, config: String, remote: String, root: String, streams: Int = 8) {
        self.binary = binary
        self.config = config
        self.remote = remote
        self.root = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.streams = streams
    }

    /// `remote:root/path`. Refuses `..` so a manifest cannot point outside the repo.
    func target(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.split(separator: "/").contains("..") { throw DisklesslyError.integrity("path escapes the repo: \(path)") }
        let joined = [root, trimmed].filter { !$0.isEmpty }.joined(separator: "/")
        return "\(remote):\(joined)"
    }

    private func run(_ args: [String], input: Data? = nil, stdoutFile: URL? = nil) throws -> RcloneTool.Result {
        try RcloneTool.run(binary: binary, config: config, args, input: input, stdoutFile: stdoutFile)
    }

    private func fail(_ what: String, _ result: RcloneTool.Result) -> DisklesslyError {
        .backend("rclone \(what) failed (exit \(result.status)): \(RcloneTool.lastLine(result.stderr))")
    }

    /// rclone exits 3 for a missing directory and 4 for a missing file.
    private static func isMissing(_ result: RcloneTool.Result) -> Bool { result.status == 3 || result.status == 4 }

    private struct Entry: Decodable {
        var Name: String
        var Size: Int64
        var ModTime: String
        var IsDir: Bool
    }

    public func list(_ path: String) throws -> [String] {
        let result = try run(["lsjson", "--no-mimetype", "--no-modtime", try target(path)])
        if Self.isMissing(result) { return [] }
        guard result.status == 0 else { throw fail("lsjson", result) }
        let entries = try JSONDecoder().decode([Entry].self, from: result.stdout)
        return entries.map(\.Name).sorted()
    }

    public func stat(_ path: String) throws -> BackendStat? {
        let result = try run(["lsjson", "--stat", "--no-mimetype", try target(path)])
        if Self.isMissing(result) { return nil }
        guard result.status == 0 else { throw fail("lsjson --stat", result) }
        let entry = try JSONDecoder().decode(Entry.self, from: result.stdout)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let modified = formatter.date(from: entry.ModTime) ?? ISO8601DateFormatter().date(from: entry.ModTime) ?? Date(timeIntervalSince1970: 0)
        return BackendStat(size: UInt64(max(0, entry.Size)), modified: modified)
    }

    public func get(_ path: String, range: Range<UInt64>?) throws -> Data {
        var args = ["cat"]
        if let range { args += ["--offset", String(range.lowerBound), "--count", String(range.count)] }
        let result = try run(args + [try target(path)])
        if Self.isMissing(result) { throw DisklesslyError.backend("remote object is missing: \(path)") }
        guard result.status == 0 else { throw fail("cat", result) }
        return result.stdout
    }

    public func put(_ path: String, data: Data) throws {
        let result = try run(["rcat", try target(path)], input: data)
        guard result.status == 0 else { throw fail("rcat", result) }
    }

    public func put(_ path: String, file: URL) throws {
        let result = try run(["copyto", "--ignore-times", file.path, try target(path)])
        guard result.status == 0 else { throw fail("copyto", result) }
    }

    public func delete(_ path: String) throws {
        let result = try run(["deletefile", "--retries", "1", try target(path)])
        if Self.isMissing(result) { return }
        guard result.status == 0 else { throw fail("deletefile", result) }
    }

    /// A fresh download uses rclone's multi-thread download (several ranged streams at once).
    /// A resume appends the rest with `cat --offset`.
    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        let source = try target(path)
        if offset == 0 {
            let result = try run(["copyto", "--ignore-times", "--multi-thread-streams", String(max(1, streams)), "--multi-thread-cutoff", "16M", source, destination.path])
            if Self.isMissing(result) { throw DisklesslyError.backend("remote object is missing: \(path)") }
            guard result.status == 0 else { throw fail("copyto", result) }
            return ResumableFile(restart: false, bytesWritten: (try? ChunkedIO.byteCount(destination)) ?? 0)
        }
        let before = (try? ChunkedIO.byteCount(destination)) ?? 0
        let result = try run(["cat", "--offset", String(offset), source], stdoutFile: destination)
        if Self.isMissing(result) { throw DisklesslyError.backend("remote object is missing: \(path)") }
        guard result.status == 0 else { throw fail("cat", result) }
        let after = (try? ChunkedIO.byteCount(destination)) ?? before
        return ResumableFile(restart: false, bytesWritten: after >= before ? after - before : 0)
    }

    public func localRoot() -> URL? { nil }

    public func ensureCollection(_ path: String) throws {
        let result = try run(["mkdir", try target(path)])
        guard result.status == 0 else { throw fail("mkdir", result) }
    }
}
