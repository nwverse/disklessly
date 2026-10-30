import Foundation
import IsenoughCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct UIRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
    public var token: String? {
        if let value = query["token"], !value.isEmpty { return value }
        if let header = headers["authorization"] ?? headers["Authorization"] {
            let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame { return parts[1] }
        }
        return nil
    }
}

public struct UIResponse {
    public var status: Int
    public var contentType: String
    public var body: Data
    public init(status: Int, contentType: String, body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }
    public static func json(_ object: Any, status: Int = 200) -> UIResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return UIResponse(status: status, contentType: "application/json", body: data)
    }
    public static func text(_ status: Int, _ message: String) -> UIResponse {
        UIResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }
}

/// HTTP server bound only to 127.0.0.1. Callers pass a random token; requests
/// without that token are rejected before the handler runs.
public final class LoopbackUIServer {
    public let token: String
    public private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "io.github.s546126.256isenough.ui")
    private let lock = NSLock()
    private var running = false
    private var storedHandler: (UIRequest) -> UIResponse
    /// Runs on concurrent workers, one per connection; it must be safe to call from several threads.
    public var handler: (UIRequest) -> UIResponse {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }

    public init(token: String = UUID().uuidString, handler: @escaping (UIRequest) -> UIResponse) {
        self.token = token
        self.storedHandler = handler
    }

    /// Port `isenough ui` and the native window ask for first. Taken ports fall back to an ephemeral one.
    public static let defaultPort: UInt16 = 47256

    /// Binds 127.0.0.1 and starts accepting. With `preferredPort`, that port is
    /// tried first; when it is taken the server falls back to an ephemeral port
    /// (read `port` afterwards). Without it the port is ephemeral, as before.
    public func start(preferredPort: UInt16? = nil) throws {
        var fd: Int32 = -1
        if let preferredPort, preferredPort != 0 {
            fd = try bindLoopback(port: preferredPort, required: false)
        }
        if fd < 0 { fd = try bindLoopback(port: 0, required: true) }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let namedRC = withUnsafeMutablePointer(to: &named) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard namedRC == 0 else {
            close(fd)
            throw IsenoughError.failure("could not read the UI port")
        }
        listenFD = fd
        port = UInt16(bigEndian: named.sin_port)
        lock.lock()
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.acceptLoop() }
    }

    /// Returns a listening socket, or -1 when `required` is false and the port is taken.
    private func bindLoopback(port: UInt16, required: Bool) throws -> Int32 {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw IsenoughError.failure("could not open the UI socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            if !required { return -1 }
            throw IsenoughError.failure("could not bind the UI server to 127.0.0.1")
        }
        return fd
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &length) }
            }
            if client < 0 { continue }
            Self.configureClient(client)
            let address = UInt32(bigEndian: peer.sin_addr.s_addr)
            if address != 0x7f000001 {
                let denied = UIResponse.text(403, "loopback only")
                transmit(client, denied)
                close(client)
                continue
            }
            // Each connection runs on its own worker, so a slow action or a
            // slow iCloud listing does not hold up /api/status or /api/icon.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                transmit(client, respond(readRequest(client)))
                close(client)
            }
        }
    }

    /// A stalled client gives up its worker after the timeout; a closed one does not raise SIGPIPE.
    private static func configureClient(_ fd: Int32) {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private func respond(_ request: UIRequest?) -> UIResponse {
        guard let request else { return UIResponse.text(400, "bad request") }
        guard request.token == token else {
            return UIResponse.json(["ok": false, "error": ["code": "unauthorized", "message": "The page token is missing or expired."]], status: 401)
        }
        return handler(request)
    }

    private func readRequest(_ fd: Int32) -> UIRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil && data.count < 1024 * 64 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) else { return nil }
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = data.subdata(in: headerEnd.upperBound..<data.count)
        if let length = headers["content-length"].flatMap(Int.init), length > body.count, length < 1024 * 1024 {
            while body.count < length {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1).map(String.init)
        return UIRequest(method: String(parts[0]), path: split[0], query: queryItems(split.count > 1 ? split[1] : ""), headers: headers, body: body)
    }

    private func queryItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let bits = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = bits.first?.removingPercentEncoding else { continue }
            let value = bits.count > 1 ? (bits[1].removingPercentEncoding ?? bits[1]) : ""
            items[key] = value
        }
        return items
    }

    private func transmit(_ fd: Int32, _ response: UIResponse) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 500: reason = "Internal Server Error"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var bytes = Data(header.utf8)
        bytes.append(response.body)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = write(fd, base.advanced(by: sent), raw.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}
