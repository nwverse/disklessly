import Crypto
import Foundation
import DisklesslyCore
import DisklesslySessions

enum SessionTierV2 {
    static func apply(config: RuntimeConfig, backend: any StorageBackend, now: Date, cold: [SessionCandidate], skipped: [(String, String)], secrets: (any SecretStore)?, encrypt: Bool, isOpen: (String) -> Bool, beforeDelete: ((String) -> Void)?, afterIndexCommit: (() throws -> Void)?) throws -> SessionReport {
        let lockURL = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/sessions.lock")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lock = FileLock(path: lockURL.path)
        guard try lock.tryLock() else { throw DisklesslyError.busy("sessions are already being tiered") }
        defer { lock.unlock() }

        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        _ = try SessionMigration.migrateIfNeeded(stateDir: config.stateDir, deviceId: device.deviceId, database: database)
        let store = secrets ?? MemorySecretStore()
        var kept = try finishPending(database: database, isOpen: isOpen, backend: backend, config: config, secrets: store)
        let wantsEncryption = encrypt || config.sessionEncryption == "aes-gcm"
        let key = try encryptionKey(secrets: store, enabled: wantsEncryption)
        var extraSkipped = skipped
        let drafts = try snapshot(cold: cold, config: config, skipped: &extraSkipped)
        let groups = pack(drafts, deviceId: device.deviceId, config: config)
        var segments: [String] = []
        for group in groups {
            let built = try SegmentWriter.build(deviceId: device.deviceId, tool: group.tool, now: now, members: group.members, key: key)
            try publish(built, backend: backend)
            // Round-trip the stored object before the index says pendingDelete.
            // A later finishPending settles that state, so a failed check must
            // leave the index alone and the local file in place.
            try verifyMembers(relative: built.relativePath, members: group.members, backend: backend, config: config, secrets: store)
            let created = SegmentWriter.createdAt(now)
            let row = SessionSegmentRow(id: built.sha256, path: built.relativePath, deviceId: device.deviceId, tool: group.tool, createdAt: created, bytes: Int64(built.stored.count), codec: built.codec, encrypted: key != nil, keyId: built.keyId)
            // Digest from the snapshot bytes already in memory. The transcript
            // itself is what was packed; the digest only goes into the index.
            let entries = group.members.map { member in
                SessionEntryRow(id: member.entryId, segmentId: built.sha256, legacyArchive: nil, member: "m/\(member.entryId).jsonl", deviceId: device.deviceId, tool: member.tool, path: member.path, sha256: member.sha256, size: member.size, mtimeNs: member.mtimeNs, ino: member.ino, preview: member.preview, archivedAt: created, state: "pendingDelete", digest: SessionDigest.digest(tool: member.tool, path: member.path, data: member.bytes))
            }
            try database.commit(segment: row, entries: entries)
            for entry in entries {
                // A digest file is a convenience; failing to write it never blocks the run.
                try? writeDigestFile(entry, stateDir: config.stateDir)
            }
            segments.append(built.relativePath)
            if let afterIndexCommit { try afterIndexCommit() }
            for member in group.members {
                beforeDelete?(member.path)
                if let reason = try settle(member, database: database, isOpen: isOpen, txid: String(built.sha256.prefix(8))) {
                    kept.append((member.path, reason))
                }
            }
        }
        return SessionReport(cold: cold.map(\.path), skipped: extraSkipped, applied: true, keptLocal: kept, segments: segments)
    }

    /// `stateDir/sessions/digests/<entryId>.md`.
    static func digestURL(stateDir: String, id: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("sessions/digests/\(id).md")
    }

