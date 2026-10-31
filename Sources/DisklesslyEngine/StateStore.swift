import Foundation
import DisklesslyCore

/// `state.json` guarded by `state.lock`. Nested `update` calls in one process flock once.
/// Do not take `locks/app/*.lock` or do slow I/O while an update is in progress.
public struct StateStore {
    public let dir: URL
    private static let gate = NSRecursiveLock()
    private static var depths: [String: Int] = [:]
    private static var held: [String: FileLock] = [:]
    private final class OpenState { var state: LocalState; init(_ state: LocalState) { self.state = state } }
    private static var open: [String: OpenState] = [:]

    public init(_ path: String) {
        dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func load() -> LocalState {
        let url = file
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return LocalState() }
        guard let object = try? JSONSerialization.jsonObject(with: data), let value = Optional(JSONValue.from(object)), value.object != nil else {
            return LocalState()
        }
        return LocalState.parse(value)
    }

    public func update<T>(_ body: (inout LocalState) throws -> T) throws -> T {
        let path = lockFile.path
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        Self.gate.lock()
        defer { Self.gate.unlock() }
        let depth = Self.depths[path] ?? 0
        if let existing = Self.open[path] {
            Self.depths[path] = depth + 1
            defer { Self.release(path) }
            var local = existing.state
            let base = local
            let result = try body(&local)
            existing.state = Self.merge(base: base, local: local, published: existing.state)
            return result
        }
        var lock = FileLock(path: path)
        try lock.lock()
        Self.held[path] = lock
        Self.depths[path] = depth + 1
        defer {
            Self.open[path] = nil
            Self.release(path)
        }
        let kind = inspect()
        if kind == .corrupt {
            let stamp = Int(Date().timeIntervalSince1970)
            let name = "state.json.corrupt-\(stamp)"
            let copy = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.copyItem(at: file, to: copy)
            }
            throw DisklesslyError.integrity("state.json is corrupt; a copy was kept at \(name)")
        }
        let box = OpenState(load())
        Self.open[path] = box
        var local = box.state
        let base = local
        let result = try body(&local)
        box.state = Self.merge(base: base, local: local, published: box.state)
        if kind == .legacy {
            let backup = dir.appendingPathComponent("state.json.v1.bak")
            if !FileManager.default.fileExists(atPath: backup.path), FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: file, to: backup)
            }
        }
        box.state.schema = "state/2"
        try AtomicFile.write(try box.state.jsonData(), to: file)
        try DurableIO.syncItem(dir)
        return result
    }

    private static func merge(base: LocalState, local: LocalState, published: LocalState) -> LocalState {
        var result = published
        result.schema = local.schema
        result.apps = mergeMap(base.apps, local.apps, published.apps)
        result.cache = mergeMap(base.cache, local.cache, published.cache)
        result.restored = mergeMap(base.restored, local.restored, published.restored)
        result.extra = mergeMap(base.extra, local.extra, published.extra)
        return result
    }

    private static func mergeMap<V: Equatable>(_ base: [String: V], _ local: [String: V], _ published: [String: V]) -> [String: V] {
        var result = published
        for (key, value) in local where base[key] != value {
            result[key] = value
        }
        for key in base.keys where local[key] == nil {
            result.removeValue(forKey: key)
        }
        return result
    }

    private static func release(_ path: String) {
        let next = (depths[path] ?? 1) - 1
        if next <= 0 {
            depths[path] = nil
            var lock = held.removeValue(forKey: path)
            lock?.unlock()
        } else {
            depths[path] = next
        }
    }

    public func read() -> [String: Any] { load().dictionary() }

    public func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let parsed = LocalState.parse(JSONValue.from(try JSONSerialization.jsonObject(with: data)))
        try update { state in
            state = parsed
        }
    }

    public func setAppState(bundleId: String, imageId: String, state name: String, mountPoint: String? = nil, lastUsed: Date = Date()) throws {
        try update { state in
            var app = state.apps[bundleId] ?? AppState()
            app.imageId = imageId
            app.state = name
            app.mountPoint = mountPoint
            app.lastUsed = lastUsed
            state.apps[bundleId] = app
            var entry = state.cache[imageId] ?? CacheEntry()
            entry.lastUsed = lastUsed
            state.cache[imageId] = entry
        }
    }

    public func applyRetirement(appId: String, imageId: String, outcome: String, at: Date, txid: String, needsResolution: [String: Any]?, updateLastUsed: Bool) throws {
        try update { state in
            state.restored.removeValue(forKey: appId)
            var app = state.apps[appId] ?? AppState()
            app.imageId = imageId
            app.state = needsResolution == nil ? "cached" : "needsResolution"
            app.lastOutcome = AppState.Outcome(name: outcome, at: at, txid: txid)
            app.mountPoint = nil
            if updateLastUsed { app.lastUsed = at }
            if let needsResolution {
                app.needsResolution = needsResolution.mapValues(JSONValue.from)
            } else {
                app.needsResolution = nil
            }
            state.apps[appId] = app
            if updateLastUsed {
                var entry = state.cache[imageId] ?? CacheEntry()
                entry.lastUsed = at
                state.cache[imageId] = entry
            }
        }
    }

    private var file: URL { dir.appendingPathComponent("state.json") }
    private var lockFile: URL { dir.appendingPathComponent("state.lock") }

    private func inspect() -> StateFileKind {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return .corrupt }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .corrupt }
        let schema = object["schema"] as? String
        if schema == nil || schema == "state/1" { return .legacy }
        return .current
    }
}
