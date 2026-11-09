import Foundation
import DisklesslyCore

/// Large things on this Mac that are not apps: simulator runtimes and devices, Xcode
/// DerivedData, caches that their tools rebuild, big app data, and big personal folders.
/// The app recommendations only look at bundles in /Applications, which on a developer's Mac
/// are rarely where the space went.
public struct BigItem: Equatable {
    /// What can be done with it.
    public enum Action: String {
        /// Offload in the Xcode simulators section (`/api/dev/...`).
        case devOffload = "dev-offload"
        /// A cleanup whose tool rebuilds what it removes (`/api/usage/cleanup`, `BigItems.clean`).
        case clean
        /// Nothing to press here; the page points at the usage map or the files section.
        case review
    }

    public var id: String
    public var kind: String
    public var title: String
    public var path: String
    public var bytes: UInt64
    public var action: Action
    /// The id to pass to the action: a runtime id, a simulator udid, or a cleanup id.
    public var target: String
    /// Short machine reason (`unusedRuntime`, `idleSimulator`, `rebuildable`, `appData`, `personal`).
    public var reason: String
    public var lastUsed: Date?
    /// The folder passes the offload safety rules, so the page offers Offload and Delete on it.
    public var fileActions: Bool = false
    /// Page string key for the title, for rows Disklessly names itself; `title` is the English fallback.
    public var titleKey: String?

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "kind": kind, "title": title, "path": path, "bytes": NSNumber(value: bytes),
            "action": action.rawValue, "target": target, "reason": reason, "fileActions": fileActions,
        ]
        if let lastUsed { object["lastUsed"] = ISO8601DateFormatter().string(from: lastUsed) }
        if let titleKey { object["titleKey"] = titleKey }
        return object
    }
}

public struct BigItemsReport: Equatable {
    public var items: [BigItem]
    public var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    public func jsonObject() -> [String: Any] {
        ["items": items.map { $0.jsonObject() }, "bytes": NSNumber(value: bytes)]
    }
}

/// Folders whose contents their own tool downloads or builds again. Removing the contents is
/// safe at any time the tool is not running; the next build or install is slower once.
public struct RebuildableCache: Equatable {
    public var id: String
    public var title: String
    /// Relative to the home folder.
    public var relativePath: String

    /// The list lives in `KnownLocations`.
    public static var all: [RebuildableCache] { KnownLocations.rebuildableCaches }
}

public enum BigItems {
    /// Items under this size are not worth a row.
    public static let minBytes: UInt64 = 1 << 30
    /// App data and personal folders are only listed from this size on.
    public static let reviewMinBytes: UInt64 = 3 << 30

    public static let personalFolders = ["Downloads", "Movies", "Desktop", "Documents", "Pictures", "Music"]

    /// Removes the contents of a rebuildable cache (moved to the Trash on macOS, so it can be
    /// put back). The folder itself stays, so tools that expect it keep working.
    public static func clean(_ id: String, home: String = NSHomeDirectory()) throws -> (items: Int, bytes: UInt64) {
        guard let cache = RebuildableCache.all.first(where: { $0.id == id }) else {
            throw DisklesslyError.usage("unknown cache: \(id)")
        }
        let folder = URL(fileURLWithPath: home).appendingPathComponent(cache.relativePath)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var bytes: UInt64 = 0, items = 0
        for entry in entries {
            let size = AllocatedSize.tree(entry)
            #if os(macOS)
            try FileManager.default.trashItem(at: entry, resultingItemURL: nil)
            #else
            try FileManager.default.removeItem(at: entry)
            #endif
            bytes += size
            items += 1
        }
        return (items, bytes)
    }

