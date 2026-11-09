import CSQLite
import Foundation
import DisklesslyCore

public struct SessionSegmentRow: Equatable {
    public var id: String
    public var path: String
    public var deviceId: String
    public var tool: String
    public var createdAt: String
    public var bytes: Int64
    public var codec: String
    public var encrypted: Bool
    public var keyId: String?
    public init(id: String, path: String, deviceId: String, tool: String, createdAt: String, bytes: Int64, codec: String, encrypted: Bool, keyId: String?) {
        self.id = id
        self.path = path
        self.deviceId = deviceId
        self.tool = tool
        self.createdAt = createdAt
        self.bytes = bytes
        self.codec = codec
        self.encrypted = encrypted
        self.keyId = keyId
    }
}

public struct SessionEntryRow: Equatable {
    public var id: String
    public var segmentId: String?
    public var legacyArchive: String?
    public var member: String
    public var deviceId: String
    public var tool: String
    public var path: String
    public var sha256: String
    public var size: Int64
    public var mtimeNs: Int64
    public var ino: Int64?
    public var preview: String
    public var archivedAt: String
    public var state: String
    /// Short text digest of the transcript (user prompts and final answers). Empty
    /// for rows archived before schema 3 or imported from another Mac.
    public var digest: String

    public init(id: String, segmentId: String?, legacyArchive: String?, member: String, deviceId: String, tool: String, path: String, sha256: String, size: Int64, mtimeNs: Int64, ino: Int64?, preview: String, archivedAt: String, state: String, digest: String = "") {
        self.id = id
        self.segmentId = segmentId
        self.legacyArchive = legacyArchive
        self.member = member
        self.deviceId = deviceId
        self.tool = tool
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.mtimeNs = mtimeNs
        self.ino = ino
        self.preview = preview
        self.archivedAt = archivedAt
        self.state = state
        self.digest = digest
    }
}

public final class SessionIndexDB {
    /// Schema 3 added `entries.digest` and the `digest` FTS column.
    public static let schemaVersion: Int64 = 3
    private var db: OpaquePointer?
    private var compiledFTS = false
    public var ftsAvailable = false

    public init(stateDir: String) throws {
        let directory = URL(fileURLWithPath: stateDir).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DisklesslyError.failure("cannot open session index \(path)")
        }
        db = handle
        // The dashboard reads while an apply holds a write transaction.
        sqlite3_busy_timeout(handle, 5_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=FULL")
        var version = try pragma("user_version")
        if version > Self.schemaVersion {
            throw DisklesslyError.unsupported("session index is from a newer disklessly")
        }
        var fts = false
        if version == 2 {
            try migrateV2toV3()
            version = Self.schemaVersion
        }
        if version == 0 {
            try exec("BEGIN IMMEDIATE")
            do {
                try createTables()
                try exec("COMMIT")
            } catch {
                _ = try? exec("ROLLBACK")
                throw error
            }
            if sqlite3_compileoption_used("ENABLE_FTS5") == 1 {
                do {
                    try exec("CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(id UNINDEXED, path, preview, digest)")
                    fts = true
                } catch {
                    fts = false
                }
            }
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
        } else {
            fts = sqlite3_compileoption_used("ENABLE_FTS5") == 1 && tableExists("entries_fts")
        }
        compiledFTS = fts
        ftsAvailable = fts
    }

    deinit { sqlite3_close(db) }

