import Crypto
import Foundation
import DisklesslyCore
import DisklesslySessions

enum SessionTierV2 {
    static func apply(config: RuntimeConfig, backend: any StorageBackend, now: Date, cold: [SessionCandidate], skipped: [(String, String)], secrets: (any SecretStore)?, encrypt: Bool, isOpen: (String) -> Bool, beforeDelete: ((String) -> Void)?, afterIndexCommit: (() throws -> Void)?, exclusions: (() -> SessionExclusions)? = nil) throws -> SessionReport {
        let lockURL = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/sessions.lock")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lock = FileLock(path: lockURL.path)
        guard try lock.tryLock() else { throw DisklesslyError.busy("sessions are already being tiered") }
        defer { lock.unlock() }

        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        _ = try SessionMigration.migrateIfNeeded(stateDir: config.stateDir, deviceId: device.deviceId, database: database)
        // Runs last, also when the run throws: text files of transcripts that did
        // not end up indexed, or of an older version of the same session, are
        // removed, and headers still without a segment are filled in.
        defer { pruneTextIndex(database: database, deviceId: device.deviceId, stateDir: config.stateDir) }
        let store = secrets ?? MemorySecretStore()
        // The exclusion list is read again before each local delete, so a session
        // referenced after the run started is still kept.
        let referenced: (String, String) -> Bool = { tool, path in exclusions?().matches(tool: tool, path: path) ?? false }
        let settled = try finishPending(database: database, isOpen: isOpen, backend: backend, config: config, secrets: store, referenced: referenced)
        var kept = settled.kept
        var archived = settled.archived
        let wantsEncryption = encrypt || config.sessionEncryption == "aes-gcm"
        let key = try encryptionKey(secrets: store, enabled: wantsEncryption)
        var extraSkipped = skipped
        let snapped = try snapshot(cold: cold, config: config, skipped: &extraSkipped)
        // Digests, titles and the plain-text index come from the snapshot bytes,
        // before anything is written to the repo, so a slow or failing digest cannot
        // leave an unindexed segment. A transcript whose text index cannot be
        // written is neither uploaded nor deleted, so every archived session of this
        // device stays searchable locally.
        var digests: [String: String] = [:]
        var titles: [String: String] = [:]
        var texts: [String: [SessionDigest.Message]] = [:]
        var drafts: [Snap] = []
        for var draft in snapped {
            digests[draft.member.path] = SessionDigest.digest(tool: draft.tool, path: draft.member.path, data: draft.member.bytes)
            // The row's preview holds the session title, so the list can show what each one was about.
            let title = SessionDigest.title(tool: draft.tool, path: draft.member.path, data: draft.member.bytes)
            if !title.isEmpty { titles[draft.member.path] = title }
            draft.member.title = title
            draft.member.cwd = SessionDigest.workingDirectory(draft.member.bytes) ?? ""
            draft.member.firstPrompt = SessionDigest.firstPrompt(tool: draft.tool, path: draft.member.path, data: draft.member.bytes)
            draft.member.entryId = SegmentWriter.entryId(deviceId: device.deviceId, path: draft.member.path, sha256: draft.member.sha256)
            let messages = SessionText.messages(tool: draft.tool, path: draft.member.path, data: draft.member.bytes)
            // The entry id covers the bytes, so an existing file already holds this
            // text; it is left as it is (its header may carry the segment of a
            // stored copy that reuseStored settles against).
            do {
                if !SessionTextIndex.exists(stateDir: config.stateDir, id: draft.member.entryId) {
                    try SessionTextIndex.write(header: textHeader(draft.member, deviceId: device.deviceId, segment: "", archivedAt: ""), messages: messages, stateDir: config.stateDir)
                }
            } catch {
                extraSkipped.append((draft.member.path, "text index failed"))
                continue
            }
            texts[draft.member.path] = messages
            drafts.append(draft)
        }
        // Fills in the segment and archive time once known, still before the
        // delete. The file written above already exists, so a failure here does not
        // block the delete; pruneTextIndex fills the header in on this or a later run.
        let retext: (SessionMemberDraft, String, String) -> Void = { member, segment, archivedAt in
            try? SessionTextIndex.write(header: textHeader(member, deviceId: device.deviceId, segment: segment, archivedAt: archivedAt), messages: texts[member.path] ?? [], stateDir: config.stateDir)
        }
        // A transcript already in a stored segment (restored or kept local, then
        // unchanged) is settled against that segment instead of being uploaded again,
        // so no orphan copy is left behind.
        let described = try reuseStored(drafts, deviceId: device.deviceId, database: database, backend: backend, config: config, secrets: store, isOpen: isOpen, beforeDelete: beforeDelete, referenced: referenced, retext: retext, kept: &kept, archived: &archived)
        let groups = pack(described, deviceId: device.deviceId, config: config, encrypted: key != nil)
        var segments: [String] = []
        for group in groups {
            let built = try SegmentWriter.build(deviceId: device.deviceId, tool: group.tool, now: now, members: group.members, key: key, project: group.project, month: group.month)
            try publish(built, backend: backend)
            // Round-trip the stored object before the index says pendingDelete.
            // A later finishPending settles that state, so a failed check must
            // leave the index alone and the local file in place.
            try verifyMembers(relative: built.relativePath, members: group.members, backend: backend, config: config, secrets: store)
            let created = SegmentWriter.createdAt(now)
            let row = SessionSegmentRow(id: built.sha256, path: built.relativePath, deviceId: device.deviceId, tool: group.tool, createdAt: created, bytes: Int64(built.stored.count), codec: built.codec, encrypted: key != nil, keyId: built.keyId)
            // The transcript itself is what was packed; the digest only goes into the index.
            let entries = group.members.map { member in
                SessionEntryRow(id: member.entryId, segmentId: built.sha256, legacyArchive: nil, member: "m/\(member.entryId).jsonl", deviceId: device.deviceId, tool: member.tool, path: member.path, sha256: member.sha256, size: member.size, mtimeNs: member.mtimeNs, ino: member.ino, preview: titles[member.path] ?? member.preview, archivedAt: created, state: "pendingDelete", digest: digests[member.path] ?? "", cwd: member.cwd, firstPrompt: member.firstPrompt)
            }
            try database.commit(segment: row, entries: entries)
            for entry in entries {
                // A digest file is a convenience; failing to write it never blocks the run.
                try? writeDigestFile(entry, stateDir: config.stateDir)
            }
            segments.append(built.relativePath)
            if let afterIndexCommit { try afterIndexCommit() }
            for member in group.members {
                retext(member, built.relativePath, created)
                beforeDelete?(member.path)
                if let reason = try settle(member, database: database, isOpen: isOpen, txid: String(built.sha256.prefix(8)), referenced: referenced) {
                    kept.append((member.path, reason))
                } else {
                    archived.append(archivedItem(member))
                }
            }
        }
        // Original size of what this run archived, so a member kept local is not counted.
        let uploadedBytes = archived.reduce(Int64(0)) { $0 + $1.bytes }
        return SessionReport(cold: cold.map(\.path), skipped: extraSkipped, applied: true, keptLocal: kept, segments: segments, archived: archived, uploadedBytes: uploadedBytes)
    }

