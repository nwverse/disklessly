import Foundation
import DisklesslyCore

public struct RepoSwitchReport {
    public var from: String
    public var to: String
    /// False when nothing was copied because the old repo was empty or `migrate` was off.
    public var migrated: Bool
    public var sync: RepoCopyReport
    /// The old repo's id when it was kept as a mirror.
    public var keptAsMirror: String?

    public var dictionary: [String: Any] {
        var object: [String: Any] = ["from": from, "backendId": to, "migrated": migrated]
        object.merge(sync.dictionary) { $1 }
        if let keptAsMirror { object["keptAsMirror"] = keptAsMirror }
        return object
    }
}

/// Last `repo mirror sync` per mirror, kept in `<stateDir>/mirrors.json`.
public struct MirrorSyncStatus: Codable, Equatable {
    public var lastSyncAt: Date
    public var ok: Bool
    public var message: String?
    public var copied: Int
    public var skipped: Int
    public var failed: Int
    public var bytesCopied: UInt64

    public var dictionary: [String: Any] {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = ["lastSyncAt": formatter.string(from: lastSyncAt), "ok": ok, "copied": copied, "skipped": skipped,
                                     "failed": failed, "bytesCopied": NSNumber(value: bytesCopied)]
        if let message { object["message"] = message }
        return object
    }
}

public enum MirrorStatusStore {
    public static func url(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("mirrors.json")
    }

    public static func load(stateDir: String) -> [String: MirrorSyncStatus] {
        guard let data = try? Data(contentsOf: url(stateDir: stateDir)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: MirrorSyncStatus].self, from: data)) ?? [:]
    }

    public static func save(_ statuses: [String: MirrorSyncStatus], stateDir: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try encoder.encode(statuses).write(to: url(stateDir: stateDir), options: .atomic)
    }
}

extension RuntimeConfig {
    /// Makes `id` the active repo (`default` or a known backend).
    mutating func activate(_ id: String) throws {
        if id == Self.defaultRepoId {
            useDefaultRepo()
        } else {
            guard let endpoint = backends.first(where: { $0.id == id }) else { throw DisklesslyError.usage("unknown backend: \(id)") }
            remember(endpoint)
        }
        mirrorBackendIds.removeAll { $0 == id }
    }

    func knowsRepo(_ id: String) -> Bool {
        id == Self.defaultRepoId || backends.contains { $0.id == id }
    }
}

extension DisklesslyEngine {
    /// Staging folder for repo copies: on this Mac's cache volume, emptied before each run.
    var repoSyncStaging: URL {
        URL(fileURLWithPath: config.cacheDir).appendingPathComponent("repo-sync", isDirectory: true)
    }

