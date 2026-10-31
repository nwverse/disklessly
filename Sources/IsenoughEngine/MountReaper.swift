import Foundation
import IsenoughCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The disk-image and process facts that `detach` and the orphan reaper use.
/// Production uses `live`; tests inject fakes so no real image is attached.
public struct MountOps {
    /// Mount points of every attached disk image (`hdiutil info -plist`).
    public var listMounted: () -> [String]
    /// True when the path is a live mount point, not just a leftover folder.
    public var isMounted: (String) -> Bool
    /// Detaches the image mounted at the path. `force` is the tool's force form.
    public var detach: (String, Bool) throws -> Void
    /// Usage of the mounted bundle by processes other than isenough itself.
    public var usage: (String) -> UsageClass

    public init(listMounted: @escaping () -> [String], isMounted: @escaping (String) -> Bool, detach: @escaping (String, Bool) throws -> Void, usage: @escaping (String) -> UsageClass) {
        self.listMounted = listMounted
        self.isMounted = isMounted
        self.detach = detach
        self.usage = usage
    }

    public static var live: MountOps {
        MountOps(
            listMounted: {
                #if os(macOS)
                let info = ProcessRunner.capture(DiskImageTool.hdiutil, ["info", "-plist"])
                return MountReaper.mountPoints(hdiutilInfo: Data(info.utf8))
                #else
                return []
                #endif
            },
            isMounted: { IsenoughEngine.isActiveMountPoint($0) },
            detach: { path, force in
                #if os(macOS)
                try LiveDiskImage.detach(mountPoint: URL(fileURLWithPath: path), force: force)
                #else
                _ = (path, force)
                throw IsenoughError.unsupported("detach requires macOS hdiutil or diskutil")
                #endif
            },
            usage: { ProcessProbe.usage(roots: [$0]) }
        )
    }
}

/// A flock held by whichever isenough process owns a mount under the mount
/// root: the launch supervisor, `hook watch`, unpack, or icon backfill. The
/// kernel drops it when that process dies, so a free lease on a still-attached
/// image means its owner crashed. The reaper only try-locks it.
public struct MountLease {
    private var lock: FileLock

    public static func path(stateDir: String, name: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("locks/mount/\(name).lock")
    }

