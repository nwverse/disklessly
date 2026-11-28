import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenList 3 and AList 3. The routes are `/api/auth/login`, `/api/fs/list`,
/// `/api/fs/get`, `/api/fs/put`, `/api/fs/remove`, and `/api/fs/mkdir`.
/// AList 2 is not supported. The login token is stored in the Keychain; the
/// password stays there too so a 401 can log in again. Neither value is written
/// to config.
public enum OpenListAPI {
    public static let supportedVersions = "OpenList 3 and AList 3 (/api/fs)"
}

public struct OpenListBackend: StorageBackend {
    public let baseURL: URL
    public let root: String
    public let user: String
    public let password: String
    public let transport: any HTTPTransport
    public let secrets: any SecretStore
    public let secretAccount: String
    final class Session {
        var token: String?
    }
    let session = Session()

    public init(baseURL: URL, root: String, user: String, password: String, transport: any HTTPTransport, secrets: any SecretStore, secretAccount: String) {
        self.baseURL = baseURL
        self.root = root
        self.user = user
        self.password = password
        self.transport = transport
        self.secrets = secrets
        self.secretAccount = secretAccount
    }

    public func localRoot() -> URL? { nil }

    public func list(_ path: String) throws -> [String] {
        let payload = try rpc(path: "/api/fs/list", body: ["path": try remotePath(path), "refresh": false])
        let data = payload["data"] as? [String: Any] ?? [:]
        let content = data["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["name"] as? String }.sorted()
    }

    public func entries(_ path: String) throws -> [BackendEntry] {
        let payload = try rpc(path: "/api/fs/list", body: ["path": try remotePath(path), "refresh": false])
        let data = payload["data"] as? [String: Any] ?? [:]
        let content = data["content"] as? [[String: Any]] ?? []
        return content.compactMap { item -> BackendEntry? in
            guard let name = item["name"] as? String else { return nil }
            let isDir = item["is_dir"] as? Bool ?? false
            return BackendEntry(name: name, isDirectory: isDir, size: isDir ? nil : (item["size"] as? NSNumber)?.uint64Value)
        }.sorted { $0.name < $1.name }
    }

    public func stat(_ path: String) throws -> BackendStat? {
        let response = try call(path: "/api/fs/get", body: ["path": try remotePath(path)], allowMissing: true)
        guard response.code == 200 else { return nil }
        let data = response.object["data"] as? [String: Any] ?? [:]
        let size = (data["size"] as? NSNumber)?.uint64Value ?? 0
        return BackendStat(size: size, modified: .distantPast)
    }

    public func get(_ path: String, range: Range<UInt64>?) throws -> Data {
        if let range {
            let body = try getResumable(path, offset: range.lowerBound)
            if body.restart {
                let count = UInt64(body.data.count)
                let lo = Int(min(range.lowerBound, count))
                let hi = Int(min(range.upperBound, count))
                guard lo <= hi else { return Data() }
                return body.data.subdata(in: lo..<hi)
            }
            let upper = range.upperBound > range.lowerBound ? range.upperBound - range.lowerBound : 0
            if upper < UInt64(body.data.count), upper <= UInt64(Int.max) {
                return Data(body.data.prefix(Int(upper)))
            }
            return body.data
        }
        return try getResumable(path, offset: 0).data
    }

    public func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody {
        let info = try rpc(path: "/api/fs/get", body: ["path": try remotePath(path)])
        guard let data = info["data"] as? [String: Any], let raw = data["raw_url"] as? String, let url = URL(string: raw) else {
            throw DisklesslyError.backend("openlist fs/get did not return a raw_url")
        }
        return try fetchRaw(url, offset: offset, renew: { try self.rawURL(path) })
    }

    public func put(_ path: String, data: Data) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-openlist-\(UUID().uuidString)")
        try ChunkedIO.writeAtomically(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try put(path, file: temporary)
    }

    public func put(_ path: String, file: URL) throws {
        guard !WriteOnceScope.exclusive else {
            if try stat(path) != nil {
                throw WriteOnceConflict(path: path)
            }
            throw DisklesslyError.unsupported("openlist cannot create \(path) atomically; refusing a write-once upload")
        }
        let remote = try remotePath(path)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = remote.addingPercentEncoding(withAllowedCharacters: allowed) ?? remote
        let uploadHeaders = [
            "File-Path": encoded,
            "As-Task": "false",
            "Content-Type": "application/octet-stream",
            "Content-Length": String(try ChunkedIO.byteCount(file)),
        ]
        let response = try sendUpload(url: try api("/api/fs/put"), headers: uploadHeaders, file: file, authorized: true)
        let envelope = try decodeAPIResponse(response, requireCode: true)
        if envelope.code == 401 {
            try login()
            let retry = try sendUpload(url: try api("/api/fs/put"), headers: uploadHeaders, file: file, authorized: true)
            let retried = try decodeAPIResponse(retry, requireCode: true)
            guard retry.status == 200 && retried.code == 200 else {
                throw apiFailure(path: "/api/fs/put", status: retry.status, response: retried)
            }
        } else {
            guard response.status == 200 && envelope.code == 200 else {
                throw apiFailure(path: "/api/fs/put", status: response.status, response: envelope)
            }
        }
        try verify(path, expected: SHA256Digest.hexFile(file))
    }

    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        let info = try rpc(path: "/api/fs/get", body: ["path": try remotePath(path)])
        guard let data = info["data"] as? [String: Any], let raw = data["raw_url"] as? String, let url = URL(string: raw) else {
            throw DisklesslyError.backend("openlist fs/get did not return a raw_url")
        }
        return try fetchRawFile(url, offset: offset, to: destination, renew: { try self.rawURL(path) })
    }

