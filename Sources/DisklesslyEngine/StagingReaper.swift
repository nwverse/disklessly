import Foundation
import DisklesslyCore

/// Streamed uploads write `files/staging/<uuid>.part` (files) and `staging/<uuid>.part` (app data)
/// before moving them to their object. A process that dies mid-upload never deletes its part,
/// and on a cloud drive each one keeps counting against the quota. The names are random and
/// never reused, so a part older than `maxAge` belongs to nobody.
enum StagingReaper {
    static let folders = ["files/staging", "staging"]
    static let maxAge: TimeInterval = 24 * 3600

    static func stale(_ backend: any StorageBackend, now: Date, maxAge: TimeInterval = maxAge) -> [(path: String, bytes: UInt64)] {
        var out: [(String, UInt64)] = []
        for folder in folders {
            guard let names = try? backend.list(folder) else { continue }
            for name in names where name.hasSuffix(".part") {
                let path = "\(folder)/\((name as NSString).lastPathComponent)"
                guard let stat = try? backend.stat(path), now.timeIntervalSince(stat.modified) > maxAge else { continue }
                out.append((path, stat.size))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Deletes stale parts; returns one line per part removed or failed.
    static func reap(_ backend: any StorageBackend, now: Date, maxAge: TimeInterval = maxAge) -> [String] {
        stale(backend, now: now, maxAge: maxAge).map { part in
            do {
                try backend.delete(part.path)
                return "staging-reaped \(part.path) \(part.bytes)"
            } catch {
                return "staging-reap-failed \(part.path): \(error.localizedDescription)"
            }
        }
    }
}

extension DisklesslyEngine {
    /// Unfinished upload parts older than a day (see `StagingReaper`).
    public func staleStagingParts(now: Date = Date()) -> [(path: String, bytes: UInt64)] {
        guard let backend = try? repo else { return [] }
        return StagingReaper.stale(backend, now: now)
    }
}