    /// v2 → v3: add `entries.digest` and rebuild the FTS table with a digest
    /// column (FTS5 cannot add columns), all in one transaction.
    private func migrateV2toV3() throws {
        try exec("BEGIN IMMEDIATE")
        do {
            // Another process may have migrated between our read and the lock.
            if try pragma("user_version") == 2 {
                if !columnExists(table: "entries", column: "digest") {
                    try exec("ALTER TABLE entries ADD COLUMN digest TEXT NOT NULL DEFAULT ''")
                }
                if sqlite3_compileoption_used("ENABLE_FTS5") == 1 {
                    try exec("DROP TABLE IF EXISTS entries_fts")
                    try exec("CREATE VIRTUAL TABLE entries_fts USING fts5(id UNINDEXED, path, preview, digest)")
                    try exec("INSERT INTO entries_fts(id, path, preview, digest) SELECT id, path, preview, digest FROM entries")
                }
                try exec("PRAGMA user_version = 3")
            }
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let statement = try? prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    public func userVersion() throws -> Int64 { try pragma("user_version") }

    /// The stored digest of one entry, or nil when the row is missing.
    public func digest(id: String) throws -> String? {
        let statement = try prepare("SELECT digest FROM entries WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let raw = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: raw)
    }

    public func insert(entries: [SessionEntryRow]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for entry in entries {
                try insertOne(entry)
            }
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
    }

    public func allEntries() throws -> [SessionEntryRow] {
        let sql = "SELECT id, segment_id, legacy_archive, member, device_id, tool, path, sha256, size, mtime_ns, ino, preview, archived_at, state, digest FROM entries"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows: [SessionEntryRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(read(statement))
        }
        return rows
    }

    public func segmentPaths() throws -> [String: String] {
        let statement = try prepare("SELECT id, path FROM segments")
        defer { sqlite3_finalize(statement) }
        var paths: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let path = sqlite3_column_text(statement, 1) else { continue }
            paths[String(cString: id)] = String(cString: path)
        }
        return paths
    }

    public func setState(id: String, state: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE entries SET state = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, state)
            bind(statement, 2, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DisklesslyError.failure("session index update failed: \(message())")
            }
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
    }

    public func hasEntry(id: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM entries WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func commit(segment: SessionSegmentRow, entries: [SessionEntryRow]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
            INSERT INTO segments(id, path, device_id, tool, created_at, bytes, codec, encrypted, key_id)
            VALUES(?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, segment.id)
            bind(statement, 2, segment.path)
            bind(statement, 3, segment.deviceId)
            bind(statement, 4, segment.tool)
            bind(statement, 5, segment.createdAt)
            bind(statement, 6, segment.bytes)
            bind(statement, 7, segment.codec)
            bind(statement, 8, segment.encrypted ? Int64(1) : 0)
            bind(statement, 9, segment.keyId)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DisklesslyError.failure("session segment insert failed: \(message())")
            }
            for entry in entries {
                try insertOne(entry)
            }
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
    }

    private func read(_ statement: OpaquePointer?) -> SessionEntryRow {
        func text(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: raw)
        }
        let ino: Int64? = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 10)
        return SessionEntryRow(
            id: text(0) ?? "",
            segmentId: text(1),
            legacyArchive: text(2),
            member: text(3) ?? "",
            deviceId: text(4) ?? "",
            tool: text(5) ?? "",
            path: text(6) ?? "",
            sha256: text(7) ?? "",
            size: sqlite3_column_int64(statement, 8),
            mtimeNs: sqlite3_column_int64(statement, 9),
            ino: ino,
            preview: text(11) ?? "",
            archivedAt: text(12) ?? "",
            state: text(13) ?? "",
            digest: text(14) ?? ""
        )
    }

    public func search(query: String, limit: Int) throws -> [String] {
        if ftsAvailable && compiledFTS {
            return try queryIds("SELECT e.id FROM entries_fts f JOIN entries e ON e.id = f.id WHERE entries_fts MATCH ? LIMIT ?", query, limit)
        }
        let needle = "%" + query.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return try queryIds("SELECT id FROM entries WHERE path LIKE ? ESCAPE '\\' OR preview LIKE ? ESCAPE '\\' OR digest LIKE ? ESCAPE '\\' LIMIT ?", needle, limit, like: true)
    }

    private func createTables() throws {
        try exec("""
        CREATE TABLE segments(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE,
          device_id TEXT NOT NULL, tool TEXT NOT NULL, created_at TEXT NOT NULL, bytes INTEGER NOT NULL,
          codec TEXT NOT NULL, encrypted INTEGER NOT NULL, key_id TEXT)
        """)
        try exec("""
        CREATE TABLE entries(id TEXT PRIMARY KEY, segment_id TEXT, legacy_archive TEXT, member TEXT NOT NULL,
          device_id TEXT NOT NULL, tool TEXT NOT NULL, path TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
          mtime_ns INTEGER NOT NULL, ino INTEGER, preview TEXT NOT NULL, archived_at TEXT NOT NULL, state TEXT NOT NULL,
          digest TEXT NOT NULL DEFAULT '')
        """)
        try exec("CREATE INDEX entries_path ON entries(path)")
    }

    private func insertOne(_ entry: SessionEntryRow) throws {
        let sql = """
        INSERT INTO entries(id, segment_id, legacy_archive, member, device_id, tool, path, sha256, size, mtime_ns, ino, preview, archived_at, state, digest)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, entry.id)
        bind(statement, 2, entry.segmentId)
        bind(statement, 3, entry.legacyArchive)
        bind(statement, 4, entry.member)
        bind(statement, 5, entry.deviceId)
        bind(statement, 6, entry.tool)
        bind(statement, 7, entry.path)
        bind(statement, 8, entry.sha256)
        bind(statement, 9, entry.size)
        bind(statement, 10, entry.mtimeNs)
        if let ino = entry.ino { bind(statement, 11, ino) } else { sqlite3_bind_null(statement, 11) }
        bind(statement, 12, entry.preview)
        bind(statement, 13, entry.archivedAt)
        bind(statement, 14, entry.state)
        bind(statement, 15, entry.digest)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DisklesslyError.failure("session index insert failed: \(message())")
        }
        if ftsAvailable && compiledFTS {
            let fts = try prepare("INSERT INTO entries_fts(id, path, preview, digest) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(fts) }
            bind(fts, 1, entry.id)
            bind(fts, 2, entry.path)
            bind(fts, 3, entry.preview)
            bind(fts, 4, entry.digest)
            guard sqlite3_step(fts) == SQLITE_DONE else {
                throw DisklesslyError.failure("session index fts insert failed: \(message())")
            }
        }
    }

    private func queryIds(_ sql: String, _ query: String, _ limit: Int, like: Bool = false) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if like {
            bind(statement, 1, query)
            bind(statement, 2, query)
            bind(statement, 3, query)
            bind(statement, 4, Int64(limit))
        } else {
            bind(statement, 1, query)
            bind(statement, 2, Int64(limit))
        }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: text))
            }
        }
        return ids
    }

    @discardableResult
    private func exec(_ sql: String) throws -> Int32 {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let text = error.map { String(cString: $0) } ?? message()
            sqlite3_free(error)
            throw DisklesslyError.failure("session index sql failed: \(text)")
        }
        return status
    }

    private func tableExists(_ name: String) -> Bool {
        guard let statement = try? prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?") else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, name)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func pragma(_ name: String) throws -> Int64 {
        let statement = try prepare("PRAGMA \(name)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DisklesslyError.failure("session index prepare failed: \(message())")
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bind(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func message() -> String {
        guard let raw = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: raw)
    }
}
