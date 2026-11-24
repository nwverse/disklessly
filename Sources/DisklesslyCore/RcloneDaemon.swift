import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One `rclone rcd` per rclone config for the life of this process. Each rclone CLI call pays
/// for a process start and, on Google Drive, a lookup of the root folder (about a second);
/// the daemon keeps the remote open, so later calls take a fraction of that.
///
/// rcd listens on 127.0.0.1 with a random user and password passed in its environment (not its
/// arguments, which other users can read with `ps`). It runs under a small `sh` watchdog that
/// holds this process's pipe: when this process exits, even by a crash, the pipe closes and the
/// watchdog stops rcd.
final class RcloneDaemon {
    let port: Int
    private let authorization: String
    private let process: Process
    private let lifeline: Pipe
    private let session: URLSession

    private static let lock = NSLock()
    private static var daemons: [String: RcloneDaemon] = [:]
    private static var broken: Set<String> = []

    /// The daemon for `config`, started on first use. Nil when rcd cannot start (the caller then
    /// runs the rclone CLI) or `DISKLESSLY_RCLONE_DAEMON=0`.
    static func shared(binary: URL, config: String) -> RcloneDaemon? {
        if ProcessInfo.processInfo.environment["DISKLESSLY_RCLONE_DAEMON"] == "0" { return nil }
        let key = binary.path + "\n" + config
        lock.lock(); defer { lock.unlock() }
        if let running = daemons[key] {
            if running.process.isRunning { return running }
            daemons[key] = nil
        }
        if broken.contains(key) { return nil }
        guard let started = try? RcloneDaemon(binary: binary, config: config) else {
            broken.insert(key)
            return nil
        }
        daemons[key] = started
        return started
    }

    private init(binary: URL, config: String) throws {
        port = try Self.freePort()
        let user = UUID().uuidString, pass = UUID().uuidString
        authorization = "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\"$0\" \"$@\" </dev/null & child=$!; read _; kill $child 2>/dev/null; wait $child",
                             binary.path, "--config", config, "rcd", "--rc-serve", "--rc-addr", "127.0.0.1:\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["RCLONE_CONFIG"] = config
        environment["RCLONE_RC_USER"] = user
        environment["RCLONE_RC_PASS"] = pass
        process.environment = environment
        lifeline = Pipe()
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 24 * 3600
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !process.isRunning { break }
            if let (status, _) = try? call("rc/noop", [:]), status == 200 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop()
        throw DisklesslyError.backend("rclone rcd did not start")
    }

    deinit { stop() }

    private func stop() {
        try? lifeline.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private static func freePort() throws -> Int {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw DisklesslyError.backend("socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0 else { throw DisklesslyError.backend("bind() failed") }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func send(_ request: URLRequest, to file: URL? = nil) throws -> (Int, Data) {
        var request = request
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        var failure: Error?
        if let file {
            session.downloadTask(with: request) { location, response, error in
                defer { done.signal() }
                guard let location, let http = response as? HTTPURLResponse else { failure = error; return }
                do {
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: location, to: file)
                    result = (http.statusCode, Data())
                } catch { failure = error }
            }.resume()
        } else {
            session.dataTask(with: request) { data, response, error in
                defer { done.signal() }
                guard let http = response as? HTTPURLResponse else { failure = error; return }
                result = (http.statusCode, data ?? Data())
            }.resume()
        }
        done.wait()
        guard let result else { throw DisklesslyError.backend("rclone rcd: \(failure.map { String(describing: $0) } ?? "no response")") }
        return result
    }

    /// POST `/<method>` with JSON parameters. Returns the HTTP status and the JSON reply.
    func call(_ method: String, _ parameters: [String: Any]) throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        let (status, data) = try send(request)
        return (status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    /// GET a file through `--rc-serve`, optionally from `offset` on or for `range`.
    /// With `file`, the body streams to that file instead of memory.
    func fetch(fs: String, path: String, range: Range<UInt64>? = nil, offset: UInt64? = nil, to file: URL? = nil) throws -> (Int, Data) {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "[]:?#%")
        let encodedFs = fs.addingPercentEncoding(withAllowedCharacters: allowed) ?? fs
        let encodedPath = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/%5B\(encodedFs)%5D/\(encodedPath)")!)
        if let range, !range.isEmpty { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        else if let offset, offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        return try send(request, to: file)
    }

    /// The `error` text of an rc reply.
    static func message(_ reply: [String: Any]) -> String { reply["error"] as? String ?? "unknown error" }
}
