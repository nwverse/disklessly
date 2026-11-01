import Foundation
import DisklesslyCore
#if canImport(CoreServices)
import CoreServices
#endif

/// A large file or folder in the home folder that has not been opened for a while.
public struct LargeFileItem: Equatable {
    public var path: String
    public var name: String
    public var kind: FilePlaceholder.Kind
    /// Allocated bytes: what offloading it frees.
    public var bytes: UInt64
    public var lastUsed: Date?

    public func jsonObject(now: Date) -> [String: Any] {
        var object: [String: Any] = ["path": path, "name": name, "kind": kind.rawValue, "sizeBytes": NSNumber(value: bytes)]
        if let lastUsed {
            object["lastUsed"] = ISO8601DateFormatter().string(from: lastUsed)
            object["daysIdle"] = max(0, Int(now.timeIntervalSince(lastUsed) / 86_400))
        }
        return object
    }
}

public struct LargeFileOptions: Equatable {
    public var minBytes: UInt64 = 500 << 20
    public var minIdleDays: Int = 30
    public var limit: Int = 40
    /// Seconds before the walk stops and returns what it found.
    public var timeout: TimeInterval = 180
    public init(minBytes: UInt64 = 500 << 20, minIdleDays: Int = 30, limit: Int = 40, timeout: TimeInterval = 180) {
        self.minBytes = minBytes; self.minIdleDays = minIdleDays; self.limit = limit; self.timeout = timeout
    }
}

public enum LargeFileScan {
    struct Summary { var bytes: UInt64 = 0; var newest: Date = .distantPast; var blocked = false }

    /// Walks `root` (the home folder). Hidden items (a hidden folder also keeps its parent from being listed whole), symlinks, other volumes, iCloud items and the
    /// folders `FileOffloadPolicy` names are skipped. A folder is listed whole when nothing in it was
    /// changed recently and it is at least two levels down (`~/Downloads/Old Project`); then nothing
    /// inside it is listed separately. Files that are open (a running VM disk) are dropped.
    public static func scan(root: URL, protected: [String], options: LargeFileOptions, now: Date = Date(),
                            lastUsed: (URL) -> Date? = LargeFileScan.spotlightLastUsed,
                            openPaths: ([String]) -> Set<String> = LargeFileScan.openFiles) -> (items: [LargeFileItem], partial: Bool) {
        let cutoff = now.addingTimeInterval(-Double(options.minIdleDays) * 86_400)
        let deadline = Date().addingTimeInterval(options.timeout)
        let protectedRoots = protected.filter { !$0.isEmpty }.map { SessionPaths.canonical($0) }
        let rootDevice = PackPreflight.deviceID(root.path)
        var files: [LargeFileItem] = []
        var folders: [LargeFileItem] = []
        var partial = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .contentModificationDateKey, .contentAccessDateKey, .isUbiquitousItemKey, .isPackageKey]

        func visit(_ dir: URL, _ dirPath: String, depth: Int) -> Summary {
            var summary = Summary()
            if Date() > deadline { partial = true; summary.blocked = true; return summary }
            guard let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else {
                summary.blocked = true
                return summary
            }
            // A source checkout (`.git`, `.hg`, `.svn`) is skipped whole: its files belong to the repository.
            if children.contains(where: { [".git", ".hg", ".svn"].contains($0.lastPathComponent) }) {
                summary.blocked = true
                return summary
            }
            for child in children {
                let name = child.lastPathComponent
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { summary.blocked = true; continue }
                if values.isSymbolicLink == true { continue }
                // Built from the canonical root, so it compares with the canonical protected paths.
                let path = dirPath + "/" + name
                // Hidden folders are tool stores (`.git`, `.cache`, `.docker`): skipped, and the folder holding one is never listed whole.
                if name.hasPrefix(".") {
                    if values.isDirectory == true { summary.blocked = true }
                    continue
                }
                if depth == 0, FileOffloadPolicy.skippedHomeChildren.contains(name) { continue }
                // Inside the repo, cache or state: skipped. A folder that holds one is walked but never listed whole.
                if protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { summary.blocked = true; continue }
                if values.isUbiquitousItem == true { summary.blocked = true; continue }
                if values.isDirectory == true {
                    if FileOffloadPolicy.skipsFolder(name: name) { summary.blocked = true; continue }
                    if let rootDevice, PackPreflight.deviceID(child.path) != rootDevice { continue }
                    var inner = visit(child, path, depth: depth + 1)
                    if let own = values.contentModificationDate, own > inner.newest { inner.newest = own }
                    summary.bytes += inner.bytes
                    summary.newest = max(summary.newest, inner.newest)
                    summary.blocked = summary.blocked || inner.blocked
                    if depth >= 1, !inner.blocked, inner.bytes >= options.minBytes, inner.newest < cutoff {
                        let used = lastUsed(child)
                        if used.map({ $0 < cutoff }) ?? true {
                            folders.append(LargeFileItem(path: path, name: name, kind: .folder, bytes: inner.bytes, lastUsed: max(used ?? .distantPast, inner.newest)))
                        }
                    }
                } else if values.isRegularFile == true {
                    let bytes = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                    let modified = values.contentModificationDate ?? .distantPast
                    summary.bytes += bytes
                    summary.newest = max(summary.newest, modified)
                    if FileOffloadPolicy.skipsFile(name: name) { summary.blocked = true; continue }
                    guard bytes >= options.minBytes else { continue }
                    let used = lastUsed(child) ?? max(modified, values.contentAccessDate ?? .distantPast)
                    if used < cutoff {
                        files.append(LargeFileItem(path: path, name: name, kind: .file, bytes: bytes, lastUsed: used == .distantPast ? nil : used))
                    } else {
                        summary.newest = max(summary.newest, used)
                    }
                }
            }
            return summary
        }
        let rootPath = SessionPaths.canonical(root.path)
        _ = visit(URL(fileURLWithPath: rootPath), rootPath, depth: 0)

