import Foundation
import IsenoughCore
import IsenoughSessions

public struct SessionReport: Equatable {
    public var cold: [String]
    public var skipped: [(String, String)]
    public var applied: Bool
    public var keptLocal: [(String, String)]
    public var segments: [String]
    public init(cold: [String], skipped: [(String, String)], applied: Bool, keptLocal: [(String, String)] = [], segments: [String] = []) {
        self.cold = cold
        self.skipped = skipped
        self.applied = applied
        self.keptLocal = keptLocal
        self.segments = segments
    }
    public static func == (lhs: SessionReport, rhs: SessionReport) -> Bool {
        lhs.cold == rhs.cold && lhs.applied == rhs.applied && lhs.segments == rhs.segments
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
        let fm = FileManager.default
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.directory, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root.directory), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                let path = SessionPaths.canonical(url.path)
                guard path.hasSuffix(root.suffix) else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
                var targetIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &targetIsDirectory), !targetIsDirectory.boolValue else { continue }
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
        let base: String
        if let home, !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = SessionPaths.canonical(home)
        } else if let configured = config.sessionHome, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = SessionPaths.canonical(configured)
        } else {
            base = SessionPaths.homeDirectory(environment: environment)
        }
        return SessionRoot.defaults(home: base)
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
    public static func tier(config: RuntimeConfig, backend: any StorageBackend, now: Date = Date(), apply: Bool = false, coldDays: Int? = nil, home: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, isOpen: (String) -> Bool = { _ in false }, secrets: (any SecretStore)? = nil, encrypt: Bool = false, beforeDelete: ((String) -> Void)? = nil, afterIndexCommit: (() throws -> Void)? = nil) throws -> SessionReport {
        let days = coldDays ?? config.sessionColdDays
        let roots = configuredRoots(config: config, home: home, environment: environment)
        let candidates = try scan(roots: roots, isOpen: isOpen)
        let decisions = candidates.map { SessionTiering.decide($0, now: now, coldDays: days) }
        let cold = decisions.filter(\.cold).map(\.candidate)
        let skipped = decisions.filter { !$0.cold }.map { ($0.candidate.path, $0.reason) }
        guard apply else { return SessionReport(cold: cold.map(\.path), skipped: skipped, applied: false) }
        let outside = pathsOutsideRoots(candidates.map(\.path), roots: roots)
        if !outside.isEmpty {
            throw IsenoughError.usage("refusing to apply session tiering; candidate is outside the configured roots: \(outside.sorted().joined(separator: ", "))")
        }
        return try SessionTierV2.apply(config: config, backend: backend, now: now, cold: cold, skipped: skipped, secrets: secrets, encrypt: encrypt, isOpen: isOpen, beforeDelete: beforeDelete, afterIndexCommit: afterIndexCommit)
    }

    /// Archived (cold) sessions for the dashboard; never migrates or writes.
    public static func archivedEntries(config: RuntimeConfig) throws -> [SessionIndexEntry] {
        try SessionTierV2.archivedForDisplay(config: config)
    }

    public static func search(config: RuntimeConfig, query: String) throws -> [SessionIndexEntry] {
        try SessionTierV2.search(config: config, query: query)
    }

    public static func restore(config: RuntimeConfig, backend: any StorageBackend, query: String, to: String? = nil, secrets: (any SecretStore)? = nil) throws -> String {
        try SessionTierV2.restore(config: config, backend: backend, query: query, to: to, secrets: secrets)
    }

    public static func reindex(config: RuntimeConfig, backend: any StorageBackend, secrets: any SecretStore) throws -> Int {
        try SessionTierV2.reindex(config: config, backend: backend, secrets: secrets)
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
        guard let entry = matches.first else { throw IsenoughError.usage("no cold session matches \(query)") }
        guard matches.count == 1 else { throw IsenoughError.usage("session query \(query) matches \(matches.count) entries") }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-session-\(UUID().uuidString).tar.gz")
        _ = try backend.download(entry.archive, to: archive, offset: 0)
        defer { try? FileManager.default.removeItem(at: archive) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path, entry.member])
        let extracted = staging.appendingPathComponent(entry.member)
        guard try SHA256Digest.hexFile(extracted) == entry.sha256 else { throw IsenoughError.integrity("restored session hash does not match the index") }
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
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-pack-\(UUID().uuidString)")
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
        let packed = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-next-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: packed) }
        let names = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        try run("/usr/bin/tar", ["-czf", packed.path, "-C", staging.path] + names)
        try backend.put(archive, file: packed)
        let roundTrip = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-roundtrip-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: roundTrip) }
        _ = try backend.download(archive, to: roundTrip, offset: 0)
        guard try SHA256Digest.hexFile(roundTrip) == SHA256Digest.hexFile(packed) else {
            throw IsenoughError.integrity("session archive hash does not match the bytes that were sent")
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
            throw IsenoughError.failure("Command failed: \(path) \(arguments.joined(separator: " ")) (exit \(process.terminationStatus))\(detail.isEmpty ? "" : "\n\(detail)")")
        }
    }
}
