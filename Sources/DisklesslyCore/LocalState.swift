import Foundation
import CoreFoundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum StateDates {
    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func from(_ value: Any) -> JSONValue {
        if value is NSNull { return .null }
        if let text = value as? String { return .string(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let flag = value as? Bool { return .bool(flag) }
        if let list = value as? [Any] { return .array(list.map(from)) }
        if let object = value as? [String: Any] { return .object(object.mapValues(from)) }
        return .string(String(describing: value))
    }

    public func foundation() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if let exact = Int64(exactly: value) { return exact }
            return value
        case .string(let value): return value
        case .array(let value): return value.map { $0.foundation() }
        case .object(let value): return value.mapValues { $0.foundation() }
        }
    }

    fileprivate static func exactUInt(_ value: JSONValue?) -> UInt64? {
        guard let value else { return nil }
        if let text = value.string, let parsed = UInt64(text) { return parsed }
        if let number = value.int, number >= 0 { return UInt64(exactly: number) }
        return nil
    }

    fileprivate static func exactInt(_ value: JSONValue?) -> Int64? {
        guard let value else { return nil }
        if let text = value.string, let parsed = Int64(text) { return parsed }
        if let number = value.int { return Int64(exactly: number) }
        return nil
    }

    public var string: String? { if case .string(let value) = self { return value } else { return nil } }
    public var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { return value } else { return nil } }
    public var int: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }
}

public struct FileFingerprint: Codable, Equatable, Hashable {
    public var dev: UInt64
    public var ino: UInt64
    public var size: UInt64
    public var mtimeNs: Int64
    public init(dev: UInt64, ino: UInt64, size: UInt64, mtimeNs: Int64) {
        self.dev = dev
        self.ino = ino
        self.size = size
        self.mtimeNs = mtimeNs
    }

    public static func of(url: URL) throws -> FileFingerprint {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw DisklesslyError.failure("stat failed for \(url.path)")
        }
        let mtimeNs: Int64
        #if os(Linux)
        mtimeNs = Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
        #else
        mtimeNs = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        #endif
        return FileFingerprint(dev: UInt64(info.st_dev), ino: UInt64(info.st_ino), size: UInt64(info.st_size), mtimeNs: mtimeNs)
    }
}

public struct VerifiedStamp: Codable, Equatable {
    public var sha256: String
    public var fingerprint: FileFingerprint
    public init(sha256: String, fingerprint: FileFingerprint) {
        self.sha256 = sha256
        self.fingerprint = fingerprint
    }
}

public struct CacheEntry: Codable, Equatable {
    public var lastUsed: Date?
    public var bytes: UInt64?
    public var verified: VerifiedStamp?
    public var extra: [String: JSONValue]
    public init(lastUsed: Date? = nil, bytes: UInt64? = nil, verified: VerifiedStamp? = nil, extra: [String: JSONValue] = [:]) {
        self.lastUsed = lastUsed
        self.bytes = bytes
        self.verified = verified
        self.extra = extra
    }
}

public struct AppState: Codable, Equatable {
    public var imageId: String?
    public var state: String?
    public var mountPoint: String?
    public var lastUsed: Date?
    public var pinned: Bool
    public var mode: String?
    public var lastOutcome: Outcome?
    public var needsResolution: [String: JSONValue]?
    public var extra: [String: JSONValue]

    public struct Outcome: Codable, Equatable {
        public var name: String
        public var at: Date
        public var txid: String
        public init(name: String, at: Date, txid: String) {
            self.name = name
            self.at = at
            self.txid = txid
        }
    }

    public init(imageId: String? = nil, state: String? = nil, mountPoint: String? = nil, lastUsed: Date? = nil, pinned: Bool = false, mode: String? = nil, lastOutcome: Outcome? = nil, needsResolution: [String: JSONValue]? = nil, extra: [String: JSONValue] = [:]) {
        self.imageId = imageId
        self.state = state
        self.mountPoint = mountPoint
        self.lastUsed = lastUsed
        self.pinned = pinned
        self.mode = mode
        self.lastOutcome = lastOutcome
        self.needsResolution = needsResolution
        self.extra = extra
    }
}

public struct RestoredMirror: Codable, Equatable {
    public var journal: String
    public var txid: String
    public var phase: String
    public var waitReason: String
    public var dest: String
    public var staging: String
    public var epoch: Int
    public var postQuitRanForEpoch: Int?
    public var owner: ProcessOwner
    public var extra: [String: JSONValue]
    public init(journal: String, txid: String, phase: String, waitReason: String, dest: String, staging: String, epoch: Int, postQuitRanForEpoch: Int?, owner: ProcessOwner, extra: [String: JSONValue] = [:]) {
        self.journal = journal
        self.txid = txid
        self.phase = phase
        self.waitReason = waitReason
        self.dest = dest
        self.staging = staging
        self.epoch = epoch
        self.postQuitRanForEpoch = postQuitRanForEpoch
        self.owner = owner
        self.extra = extra
    }
}

