import Foundation
import DisklesslyCore

public enum SessionMigration {
    public static func jsonURL(_ stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("sessions-index.json")
    }

    public static func migratedURL(_ stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("sessions-index.json.migrated-v2")
    }

    /// Copy v1 index rows into SQLite and rename the JSON file. The old tar.gz objects stay.
    public static func migrateIfNeeded(stateDir: String, deviceId: String, database: SessionIndexDB) throws -> Bool {
        let source = jsonURL(stateDir)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(SessionIndex.self, from: Data(contentsOf: source))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var rows: [SessionEntryRow] = []
        for entry in index.entries {
            let mtime = Int64(entry.modified.timeIntervalSince1970 * 1_000_000_000)
            rows.append(SessionEntryRow(
                id: entry.id,
                segmentId: nil,
                legacyArchive: entry.archive,
                member: entry.member,
                deviceId: deviceId,
                tool: entry.tool,
                path: entry.path,
                sha256: entry.sha256,
                size: Int64(entry.size),
                mtimeNs: mtime,
                ino: nil,
                preview: entry.preview,
                archivedAt: formatter.string(from: entry.modified),
                state: "archived"
            ))
        }
        if !rows.isEmpty {
            try database.insert(entries: rows)
        }
        let destination = migratedURL(stateDir)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return true
    }
}