    /// Non-blocking. Nil means another process (or another lease in this
    /// process) holds it, or the lock file cannot be created.
    public static func tryAcquire(stateDir: String, name: String) -> MountLease? {
        let url = path(stateDir: stateDir, name: name)
        guard (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { return nil }
        var lock = FileLock(path: url.path)
        guard (try? lock.tryLock()) == true else { return nil }
        return MountLease(lock: lock)
    }

    /// Polls for up to `waitSeconds`. Owners use this: a reaper's check is short,
    /// and a launch handing off to its watcher returns at once. Nil after the
    /// wait means an older owner still holds it; that owner's lease then keeps
    /// covering the mount, so the caller carries on without one.
    public static func acquire(stateDir: String, name: String, waitSeconds: TimeInterval = 3) -> MountLease? {
        let deadline = Date().addingTimeInterval(waitSeconds)
        while true {
            if let lease = tryAcquire(stateDir: stateDir, name: name) { return lease }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    public mutating func release() { lock.unlock() }
}

public struct DetachReport: Equatable {
    public enum Outcome: String { case detached, notMounted = "not_mounted" }
    public var outcome: Outcome
    public var mountPoint: String
    public var forced: Bool
}

/// Why `evict` or `detach` refused. `reason` is the stable machine key the CLI
/// prints in `--json` errors; `error` carries the exit code and message.
public struct LifecycleRefusal {
    public var reason: String
    public var error: IsenoughError
}

public struct MountReapReport: Equatable {
    public struct Skip: Equatable {
        public var path: String
        public var reason: String
    }
    public var dryRun: Bool
    public var detached: [String] = []
    public var wouldDetach: [String] = []
    public var skipped: [Skip] = []
    public var failed: [Skip] = []

    /// Everything, including the mounts kept on purpose. For `isenough reap`.
    public var lines: [String] {
        detached.map { "reaped orphan mount \($0)" }
            + wouldDetach.map { "would reap orphan mount \($0)" }
            + skipped.map { "kept mount \($0.path): \($0.reason)" }
            + failed.map { "could not reap mount \($0.path): \($0.reason)" }
    }

    /// Only what changed or went wrong. Launch, gc and doctor print these, so a
    /// healthy mount owned by a running app does not look like a problem.
    public var actionLines: [String] {
        detached.map { "reaped orphan mount \($0)" }
            + wouldDetach.map { "would reap orphan mount \($0)" }
            + failed.map { "could not reap mount \($0.path): \($0.reason)" }
    }

    public func jsonObject() -> [String: Any] {
        ["ok": failed.isEmpty, "dryRun": dryRun, "detached": detached, "wouldDetach": wouldDetach,
         "skipped": skipped.map { ["path": $0.path, "reason": $0.reason] },
         "failed": failed.map { ["path": $0.path, "reason": $0.reason] }]
    }
}

public enum MountReaper {
    /// Mount paths whose reap failed, with when, in `state/reap-failures.json`.
    struct FailureMemo {
        var url: URL
        init(stateDir: String) { url = URL(fileURLWithPath: stateDir).appendingPathComponent("reap-failures.json") }

        func load(within seconds: TimeInterval, now: Date = Date()) -> [String: Date] {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
            var out: [String: Date] = [:]
            for (path, stamp) in raw where now.timeIntervalSince1970 - stamp < seconds { out[path] = Date(timeIntervalSince1970: stamp) }
            return out
        }

        func save(_ entries: [String: Date]) {
            if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
            let raw = entries.mapValues { $0.timeIntervalSince1970 }
            guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Mount points listed by `hdiutil info -plist` (`images[].system-entities[].mount-point`).
    public static func mountPoints(hdiutilInfo data: Data) -> [String] {
        var slice = data
        if let start = data.range(of: Data("<?xml".utf8)) { slice = data.subdata(in: start.lowerBound..<data.endIndex) }
        guard let root = try? PropertyListSerialization.propertyList(from: slice, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        var found: [String] = []
        for image in images {
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                if let mount = entity["mount-point"] as? String, !mount.isEmpty { found.append(mount) }
            }
        }
        return found
    }

    /// One spelling per location: symlinks resolved and `/private/var` folded to `/var`.
    public static func canonical(_ path: String) -> String {
        var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        for prefix in ["/private/var", "/private/tmp", "/private/etc"] where resolved == prefix || resolved.hasPrefix(prefix + "/") {
            resolved = String(resolved.dropFirst("/private".count))
        }
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    /// The entry name when `path` is a direct child of `mountRoot`, else nil.
    /// Anything else (the root itself, a nested path, another volume) is never ours.
    public static func childName(_ path: String, mountRoot: String) -> String? {
        guard !mountRoot.isEmpty else { return nil }
        let root = canonical(mountRoot)
        let candidate = canonical(path)
        guard root != "/", candidate.hasPrefix(root + "/") else { return nil }
        let name = String(candidate.dropFirst(root.count + 1))
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }
}

extension IsenoughEngine {
    var mountOps: MountOps { mountOpsOverride ?? .live }

    private func mountPath(_ manifest: ImageManifest) -> String {
        URL(fileURLWithPath: config.mountRoot).appendingPathComponent(manifest.imageId).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `evict` refuses a pinned app unless `force`, and always refuses an image
    /// that is mounted, in use, or held by an open restore (design §4, EX_BUSY).
    public func evictRefusal(_ manifest: ImageManifest, force: Bool) -> LifecycleRefusal? {
        if let reason = restore.blockReason(appId: manifest.bundleId) {
            return LifecycleRefusal(reason: "restore_open", error: .busy(reason))
        }
        if !force, StateStore(config.stateDir).load().apps[manifest.bundleId]?.pinned == true {
            return LifecycleRefusal(reason: "pinned", error: .busy("\(manifest.name) is pinned; unpin it first or pass --force"))
        }
        let path = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        if mountOps.isMounted(mountPath(manifest)) {
            return LifecycleRefusal(reason: "mounted", error: .busy("\(manifest.name) is mounted or in use; quit it and try again"))
        }
        if let item = scanCache(justUsed: nil, now: Date()).items.first(where: { $0.imageId == manifest.imageId }), item.mounted || item.inUse {
            return LifecycleRefusal(reason: "mounted", error: .busy("\(manifest.name) is mounted or in use; quit it and try again"))
        }
        return nil
    }

    /// `detach` refuses while any process still uses the mounted bundle, with or
    /// without `--force`, and refuses a recorded mount outside the mount root.
    public func detachRefusal(_ manifest: ImageManifest) -> LifecycleRefusal? {
        let ops = mountOps
        if let recorded = StateStore(config.stateDir).load().apps[manifest.bundleId]?.mountPoint,
           ops.isMounted(recorded), MountReaper.childName(recorded, mountRoot: config.mountRoot) == nil {
            return LifecycleRefusal(reason: "not_ours", error: .busy("\(manifest.name) is mounted at \(recorded), outside the isenough mount root; isenough will not detach it"))
        }
        let mount = mountPath(manifest)
        guard ops.isMounted(mount) else { return nil }
        if ops.usage(mount) != .clean {
            return LifecycleRefusal(reason: "app_running", error: .busy("\(manifest.name) is still running from its disk image; quit it first (--force does not detach a running app)"))
        }
        return nil
    }

    /// Detaches a mount-mode app's image now. A clean usage probe is required
    /// first; `force` only switches to the tool's forced detach.
    @discardableResult
    public func detach(_ manifest: ImageManifest, force: Bool = false) throws -> DetachReport {
        let ops = mountOps
        let mount = mountPath(manifest)
        let state = StateStore(config.stateDir)
        return try restore.withLock(manifest.bundleId) {
            if let refusal = detachRefusal(manifest) { throw refusal.error }
            guard ops.isMounted(mount) else {
                try markDetached(manifest.bundleId, mount: mount, state: state)
                return DetachReport(outcome: .notMounted, mountPoint: mount, forced: false)
            }
            do {
                try ops.detach(mount, force)
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                throw IsenoughError.diskImage("could not detach \(manifest.name)'s disk image at \(mount)\(force ? "" : "; something still has files open on it, retry later or pass --force"): \(detail)")
            }
            if ops.isMounted(mount) {
                throw IsenoughError.diskImage("\(manifest.name)'s disk image is still mounted at \(mount) after detach")
            }
            rmdir(mount)
            try markDetached(manifest.bundleId, mount: mount, state: state)
            return DetachReport(outcome: .detached, mountPoint: mount, forced: force)
        }
    }

    /// Mount-session states that only make sense while an image is attached.
    private static let mountedStates: Set<String> = ["running", "detaching", "backoff", "stuck", "idle"]

    private func markDetached(_ bundleId: String, mount: String, state: StateStore) throws {
        let wanted = MountReaper.canonical(mount)
        try state.update { local in
            guard var app = local.apps[bundleId] else { return }
            let recorded = app.mountPoint.map(MountReaper.canonical)
            guard recorded == nil || recorded == wanted else { return }
            if let name = app.state, Self.mountedStates.contains(name) { app.state = "cached" }
            app.mountPoint = nil
            local.apps[bundleId] = app
        }
    }

    /// Finds images attached under the mount root that no live isenough process
    /// owns (for example after a watcher crash) and detaches the idle ones.
    /// Never touches a volume outside the mount root, never forces, and skips a
    /// mount whose lease or app lock is held or whose bundle is in use.
    /// `deep` also asks `hdiutil info`; the fast form only scans the mount root.
    /// `retryAfter` skips a mount whose detach failed that recently (launch
    /// uses it so a wedged orphan is not retried on every stub launch).
    public func reapOrphanMounts(dryRun: Bool = false, deep: Bool = true, excluding: Set<String> = [], retryAfter: TimeInterval? = nil) -> MountReapReport {
        var report = MountReapReport(dryRun: dryRun)
        guard !config.mountRoot.isEmpty else { return report }
        // Resolved once: a symlinked root must not compare its children against
        // the link's own device (design §4: never detach outside the mount root).
        let root = MountReaper.canonical(config.mountRoot)
        guard root != "/" else { return report }
        let ops = mountOps
        var names: Set<String> = []
        var listedCache: Set<String>?
        func listed() -> Set<String> {
            if let listedCache { return listedCache }
            let found = Set(ops.listMounted().map(MountReaper.canonical))
            listedCache = found
            return found
        }
        if deep {
            for path in listed() {
                if let name = MountReaper.childName(path, mountRoot: root) { names.insert(name) }
            }
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
            for name in entries where ops.isMounted((root as NSString).appendingPathComponent(name)) { names.insert(name) }
        }
        let failures = MountReaper.FailureMemo(stateDir: config.stateDir)
        var recentFailures = failures.load(within: 24 * 3600)
        var failuresChanged = false
        defer { if failuresChanged { failures.save(recentFailures) } }
        let state = StateStore(config.stateDir)
        var journals: [RestoreJournal] = []
        var journalError: String?
        do { journals = try JournalStore.loadAll(stateDir: config.stateDir) }
        catch { journalError = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
        for name in names.sorted() where !excluding.contains(name) {
            let path = (root as NSString).appendingPathComponent(name)
            func skip(_ reason: String) { report.skipped.append(.init(path: path, reason: reason)) }
            guard ops.isMounted(path) else { continue }
            let canonical = MountReaper.canonical(path)
            // Only a disk image hdiutil lists at exactly this path is ours to
            // detach; `diskutil eject` on any other path ejects its whole volume.
            guard listed().contains(canonical) else { continue }
            if let journalError, name.hasPrefix("restore-") {
                // Fail closed: an unreadable journal may be the one that owns it.
                skip("restore journals could not be read (\(journalError)); run isenough doctor")
                continue
            }
            if let retryAfter, let at = recentFailures[canonical], Date().timeIntervalSince(at) < retryAfter {
                skip("detach failed recently; retrying later")
                continue
            }
            if journals.contains(where: { name == "restore-\($0.txid)" || $0.mountPath.map(MountReaper.canonical) == canonical }) {
                skip("an open restore journal owns it; run isenough doctor --fix")
                continue
            }
            guard var lease = MountLease.tryAcquire(stateDir: config.stateDir, name: name) else {
                skip("a running isenough process owns it")
                continue
            }
            defer { lease.release() }
            let owner = state.load().apps.first { $0.value.imageId == name || $0.value.mountPoint.map(MountReaper.canonical) == canonical }?.key
            var appLock: FileLock?
            if let owner {
                let lockURL = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/app/\(owner).lock")
                try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                var lock = FileLock(path: lockURL.path)
                guard (try? lock.tryLock()) == true else {
                    skip("\(owner) is launching or restoring")
                    continue
                }
                appLock = lock
            }
            defer { appLock?.unlock() }
            let usage = ops.usage(path)
            guard usage == .clean else {
                skip(usage == .busy ? "in use" : "usage is \(usage.rawValue)")
                continue
            }
            if dryRun {
                report.wouldDetach.append(path)
                continue
            }
            do {
                try ops.detach(path, false)
                guard !ops.isMounted(path) else {
                    report.failed.append(.init(path: path, reason: "still mounted after detach"))
                    recentFailures[canonical] = Date(); failuresChanged = true
                    continue
                }
                rmdir(path)
                if let owner { try? markDetached(owner, mount: path, state: state) }
                report.detached.append(path)
                if recentFailures.removeValue(forKey: canonical) != nil { failuresChanged = true }
            } catch {
                report.failed.append(.init(path: path, reason: (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
                recentFailures[canonical] = Date(); failuresChanged = true
            }
        }
        return report
    }
}
