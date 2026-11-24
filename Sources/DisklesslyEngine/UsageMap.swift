import Foundation
import DisklesslyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One box of the disk usage map. `key` names the fixed boxes the page translates
/// (`apps`, `bundle`, `cache`, ...); `name` is the literal label (an app or a folder).
public struct UsageNode: Equatable {
    public enum Kind: String {
        case root, apps, bundle, cache, data, offloaded, repo, personal, library, system, free, other
    }

    public var name: String
    public var key: String?
    public var kind: Kind
    public var bytes: UInt64
    public var children: [UsageNode]
    /// A cleanup the page can offer on this box (`UsageCleanup` id).
    public var action: String?
    /// The folder on disk this box measures, when it is exactly one folder.
    public var path: String?
    /// Why the page must not offer Offload or Delete on `path`; nil when it may.
    public var refusal: String?
    /// Why the page must not offer Delete on `path`; defaults to `refusal` when not separately evaluated.
    public var trashRefusal: String?
    /// True when this app node represents an already-offloaded stub launcher on disk.
    public var offloaded: Bool = false
    /// Newest modification time under this box. A folder sized by `du` carries its own mtime
    /// (which changes when entries are added or removed directly in it), not the newest file deep inside.
    public var modified: Date?
    /// How many offloaded items came from this box's path or below it (cloud badge on the local map).
    public var offloadedCount = 0
    /// Set on the boxes of the cloud side (`CloudUsage`): what the repo holds and how it comes back.
    public var cloud: CloudInfo?
    /// A `HiddenUsage` action offered on a child of "Not measured" (thin snapshots, measure or rebuild
    /// Spotlight). Kept apart from `action` so no cleanup list or bulk path ever runs it.
    public var reconcile: String?
    /// On the "Not measured" box: the facts its children were computed from (`disklessly reconcile`).
    public var hidden: HiddenUsageFacts?

    /// One offloaded item as the cloud side shows it. `bytes` of the node is the size it had on disk.
    public struct CloudInfo: Equatable {
        public var id: String
        public var storedBytes: UInt64?
        /// Where it was on this Mac (the box it links to on the local side).
        public var originPath: String?
        /// The stub app or `.disklessly` placeholder left on this Mac.
        public var stubPath: String?
        /// What of it is on this Mac now (a prefetched image is in both places).
        public var localBytes: UInt64 = 0
        public var offloadedAt: Date?
        public var lastUsed: Date?
        /// How it comes back: `unpack`, `fetch`, `data/disable`, `links/restore`, `sessions/restore`.
        public var restore: String?
        /// What the restore takes as its `app` or `id` (app name, linked bundle id, session id, placeholder path).
        public var restoreId: String?
        /// Another device that holds it too ("Also on ...").
        public var otherDevice: String?
        public init(id: String) { self.id = id }
    }

    public init(name: String, key: String? = nil, kind: Kind, bytes: UInt64 = 0, children: [UsageNode] = [], action: String? = nil) {
        self.name = name
        self.key = key
        self.kind = kind
        self.bytes = bytes
        self.children = children
        self.action = action
    }

    /// A box that is the sum of its children.
    static func group(name: String, key: String? = nil, kind: Kind, _ children: [UsageNode]) -> UsageNode {
        var node = UsageNode(name: name, key: key, kind: kind, bytes: children.reduce(0) { $0 + $1.bytes }, children: children)
        node.modified = children.compactMap(\.modified).max()
        node.offloadedCount = children.reduce(0) { $0 + $1.offloadedCount }
        return node
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["name": name, "kind": kind.rawValue, "bytes": NSNumber(value: bytes)]
        if let key { object["key"] = key }
        if let action { object["action"] = action }
        if let reconcile { object["reconcile"] = reconcile }
        if let hidden { object["hidden"] = hidden.jsonObject() }
        if offloaded { object["offloaded"] = true }
        if let modified { object["modified"] = NSNumber(value: Int64(modified.timeIntervalSince1970)) }
        if offloadedCount > 0 { object["offloadedCount"] = NSNumber(value: offloadedCount) }
        if let cloud {
            object["id"] = cloud.id
            if let stored = cloud.storedBytes { object["storedBytes"] = NSNumber(value: stored) }
            if let origin = cloud.originPath { object["originPath"] = origin }
            if let stub = cloud.stubPath { object["stubPath"] = stub }
            if cloud.localBytes > 0 { object["localBytes"] = NSNumber(value: cloud.localBytes) }
            if let at = cloud.offloadedAt { object["offloadedAt"] = NSNumber(value: Int64(at.timeIntervalSince1970)) }
            if let used = cloud.lastUsed { object["lastUsed"] = NSNumber(value: Int64(used.timeIntervalSince1970)) }
            if let restore = cloud.restore { object["restore"] = restore }
            if let restoreId = cloud.restoreId { object["restoreId"] = restoreId }
            if let other = cloud.otherDevice { object["otherDevice"] = other }
        }
        if let path {
            object["path"] = path
            if let refusal { object["refusal"] = refusal }
            object["canTrash"] = (trashRefusal == nil)
        }
        if !children.isEmpty { object["children"] = children.map { $0.jsonObject() } }
        return object
    }
}

