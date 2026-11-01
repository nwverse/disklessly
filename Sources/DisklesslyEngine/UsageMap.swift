import Foundation
import DisklesslyCore

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
        UsageNode(name: name, key: key, kind: kind, bytes: children.reduce(0) { $0 + $1.bytes }, children: children)
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["name": name, "kind": kind.rawValue, "bytes": NSNumber(value: bytes)]
        if let key { object["key"] = key }
        if let action { object["action"] = action }
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
        public init(name: String, bundleBytes: UInt64, cacheBytes: UInt64 = 0, dataBytes: UInt64 = 0) {
            self.name = name; self.bundleBytes = bundleBytes; self.cacheBytes = cacheBytes; self.dataBytes = dataBytes
        }
    }
    public struct Offloaded {
        public var name: String
        /// The image downloaded to this Mac.
        public var cachedBytes: UInt64
        public init(name: String, cachedBytes: UInt64) { self.name = name; self.cachedBytes = cachedBytes }
    }
    public struct Entry {
        public var name: String
        public var bytes: UInt64
        public var kind: UsageNode.Kind
        /// What is inside, when the scan looked (one level).
        public var children: [Entry] = []
        public var key: String?
        public var action: String?
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
    /// Measured parts of what used to be one "System & other" box: macOS volumes, /Library,
    /// Homebrew, /private/var. The rest stays as "not measured".
    public var system: [Entry] = []

    public init(totalBytes: UInt64, freeBytes: UInt64) { self.totalBytes = totalBytes; self.freeBytes = freeBytes }
}

public enum UsageMap {
    /// Boxes beyond this many in one list are merged into "other".
    public static let maxListed = 14

