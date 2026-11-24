import Foundation
import DisklesslyCore

// MARK: - Command runner

/// What a system tool printed and how it exited.
public struct SystemCommandResult: Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

/// Every call to `tmutil`, `mdutil`, `osascript` (administrator prompts), `lsof` and `du` made by the
/// hidden-usage reconciliation goes through one of these. Tests inject a recording fake, so they never
/// reach the real binaries: a stray `mdutil -E` would reindex the whole Mac.
public protocol SystemCommandRunner: AnyObject {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> SystemCommandResult
}

/// Runs the real tools. Inside an XCTest process it refuses every command that changes the system
/// (`mdutil` other than `-s`, `tmutil` other than listing, administrator `osascript`, `sudo`), as a
/// backstop in case a test forgets to inject a fake runner.
public final class LiveSystemCommandRunner: SystemCommandRunner {
    public static let shared = LiveSystemCommandRunner()
    public init() {}

    public static var insideTests: Bool {
        if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil { return true }
        // swift-corelibs: the test bundle runs as `<Package>PackageTests.xctest`; Xcode runs `xctest`.
        let process = ProcessInfo.processInfo.processName
        return process == "xctest" || process.hasSuffix(".xctest") || (CommandLine.arguments.first ?? "").hasSuffix(".xctest")
    }

    /// True for argv that change the system or ask for administrator rights.
    public static func changesSystem(_ executable: String, _ arguments: [String]) -> Bool {
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "mdutil":
            // Read-only only as a status query: `-s` (optionally `-v`) and volume paths.
            let flags = arguments.filter { $0.hasPrefix("-") }
            return !(flags.contains("-s") && flags.allSatisfy { $0 == "-s" || $0 == "-v" })
        case "tmutil": return !["listlocalsnapshots", "listlocalsnapshotdates", "version"].contains(arguments.first ?? "")
        case "osascript": return arguments.joined(separator: " ").contains("administrator privileges")
        case "sudo", "rm": return true
        default: return false
        }
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> SystemCommandResult {
        if Self.insideTests && Self.changesSystem(executable, arguments) {
            return SystemCommandResult(status: 126, stderr: "refused inside tests: \(executable) \(arguments.joined(separator: " "))")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return SystemCommandResult(status: 127, stderr: "could not start \(executable): \(error.localizedDescription)")
        }
        let box = Collected()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.set(data, out: isOut)
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        let (o, e) = box.get()
        return SystemCommandResult(status: process.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(_ data: Data, out isOut: Bool) { lock.lock(); if isOut { out = data } else { err = data }; lock.unlock() }
        func get() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }
}

// MARK: - Facts

/// The Spotlight index size measured once with an administrator prompt, kept in the state folder.
public struct SpotlightMeasurement: Equatable {
    public var bytes: UInt64
    public var measuredAt: Date
    public init(bytes: UInt64, measuredAt: Date) { self.bytes = bytes; self.measuredAt = measuredAt }
}

/// What a usage scan can learn about the space it could not measure folder by folder.
public struct HiddenUsageFacts: Equatable {
    /// `volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity`: what macOS would free on
    /// demand. Local snapshots are part of it, and so are caches and iCloud files `du` already counted.
    public var purgeableBytes: UInt64 = 0
    /// `tmutil listlocalsnapshots /` names (per-snapshot size is not available).
    public var snapshots: [String] = []
    /// Other users' home folders and /Users/Shared, sized only where readable.
    public var otherUsers: [UsageInputs.Entry] = []
    /// Folders the scan could not read (permission denied / Full Disk Access). They have no size.
    public var unreadable: [String] = []
    public var spotlight: SpotlightMeasurement?
    /// Filled by `UsageMap.assemble`: the used bytes of the disk and the gap the breakdown explains.
    public var usedBytes: UInt64 = 0
    public var gapBytes: UInt64 = 0
    public init() {}

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "purgeableBytes": NSNumber(value: purgeableBytes),
            "snapshots": snapshots,
            "otherUsers": otherUsers.map { ["name": $0.name, "path": $0.path ?? "", "bytes": NSNumber(value: $0.bytes)] as [String: Any] },
            "unreadable": unreadable,
            "usedBytes": NSNumber(value: usedBytes),
            "gapBytes": NSNumber(value: gapBytes),
            "spotlightPath": HiddenUsage.spotlightStore,
            "spotlightThresholdBytes": NSNumber(value: HiddenUsage.spotlightThreshold(usedBytes: usedBytes)),
        ]
        if let spotlight {
            object["spotlightBytes"] = NSNumber(value: spotlight.bytes)
            object["spotlightMeasuredAt"] = NSNumber(value: Int64(spotlight.measuredAt.timeIntervalSince1970))
        }
        return object
    }
}

