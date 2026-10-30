import Foundation
import IsenoughCore
import IsenoughStubSupport

/// The stable id of a repo, kept in `repo.json` as `repoId`.
///
/// Every Mac that uses the same repo reads the same `repo.json`, so they all
/// see the same id. Stubs record it in `stub.json` so a repo only claims its
/// own stubs (see `StubIdentity.belongs`).
public enum RepoIdentity {
    public static let path = "repo.json"

    /// The `repoId` in `repo.json`, or nil when the file is missing, unreadable,
    /// or was written before ids existed. Never writes.
    public static func read(_ backend: any StorageBackend) -> String? {
        guard let object = readObject(backend) else { return nil }
        return repoId(in: object)
    }

    /// Returns the repo's id, creating `repo.json` or adding `repoId` to an older
    /// one as needed. Other keys in an existing `repo.json` are kept.
    ///
    /// Returns nil, and writes nothing, when `repo.json` exists but cannot be read
    /// or parsed (for example an iCloud placeholder), so a good file is never
    /// replaced by a guess.
    @discardableResult
    public static func ensure(_ backend: any StorageBackend, now: Date = Date()) throws -> String? {
        var object: [String: Any]
        if try backend.stat(path) == nil {
            object = ["schema": "repo/1", "layoutVersion": 1, "createdAt": stamp(now)]
        } else {
            guard let existing = readObject(backend) else { return nil }
            if let id = repoId(in: existing) { return id }
            object = existing
            if object["schema"] == nil { object["schema"] = "repo/1" }
        }
        object["repoId"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try backend.put(path, data: data)
        // Another Mac may have written first; whatever the repo now holds wins.
        return read(backend) ?? (object["repoId"] as? String)
    }

    static func repoId(in object: [String: Any]) -> String? {
        guard let id = object["repoId"] as? String else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readObject(_ backend: any StorageBackend) -> [String: Any]? {
        guard let data = try? backend.get(path, range: nil),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Local copy

    /// Code that must not read the repo (stub regeneration during recovery) uses
    /// the id last seen for the configured repo. Keyed so switching repos does
    /// not reuse the old id.
    static func cacheURL(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("repo-identity.json")
    }

    static func cacheKey(_ config: RuntimeConfig) -> String {
        if let id = config.activeBackendId, !id.isEmpty { return "backend:\(id)" }
        return "path:" + (config.repoPath as NSString).standardizingPath
    }

    static func remember(_ repoId: String, config: RuntimeConfig) {
        let object: [String: Any] = ["repoKey": cacheKey(config), "repoId": repoId]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? AtomicFile.write(data, to: cacheURL(stateDir: config.stateDir))
    }

    static func remembered(config: RuntimeConfig) -> String? {
        guard let data = try? Data(contentsOf: cacheURL(stateDir: config.stateDir)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["repoKey"] as? String == cacheKey(config) else { return nil }
        return repoId(in: object)
    }
}

extension IsenoughEngine {
    /// The current repo's id, created on first use. Nil only when `repo.json`
    /// exists but cannot be read; callers then fall back to legacy rules.
    public func repoIdentity() throws -> String? {
        let id = try RepoIdentity.ensure(try repo)
        if let id { RepoIdentity.remember(id, config: config) }
        return id
    }

}
