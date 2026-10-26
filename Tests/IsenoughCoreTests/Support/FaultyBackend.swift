import Foundation
import IsenoughCore

/// Test double that fails selected backend calls and records every call.
/// Prefixes match the path itself or a path under that prefix (`devices` matches `devices/a.json`).
public final class FaultyBackend: StorageBackend {
    public let inner: LocalFolderBackend
    public var failList: Set<String>
    public var failGet: Set<String>
    public var failPut: Set<String>
    public var failStat: Set<String>
    public private(set) var calls: [String] = []

    public init(inner: LocalFolderBackend, failList: Set<String> = [], failGet: Set<String> = [], failPut: Set<String> = [], failStat: Set<String> = []) {
        self.inner = inner
        self.failList = failList
        self.failGet = failGet
        self.failPut = failPut
        self.failStat = failStat
    }

    public convenience init(root: URL, failList: Set<String> = [], failGet: Set<String> = [], failPut: Set<String> = [], failStat: Set<String> = []) throws {
        try self.init(inner: LocalFolderBackend(root: root), failList: failList, failGet: failGet, failPut: failPut, failStat: failStat)
    }

    private func hits(_ set: Set<String>, _ path: String) -> Bool {
        set.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private func note(_ kind: String, _ path: String) {
        calls.append("\(kind):\(path)")
    }

    private func reject(_ set: Set<String>, _ path: String) throws {
        if hits(set, path) { throw IsenoughError.backend("injected") }
    }

    public func list(_ path: String) throws -> [String] {
        note("list", path)
        try reject(failList, path)
        return try inner.list(path)
    }

    public func stat(_ path: String) throws -> BackendStat? {
        note("stat", path)
        try reject(failStat, path)
        return try inner.stat(path)
    }

    public func get(_ path: String, range: Range<UInt64>?) throws -> Data {
        note("get", path)
        try reject(failGet, path)
        return try inner.get(path, range: range)
    }

    public func put(_ path: String, data: Data) throws {
        note("put", path)
        try reject(failPut, path)
        try inner.put(path, data: data)
    }

    public func put(_ path: String, file: URL) throws {
        note("put", path)
        try reject(failPut, path)
        try inner.put(path, file: file)
    }

    public func delete(_ path: String) throws {
        note("delete", path)
        try inner.delete(path)
    }

    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        note("get", path)
        try reject(failGet, path)
        return try inner.download(path, to: destination, offset: offset)
    }

    public func localRoot() -> URL? { inner.localRoot() }

    public func ensureCollection(_ path: String) throws {
        note("ensure", path)
        try inner.ensureCollection(path)
    }
}
