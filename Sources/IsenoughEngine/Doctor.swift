import Foundation
import Dispatch
import IsenoughCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Per-check wait for `isenough doctor`. A stuck file-provider call cannot be
/// cancelled; the wait only lets the command continue and, on exit, abandon it.
public enum DoctorLimits {
    public static let defaultSeconds: TimeInterval = 15

    public static func timeout(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        guard let raw = environment["ISENOUGH_DOCTOR_TIMEOUT"], let value = TimeInterval(raw), value >= 1 else {
            return defaultSeconds
        }
        return value
    }
}

public enum DoctorFormatting {
    /// `ok` / `warn` / `fail` / `timed out`, padded so the name starts in the same column.
    public static func line(_ check: [String: Any]) -> String {
        let status = check["status"] as? String ?? ""
        let name = check["name"] as? String ?? ""
        let detail = check["detail"] as? String ?? ""
        let head = status.padding(toLength: 9, withPad: " ", startingAt: 0) + " " + name.padding(toLength: 12, withPad: " ", startingAt: 0)
        if detail.isEmpty { return head }
        return head + " " + detail
    }
}

/// `doctor` used to call `FileManager.fileExists` on the repository path on the
/// calling thread and print nothing until that returned. The default repository
/// lives in iCloud Drive. List and stat go through a bounded backend, but this
/// call did not, and the file provider can block it indefinitely when the folder
/// is slow or Files and Folders access was never granted. Disk-space (`statvfs`),
/// mount-directory listings, journal walks, and `diskutil` have the same shape,
/// so each one has its own wait.
enum Doctor {
    static func run(engine: IsenoughEngine, checkTimeout: TimeInterval, fix: Bool, onCheck: (([String: Any]) -> Void)?) -> [String: Any] {
        let seconds = checkTimeout > 0 ? checkTimeout : 0.05
        var checks: [[String: Any]] = []
        var issues: [String] = []
        var repoPresent = false
        var unpackNeedsAttention = false

        func record(_ name: String, _ status: String, _ detail: String) {
            let check: [String: Any] = ["name": name, "status": status, "detail": detail]
            checks.append(check)
            onCheck?(check)
        }

        func timedOut(_ what: String, path: String) -> String {
            let shown = seconds >= 10
                ? String(Int(seconds.rounded()))
                : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            var text = "\(what) timed out after \(shown)s. isenough cannot cancel a stuck system call; this check was abandoned. Raise the wait with ISENOUGH_DOCTOR_TIMEOUT (seconds)."
            if ICloudFolderBackend.looksLikeICloud(URL(fileURLWithPath: path)) {
                text += " " + ICloudLimits.permissionHint
            }
            return text
        }

        let config = engine.config
        let required = [config.repoPath, config.cacheDir, config.stateDir, config.mountRoot, config.stubDir]
        if required.contains(where: \.isEmpty) {
            record("config", "fail", "a required path is empty")
        } else {
            record("config", "ok", "")
        }

        if fix {
            switch bound(seconds: seconds, { try engine.gc() }) {
            case .value(let notes):
                record("fix", "ok", notes.isEmpty ? "no open journals" : notes.joined(separator: " | "))
            case .failure(let message):
                record("fix", "fail", message)
            case .timedOut:
                record("fix", "timed out", timedOut("recovery", path: config.stateDir))
            }
        }

        switch bound(seconds: seconds, { () -> (lines: [String], attention: Bool) in
            let found = engine.restore.diagnose()
            let attention = engine.unpackAttentionLines()
            return (found + attention, !attention.isEmpty)
        }) {
        case .value(let found):
            issues = found.lines
            unpackNeedsAttention = found.attention
            if found.lines.isEmpty {
                record("journals", "ok", "")
            } else {
                record("journals", "fail", found.lines.joined(separator: " | "))
            }
        case .failure(let message):
            record("journals", "fail", message)
        case .timedOut:
            record("journals", "timed out", timedOut("journal diagnosis", path: config.stateDir))
        }

        let repoStatus = repositoryCheck(engine: engine, seconds: seconds, record: record, timedOut: timedOut)
        repoPresent = repoStatus == "ok"

        if repoStatus != "ok" {
            let why = repoStatus == "timed out" ? "the repository check timed out" : "the repository path was not confirmed"
            record("backend", "warn", "skipped because \(why)")
            record("conflicts", "warn", "skipped because \(why)")
            record("materialized", "warn", "skipped because \(why)")
        } else {
            backendCheck(engine: engine, seconds: seconds, record: record, timedOut: timedOut)
            switch bound(seconds: seconds, {
                engine.syncReport()
            }) {
            case .value(let report):
                record("conflicts", report.status, report.detail)
            case .failure(let message):
                record("conflicts", "fail", message)
            case .timedOut:
                record("conflicts", "timed out", timedOut("checking iCloud conflict copies", path: config.repoPath))
            }
            switch bound(seconds: seconds, { engine.materialSummary() }) {
            case .value(let summary):
                record("materialized", summary.status, summary.detail)
            case .failure(let message):
                record("materialized", "fail", message)
            case .timedOut:
                record("materialized", "timed out", timedOut("reading which repo files are stored locally", path: config.repoPath))
            }
        }

        freeSpaceCheck(config: config, seconds: seconds, record: record, timedOut: timedOut)
        mountCheck(config: config, seconds: seconds, record: record, timedOut: timedOut)
        engineCheck(engine: engine, seconds: seconds, record: record, timedOut: timedOut)
        diskImageCheck(seconds: seconds, record: record)

        let failed = checks.contains { check in
            let status = check["status"] as? String
            return status == "fail" || status == "timed out"
        }
        var report: [String: Any] = [
            "ok": !failed,
            "needsAttention": unpackNeedsAttention,
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "repo": repoPresent,
            "issues": issues,
            "checks": checks,
        ]
        if repoPresent, let hint = IconBackfill.doctorHint(missing: engine.missingIconCount()) {
            report["iconHint"] = hint
        }
        return report
    }

