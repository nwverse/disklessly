import Foundation
import DisklesslyCore
import DisklesslySessions

/// One transcript archived by a `sessions --apply` run (uploaded, verified, and
/// removed locally).
public struct SessionArchivedItem: Equatable {
    public var id: String
    public var path: String
    public var sessionId: String
    public var bytes: Int64
    public init(id: String, path: String, sessionId: String, bytes: Int64) {
        self.id = id
        self.path = path
        self.sessionId = sessionId
        self.bytes = bytes
    }
}

public struct SessionRestoreResult: Equatable {
    public var path: String
    public var id: String
    public var sessionId: String
}

/// Whether the repo answers: `repo.json` can be stat'ed within `timeout`.
public struct SessionBackendStatus: Equatable {
    public var reachable: Bool
    public var latencyMs: Int
    public var error: String
    public init(reachable: Bool, latencyMs: Int, error: String) {
        self.reachable = reachable
        self.latencyMs = latencyMs
        self.error = error
    }
}

public enum SessionBackendCheck {
    public static let defaultTimeout: TimeInterval = 10

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var outcome: (status: SessionBackendStatus, backend: (any StorageBackend)?)?
    }

    public static let missingMarker = "repo.json is not in the backend; if the repo folder is there and new, run disklessly init"

    /// Nil when the repo answers, else why not. The marker `repo.json` answers;
    /// with `mirrors`, a mirror of a `FailoverBackend` that has it answers too. A
    /// repo without the marker that `RepoIdentity.ensure` will not mark (it holds
    /// manifests, images, or a placeholder or conflict copy of `repo.json`) also
    /// answers, since `init` cannot fix it. An empty folder, which is what a local
    /// repo on a missing volume reopens as, does not.
    static func markerProblem(_ backend: any StorageBackend, mirrors: Bool) throws -> String? {
        if try backend.stat(RepoIdentity.path) != nil { return nil }
        if mirrors, let failover = backend as? FailoverBackend, failover.statOnMirrors(RepoIdentity.path) != nil { return nil }
        if let names = try? backend.list(""), !names.isEmpty, !RepoIdentity.isSafeToCreate(backend) { return nil }
        return missingMarker
    }

    /// Opens the backend and checks the repo marker on a worker thread (see
    /// `markerProblem`). A missing marker, an error, or no answer within `timeout`
    /// is unreachable. A local folder whose volume is gone has no `repo.json`, so
    /// it is never mistaken for an empty repo.
    public static func probe(timeout: TimeInterval = defaultTimeout, mirrors: Bool = false, _ open: @escaping () throws -> any StorageBackend) -> (status: SessionBackendStatus, backend: (any StorageBackend)?) {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let started = Date()
        let thread = Thread {
            var result: (SessionBackendStatus, (any StorageBackend)?)
            do {
                let backend = try open()
                let problem = try markerProblem(backend, mirrors: mirrors)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                result = (SessionBackendStatus(reachable: problem == nil, latencyMs: ms, error: problem ?? ""), backend)
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                result = (SessionBackendStatus(reachable: false, latencyMs: ms, error: text), nil)
            }
            box.lock.lock()
            box.outcome = result
            box.lock.unlock()
            done.signal()
        }
        thread.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            return (SessionBackendStatus(reachable: false, latencyMs: Int(timeout * 1000), error: "no answer within \(Int(timeout)) s"), nil)
        }
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.outcome ?? (SessionBackendStatus(reachable: false, latencyMs: 0, error: "no answer"), nil)
    }

    /// Throws exit 4 (`backend unreachable: …`) unless the repo marker answers.
    /// `mirrors` is for reads only (restore): writes go to the primary.
    public static func require(_ backend: any StorageBackend, timeout: TimeInterval = defaultTimeout, mirrors: Bool = false) throws {
        let status = probe(timeout: timeout, mirrors: mirrors) { backend }.status
        guard status.reachable else { throw DisklesslyError.backend("backend unreachable: \(status.error)") }
    }
}

