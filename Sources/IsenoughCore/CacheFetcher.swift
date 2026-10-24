import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum VolumeSpace {
    public static func availableBytes(at path: String) throws -> UInt64 {
        var info = statvfs()
        let result = path.withCString { statvfs($0, &info) }
        guard result == 0 else { throw IsenoughError.failure("Could not read free space for \(path)") }
        return UInt64(info.f_bavail) * UInt64(info.f_frsize)
    }
}

public enum CacheFetcher {
    public static func materialize(backend: any StorageBackend, remote: String, destination: URL, partial: URL, expectedSize: UInt64, expectedSHA256: String) throws {
        if FileManager.default.fileExists(atPath: destination.path), try digest(destination) == expectedSHA256 {
            return
        }
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        var resumed = false
        do {
            resumed = try download(backend: backend, remote: remote, partial: partial, allowResume: true)
            if try matches(partial, expectedSize: expectedSize, expectedSHA256: expectedSHA256) {
                try promote(partial, to: destination)
                return
            }
        } catch let error as IsenoughError {
            switch error {
            case .backend, .noSpace, .unsupported: throw error
            default: resumed = true
            }
        }
        guard resumed else {
            try? FileManager.default.removeItem(at: partial)
            throw IsenoughError.integrity("Remote image hash or size mismatch")
        }
        try? FileManager.default.removeItem(at: partial)
        _ = try download(backend: backend, remote: remote, partial: partial, allowResume: false)
        if try matches(partial, expectedSize: expectedSize, expectedSHA256: expectedSHA256) {
            try promote(partial, to: destination)
            return
        }
        try? FileManager.default.removeItem(at: partial)
        throw IsenoughError.integrity("Remote image hash or size mismatch")
    }

    @discardableResult
    private static func download(backend: any StorageBackend, remote: String, partial: URL, allowResume: Bool) throws -> Bool {
        var offset: UInt64 = 0
        var resumed = false
        if allowResume, FileManager.default.fileExists(atPath: partial.path) {
            offset = try byteCount(partial)
            resumed = offset > 0
        } else if FileManager.default.fileExists(atPath: partial.path) {
            try FileManager.default.removeItem(at: partial)
        }
        let fetched = try backend.download(remote, to: partial, offset: offset)
        if fetched.restart { return false }
        return resumed
    }

    private static func matches(_ url: URL, expectedSize: UInt64, expectedSHA256: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard try byteCount(url) == expectedSize else { return false }
        return try digest(url) == expectedSHA256
    }

    private static func digest(_ url: URL) throws -> String {
        try SHA256Digest.hexFile(url)
    }

    private static func promote(_ partial: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw IsenoughError.failure("Could not install verified image at cache path \(destination.path): \(error.localizedDescription)")
        }
    }

    private static func byteCount(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