        // Keep the outermost folder; drop folders and files inside it.
        let outer = folders.sorted { $0.path.count < $1.path.count }.reduce(into: [LargeFileItem]()) { kept, folder in
            if !kept.contains(where: { folder.path.hasPrefix($0.path + "/") }) { kept.append(folder) }
        }
        let loose = files.filter { file in !outer.contains { file.path.hasPrefix($0.path + "/") } }
        let open = openPaths(loose.map(\.path))
        let items = (outer + loose.filter { !open.contains($0.path) })
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return (Array(items.prefix(options.limit)), partial)
    }

    /// Spotlight's `kMDItemLastUsedDate`: the last time the item was opened. Nil off macOS or when unindexed.
    public static func spotlightLastUsed(_ url: URL) -> Date? {
        #if os(macOS)
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        #else
        return nil
        #endif
    }

    /// The subset of `paths` some process has open, from one `lsof` call.
    public static func openFiles(_ paths: [String]) -> Set<String> {
        guard !paths.isEmpty, let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsof)
        process.arguments = ["-Fn", "--"] + paths
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let wanted = Dictionary(paths.map { (SessionPaths.canonical($0), $0) }, uniquingKeysWith: { a, _ in a })
        var open: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix("n") {
            if let original = wanted[SessionPaths.canonical(String(line.dropFirst()))] { open.insert(original) }
        }
        return open
    }
}

extension DisklesslyEngine {
    /// Large, idle files and folders in the home folder.
    public func largeFiles(options: LargeFileOptions = LargeFileOptions(), home: String? = nil) -> (items: [LargeFileItem], partial: Bool) {
        let lastUsed = lastUsedOverride ?? LargeFileScan.spotlightLastUsed
        let open: ([String]) -> Set<String> = { paths in
            if let fileOpenOverride { return Set(paths.filter { fileOpenOverride($0, false) }) }
            return LargeFileScan.openFiles(paths)
        }
        return LargeFileScan.scan(root: URL(fileURLWithPath: home ?? homeDirectory), protected: protectedPaths, options: options, lastUsed: lastUsed, openPaths: open)
    }
}

/// Runs one large-file scan at a time off the request thread; the page polls for the result.
public final class LargeFileScanner {
    private let lock = NSLock()
    private var scanning = false
    private var result: (items: [LargeFileItem], partial: Bool, at: Date)?
    private let run: (DisklesslyEngine) -> ([LargeFileItem], Bool)
    public let options: LargeFileOptions

    public init(options: LargeFileOptions = LargeFileOptions(), run: ((DisklesslyEngine) -> ([LargeFileItem], Bool))? = nil) {
        self.options = options
        self.run = run ?? { engine in
            let scan = engine.largeFiles(options: options)
            return (scan.items, scan.partial)
        }
    }

    @discardableResult
    public func start(engine: DisklesslyEngine) -> Bool {
        lock.lock()
        if scanning { lock.unlock(); return false }
        scanning = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            let (items, partial) = run(engine)
            lock.lock()
            result = (items, partial, Date())
            scanning = false
            lock.unlock()
        }
        return true
    }

    /// Drops an item that was just offloaded, so the list updates before the next scan.
    public func forget(path: String) {
        lock.lock()
        if var current = result { current.items.removeAll { $0.path == path }; result = current }
        lock.unlock()
    }

    public func snapshot(now: Date = Date()) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var object: [String: Any] = ["ok": true, "state": scanning ? "scanning" : (result == nil ? "idle" : "ready"),
                                     "minSizeBytes": NSNumber(value: options.minBytes), "minIdleDays": options.minIdleDays]
        if let result {
            object["scannedAt"] = ISO8601DateFormatter().string(from: result.at)
            object["partial"] = result.partial
            object["items"] = result.items.map { $0.jsonObject(now: now) }
            object["estimatedFreedBytes"] = NSNumber(value: result.items.reduce(0) { $0 + $1.bytes })
        }
        return object
    }
}
