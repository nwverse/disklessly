import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ICloudLimits {
    public static let permissionHint = "A process started from Finder or LaunchServices can block inside the iCloud file provider when Files and Folders access has not been granted, and macOS may never show the permission prompt. Grant the app access to this folder in System Settings → Privacy & Security → Files and Folders. If the repo is outside your home folder, also grant Full Disk Access. disklessly cannot cancel a stuck system call; a timeout only unblocks the caller."

    public static func listTimeout(fallback: TimeInterval = 20) -> TimeInterval {
        seconds(from: "DISKLESSLY_ICLOUD_LIST_TIMEOUT", fallback: fallback)
    }

    public static func downloadTimeout(fallback: TimeInterval = 900) -> TimeInterval {
        seconds(from: "DISKLESSLY_ICLOUD_DOWNLOAD_TIMEOUT", fallback: fallback)
    }

    /// Device files, catalog JSON, and other metadata. Listing must not wait out a full image download.
    public static func metadataTimeout(fallback: TimeInterval = 20) -> TimeInterval {
        seconds(from: "DISKLESSLY_ICLOUD_METADATA_TIMEOUT", fallback: fallback)
    }

    /// `devices/`, `catalog/`, and any `.json` object use `metadata`. Disk images keep `download`.
    public static func readTimeout(path: String, download: TimeInterval, metadata: TimeInterval) -> TimeInterval {
        isMetadataPath(path) ? metadata : download
    }

    public static func isMetadataPath(_ path: String) -> Bool {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if trimmed == "devices" || trimmed.hasPrefix("devices/") { return true }
        if trimmed == "catalog" || trimmed.hasPrefix("catalog/") { return true }
        return trimmed.hasSuffix(".json")
    }

    public static func timeoutMessage(what: String, seconds: TimeInterval) -> String {
        "\(what) timed out after \(Int(seconds))s. \(permissionHint) If the folder is only slow, raise the wait with DISKLESSLY_ICLOUD_LIST_TIMEOUT (seconds)."
    }

    private static func seconds(from key: String, fallback: TimeInterval) -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment[key], let value = TimeInterval(raw), value >= 1 {
            return value
        }
        return fallback
    }
}

enum BlockingCall {
    static func run<T>(seconds: TimeInterval, what: String, _ work: @escaping () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.store(Result { try work() })
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            throw DisklesslyError.backend(ICloudLimits.timeoutMessage(what: what, seconds: seconds))
        }
        return try box.take()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func store(_ result: Result<T, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }
    func take() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let value else { throw DisklesslyError.failure("missing bounded-call result") }
        return try value.get()
    }
}

public struct UbiquitySnapshot: Equatable {
    public var isUbiquitous: Bool
    public var status: String?
    public var downloading: Bool
    public init(isUbiquitous: Bool, status: String?, downloading: Bool) {
        self.isUbiquitous = isUbiquitous
        self.status = status
        self.downloading = downloading
    }
}

public enum UbiquitousMaterializer {
    private static let budgetKey = "io.github.s546126.disklessly.icloud-budget"

    /// Caps every ubiquitous read inside `body` to `seconds`, and a nested call cannot extend that deadline.
    /// Read-only commands use this so a listing cannot sit on iCloud longer than the metadata timeout.
    public static func withBudget<T>(_ seconds: TimeInterval, _ body: () throws -> T) rethrows -> T {
        let thread = Thread.current
        let previous = thread.threadDictionary[budgetKey] as? Date
        let proposed = Date().addingTimeInterval(max(0, seconds))
        thread.threadDictionary[budgetKey] = min(previous ?? proposed, proposed)
        defer {
            if let previous {
                thread.threadDictionary[budgetKey] = previous
            } else {
                thread.threadDictionary.removeObject(forKey: budgetKey)
            }
        }
        return try body()
    }

    /// `requested`, or whatever remains of the current listing budget.
    public static func cappedTimeout(_ requested: TimeInterval, now: Date = Date()) -> TimeInterval {
        guard let deadline = Thread.current.threadDictionary[budgetKey] as? Date else { return requested }
        return min(requested, max(0, deadline.timeIntervalSince(now)))
    }

    /// `current` and `downloaded` are already local. Anything else on a ubiquitous item needs a download.
    public static func needsDownload(isUbiquitous: Bool, status: String?) -> Bool {
        guard isUbiquitous else { return false }
        switch status {
        case "current", "downloaded": return false
        default: return true
        }
    }

