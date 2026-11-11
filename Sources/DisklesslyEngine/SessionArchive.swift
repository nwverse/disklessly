import Foundation
import DisklesslyCore
import DisklesslySessions

public struct SessionReport: Equatable {
    public var cold: [String]
    public var skipped: [(String, String)]
    public var applied: Bool
    public var keptLocal: [(String, String)]
    public var segments: [String]
    /// Transcripts this run removed locally after their archive was verified,
    /// including pendingDelete rows an earlier run left behind.
    public var archived: [SessionArchivedItem]
    /// Original size of the transcripts in `archived`.
    public var uploadedBytes: Int64
    public init(cold: [String], skipped: [(String, String)], applied: Bool, keptLocal: [(String, String)] = [], segments: [String] = [], archived: [SessionArchivedItem] = [], uploadedBytes: Int64 = 0) {
        self.cold = cold
        self.skipped = skipped
        self.applied = applied
        self.keptLocal = keptLocal
        self.segments = segments
        self.archived = archived
        self.uploadedBytes = uploadedBytes
    }
    public static func == (lhs: SessionReport, rhs: SessionReport) -> Bool {
        lhs.cold == rhs.cold && lhs.applied == rhs.applied && lhs.segments == rhs.segments
            && lhs.archived == rhs.archived && lhs.uploadedBytes == rhs.uploadedBytes
            && lhs.skipped.elementsEqual(rhs.skipped, by: { $0.0 == $1.0 && $0.1 == $1.1 })
            && lhs.keptLocal.elementsEqual(rhs.keptLocal, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }
}

public enum SessionArchive {
    public static func indexURL(_ stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("sessions-index.json")
    }

    public static func loadIndex(_ stateDir: String) throws -> SessionIndex {
        let url = indexURL(stateDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionIndex() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionIndex.self, from: ChunkedIO.readAll(url))
    }

    public static func saveIndex(_ index: SessionIndex, stateDir: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try encoder.encode(index).write(to: indexURL(stateDir), options: .atomic)
    }

