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
    /// Only explicit commands call this (`init`, `stub refresh`); routine
    /// commands use `read` so two Macs never race to mint different ids.
    ///
    /// Returns nil, and writes nothing, when `repo.json` exists but cannot be read
    /// or parsed, when the root holds an iCloud placeholder or conflict copy of
    /// it (`.repo.json.icloud`, `repo 2.json`), or when `repo.json` is missing
    /// but the repo already has manifests or images (it may not have synced yet).
    /// A good or not-yet-downloaded file is never replaced by a guess.
    @discardableResult
    public static func ensure(_ backend: any StorageBackend, now: Date = Date()) throws -> String? {
        var object: [String: Any]
        if try backend.stat(path) == nil {
            guard isSafeToCreate(backend) else { return nil }
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

    /// A fresh `repo.json` may be written only when no other copy of it can be
    /// on its way: no placeholder or conflict copy in the root, and no repo
    /// content that would mean the real file has not synced yet.
    static func isSafeToCreate(_ backend: any StorageBackend) -> Bool {
        guard let names = try? backend.list("") else { return false }
        for name in names where name != path {
            if RepoFileNames.logicalName(name) == path { return false }
            let logical = RepoFileNames.logicalName(name)
            if RepoFileNames.isConflictCopy(name), (logical as NSString).pathExtension == "json",
               (logical as NSString).deletingPathExtension.hasPrefix("repo ") { return false }
        }
        for dir in ["manifests", "images"] {
            if let entries = try? backend.list(dir), !entries.isEmpty { return false }
        }
        return true
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
}

extension IsenoughEngine {
    /// The current repo's id as `repo.json` records it. Never writes; nil for a
    /// repo that has no id yet (legacy rules then apply).
    public func repoIdentity() -> String? {
        guard let backend = try? repo else { return nil }
        return RepoIdentity.read(backend)
    }

    /// Creates the id when it is safe to (see `RepoIdentity.ensure`). Explicit commands only.
    @discardableResult
    public func ensureRepoIdentity() throws -> String? {
        try RepoIdentity.ensure(try repo)
    }
}
