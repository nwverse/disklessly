import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct HTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: AnyObject {
    func send(method: String, url: URL, headers: [String: String], body: Data?) throws -> HTTPResponse
    /// Stream a file as the request body. `URLSessionTransport` uses `uploadTask(with:fromFile:)`.
    func upload(method: String, url: URL, headers: [String: String], file: URL) throws -> HTTPResponse
    /// Stream the response body onto `destination`. `URLSessionTransport` uses `downloadTask`.
    func download(method: String, url: URL, headers: [String: String], to destination: URL) throws -> HTTPResponse
}

extension HTTPTransport {
    public func upload(method: String, url: URL, headers: [String: String], file: URL) throws -> HTTPResponse {
        try send(method: method, url: url, headers: headers, body: ChunkedIO.readAll(file))
    }

    public func download(method: String, url: URL, headers: [String: String], to destination: URL) throws -> HTTPResponse {
        let response = try send(method: method, url: url, headers: headers, body: nil)
        try ChunkedIO.writeAtomically(response.body, to: destination)
        return HTTPResponse(status: response.status, headers: response.headers, body: Data())
    }
}

public enum BasicAuth {
    public static func header(user: String, password: String) -> String {
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

private final class ResponseBox: @unchecked Sendable {
    var result: Result<HTTPResponse, Error> = .failure(URLError(.unknown))
}

private final class RedirectStripper: NSObject, URLSessionTaskDelegate {
    let origin: String?
    init(origin: String?) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let origin, let host = request.url?.host, host != origin {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let stripper: RedirectStripper
    public init(origin: String? = nil) {
        stripper = RedirectStripper(origin: origin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: configuration, delegate: stripper, delegateQueue: nil)
    }

    public func send(method: String, url: URL, headers: [String: String], body: Data?) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            http?.allHeaderFields.forEach { key, value in
                headers["\(key)"] = "\(value)"
            }
            box.result = .success(HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data ?? Data()))
        }
        task.resume()
        semaphore.wait()
        return try box.result.get()
    }

    public func upload(method: String, url: URL, headers: [String: String], file: URL) throws -> HTTPResponse {
        let request = Self.request(method: method, url: url, headers: headers)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let task = session.uploadTask(with: request, fromFile: file) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            box.result = .success(Self.received(response, body: data ?? Data()))
        }
        task.resume()
        semaphore.wait()
        return try box.result.get()
    }

    public func download(method: String, url: URL, headers: [String: String], to destination: URL) throws -> HTTPResponse {
        let request = Self.request(method: method, url: url, headers: headers)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let task = session.downloadTask(with: request) { location, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            let received = Self.received(response, body: Data())
            if let location {
                do {
                    try ChunkedIO.replaceFile(destination, with: location)
                } catch {
                    box.result = .failure(error)
                    return
                }
            } else if (200..<300).contains(received.status) {
                box.result = .failure(DisklesslyError.backend("download produced no file (HTTP \(received.status))"))
                return
            }
            box.result = .success(received)
        }
        task.resume()
        semaphore.wait()
        return try box.result.get()
    }

    private static func request(method: String, url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private static func received(_ response: URLResponse?, body: Data) -> HTTPResponse {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        http?.allHeaderFields.forEach { key, value in
            headers["\(key)"] = "\(value)"
        }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: body)
    }
}

enum WebDAVXML {
    struct Item: Equatable {
        var href: String
        var size: UInt64?
        var isCollection: Bool
    }

    static func responses(_ xml: Data) -> [Item] {
        let parser = XMLParser(data: xml)
        let delegate = Parser()
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            if elementName == "response" { current = Item(href: "", size: nil, isCollection: false) }
            if elementName == "collection" { current?.isCollection = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "href": current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "getcontentlength": current?.size = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "response":
                if let current { items.append(current) }
                current = nil
            default: break
            }
        }
    }
}

public struct WebDAVBackend: StorageBackend {
    public let baseURL: URL
    public let user: String?
    public let password: String?
    public let transport: any HTTPTransport

    public init(baseURL: URL, user: String?, password: String?, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.user = user
        self.password = password
        self.transport = transport
    }

    public func localRoot() -> URL? { nil }

    public func list(_ path: String) throws -> [String] {
        let url = try itemURL(path)
        let response = try call(method: "PROPFIND", url: url, headers: ["Depth": "1", "Content-Type": "application/xml"], body: propfindBody)
        if response.status == 404 { return [] }
        try expect(response, ok: [207, 200])
        return names(in: response.body, requested: url)
    }