/// What the scan measured. Everything is allocated bytes. Tests build this by hand.
public struct UsageInputs {
    public struct App {
        public var name: String
        public var bundleBytes: UInt64
        public var cacheBytes: UInt64
        public var dataBytes: UInt64
        public var path: String?
        public var offloaded: Bool
        public var cachePath: String?
        public var dataPath: String?
        /// The bundle's modification time (install or update; macOS has no cheap last-launch date here).
        public var modified: Date?
        public init(name: String, bundleBytes: UInt64, cacheBytes: UInt64 = 0, dataBytes: UInt64 = 0, path: String? = nil, offloaded: Bool = false, cachePath: String? = nil, dataPath: String? = nil) {
            self.name = name; self.bundleBytes = bundleBytes; self.cacheBytes = cacheBytes; self.dataBytes = dataBytes; self.path = path
            self.offloaded = offloaded; self.cachePath = cachePath; self.dataPath = dataPath
        }
    }
    public struct Offloaded {
        public var name: String
        /// The image downloaded to this Mac.
        public var cachedBytes: UInt64
        public init(name: String, cachedBytes: UInt64) { self.name = name; self.cachedBytes = cachedBytes }
    }
    public struct Entry: Equatable {
        public var name: String
        public var bytes: UInt64
        public var kind: UsageNode.Kind
        /// What is inside, when the scan looked (one level).
        public var children: [Entry] = []
        public var key: String?
        public var action: String?
        /// The folder on disk, when the entry is exactly one folder.
        public var path: String?
        /// Its modification time (the folder's own mtime when `du` measured it).
        public var modified: Date?
        public init(name: String, bytes: UInt64, kind: UsageNode.Kind = .other, children: [Entry] = [], key: String? = nil, action: String? = nil) {
            self.name = name; self.bytes = bytes; self.kind = kind; self.children = children; self.key = key; self.action = action
        }
    }

    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var apps: [App] = []
    public var offloaded: [Offloaded] = []
    /// The repo folder when it sits on this Mac, and Disklessly's own cache and state besides the images.
    public var repoBytes: UInt64 = 0
    public var otherDisklesslyBytes: UInt64 = 0
    public var personal: [Entry] = []
    public var library: [Entry] = []
    /// The page's label for the `library` box: `library` (~/Library) on macOS,
    /// `appdata` (the dot folders under ~) on Linux.
    public var libraryKey = "library"
    /// Measured parts of what used to be one "System & other" box: macOS volumes, /Library,
    /// Homebrew, /private/var. The rest stays as "not measured".
    public var system: [Entry] = []
    /// What explains "not measured" (snapshots, other users, Spotlight); nil keeps it one box.
    public var hidden: HiddenUsageFacts?

    public init(totalBytes: UInt64, freeBytes: UInt64) { self.totalBytes = totalBytes; self.freeBytes = freeBytes }
}

public enum UsageMap {
    /// Boxes beyond this many in one list are merged into "other".
    public static let maxListed = 14

    /// Builds the tree. Whatever the measured boxes do not add up to is "System & other",
    /// so the root always equals the disk and the free box.
    public static func assemble(_ input: UsageInputs) -> UsageNode {
        let appNodes: [UsageNode] = input.apps.map { app in
            var bundle = UsageNode(name: app.name, key: "bundle", kind: .bundle, bytes: app.bundleBytes)
            bundle.path = app.path
            bundle.offloaded = app.offloaded
            bundle.modified = app.modified
            var parts: [UsageNode] = [bundle]
            if app.cacheBytes > 0 {
                var cacheNode = UsageNode(name: app.name, key: "cache", kind: .cache, bytes: app.cacheBytes)
                cacheNode.path = app.cachePath
                parts.append(cacheNode)
            }
            if app.dataBytes > 0 {
                var dataNode = UsageNode(name: app.name, key: "data", kind: .data, bytes: app.dataBytes)
                dataNode.path = app.dataPath
                parts.append(dataNode)
            }
            var group = UsageNode.group(name: app.name, kind: .apps, parts)
            group.path = app.path
            group.offloaded = app.offloaded
            return group
        }
        let apps = UsageNode.group(name: "Apps", key: "apps", kind: .apps, merged(appNodes, kind: .apps))

        var offloadedNodes: [UsageNode] = input.offloaded.filter { $0.cachedBytes > 0 }.map {
            UsageNode(name: $0.name, key: "cache", kind: .cache, bytes: $0.cachedBytes)
        }
        offloadedNodes = merged(offloadedNodes, kind: .cache)
        if input.repoBytes > 0 { offloadedNodes.append(UsageNode(name: "Repo", key: "repo", kind: .repo, bytes: input.repoBytes)) }
        if input.otherDisklesslyBytes > 0 { offloadedNodes.append(UsageNode(name: "State", key: "state", kind: .other, bytes: input.otherDisklesslyBytes)) }
        let disklessly = UsageNode.group(name: "Disklessly", key: "disklessly", kind: .offloaded, offloadedNodes)

        let personal = UsageNode.group(name: "Personal files", key: "personal", kind: .personal, merged(input.personal.map { entry in
            var node = UsageNode(name: entry.name, kind: entry.kind == .other ? .personal : entry.kind, bytes: entry.bytes)
            node.path = entry.path
            node.modified = entry.modified
            return node
        }, kind: .personal))
        let library = UsageNode.group(name: input.libraryKey == "library" ? "Library" : "App data", key: input.libraryKey, kind: .library, merged(input.library.map(libraryNode), kind: .library))

        var top = [apps, disklessly, personal, library].filter { $0.bytes > 0 }
        let used = input.totalBytes > input.freeBytes ? input.totalBytes - input.freeBytes : 0
        let measured = top.reduce(0) { $0 + $1.bytes }
        let leftover = used > measured ? used - measured : 0
        if input.system.isEmpty {
            top.append(UsageNode(name: "System & other", key: "system", kind: .system, bytes: leftover))
        } else {
            var parts = input.system.map { entryNode($0, kind: .system) }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            let partsBytes = parts.reduce(0) { $0 + $1.bytes }
            // Snapshots, purgeable space, other users, the Spotlight index and folders the scan could not read.
            if leftover > partsBytes {
                let gap = leftover - partsBytes
                if var hidden = input.hidden {
                    hidden.usedBytes = used
                    hidden.gapBytes = gap
                    var unmeasured = UsageNode.group(name: "Not measured", key: "unmeasured", kind: .system, HiddenUsage.breakdown(gap: gap, facts: hidden).map(HiddenUsage.node))
                    unmeasured.hidden = hidden
                    parts.append(unmeasured)
                } else {
                    parts.append(UsageNode(name: "Not measured", key: "unmeasured", kind: .system, bytes: gap))
                }
            }
            top.append(UsageNode.group(name: "System & other", key: "system", kind: .system, parts))
        }
        top.append(UsageNode(name: "Free", key: "free", kind: .free, bytes: min(input.freeBytes, input.totalBytes)))
        // If the boxes add up to more than the disk (clones, snapshots), the root grows to fit.
        return UsageNode.group(name: "Disk", key: "disk", kind: .root, top)
    }