    static func writeDigestFile(_ entry: SessionEntryRow, stateDir: String) throws {
        let url = digestURL(stateDir: stateDir, id: entry.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let modified = Date(timeIntervalSince1970: Double(entry.mtimeNs) / 1_000_000_000)
        let text = SessionDigest.markdown(id: entry.id, tool: entry.tool, path: entry.path, sha256: entry.sha256, modified: modified, digest: entry.digest)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func search(config: RuntimeConfig, query: String) throws -> [SessionIndexEntry] {
        let entries = try indexed(config: config, includeRestored: false)
        return SessionIndex(entries: entries).search(query)
    }

    static func restore(config: RuntimeConfig, backend: any StorageBackend, query: String, to: String?, secrets: (any SecretStore)?) throws -> String {
        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        _ = try SessionMigration.migrateIfNeeded(stateDir: config.stateDir, deviceId: device.deviceId, database: database)
        let rows = try database.allEntries()
        let paths = try database.segmentPaths()
        let entries = rows.map { indexEntry($0, paths: paths) }
        let matches = SessionIndex(entries: entries).matches(query)
        guard let entry = matches.first else { throw DisklesslyError.usage("no cold session matches \(query)") }
        guard matches.count == 1 else { throw DisklesslyError.usage("session query \(query) matches \(matches.count) entries") }
        guard let row = rows.first(where: { $0.id == entry.id }) else { throw DisklesslyError.usage("no cold session matches \(query)") }
        if row.deviceId != device.deviceId && to == nil {
            throw DisklesslyError.usage("session belongs to another Mac; pass --to PATH")
        }
        let destination = to ?? row.path
        if FileManager.default.fileExists(atPath: destination) {
            let existing = try SHA256Digest.hexFile(URL(fileURLWithPath: destination))
            if existing != row.sha256 {
                throw DisklesslyError.busy("move \(destination) aside before restoring; its bytes differ from the archived session")
            }
        } else if let legacy = row.legacyArchive {
            try restoreLegacyArchive(legacy, member: row.member, sha256: row.sha256, tool: row.tool, modified: entry.modified, destination: destination, backend: backend)
        } else if let segmentId = row.segmentId, let relative = paths[segmentId] {
            try restoreSegment(relative, member: row.member, sha256: row.sha256, tool: row.tool, modified: entry.modified, destination: destination, backend: backend, config: config, secrets: secrets)
        } else {
            throw DisklesslyError.integrity("session \(row.id) has no archive")
        }
        try database.setState(id: row.id, state: "restored")
        return SessionPaths.canonical(destination)
    }

    static func reindex(config: RuntimeConfig, backend: any StorageBackend, secrets: (any SecretStore)?) throws -> Int {
        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        let names = try listOrEmpty(backend, "sessions")
        var added = 0
        let keyring = try secrets.map { try SessionKeyStore.keyring(secrets: $0) } ?? [:]
        for name in names where isUUID(name) {
            let tools = try listOrEmpty(backend, "sessions/\(name)")
            for tool in tools {
                let files = try listOrEmpty(backend, "sessions/\(name)/\(tool)")
                for file in files where file.hasSuffix(".json") || file.hasSuffix(".json.enc") {
                    let relative = "sessions/\(name)/\(tool)/\(file)"
                    let raw = try backend.get(relative, range: nil)
                    let json = try sidecarJSON(raw, path: relative, keyring: keyring)
                    added += try importSidecar(json, database: database, localDevice: device.deviceId)
                }
            }
        }
        return added
    }

    static func verifyLegacy(config: RuntimeConfig, backend: any StorageBackend) throws -> [String] {
        let database = try SessionIndexDB(stateDir: config.stateDir)
        var missing: [String] = []
        for row in try database.allEntries() where row.legacyArchive != nil {
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-verify-\(UUID().uuidString).tar.gz")
            _ = try backend.download(row.legacyArchive ?? "", to: archive, offset: 0)
            defer { try? FileManager.default.removeItem(at: archive) }
            let listing = try tarList(archive)
            if !listing.contains(row.member) {
                missing.append(row.path)
            }
        }
        return missing
    }

    private static func encryptionKey(secrets: any SecretStore, enabled: Bool) throws -> SymmetricKey? {
        guard enabled else { return nil }
        guard let id = try SessionKeyStore.currentKeyId(secrets: secrets), let key = try SessionKeyStore.load(secrets: secrets, keyId: id) else {
            throw DisklesslyError.usage("no session key; run disklessly sessions key init")
        }
        return key
    }

    private struct Snap {
        var tool: String
        var member: SessionMemberDraft
    }

    private struct Group {
        var tool: String
        var members: [SessionMemberDraft]
    }

    private static func snapshot(cold: [SessionCandidate], config: RuntimeConfig, skipped: inout [(String, String)]) throws -> [Snap] {
        var drafts: [Snap] = []
        for candidate in cold {
            let url = URL(fileURLWithPath: candidate.path)
            guard let before = try? FileFingerprint.of(url: url) else {
                skipped.append((candidate.path, "changed while reading"))
                continue
            }
            if before.size > config.sessionMaxFileBytes {
                skipped.append((candidate.path, "too large to tier"))
                continue
            }
            let data = (try? Data(contentsOf: url)) ?? Data()
            guard let after = try? FileFingerprint.of(url: url), after == before else {
                skipped.append((candidate.path, "changed while reading"))
                continue
            }
            let sha = SHA256Digest.hex(data)
            drafts.append(Snap(tool: candidate.tool, member: SessionMemberDraft(entryId: "", path: candidate.path, sha256: sha, size: Int64(before.size), mtimeNs: before.mtimeNs, ino: Int64(before.ino), preview: candidate.preview, bytes: data, tool: candidate.tool)))
        }
        return drafts
    }

    private static func pack(_ drafts: [Snap], deviceId: String, config: RuntimeConfig) -> [Group] {
        let byTool = Dictionary(grouping: drafts) { $0.tool }
        var groups: [Group] = []
        for tool in byTool.keys.sorted() {
            let ordered = (byTool[tool] ?? []).sorted { $0.member.path < $1.member.path }
            var current: [SessionMemberDraft] = []
            var used: UInt64 = 0
            func flush() {
                if !current.isEmpty { groups.append(Group(tool: tool, members: current)) }
                current = []
                used = 0
            }
            for snap in ordered {
                let size = UInt64(max(0, snap.member.size))
                if size > config.sessionSoloBytes {
                    flush()
                    groups.append(Group(tool: tool, members: [snap.member]))
                    continue
                }
                if !current.isEmpty && used + size > config.sessionSegmentMaxBytes { flush() }
                current.append(snap.member)
                used += size
            }
            flush()
        }
        return groups.map { group in
            Group(tool: group.tool, members: group.members.map { member in
                var copy = member
                copy.entryId = SegmentWriter.entryId(deviceId: deviceId, path: member.path, sha256: member.sha256)
                return copy
            })
        }
    }

    private static func publish(_ built: BuiltSegment, backend: any StorageBackend) throws {
        try writeOnce(backend, built.relativePath, built.stored, built.sha256)
        let sidecarSha = SHA256Digest.hex(built.sidecar)
        try writeOnce(backend, built.sidecarPath, built.sidecar, sidecarSha)
    }

    private static func writeOnce(_ backend: any StorageBackend, _ path: String, _ data: Data, _ sha: String) throws {
        switch try WriteOnce.probe(backend, path) {
        case .absent:
            try backend.put(path, data: data)
            let round = try backend.get(path, range: nil)
            guard SHA256Digest.hex(round) == sha else {
                throw DisklesslyError.integrity("session segment hash does not match the bytes that were sent")
            }
        case .sha256(let existing) where existing == sha:
            return
        case .sha256:
            throw DisklesslyError.integrity("refusing to overwrite \(path): the existing bytes differ")
        case .placeholder:
            throw DisklesslyError.integrity("refusing to overwrite iCloud placeholder \(path)")
        }
    }

    private static func finishPending(database: SessionIndexDB, isOpen: (String) -> Bool, backend: any StorageBackend, config: RuntimeConfig, secrets: any SecretStore) throws -> [(String, String)] {
        var kept: [(String, String)] = []
        let pending = try database.allEntries().filter { $0.state == "pendingDelete" }
        let paths = try database.segmentPaths()
        var verified = Set<String>()
        for row in pending where FileManager.default.fileExists(atPath: row.path) {
            guard let segmentId = row.segmentId else {
                throw DisklesslyError.integrity("session \(row.id) has no archive; local file kept")
            }
            if verified.insert(segmentId).inserted {
                guard let relative = paths[segmentId] else {
                    throw DisklesslyError.integrity("session \(row.id) has no archive; local file kept")
                }
                try verifyIndexedSegment(relative: relative, segmentId: segmentId, database: database, backend: backend, config: config, secrets: secrets)
            }
        }
        for row in pending {
            let member = SessionMemberDraft(entryId: row.id, path: row.path, sha256: row.sha256, size: row.size, mtimeNs: row.mtimeNs, ino: row.ino ?? 0, preview: row.preview, bytes: Data(), tool: row.tool)
            if let reason = try settle(member, database: database, isOpen: isOpen, txid: String(row.id.prefix(8))) {
                kept.append((row.path, reason))
            }
        }
        return kept
    }

    /// Returns a kept-local reason, or nil when the file was removed and marked archived.
    private static func settle(_ member: SessionMemberDraft, database: SessionIndexDB, isOpen: (String) -> Bool, txid: String) throws -> String? {
        let url = URL(fileURLWithPath: member.path)
        let fm = FileManager.default
        let deleting = member.path + ".disklessly-deleting-\(txid)"
        let deletingURL = URL(fileURLWithPath: deleting)
        if !fm.fileExists(atPath: member.path) {
            if fm.fileExists(atPath: deleting) {
                let sha = try SHA256Digest.hexFile(deletingURL)
                if sha == member.sha256 {
                    try fm.removeItem(at: deletingURL)
                }
            }
            try database.setState(id: member.entryId, state: "archived")
            return nil
        }
        guard let again = try? FileFingerprint.of(url: url) else {
            try database.setState(id: member.entryId, state: "keptLocal")
            return "modified after archiving"
        }
        let sameStat = again.ino == UInt64(member.ino) && Int64(again.size) == member.size && again.mtimeNs == member.mtimeNs
        let sameHash = try SHA256Digest.hexFile(url) == member.sha256
        if !sameStat || isOpen(member.path) || !sameHash {
            try database.setState(id: member.entryId, state: "keptLocal")
            let reason = isOpen(member.path) ? "open" : "modified after archiving"
            return reason
        }
        if fm.fileExists(atPath: deleting) { try fm.removeItem(at: deletingURL) }
        try fm.moveItem(at: url, to: deletingURL)
        if let renamed = try? FileFingerprint.of(url: deletingURL), renamed.ino == UInt64(member.ino), Int64(renamed.size) == member.size, renamed.mtimeNs == member.mtimeNs {
            try fm.removeItem(at: deletingURL)
            try database.setState(id: member.entryId, state: "archived")
            return nil
        }
        if !fm.fileExists(atPath: member.path) {
            try? fm.moveItem(at: deletingURL, to: url)
        }
        try database.setState(id: member.entryId, state: "keptLocal")
        return "\(deleting) kept for review"
    }

    /// Archived sessions for display. Reads the SQLite index only when it already
    /// exists (no migration, no file creation) and falls back to the legacy JSON index.
    static func archivedForDisplay(config: RuntimeConfig) throws -> [SessionIndexEntry] {
        let sqlite = URL(fileURLWithPath: config.stateDir).appendingPathComponent("sessions/index.sqlite")
        guard FileManager.default.fileExists(atPath: sqlite.path) else {
            return try SessionArchive.loadIndex(config.stateDir).entries
        }
        let database = try SessionIndexDB(stateDir: config.stateDir)
        let paths = try database.segmentPaths()
        let current = try database.allEntries().compactMap { row in row.state == "restored" ? nil : indexEntry(row, paths: paths) }
        let ids = Set(current.map(\.id))
        // Entries not yet migrated from the legacy JSON index still count.
        let legacy = ((try? SessionArchive.loadIndex(config.stateDir).entries) ?? []).filter { !ids.contains($0.id) }
        return current + legacy
    }

    private static func indexed(config: RuntimeConfig, includeRestored: Bool) throws -> [SessionIndexEntry] {
        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        _ = try SessionMigration.migrateIfNeeded(stateDir: config.stateDir, deviceId: device.deviceId, database: database)
        let paths = try database.segmentPaths()
        return try database.allEntries().compactMap { row in
            if !includeRestored && row.state == "restored" { return nil }
            return indexEntry(row, paths: paths)
        }
    }

    private static func indexEntry(_ row: SessionEntryRow, paths: [String: String]) -> SessionIndexEntry {
        let archive = row.legacyArchive ?? row.segmentId.flatMap { paths[$0] } ?? ""
        return SessionIndexEntry(id: row.id, tool: row.tool, path: row.path, sha256: row.sha256, size: UInt64(max(0, row.size)), modified: Date(timeIntervalSince1970: Double(row.mtimeNs) / 1_000_000_000), archive: archive, member: row.member, preview: row.preview, digest: row.digest.isEmpty ? nil : row.digest)
    }

    private static func restoreLegacyArchive(_ archivePath: String, member: String, sha256: String, tool: String, modified: Date, destination: String, backend: any StorageBackend) throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-session-\(UUID().uuidString).tar.gz")
        _ = try backend.download(archivePath, to: archive, offset: 0)
        defer { try? FileManager.default.removeItem(at: archive) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try SessionArchive.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path, member])
        try place(staging.appendingPathComponent(member), sha256: sha256, tool: tool, modified: modified, destination: destination)
    }