    public func delete(_ path: String) throws {
        let remote = try remotePath(path)
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "." { throw DisklesslyError.usage("refusing to delete the OpenList root") }
        let parent = (remote as NSString).deletingLastPathComponent
        let name = (remote as NSString).lastPathComponent
        _ = try rpc(path: "/api/fs/remove", body: ["dir": parent.isEmpty ? "/" : parent, "names": [name]])
    }

    public func ensureCollection(_ path: String) throws {
        _ = try rpc(path: "/api/fs/mkdir", body: ["path": try remotePath(path)])
    }

    private func rawURL(_ path: String) throws -> URL {
        let info = try rpc(path: "/api/fs/get", body: ["path": try remotePath(path)])
        guard let data = info["data"] as? [String: Any], let raw = data["raw_url"] as? String, let url = URL(string: raw) else {
            throw DisklesslyError.backend("openlist fs/get did not return a raw_url")
        }
        return url
    }

    private func fetchRaw(_ url: URL, offset: UInt64, renew: () throws -> URL) throws -> ResumableBody {
        func once(_ target: URL) throws -> HTTPResponse {
            var headers: [String: String] = [:]
            if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
            return try send(method: "GET", url: target, headers: headers, body: nil, authorized: false)
        }
        var response = try once(url)
        if response.status == 403 || response.status == 410 {
            response = try once(try renew())
        }
        if response.status == 404 { throw DisklesslyError.backend("remote object is missing") }
        if offset > 0 && response.status == 200 {
            return ResumableBody(data: response.body, restart: true)
        }
        guard [200, 206].contains(response.status) else {
            throw DisklesslyError.backend("openlist download failed (HTTP \(response.status))")
        }
        return ResumableBody(data: response.body, restart: false)
    }

    private func fetchRawFile(_ url: URL, offset: UInt64, to destination: URL, renew: () throws -> URL) throws -> ResumableFile {
        func once(_ target: URL) throws -> (HTTPResponse, URL) {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-openlist-\(UUID().uuidString)")
            var headers: [String: String] = [:]
            if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
            let response = try downloadRaw(target, headers: headers, to: staging)
            return (response, staging)
        }
        var (response, staging) = try once(url)
        if response.status == 403 || response.status == 410 {
            try? FileManager.default.removeItem(at: staging)
            (response, staging) = try once(try renew())
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        if response.status == 404 { throw DisklesslyError.backend("remote object is missing") }
        let received = (try? ChunkedIO.byteCount(staging)) ?? 0
        if offset > 0 && response.status == 200 {
            try ChunkedIO.replaceFile(destination, with: staging)
            return ResumableFile(restart: true, bytesWritten: received)
        }
        guard [200, 206].contains(response.status) else {
            throw DisklesslyError.backend("openlist download failed (HTTP \(response.status))")
        }
        if offset == 0 || response.status == 200 {
            try ChunkedIO.replaceFile(destination, with: staging)
        } else {
            try ChunkedIO.appendFile(staging, to: destination)
        }
        return ResumableFile(restart: false, bytesWritten: received)
    }

    private func verify(_ path: String, expected: String) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try download(path, to: staging, offset: 0)
        guard try SHA256Digest.hexFile(staging) == expected else {
            throw DisklesslyError.integrity("openlist upload hash does not match the bytes that were sent")
        }
    }

    private func rpc(path: String, body: [String: Any]) throws -> [String: Any] {
        let response = try call(path: path, body: body, allowMissing: false)
        guard response.code == 200 else {
            throw apiFailure(path: path, status: response.status, response: response)
        }
        return response.object
    }