    private static func libraryNode(_ entry: UsageInputs.Entry) -> UsageNode {
        entryNode(entry, kind: entry.kind == .other ? .library : entry.kind)
    }

    private static func entryNode(_ entry: UsageInputs.Entry, kind: UsageNode.Kind) -> UsageNode {
        guard !entry.children.isEmpty else {
            var leaf = UsageNode(name: entry.name, key: entry.key, kind: kind, bytes: entry.bytes, action: entry.action)
            leaf.path = entry.path
            leaf.modified = entry.modified
            return leaf
        }
        let inside = merged(entry.children.map { entryNode($0, kind: kind) }, kind: kind)
        // The folder's own size stays: files directly in it show up as the difference.
        let loose = entry.bytes > inside.reduce(0, { $0 + $1.bytes }) ? entry.bytes - inside.reduce(0, { $0 + $1.bytes }) : 0
        let parts = loose > 0 ? inside + [UsageNode(name: "files", key: "files", kind: kind, bytes: loose)] : inside
        var node = UsageNode.group(name: entry.name, key: entry.key, kind: kind, parts)
        node.action = entry.action
        node.path = entry.path
        if let own = entry.modified { node.modified = max(own, node.modified ?? own) }
        return node
    }

    /// Fills `refusal` on every box with a path, so the page knows where Offload and Delete are allowed.
    static func annotate(_ node: UsageNode, refusal: (String) -> String?) -> UsageNode {
        annotate(node, refusal: refusal, trashRefusal: refusal)
    }

    static func annotate(_ node: UsageNode, refusal: (String) -> String?, trashRefusal: (String) -> String?) -> UsageNode {
        var out = node
        if let path = node.path {
            out.refusal = refusal(path)
            out.trashRefusal = trashRefusal(path)
        }
        out.children = node.children.map { annotate($0, refusal: refusal, trashRefusal: trashRefusal) }
        return out
    }

    /// Fills `offloadedCount` from the places offloaded items came from: a box counts every origin at
    /// its path or below it; a group box without a path sums its children.
    public static func countOffloaded(_ node: UsageNode, originPaths: [String]) -> UsageNode {
        let origins = originPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard !origins.isEmpty else { return node }
        func walk(_ node: UsageNode) -> UsageNode {
            var out = node
            out.children = node.children.map(walk)
            if let path = node.path {
                let prefix = path.hasSuffix("/") ? path : path + "/"
                out.offloadedCount = origins.filter { $0 == path || $0.hasPrefix(prefix) }.count
            } else {
                out.offloadedCount = out.children.reduce(0) { $0 + $1.offloadedCount }
            }
            return out
        }
        return walk(node)
    }

    /// Largest first; the tail past `maxListed` becomes one "Other" box.
    static func merged(_ nodes: [UsageNode], kind: UsageNode.Kind) -> [UsageNode] {
        let sorted = nodes.filter { $0.bytes > 0 }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        guard sorted.count > maxListed else { return sorted }
        let head = Array(sorted.prefix(maxListed))
        let tail = sorted.dropFirst(maxListed)
        var rest = UsageNode(name: "\(tail.count)", key: "rest", kind: .other, bytes: tail.reduce(0) { $0 + $1.bytes })
        rest.modified = tail.compactMap(\.modified).max()
        rest.offloadedCount = tail.reduce(0) { $0 + $1.offloadedCount }
        return head + [rest]
    }

    /// Scans one directory's direct children on demand for treemap drill-down.
    public static func scanDirectory(_ path: String, kind: UsageNode.Kind = .personal, refusal: (String) -> String?) -> [UsageNode] {
        scanDirectoryDetailed(path, kind: kind, refusal: refusal).children
    }

