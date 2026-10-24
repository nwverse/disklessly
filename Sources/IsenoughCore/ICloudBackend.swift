import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ICloudLimits {
    public static let permissionHint = "A process started from Finder or LaunchServices can block inside the iCloud file provider when Files and Folders access has not been granted, and macOS may never show the permission prompt. Grant the app access to this folder in System Settings → Privacy & Security → Files and Folders. If the repo is outside your home folder, also grant Full Disk Access. isenough cannot cancel a stuck system call; a timeout only unblocks the caller."

    public static func listTimeout(fallback: TimeInterval = 20) -> TimeInterval {
        seconds(from: "ISENOUGH_ICLOUD_LIST_TIMEOUT", fallback: fallback)
    }

    public static func downloadTimeout(fallback: TimeInterval = 900) -> TimeInterval {
        seconds(from: "ISENOUGH_ICLOUD_DOWNLOAD_TIMEOUT", fallback: fallback)
    }

    public static func timeoutMessage(what: String, seconds: TimeInterval) -> String {
        "\(what) timed out after \(Int(seconds))s. \(permissionHint) If the folder is only slow, raise the wait with ISENOUGH_ICLOUD_LIST_TIMEOUT (seconds)."
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
            throw IsenoughError.backend(ICloudLimits.timeoutMessage(what: what, seconds: seconds))
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
        guard let value else { throw IsenoughError.failure("missing bounded-call result") }
        return try value.get()
    }
}

enum UbiquitousMaterializer {
    /// `current` and `downloaded` are already local. Anything else on a ubiquitous item needs a download.
    static func needsDownload(isUbiquitous: Bool, status: String?) -> Bool {
        guard isUbiquitous else { return false }
        switch status {
        case "current", "downloaded": return false
        default: return true
        }
    }

    static func beforeRead(_ url: URL, timeout: TimeInterval, enabled: Bool) throws {
        guard enabled else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        #if os(macOS)
        try waitUntilDownloaded(url, timeout: timeout)
        #else
        _ = timeout
        #endif
    }

    #if os(macOS)
    private static func waitUntilDownloaded(_ url: URL, timeout: TimeInterval) throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        let initial: URLResourceValues
        do {
            initial = try url.resourceValues(forKeys: keys)
        } catch {
            throw IsenoughError.backend("could not read iCloud metadata for \(url.lastPathComponent): \(error.localizedDescription). \(ICloudLimits.permissionHint)")
        }
        guard initial.isUbiquitousItem == true else { return }
        if isLocal(initial.ubiquitousItemDownloadingStatus) { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw IsenoughError.backend("could not start downloading iCloud item \(url.lastPathComponent): \(error.localizedDescription). \(ICloudLimits.permissionHint)")
        }
        let started = Date()
        var last = describe(initial)
        while Date().timeIntervalSince(started) < timeout {
            Thread.sleep(forTimeInterval: 0.25)
            let values = try url.resourceValues(forKeys: keys)
            last = describe(values)
            if isLocal(values.ubiquitousItemDownloadingStatus) { return }
        }
        throw IsenoughError.backend("iCloud item \(url.lastPathComponent) was not downloaded within \(Int(timeout))s (\(last)). \(ICloudLimits.permissionHint) Raise the wait with ISENOUGH_ICLOUD_DOWNLOAD_TIMEOUT (seconds).")
    }

    private static func isLocal(_ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        status == .current || status == .downloaded
    }

    private static func describe(_ values: URLResourceValues) -> String {
        let status: String
        if values.ubiquitousItemDownloadingStatus == .current { status = "current" }
        else if values.ubiquitousItemDownloadingStatus == .downloaded { status = "downloaded" }
        else if values.ubiquitousItemDownloadingStatus == .notDownloaded { status = "notDownloaded" }
        else { status = "unknown" }
        let downloading = values.ubiquitousItemIsDownloading == true ? "yes" : "no"
        return "status=\(status), downloading=\(downloading)"
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
        self.folder = configured
    }

    public static func looksLikeICloud(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Mobile Documents/") || path.contains("com~apple~CloudDocs")
    }

    public func list(_ path: String) throws -> [String] { try folder.list(path) }
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
