import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Process-wide cache of archive sha256 checks. A file is hashed again only when its fingerprint changes.
public final class ArchiveVerificationCache {
    public static let shared = ArchiveVerificationCache()
    private let lock = NSLock()
    private var values: [Key: Bool] = [:]

    private struct Key: Hashable {
        var path: String
        var dev: UInt64
        var ino: UInt64
        var size: UInt64
        var mtimeNs: Int64
        var sha: String
    }

    public init() {}

    public func verify(url: URL, expected: String, hasher: (URL) throws -> String) -> Bool {
        guard let finger = try? FileFingerprint.of(url: url) else { return false }
        let key = Key(path: url.path, dev: finger.dev, ino: finger.ino, size: finger.size, mtimeNs: finger.mtimeNs, sha: expected)
        lock.lock()
        if let cached = values[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let matched = (try? hasher(url)) == expected
        lock.lock()
        values[key] = matched
        lock.unlock()
        return matched
    }
}

/// Stat-only digest of a tree. Content that changes without mtime or size is not detected.
public enum TreeFingerprint {
    public static func of(_ root: URL) throws -> String {
        var lines: [String] = []
        try walk(root, root, &lines)
        lines.sort()
        return SHA256Digest.hex(Data(lines.joined(separator: "\n").utf8))
    }

    private static func walk(_ root: URL, _ url: URL, _ lines: inout [String]) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        let kind = info.st_mode & S_IFMT
        let type: String
        var target = ""
        if kind == S_IFLNK {
            type = "link"
            target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
        } else if kind == S_IFDIR {
            type = "dir"
        } else if kind == S_IFREG {
            type = "file"
        } else {
            type = "other"
        }
        let relative = url.path == root.path ? "." : String(url.path.dropFirst(root.path.hasSuffix("/") ? root.path.count : root.path.count + 1))
        let mtimeNs: Int64
        #if os(Linux)
        mtimeNs = Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
        #else
        mtimeNs = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        #endif
        lines.append("\(relative)\t\(type)\t\(info.st_mode & 0o777)\t\(info.st_size)\t\(mtimeNs)\t\(info.st_ino)\t\(target)")
        if kind == S_IFDIR {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names.sorted() {
                try walk(root, url.appendingPathComponent(name), &lines)
            }
        }
    }
}