/// One child box of "Not measured".
public struct HiddenUsagePart: Equatable {
    public var key: String
    public var name: String
    public var bytes: UInt64
    /// A `HiddenUsage` action offered on this box (never a `UsageCleanup` id, so no bulk path runs it).
    public var reconcile: String?
    public var children: [HiddenUsagePart] = []
    public var path: String?
}

// MARK: - Reconciliation

public enum HiddenUsage {
    /// Where the Data volume keeps its Spotlight index. root:_mds_stores drwx--x---: only root can size it.
    public static let spotlightStore = "/System/Volumes/Data/.Spotlight-V100"
    /// The volume `mdutil -E` erases and rebuilds. `mdutil -s -v` reports the same store (same scan base
    /// time) for `/` and `/System/Volumes/Data`; the Data volume is the one that holds `spotlightStore`.
    public static let spotlightVolume = "/System/Volumes/Data"
    /// An index is "abnormally large" above max(20 GiB, 5% of used space). A healthy index is a few GB
    /// even on a full 1 TB disk (roughly 1–3% of indexed data); corrupted ones grow to 100+ GB.
    public static let spotlightFloorBytes: UInt64 = 20 << 30
    public static let spotlightUsedPercent: UInt64 = 5
    /// A cached Spotlight measurement older than this is not used.
    public static let spotlightMaxAge: TimeInterval = 7 * 86_400
    /// At most this many other-user folders are sized, each within `otherUserTimeout`.
    public static let maxOtherUsers = 12
    public static let otherUserTimeout: TimeInterval = 30
    /// At most this many unreadable folders are listed.
    public static let maxUnreadable = 40

    public static let thinSnapshots = "thin-snapshots"
    public static let measureSpotlight = "spotlight-measure"
    public static let rebuildSpotlight = "spotlight-rebuild"
    public static let modelTrashPrefix = "model-trash:"
    public static let modelOffloadPrefix = "model-offload:"

    /// The actions `perform` accepts. None of them is a `UsageCleanup` id.
    public static func isAction(_ action: String) -> Bool {
        if [thinSnapshots, measureSpotlight, rebuildSpotlight].contains(action) { return true }
        for prefix in [modelTrashPrefix, modelOffloadPrefix] where action.hasPrefix(prefix) {
            return AIModelLocations.location(id: String(action.dropFirst(prefix.count))) != nil
        }
        return false
    }

    public static func spotlightThreshold(usedBytes: UInt64) -> UInt64 {
        max(spotlightFloorBytes, usedBytes / 100 * spotlightUsedPercent)
    }

    public static func spotlightAbnormal(_ bytes: UInt64, usedBytes: UInt64) -> Bool {
        bytes > spotlightThreshold(usedBytes: usedBytes)
    }

