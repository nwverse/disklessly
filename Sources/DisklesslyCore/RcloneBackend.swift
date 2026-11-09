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
    /// `streaming` writes stdin through the handle while rclone runs (for `rcat`); the pipe closes when it returns.
    public static func run(binary: URL, config: String, _ args: [String], input: Data? = nil, stdoutFile: URL? = nil, timeout: TimeInterval? = nil,
                           streaming: ((FileHandle) throws -> Void)? = nil) throws -> Result {
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
        process.standardInput = input == nil && streaming == nil ? FileHandle.nullDevice : inPipe
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
        var feedError: Error?
        if let streaming {
            do { try streaming(inPipe.fileHandleForWriting) } catch {
                feedError = error
                process.terminate()
            }
            try? inPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        group.wait()
        try? outHandle?.close()
        if let feedError { throw feedError }
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

/// A repo on any rclone remote (Google Drive, Dropbox, OneDrive, S3, ...). Calls go to a
/// `rclone rcd` this process keeps running (see `RcloneDaemon`), or to the rclone CLI when the
/// daemon cannot start.
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

    /// `remote:root` and the path inside it, for rc calls.
    func location(_ path: String) throws -> (fs: String, remote: String) {
        let fs = try target("")
        let inside = try target(path).dropFirst(fs.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (fs, inside)
    }

    private var daemon: RcloneDaemon? { RcloneDaemon.shared(binary: binary, config: config) }

    /// Runs an rc method; 404 (not found) comes back as nil.
    private func rc(_ method: String, _ parameters: [String: Any], on daemon: RcloneDaemon) throws -> [String: Any]? {
        let (status, reply) = try daemon.call(method, parameters)
        if status == 404 { return nil }
        guard status == 200 else { throw DisklesslyError.backend("rclone \(method) failed: \(RcloneDaemon.message(reply))") }
        return reply
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
        if let daemon {
            let (fs, inside) = try location(path)
            guard let reply = try rc("operations/list", ["fs": fs, "remote": inside, "opt": ["noModTime": true, "noMimeType": true]], on: daemon) else { return [] }
            return ((reply["list"] as? [[String: Any]]) ?? []).compactMap { $0["Name"] as? String }.sorted()
        }
        let result = try run(["lsjson", "--no-mimetype", "--no-modtime", try target(path)])
        if Self.isMissing(result) { return [] }
        guard result.status == 0 else { throw fail("lsjson", result) }
        let entries = try JSONDecoder().decode([Entry].self, from: result.stdout)
        return entries.map(\.Name).sorted()
    }

    public func entries(_ path: String) throws -> [BackendEntry] {
        if let daemon {
            let (fs, inside) = try location(path)
            guard let reply = try rc("operations/list", ["fs": fs, "remote": inside, "opt": ["noModTime": true, "noMimeType": true]], on: daemon) else { return [] }
            return ((reply["list"] as? [[String: Any]]) ?? []).compactMap { item -> BackendEntry? in
                guard let name = item["Name"] as? String else { return nil }
                let isDir = item["IsDir"] as? Bool ?? false
                let size = (item["Size"] as? NSNumber)?.int64Value ?? -1
                return BackendEntry(name: name, isDirectory: isDir, size: isDir || size < 0 ? nil : UInt64(size))
            }.sorted { $0.name < $1.name }
        }
        let result = try run(["lsjson", "--no-mimetype", "--no-modtime", try target(path)])
        if Self.isMissing(result) { return [] }
        guard result.status == 0 else { throw fail("lsjson", result) }
        let entries = try JSONDecoder().decode([Entry].self, from: result.stdout)
        return entries.map { BackendEntry(name: $0.Name, isDirectory: $0.IsDir, size: $0.IsDir || $0.Size < 0 ? nil : UInt64($0.Size)) }
            .sorted { $0.name < $1.name }
    }

    public func stat(_ path: String) throws -> BackendStat? {
        if let daemon {
            let (fs, inside) = try location(path)
            guard let reply = try rc("operations/stat", ["fs": fs, "remote": inside, "opt": ["noMimeType": true]], on: daemon),
                  let item = reply["item"] as? [String: Any] else { return nil }
            let size = (item["Size"] as? NSNumber)?.int64Value ?? 0
            return BackendStat(size: UInt64(max(0, size)), modified: Self.date(item["ModTime"] as? String ?? ""))
        }
        let result = try run(["lsjson", "--stat", "--no-mimetype", try target(path)])
        if Self.isMissing(result) { return nil }
        guard result.status == 0 else { throw fail("lsjson --stat", result) }
        let entry = try JSONDecoder().decode(Entry.self, from: result.stdout)
        return BackendStat(size: UInt64(max(0, entry.Size)), modified: Self.date(entry.ModTime))
    }

    static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    public func get(_ path: String, range: Range<UInt64>?) throws -> Data {
        if let daemon {
            if let range, range.isEmpty { return Data() }
            let (fs, inside) = try location(path)
            let (status, body) = try daemon.fetch(fs: fs, path: inside, range: range)
            if status == 404 { throw DisklesslyError.backend("remote object is missing: \(path)") }
            guard status == 200 || status == 206 else { throw DisklesslyError.backend("rclone serve returned HTTP \(status) for \(path)") }
            if let range, status == 200 {
                // The server ignored Range; cut the slice out.
                let upper = min(Int(range.upperBound), body.count)
                return Int(range.lowerBound) < upper ? body.subdata(in: Int(range.lowerBound)..<upper) : Data()
            }
            return body
        }
        var args = ["cat"]
        if let range { args += ["--offset", String(range.lowerBound), "--count", String(range.count)] }
        let result = try run(args + [try target(path)])
        if Self.isMissing(result) { throw DisklesslyError.backend("remote object is missing: \(path)") }
        guard result.status == 0 else { throw fail("cat", result) }
        return result.stdout
    }

    public func put(_ path: String, data: Data) throws {
        if daemon != nil {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-rclone-\(UUID().uuidString)")
            try data.write(to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            return try put(path, file: staging)
        }
        let result = try run(["rcat", try target(path)], input: data)
        guard result.status == 0 else { throw fail("rcat", result) }
    }

    /// Streams stdin into `rcat` (the CLI, not the rc daemon, which has no stdin upload).
    public func putStream(_ path: String, from producer: (FileHandle) throws -> Void) throws {
        let overrides = Self.uploadOverrides(type: Self.remoteType(remote, config: config))
        let args = ["rcat", Self.withOverrides(try target(path), overrides)]
        let result = try withoutActuallyEscaping(producer) { feed in
            try RcloneTool.run(binary: binary, config: config, args, streaming: feed)
        }
        guard result.status == 0 else { throw fail("rcat", result) }
    }

    /// Server-side `moveto` inside the remote. `moveto` would overwrite, so an existing
    /// destination is checked first (not atomic; the engine's content addressing covers races).
    public func move(_ from: String, to: String) throws {
        if try stat(to) != nil { throw DisklesslyError.backend("move destination already exists: \(to)") }
        let result = try run(["moveto", try target(from), try target(to)])
        if Self.isMissing(result) { throw DisklesslyError.backend("remote object is missing: \(from)") }
        guard result.status == 0 else { throw fail("moveto", result) }
    }

    public func put(_ path: String, file: URL) throws {
        let overrides = Self.uploadOverrides(type: Self.remoteType(remote, config: config))
        if let daemon {
            let (fs, inside) = try location(path)
            _ = try rc("operations/copyfile", ["srcFs": file.deletingLastPathComponent().path, "srcRemote": file.lastPathComponent,
                                                "dstFs": Self.withOverrides(fs, overrides), "dstRemote": inside, "_config": ["IgnoreTimes": true]], on: daemon)
                ?? { throw DisklesslyError.backend("upload source is missing: \(file.path)") }()
            return
        }
        let result = try run(["copyto", "--ignore-times", file.path, Self.withOverrides(try target(path), overrides)])
        guard result.status == 0 else { throw fail("copyto", result) }
    }

    /// Backend options for uploads. Google Drive uploads one file as a single stream of chunks,
    /// waiting for each chunk before sending the next, so rclone's 8 MiB default leaves most of the
    /// link idle; 64 MiB measured ~60% faster. rclone holds one chunk in memory per transfer.
    static func uploadOverrides(type: String?) -> [String: String] {
        type == "drive" ? ["chunk_size": "64M"] : [:]
    }

    /// `remote:path` with rclone connection-string options: `remote,key=value:path`.
    static func withOverrides(_ fs: String, _ overrides: [String: String]) -> String {
        guard !overrides.isEmpty, let colon = fs.firstIndex(of: ":") else { return fs }
        let options = overrides.keys.sorted().map { ",\($0)=\(overrides[$0]!)" }.joined()
        return String(fs[..<colon]) + options + String(fs[colon...])
    }

    /// The `type =` of `[remote]` in an rclone config file.
    static func remoteType(_ remote: String, config: String) -> String? {
        guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { return nil }
        var inSection = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[\(remote)]"; continue }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == "type" {
                return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    public func delete(_ path: String) throws {
        if let daemon {
            let (fs, inside) = try location(path)
            _ = try rc("operations/deletefile", ["fs": fs, "remote": inside], on: daemon)
            return
        }
        let result = try run(["deletefile", "--retries", "1", try target(path)])
        if Self.isMissing(result) { return }
        guard result.status == 0 else { throw fail("deletefile", result) }
    }

    /// A fresh download uses rclone's multi-thread download (several ranged streams at once).
    /// A resume appends the rest with `cat --offset`.
    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        if let daemon {
            let (fs, inside) = try location(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if offset == 0 {
                let copied = try rc("operations/copyfile", ["srcFs": fs, "srcRemote": inside,
                                                            "dstFs": destination.deletingLastPathComponent().path, "dstRemote": destination.lastPathComponent,
                                                            "_config": ["IgnoreTimes": true, "MultiThreadStreams": max(1, streams), "MultiThreadCutoff": 16 * 1024 * 1024]], on: daemon)
                if copied == nil { throw DisklesslyError.backend("remote object is missing: \(path)") }
                return ResumableFile(restart: false, bytesWritten: (try? ChunkedIO.byteCount(destination)) ?? 0)
            }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).rest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            let (status, _) = try daemon.fetch(fs: fs, path: inside, offset: offset, to: staging)
            if status == 404 { throw DisklesslyError.backend("remote object is missing: \(path)") }
            if status == 416 { return ResumableFile(restart: false, bytesWritten: 0) }
            if status == 200 {
                // Range ignored: the whole object came back, so it replaces the partial.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staging, to: destination)
                return ResumableFile(restart: true, bytesWritten: (try? ChunkedIO.byteCount(destination)) ?? 0)
            }
            guard status == 206 else { throw DisklesslyError.backend("rclone serve returned HTTP \(status) for \(path)") }
            let added = (try? ChunkedIO.byteCount(staging)) ?? 0
            try ChunkedIO.appendFile(staging, to: destination)
            return ResumableFile(restart: false, bytesWritten: added)
        }
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
        if let daemon {
            let (fs, inside) = try location(path)
            _ = try rc("operations/mkdir", ["fs": fs, "remote": inside], on: daemon)
            return
        }
        let result = try run(["mkdir", try target(path)])
        guard result.status == 0 else { throw fail("mkdir", result) }
    }
}
