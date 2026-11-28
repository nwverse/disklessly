import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Identity checks for paths that may resolve to the same inode. `stat` follows
/// symlinks, so this also catches symlinked and hard-linked aliases.
enum FileIdentity {
    static func stamp(_ url: URL) -> stat? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info
    }

    static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = stamp(lhs), let right = stamp(rhs) else { return false }
        return same(left, right)
    }

    static func stamp(fileDescriptor fd: Int32) -> stat? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return info
    }
}