    /// Solo files may be as large as `sessionMaxFileBytes`. The tar around that
    /// member needs a little slack past the file itself.
    static func decompressLimit(_ config: RuntimeConfig) -> Int {
        let slack: UInt64 = 1_048_576
        let base = max(config.sessionSegmentMaxBytes, config.sessionMaxFileBytes)
        let cap = base > UInt64.max - slack ? UInt64.max : base + slack
        if cap > UInt64(Int.max) { return Int.max }
        return Int(cap)
    }

    private static func restoreSegment(_ relative: String, member: String, sha256: String, tool: String, modified: Date, destination: String, backend: any StorageBackend, config: RuntimeConfig, secrets: (any SecretStore)?) throws {
        let entries = try openSegment(relative, backend: backend, config: config, secrets: secrets, expectIndexed: true)
        guard let found = entries.first(where: { $0.name == member }) else {
            throw DisklesslyError.integrity("session member \(member) is missing from \(relative)")
        }
        guard SHA256Digest.hex(found.data) == sha256 else {
            throw DisklesslyError.integrity("session member \(member) hash does not match the index")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-member-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("member")
        try found.data.write(to: file)
        try place(file, sha256: sha256, tool: tool, modified: modified, destination: destination)
    }

    /// Decrypt, decompress, and untar a stored segment. When `expectIndexed` is
    /// set, the sha of the stored bytes must be the segment id recorded for this path.
    private static func openSegment(_ relative: String, backend: any StorageBackend, config: RuntimeConfig, secrets: (any SecretStore)?, expectIndexed: Bool) throws -> [(name: String, data: Data)] {
        let downloaded = try backend.get(relative, range: nil)
        if expectIndexed {
            let segmentId = SHA256Digest.hex(downloaded)
            let known = try SessionIndexDB(stateDir: config.stateDir).segmentPaths()
            guard known[segmentId] == relative else {
                throw DisklesslyError.integrity("session segment hash does not match the index")
            }
        }
        let keyring = try secrets.map { try SessionKeyStore.keyring(secrets: $0) } ?? [:]
        let compressed = try SegmentWriter.plaintext(stored: downloaded, relativePath: relative, keyring: keyring)
        let tar = try Zstd.decompress(compressed, maxBytes: decompressLimit(config))
        return try TarReader.entries(tar)
    }

    private static func verifyMembers(relative: String, members: [SessionMemberDraft], backend: any StorageBackend, config: RuntimeConfig, secrets: any SecretStore) throws {
        let entries = try openSegment(relative, backend: backend, config: config, secrets: secrets, expectIndexed: false)
        for member in members {
            let name = "m/\(member.entryId).jsonl"
            guard let found = entries.first(where: { $0.name == name }) else {
                throw DisklesslyError.integrity("session member \(name) is missing from \(relative); local file kept")
            }
            guard SHA256Digest.hex(found.data) == member.sha256 else {
                throw DisklesslyError.integrity("session member \(name) hash does not match the index; local file kept")
            }
        }
    }

    private static func verifyIndexedSegment(relative: String, segmentId: String, database: SessionIndexDB, backend: any StorageBackend, config: RuntimeConfig, secrets: any SecretStore) throws {
        let entries = try openSegment(relative, backend: backend, config: config, secrets: secrets, expectIndexed: true)
        let rows = try database.allEntries().filter { $0.segmentId == segmentId }
        guard !rows.isEmpty else {
            throw DisklesslyError.integrity("session segment \(relative) has no index rows; local file kept")
        }
        for row in rows {
            guard let found = entries.first(where: { $0.name == row.member }) else {
                throw DisklesslyError.integrity("session member \(row.member) is missing from \(relative); local file kept")
            }
            guard SHA256Digest.hex(found.data) == row.sha256 else {
                throw DisklesslyError.integrity("session member \(row.member) hash does not match the index; local file kept")
            }
        }
    }

    private static func place(_ extracted: URL, sha256: String, tool: String, modified: Date, destination: String) throws {
        guard try SHA256Digest.hexFile(extracted) == sha256 else {
            throw DisklesslyError.integrity("restored session hash does not match the index")
        }
        let dest = URL(fileURLWithPath: destination)
        let held = extracted.deletingLastPathComponent().appendingPathComponent("held-\(UUID().uuidString)")
        try ChunkedIO.copyFile(from: extracted, to: held)
        try ChunkedIO.replaceFile(dest, with: held)
        let restoredDate = tool == "claude" ? Date() : modified
        try FileManager.default.setAttributes([.modificationDate: restoredDate], ofItemAtPath: SessionPaths.canonical(dest.path))
    }

    private static func listOrEmpty(_ backend: any StorageBackend, _ path: String) throws -> [String] {
        do { return try backend.list(path) }
        catch let error as DisklesslyError where error.exitCode == 4 { throw error }
        catch { return [] }
    }

    private static func isUUID(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    private static func sidecarJSON(_ data: Data, path: String, keyring: [String: SymmetricKey]) throws -> [String: Any] {
        let plain: Data
        if path.hasSuffix(".enc") {
            plain = try SegmentCrypto.open(envelope: data, keyring: keyring, aad: Data(path.utf8))
        } else {
            plain = data
        }
        guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw DisklesslyError.integrity("session sidecar \(path) is not an object")
        }
        return object
    }

    private static func importSidecar(_ json: [String: Any], database: SessionIndexDB, localDevice: String) throws -> Int {
        guard let segment = json["segment"] as? String, let sha = json["sha256"] as? String else { return 0 }
        let device = json["deviceId"] as? String ?? ""
        let tool = json["tool"] as? String ?? ""
        let created = json["createdAt"] as? String ?? ""
        let bytes = (json["bytes"] as? NSNumber)?.int64Value ?? 0
        let codec = json["codec"] as? String ?? "zstd-3"
        let encrypted = (json["encryption"] as? String) == "aes-256-gcm"
        let keyId = json["keyId"] as? String
        if try database.segmentPaths()[sha] == nil {
            let members = json["members"] as? [[String: Any]] ?? []
            var entries: [SessionEntryRow] = []
            for member in members {
                guard let id = member["id"] as? String else { continue }
                if try database.hasEntry(id: id) { continue }
                entries.append(SessionEntryRow(
                    id: id,
                    segmentId: sha,
                    legacyArchive: nil,
                    member: member["member"] as? String ?? "m/\(id).jsonl",
                    deviceId: device,
                    tool: tool,
                    path: member["path"] as? String ?? "",
                    sha256: member["sha256"] as? String ?? "",
                    size: (member["size"] as? NSNumber)?.int64Value ?? 0,
                    mtimeNs: (member["mtimeNs"] as? NSNumber)?.int64Value ?? 0,
                    ino: nil,
                    preview: member["preview"] as? String ?? "",
                    archivedAt: created,
                    state: device == localDevice ? "archived" : "remote"
                ))
            }
            if try database.segmentPaths()[sha] == nil {
                try database.commit(segment: SessionSegmentRow(id: sha, path: segment, deviceId: device, tool: tool, createdAt: created, bytes: bytes, codec: codec, encrypted: encrypted, keyId: keyId), entries: entries)
                return entries.count
            }
        }
        return 0
    }

    private static func tarList(_ archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw DisklesslyError.failure("tar list failed") }
        return text.split(separator: "\n").map(String.init)
    }
}
