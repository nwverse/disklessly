import Foundation
import DisklesslyCore

/// What `sessions` would do for one agent, without uploading or deleting.
public struct SessionToolPlan: Equatable {
    public var tool: String
    public var label: String
    public var roots: [SessionRoot]
    /// Roots whose directory exists on this Mac.
    public var presentRoots: [String]
    /// Transcripts found (excluded names such as credentials are not counted).
    public var files: Int = 0
    public var bytes: UInt64 = 0
    /// Files apply would archive: closed, not modified for 24h or `days`, and
    /// no larger than `sessionMaxFileBytes`.
    public var coldFiles: Int = 0
    public var coldBytes: UInt64 = 0
    /// Old enough to be cold but held open by a process.
    public var openFiles: Int = 0
    /// Old enough to be cold but larger than `sessionMaxFileBytes`.
    public var tooLargeFiles: Int = 0
    public var tooLargeBytes: UInt64 = 0
    /// Files under the root that are not transcripts (secrets, settings, SQLite).
    public var excludedFiles: Int = 0
    public var oldest: Date?
    public var newest: Date?

    public func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = [
            "tool": tool,
            "label": label,
            "present": !presentRoots.isEmpty,
            "roots": roots.map { root -> [String: Any] in
                ["directory": root.directory, "suffixes": root.allSuffixes, "requireComponent": root.requireComponent ?? "",
                 "exists": presentRoots.contains(root.directory)]
            },
            "files": NSNumber(value: files),
            "bytes": NSNumber(value: bytes),
            "coldFiles": NSNumber(value: coldFiles),
            "coldBytes": NSNumber(value: coldBytes),
            "hotFiles": NSNumber(value: files - coldFiles),
            "hotBytes": NSNumber(value: bytes >= coldBytes ? bytes - coldBytes : 0),
            "openFiles": NSNumber(value: openFiles),
            "tooLargeFiles": NSNumber(value: tooLargeFiles),
            "tooLargeBytes": NSNumber(value: tooLargeBytes),
            "excludedFiles": NSNumber(value: excludedFiles),
        ]
        if let oldest { object["oldest"] = iso.string(from: oldest) }
        if let newest { object["newest"] = iso.string(from: newest) }
        return object
    }
}

/// Per-agent dry run of session tiering. Building it reads only the agents'
/// folders: no index, lock, or repo is opened.
public struct SessionPlanReport: Equatable {
    public var days: Int
    public var generatedAt: Date
    public var tools: [SessionToolPlan]

    public var files: Int { tools.reduce(0) { $0 + $1.files } }
    public var bytes: UInt64 { tools.reduce(0) { $0 + $1.bytes } }
    public var coldFiles: Int { tools.reduce(0) { $0 + $1.coldFiles } }
    public var coldBytes: UInt64 { tools.reduce(0) { $0 + $1.coldBytes } }

    public func tool(_ id: String) -> SessionToolPlan? { tools.first { $0.tool == id } }

    public func jsonObject() -> [String: Any] {
        [
            "days": NSNumber(value: days),
            "protectHours": NSNumber(value: Int(SessionTiering.protectSeconds / 3600)),
            "generatedAt": ISO8601DateFormatter().string(from: generatedAt),
            "tools": tools.map { $0.jsonObject() },
            "totals": [
                "files": NSNumber(value: files),
                "bytes": NSNumber(value: bytes),
                "coldFiles": NSNumber(value: coldFiles),
                "coldBytes": NSNumber(value: coldBytes),
            ] as [String: Any],
        ]
    }
}

extension SessionReport {
    public func jsonObject() -> [String: Any] {
        ["ok": true, "applied": applied, "cold": cold,
         "skipped": skipped.map { ["path": $0.0, "reason": $0.1] },
         "keptLocal": keptLocal.map { ["path": $0.0, "reason": $0.1] },
         "segments": segments]
    }
}