    /// Splits `gap` (used − measured) into explained parts. The parts always add up to `gap`.
    ///
    /// Order: exactly measured first (other users, a measured Spotlight index), then the estimate
    /// (purgeable space, only when local snapshots exist: without snapshots purgeable space is mostly
    /// caches and iCloud files the folder scan already counted, so it must not hide the remainder).
    /// Whatever is left is "likely the Spotlight index" until the index is measured, then "unexplained".
    public static func breakdown(gap: UInt64, facts: HiddenUsageFacts) -> [HiddenUsagePart] {
        var remaining = gap
        func take(_ bytes: UInt64) -> UInt64 { let taken = min(remaining, bytes); remaining -= taken; return taken }
        var parts: [HiddenUsagePart] = []

        var users: [HiddenUsagePart] = []
        for user in facts.otherUsers.sorted(by: { $0.bytes > $1.bytes }) {
            let bytes = take(user.bytes)
            if bytes > 0 { users.append(HiddenUsagePart(key: "otheruser", name: user.name, bytes: bytes, path: user.path)) }
        }
        if !users.isEmpty {
            parts.append(HiddenUsagePart(key: "otherusers", name: "Other users", bytes: users.reduce(0) { $0 + $1.bytes }, children: users))
        }
        if let spotlight = facts.spotlight {
            let bytes = take(spotlight.bytes)
            if bytes > 0 {
                let abnormal = spotlightAbnormal(spotlight.bytes, usedBytes: facts.usedBytes)
                parts.append(HiddenUsagePart(key: "spotlight", name: "Spotlight index", bytes: bytes, reconcile: abnormal ? rebuildSpotlight : nil, path: spotlightStore))
            }
        }
        if !facts.snapshots.isEmpty {
            let bytes = take(facts.purgeableBytes)
            if bytes > 0 { parts.append(HiddenUsagePart(key: "snapshots", name: "Local snapshots and purgeable space", bytes: bytes, reconcile: thinSnapshots)) }
        }
        if remaining > 0 {
            if facts.spotlight == nil {
                // Folders the scan could not read have no size, so they share this remainder with the index.
                let name = facts.unreadable.isEmpty ? "Likely Spotlight index" : "Likely Spotlight index and unreadable folders"
                parts.append(HiddenUsagePart(key: "spotlight-likely", name: name, bytes: remaining, reconcile: measureSpotlight))
            } else {
                parts.append(HiddenUsagePart(key: "unexplained", name: facts.unreadable.isEmpty ? "Unexplained" : "Unreadable folders and other system data", bytes: remaining))
            }
        }
        return parts
    }

    static func node(_ part: HiddenUsagePart) -> UsageNode {
        var node = part.children.isEmpty
            ? UsageNode(name: part.name, key: part.key, kind: .system, bytes: part.bytes)
            : UsageNode.group(name: part.name, key: part.key, kind: .system, part.children.map(node))
        node.reconcile = part.reconcile
        // No `path`: the map must never offer Offload or Delete on another user's home or the index.
        return node
    }

    // MARK: Command lines

    public static let tmutil = "/usr/bin/tmutil"
    public static let osascript = "/usr/bin/osascript"
    public static let lsof = "/usr/sbin/lsof"
    public static let du = "/usr/bin/du"

    public static func listSnapshotsCommand() -> (String, [String]) { (tmutil, ["listlocalsnapshots", "/"]) }

    /// `tmutil thinlocalsnapshots / <bytes> 4`: asks macOS to reclaim up to `bytes` by thinning local
    /// snapshots at the highest urgency. No root needed (tmutil(8) marks only other verbs as root).
    /// It deletes only snapshots, never files.
    public static func thinSnapshotsCommand(bytes: UInt64) -> (String, [String]) {
        (tmutil, ["thinlocalsnapshots", "/", String(max(bytes, 1)), "4"])
    }

    /// One administrator prompt that runs `du -skx` on the Spotlight store and prints its size.
    public static func measureSpotlightCommand() -> (String, [String]) {
        (osascript, ["-e", "do shell script \"/usr/bin/du -skx \" & quoted form of \(AdminShell.appleString(spotlightStore)) with administrator privileges"])
    }