    public func entries(_ path: String) throws -> [BackendEntry] {
        let url = try itemURL(path)
        let response = try call(method: "PROPFIND", url: url, headers: ["Depth": "1", "Content-Type": "application/xml"], body: propfindBody)
        if response.status == 404 { return [] }
        try expect(response, ok: [207, 200])
        return WebDAVXML.responses(response.body).compactMap { item -> BackendEntry? in
            if isSelf(item.href, requested: url) { return nil }
            let href = item.href.removingPercentEncoding ?? item.href
            let name = (href as NSString).lastPathComponent
            if name.isEmpty || name == "/" { return nil }
            return BackendEntry(name: name, isDirectory: item.isCollection, size: item.isCollection ? nil : item.size)
        }.sorted { $0.name < $1.name }
    }

    public func stat(_ path: String) throws -> BackendStat? {
        let url = try itemURL(path)
        let response = try call(method: "PROPFIND", url: url, headers: ["Depth": "0", "Content-Type": "application/xml"], body: propfindBody)
        if response.status == 404 { return nil }
        try expect(response, ok: [207, 200])
        let items = WebDAVXML.responses(response.body)
        let match = items.first { self.isSelf($0.href, requested: url) } ?? items.first
        guard let match else { return nil }
        return BackendStat(size: match.size ?? 0, modified: .distantPast)
    }

    public func get(_ path: String, range: Range<UInt64>?) throws -> Data {
        if let range {
            let body = try getResumable(path, offset: range.lowerBound)
            let data = body.data
            let upper = range.upperBound > range.lowerBound ? range.upperBound - range.lowerBound : 0
            if body.restart {
                let count = UInt64(data.count)
                let lo = Int(min(range.lowerBound, count))
                let hi = Int(min(range.upperBound, count))
                guard lo <= hi, hi <= data.count else { return Data() }
                return data.subdata(in: lo..<hi)
            }
            if upper < UInt64(data.count), upper <= UInt64(Int.max) {
                return Data(data.prefix(Int(upper)))
            }
            return data
        }
        return try getResumable(path, offset: 0).data
    }

    public func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody {
        let url = try itemURL(path)
        var headers: [String: String] = [:]
        if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
        let response = try call(method: "GET", url: url, headers: headers, body: nil)
        if response.status == 404 { throw DisklesslyError.backend("remote object is missing: \(path)") }
        if offset > 0 && response.status == 200 {
            return ResumableBody(data: response.body, restart: true)
        }
        try expect(response, ok: offset > 0 ? [206, 200] : [200])
        return ResumableBody(data: response.body, restart: false)
    }

    public func put(_ path: String, data: Data) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-webdav-\(UUID().uuidString)")
        try ChunkedIO.writeAtomically(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try put(path, file: temporary)
    }