    private static func repositoryCheck(engine: IsenoughEngine, seconds: TimeInterval, record: (String, String, String) -> Void, timedOut: (String, String) -> String) -> String {
        let path = engine.config.repoPath
        if path.isEmpty {
            record("repo", "fail", "repository path is empty")
            return "fail"
        }
        let probe = engine.doctorRepositoryProbe
        switch bound(seconds: seconds, { () -> String in
            if let probe {
                return probe(path) ? "directory" : "missing"
            }
            var isDir = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return "missing" }
            return isDir.boolValue ? "directory" : "file"
        }) {
        case .value("directory"):
            record("repo", "ok", path)
            return "ok"
        case .value("missing"):
            record("repo", "warn", "repository path is missing: \(path)")
            return "warn"
        case .value(_):
            record("repo", "fail", "repository path is not a directory: \(path)")
            return "fail"
        case .failure(let message):
            record("repo", "fail", message)
            return "fail"
        case .timedOut:
            record("repo", "timed out", timedOut("checking repository \(path)", path))
            return "timed out"
        }
    }

    private static func backendCheck(engine: IsenoughEngine, seconds: TimeInterval, record: (String, String, String) -> Void, timedOut: (String, String) -> String) {
        let path = engine.config.repoPath
        if let id = engine.config.activeBackendId,
           let endpoint = engine.config.backends.first(where: { $0.id == id }),
           ["smb", "nfs", "webdav", "openlist"].contains(endpoint.type) {
            switch bound(seconds: seconds, { () -> String in
                let backend = try engine.openBackend()
                if try backend.stat("repo.json") != nil {
                    return "ok"
                }
                return "missing"
            }) {
            case .value("ok"):
                record("backend", "ok", "\(endpoint.type) \(endpoint.id) has repo.json")
            case .value(_):
                record("backend", "warn", "repo.json is not in the \(endpoint.type) backend \(endpoint.id)")
            case .failure(let message):
                record("backend", "fail", message)
            case .timedOut:
                record("backend", "timed out", timedOut("checking backend \(endpoint.type) \(endpoint.id)", endpoint.mountPoint ?? path))
            }
            return
        }
        let repoJSON = URL(fileURLWithPath: path).appendingPathComponent("repo.json").path
        switch bound(seconds: seconds, { FileManager.default.fileExists(atPath: repoJSON) }) {
        case .value(true):
            record("backend", "ok", "repo.json")
        case .value(false):
            record("backend", "warn", "repo.json is not in the repository")
        case .failure(let message):
            record("backend", "fail", message)
        case .timedOut:
            record("backend", "timed out", timedOut("checking repo.json", path))
        }
    }

    private static func freeSpaceCheck(config: RuntimeConfig, seconds: TimeInterval, record: (String, String, String) -> Void, timedOut: (String, String) -> String) {
        let cacheDir = config.cacheDir
        if cacheDir.isEmpty {
            record("free-space", "fail", "cache directory is not set")
            return
        }
        switch bound(seconds: seconds, { try readFreeSpace(cacheDir) }) {
        case .value(let reading):
            let free = byteText(reading.bytes)
            let floor = byteText(config.minFreeBytes)
            if reading.cacheMissing {
                record("free-space", "warn", "cache directory is missing; volume has \(free) free, floor \(floor)")
            } else if reading.bytes < config.minFreeBytes {
                record("free-space", "warn", "\(free) free is below the \(floor) floor")
            } else {
                record("free-space", "ok", "\(free) free; floor \(floor)")
            }
        case .failure(let message):
            record("free-space", "fail", message)
        case .timedOut:
            record("free-space", "timed out", timedOut("reading free space at \(cacheDir)", cacheDir))
        }
    }

    private static func mountCheck(config: RuntimeConfig, seconds: TimeInterval, record: (String, String, String) -> Void, timedOut: (String, String) -> String) {
        let mountRoot = config.mountRoot
        if mountRoot.isEmpty {
            record("mounts", "fail", "mount root is not set")
            return
        }
        switch bound(seconds: seconds, { try mountCount(mountRoot) }) {
        case .value(let count):
            if let count {
                record("mounts", "ok", "\(count) entries")
            } else {
                record("mounts", "warn", "mount root is missing: \(mountRoot)")
            }
        case .failure(let message):
            record("mounts", "fail", message)
        case .timedOut:
            record("mounts", "timed out", timedOut("listing mounts at \(mountRoot)", mountRoot))
        }
    }

    /// Missing or older than this CLI is a warning. `doctor` still exits 0.
    private static func engineCheck(engine: IsenoughEngine, seconds: TimeInterval, record: (String, String, String) -> Void, timedOut: (String, String) -> String) {
        switch bound(seconds: seconds, { engine.engineWarnings() }) {
        case .value(let lines):
            if lines.isEmpty {
                record("engine", "ok", EngineInstall.binary(stateDir: engine.config.stateDir).path)
            } else {
                record("engine", "warn", lines.joined(separator: " | "))
            }
        case .failure(let message):
            record("engine", "warn", message)
        case .timedOut:
            record("engine", "warn", timedOut("checking the installed engine", engine.config.stateDir))
        }
    }

    private static func diskImageCheck(seconds: TimeInterval, record: (String, String, String) -> Void) {
        #if os(macOS)
        let diskutil = DiskImageTool.diskutil
        let hdiutil = DiskImageTool.hdiutil
        let diskutilExists = FileManager.default.isExecutableFile(atPath: diskutil)
        let hdiutilExists = FileManager.default.isExecutableFile(atPath: hdiutil)
        if !diskutilExists && !hdiutilExists {
            record("disk-image", "fail", "hdiutil and diskutil are missing")
            return
        }
        if diskutilExists {
            switch commandStatus(path: diskutil, arguments: ["image", "--help"], seconds: seconds) {
            case .value(0):
                record("disk-image", "ok", "diskutil image is available")
                return
            case .value(_):
                if hdiutilExists {
                    record("disk-image", "warn", "diskutil image is unavailable; hdiutil is available")
                } else {
                    record("disk-image", "fail", "diskutil image is unavailable and hdiutil is missing")
                }
                return
            case .failure(let message):
                record("disk-image", "fail", message)
                return
            case .timedOut:
                record("disk-image", "timed out", "diskutil image --help timed out after \(Int(seconds.rounded()))s. The help text was not read. Raise the wait with ISENOUGH_DOCTOR_TIMEOUT (seconds).")
                return
            }
        }
        record("disk-image", "ok", "hdiutil is available")
        #else
        _ = seconds
        record("disk-image", "warn", "disk image tools are not available on this platform")
        #endif
    }

    private struct FreeReading {
        var bytes: UInt64
        var cacheMissing: Bool
    }

    private static func readFreeSpace(_ cacheDir: String) throws -> FreeReading {
        var isDir = ObjCBool(false)
        if FileManager.default.fileExists(atPath: cacheDir, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw IsenoughError.failure("cache directory is not a directory: \(cacheDir)")
            }
            return FreeReading(bytes: try VolumeSpace.availableBytes(at: cacheDir), cacheMissing: false)
        }
        // A cache directory that has never been created should not fail the command.
        // Walk up to a path that exists and read that volume.
        var candidate = URL(fileURLWithPath: cacheDir).deletingLastPathComponent()
        while candidate.path != "/" && !FileManager.default.fileExists(atPath: candidate.path) {
            candidate.deleteLastPathComponent()
        }
        return FreeReading(bytes: try VolumeSpace.availableBytes(at: candidate.path), cacheMissing: true)
    }

    /// `nil` means the mount root is absent. A present directory returns its entry count.
    private static func mountCount(_ mountRoot: String) throws -> Int? {
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: mountRoot, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { throw IsenoughError.failure("mount root is not a directory: \(mountRoot)") }
        return try FileManager.default.contentsOfDirectory(atPath: mountRoot).count
    }

    private static func byteText(_ value: UInt64) -> String {
        let gib = 1024.0 * 1024.0 * 1024.0
        let mib = 1024.0 * 1024.0
        if value >= UInt64(gib) {
            return String(format: "%.1f GiB", locale: Locale(identifier: "en_US_POSIX"), Double(value) / gib)
        }
        if value >= UInt64(mib) {
            return String(format: "%.1f MiB", locale: Locale(identifier: "en_US_POSIX"), Double(value) / mib)
        }
        return "\(value) B"
    }

    #if os(macOS)
    /// Exit status only. stdout and stderr are discarded so a localized help sentence is never parsed.
    private static func commandStatus(path: String, arguments: [String], seconds: TimeInterval) -> Bound<Int32> {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure("missing \(path)")
        }
        let process = ParsedCommand.process(path: path, arguments: arguments)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        for pipe in [stdoutPipe, stderrPipe] {
            DispatchQueue.global(qos: .utility).async {
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
            }
        }
        do {
            try process.run()
        } catch {
            return .failure("could not start \(path): \(error.localizedDescription)")
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return .timedOut
        }
        return .value(process.terminationStatus)
    }
    #endif
}

private enum Bound<T> {
    case value(T)
    case failure(String)
    case timedOut
}

private final class BoundBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func store(_ result: Result<T, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }
    func take() -> Result<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        return value ?? .failure(IsenoughError.failure("missing bounded-call result"))
    }
}

private func bound<T>(seconds: TimeInterval, _ work: @escaping () throws -> T) -> Bound<T> {
    let box = BoundBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.store(Result { try work() })
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + seconds) == .timedOut {
        return .timedOut
    }
    switch box.take() {
    case .success(let value):
        return .value(value)
    case .failure(let error):
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .failure(text)
    }
}