extension SessionArchive {
    /// Per-tool counts with the same roots, scan, and cold rules `tier` uses.
    /// `openAmong` gets every file that is otherwise cold in one call and returns
    /// the ones held open, so a live probe can batch them.
    public static func plan(config: RuntimeConfig, now: Date = Date(), coldDays: Int? = nil, home: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, openAmong: ([String]) -> Set<String> = { _ in [] }) throws -> SessionPlanReport {
        let days = coldDays ?? config.sessionColdDays
        let roots = configuredRoots(config: config, home: home, environment: environment)
        var order: [String] = []
        var plans: [String: SessionToolPlan] = [:]
        let fm = FileManager.default
        for root in roots {
            if plans[root.tool] == nil {
                order.append(root.tool)
                plans[root.tool] = SessionToolPlan(tool: root.tool, label: SessionRoot.label(tool: root.tool), roots: [], presentRoots: [])
            }
            plans[root.tool]?.roots.append(root)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.directory, isDirectory: &isDir), isDir.boolValue {
                plans[root.tool]?.presentRoots.append(root.directory)
            }
        }
        let candidates = try scan(roots: roots, isOpen: { _ in false })
        let ageCold = candidates.filter { SessionTiering.decide($0, now: now, coldDays: days).cold && $0.size <= config.sessionMaxFileBytes }
        let open = ageCold.isEmpty ? [] : openAmong(ageCold.map(\.path))
        for candidate in candidates {
            guard var plan = plans[candidate.tool] else { continue }
            defer { plans[candidate.tool] = plan }
            if SessionTiering.forbidden(candidate.path) {
                plan.excludedFiles += 1
                continue
            }
            plan.files += 1
            plan.bytes += candidate.size
            plan.oldest = min(plan.oldest ?? candidate.modified, candidate.modified)
            plan.newest = max(plan.newest ?? candidate.modified, candidate.modified)
            guard SessionTiering.decide(candidate, now: now, coldDays: days).cold else { continue }
            if candidate.size > config.sessionMaxFileBytes {
                plan.tooLargeFiles += 1
                plan.tooLargeBytes += candidate.size
                continue
            }
            if open.contains(candidate.path) {
                plan.openFiles += 1
                continue
            }
            plan.coldFiles += 1
            plan.coldBytes += candidate.size
        }
        return SessionPlanReport(days: days, generatedAt: now, tools: order.compactMap { plans[$0] })
    }

    /// The open-file probe `sessions` uses on this machine, snapshotting `/proc`
    /// once per call on Linux. lsof when installed; on Linux without lsof the
    /// `/proc` fd links; if neither works on Linux every file counts as open,
    /// so nothing live is archived.
    public static func liveOpenProbe() -> (String) -> Bool {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lsof else {
            guard HostPlatform.current == .linux else { return { _ in false } }
            guard let open = OpenFileProbe.procOpenPaths() else { return { _ in true } }
            return { open.contains(SessionPaths.canonical($0)) }
        }
        return { path in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsof)
            process.arguments = ["-Fn", "--", path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return OpenFileProbe.isOpen(lsofStatus: process.terminationStatus, lsofStdout: String(decoding: data, as: UTF8.self), path: path)
        }
    }

    /// The subset of `paths` some process holds open, with one lsof run per 200
    /// paths. Linux without lsof reads `/proc`; if that fails too, every path
    /// counts as open.
    public static func liveOpenAmong(_ paths: [String]) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lsof else {
            guard HostPlatform.current == .linux else { return [] }
            guard let open = OpenFileProbe.procOpenPaths() else { return Set(paths) }
            return Set(paths.filter { open.contains(SessionPaths.canonical($0)) })
        }
        let wanted = Dictionary(paths.map { (SessionPaths.canonical($0), $0) }, uniquingKeysWith: { first, _ in first })
        var found = Set<String>()
        var start = 0
        while start < paths.count {
            let chunk = Array(paths[start..<min(start + 200, paths.count)])
            start += chunk.count
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsof)
            process.arguments = ["-Fn", "--"] + chunk
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // lsof exits 1 when any named file is not open; the `n` records of the
            // open ones are still printed, so they are read whatever the status.
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("n") && line.count > 1 {
                if let original = wanted[SessionPaths.canonical(String(line.dropFirst()))] { found.insert(original) }
            }
        }
        return found
    }

    /// Readable digest written when a session was archived, if any.
    public static func digestURL(config: RuntimeConfig, id: String) -> URL {
        SessionTierV2.digestURL(stateDir: config.stateDir, id: id)
    }
}

extension DisklesslyEngine {
    private var sessionOpenAmong: ([String]) -> Set<String> {
        if let override = fileOpenOverride { return { Set($0.filter { override($0, false) }) } }
        return SessionArchive.liveOpenAmong
    }

    private var sessionOpenProbe: (String) -> Bool {
        if let override = fileOpenOverride { return { override($0, false) } }
        return SessionArchive.liveOpenProbe()
    }

    /// Dry run per agent: file count, bytes, cold count and bytes, oldest and
    /// newest mtime. Reads the agents' folders only.
    public func sessionPlan(days: Int? = nil, home: String? = nil, now: Date = Date()) throws -> SessionPlanReport {
        try SessionArchive.plan(config: config, now: now, coldDays: days, home: home, openAmong: sessionOpenAmong)
    }

    /// Archive the cold sessions of the selected agents. `tools` nil means all
    /// configured agents; an empty set or an unknown id is a usage error (exit 2).
    public func sessionApply(tools: Set<String>?, days: Int? = nil, home: String? = nil, encrypt: Bool = false, now: Date = Date()) throws -> SessionReport {
        try SessionArchive.tier(config: config, backend: repo, now: now, apply: true, coldDays: days, home: home, tools: tools, isOpen: sessionOpenProbe, secrets: secrets, encrypt: encrypt)
    }
}