    /// Builds the tree. Whatever the measured boxes do not add up to is "System & other",
    /// so the root always equals the disk and the free box.
    public static func assemble(_ input: UsageInputs) -> UsageNode {
        let appNodes: [UsageNode] = input.apps.map { app in
            var parts: [UsageNode] = [UsageNode(name: app.name, key: "bundle", kind: .bundle, bytes: app.bundleBytes)]
            if app.cacheBytes > 0 { parts.append(UsageNode(name: app.name, key: "cache", kind: .cache, bytes: app.cacheBytes)) }
            if app.dataBytes > 0 { parts.append(UsageNode(name: app.name, key: "data", kind: .data, bytes: app.dataBytes)) }
            return UsageNode.group(name: app.name, kind: .apps, parts)
        }
        let apps = UsageNode.group(name: "Apps", key: "apps", kind: .apps, merged(appNodes, kind: .apps))

        var offloadedNodes: [UsageNode] = input.offloaded.filter { $0.cachedBytes > 0 }.map {
            UsageNode(name: $0.name, key: "cache", kind: .cache, bytes: $0.cachedBytes)
        }
        offloadedNodes = merged(offloadedNodes, kind: .cache)
        if input.repoBytes > 0 { offloadedNodes.append(UsageNode(name: "Repo", key: "repo", kind: .repo, bytes: input.repoBytes)) }
        if input.otherDisklesslyBytes > 0 { offloadedNodes.append(UsageNode(name: "State", key: "state", kind: .other, bytes: input.otherDisklesslyBytes)) }
        let disklessly = UsageNode.group(name: "Disklessly", key: "disklessly", kind: .offloaded, offloadedNodes)

        let personal = UsageNode.group(name: "Personal files", key: "personal", kind: .personal, merged(input.personal.map { UsageNode(name: $0.name, kind: $0.kind == .other ? .personal : $0.kind, bytes: $0.bytes) }, kind: .personal))
        let library = UsageNode.group(name: "Library", key: "library", kind: .library, merged(input.library.map(libraryNode), kind: .library))

        var top = [apps, disklessly, personal, library].filter { $0.bytes > 0 }
        let used = input.totalBytes > input.freeBytes ? input.totalBytes - input.freeBytes : 0
        let measured = top.reduce(0) { $0 + $1.bytes }
        let leftover = used > measured ? used - measured : 0
        if input.system.isEmpty {
            top.append(UsageNode(name: "System & other", key: "system", kind: .system, bytes: leftover))
        } else {
            var parts = input.system.map { entryNode($0, kind: .system) }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            let partsBytes = parts.reduce(0) { $0 + $1.bytes }
            // Snapshots, purgeable space, other users and folders the scan could not read.
            if leftover > partsBytes { parts.append(UsageNode(name: "Not measured", key: "unmeasured", kind: .system, bytes: leftover - partsBytes)) }
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
        guard !entry.children.isEmpty else { return UsageNode(name: entry.name, key: entry.key, kind: kind, bytes: entry.bytes, action: entry.action) }
        let inside = merged(entry.children.map { entryNode($0, kind: kind) }, kind: kind)
        // The folder's own size stays: files directly in it show up as the difference.
        let loose = entry.bytes > inside.reduce(0, { $0 + $1.bytes }) ? entry.bytes - inside.reduce(0, { $0 + $1.bytes }) : 0
        let parts = loose > 0 ? inside + [UsageNode(name: "files", key: "files", kind: kind, bytes: loose)] : inside
        var node = UsageNode.group(name: entry.name, key: entry.key, kind: kind, parts)
        node.action = entry.action
        return node
    }

    /// Largest first; the tail past `maxListed` becomes one "Other" box.
    static func merged(_ nodes: [UsageNode], kind: UsageNode.Kind) -> [UsageNode] {
        let sorted = nodes.filter { $0.bytes > 0 }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        guard sorted.count > maxListed else { return sorted }
        let head = Array(sorted.prefix(maxListed))
        let tail = sorted.dropFirst(maxListed)
        let rest = UsageNode(name: "\(tail.count)", key: "rest", kind: .other, bytes: tail.reduce(0) { $0 + $1.bytes })
        return head + [rest]
    }
}

// MARK: - Measuring

public enum UsageScan {
    /// `du -k -d 1`: allocated kilobytes for each direct child of `path`, plus the folder itself under its own path.
    /// A timeout keeps what finished, because du prints a child as soon as its subtree is done.
    static func sizes(of path: String, timeout: TimeInterval) -> (sizes: [String: UInt64], complete: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        // -x: stay on this volume, so mounted disk images (Disklessly's own, simulator runtimes) are not counted.
        process.arguments = ["-x", "-k", "-d", "1", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ([:], false) }
        let output = LockedData()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            reader.leave()
        }
        var complete = true
        let deadline = DispatchTime.now() + timeout
        if reader.wait(timeout: deadline) == .timedOut {
            complete = false
            process.terminate()
            _ = reader.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        var result: [String: UInt64] = [:]
        for line in String(decoding: output.get(), as: UTF8.self).split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = UInt64(line[line.startIndex..<tab]) else { continue }
            result[String(line[line.index(after: tab)...])] = kb * 1024
        }
        return (result, complete)
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Measures this Mac and builds the tree. Slow on a big disk: callers run it off the request thread.
    public static func run(engine: DisklesslyEngine, timeout: TimeInterval = 240, progress: (String) -> Void = { _ in }) -> (tree: UsageNode, partial: Bool) {
        let home = NSHomeDirectory()
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        var input = UsageInputs(
            totalBytes: UInt64(volume?.volumeTotalCapacity ?? 0),
            freeBytes: UInt64(volume?.volumeAvailableCapacity ?? 0)
        )
        let library = home + "/Library"
        let jobs: [(String, String)] = [
            ("apps", "/Applications"), ("userApps", home + "/Applications"), ("home", home), ("library", library),
            ("caches", library + "/Caches"), ("support", library + "/Application Support"), ("containers", library + "/Containers"),
            ("cacheDir", engine.config.cacheDir), ("repo", engine.config.repoPath),
            // Parts of "System & other".
            ("sysLibrary", "/Library"), ("simRuntimes", "/Library/Developer/CoreSimulator"), ("homebrew", "/opt/homebrew"),
            ("usrLocal", "/usr/local"), ("var", "/private/var"),
            ("userDeveloper", library + "/Developer"), ("derivedData", library + "/Developer/Xcode/DerivedData"),
        ]
        progress("scan")
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let (name, path) = jobs[index]
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            results.set(name, path: path, sizes(of: path, timeout: timeout))
        }
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
                let display = String(name.dropLast(4))
                let bundleId = Bundle(path: root + "/" + name)?.bundleIdentifier
                var cache: UInt64 = 0, data: UInt64 = 0
                for key in [bundleId, display].compactMap({ $0 }) {
                    if let v = caches[key], !usedCache.contains(key) { cache += v; usedCache.insert(key) }
                    if let v = support[key], !usedSupport.contains(key) { data += v; usedSupport.insert(key) }
                    if let v = containers[key], !usedContainers.contains(key) { data += v; usedContainers.insert(key) }
                }
                input.apps.append(.init(name: display, bundleBytes: bytes, cacheBytes: cache, dataBytes: data))
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
        input.personal = homeEntries.map { .init(name: $0.key, bytes: $0.value, kind: .personal) }

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
        ]
        input.library = entries.map { .init(name: $0.key, bytes: $0.value, kind: $0.key == "Caches" ? .cache : .library, children: inside[$0.key] ?? []) }
        // ~/Library/Developer: simulator devices and Xcode's DerivedData get their own boxes and cleanups.
        if let index = input.library.firstIndex(where: { $0.name == "Developer" }) {
            let derived = total("derivedData")
            input.library[index].children = children("userDeveloper").map { name, bytes in
                switch name {
                case "CoreSimulator": return .init(name: "Simulator devices", bytes: bytes, key: "simdevices", action: UsageCleanup.simulatorDevices)
                case "Xcode" where derived > 0:
                    return .init(name: "Xcode", bytes: bytes, children: [
                        .init(name: "DerivedData", bytes: derived, key: "deriveddata", action: UsageCleanup.derivedData),
                        .init(name: "other", bytes: bytes > derived ? bytes - derived : 0),
                    ])
                default: return .init(name: name, bytes: bytes)
                }
            }
        }
        input.system = systemParts(children: children, total: total)
        return (UsageMap.assemble(input), partial)
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

    public init(run: @escaping (DisklesslyEngine, @escaping (String) -> Void) -> (UsageNode, Bool) = { engine, progress in
        let scan = UsageScan.run(engine: engine, progress: progress)
        return (scan.tree, scan.partial)
    }) { self.run = run }

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