    /// Polls `probe` on every iteration. `start` runs once, and only when the first snapshot still needs a download.
    /// A stalled item returns a warning instead of waiting past `timeout`. Nil means the item is local or not in iCloud.
    public static func wait(
        name: String,
        timeout: TimeInterval,
        interval: TimeInterval = 0.25,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        start: () throws -> Void,
        probe: () throws -> UbiquitySnapshot
    ) throws -> String? {
        let initial = try probe()
        guard initial.isUbiquitous, needsDownload(isUbiquitous: true, status: initial.status) else { return nil }
        try start()
        let started = now()
        var last = describe(initial)
        while now().timeIntervalSince(started) < timeout {
            let remaining = timeout - now().timeIntervalSince(started)
            if remaining <= 0 { break }
            sleep(min(interval, remaining))
            let values = try probe()
            last = describe(values)
            if !needsDownload(isUbiquitous: values.isUbiquitous, status: values.status) { return nil }
        }
        return "iCloud item \(name) was not downloaded within \(Int(timeout))s (\(last)). \(ICloudLimits.permissionHint)"
    }

    static func beforeRead(_ url: URL, path: String, downloadTimeout: TimeInterval, metadataTimeout: TimeInterval, enabled: Bool) throws {
        guard enabled else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let timeout = cappedTimeout(ICloudLimits.readTimeout(path: path, download: downloadTimeout, metadata: metadataTimeout))
        #if os(macOS)
        let warning = try wait(name: url.lastPathComponent, timeout: timeout, start: {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }, probe: {
            try snapshot(url)
        })
        if var warning {
            if ICloudLimits.isMetadataPath(path) {
                warning += " Metadata reads stop after the short timeout. Raise it with DISKLESSLY_ICLOUD_METADATA_TIMEOUT (seconds)."
            } else {
                warning += " Raise the wait with DISKLESSLY_ICLOUD_DOWNLOAD_TIMEOUT (seconds)."
            }
            FileHandle.standardError.write(Data("disklessly: \(warning)\n".utf8))
            throw DisklesslyError.backend(warning)
        }
        #else
        _ = (timeout, path)
        #endif
    }

    private static func describe(_ snapshot: UbiquitySnapshot) -> String {
        let status = snapshot.status ?? "unknown"
        let downloading = snapshot.downloading ? "yes" : "no"
        return "status=\(status), downloading=\(downloading)"
    }

    #if os(macOS)
    /// A new URL plus `removeAllCachedResourceValues()` so a cached `notDownloaded` cannot hide a later `current`.
    private static func snapshot(_ url: URL) throws -> UbiquitySnapshot {
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        let values: URLResourceValues
        do {
            values = try fresh.resourceValues(forKeys: keys)
        } catch {
            throw DisklesslyError.backend("could not read iCloud metadata for \(url.lastPathComponent): \(error.localizedDescription). \(ICloudLimits.permissionHint)")
        }
        let status: String?
        if values.ubiquitousItemDownloadingStatus == .current { status = "current" }
        else if values.ubiquitousItemDownloadingStatus == .downloaded { status = "downloaded" }
        else if values.ubiquitousItemDownloadingStatus == .notDownloaded { status = "notDownloaded" }
        else { status = nil }
        return UbiquitySnapshot(isUbiquitous: values.isUbiquitousItem == true, status: status, downloading: values.ubiquitousItemIsDownloading == true)
    }
    #endif
}

/// File-backed repository that may live in iCloud Drive. Listings are bounded so a
/// LaunchServices-spawned process cannot sit forever inside the file provider.
/// Reads of evicted ubiquitous items start a download and wait, with a timeout.
public struct ICloudFolderBackend: StorageBackend {
    public let root: URL
    private let folder: LocalFolderBackend

    public init(root: URL) throws {
        let url = root.standardizedFileURL
        self.root = url
        var configured = try LocalFolderBackend(root: url)
        configured.boundsListing = true
        configured.materializeReads = true
        configured.listTimeout = ICloudLimits.listTimeout()
        configured.materializeTimeout = ICloudLimits.downloadTimeout()
        configured.metadataTimeout = ICloudLimits.metadataTimeout()
        self.folder = configured
    }

    public static func looksLikeICloud(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Mobile Documents/") || path.contains("com~apple~CloudDocs")
    }

    public func list(_ path: String) throws -> [String] { try folder.list(path) }
    public func entries(_ path: String) throws -> [BackendEntry] { try folder.entries(path) }
    public func stat(_ path: String) throws -> BackendStat? { try folder.stat(path) }
    public func get(_ path: String, range: Range<UInt64>?) throws -> Data { try folder.get(path, range: range) }
    public func put(_ path: String, data: Data) throws { try folder.put(path, data: data) }
    public func put(_ path: String, file: URL) throws { try folder.put(path, file: file) }
    public func delete(_ path: String) throws { try folder.delete(path) }
    public func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody { try folder.getResumable(path, offset: offset) }
    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        try folder.download(path, to: destination, offset: offset)
    }
    public func localRoot() -> URL? { folder.localRoot() }
    public func ensureCollection(_ path: String) throws { try folder.ensureCollection(path) }
}