    /// Scans one directory's direct children in parallel for treemap drill-down, reporting whether a timeout left it partial.
    public static func scanDirectoryDetailed(_ path: String, kind: UsageNode.Kind = .personal, timeout: TimeInterval = 20, refusal: (String) -> String?, trashRefusal: ((String) -> String?)? = nil) -> (children: [UsageNode], partial: Bool) {
        let dir = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return ([], false)
        }
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        let collector = LockedDirScan()
        var subdirs: [(name: String, path: String, modified: Date)] = []
        for name in entries where !name.isEmpty {
            let entryPath = prefix + name
            var info = stat()
            guard lstat(entryPath, &info) == 0 else { continue }
            let fileKind = info.st_mode & S_IFMT
            let modified = mtime(info)
            if fileKind == S_IFDIR {
                // du sizes the folder; its age is the folder's own mtime (no second walk).
                subdirs.append((name, entryPath, modified))
            } else if fileKind == S_IFREG || fileKind == S_IFLNK {
                let bytes = UInt64(max(0, info.st_blocks)) * 512
                if bytes > 0 {
                    var node = UsageNode(name: name, kind: kind, bytes: bytes)
                    node.path = entryPath
                    node.modified = modified
                    collector.append(node)
                }
            }
        }
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 8)
        let deadline = Date().addingTimeInterval(timeout)
        for sub in subdirs {
            if deadline.timeIntervalSinceNow <= 0.1 {
                collector.markPartial()
                break
            }
            sem.wait()
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0.1 {
                sem.signal()
                collector.markPartial()
                break
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { sem.signal(); group.leave() }
                let (bytes, complete) = UsageScan.singleSize(of: sub.path, timeout: remaining)
                if !complete { collector.markPartial() }
                if bytes > 0 {
                    var node = UsageNode(name: sub.name, kind: kind, bytes: bytes)
                    node.path = sub.path
                    node.modified = sub.modified
                    collector.append(node)
                }
            }
        }
        group.wait()
        let (nodes, partial) = collector.snapshot()
        let grouped = UsageNode.group(name: URL(fileURLWithPath: dir).lastPathComponent, kind: kind, merged(nodes, kind: kind))
        if let trashRefusal {
            return (annotate(grouped, refusal: refusal, trashRefusal: trashRefusal).children, partial)
        }
        return (annotate(grouped, refusal: refusal).children, partial)
    }

    static func mtime(_ info: stat) -> Date {
        #if canImport(Darwin)
        let spec = info.st_mtimespec
        #else
        let spec = info.st_mtim
        #endif
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9)
    }

    /// The modification time of `path` itself (lstat), or nil when it is gone.
    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return mtime(info)
    }

    private final class LockedDirScan: @unchecked Sendable {
        private let lock = NSLock()
        private var nodes: [UsageNode] = []
        private var partial = false
        func append(_ node: UsageNode) { lock.lock(); nodes.append(node); lock.unlock() }
        func markPartial() { lock.lock(); partial = true; lock.unlock() }
        func snapshot() -> ([UsageNode], Bool) { lock.lock(); defer { lock.unlock() }; return (nodes, partial) }
    }
}

// MARK: - Measuring