extension SessionArchive {
    public static let listStates = ["archived", "remote", "restored", "keptLocal", "pendingDelete"]

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    struct Catalog {
        var deviceId: String
        var rows: [SessionEntryRow]
        var segments: [String: SessionSegmentRow]
    }

    static func catalog(config: RuntimeConfig) throws -> Catalog {
        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        _ = try SessionMigration.migrateIfNeeded(stateDir: config.stateDir, deviceId: device.deviceId, database: database)
        return Catalog(deviceId: device.deviceId, rows: try database.allEntries(), segments: try database.segments())
    }

    /// The partition project a row is filed under: the folder of a partitioned
    /// segment path, else the key its working directory would get.
    static func project(_ row: SessionEntryRow, segment: SessionSegmentRow?) -> String {
        if let segment {
            let parts = segment.path.split(separator: "/").map(String.init)
            if parts.count >= 6, parts[0] == "sessions" { return parts[3] }
        }
        return SessionIdentity.projectKey(cwd: row.cwd, encrypted: segment?.encrypted ?? false)
    }

    static func title(_ row: SessionEntryRow) -> String {
        let preview = row.preview.trimmingCharacters(in: .whitespaces)
        if !preview.isEmpty, !preview.hasPrefix("{"), !preview.hasPrefix("[") { return preview }
        return SessionDigest.title(fromDigest: row.digest)
    }

    static func entryJSON(_ row: SessionEntryRow, segments: [String: SessionSegmentRow], localDevice: String, includeDigest: Bool) -> [String: Any] {
        let segment = row.segmentId.flatMap { segments[$0] }
        let modified = Date(timeIntervalSince1970: Double(row.mtimeNs) / 1_000_000_000)
        var object: [String: Any] = [
            "id": row.id,
            "deviceId": row.deviceId,
            "local": row.deviceId == localDevice,
            "tool": row.tool,
            "path": row.path,
            "sessionId": SessionIdentity.sessionId(tool: row.tool, path: row.path),
            "cwd": row.cwd,
            "project": project(row, segment: segment),
            "month": SessionIdentity.month(modified),
            "mtime": rfc3339(modified),
            "archivedAt": row.archivedAt,
            "bytes": NSNumber(value: row.size),
            "state": row.state,
            "title": title(row),
            "firstPrompt": row.firstPrompt,
            "segment": segment?.path ?? row.legacyArchive ?? "",
            "encrypted": segment?.encrypted ?? false,
        ]
        if includeDigest { object["digest"] = row.digest }
        return object
    }

    /// `sessions list`: index rows, newest mtime first. Reads the local index only.
    public static func listSessions(config: RuntimeConfig, state: String = "all", tool: String? = nil, limit: Int? = nil, includeDigest: Bool = false) throws -> [String: Any] {
        guard state == "all" || listStates.contains(state) else {
            throw DisklesslyError.usage("invalid --state \(state)")
        }
        let catalog = try catalog(config: config)
        var rows = catalog.rows.filter { (state == "all" || $0.state == state) && (tool == nil || $0.tool == tool) }
        rows.sort { $0.mtimeNs != $1.mtimeNs ? $0.mtimeNs > $1.mtimeNs : $0.id < $1.id }
        if let limit { rows = Array(rows.prefix(limit)) }
        return ["ok": true, "deviceId": catalog.deviceId,
                "entries": rows.map { entryJSON($0, segments: catalog.segments, localDevice: catalog.deviceId, includeDigest: includeDigest) }]
    }

    /// Extra fields for `sessions search` hits, keyed by entry id.
    public static func searchDetails(config: RuntimeConfig) throws -> [String: [String: Any]] {
        let catalog = try catalog(config: config)
        var details: [String: [String: Any]] = [:]
        for row in catalog.rows {
            details[row.id] = [
                "deviceId": row.deviceId,
                "state": row.state,
                "mtime": rfc3339(Date(timeIntervalSince1970: Double(row.mtimeNs) / 1_000_000_000)),
                "bytes": NSNumber(value: row.size),
                "cwd": row.cwd,
                "sessionId": SessionIdentity.sessionId(tool: row.tool, path: row.path),
            ]
        }
        return details
    }