public struct LocalState: Codable, Equatable {
    public var schema: String
    public var apps: [String: AppState]
    public var cache: [String: CacheEntry]
    public var restored: [String: RestoredMirror]
    public var extra: [String: JSONValue]

    public init(schema: String = "state/2", apps: [String: AppState] = [:], cache: [String: CacheEntry] = [:], restored: [String: RestoredMirror] = [:], extra: [String: JSONValue] = [:]) {
        self.schema = schema
        self.apps = apps
        self.cache = cache
        self.restored = restored
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object = value else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "state is not an object"))
        }
        self = LocalState.parse(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(render())
    }

    public static func parse(_ value: JSONValue) -> LocalState {
        guard let root = value.object else { return LocalState() }
        var state = LocalState()
        let known: Set<String> = ["schema", "apps", "cache", "restored"]
        if let schema = root["schema"]?.string {
            state.schema = schema
        } else if root["schema"] != nil {
            state.extra["schema"] = root["schema"]
            state.schema = "state/1"
        } else {
            state.schema = "state/1"
        }
        if let apps = root["apps"]?.object {
            for (key, item) in apps {
                if let object = item.object {
                    state.apps[key] = parseApp(object)
                }
            }
        } else if let apps = root["apps"] {
            state.extra["apps"] = apps
        }
        if let cache = root["cache"]?.object {
            for (key, item) in cache {
                if let object = item.object {
                    state.cache[key] = parseCache(object)
                }
            }
        } else if let cache = root["cache"] {
            state.extra["cache"] = cache
        }
        if let restored = root["restored"]?.object {
            for (key, item) in restored {
                if let object = item.object {
                    state.restored[key] = parseMirror(object)
                }
            }
        } else if let restored = root["restored"] {
            state.extra["restored"] = restored
        }
        for (key, item) in root where !known.contains(key) && state.extra[key] == nil {
            state.extra[key] = item
        }
        return state
    }

    public func render() -> JSONValue {
        var root: [String: JSONValue] = ["schema": .string(schema)]
        root["apps"] = .object(apps.mapValues { renderApp($0) })
        root["cache"] = .object(cache.mapValues { renderCache($0) })
        root["restored"] = .object(restored.mapValues { renderMirror($0) })
        for (key, value) in extra where root[key] == nil {
            root[key] = value
        }
        return .object(root)
    }

    public func dictionary() -> [String: Any] {
        render().foundation() as? [String: Any] ?? [:]
    }

    public func jsonData() throws -> Data {
        let object = dictionary()
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func parseApp(_ object: [String: JSONValue]) -> AppState {
        var app = AppState()
        let known: Set<String> = ["imageId", "state", "mountPoint", "lastUsed", "pinned", "mode", "lastOutcome", "needsResolution"]
        if let value = object["imageId"] {
            if let text = value.string { app.imageId = text } else { app.extra["imageId"] = value }
        }
        if let value = object["state"] {
            if let text = value.string { app.state = text } else { app.extra["state"] = value }
        }
        if let value = object["mountPoint"] {
            if let text = value.string { app.mountPoint = text } else { app.extra["mountPoint"] = value }
        }
        if let value = object["lastUsed"] {
            if let text = value.string, let date = StateDates.parse(text) { app.lastUsed = date } else { app.extra["lastUsed"] = value }
        }
        if let value = object["pinned"] {
            if let flag = value.bool { app.pinned = flag } else { app.extra["pinned"] = value }
        }
        if let value = object["mode"] {
            if let text = value.string { app.mode = text } else { app.extra["mode"] = value }
        }
        if let value = object["lastOutcome"] {
            if let outcome = value.object, let name = outcome["name"]?.string, let stamp = outcome["at"]?.string, let date = StateDates.parse(stamp), let txid = outcome["txid"]?.string {
                app.lastOutcome = AppState.Outcome(name: name, at: date, txid: txid)
            } else {
                app.extra["lastOutcome"] = value
            }
        }
        if let value = object["needsResolution"] {
            if let map = value.object { app.needsResolution = map } else { app.extra["needsResolution"] = value }
        }
        for (key, item) in object where !known.contains(key) {
            app.extra[key] = item
        }
        return app
    }

    private static func parseCache(_ object: [String: JSONValue]) -> CacheEntry {
        var entry = CacheEntry()
        let known: Set<String> = ["lastUsed", "bytes", "verified"]
        if let value = object["lastUsed"] {
            if let text = value.string, let date = StateDates.parse(text) { entry.lastUsed = date } else { entry.extra["lastUsed"] = value }
        }
        if let value = object["bytes"] {
            if case .number(let number) = value, let bytes = UInt64(exactly: number) {
                entry.bytes = bytes
            } else {
                entry.extra["bytes"] = value
            }
        }
        if let value = object["verified"] {
            if let stamp = parseStamp(value) { entry.verified = stamp } else { entry.extra["verified"] = value }
        }
        for (key, item) in object where !known.contains(key) {
            entry.extra[key] = item
        }
        return entry
    }

    private static func parseStamp(_ value: JSONValue) -> VerifiedStamp? {
        guard let object = value.object, let sha = object["sha256"]?.string, let finger = object["fingerprint"]?.object else { return nil }
        guard let dev = JSONValue.exactUInt(finger["dev"]), let ino = JSONValue.exactUInt(finger["ino"]), let size = JSONValue.exactUInt(finger["size"]), let mtime = JSONValue.exactInt(finger["mtimeNs"]) else { return nil }
        return VerifiedStamp(sha256: sha, fingerprint: FileFingerprint(dev: dev, ino: ino, size: size, mtimeNs: mtime))
    }

    /// Partial mirrors (dest/staging only) stay addressable. Missing fields default;
    /// a value of the wrong type is kept on `extra` so a later write does not drop it.
    private static func parseMirror(_ object: [String: JSONValue]) -> RestoredMirror {
        var extra: [String: JSONValue] = [:]
        func text(_ key: String) -> String {
            guard let value = object[key] else { return "" }
            if let string = value.string { return string }
            extra[key] = value
            return ""
        }
        let epoch: Int
        if let value = object["epoch"] {
            if let number = value.int { epoch = number } else { extra["epoch"] = value; epoch = 0 }
        } else {
            epoch = 0
        }
        let post: Int?
        if let value = object["postQuitRanForEpoch"] {
            if let number = value.int { post = number } else { extra["postQuitRanForEpoch"] = value; post = nil }
        } else {
            post = nil
        }
        var pid: Int32 = 0
        var start: UInt64 = 0
        if let value = object["owner"] {
            if let owner = value.object {
                if let number = owner["pid"]?.int, let narrowed = Int32(exactly: number) { pid = narrowed }
                else if let raw = owner["pid"] { extra["owner.pid"] = raw }
                if let number = JSONValue.exactUInt(owner["start"]) { start = number }
                else if let raw = owner["start"] { extra["owner.start"] = raw }
            } else {
                extra["owner"] = value
            }
        }
        let known: Set<String> = ["journal", "txid", "phase", "waitReason", "dest", "staging", "epoch", "postQuitRanForEpoch", "owner"]
        for (key, item) in object where !known.contains(key) { extra[key] = item }
        return RestoredMirror(
            journal: text("journal"),
            txid: text("txid"),
            phase: text("phase"),
            waitReason: text("waitReason"),
            dest: text("dest"),
            staging: text("staging"),
            epoch: epoch,
            postQuitRanForEpoch: post,
            owner: ProcessOwner(pid: pid, start: start),
            extra: extra
        )
    }

    private func renderApp(_ app: AppState) -> JSONValue {
        var object: [String: JSONValue] = ["pinned": .bool(app.pinned)]
        if let imageId = app.imageId { object["imageId"] = .string(imageId) }
        if let state = app.state { object["state"] = .string(state) }
        if let mountPoint = app.mountPoint { object["mountPoint"] = .string(mountPoint) }
        if let lastUsed = app.lastUsed { object["lastUsed"] = .string(StateDates.string(lastUsed)) }
        if let mode = app.mode { object["mode"] = .string(mode) }
        if let outcome = app.lastOutcome {
            object["lastOutcome"] = .object([
                "name": .string(outcome.name),
                "at": .string(StateDates.string(outcome.at)),
                "txid": .string(outcome.txid),
            ])
        }
        if let needs = app.needsResolution { object["needsResolution"] = .object(needs) }
        for (key, value) in app.extra where object[key] == nil { object[key] = value }
        return .object(object)
    }

    private func renderCache(_ entry: CacheEntry) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let lastUsed = entry.lastUsed { object["lastUsed"] = .string(StateDates.string(lastUsed)) }
        if let bytes = entry.bytes { object["bytes"] = .number(Double(bytes)) }
        if let stamp = entry.verified {
            object["verified"] = .object([
                "sha256": .string(stamp.sha256),
                "fingerprint": .object([
                    "dev": .string(String(stamp.fingerprint.dev)),
                    "ino": .string(String(stamp.fingerprint.ino)),
                    "size": .string(String(stamp.fingerprint.size)),
                    "mtimeNs": .string(String(stamp.fingerprint.mtimeNs)),
                ]),
            ])
        }
        for (key, value) in entry.extra where object[key] == nil { object[key] = value }
        return .object(object)
    }

    private func renderMirror(_ mirror: RestoredMirror) -> JSONValue {
        var object: [String: JSONValue] = [
            "journal": .string(mirror.journal),
            "txid": .string(mirror.txid),
            "phase": .string(mirror.phase),
            "waitReason": .string(mirror.waitReason),
            "dest": .string(mirror.dest),
            "staging": .string(mirror.staging),
            "epoch": .number(Double(mirror.epoch)),
            "owner": .object([
                "pid": .number(Double(mirror.owner.pid)),
                "start": .number(Double(mirror.owner.start)),
            ]),
        ]
        if let post = mirror.postQuitRanForEpoch { object["postQuitRanForEpoch"] = .number(Double(post)) }
        for (key, value) in mirror.extra { object[key] = value }
        return .object(object)
    }
}

public enum StateFileKind: Equatable {
    case missing
    case corrupt
    case legacy
    case current
}
