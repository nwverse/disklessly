import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Fixed-size file IO. Callers that move disk images, session archives, or cache
/// objects use this instead of `Data(contentsOf:)`, which maps the whole file.
public enum ChunkedIO {
    public static let chunkSize = 1 << 20

    @discardableResult
    public static func read(_ url: URL, offset: UInt64 = 0, count: UInt64? = nil, _ body: (Data) throws -> Void) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw IsenoughError.failure("cannot read \(url.path)") }
        defer { _ = close(fd) }
        if offset > 0 {
            guard systemSeek(fd, off_t(offset)) >= 0 else { throw IsenoughError.failure("cannot seek \(url.path)") }
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
            if n < 0 { throw IsenoughError.failure("cannot read \(url.path)") }
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
        throw IsenoughError.failure("cannot replace \(destination.path) (errno \(errorCode))")
    }

    public static func appendFile(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path) {
            try copyFile(from: source, to: destination)
            return
        }
        let out = open(destination.path, O_WRONLY | O_APPEND)
        guard out >= 0 else { throw IsenoughError.failure("cannot append \(destination.path)") }
        defer { _ = close(out) }
        _ = try read(source) { chunk in
            try writeAll(out, chunk)
        }
    }

    private static func streamCopy(from source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw IsenoughError.failure("cannot read \(source.path)") }
        defer { _ = close(input) }
        var info = stat()
        let mode: mode_t = fstat(input, &info) == 0 ? mode_t(info.st_mode & 0o777) : 0o644
        let output = open(destination.path, O_CREAT | O_TRUNC | O_WRONLY, mode)
        guard output >= 0 else { throw IsenoughError.failure("cannot write \(destination.path)") }
        defer { _ = close(output) }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return systemRead(input, base, raw.count)
            }
            if n < 0 { throw IsenoughError.failure("cannot read \(source.path)") }
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
                if n < 0 { throw IsenoughError.failure("cannot write file") }
                if n == 0 { throw IsenoughError.failure("short write") }
                sent += n
            }
        }
    }

    private static func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        while true {
            let n = libcRead(fd, buffer, count)
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    private static func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
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
