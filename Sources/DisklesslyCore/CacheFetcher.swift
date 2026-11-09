import Crypto
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
        guard result == 0 else { throw DisklesslyError.failure("Could not read free space for \(path)") }
        return UInt64(info.f_bavail) * UInt64(info.f_frsize)
    }
}

/// How to open an encrypted repo object once its ciphertext is verified.
public struct ImageDecryption {
    public var key: SymmetricKey
    public var keyId: String
    public var plainSha256: String
    public var plainSize: UInt64
    public init(key: SymmetricKey, keyId: String, plainSha256: String, plainSize: UInt64) {
        self.key = key; self.keyId = keyId; self.plainSha256 = plainSha256; self.plainSize = plainSize
    }
}

public enum CacheFetcher {
    /// Downloads `remote` into `partial`, checks it against `expectedSize` and
    /// `expectedSHA256` (the repo object), then installs it at `destination`.
    /// With `decryption` the verified ciphertext is decrypted next to `partial`
    /// and the plaintext, checked against the manifest's plain hash, is installed.
    public static func materialize(backend: any StorageBackend, remote: String, destination: URL, partial: URL, expectedSize: UInt64, expectedSHA256: String, decryption: ImageDecryption? = nil) throws {
        if FileManager.default.fileExists(atPath: destination.path), try digest(destination) == (decryption?.plainSha256 ?? expectedSHA256) {
            return
        }
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        var resumed = false
        var verified = false
        do {
            resumed = try download(backend: backend, remote: remote, partial: partial, allowResume: true)
            verified = try matches(partial, expectedSize: expectedSize, expectedSHA256: expectedSHA256)
        } catch let error as DisklesslyError {
            switch error {
            case .backend, .noSpace, .unsupported: throw error
            default: resumed = true
            }
        }
        if verified {
            try install(partial, to: destination, decryption: decryption)
            return
        }
        guard resumed else {
            try? FileManager.default.removeItem(at: partial)
            throw DisklesslyError.integrity("Remote image hash or size mismatch")
        }
        try? FileManager.default.removeItem(at: partial)
        _ = try download(backend: backend, remote: remote, partial: partial, allowResume: false)
        if try matches(partial, expectedSize: expectedSize, expectedSHA256: expectedSHA256) {
            try install(partial, to: destination, decryption: decryption)
            return
        }
        try? FileManager.default.removeItem(at: partial)
        throw DisklesslyError.integrity("Remote image hash or size mismatch")
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

    /// Where a verified encrypted partial is decrypted before it is promoted.
    public static func plainPartial(_ partial: URL) -> URL {
        partial.appendingPathExtension("plain")
    }

    private static func install(_ partial: URL, to destination: URL, decryption: ImageDecryption?) throws {
        guard let decryption else {
            try promote(partial, to: destination)
            return
        }
        let plain = plainPartial(partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        let opened: ImageCrypto.Opened
        do {
            opened = try ImageCrypto.open(partial, to: plain) { id in id == decryption.keyId ? decryption.key : nil }
        } catch {
            try? FileManager.default.removeItem(at: plain)
            throw error
        }
        guard opened.plainSha256 == decryption.plainSha256, opened.plainSize == decryption.plainSize else {
            try? FileManager.default.removeItem(at: plain)
            throw DisklesslyError.integrity("Decrypted image hash or size does not match the manifest")
        }
        try? FileManager.default.removeItem(at: partial)
        try promote(plain, to: destination)
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
            throw DisklesslyError.failure("Could not install verified image at cache path \(destination.path): \(error.localizedDescription)")
        }
    }

    private static func byteCount(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
