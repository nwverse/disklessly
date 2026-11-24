import Foundation
import DisklesslyCore

/// Cleanups the usage map offers on boxes it can shrink. Each one only removes what its own
/// tool regenerates or no longer needs; the page asks before running any of them.
public enum UsageCleanup {
    /// `brew cleanup --prune=all`: old versions and the download cache.
    public static let homebrew = "brew-cleanup"
    /// `xcrun simctl runtime delete --outdated` and `--unusable`: runtimes replaced by a newer
    /// build of the same version, and broken ones.
    public static let simulatorRuntimes = "sim-runtimes"
    /// `xcrun simctl delete unavailable`: simulator devices for runtimes that are gone.
    public static let simulatorDevices = "sim-devices"
    /// The contents of ~/Library/Developer/Xcode/DerivedData. Xcode rebuilds it.
    public static let derivedData = "derived-data"

    public static let all = [homebrew, simulatorRuntimes, simulatorDevices, derivedData]

    /// Every id `run` accepts: the four above and the rebuildable caches of `BigItems`.
    public static func known(_ id: String) -> Bool {
        all.contains(id) || RebuildableCache.all.contains { $0.id == id } || DiskAdvisor.sipAssetGroups.contains { $0.id == id }
    }

    static func brew() -> String? {
        KnownLocations.brewExecutables.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs one cleanup and returns its output (last lines). Throws when the tool is missing or fails.
    public static func run(_ id: String, home: String = NSHomeDirectory()) throws -> String {
        switch id {
        case homebrew:
            guard let brew = brew() else { throw DisklesslyError.unsupported("Homebrew is not installed") }
            return try tool(brew, ["cleanup", "--prune=all"], environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"])
        case simulatorRuntimes:
            let outdated = try tool("/usr/bin/xcrun", ["simctl", "runtime", "delete", "--outdated"])
            let unusable = try tool("/usr/bin/xcrun", ["simctl", "runtime", "delete", "--unusable"])
            return [outdated, unusable].filter { !$0.isEmpty }.joined(separator: "\n")
        case simulatorDevices:
            return try tool("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
        case derivedData:
            let folder = URL(fileURLWithPath: home).appendingPathComponent(KnownLocations.derivedData)
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for item in items { try FileManager.default.removeItem(at: item) }
            return "Removed \(items.count) item(s) from \(folder.path)"
        default:
            if DiskAdvisor.sipAssetGroups.contains(where: { $0.id == id }) {
                return try DiskAdvisor.deleteSipGroup(id)
            }
            if RebuildableCache.all.contains(where: { $0.id == id }) {
                let done = try BigItems.clean(id, home: home)
                return "Moved \(done.items) item(s) to the Trash"
            }
            throw DisklesslyError.usage("unknown cleanup: \(id)")
        }
    }

    static func tool(_ path: String, _ args: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
        guard process.terminationStatus == 0 else {
            throw DisklesslyError.failure("\((path as NSString).lastPathComponent) \(args.joined(separator: " ")) failed: \(tail)")
        }
        return tail
    }
}

/// Runs one cleanup at a time off the request thread, like `UsageScanner`.
public final class UsageCleaner {
    private let lock = NSLock()
    private var current: [String: Any] = [:]

    public init() {}

    /// False when a cleanup is already running.
    public func start(_ id: String, volume: String = "/", then: @escaping () -> Void = {}) -> Bool {
        start(id, volume: volume, work: { try UsageCleanup.run(id) }, then: then)
    }

    /// Runs `work` (a reconcile action) under the same one-at-a-time slot and status as a cleanup.
    public func start(_ id: String, volume: String = "/", work: @escaping () throws -> String, then: @escaping () -> Void = {}) -> Bool {
        lock.lock()
        if current["state"] as? String == "running" { lock.unlock(); return false }
        current = ["action": id, "state": "running"]
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            let before = Self.free(volume)
            var result: [String: Any] = ["action": id]
            do {
                result["output"] = try work()
                result["state"] = "done"
            } catch {
                result["state"] = "failed"
                result["message"] = (error as? DisklesslyError)?.errorDescription ?? String(describing: error)
            }
            let after = Self.free(volume)
            result["freedBytes"] = NSNumber(value: after > before ? after - before : 0)
            self?.lock.lock(); self?.current = result; self?.lock.unlock()
            then()
        }
        return true
    }

    public func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    static func free(_ path: String) -> UInt64 {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return UInt64(max(0, values?.volumeAvailableCapacity ?? 0))
    }
}