    public static let segmentCheckTimeout: TimeInterval = 60

    private final class SegmentCheck: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var checked = 0
        var missing: [String] = []
        var unchecked: [String] = []
    }

    /// Stats each path on a worker thread until `deadline`. A path that is not
    /// there is missing; a stat that throws, or one not reached in time, is
    /// unchecked (unknown, never reported as missing).
    static func checkSegments(_ paths: [String], backend: any StorageBackend, timeout: TimeInterval) -> (checked: Int, missing: [String], unchecked: [String], timedOut: Bool) {
        let box = SegmentCheck()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            for path in paths {
                box.lock.lock()
                let stop = box.cancelled
                box.lock.unlock()
                if stop { break }
                let found: BackendStat??
                do { found = .some(try backend.stat(path)) } catch { found = nil }
                box.lock.lock()
                if !box.cancelled {
                    switch found {
                    case .some(.some): box.checked += 1
                    case .some(.none): box.checked += 1; box.missing.append(path)
                    case .none: box.unchecked.append(path)
                    }
                }
                box.lock.unlock()
            }
            done.signal()
        }
        thread.start()
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        box.lock.lock()
        defer { box.lock.unlock() }
        box.cancelled = true
        var unchecked = box.unchecked
        if timedOut {
            // Paths are walked in order, so the ones after the first
            // `checked + unchecked` were never asked.
            unchecked += paths.dropFirst(box.checked + box.unchecked.count)
        }
        return (box.checked, box.missing, unchecked, timedOut)
    }

    /// `sessions status`: counts from the local index and whether the repo answers.
    /// It succeeds whenever the index opens, even with the backend down.
    public static func sessionStatus(config: RuntimeConfig, backendId: String, backendType: String, checkSegments: Bool = false, timeout: TimeInterval = SessionBackendCheck.defaultTimeout, segmentTimeout: TimeInterval = segmentCheckTimeout, open: @escaping () throws -> any StorageBackend) throws -> [String: Any] {
        let catalog = try catalog(config: config)
        var counts: [String: Int] = Dictionary(uniqueKeysWithValues: listStates.map { ($0, 0) })
        var archivedBytes: Int64 = 0
        var referenced = Set<String>()
        for row in catalog.rows {
            counts[row.state, default: 0] += 1
            if row.state == "archived" { archivedBytes += row.size }
            if row.state == "archived" || row.state == "remote" {
                if let path = row.segmentId.flatMap({ catalog.segments[$0]?.path }) ?? row.legacyArchive { referenced.insert(path) }
            }
        }
        let probe = SessionBackendCheck.probe(timeout: timeout, open)
        var checked = 0
        var missing: [String] = []
        var unchecked: [String] = []
        var timedOut = false
        if checkSegments, probe.status.reachable, let backend = probe.backend {
            (checked, missing, unchecked, timedOut) = Self.checkSegments(referenced.sorted(), backend: backend, timeout: segmentTimeout)
        }
        return [
            "ok": true,
            "deviceId": catalog.deviceId,
            "stateDir": SessionPaths.canonical(config.stateDir),
            "backend": [
                "id": backendId,
                "type": backendType,
                "reachable": probe.status.reachable,
                "latencyMs": probe.status.latencyMs,
                "error": probe.status.error,
            ] as [String: Any],
            "counts": counts.mapValues { NSNumber(value: $0) },
            "archivedBytes": NSNumber(value: archivedBytes),
            "textDir": SessionTextIndex.directory(stateDir: SessionPaths.canonical(config.stateDir)).path,
            "textFiles": NSNumber(value: SessionTextIndex.count(stateDir: config.stateDir)),
            "segments": ["total": referenced.count, "checked": checked, "missing": missing, "unchecked": unchecked, "timedOut": timedOut] as [String: Any],
        ]
    }
}