public enum UsageScan {
    /// `du -k -x -d 1`: allocated kilobytes for each direct child of `path`, plus the folder itself under its own path.
    /// A timeout keeps what finished, because du prints a child as soon as its subtree is done.
    /// `-x` stays on this volume: CoreDevice mounts a running simulator's whole
    /// system at ~/Library/Developer/CoreDevice/DeviceFS, and mounted images
    /// would otherwise count again on top of where they really live.
    static func sizes(of path: String, timeout: TimeInterval, denied: ((String) -> Void)? = nil) -> (sizes: [String: UInt64], complete: Bool) {
        let (raw, complete) = runDU(arguments: ["-x", "-k", "-d", "1", path], timeout: timeout, denied: denied)
        var result: [String: UInt64] = [:]
        for line in raw.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = UInt64(line[line.startIndex..<tab]) else { continue }
            result[String(line[line.index(after: tab)...])] = kb * 1024
        }
        return (result, complete)
    }

    static func singleSize(of path: String, timeout: TimeInterval) -> (bytes: UInt64, complete: Bool) {
        let (raw, complete) = runDU(arguments: ["-x", "-k", "-s", path], timeout: timeout)
        for line in raw.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = UInt64(line[line.startIndex..<tab]) else { continue }
            return (kb * 1024, complete)
        }
        return (0, complete)
    }

    /// `denied` receives each folder du could not read (permission denied / Full Disk Access).
    private static func runDU(arguments: [String], timeout: TimeInterval, denied: ((String) -> Void)? = nil) -> (output: String, complete: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        let errors = denied == nil ? nil : Pipe()
        process.standardError = errors ?? FileHandle.nullDevice
        do { try process.run() } catch { return ("", false) }
        let output = LockedData()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            reader.leave()
        }
        if let errors, let denied {
            reader.enter()
            DispatchQueue.global().async {
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                for path in HiddenUsage.parseDenied(text) { denied(path) }
                reader.leave()
            }
        }
        var complete = true
        let deadline = DispatchTime.now() + timeout
        if reader.wait(timeout: deadline) == .timedOut {
            complete = false
            process.terminate()
            _ = reader.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        return (String(decoding: output.get(), as: UTF8.self), complete)
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Measures this machine and builds the tree. Slow on a big disk: callers run it off the request thread.
    /// `runner` carries every system tool the "Not measured" breakdown asks (`tmutil`, `du` of other users).
    public static func run(engine: DisklesslyEngine, timeout: TimeInterval = 240, runner: SystemCommandRunner = LiveSystemCommandRunner.shared, progress: (String) -> Void = { _ in }) -> (tree: UsageNode, partial: Bool) {
        HostPlatform.current == .linux ? runLinux(engine: engine, timeout: timeout, progress: progress) : runMac(engine: engine, timeout: timeout, runner: runner, progress: progress)
    }

    static func runMac(engine: DisklesslyEngine, timeout: TimeInterval, runner: SystemCommandRunner, progress: (String) -> Void) -> (tree: UsageNode, partial: Bool) {
        let home = NSHomeDirectory()
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        var input = UsageInputs(
            totalBytes: UInt64(volume?.volumeTotalCapacity ?? 0),
            freeBytes: UInt64(volume?.volumeAvailableCapacity ?? 0)
        )
        let library = home + "/Library"
        let jobs: [(String, String)] = [
            ("apps", "/Applications"), ("userApps", home + "/Applications"), ("home", home), ("library", library),
            ("caches", library + "/Caches"), ("support", library + "/Application Support"), ("containers", library + "/Containers"), ("developer", library + "/Developer"),
            ("cacheDir", engine.config.cacheDir), ("repo", engine.config.repoPath),
            // Parts of "System & other".
            ("sysLibrary", "/Library"), ("simRuntimes", KnownLocations.simulatorRuntimes), ("homebrew", KnownLocations.homebrewPrefixes[0]),
            ("usrLocal", KnownLocations.homebrewPrefixes[1]), ("var", "/private/var"),
            ("userDeveloper", library + "/Developer"), ("derivedData", home + "/" + KnownLocations.derivedData),
        ]
        progress("scan")
        let results = LockedResults()
        let denied = LockedPaths()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let (name, path) = jobs[index]
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            results.set(name, path: path, sizes(of: path, timeout: timeout, denied: denied.add))
        }
        progress("reconcile")
        let hidden = HiddenUsage.gather(runner: runner, home: home, stateDir: engine.config.stateDir, unreadable: denied.all)
        progress("assemble")
        let partial = results.anyIncomplete

        func children(_ name: String) -> [(String, UInt64)] {
            guard let hit = results.get(name) else { return [] }
            return hit.sizes.compactMap { key, value in
                key == hit.path ? nil : (URL(fileURLWithPath: key).lastPathComponent, value)
            }
        }
        func total(_ name: String) -> UInt64 {
            guard let hit = results.get(name) else { return 0 }
            return hit.sizes[hit.path] ?? 0
        }
        let caches = Dictionary(children("caches"), uniquingKeysWith: max)
        let support = Dictionary(children("support"), uniquingKeysWith: max)
        let containers = Dictionary(children("containers"), uniquingKeysWith: max)
        var usedCache: Set<String> = [], usedSupport: Set<String> = [], usedContainers: Set<String> = []

        for (root, entries) in [("/Applications", children("apps")), (home + "/Applications", children("userApps"))] {
            for (name, bytes) in entries where name.hasSuffix(".app") {
                let appPath = root + "/" + name
                let display = String(name.dropLast(4))
                let bundleId = Bundle(path: appPath)?.bundleIdentifier
                let stubFile = appPath + "/Contents/Resources/stub.json"
                var isOffloaded = false
                var stubBundleId: String?
                if let stubData = FileManager.default.contents(atPath: stubFile) {
                    isOffloaded = true
                    if let stubObj = (try? JSONSerialization.jsonObject(with: stubData)) as? [String: Any] {
                        stubBundleId = stubObj["appId"] as? String
                    }
                }
                var cache: UInt64 = 0, data: UInt64 = 0
                var bestCachePath: String?
                var bestCacheBytes: UInt64 = 0
                var bestDataPath: String?
                var bestDataBytes: UInt64 = 0
                for key in [stubBundleId, bundleId, display].compactMap({ $0 }) {
                    if let v = caches[key], !usedCache.contains(key) {
                        cache += v
                        usedCache.insert(key)
                        if v > bestCacheBytes { bestCacheBytes = v; bestCachePath = library + "/Caches/" + key }
                    }
                    if let v = support[key], !usedSupport.contains(key) {
                        data += v
                        usedSupport.insert(key)
                        if v > bestDataBytes { bestDataBytes = v; bestDataPath = library + "/Application Support/" + key }
                    }
                    if let v = containers[key], !usedContainers.contains(key) {
                        data += v
                        usedContainers.insert(key)
                        if v > bestDataBytes { bestDataBytes = v; bestDataPath = library + "/Containers/" + key }
                    }
                }
                input.apps.append(.init(
                    name: display,
                    bundleBytes: bytes,
                    cacheBytes: cache,
                    dataBytes: data,
                    path: appPath,
                    offloaded: isOffloaded,
                    cachePath: bestCachePath,
                    dataPath: bestDataPath
                ))
                input.apps[input.apps.count - 1].modified = UsageMap.modified(appPath)
            }
        }

        // Offloaded apps: the image cached on this Mac.
        let images = URL(fileURLWithPath: engine.config.cacheDir).appendingPathComponent("images")
        for manifest in (try? engine.list()) ?? [] {
            let file = images.appendingPathComponent("\(manifest.imageId).dmg")
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            if size > 0 { input.offloaded.append(.init(name: manifest.name, cachedBytes: size)) }
        }
        let imageBytes = input.offloaded.reduce(0) { $0 + $1.cachedBytes }
        let cacheDirTotal = total("cacheDir")
        input.otherDisklesslyBytes = cacheDirTotal > imageBytes ? cacheDirTotal - imageBytes : 0
        // The repo counts once: as "Repo", and not again where it sits under the home folder.
        let repoTotal = total("repo")
        input.repoBytes = repoTotal
        let repo = engine.config.repoPath

        var homeEntries = Dictionary(children("home"), uniquingKeysWith: max)
        var libraryEntries = Dictionary(children("library"), uniquingKeysWith: max)
        if repoTotal > 0, repo.hasPrefix(home + "/") {
            let rest = repo.dropFirst(home.count + 1).split(separator: "/").map(String.init)
            if rest.first == "Library", rest.count > 1 { libraryEntries[rest[1]] = (libraryEntries[rest[1]] ?? 0) &- min(repoTotal, libraryEntries[rest[1]] ?? 0) }
            else if let first = rest.first { homeEntries[first] = (homeEntries[first] ?? 0) &- min(repoTotal, homeEntries[first] ?? 0) }
        }
        homeEntries.removeValue(forKey: "Library")
        homeEntries.removeValue(forKey: "Applications")
        input.personal = homeEntries.map { item in
            var entry = UsageInputs.Entry(name: item.key, bytes: item.value, kind: .personal)
            entry.path = home + "/" + item.key
            entry.modified = UsageMap.modified(home + "/" + item.key)
            return entry
        }

        // Caches, Application Support and Containers keep only what no app claimed.
        func leftover(_ all: [String: UInt64], used: Set<String>) -> UInt64 {
            all.filter { !used.contains($0.key) }.values.reduce(0, +)
        }
        let cachesRest = leftover(caches, used: usedCache), supportRest = leftover(support, used: usedSupport), containersRest = leftover(containers, used: usedContainers)
        var entries = libraryEntries
        for (name, rest) in [("Caches", cachesRest), ("Application Support", supportRest), ("Containers", containersRest)] where entries[name] != nil {
            entries[name] = rest
        }
        func unclaimed(_ all: [String: UInt64], used: Set<String>) -> [UsageInputs.Entry] {
            all.filter { !used.contains($0.key) }.map { .init(name: $0.key, bytes: $0.value, kind: .other) }
        }
        let inside: [String: [UsageInputs.Entry]] = [
            "Caches": unclaimed(caches, used: usedCache),
            "Application Support": unclaimed(support, used: usedSupport),
            "Containers": unclaimed(containers, used: usedContainers),
            "Developer": children("developer").map { .init(name: $0.0, bytes: $0.1, kind: .other) },
        ]
        input.library = entries.map { .init(name: $0.key, bytes: $0.value, kind: $0.key == "Caches" ? .cache : .library, children: inside[$0.key] ?? []) }
        // ~/Library/Developer: simulator devices and Xcode's DerivedData get their own boxes and cleanups.
        if let index = input.library.firstIndex(where: { $0.name == "Developer" }) {
            let derived = total("derivedData")
            input.library[index].children = children("userDeveloper").map { name, bytes in
                switch name {
                case KnownLocations.developerFolder(of: KnownLocations.simulatorDevices): return .init(name: "Simulator devices", bytes: bytes, key: "simdevices", action: UsageCleanup.simulatorDevices)
                case KnownLocations.developerFolder(of: KnownLocations.derivedData) where derived > 0:
                    return .init(name: name, bytes: bytes, children: [
                        .init(name: "DerivedData", bytes: derived, key: "deriveddata", action: UsageCleanup.derivedData),
                        .init(name: "other", bytes: bytes > derived ? bytes - derived : 0),
                    ])
                default: return .init(name: name, bytes: bytes)
                }
            }
        }
        // Each library box and the folders listed inside it are real folders; synthetic boxes
        // (keyed ones such as simulator devices, "other") get no path.
        for index in input.library.indices {
            let folder = library + "/" + input.library[index].name
            input.library[index].path = folder
            input.library[index].modified = UsageMap.modified(folder)
            for child in input.library[index].children.indices where input.library[index].children[child].key == nil && input.library[index].children[child].name != "other" {
                let childPath = folder + "/" + input.library[index].children[child].name
                input.library[index].children[child].path = childPath
                input.library[index].children[child].modified = UsageMap.modified(childPath)
            }
        }
        input.system = systemParts(children: children, total: total)
        input.hidden = hidden
        return (UsageMap.annotate(UsageMap.assemble(input), refusal: engine.fileOffloadRefusal, trashRefusal: engine.trashPathRefusal), partial)
    }

    // MARK: Linux

    /// What a Linux scan measured, by name: the direct children of each root (`du -d 1`).
    public struct LinuxMeasurements {
        public var home: [String: UInt64] = [:]
        /// `~/.cache`, `~/.local/share`, `~/.config`, `~/.var/app` (Flatpak data), `~/snap` (Snap data).
        public var cache: [String: UInt64] = [:]
        public var share: [String: UInt64] = [:]
        public var config: [String: UInt64] = [:]
        public var varApp: [String: UInt64] = [:]
        public var snapHome: [String: UInt64] = [:]
        /// Installed software: `/opt/<name>`, Flatpak apps by id, Snap packages by name.
        public var opt: [String: UInt64] = [:]
        public var flatpakSystem: [String: UInt64] = [:]
        public var flatpakUser: [String: UInt64] = [:]
        public var snaps: [String: UInt64] = [:]
        /// Bytes to take off a top-level home entry because another box already counts them (the repo).
        public var homeClaimed: [String: UInt64] = [:]
        public init() {}
    }

    static func minus(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }

    /// The dot folders that the `appdata` box shows instead of `personal`.
    static let linuxDataFolders = [".cache", ".local", ".config", ".var", "snap"]

    /// Linux apps and app data. Each app claims its own cache and data folders by name;
    /// what no app claims stays under its dot folder. `disklessly` folders are left to
    /// the Disklessly box. Pure, so tests feed it a table.
    public static func linuxInputs(_ m: LinuxMeasurements, into input: inout UsageInputs) {
        var cache = m.cache, share = m.share, config = m.config, varApp = m.varApp, snapHome = m.snapHome
        // User Flatpak apps sit inside ~/.local/share/flatpak; they count as apps, not as data.
        let userFlatpak = m.flatpakUser.values.reduce(0, +)
        if let flatpak = share["flatpak"] { share["flatpak"] = minus(flatpak, userFlatpak) }
        var claimed: [String: UInt64] = [".local": userFlatpak]
        func take(_ dict: inout [String: UInt64], _ keys: [String], folder: String) -> UInt64 {
            var bytes: UInt64 = 0
            for key in Set(keys) { if let v = dict.removeValue(forKey: key) { bytes += v } }
            claimed[folder, default: 0] += bytes
            return bytes
        }
        _ = take(&cache, ["disklessly"], folder: ".cache")
        _ = take(&share, ["disklessly"], folder: ".local")

        for (id, bytes) in m.flatpakSystem {
            input.apps.append(.init(name: id, bundleBytes: bytes, dataBytes: take(&varApp, [id], folder: ".var")))
        }
        for (id, bytes) in m.flatpakUser {
            let name = m.flatpakSystem[id] == nil ? id : "\(id) (user)"
            input.apps.append(.init(name: name, bundleBytes: bytes, dataBytes: take(&varApp, [id], folder: ".var")))
        }
        for (name, bytes) in m.snaps {
            input.apps.append(.init(name: name, bundleBytes: bytes, dataBytes: take(&snapHome, [name], folder: "snap")))
        }
        for (name, bytes) in m.opt {
            let keys = [name, name.lowercased()]
            let cacheBytes = take(&cache, keys, folder: ".cache")
            let data = take(&share, keys, folder: ".local") + take(&config, keys, folder: ".config")
            input.apps.append(.init(name: name, bundleBytes: bytes, cacheBytes: cacheBytes, dataBytes: data))
        }

        var home = m.home
        for (name, bytes) in m.homeClaimed { if let v = home[name] { home[name] = minus(v, bytes) } }
        let inside: [String: [String: UInt64]] = [".cache": cache, ".local": share, ".config": config, ".var": varApp, "snap": snapHome]
        input.library = linuxDataFolders.compactMap { folder in
            guard let total = home.removeValue(forKey: folder) else { return nil }
            let children = (inside[folder] ?? [:]).map { UsageInputs.Entry(name: $0.key, bytes: $0.value) }
            return .init(name: folder, bytes: minus(total, claimed[folder] ?? 0), kind: folder == ".cache" ? .cache : .other, children: children)
        }
        input.personal = home.map { .init(name: $0.key, bytes: $0.value, kind: .personal) }
        input.libraryKey = "appdata"
    }

    /// Size and free space of the file system holding `path` (on Linux `/home` is often its own partition).
    static func fileSystemBytes(_ path: String) -> (total: UInt64, free: UInt64) {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return (0, 0) }
        let unit = UInt64(info.f_frsize == 0 ? info.f_bsize : info.f_frsize)
        return (UInt64(info.f_blocks) * unit, UInt64(info.f_bavail) * unit)
    }

    /// Allocated bytes of each `<name>_<revision>.snap` under `/var/lib/snapd/snaps`, summed by name.
    /// `/snap` itself is squashfs mounts, so du there is slow and counts the unpacked size.
    static func snapPackages(_ folder: String = "/var/lib/snapd/snaps") -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".snap") {
            var info = stat()
            guard lstat("\(folder)/\(file)", &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let name = file.split(separator: "_").first.map(String.init) ?? String(file.dropLast(5))
            result[name, default: 0] += UInt64(info.st_blocks) * 512
        }
        return result
    }

    static func runLinux(engine: DisklesslyEngine, timeout: TimeInterval, progress: (String) -> Void) -> (tree: UsageNode, partial: Bool) {
        let home = NSHomeDirectory()
        let disk = fileSystemBytes(home)
        var input = UsageInputs(totalBytes: disk.total, freeBytes: disk.free)
        let jobs: [(String, String)] = [
            ("home", home), ("cache", home + "/.cache"), ("share", home + "/.local/share"), ("config", home + "/.config"),
            ("varApp", home + "/.var/app"), ("snapHome", home + "/snap"), ("opt", "/opt"),
            ("flatpakSystem", "/var/lib/flatpak/app"), ("flatpakUser", home + "/.local/share/flatpak/app"),
            ("cacheDir", engine.config.cacheDir), ("stateDir", engine.config.stateDir), ("repo", engine.config.repoPath),
        ]
        progress("scan")
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let (name, path) = jobs[index]
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            results.set(name, path: path, sizes(of: path, timeout: timeout))
        }
        let snaps = snapPackages()
        progress("assemble")
        func children(_ name: String) -> [String: UInt64] {
            guard let hit = results.get(name) else { return [:] }
            return Dictionary(hit.sizes.compactMap { key, value in key == hit.path ? nil : (URL(fileURLWithPath: key).lastPathComponent, value) }, uniquingKeysWith: max)
        }
        func total(_ name: String) -> UInt64 {
            guard let hit = results.get(name) else { return 0 }
            return hit.sizes[hit.path] ?? 0
        }
        var m = LinuxMeasurements()
        m.home = children("home"); m.cache = children("cache"); m.share = children("share"); m.config = children("config")
        m.varApp = children("varApp"); m.snapHome = children("snapHome"); m.opt = children("opt")
        m.flatpakSystem = children("flatpakSystem"); m.flatpakUser = children("flatpakUser"); m.snaps = snaps

        // Disklessly's own folders count once, in the Disklessly box. The repo may sit in
        // the state folder (the default), or anywhere else under ~.
        let repoTotal = total("repo"), stateTotal = total("stateDir"), cacheTotal = total("cacheDir")
        let config = engine.config
        let repoInState = config.repoPath.hasPrefix(config.stateDir + "/")
        input.repoBytes = repoTotal
        input.otherDisklesslyBytes = cacheTotal + (repoInState ? minus(stateTotal, repoTotal) : stateTotal)
        let own = [(config.cacheDir, cacheTotal), (config.stateDir, stateTotal)] + (repoInState ? [] : [(config.repoPath, repoTotal)])
        for (path, bytes) in own where path.hasPrefix(home + "/") {
            // ~/.cache/disklessly and ~/.local/share/disklessly are dropped by name in linuxInputs.
            if path == home + "/.cache/disklessly" || path.hasPrefix(home + "/.local/share/disklessly") { continue }
            if let first = path.dropFirst(home.count + 1).split(separator: "/").first { m.homeClaimed[String(first), default: 0] += bytes }
        }
        linuxInputs(m, into: &input)
        return (UsageMap.assemble(input), results.anyIncomplete)
    }

    /// macOS volumes in the boot container, and the big folders outside the home folder.
    static func systemParts(children: (String) -> [(String, UInt64)], total: (String) -> UInt64) -> [UsageInputs.Entry] {
        var parts: [UsageInputs.Entry] = []
        let volumes = apfsVolumes()
        let macOS = ["System", "Preboot", "Recovery", "Update"].reduce(UInt64(0)) { $0 + (volumes[$1] ?? 0) }
        if macOS > 0 { parts.append(.init(name: "macOS", bytes: macOS, key: "macos")) }
        if let vm = volumes["VM"], vm > 0 { parts.append(.init(name: "Virtual memory", bytes: vm, key: "vm")) }
        let runtimes = total("simRuntimes")
        let library = children("sysLibrary").map { name, bytes -> UsageInputs.Entry in
            name == "Developer" && runtimes > 0 ? .init(name: name, bytes: bytes > runtimes ? bytes - runtimes : 0) : .init(name: name, bytes: bytes)
        }
        if runtimes > 0 { parts.append(.init(name: "Simulator runtimes", bytes: runtimes, key: "simruntimes", action: UsageCleanup.simulatorRuntimes)) }
        let libraryBytes = library.reduce(0) { $0 + $1.bytes }
        if libraryBytes > 0 { parts.append(.init(name: "/Library", bytes: libraryBytes, children: library)) }
        if total("homebrew") > 0 { parts.append(.init(name: "Homebrew", bytes: total("homebrew"), key: "homebrew", action: UsageCleanup.homebrew)) }
        if total("usrLocal") > 0 { parts.append(.init(name: "/usr/local", bytes: total("usrLocal"))) }
        if total("var") > 0 { parts.append(.init(name: "/private/var", bytes: total("var"), key: "var")) }
        return parts
    }

    /// Bytes in use per APFS role (System, Preboot, Recovery, Update, VM) in the container holding "/".
    static func apfsVolumes() -> [String: UInt64] {
        #if os(macOS)
        func plist(_ args: [String]) -> Any? {
            let data = Data(ProcessRunner.capture("/usr/sbin/diskutil", args).utf8)
            return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        }
        guard let info = plist(["info", "-plist", "/"]) as? [String: Any],
              let container = info["APFSContainerReference"] as? String,
              let list = plist(["apfs", "list", "-plist"]) as? [String: Any],
              let containers = list["Containers"] as? [[String: Any]],
              let mine = containers.first(where: { $0["ContainerReference"] as? String == container }),
              let volumes = mine["Volumes"] as? [[String: Any]] else { return [:] }
        var out: [String: UInt64] = [:]
        for volume in volumes {
            let roles = volume["Roles"] as? [String] ?? []
            let bytes = (volume["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0
            for role in roles where role != "Data" { out[role, default: 0] += bytes }
        }
        return out
        #else
        return [:]
        #endif
    }

    private final class LockedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.lock(); if paths.count < 2000 { paths.append(path) }; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private final class LockedResults: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (path: String, sizes: [String: UInt64], complete: Bool)] = [:]
        func set(_ name: String, path: String, _ value: (sizes: [String: UInt64], complete: Bool)) {
            lock.lock(); map[name] = (path, value.sizes, value.complete); lock.unlock()
        }
        func get(_ name: String) -> (path: String, sizes: [String: UInt64], complete: Bool)? {
            lock.lock(); defer { lock.unlock() }; return map[name]
        }
        var anyIncomplete: Bool { lock.lock(); defer { lock.unlock() }; return map.values.contains { !$0.complete } }
    }
}