    private struct APIResponse {
        var status: Int
        var code: Int
        var object: [String: Any]
    }

    private func call(path: String, body: [String: Any], allowMissing: Bool) throws -> APIResponse {
        let url = try api(path)
        let data = try JSONSerialization.data(withJSONObject: body)
        var response = try send(method: "POST", url: url, headers: ["Content-Type": "application/json"], body: data, authorized: true)
        if response.status == 401 {
            try login()
            response = try send(method: "POST", url: url, headers: ["Content-Type": "application/json"], body: data, authorized: true)
        }
        let api = try decodeAPIResponse(response, requireCode: false)
        if api.code == 401 {
            try login()
            let retry = try send(method: "POST", url: url, headers: ["Content-Type": "application/json"], body: data, authorized: true)
            return try decodeAPIResponse(retry, requireCode: false)
        }
        if !allowMissing && response.status != 200 && api.code != 200 {
            throw apiFailure(path: path, status: response.status, response: api)
        }
        return api
    }

    private func decodeAPIResponse(_ response: HTTPResponse, requireCode: Bool) throws -> APIResponse {
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw DisklesslyError.backend("openlist returned a non-object body (HTTP \(response.status))")
        }
        let code: Int
        if let value = object["code"] as? NSNumber {
            code = value.intValue
        } else if requireCode {
            throw DisklesslyError.backend("openlist returned no JSON code (HTTP \(response.status))")
        } else {
            code = response.status
        }
        return APIResponse(status: response.status, code: code, object: object)
    }

    private func apiFailure(path: String, status: Int, response: APIResponse) -> DisklesslyError {
        let message = (response.object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = message.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
        if status == 200 {
            return DisklesslyError.backend("openlist \(path) failed (code \(response.code))\(detail)")
        }
        return DisklesslyError.backend("openlist \(path) failed (HTTP \(status), code \(response.code))\(detail)")
    }

    private func login() throws {
        let url = try api("/api/auth/login")
        let data = try JSONSerialization.data(withJSONObject: ["username": user, "password": password])
        let response = try send(method: "POST", url: url, headers: ["Content-Type": "application/json"], body: data, authorized: false)
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let token = payload["token"] as? String, !token.isEmpty else {
            throw DisklesslyError.backend("openlist login failed (HTTP \(response.status))")
        }
        session.token = token
        try secrets.save(service: BackendCatalog.keychainService, account: "openlist-token:\(secretAccount)", secret: token)
    }

    private func send(method: String, url: URL, headers: [String: String], body: Data?, authorized: Bool) throws -> HTTPResponse {
        try dispatch(method: method, url: url, headers: headers, authorized: authorized) { headers in
            try transport.send(method: method, url: url, headers: headers, body: body)
        }
    }

    private func sendUpload(url: URL, headers: [String: String], file: URL, authorized: Bool) throws -> HTTPResponse {
        try dispatch(method: "PUT", url: url, headers: headers, authorized: authorized) { headers in
            try transport.upload(method: "PUT", url: url, headers: headers, file: file)
        }
    }

    private func downloadRaw(_ url: URL, headers: [String: String], to destination: URL) throws -> HTTPResponse {
        try dispatch(method: "GET", url: url, headers: headers, authorized: false) { headers in
            try transport.download(method: "GET", url: url, headers: headers, to: destination)
        }
    }

    private func dispatch(method: String, url: URL, headers: [String: String], authorized: Bool, perform: ([String: String]) throws -> HTTPResponse) throws -> HTTPResponse {
        var headers = headers
        if authorized { try authorize(&headers) }
        do {
            var response = try perform(headers)
            if response.status == 401 && authorized {
                try login()
                try authorize(&headers)
                response = try perform(headers)
            }
            if response.status == 0 || response.status == 503 {
                throw DisklesslyError.backend("openlist unavailable (HTTP \(response.status))")
            }
            return response
        } catch let error as DisklesslyError {
            throw error
        } catch {
            throw DisklesslyError.backend("openlist offline: \(error.localizedDescription)")
        }
    }

    private func authorize(_ headers: inout [String: String]) throws {
        if session.token == nil {
            session.token = try secrets.load(service: BackendCatalog.keychainService, account: "openlist-token:\(secretAccount)")
        }
        if session.token == nil { try login() }
        if let token = session.token { headers["Authorization"] = token }
    }

    private func api(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw DisklesslyError.backend("invalid OpenList URL")
        }
        return url
    }

    private func remotePath(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw DisklesslyError.usage("Invalid backend path")
        }
        let base = root == "/" ? "" : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { return base.isEmpty ? "/" : "/" + base }
        if base.isEmpty { return "/" + path }
        return "/" + base + "/" + path
    }
}