    /// One administrator prompt that runs `mdutil -E` on the Data volume (erase and rebuild its index).
    public static func rebuildSpotlightCommand() -> (String, [String]) {
        (osascript, ["-e", "do shell script \"/usr/bin/mdutil -E \" & quoted form of \(AdminShell.appleString(spotlightVolume)) with administrator privileges"])
    }

    public static func openFilesCommand() -> (String, [String]) { (lsof, ["-n", "-w", "-F", "n"]) }

    static func sizeCommand(_ path: String) -> (String, [String]) { (du, ["-skx", path]) }

    // MARK: Parsing

    /// Snapshot names from `tmutil listlocalsnapshots /` ("Snapshots for disk /:" then one per line).
    public static func parseSnapshots(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for") && !$0.hasSuffix(":") }
    }

    /// Kilobytes on the first line of `du -sk` output, as bytes.
    public static func parseDU(_ output: String) -> UInt64? {
        guard let line = output.split(whereSeparator: \.isNewline).first,
              let kb = UInt64(line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") else { return nil }
        return kb * 1024
    }

    /// osascript exits 1 with error -128 when the user cancels the administrator prompt.
    public static func isCancelled(_ result: SystemCommandResult) -> Bool {
        result.status != 0 && result.stderr.contains("-128")
    }

    /// Paths du could not read (`du: <path>: Permission denied` / `Operation not permitted`).
    public static func parseDenied(_ stderr: String) -> [String] {
        stderr.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard line.hasSuffix(": Permission denied") || line.hasSuffix(": Operation not permitted") else { return nil }
            var body = line
            if body.hasPrefix("du: ") { body.removeFirst(4) }
            guard let colon = body.range(of: ": ", options: .backwards) else { return nil }
            let path = String(body[..<colon.lowerBound])
            return path.hasPrefix("/") ? path : nil
        }
    }

    /// Keeps the shallowest folders only (a denied folder hides everything below it), capped.
    static func collapseDenied(_ paths: [String]) -> [String] {
        var kept: [String] = []
        for path in Set(paths).sorted() where !kept.contains(where: { path.hasPrefix($0 + "/") }) {
            kept.append(path)
            if kept.count >= maxUnreadable { break }
        }
        return kept
    }

    // MARK: Spotlight cache

    static func spotlightCacheURL(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("spotlight-index.json")
    }