// MARK: - Background scan

/// Runs one scan at a time off the request thread; the page polls for the result.
public final class UsageScanner {
    public enum State: String { case idle, scanning, ready }

    private let lock = NSLock()
    private var state: State = .idle
    private var phase = ""
    private var result: (tree: UsageNode, partial: Bool, at: Date)?
    private var startedAt: Date?
    private let run: (DisklesslyEngine, @escaping (String) -> Void) -> (UsageNode, Bool)

    public init(runner: SystemCommandRunner = LiveSystemCommandRunner.shared) {
        self.run = { engine, progress in
            let scan = UsageScan.run(engine: engine, runner: runner, progress: progress)
            return (scan.tree, scan.partial)
        }
    }

    public init(run: @escaping (DisklesslyEngine, @escaping (String) -> Void) -> (UsageNode, Bool)) { self.run = run }

    /// Starts a scan unless one is running. Returns false when one already is.
    @discardableResult
    public func start(engine: DisklesslyEngine) -> Bool {
        lock.lock()
        if state == .scanning { lock.unlock(); return false }
        state = .scanning
        phase = "scan"
        startedAt = Date()
        lock.unlock()
        Thread.detachNewThread { [self] in
            let (tree, partial) = run(engine) { [self] name in lock.lock(); phase = name; lock.unlock() }
            lock.lock()
            result = (tree, partial, Date())
            state = .ready
            lock.unlock()
        }
        return true
    }

    public var scannedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return result?.at
    }

    /// The last finished tree, if any.
    public var tree: UsageNode? {
        lock.lock(); defer { lock.unlock() }
        return result?.tree
    }

    public func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = ["ok": true, "state": state.rawValue]
        if state == .scanning {
            object["phase"] = phase
            if let startedAt { object["startedAt"] = formatter.string(from: startedAt) }
        }
        if let result {
            object["scannedAt"] = formatter.string(from: result.at)
            object["partial"] = result.partial
            object["tree"] = result.tree.jsonObject()
        }
        return object
    }
}