    public func put(_ path: String, file: URL) throws {
        let finalURL = try itemURL(path)
        let fileName = finalURL.lastPathComponent
        let tempURL = finalURL.deletingLastPathComponent().appendingPathComponent(".\(fileName).tmp-\(UUID().uuidString)")
        var headers = ["Content-Type": "application/octet-stream"]
        headers["Content-Length"] = String(try ChunkedIO.byteCount(file))
        let created = try callUpload(method: "PUT", url: tempURL, headers: headers, file: file)
        try expect(created, ok: [200, 201, 204])
        let exclusive = WriteOnceScope.exclusive
        let moved = try call(method: "MOVE", url: tempURL, headers: ["Destination": finalURL.absoluteString, "Overwrite": exclusive ? "F" : "T"], body: nil)
        if ![201, 204, 200].contains(moved.status) {
            _ = try? call(method: "DELETE", url: tempURL, headers: [:], body: nil)
            if exclusive && moved.status == 412 {
                throw WriteOnceConflict(path: path)
            }
            throw DisklesslyError.backend("webdav MOVE failed (HTTP \(moved.status))")
        }
        try verify(path, expected: SHA256Digest.hexFile(file))
    }

    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        let url = try itemURL(path)
        var headers: [String: String] = [:]
        if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-webdav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let response = try callDownload(method: "GET", url: url, headers: headers, to: staging)
        if response.status == 404 { throw DisklesslyError.backend("remote object is missing: \(path)") }
        let received = (try? ChunkedIO.byteCount(staging)) ?? 0
        if offset > 0 && response.status == 200 {
            try ChunkedIO.replaceFile(destination, with: staging)
            return ResumableFile(restart: true, bytesWritten: received)
        }
        try expect(response, ok: offset > 0 ? [206, 200] : [200])
        if offset == 0 {
            try ChunkedIO.replaceFile(destination, with: staging)
        } else {
            try ChunkedIO.appendFile(staging, to: destination)
        }
        return ResumableFile(restart: false, bytesWritten: received)
    }

    public func delete(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "." { throw DisklesslyError.usage("refusing to delete the WebDAV root") }
        let response = try call(method: "DELETE", url: try itemURL(path), headers: [:], body: nil)
        if response.status == 404 { return }
        try expect(response, ok: [200, 204])
    }

    public func ensureCollection(_ path: String) throws {
        let url = try itemURL(path.isEmpty ? "" : path)
        let response = try call(method: "MKCOL", url: url, headers: [:], body: nil)
        if [200, 201, 204, 301, 405].contains(response.status) { return }
        try expect(response, ok: [200, 201])
    }

    private var propfindBody: Data {
        Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><propfind xmlns=\"DAV:\"><prop><getcontentlength/><resourcetype/></prop></propfind>".utf8)
    }

    private func itemURL(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw DisklesslyError.usage("Invalid backend path")
        }
        var url = baseURL
        if url.pathExtension.isEmpty == false && !baseURL.absoluteString.hasSuffix("/") {
            // base is a collection; append below
        }
        if !url.absoluteString.hasSuffix("/") {
            url = URL(string: url.absoluteString + "/") ?? url
        }
        if path.isEmpty { return url }
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        return url
    }

    private func call(method: String, url: URL, headers: [String: String], body: Data?) throws -> HTTPResponse {
        let headers = try authorized(headers)
        return try perform {
            try transport.send(method: method, url: url, headers: headers, body: body)
        }
    }

    private func callUpload(method: String, url: URL, headers: [String: String], file: URL) throws -> HTTPResponse {
        let headers = try authorized(headers)
        return try perform {
            try transport.upload(method: method, url: url, headers: headers, file: file)
        }
    }

    private func callDownload(method: String, url: URL, headers: [String: String], to destination: URL) throws -> HTTPResponse {
        let headers = try authorized(headers)
        return try perform {
            try transport.download(method: method, url: url, headers: headers, to: destination)
        }
    }

    private func authorized(_ headers: [String: String]) throws -> [String: String] {
        var headers = headers
        if let user {
            guard let password else { throw DisklesslyError.backend("webdav credential is not in the Keychain") }
            headers["Authorization"] = BasicAuth.header(user: user, password: password)
        }
        return headers
    }

    private func perform(_ work: () throws -> HTTPResponse) throws -> HTTPResponse {
        do {
            let response = try work()
            if response.status == 0 || response.status == 503 {
                throw DisklesslyError.backend("webdav unavailable (HTTP \(response.status))")
            }
            return response
        } catch let error as DisklesslyError {
            throw error
        } catch {
            throw DisklesslyError.backend("webdav offline: \(error.localizedDescription)")
        }
    }

    private func verify(_ path: String, expected: String) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try download(path, to: staging, offset: 0)
        guard try SHA256Digest.hexFile(staging) == expected else {
            try? delete(path)
            throw DisklesslyError.integrity("webdav upload hash does not match the bytes that were sent")
        }
    }

    private func expect(_ response: HTTPResponse, ok: [Int]) throws {
        guard ok.contains(response.status) else {
            let detail = String(decoding: response.body.prefix(180), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            throw DisklesslyError.backend("webdav request failed (HTTP \(response.status)) \(detail)")
        }
    }

    private func names(in body: Data, requested: URL) -> [String] {
        WebDAVXML.responses(body).compactMap { item in
            if isSelf(item.href, requested: requested) { return nil }
            let href = item.href.removingPercentEncoding ?? item.href
            let name = (href as NSString).lastPathComponent
            if name.isEmpty || name == "/" { return nil }
            return name
        }.sorted()
    }

    private func isSelf(_ href: String, requested: URL) -> Bool {
        let resolved = URL(string: href, relativeTo: requested)?.absoluteURL ?? requested
        let left = resolved.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = requested.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return left == right
    }
}