    public static func loadSpotlight(stateDir: String, now: Date = Date()) -> SpotlightMeasurement? {
        guard let data = try? Data(contentsOf: spotlightCacheURL(stateDir: stateDir)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bytes = (object["bytes"] as? NSNumber)?.uint64Value,
              let at = (object["measuredAt"] as? NSNumber)?.doubleValue else { return nil }
        let date = Date(timeIntervalSince1970: at)
        guard now.timeIntervalSince(date) <= spotlightMaxAge else { return nil }
        return SpotlightMeasurement(bytes: bytes, measuredAt: date)
    }

    static func saveSpotlight(_ value: SpotlightMeasurement?, stateDir: String) throws {
        let url = spotlightCacheURL(stateDir: stateDir)
        guard let value else { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = ["bytes": NSNumber(value: value.bytes), "measuredAt": NSNumber(value: value.measuredAt.timeIntervalSince1970)]
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    // MARK: Gathering

    /// Reads the facts for "Not measured". Cheap next to the folder scan: one `tmutil` listing, one
    /// volume query and a bounded `du` per readable other-user folder. Nothing is changed.
    public static func gather(runner: SystemCommandRunner, home: String = NSHomeDirectory(), usersRoot: String = "/Users",
                              volume: String = "/", stateDir: String, unreadable: [String] = [], now: Date = Date()) -> HiddenUsageFacts {
        var facts = HiddenUsageFacts()
        #if os(macOS)
        if let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, let available = values.volumeAvailableCapacity,
           important > Int64(available) {
            facts.purgeableBytes = UInt64(important - Int64(available))
        }
        #endif
        let (exe, args) = listSnapshotsCommand()
        let listing = runner.run(exe, args, timeout: 20)
        if listing.status == 0 { facts.snapshots = parseSnapshots(listing.stdout) }
        facts.otherUsers = otherUsers(runner: runner, home: home, usersRoot: usersRoot)
        facts.unreadable = collapseDenied(unreadable)
        facts.spotlight = loadSpotlight(stateDir: stateDir, now: now)
        return facts
    }

    /// Folders in `usersRoot` other than `home` (including Shared), sized only when this user can list them.
    static func otherUsers(runner: SystemCommandRunner, home: String, usersRoot: String) -> [UsageInputs.Entry] {
        let own = URL(fileURLWithPath: home).standardizedFileURL.path
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: usersRoot)) ?? []).sorted()
        var out: [UsageInputs.Entry] = []
        for name in names where !name.hasPrefix(".") {
            let path = (usersRoot as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard URL(fileURLWithPath: path).standardizedFileURL.path != own,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  access(path, R_OK | X_OK) == 0 else { continue }
            if out.count >= maxOtherUsers { break }
            let (exe, args) = sizeCommand(path)
            // du exits 1 when some subfolders are unreadable; what it could read still counts.
            let bytes = parseDU(runner.run(exe, args, timeout: otherUserTimeout).stdout) ?? 0
            if bytes > 0 {
                var entry = UsageInputs.Entry(name: name, bytes: bytes)
                entry.path = path
                out.append(entry)
            }
        }
        return out
    }

    // MARK: AI models

    /// One model folder on this Mac.
    public struct ModelFolder: Equatable {
        public var location: AIModelLocation
        public var path: String
        public var bytes: UInt64
        /// Newest modification time of the folder and the two levels below it.
        public var lastUsed: Date?
        /// Why it is in use right now (a running owner process, or a file open under it). Empty = idle.
        public var inUseBy: [String]
        public var inUse: Bool { !inUseBy.isEmpty }

        public func jsonObject() -> [String: Any] {
            var object: [String: Any] = ["id": location.id, "title": location.title, "path": path, "bytes": NSNumber(value: bytes),
                                         "reason": location.reason, "inUse": inUse, "inUseBy": inUseBy]
            if let lastUsed { object["lastUsed"] = NSNumber(value: Int64(lastUsed.timeIntervalSince1970)) }
            return object
        }
    }

    /// Running processes as (pid, executable path). macOS: every process this user can see.
    public static func runningProcesses() -> [(Int32, String)] {
        #if os(macOS)
        return BundleProcesses.allProcesses()
        #else
        return []
        #endif
    }

    /// Why `location` at `path` is in use: an owner process by name, a process running from inside
    /// it, or a file open under it (`lsof`, through `runner`).
    public static func inUse(_ location: AIModelLocation, path: String, processes: [(Int32, String)], openFiles: [String]) -> [String] {
        let roots = Set([path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path, realPath(path)].map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        func under(_ candidate: String) -> Bool { roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") } }
        var reasons: [String] = []
        for (pid, exe) in processes {
            let name = URL(fileURLWithPath: exe).lastPathComponent
            if location.processNames.contains(name) { reasons.append("\(name) is running (pid \(pid))") }
            else if under(exe) { reasons.append("\(name) runs from this folder (pid \(pid))") }
        }
        if let open = openFiles.first(where: under) { reasons.append("a running process has \(open) open") }
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    static func realPath(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// Paths open by any process (`lsof -n -w -F n`), through `runner`.
    static func openFiles(runner: SystemCommandRunner) -> [String] {
        let (exe, args) = openFilesCommand()
        return runner.run(exe, args, timeout: 30).stdout.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("n/") ? String(line.dropFirst()) : nil
        }
    }

    /// The model folders that exist under `home`, with size, last use and in-use state.
    public static func models(home: String = NSHomeDirectory(), runner: SystemCommandRunner,
                              processes: [(Int32, String)], sizeTimeout: TimeInterval = 60) -> [ModelFolder] {
        let present = AIModelLocations.all.compactMap { location -> (AIModelLocation, String)? in
            let path = location.path(home: home)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? (location, path) : nil
        }
        guard !present.isEmpty else { return [] }
        let open = openFiles(runner: runner)
        return present.compactMap { location, path in
            let (bytes, _) = UsageScan.singleSize(of: path, timeout: sizeTimeout)
            guard bytes > 0 else { return nil }
            return ModelFolder(location: location, path: path, bytes: bytes, lastUsed: newestModification(path),
                               inUseBy: inUse(location, path: path, processes: processes, openFiles: open))
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Newest mtime of `path` and the entries up to two levels below it (bounded; model trees are
    /// shallow at the top: one folder per model or blob).
    static func newestModification(_ path: String, limit: Int = 4000) -> Date? {
        var newest = UsageMap.modified(path)
        var seen = 0
        var level = [path]
        for _ in 0..<2 {
            var next: [String] = []
            for dir in level {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                    seen += 1
                    if seen > limit { return newest }
                    let child = dir + "/" + name
                    var info = stat()
                    guard lstat(child, &info) == 0 else { continue }
                    let date = UsageMap.mtime(info)
                    if newest.map({ date > $0 }) ?? true { newest = date }
                    if info.st_mode & S_IFMT == S_IFDIR { next.append(child) }
                }
            }
            level = next
        }
        return newest
    }

    // MARK: Actions

    public enum Outcome: Equatable {
        case done(String)
        case cancelled
    }

    /// Runs one reconcile action. Each is confirmed on its own by the caller; nothing here runs as part
    /// of a bulk clean. Model actions re-check that the owning tool is idle right before acting.
    public static func perform(_ action: String, engine: DisklesslyEngine, runner: SystemCommandRunner,
                               processes: () -> [(Int32, String)] = runningProcesses,
                               home: String = NSHomeDirectory(), volume: String = "/", now: Date = Date()) throws -> Outcome {
        switch action {
        case thinSnapshots:
            let total = (try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).map { UInt64(max(0, $0)) } ?? 0
            let (exe, args) = thinSnapshotsCommand(bytes: total)
            let result = runner.run(exe, args, timeout: 600)
            guard result.status == 0 else { throw DisklesslyError.failure("tmutil thinlocalsnapshots failed (exit \(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
            return .done(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        case measureSpotlight:
            let (exe, args) = measureSpotlightCommand()
            let result = runner.run(exe, args, timeout: 900)
            if isCancelled(result) { return .cancelled }
            guard result.status == 0, let bytes = parseDU(result.stdout) else {
                throw DisklesslyError.failure("could not measure the Spotlight index (osascript exit \(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            try saveSpotlight(SpotlightMeasurement(bytes: bytes, measuredAt: now), stateDir: engine.config.stateDir)
            return .done("Spotlight index: \(bytes) bytes")
        case rebuildSpotlight:
            let (exe, args) = rebuildSpotlightCommand()
            let result = runner.run(exe, args, timeout: 300)
            if isCancelled(result) { return .cancelled }
            guard result.status == 0 else {
                throw DisklesslyError.failure("mdutil -E did not complete (osascript exit \(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            // The old size no longer applies; the index grows back while macOS reindexes.
            try saveSpotlight(nil, stateDir: engine.config.stateDir)
            return .done(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            let trash = action.hasPrefix(modelTrashPrefix)
            guard trash || action.hasPrefix(modelOffloadPrefix) else { throw DisklesslyError.usage("unknown reconcile action: \(action)") }
            let id = String(action.dropFirst(trash ? modelTrashPrefix.count : modelOffloadPrefix.count))
            guard let location = AIModelLocations.location(id: id) else { throw DisklesslyError.usage("unknown model folder: \(id)") }
            let path = location.path(home: home)
            guard FileManager.default.fileExists(atPath: path) else { throw DisklesslyError.usage("\(path) does not exist") }
            let busy = inUse(location, path: path, processes: processes(), openFiles: openFiles(runner: runner))
            if !busy.isEmpty {
                throw DisklesslyError.busy("\(location.title) is in use (\(busy.joined(separator: "; "))). Quit it first; nothing was changed.")
            }
            if trash {
                if let refusal = engine.trashPathRefusal(path) { throw DisklesslyError.usage(refusal) }
                #if os(macOS)
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                return .done("Moved \(path) to the Trash; empty the Trash to free the space")
                #else
                try FileManager.default.removeItem(atPath: path)
                return .done("Deleted \(path)")
                #endif
            }
            if let refusal = engine.fileOffloadRefusal(path) { throw DisklesslyError.usage(refusal) }
            let result = try engine.offloadFile(path)
            return .done("Offloaded \(path) -> \(result.placeholderPath)")
        }
    }
}

// MARK: - Report

/// `disklessly reconcile`: the "Not measured" breakdown, the model folders, and the safe next steps.
public struct ReconcileReport {
    public var facts: HiddenUsageFacts
    public var parts: [HiddenUsagePart]
    public var models: [HiddenUsage.ModelFolder]
    public var partial: Bool

    public struct Suggestion: Equatable {
        public var action: String
        public var title: String
        public var detail: String
        public var command: String
    }

    public init(facts: HiddenUsageFacts, models: [HiddenUsage.ModelFolder], partial: Bool = false) {
        self.facts = facts
        self.parts = HiddenUsage.breakdown(gap: facts.gapBytes, facts: facts)
        self.models = models
        self.partial = partial
    }

    /// Finds the facts the scan attached to "Not measured". Nil when the tree has none (Linux, or no gap).
    public static func facts(in tree: UsageNode) -> HiddenUsageFacts? {
        if tree.key == "unmeasured", let hidden = tree.hidden { return hidden }
        for child in tree.children { if let found = facts(in: child) { return found } }
        return nil
    }

    /// Models idle for this long are suggested for offload or delete.
    public static let idleModelDays: Double = 30

    public func suggestions(now: Date = Date()) -> [Suggestion] {
        var out: [Suggestion] = []
        if !facts.snapshots.isEmpty {
            out.append(Suggestion(action: HiddenUsage.thinSnapshots, title: "Thin \(facts.snapshots.count) local snapshot(s)",
                                  detail: "macOS deletes local Time Machine snapshots it can spare. Files are not touched; older restore points on this Mac go away.",
                                  command: "disklessly reconcile thin-snapshots"))
        }
        if let spotlight = facts.spotlight {
            if HiddenUsage.spotlightAbnormal(spotlight.bytes, usedBytes: facts.usedBytes) {
                out.append(Suggestion(action: HiddenUsage.rebuildSpotlight, title: "Rebuild the Spotlight index",
                                      detail: "The index is larger than \(HiddenUsage.spotlightThreshold(usedBytes: facts.usedBytes)) bytes, which usually means it is corrupted. Search is degraded for hours while macOS reindexes. Needs an administrator password.",
                                      command: "disklessly reconcile rebuild-spotlight"))
            }
        } else if parts.contains(where: { $0.key == "spotlight-likely" }) {
            out.append(Suggestion(action: HiddenUsage.measureSpotlight, title: "Measure the Spotlight index",
                                  detail: "Only root can read \(HiddenUsage.spotlightStore). One administrator prompt runs du on it; nothing is changed.",
                                  command: "disklessly reconcile measure-spotlight"))
        }
        for model in models where !model.inUse {
            let idleDays = model.lastUsed.map { now.timeIntervalSince($0) / 86_400 } ?? .infinity
            guard idleDays >= Self.idleModelDays else { continue }
            out.append(Suggestion(action: HiddenUsage.modelOffloadPrefix + model.location.id, title: "Offload \(model.location.title)",
                                  detail: "Not changed for \(idleDays.isFinite ? "\(Int(idleDays)) days" : "a long time"). \(model.location.reason).",
                                  command: "disklessly reconcile offload-model \(model.location.id)  (or: delete-model \(model.location.id))"))
        }
        return out
    }

    public func jsonObject(now: Date = Date()) -> [String: Any] {
        func part(_ p: HiddenUsagePart) -> [String: Any] {
            var object: [String: Any] = ["key": p.key, "name": p.name, "bytes": NSNumber(value: p.bytes)]
            if let r = p.reconcile { object["reconcile"] = r }
            if let path = p.path { object["path"] = path }
            if !p.children.isEmpty { object["children"] = p.children.map(part) }
            return object
        }
        return [
            "ok": true,
            "partial": partial,
            "facts": facts.jsonObject(),
            "parts": parts.map(part),
            "models": models.map { $0.jsonObject() },
            "suggestions": suggestions(now: now).map { ["action": $0.action, "title": $0.title, "detail": $0.detail, "command": $0.command] },
        ]
    }

    public func text(now: Date = Date()) -> String {
        func size(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
        var lines: [String] = []
        lines.append("Used \(size(facts.usedBytes)); the folder scan could not account for \(size(facts.gapBytes)).")
        if partial { lines.append("(the scan stopped early; part of the gap may be folders that timed out)") }
        for p in parts {
            lines.append("  \(p.name): \(size(p.bytes))")
            for c in p.children { lines.append("      \(c.name): \(size(c.bytes))") }
        }
        lines.append("Purgeable space (macOS frees it on demand): \(size(facts.purgeableBytes)); local snapshots: \(facts.snapshots.count)")
        if facts.snapshots.isEmpty && facts.purgeableBytes > 0 {
            lines.append("  No local snapshots: purgeable space is mostly caches and iCloud files already counted above.")
        }
        for name in facts.snapshots.prefix(10) { lines.append("    \(name)") }
        if let s = facts.spotlight {
            lines.append("Spotlight index (\(HiddenUsage.spotlightStore)): \(size(s.bytes)); rebuild suggested above \(size(HiddenUsage.spotlightThreshold(usedBytes: facts.usedBytes))).")
        } else {
            lines.append("Spotlight index (\(HiddenUsage.spotlightStore)): not measured (needs an administrator prompt).")
        }
        if !facts.unreadable.isEmpty {
            let capped = facts.unreadable.count >= HiddenUsage.maxUnreadable ? " (first \(HiddenUsage.maxUnreadable))" : ""
            lines.append("Folders the scan could not read\(capped) — root-only or privacy-protected (Full Disk Access helps for the latter); they have no size here:")
            for path in facts.unreadable.prefix(10) { lines.append("    \(path)") }
        }
        if !models.isEmpty {
            lines.append("AI model folders (already counted under Personal files / Library):")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            for m in models {
                let used = m.lastUsed.map { formatter.string(from: $0) } ?? "unknown"
                lines.append("  \(m.location.title): \(size(m.bytes)), last changed \(used)\(m.inUse ? " — in use: " + m.inUseBy.joined(separator: "; ") : "")")
                lines.append("      \(m.path)")
            }
        }
        let suggestions = suggestions(now: now)
        if suggestions.isEmpty {
            lines.append("Nothing to suggest. Nothing was changed.")
        } else {
            lines.append("Suggested (each asks for its own confirmation; none runs in a bulk clean):")
            for s in suggestions { lines.append("  - \(s.title): \(s.command)\n      \(s.detail)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