    static func textHeader(_ member: SessionMemberDraft, deviceId: String, segment: String, archivedAt: String) -> SessionText.Header {
        SessionText.Header(entryId: member.entryId, deviceId: deviceId, sessionId: SessionIdentity.sessionId(tool: member.tool, path: member.path), tool: member.tool, path: member.path, cwd: member.cwd, title: member.title, firstPrompt: member.firstPrompt, mtime: SessionTextIndex.rfc3339(mtimeNs: member.mtimeNs), archivedAt: archivedAt, bytes: member.size, segment: segment)
    }

    /// Keeps one text file per session of this device: the one of the newest
    /// index row for its path (a row that is not restored before a restored one).
    /// Files with no index row (a run that failed or stopped after the first
    /// write), files of older versions of a path, and leftover temp files are
    /// removed. A kept file whose header still lacks the segment or archive time
    /// gets them from the row. Failures are ignored; the next run tries again.
    static func pruneTextIndex(database: SessionIndexDB, deviceId: String, stateDir: String) {
        let (ids, temps) = SessionTextIndex.listing(stateDir: stateDir)
        let dir = SessionTextIndex.directory(stateDir: stateDir)
        for name in temps { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        guard !ids.isEmpty, let rows = try? database.allEntries(), let paths = try? database.segmentPaths() else { return }
        let mine = rows.filter { $0.deviceId == deviceId }
        var current: [String: SessionEntryRow] = [:]
        for row in mine {
            guard let other = current[row.path] else { current[row.path] = row; continue }
            let rank = { (r: SessionEntryRow) in (r.state == "restored" ? 0 : 1, r.archivedAt, r.mtimeNs, r.id) }
            if rank(other) < rank(row) { current[row.path] = row }
        }
        let keep = Dictionary(current.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            guard let row = keep[id] else {
                try? FileManager.default.removeItem(at: SessionTextIndex.url(stateDir: stateDir, id: id))
                continue
            }
            let segment = row.segmentId.flatMap { paths[$0] } ?? row.legacyArchive ?? ""
            guard !segment.isEmpty, var header = SessionTextIndex.header(stateDir: stateDir, id: id),
                  header.segment.isEmpty || header.archivedAt.isEmpty else { continue }
            header.segment = segment
            header.archivedAt = row.archivedAt
            try? SessionTextIndex.rewriteHeader(header, stateDir: stateDir)
        }
    }

    private static func archivedItem(_ member: SessionMemberDraft) -> SessionArchivedItem {
        SessionArchivedItem(id: member.entryId, path: member.path, sessionId: SessionIdentity.sessionId(tool: member.tool, path: member.path), bytes: member.size)
    }

    /// Settles drafts whose entry id already has a row in a stored segment and
    /// returns the rest. The stored segment is checked first; one that cannot be
    /// read is skipped here and the draft is uploaded again as usual.
    private static func reuseStored(_ drafts: [Snap], deviceId: String, database: SessionIndexDB, backend: any StorageBackend, config: RuntimeConfig, secrets: any SecretStore, isOpen: (String) -> Bool, beforeDelete: ((String) -> Void)?, referenced: (String, String) -> Bool, retext: (SessionMemberDraft, String, String) -> Void, kept: inout [(String, String)], archived: inout [SessionArchivedItem]) throws -> [Snap] {
        let rows = Dictionary(try database.allEntries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = try database.segmentPaths()
        var good = Set<String>()
        var bad = Set<String>()
        var rest: [Snap] = []
        for draft in drafts {
            let id = SegmentWriter.entryId(deviceId: deviceId, path: draft.member.path, sha256: draft.member.sha256)
            guard let row = rows[id], row.state == "restored" || row.state == "keptLocal",
                  row.sha256 == draft.member.sha256, let segmentId = row.segmentId, let relative = paths[segmentId], !bad.contains(segmentId) else {
                rest.append(draft)
                continue
            }
            if !good.contains(segmentId) {
                do {
                    try verifyIndexedSegment(relative: relative, segmentId: segmentId, database: database, backend: backend, config: config, secrets: secrets)
                    good.insert(segmentId)
                } catch let error as DisklesslyError where error.exitCode == 4 {
                    throw error
                } catch {
                    bad.insert(segmentId)
                    rest.append(draft)
                    continue
                }
            }
            var member = draft.member
            member.entryId = id
            try database.setState(id: id, state: "pendingDelete")
            retext(member, relative, row.archivedAt)
            beforeDelete?(member.path)
            if let reason = try settle(member, database: database, isOpen: isOpen, txid: String(segmentId.prefix(8)), referenced: referenced) {
                kept.append((member.path, reason))
            } else {
                archived.append(archivedItem(member))
            }
        }
        return rest
    }

    /// Paths of transcripts restored less than `days` ago (by the file's status
    /// change time, which the restore sets) and unchanged since: same size and
    /// mtime as the restored row. pi and Codex get their old mtime back on
    /// restore, so without this the next run would archive them again at once.
    static func recentlyRestored(config: RuntimeConfig, candidates: [SessionCandidate], now: Date, days: Int) -> Set<String> {
        let sqlite = URL(fileURLWithPath: config.stateDir).appendingPathComponent("sessions/index.sqlite")
        guard FileManager.default.fileExists(atPath: sqlite.path),
              let database = try? SessionIndexDB(stateDir: config.stateDir),
              let rows = try? database.allEntries() else { return [] }
        let restored = Dictionary(grouping: rows.filter { $0.state == "restored" }, by: \.path)
        guard !restored.isEmpty else { return [] }
        var held = Set<String>()
        for candidate in candidates {
            guard let mine = restored[candidate.path],
                  let print = try? FileFingerprint.of(url: URL(fileURLWithPath: candidate.path)),
                  mine.contains(where: { $0.size == Int64(print.size) && $0.mtimeNs == print.mtimeNs }) else { continue }
            guard let changed = statusChangeTime(candidate.path) else { held.insert(candidate.path); continue }
            if now.timeIntervalSince(changed) < Double(days) * 86_400 { held.insert(candidate.path) }
        }
        return held
    }

    static func statusChangeTime(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if os(Linux)
        return Date(timeIntervalSince1970: Double(info.st_ctim.tv_sec) + Double(info.st_ctim.tv_nsec) / 1_000_000_000)
        #else
        return Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000)
        #endif
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

    /// The backend is opened only when the transcript has to be downloaded. With
    /// `requireRepoMarker`, the marker may answer from a mirror: reads fail over to
    /// mirrors, so a primary without `repo.json` does not block a mirror's copy.
    static func restore(config: RuntimeConfig, backend open: () throws -> any StorageBackend, query: String, to: String?, secrets: (any SecretStore)?, requireRepoMarker: Bool = false) throws -> SessionRestoreResult {
        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        _ = try SessionMigration.migrateIfNeeded(stateDir: config.stateDir, deviceId: device.deviceId, database: database)
        let rows = try database.allEntries()
        let paths = try database.segmentPaths()
        let entries = rows.map { indexEntry($0, paths: paths) }
        let matches = SessionIndex(entries: entries).matches(query)
        guard !matches.isEmpty else { throw DisklesslyError.usage("no cold session matches \(query)") }
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = matches.compactMap { byId[$0.id] }
        let row: SessionEntryRow
        if candidates.count == 1 {
            row = candidates[0]
        } else if let exact = candidates.first(where: { $0.id == query }) {
            row = exact
        } else if candidates.count > 1, Set(candidates.map(\.path)).count == 1 {
            // One path archived more than once (restored, changed, archived again):
            // this device's newest row that is not already restored.
            row = preferredRow(candidates, localDevice: device.deviceId)
        } else {
            throw DisklesslyError.usage("session query \(query) matches \(matches.count) entries")
        }
        guard let entry = entries.first(where: { $0.id == row.id }) else { throw DisklesslyError.usage("no cold session matches \(query)") }
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
            let backend = try open()
            if requireRepoMarker { try SessionBackendCheck.require(backend, mirrors: true) }
            try restoreLegacyArchive(legacy, member: row.member, sha256: row.sha256, tool: row.tool, modified: entry.modified, destination: destination, backend: backend)
        } else if let segmentId = row.segmentId, let relative = paths[segmentId] {
            let backend = try open()
            if requireRepoMarker { try SessionBackendCheck.require(backend, mirrors: true) }
            try restoreSegment(relative, member: row.member, sha256: row.sha256, tool: row.tool, modified: entry.modified, destination: destination, backend: backend, config: config, secrets: secrets)
        } else {
            throw DisklesslyError.integrity("session \(row.id) has no archive")
        }
        try database.setState(id: row.id, state: "restored")
        return SessionRestoreResult(path: SessionPaths.canonical(destination), id: row.id, sessionId: SessionIdentity.sessionId(tool: row.tool, path: row.path))
    }

    /// This device first, then rows not yet restored, then the newest archive.
    static func preferredRow(_ rows: [SessionEntryRow], localDevice: String) -> SessionEntryRow {
        rows.max { lhs, rhs in
            let left = (lhs.deviceId == localDevice ? 1 : 0, lhs.state == "restored" ? 0 : 1, lhs.archivedAt, lhs.mtimeNs)
            let right = (rhs.deviceId == localDevice ? 1 : 0, rhs.state == "restored" ? 0 : 1, rhs.archivedAt, rhs.mtimeNs)
            return left < right
        } ?? rows[0]
    }

    static func reindex(config: RuntimeConfig, backend: any StorageBackend, secrets: (any SecretStore)?, requireRepoMarker: Bool = false) throws -> Int {
        if requireRepoMarker { try SessionBackendCheck.require(backend) }
        let device = try LocalDeviceStore.loadOrCreate(stateDir: URL(fileURLWithPath: config.stateDir), suggestedName: "mac")
        let database = try SessionIndexDB(stateDir: config.stateDir)
        let names = try listOrEmpty(backend, "sessions")
        var added = 0
        let keyring = try secrets.map { try SessionKeyStore.keyring(secrets: $0) } ?? [:]
        for name in names where isUUID(name) {
            // Both the flat layout (`<uuid>/<tool>/*.json`) and the partitioned one
            // (`<uuid>/<tool>/<project>/<yyyy-MM>/*.json`) are read.
            for relative in try sidecars(backend, under: "sessions/\(name)", depth: 0) {
                let raw = try backend.get(relative, range: nil)
                let json = try sidecarJSON(raw, path: relative, keyring: keyring)
                added += try importSidecar(json, database: database, localDevice: device.deviceId)
            }
        }
        return added
    }

    /// Sidecar paths (`.json`, `.json.enc`) under `path`, at most four folders deep.
    private static func sidecars(_ backend: any StorageBackend, under path: String, depth: Int) throws -> [String] {
        guard depth <= 4 else { return [] }
        let children: [BackendEntry]
        do { children = try backend.entries(path) }
        catch let error as DisklesslyError where error.exitCode == 4 { throw error }
        catch { return [] }
        var found: [String] = []
        for child in children {
            let relative = "\(path)/\(child.name)"
            if child.isDirectory {
                found += try sidecars(backend, under: relative, depth: depth + 1)
            } else if child.name.hasSuffix(".json") || child.name.hasSuffix(".json.enc") {
                found.append(relative)
            }
        }
        return found.sorted()
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
        var project: String
        var month: String
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

    /// Segments are grouped by (tool, project, month), then cut by size.
    private static func pack(_ drafts: [Snap], deviceId: String, config: RuntimeConfig, encrypted: Bool) -> [Group] {
        struct Partition: Hashable, Comparable {
            var tool: String
            var project: String
            var month: String
            static func < (lhs: Partition, rhs: Partition) -> Bool {
                (lhs.tool, lhs.project, lhs.month) < (rhs.tool, rhs.project, rhs.month)
            }
        }
        let byPartition = Dictionary(grouping: drafts) { snap in
            Partition(tool: snap.tool,
                      project: SessionIdentity.projectKey(cwd: snap.member.cwd, encrypted: encrypted),
                      month: SessionIdentity.month(mtimeNs: snap.member.mtimeNs))
        }
        var groups: [Group] = []
        for partition in byPartition.keys.sorted() {
            let tool = partition.tool
            let ordered = (byPartition[partition] ?? []).sorted { $0.member.path < $1.member.path }
            var current: [SessionMemberDraft] = []
            var used: UInt64 = 0
            func flush() {
                if !current.isEmpty { groups.append(Group(tool: tool, project: partition.project, month: partition.month, members: current)) }
                current = []
                used = 0
            }
            for snap in ordered {
                let size = UInt64(max(0, snap.member.size))
                if size > config.sessionSoloBytes {
                    flush()
                    groups.append(Group(tool: tool, project: partition.project, month: partition.month, members: [snap.member]))
                    continue
                }
                if !current.isEmpty && used + size > config.sessionSegmentMaxBytes { flush() }
                current.append(snap.member)
                used += size
            }
            flush()
        }
        return groups.map { group in
            Group(tool: group.tool, project: group.project, month: group.month, members: group.members.map { member in
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

    /// Settles rows an earlier run left in pendingDelete. What it removes locally
    /// is reported as archived by this run.
    private static func finishPending(database: SessionIndexDB, isOpen: (String) -> Bool, backend: any StorageBackend, config: RuntimeConfig, secrets: any SecretStore, referenced: (String, String) -> Bool) throws -> (kept: [(String, String)], archived: [SessionArchivedItem]) {
        var kept: [(String, String)] = []
        var archived: [SessionArchivedItem] = []
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
            let member = SessionMemberDraft(entryId: row.id, path: row.path, sha256: row.sha256, size: row.size, mtimeNs: row.mtimeNs, ino: row.ino ?? 0, preview: row.preview, bytes: Data(), tool: row.tool, cwd: row.cwd, title: row.preview, firstPrompt: row.firstPrompt)
            // A row left by a run that had no text index gets one from the local
            // file before it is deleted; when that fails the file stays and the row
            // stays pending for the next run.
            // The run that wrote the row renamed the file with the segment id's prefix.
            let txid = String((row.segmentId ?? row.id).prefix(8))
            if !textIndexed(member, row: row, paths: paths, txid: txid, stateDir: config.stateDir) {
                kept.append((row.path, "text index failed"))
                continue
            }
            if let reason = try settle(member, database: database, isOpen: isOpen, txid: txid, referenced: referenced) {
                kept.append((row.path, reason))
            } else {
                archived.append(archivedItem(member))
            }
        }
        return (kept, archived)
    }

    /// True when the row's text index exists or was just written from the local
    /// bytes (the file, or the `.disklessly-deleting-<txid>` copy an interrupted
    /// delete left), or when there are no matching local bytes, so settle will
    /// not delete anything.
    private static func textIndexed(_ member: SessionMemberDraft, row: SessionEntryRow, paths: [String: String], txid: String, stateDir: String) -> Bool {
        let fm = FileManager.default
        guard !row.deviceId.isEmpty, !SessionTextIndex.exists(stateDir: stateDir, id: row.id) else { return true }
        let source = fm.fileExists(atPath: row.path) ? row.path : row.path + ".disklessly-deleting-\(txid)"
        guard fm.fileExists(atPath: source) else { return true }
        // settle deletes only bytes whose hash matches the row, so other bytes need no text.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: source)) else { return false }
        guard SHA256Digest.hex(data) == row.sha256 else { return true }
        let segment = row.segmentId.flatMap { paths[$0] } ?? row.legacyArchive ?? ""
        let messages = SessionText.messages(tool: row.tool, path: row.path, data: data)
        do {
            try SessionTextIndex.write(header: textHeader(member, deviceId: row.deviceId, segment: segment, archivedAt: row.archivedAt), messages: messages, stateDir: stateDir)
            return true
        } catch {
            return false
        }
    }

    /// Returns a kept-local reason, or nil when the file was removed and marked archived.
    private static func settle(_ member: SessionMemberDraft, database: SessionIndexDB, isOpen: (String) -> Bool, txid: String, referenced: (String, String) -> Bool = { _, _ in false }) throws -> String? {
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
        if referenced(member.tool, member.path) {
            try database.setState(id: member.entryId, state: "keptLocal")
            return "referenced"
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
                    preview: (member["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? member["preview"] as? String ?? "",
                    archivedAt: created,
                    state: device == localDevice ? "archived" : "remote",
                    cwd: member["cwd"] as? String ?? "",
                    firstPrompt: member["firstPrompt"] as? String ?? ""
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