    /// Makes `id` the active repo. With `migrate`, every object of the current repo is
    /// first copied onto the new one (`RepoCopier`), copied again to catch writes made
    /// meanwhile, and verified; only then is the config switched and saved. Any failure
    /// throws and leaves the config on the old repo. An empty old repo (or `migrate`
    /// off) switches at once, as before.
    ///
    /// `keepOldAsMirror` adds the old repo to `mirrorBackendIds`. `latest` supplies the
    /// newest saved config at switch time (the web UI may have changed it meanwhile).
    @discardableResult
    public mutating func switchRepo(to id: String, migrate: Bool, keepOldAsMirror: Bool = false,
                                    latest: () -> RuntimeConfig? = { nil },
                                    progress: (RepoCopyProgress) -> Void = { _ in }) throws -> RepoSwitchReport {
        guard config.knowsRepo(id) else { throw DisklesslyError.usage("unknown backend: \(id)") }
        let from = config.activeRepoId
        guard from != id else { throw DisklesslyError.usage("\(id) is already the active repo") }
        var report = RepoSwitchReport(from: from, to: id, migrated: false, sync: RepoCopyReport(), keptAsMirror: nil)
        if migrate {
            var target = self
            target.backendOverride = nil
            target.config.mirrorBackendIds = []
            try target.config.activate(id)
            let old = try openPrimaryBackend()
            let new = try target.openPrimaryBackend()
            if Self.sameFolder(old, new) {
                throw DisklesslyError.usage("\(id) is the same folder as the current repo; use backend use \(id) to switch without copying")
            }
            progress(RepoCopyProgress(phase: "scan"))
            if try RepoCopier.hasContent(old) {
                // A legacy repo gets its id now so the copy carries it.
                _ = try? RepoIdentity.ensure(old)
                try? FileManager.default.removeItem(at: repoSyncStaging)
                defer { try? FileManager.default.removeItem(at: repoSyncStaging) }
                let sync = makeCopier(source: old, destination: new)
                let first = try sync.run(progress: progress)
                try Self.requireClean(first, what: "copying the repo")
                // Another Mac may have written while the first pass ran.
                let second = try sync.run(progress: progress)
                try Self.requireClean(second, what: "copying the repo")
                progress(RepoCopyProgress(phase: "verify"))
                let problems = try sync.verify()
                guard problems.isEmpty else {
                    throw DisklesslyError.integrity("the new repo is incomplete; still using the old one: \(problems.prefix(5).joined(separator: "; "))")
                }
                var combined = first
                combined.copied += second.copied
                combined.bytesCopied += second.bytesCopied
                combined.skipped = second.skipped.filter { !first.copied.contains($0) }
                report.sync = combined
                report.migrated = true
            }
        }
        progress(RepoCopyProgress(phase: "switch"))
        var next = latest() ?? config
        // Activating an SMB/NFS/local endpoint moves `repoPath` to its mount, so `default`
        // would then name the new repo. The old folder is kept as its own backend first.
        var mirrorId = from
        if keepOldAsMirror, from == RuntimeConfig.defaultRepoId {
            let endpoint = Self.folderEndpoint(config.repoPath)
            if !next.backends.contains(where: { $0.id == endpoint.id }) { next.store(endpoint) }
            mirrorId = endpoint.id
        }
        try next.activate(id)
        if keepOldAsMirror, next.knowsRepo(mirrorId), mirrorId != next.activeRepoId, !next.mirrorBackendIds.contains(mirrorId) {
            next.mirrorBackendIds.append(mirrorId)
            report.keptAsMirror = mirrorId
        }
        var switched = self
        switched.config = next
        try switched.prepareRepo()
        try switched.saveConfig()
        self.config = next
        progress(RepoCopyProgress(phase: "done"))
        return report
    }

    /// A `local`/`icloud` backend for the folder at `path`, with an id derived from the path.
    static func folderEndpoint(_ path: String) -> BackendEndpoint {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let type = ICloudFolderBackend.looksLikeICloud(URL(fileURLWithPath: standardized)) ? "icloud" : "local"
        let id = "\(type)-\(SHA256Digest.hex(Data(standardized.utf8)).prefix(8))"
        return BackendEndpoint(id: id, type: type, root: standardized)
    }