    public static func scan(roots: [SessionRoot], isOpen: (String) -> Bool) throws -> [SessionCandidate] {
        var found: [SessionCandidate] = []
        // Roots may overlap (a config root inside a default one). The first root
        // that lists a file owns it, so one file is never packed twice.
        var seen = Set<String>()
        let fm = FileManager.default
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.directory, isDirectory: &isDir), isDir.boolValue else { continue }
            let canonicalRoot = SessionPaths.canonical(root.directory)
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root.directory), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                let path = SessionPaths.canonical(url.path)
                guard root.accepts(path, canonicalDirectory: canonicalRoot) else { continue }
                guard !seen.contains(path) else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
                var targetIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &targetIsDirectory), !targetIsDirectory.boolValue else { continue }
                seen.insert(path)
                let attributes = try? fm.attributesOfItem(atPath: path)
                let preview = (try? ChunkedIO.prefix(URL(fileURLWithPath: path), maxBytes: 4096)) ?? Data()
                found.append(SessionCandidate(
                    path: path,
                    tool: root.tool,
                    size: (attributes?[.size] as? NSNumber)?.uint64Value ?? UInt64(preview.count),
                    modified: attributes?[.modificationDate] as? Date ?? .distantPast,
                    open: isOpen(path),
                    preview: SessionTiering.preview(of: preview)
                ))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The home of the built-in roots and of herdr's layout: `--home`, then
    /// `config.sessionHome`, then `$HOME` (the passwd home when HOME is unset).
    static func sessionHome(config: RuntimeConfig, home: String?, environment: [String: String]) -> String {
        if let home, !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return SessionPaths.canonical(home) }
        if let configured = config.sessionHome, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return SessionPaths.canonical(configured) }
        return SessionPaths.homeDirectory(environment: environment)
    }

    /// Built-in roots come from `--home`, then `config.sessionHome`, then `$HOME`.
    /// The passwd home is used only when HOME is unset. An explicit `sessionRoots`
    /// list replaces the built-in directories.
    public static func configuredRoots(config: RuntimeConfig, home: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> [SessionRoot] {
        if !config.sessionRoots.isEmpty {
            return config.sessionRoots.map { root in
                var copy = root
                copy.directory = SessionPaths.canonical(root.directory)
                return copy
            }
        }
        return SessionRoot.defaults(home: sessionHome(config: config, home: home, environment: environment))
    }

    /// Roots whose tool is in `tools`. Nil keeps them all.
    public static func restrict(_ roots: [SessionRoot], to tools: Set<String>?) throws -> [SessionRoot] {
        guard let tools else { return roots }
        guard !tools.isEmpty else { throw DisklesslyError.usage("no session tools selected") }
        let known = Set(roots.map(\.tool))
        let unknown = tools.subtracting(known)
        if !unknown.isEmpty {
            throw DisklesslyError.usage("unknown session tool: \(unknown.sorted().joined(separator: ", "))")
        }
        return roots.filter { tools.contains($0.tool) }
    }

    /// Canonical paths that are not inside a configured root. Both sides of the
    /// comparison are canonical, and the returned spelling is the realpath form
    /// so a `/var` alias is reported as `/private/var`. `--apply` refuses these.
    public static func pathsOutsideRoots(_ paths: [String], roots: [SessionRoot]) -> [String] {
        paths.compactMap { path in
            let canonical = SessionPaths.canonical(path)
            guard !roots.contains(where: { SessionPaths.contains($0.directory, path: canonical) }) else { return nil }
            return canonical
        }
    }

    /// Without `apply`, nothing is uploaded or deleted. The first run is a dry run
    /// unless the caller passes `apply: true`.
    /// `tools` limits the run to those tool ids (the agents a user ticked). Nil
    /// means every configured root. An empty set or an id with no root is a usage
    /// error. Pending rows from earlier runs are settled whatever the filter.
    /// `exclusions` names sessions another tool still references; they are skipped
    /// as `referenced`, and the list is asked again right before each local delete,
    /// together with the built-in scan of running agents and herdr's layout
    /// (`SessionReferences`). When the process listing fails, no local file is
    /// deleted in this run (`reference check failed`).
    /// `requireRepoMarker` refuses `apply` (exit 4) unless the repo's `repo.json`
    /// answers, before anything is uploaded or deleted.
    public static func tier(config: RuntimeConfig, backend: any StorageBackend, now: Date = Date(), apply: Bool = false, coldDays: Int? = nil, home: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, tools: Set<String>? = nil, only: Set<String>? = nil, isOpen: (String) -> Bool = { _ in false }, secrets: (any SecretStore)? = nil, encrypt: Bool = false, beforeDelete: ((String) -> Void)? = nil, afterIndexCommit: (() throws -> Void)? = nil, exclusions: (() -> SessionExclusions)? = nil, requireRepoMarker: Bool = false) throws -> SessionReport {
        let days = coldDays ?? config.sessionColdDays
        // Sessions named by running agents or herdr's layout count as referenced,
        // like `--exclude-from` entries. The scan runs again before each delete.
        let referenceHome = sessionHome(config: config, home: home, environment: environment)
        let planScan = SessionReferences.scan(home: referenceHome)
        var excluded = exclusions?() ?? SessionExclusions()
        SessionReferences.merge(&excluded, planScan.exclusions)
        let roots = try restrict(configuredRoots(config: config, home: home, environment: environment), to: tools)
        // Ask the open-file probe only about files that are cold by name and age;
        // a recent file is skipped either way and lsof is slow per call.
        let scanned = try scan(roots: roots, isOpen: { _ in false })
        let referencedSkips = scanned.filter { excluded.matches(tool: $0.tool, path: $0.path) }.map { ($0.path, "referenced") }
        let unreferenced = scanned.filter { !excluded.matches(tool: $0.tool, path: $0.path) }
        // A transcript restored less than `days` ago and unchanged since stays local.
        let held = SessionTierV2.recentlyRestored(config: config, candidates: unreferenced, now: now, days: days)
        let restored = unreferenced.filter { held.contains($0.path) }.map { ($0.path, "restored") }
        let candidates = unreferenced.filter { !held.contains($0.path) }.map { candidate -> SessionCandidate in
            guard SessionTiering.decide(candidate, now: now, coldDays: days).cold else { return candidate }
            var probed = candidate
            probed.open = isOpen(candidate.path)
            return probed
        }
        let decisions = candidates.map { SessionTiering.decide($0, now: now, coldDays: days) }
        let picked = { (path: String) in only.map { $0.contains(path) } ?? true }
        let cold = decisions.filter { $0.cold && picked($0.candidate.path) }.map(\.candidate)
        let skipped = decisions.filter { !$0.cold }.map { ($0.candidate.path, $0.reason) }
            + decisions.filter { $0.cold && !picked($0.candidate.path) }.map { ($0.candidate.path, "not selected") }
            + referencedSkips + restored
        guard apply else { return SessionReport(cold: cold.map(\.path), skipped: skipped, applied: false) }
        let outside = pathsOutsideRoots(candidates.map(\.path), roots: roots)
        if !outside.isEmpty {
            throw DisklesslyError.usage("refusing to apply session tiering; candidate is outside the configured roots: \(outside.sorted().joined(separator: ", "))")
        }
        if requireRepoMarker { try SessionBackendCheck.require(backend) }
        // A listing that fails once in this run keeps every local file of the run.
        var listingFailed = planScan.failed
        let stillReferenced: (String, String) -> String? = { tool, path in
            if exclusions?().matches(tool: tool, path: path) == true { return "referenced" }
            let live = SessionReferences.scan(home: referenceHome)
            if live.exclusions.matches(tool: tool, path: path) { return "referenced" }
            if live.failed { listingFailed = true }
            return listingFailed ? "reference check failed" : nil
        }
        return try SessionTierV2.apply(config: config, backend: backend, now: now, cold: cold, skipped: skipped, secrets: secrets, encrypt: encrypt, isOpen: isOpen, beforeDelete: beforeDelete, afterIndexCommit: afterIndexCommit, referenced: stillReferenced)
    }

    /// Archived (cold) sessions for the dashboard. It never runs the legacy JSON
    /// migration; opening a schema 2 SQLite index does upgrade it to schema 3.
    public static func archivedEntries(config: RuntimeConfig) throws -> [SessionIndexEntry] {
        try SessionTierV2.archivedForDisplay(config: config)
    }

    public static func search(config: RuntimeConfig, query: String) throws -> [SessionIndexEntry] {
        try SessionTierV2.search(config: config, query: query)
    }

    public static func restore(config: RuntimeConfig, backend: any StorageBackend, query: String, to: String? = nil, secrets: (any SecretStore)? = nil) throws -> String {
        try SessionTierV2.restore(config: config, backend: { backend }, query: query, to: to, secrets: secrets).path
    }

    /// Restore with the entry id and session id of what came back. With
    /// `requireRepoMarker`, a download from a repo whose `repo.json` does not answer
    /// (on the primary or any mirror) fails with exit 4 (`backend unreachable: …`).
    public static func restoreSession(config: RuntimeConfig, backend: any StorageBackend, query: String, to: String? = nil, secrets: (any SecretStore)? = nil, requireRepoMarker: Bool = false) throws -> SessionRestoreResult {
        try SessionTierV2.restore(config: config, backend: { backend }, query: query, to: to, secrets: secrets, requireRepoMarker: requireRepoMarker)
    }

    /// Like `restoreSession(backend:)`, but `open` runs only when the transcript
    /// has to be downloaded, so a file already back in place needs no backend.
    public static func restoreSession(config: RuntimeConfig, open: () throws -> any StorageBackend, query: String, to: String? = nil, secrets: (any SecretStore)? = nil, requireRepoMarker: Bool = false) throws -> SessionRestoreResult {
        try SessionTierV2.restore(config: config, backend: open, query: query, to: to, secrets: secrets, requireRepoMarker: requireRepoMarker)
    }

    public static func reindex(config: RuntimeConfig, backend: any StorageBackend, secrets: any SecretStore, requireRepoMarker: Bool = false) throws -> Int {
        try SessionTierV2.reindex(config: config, backend: backend, secrets: secrets, requireRepoMarker: requireRepoMarker)
    }

    public static func verifyLegacy(config: RuntimeConfig, backend: any StorageBackend) throws -> [String] {
        try SessionTierV2.verifyLegacy(config: config, backend: backend)
    }

    public static func createSessionKey(secrets: any SecretStore) throws -> String {
        try SessionKeyStore.create(secrets: secrets)
    }

    public static func sessionKeyId(secrets: any SecretStore) throws -> String? {
        try SessionKeyStore.currentKeyId(secrets: secrets)
    }

    public static func restoreLegacy(config: RuntimeConfig, backend: any StorageBackend, query: String) throws -> String {
        let index = try loadIndex(config.stateDir)
        let matches = index.matches(query)
        guard let entry = matches.first else { throw DisklesslyError.usage("no cold session matches \(query)") }
        guard matches.count == 1 else { throw DisklesslyError.usage("session query \(query) matches \(matches.count) entries") }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-session-\(UUID().uuidString).tar.gz")
        _ = try backend.download(entry.archive, to: archive, offset: 0)
        defer { try? FileManager.default.removeItem(at: archive) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path, entry.member])
        let extracted = staging.appendingPathComponent(entry.member)
        guard try SHA256Digest.hexFile(extracted) == entry.sha256 else { throw DisklesslyError.integrity("restored session hash does not match the index") }
        let destination = URL(fileURLWithPath: entry.path)
        let held = staging.appendingPathComponent("restored-\(UUID().uuidString)")
        try ChunkedIO.copyFile(from: extracted, to: held)
        try ChunkedIO.replaceFile(destination, with: held)
        let restoredDate = entry.tool == "claude" ? Date() : entry.modified
        let restoredPath = SessionPaths.canonical(destination.path)
        try FileManager.default.setAttributes([.modificationDate: restoredDate], ofItemAtPath: restoredPath)
        var updated = index
        updated.entries.removeAll { $0.id == entry.id }
        try saveIndex(updated, stateDir: config.stateDir)
        return restoredPath
    }

    /// v1 monthly tar.gz writer. New tiering never calls this. Migration tests use it to seed an old archive.
    public static func publishLegacy(archive: String, files: [SessionCandidate], backend: any StorageBackend, index: inout SessionIndex) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        if try backend.stat(archive) != nil {
            let packed = staging.appendingPathComponent("existing.tar.gz")
            _ = try backend.download(archive, to: packed, offset: 0)
            try run("/usr/bin/tar", ["-xzf", packed.path, "-C", staging.path])
            try FileManager.default.removeItem(at: packed)
        }
        var entries: [SessionIndexEntry] = []
        for file in files {
            let member = "\(file.tool)/\(SHA256Digest.hex(Data(file.path.utf8)).prefix(12))-\((file.path as NSString).lastPathComponent)"
            let destination = staging.appendingPathComponent(member)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: file.path)
            try ChunkedIO.copyFile(from: source, to: destination)
            let digest = try SHA256Digest.hexFile(destination)
            let size = try ChunkedIO.byteCount(destination)
            entries.append(SessionIndexEntry(id: String(digest.prefix(12)), tool: file.tool, path: file.path, sha256: digest, size: size, modified: file.modified, archive: archive, member: member, preview: file.preview))
        }
        let packed = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-next-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: packed) }
        let names = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        try run("/usr/bin/tar", ["-czf", packed.path, "-C", staging.path] + names)
        try backend.put(archive, file: packed)
        let roundTrip = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-roundtrip-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: roundTrip) }
        _ = try backend.download(archive, to: roundTrip, offset: 0)
        guard try SHA256Digest.hexFile(roundTrip) == SHA256Digest.hexFile(packed) else {
            throw DisklesslyError.integrity("session archive hash does not match the bytes that were sent")
        }
        for entry in entries {
            index.entries.removeAll { $0.id == entry.id }
            index.entries.append(entry)
        }
    }

    static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DisklesslyError.failure("Command failed: \(path) \(arguments.joined(separator: " ")) (exit \(process.terminationStatus))\(detail.isEmpty ? "" : "\n\(detail)")")
        }
    }
}