    /// Children of `folder` at least `minimum` bytes, largest first. Stops measuring at `deadline`.
    static func largeChildren(of folder: URL, minimum: UInt64, deadline: Date) -> [(URL, UInt64)] {
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        var out: [(URL, UInt64)] = []
        for child in children where !child.lastPathComponent.hasPrefix(".") {
            if Date() > deadline { break }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let size = AllocatedSize.tree(child)
            if size >= minimum { out.append((child, size)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }
}

extension DisklesslyEngine {
    /// Big non-app items, largest first. Reads only; nothing is changed.
    public func bigItems(home: String = NSHomeDirectory(), now: Date = Date(), budget: TimeInterval = 60) -> BigItemsReport {
        var items: [BigItem] = []
        let deadline = now.addingTimeInterval(budget)
        let homeURL = URL(fileURLWithPath: home)
        #if os(macOS)
        let dev = devAssets()
        if dev.unavailable == nil {
            for runtime in dev.runtimes where runtime.sizeBytes >= BigItems.minBytes && runtime.deletable {
                let users = dev.simulators.filter { $0.runtimeIdentifier == runtime.runtimeIdentifier }
                items.append(BigItem(
                    id: "runtime:\(runtime.id)", kind: "simRuntime", title: runtime.title, path: runtime.path,
                    bytes: runtime.sizeBytes, action: .devOffload, target: runtime.id,
                    reason: users.isEmpty ? "unusedRuntime" : "runtime",
                    lastUsed: runtime.lastUsedAt.flatMap { ISO8601DateFormatter().date(from: $0) }))
            }
            for device in dev.simulators where device.dataBytes >= BigItems.minBytes {
                items.append(BigItem(
                    id: "simulator:\(device.udid)", kind: "simulator", title: device.name,
                    path: Self.devicesFolder + "/" + device.udid, bytes: device.dataBytes, action: .devOffload,
                    target: device.udid, reason: device.booted ? "running" : "idleSimulator",
                    lastUsed: device.lastUsedAt.flatMap { ISO8601DateFormatter().date(from: $0) }))
            }
        }
        let derived = homeURL.appendingPathComponent(KnownLocations.derivedData)
        let derivedBytes = AllocatedSize.tree(derived)
        if derivedBytes >= BigItems.minBytes {
            items.append(BigItem(id: "derived-data", kind: "derivedData", title: "Xcode DerivedData", path: derived.path,
                                 bytes: derivedBytes, action: .clean, target: UsageCleanup.derivedData, reason: "rebuildable"))
        }
        let brewCache = homeURL.appendingPathComponent(KnownLocations.homebrewDownloads)
        let brewBytes = AllocatedSize.tree(brewCache)
        if brewBytes >= BigItems.minBytes, UsageCleanup.brew() != nil {
            items.append(BigItem(id: "brew-cleanup", kind: "cache", title: "Homebrew downloads", path: brewCache.path,
                                 bytes: brewBytes, action: .clean, target: UsageCleanup.homebrew, reason: "rebuildable"))
        }
        #endif
        for cache in RebuildableCache.all {
            let folder = homeURL.appendingPathComponent(cache.relativePath)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let size = AllocatedSize.tree(folder)
            if size >= BigItems.minBytes {
                items.append(BigItem(id: cache.id, kind: "cache", title: cache.title, path: folder.path, bytes: size,
                                     action: .clean, target: cache.id, reason: "rebuildable"))
            }
        }
        // App data: whole folders the user can look at. Caches and Developer are covered above;
        // Disklessly's own folders, iCloud's store and container engines' data are not listed.
        let ownNames = KnownLocations.notAppData(home: home, config: config)
        for parent in ["Library/Containers", "Library/Group Containers", "Library/Application Support"] {
            for (url, size) in BigItems.largeChildren(of: homeURL.appendingPathComponent(parent), minimum: BigItems.reviewMinBytes, deadline: deadline)
            where !ownNames.contains(url.lastPathComponent) {
                items.append(BigItem(id: "appdata:\(url.path)", kind: "appData", title: url.lastPathComponent, path: url.path,
                                     bytes: size, action: .review, target: url.path, reason: "appData"))
            }
        }
        for name in BigItems.personalFolders {
            if Date() > deadline { break }
            let folder = homeURL.appendingPathComponent(name)
            let size = AllocatedSize.tree(folder)
            if size >= BigItems.reviewMinBytes {
                items.append(BigItem(id: "personal:\(name)", kind: "personal", title: name, path: folder.path, bytes: size,
                                     action: .review, target: folder.path, reason: "personal"))
            }
        }
        items.append(contentsOf: adviceItems(home: home))
        return BigItemsReport(items: items.sorted { $0.bytes > $1.bytes })
    }
}

/// One big-items scan at a time off the request thread; the page polls `/api/bigitems`.
public final class BigItemsScanner {
    private let lock = NSLock()
    private var scanning = false
    private var result: (report: BigItemsReport, at: Date)?
    private let run: (DisklesslyEngine) -> BigItemsReport

    public init(run: ((DisklesslyEngine) -> BigItemsReport)? = nil) {
        self.run = run ?? { $0.bigItems() }
    }

    @discardableResult
    public func start(engine: DisklesslyEngine) -> Bool {
        lock.lock()
        if scanning { lock.unlock(); return false }
        scanning = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            let report = run(engine)
            lock.lock()
            result = (report, Date())
            scanning = false
            lock.unlock()
        }
        return true
    }

    public func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var object: [String: Any] = ["ok": true, "state": scanning ? "scanning" : (result == nil ? "idle" : "ready")]
        if let result {
            object.merge(result.report.jsonObject()) { $1 }
            object["scannedAt"] = ISO8601DateFormatter().string(from: result.at)
        }
        return object
    }
}