    /// Both backends are the same local folder (a mount that `default` also points at).
    static func sameFolder(_ a: any StorageBackend, _ b: any StorageBackend) -> Bool {
        guard let left = a.localRoot(), let right = b.localRoot() else { return false }
        return left.resolvingSymlinksInPath().standardizedFileURL.path == right.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A copier staged in the cache dir that keeps `minFreeBytes` free and, for an iCloud
    /// source, evicts each placeholder again once its copy is on the destination.
    func makeCopier(source: any StorageBackend, destination: any StorageBackend) -> RepoCopier {
        var copier = RepoCopier(source: source, destination: destination, staging: repoSyncStaging)
        copier.freeSpaceMargin = config.minFreeBytes
        if let root = source.localRoot() {
            let evictor = placeholderEvictor
            copier.afterPlaceholderCopy = { path in evictor?(root.appendingPathComponent(path)) }
        }
        return copier
    }

    /// Hands a just-read iCloud file back to iCloud. Tests replace it with `placeholderEvictOverride`.
    var placeholderEvictor: ((URL) -> Void)? {
        if let placeholderEvictOverride { return placeholderEvictOverride }
        #if os(macOS)
        return { url in try? FileManager.default.evictUbiquitousItem(at: url) }
        #else
        return nil
        #endif
    }

    static func requireClean(_ report: RepoCopyReport, what: String) throws {
        guard !report.failed.isEmpty else { return }
        let sample = report.failed.sorted { $0.key < $1.key }.prefix(3).map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        throw DisklesslyError.backend("\(what) failed for \(report.failed.count) object(s); still using the old repo. Run it again to resume. \(sample)")
    }

    // MARK: - Mirrors

    public mutating func addMirror(_ id: String) throws {
        guard config.knowsRepo(id) else { throw DisklesslyError.usage("unknown backend: \(id)") }
        guard id != config.activeRepoId else { throw DisklesslyError.usage("\(id) is the active repo; a mirror must be another backend") }
        if let mirror = try? openRepo(id: id), let primary = try? openPrimaryBackend(), Self.sameFolder(mirror, primary) {
            throw DisklesslyError.usage("\(id) is the same folder as the active repo")
        }
        if !config.mirrorBackendIds.contains(id) { config.mirrorBackendIds.append(id) }
        try saveConfig()
    }

    public mutating func removeMirror(_ id: String) throws {
        guard config.mirrorBackendIds.contains(id) else { throw DisklesslyError.usage("\(id) is not a mirror") }
        config.mirrorBackendIds.removeAll { $0 == id }
        try saveConfig()
    }

    /// Copies the active repo onto every mirror. One mirror failing does not stop the
    /// others; each result is recorded in `mirrors.json`.
    @discardableResult
    public func syncMirrors(progress: (RepoCopyProgress) -> Void = { _ in }, now: () -> Date = Date.init) throws -> [String: MirrorSyncStatus] {
        let mirrors = config.mirrorBackendIds.filter { $0 != config.activeRepoId }
        guard !mirrors.isEmpty else { throw DisklesslyError.usage("no mirrors; add one with disklessly repo mirror add ID") }
        let primary = try openPrimaryBackend()
        var results: [String: MirrorSyncStatus] = [:]
        for id in mirrors {
            var status = MirrorSyncStatus(lastSyncAt: now(), ok: false, message: nil, copied: 0, skipped: 0, failed: 0, bytesCopied: 0)
            do {
                let mirror = try openRepo(id: id)
                try? FileManager.default.removeItem(at: repoSyncStaging)
                defer { try? FileManager.default.removeItem(at: repoSyncStaging) }
                if Self.sameFolder(primary, mirror) { throw DisklesslyError.usage("\(id) is the same folder as the active repo") }
                var sync = makeCopier(source: primary, destination: mirror)
                sync.pruneManifests = true
                let report = try sync.run { state in
                    var tagged = state
                    tagged.target = id
                    progress(tagged)
                }
                status.copied = report.copied.count
                status.skipped = report.skipped.count
                status.failed = report.failed.count
                status.bytesCopied = report.bytesCopied
                if report.failed.isEmpty {
                    let problems = try sync.verify()
                    status.ok = problems.isEmpty
                    if !problems.isEmpty { status.message = problems.prefix(3).joined(separator: "; ") }
                } else {
                    status.message = report.failed.sorted { $0.key < $1.key }.prefix(3).map { "\($0.key): \($0.value)" }.joined(separator: "; ")
                }
            } catch {
                status.message = (error as? DisklesslyError)?.errorDescription ?? String(describing: error)
            }
            status.lastSyncAt = now()
            results[id] = status
        }
        var stored = MirrorStatusStore.load(stateDir: config.stateDir)
        stored.merge(results) { $1 }
        try MirrorStatusStore.save(stored, stateDir: config.stateDir)
        return results
    }

    /// Mirrors with their last sync, for `/api/cloud` and `repo mirror list`.
    public func mirrorListing() -> [[String: Any]] {
        let statuses = MirrorStatusStore.load(stateDir: config.stateDir)
        return config.mirrorBackendIds.map { id in
            var row: [String: Any] = ["id": id]
            if id == RuntimeConfig.defaultRepoId {
                row["type"] = ICloudFolderBackend.looksLikeICloud(URL(fileURLWithPath: config.repoPath)) ? "icloud" : "local"
                row["url"] = config.repoPath
            } else if let endpoint = config.backends.first(where: { $0.id == id }) {
                row["type"] = endpoint.type
                row["url"] = endpoint.url ?? endpoint.remote ?? endpoint.mountPoint ?? endpoint.root
            } else {
                row["type"] = "missing"
                row["url"] = ""
            }
            if let status = statuses[id] { row["lastSync"] = status.dictionary }
            return row
        }
    }
}

/// Runs at most one background mirror sync at a time, so offloading several apps in a row
/// does not start a copy per app. A sync that is asked for while one runs runs once more after it.
public enum MirrorAutoSync {
    private static let lock = NSLock()
    private static var running = false
    private static var again = false

    /// After a write to the repo (pack, file offload): copy it onto the mirrors, off this thread.
    public static func kick(_ engine: DisklesslyEngine) {
        guard !engine.config.mirrorBackendIds.filter({ $0 != engine.config.activeRepoId }).isEmpty else { return }
        lock.lock()
        if running { again = true; lock.unlock(); return }
        running = true
        lock.unlock()
        Thread.detachNewThread {
            while true {
                _ = try? engine.syncMirrors()
                lock.lock()
                if again { again = false; lock.unlock(); continue }
                running = false
                lock.unlock()
                return
            }
        }
    }
}
