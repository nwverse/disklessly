import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A write-once publish found the destination already present. The bytes that
/// were there first are left untouched.
public struct WriteOnceConflict: Error, LocalizedError, Equatable {
    public var path: String
    public init(path: String) { self.path = path }
    public var errorDescription: String? {
        "refusing to overwrite \(path): another writer published it first"
    }
}

/// Fixed-size file IO. Callers that move disk images, session archives, or cache
/// objects use this instead of `Data(contentsOf:)`, which maps the whole file.
public enum ChunkedIO {
    public static let chunkSize = 1 << 20

    @discardableResult
    public static func read(_ url: URL, offset: UInt64 = 0, count: UInt64? = nil, _ body: (Data) throws -> Void) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw DisklesslyError.failure("cannot read \(url.path)") }
        defer { _ = close(fd) }
        if offset > 0 {
            guard systemSeek(fd, off_t(offset)) >= 0 else { throw DisklesslyError.failure("cannot seek \(url.path)") }
        }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var remaining = count
        var total: UInt64 = 0
        while true {
            if let remaining, remaining == 0 { break }
            let want = remaining.map { Int(min($0, UInt64(buffer.count))) } ?? buffer.count
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return systemRead(fd, base, want)
            }
            if n < 0 { throw DisklesslyError.failure("cannot read \(url.path)") }
            if n == 0 { break }
            try body(Data(buffer.prefix(n)))
            total += UInt64(n)
            if let left = remaining {
                remaining = left - UInt64(n)
            }
        }
        return total
    }

    public static func readAll(_ url: URL) throws -> Data {
        var data = Data()
        _ = try read(url) { data.append($0) }
        return data
    }

    public static func prefix(_ url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        var data = Data()
        _ = try read(url, count: UInt64(maxBytes)) { data.append($0) }
        return data
    }

    public static func byteCount(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Copy without holding the file in one buffer. On APFS, `clonefile` is tried first.
    public static func copyFile(from source: URL, to destination: URL) throws {
        if FileIdentity.same(source, destination) { return }
        #if os(macOS)
        let cloned = source.path.withCString { src in
            destination.path.withCString { dst in
                clonefile(src, dst, UInt32(0))
            }
        }
        if cloned == 0 { return }
        #endif
        try streamCopy(from: source, to: destination)
    }

    /// Replace `destination` with `source`. Same-directory publishes use `rename`,
    /// which overwrites an existing file. `FileManager.replaceItemAt` reports a
    /// missing file on Linux even when both paths exist, so it is not used.
    public static func replaceFile(_ destination: URL, with source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var errorCode: Int32 = 0
        let renamed = source.path.withCString { src in
            destination.path.withCString { dst -> Bool in
                if rename(src, dst) == 0 { return true }
                errorCode = errno
                return false
            }
        }
        if renamed { return }
        if errorCode == EXDEV {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try copyFile(from: source, to: destination)
            try fm.removeItem(at: source)
            return
        }
        throw DisklesslyError.failure("cannot replace \(destination.path) (errno \(errorCode))")
    }

    /// Move `temp` to `dest` only when `dest` does not exist yet. This is the
    /// publish step for write-once repo objects (images, manifests). It never
    /// replaces an existing file: when another writer got there first, `temp` is
    /// removed and `WriteOnceConflict` is thrown. Mutable files (device records,
    /// state) keep using `replaceFile`.
    ///
    /// Darwin uses `renamex_np(RENAME_EXCL)`. Linux, and Darwin file systems that
    /// do not support the flag, use `link(2)` then `unlink(2)` of the temp name.
    /// When neither is supported (some SMB servers have no hard links), an
    /// `O_CREAT | O_EXCL` reservation of `dest` decides the winner and the temp is
    /// then renamed over that reservation.
    public static func publishExclusive(temp: URL, dest: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conflict = { () -> WriteOnceConflict in
            try? FileManager.default.removeItem(at: temp)
            return WriteOnceConflict(path: dest.path)
        }
        #if canImport(Darwin)
        var renameError: Int32 = 0
        let renamed = temp.path.withCString { src in
            dest.path.withCString { dst -> Bool in
                if renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0 { return true }
                renameError = errno
                return false
            }
        }
        if renamed { return }
        if renameError == EEXIST { throw conflict() }
        guard renameError == ENOTSUP || renameError == EINVAL || renameError == ENOSYS || renameError == EOPNOTSUPP else {
            throw DisklesslyError.failure("cannot publish \(dest.path) (errno \(renameError))")
        }
        #endif
        var linkError: Int32 = 0
        let linked = temp.path.withCString { src in
            dest.path.withCString { dst -> Bool in
                if link(src, dst) == 0 { return true }
                linkError = errno
                return false
            }
        }
        if linked {
            _ = temp.path.withCString { unlink($0) }
            return
        }
        if linkError == EEXIST { throw conflict() }
        guard [EPERM, ENOTSUP, EOPNOTSUPP, EMLINK, ENOSYS, EINVAL].contains(linkError) else {
            throw DisklesslyError.failure("cannot publish \(dest.path) (errno \(linkError))")
        }
        let reservation = open(dest.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o644))
        if reservation < 0 {
            let code = errno
            if code == EEXIST { throw conflict() }
            throw DisklesslyError.failure("cannot publish \(dest.path) (errno \(code))")
        }
        _ = close(reservation)
        do {
            // The reservation is ours alone: every other writer got EEXIST above.
            try replaceFile(dest, with: temp)
        } catch {
            _ = dest.path.withCString { unlink($0) }
            throw error
        }
    }

    public static func appendFile(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path) {
            try copyFile(from: source, to: destination)
            return
        }
        let out = open(destination.path, O_WRONLY | O_APPEND)
        guard out >= 0 else { throw DisklesslyError.failure("cannot append \(destination.path)") }
        defer { _ = close(out) }
        _ = try read(source) { chunk in
            try writeAll(out, chunk)
        }
    }

    private static func streamCopy(from source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw DisklesslyError.failure("cannot read \(source.path)") }
        defer { _ = close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw DisklesslyError.failure("cannot stat \(source.path)") }
        let mode = mode_t(info.st_mode & 0o777)
        // Do not truncate until the output descriptor has been checked against
        // the source. This also closes the check/open race for aliased paths.
        let output = open(destination.path, O_CREAT | O_WRONLY, mode)
        guard output >= 0 else { throw DisklesslyError.failure("cannot write \(destination.path)") }
        defer { _ = close(output) }
        guard let destinationInfo = FileIdentity.stamp(fileDescriptor: output) else {
            throw DisklesslyError.failure("cannot stat \(destination.path)")
        }
        if FileIdentity.same(info, destinationInfo) { return }
        guard ftruncate(output, 0) == 0 else { throw DisklesslyError.failure("cannot truncate \(destination.path)") }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return systemRead(input, base, raw.count)
            }
            if n < 0 { throw DisklesslyError.failure("cannot read \(source.path)") }
            if n == 0 { break }
            try writeAll(output, Data(buffer.prefix(n)))
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = systemWrite(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0 { throw DisklesslyError.failure("cannot write file") }
                if n == 0 { throw DisklesslyError.failure("short write") }
                sent += n
            }
        }
    }

    static func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        while true {
            let n = libcRead(fd, buffer, count)
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    static func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        while true {
            let n = libcWrite(fd, buffer, count)
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    private static func libcRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
        Glibc.read(fd, buffer, count)
        #elseif canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #else
        read(fd, buffer, count)
        #endif
    }

    private static func libcWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
        Glibc.write(fd, buffer, count)
        #elseif canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #else
        write(fd, buffer, count)
        #endif
    }

    private static func systemSeek(_ fd: Int32, _ offset: off_t) -> off_t {
        #if canImport(Glibc)
        Glibc.lseek(fd, offset, SEEK_SET)
        #elseif canImport(Darwin)
        Darwin.lseek(fd, offset, SEEK_SET)
        #else
        lseek(fd, offset, SEEK_SET)
        #endif
    }
}
