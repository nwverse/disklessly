import Foundation
import DisklesslyCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `<stateDir>/sessions/text/<entryId>.jsonl`: the plain-text index of an
/// archived transcript of this device (see `SessionText`). It is written from
/// the snapshot bytes before the local file is deleted and never uploaded.
/// Restore leaves it in place.
public enum SessionTextIndex {
    public static func directory(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("sessions/text")
    }

    public static func url(stateDir: String, id: String) -> URL {
        directory(stateDir: stateDir).appendingPathComponent("\(id).jsonl")
    }

    /// Number of `.jsonl` files in the text directory.
    public static func count(stateDir: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(stateDir: stateDir).path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }.count
    }

    /// Writes the file atomically (temp file, fsync, rename) with mode 0600 in a
    /// 0700 directory.
    public static func write(_ data: Data, stateDir: String, id: String) throws {
        let fm = FileManager.default
        let dir = directory(stateDir: stateDir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(dir.path, 0o700)
        let target = url(stateDir: stateDir, id: id)
        let temp = dir.appendingPathComponent(".\(id).jsonl.tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DisklesslyError.failure("cannot write session text index \(target.path): \(String(cString: strerror(errno)))") }
        var closed = false
        defer {
            if !closed { _ = close(fd) }
        }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw DisklesslyError.failure("cannot write session text index \(target.path): \(String(cString: strerror(errno)))")
                    }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw DisklesslyError.failure("cannot sync session text index \(target.path)") }
            closed = true
            guard close(fd) == 0 else { throw DisklesslyError.failure("cannot close session text index \(target.path)") }
            guard rename(temp.path, target.path) == 0 else {
                throw DisklesslyError.failure("cannot rename session text index \(target.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            _ = unlink(temp.path)
            throw error
        }
        let dirFd = open(dir.path, O_RDONLY | O_CLOEXEC)
        if dirFd >= 0 {
            _ = fsync(dirFd)
            _ = close(dirFd)
        }
    }

    /// Renders and writes the text index for one transcript.
    public static func write(header: SessionText.Header, messages: [SessionDigest.Message], stateDir: String) throws {
        try write(try SessionText.render(header: header, messages: messages), stateDir: stateDir, id: header.entryId)
    }

    public static func rfc3339(mtimeNs: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date(timeIntervalSince1970: Double(mtimeNs) / 1_000_000_000))
    }
}
