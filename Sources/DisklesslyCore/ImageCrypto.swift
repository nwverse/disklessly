import Crypto
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Encrypted disk images in the repo (`DKLI`), ported from open-lark's olk-file format.
///
/// File:    "DKLI" | version (1) | segment size as a power of two (1, = 20)
///          | key id (8, ASCII hex) | nonce prefix (7, random) | segments
/// Segment: AES-256-GCM of up to one segment of the image, additional data =
///          the 21-byte header, IV = nonce prefix | index uint32 BE | 1 on the
///          last segment, else 0, then the 16-byte tag. Every segment but the
///          last is full. An empty image is one empty last segment (tag only).
///
/// The last-segment flag makes a file cut at a segment boundary fail to open;
/// the header as additional data binds the key id and segment size. Both
/// directions stream file to file one segment at a time, so a multi-GB image
/// is never in memory whole.
public enum ImageCrypto {
    /// Manifest `image.encryption.scheme` for this format.
    public static let scheme = "dkli-aes256gcm/1"
    public static let magic: [UInt8] = Array("DKLI".utf8)
    public static let version: UInt8 = 1
    public static let defaultSegmentShift: UInt8 = 20
    /// Shifts a reader accepts: 4 KiB to 16 MiB segments.
    static let allowedShifts: ClosedRange<UInt8> = 12...24
    public static let keyIdBytes = 8
    static let noncePrefixBytes = 7
    public static let tagBytes = 16
    public static let headerBytes = magic.count + 2 + keyIdBytes + noncePrefixBytes

    public struct Sealed: Equatable {
        public var plainSha256: String
        public var plainSize: UInt64
        public var sha256: String
        public var size: UInt64
    }

    public struct Opened: Equatable {
        public var plainSha256: String
        public var plainSize: UInt64
    }

    public struct Header: Equatable {
        public var keyId: String
        public var segmentShift: UInt8
        var noncePrefix: [UInt8]
        var bytes: [UInt8]
    }

    /// Bytes an image of `size` bytes takes once sealed.
    public static func sealedSize(plainSize size: UInt64, segmentShift: UInt8 = defaultSegmentShift) -> UInt64 {
        let segment = UInt64(1) << UInt64(segmentShift)
        let segments = max(1, (size + segment - 1) / segment)
        return UInt64(headerBytes) + size + segments * UInt64(tagBytes)
    }

    /// The plaintext size a sealed file of `length` bytes holds; nil when no
    /// valid file has that length.
    public static func plainSize(sealedSize length: UInt64, segmentShift: UInt8) -> UInt64? {
        guard length >= UInt64(headerBytes) else { return nil }
        let body = length - UInt64(headerBytes)
        let segment = UInt64(1) << UInt64(segmentShift)
        let sealedSegment = segment + UInt64(tagBytes)
        let full = body / sealedSegment
        let rest = body % sealedSegment
        if rest == 0 { return full > 0 ? full * segment : nil }
        // A trailing empty segment only exists when it is the only one.
        if rest < UInt64(tagBytes) || (rest == UInt64(tagBytes) && full > 0) { return nil }
        return full * segment + rest - UInt64(tagBytes)
    }

    /// Key id for `key`: the first 8 hex digits of its SHA-256.
    public static func keyId(for key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        return String(SHA256Digest.hex(raw).prefix(keyIdBytes))
    }

    /// Reads and checks the header of a sealed file without its key.
    public static func header(of url: URL) throws -> Header {
        let fd = Darwinish.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw DisklesslyError.failure("cannot read \(url.path)") }
        defer { _ = close(fd) }
        var bytes = [UInt8](repeating: 0, count: headerBytes)
        guard try readFully(fd, &bytes, count: headerBytes, path: url.path) == headerBytes else {
            throw DisklesslyError.integrity("\(url.lastPathComponent) is not an encrypted Disklessly image")
        }
        return try parseHeader(bytes, name: url.lastPathComponent)
    }

    /// Whether `url` starts like a sealed image. Says nothing about its contents.
    public static func looksSealed(_ url: URL) -> Bool {
        (try? header(of: url)) != nil
    }

    static func parseHeader(_ bytes: [UInt8], name: String) throws -> Header {
        guard bytes.count == headerBytes, Array(bytes.prefix(magic.count)) == magic else {
            throw DisklesslyError.integrity("\(name) is not an encrypted Disklessly image")
        }
        guard bytes[magic.count] == version else {
            throw DisklesslyError.integrity("\(name) uses encrypted image version \(bytes[magic.count]); this build reads version \(version)")
        }
        let shift = bytes[magic.count + 1]
        guard allowedShifts.contains(shift) else { throw DisklesslyError.integrity("\(name) has an invalid segment size") }
        let idStart = magic.count + 2
        let idBytes = Array(bytes[idStart..<(idStart + keyIdBytes)])
        guard idBytes.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw DisklesslyError.integrity("\(name) has an invalid key id")
        }
        let prefix = Array(bytes[(idStart + keyIdBytes)...])
        return Header(keyId: String(decoding: idBytes, as: UTF8.self), segmentShift: shift, noncePrefix: prefix, bytes: bytes)
    }

    /// Encrypts `source` into `destination` (replaced if present) under `key`
    /// with a fresh random nonce prefix, hashing plaintext and ciphertext in
    /// the same pass.
    @discardableResult
    public static func seal(_ source: URL, to destination: URL, key: SymmetricKey, segmentShift: UInt8 = defaultSegmentShift) throws -> Sealed {
        guard allowedShifts.contains(segmentShift) else { throw DisklesslyError.usage("invalid segment shift \(segmentShift)") }
        guard key.bitCount == 256 else { throw DisklesslyError.usage("image keys are 256-bit") }
        let id = keyId(for: key)
        var prefix = [UInt8](repeating: 0, count: noncePrefixBytes)
        var rng = SystemRandomNumberGenerator()
        for index in prefix.indices { prefix[index] = rng.next() }
        var header = magic
        header.append(version)
        header.append(segmentShift)
        header.append(contentsOf: Array(id.utf8))
        header.append(contentsOf: prefix)
        let aad = Data(header)

        let input = Darwinish.open(source.path, O_RDONLY)
        guard input >= 0 else { throw DisklesslyError.failure("cannot read \(source.path)") }
        defer { _ = close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw DisklesslyError.failure("cannot stat \(source.path)") }
        let size = UInt64(max(0, info.st_size))
        let output = try createOutput(destination)
        defer { _ = close(output) }

        let segment = 1 << Int(segmentShift)
        let segments = max(1, (size + UInt64(segment) - 1) / UInt64(segment))
        var plainHash = Crypto.SHA256()
        var cipherHash = Crypto.SHA256()
        try writeAll(output, header, path: destination.path)
        cipherHash.update(data: header)
        var buffer = [UInt8](repeating: 0, count: segment)
        var remaining = size
        for index in 0..<segments {
            let want = Int(min(remaining, UInt64(segment)))
            guard try readFully(input, &buffer, count: want, path: source.path) == want else {
                throw DisklesslyError.failure("\(source.lastPathComponent) changed while it was encrypted")
            }
            remaining -= UInt64(want)
            let plain = Data(buffer.prefix(want))
            plainHash.update(data: plain)
            let nonce = try AES.GCM.Nonce(data: iv(prefix, UInt32(index), last: index == segments - 1))
            let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad)
            var sealed = [UInt8](box.ciphertext)
            sealed.append(contentsOf: box.tag)
            try writeAll(output, sealed, path: destination.path)
            cipherHash.update(data: sealed)
        }
        var probe: UInt8 = 0
        guard ChunkedIO.systemRead(input, &probe, 1) == 0 else {
            throw DisklesslyError.failure("\(source.lastPathComponent) changed while it was encrypted")
        }
        guard fsync(output) == 0 else { throw DisklesslyError.failure("cannot flush \(destination.path)") }
        return Sealed(plainSha256: hex(plainHash.finalize()), plainSize: size, sha256: hex(cipherHash.finalize()), size: sealedSize(plainSize: size, segmentShift: segmentShift))
    }

    /// Decrypts `source` into `destination` (replaced if present). Checks the
    /// header, the length the segment layout allows, every tag in order and the
    /// last-segment flag. `key` returns the key for the header's key id, or nil.
    /// On any failure `destination` is removed.
    @discardableResult
    public static func open(_ source: URL, to destination: URL, key lookup: (String) throws -> SymmetricKey?) throws -> Opened {
        let input = Darwinish.open(source.path, O_RDONLY)
        guard input >= 0 else { throw DisklesslyError.failure("cannot read \(source.path)") }
        defer { _ = close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw DisklesslyError.failure("cannot stat \(source.path)") }
        let length = UInt64(max(0, info.st_size))
        let name = source.lastPathComponent
        var headerBytes = [UInt8](repeating: 0, count: Self.headerBytes)
        guard try readFully(input, &headerBytes, count: Self.headerBytes, path: source.path) == Self.headerBytes else {
            throw DisklesslyError.integrity("\(name) is not an encrypted Disklessly image")
        }
        let header = try parseHeader(headerBytes, name: name)
        guard let size = plainSize(sealedSize: length, segmentShift: header.segmentShift) else {
            throw DisklesslyError.integrity("\(name) has a truncated or padded encrypted body")
        }
        guard let key = try lookup(header.keyId) else {
            throw DisklesslyError.integrity("\(name) is encrypted with image key \(header.keyId), which this Mac does not have")
        }
        guard keyId(for: key) == header.keyId else {
            throw DisklesslyError.integrity("the image key loaded for \(header.keyId) has a different id")
        }
        let output = try createOutput(destination)
        var finished = false
        defer {
            _ = close(output)
            if !finished { try? FileManager.default.removeItem(at: destination) }
        }
        let aad = Data(header.bytes)
        let segment = 1 << Int(header.segmentShift)
        let segments = max(1, (size + UInt64(segment) - 1) / UInt64(segment))
        var plainHash = Crypto.SHA256()
        var buffer = [UInt8](repeating: 0, count: segment + tagBytes)
        var remaining = size
        for index in 0..<segments {
            let plainCount = Int(min(remaining, UInt64(segment)))
            let want = plainCount + tagBytes
            guard try readFully(input, &buffer, count: want, path: source.path) == want else {
                throw DisklesslyError.integrity("\(name) changed while it was decrypted")
            }
            remaining -= UInt64(plainCount)
            let plain: Data
            do {
                let nonce = try AES.GCM.Nonce(data: iv(header.noncePrefix, UInt32(index), last: index == segments - 1))
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(buffer.prefix(plainCount)), tag: Data(buffer[plainCount..<want]))
                plain = try AES.GCM.open(box, using: key, authenticating: aad)
            } catch {
                throw DisklesslyError.integrity("\(name) failed authentication at segment \(index)")
            }
            plainHash.update(data: plain)
            try writeAll(output, [UInt8](plain), path: destination.path)
        }
        guard fsync(output) == 0 else { throw DisklesslyError.failure("cannot flush \(destination.path)") }
        finished = true
        return Opened(plainSha256: hex(plainHash.finalize()), plainSize: size)
    }

    static func iv(_ prefix: [UInt8], _ index: UInt32, last: Bool) -> [UInt8] {
        var bytes = prefix
        bytes.append(UInt8(truncatingIfNeeded: index >> 24))
        bytes.append(UInt8(truncatingIfNeeded: index >> 16))
        bytes.append(UInt8(truncatingIfNeeded: index >> 8))
        bytes.append(UInt8(truncatingIfNeeded: index))
        bytes.append(last ? 1 : 0)
        return bytes
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func createOutput(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwinish.open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        guard fd >= 0 else { throw DisklesslyError.failure("cannot write \(url.path)") }
        return fd
    }

    /// Reads until `count` bytes or end of file; returns the bytes read.
    private static func readFully(_ fd: Int32, _ buffer: inout [UInt8], count: Int, path: String) throws -> Int {
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return ChunkedIO.systemRead(fd, base.advanced(by: got), count - got)
            }
            if n < 0 { throw DisklesslyError.failure("cannot read \(path)") }
            if n == 0 { break }
            got += n
        }
        return got
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], path: String) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = ChunkedIO.systemWrite(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 { throw DisklesslyError.failure("cannot write \(path)") }
                sent += n
            }
        }
    }
}

/// `open(2)` under a name that does not clash with `ImageCrypto.open`.
private enum Darwinish {
    static func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
        #if canImport(Glibc)
        Glibc.open(path, flags, mode)
        #else
        Darwin.open(path, flags, mode)
        #endif
    }
}

/// Image keys in the Keychain, one item per key plus a pointer to the current
/// one. Items are synchronizable so the user's other Macs can open the images.
public enum ImageKeyStore {
    public static let service = "io.github.s546126.disklessly.images"
    static let currentAccount = "image-key-current"

    static func account(_ keyId: String) -> String { "image-key-\(keyId)" }

    /// Makes a key and makes it current. Refuses when a key already exists.
    public static func create(secrets: any SecretStore) throws -> String {
        if try currentKeyId(secrets: secrets) != nil {
            throw DisklesslyError.usage("an image key already exists; disklessly images key status")
        }
        let key = SymmetricKey(size: .bits256)
        try store(key, secrets: secrets)
        return ImageCrypto.keyId(for: key)
    }

    /// Stores an existing key (from `images key import`) and makes it current.
    @discardableResult
    public static func importKey(base64 text: String, secrets: any SecretStore) throws -> String {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else {
            throw DisklesslyError.usage("an image key is 32 bytes of base64")
        }
        let key = SymmetricKey(data: data)
        try store(key, secrets: secrets)
        return ImageCrypto.keyId(for: key)
    }

    private static func store(_ key: SymmetricKey, secrets: any SecretStore) throws {
        let id = ImageCrypto.keyId(for: key)
        let raw = key.withUnsafeBytes { Data($0) }
        try secrets.save(service: service, account: account(id), secret: raw.base64EncodedString(), synchronizable: true)
        try secrets.save(service: service, account: currentAccount, secret: id, synchronizable: true)
    }

    public static func currentKeyId(secrets: any SecretStore) throws -> String? {
        try secrets.load(service: service, account: currentAccount)
    }

    public static func load(secrets: any SecretStore, keyId: String) throws -> SymmetricKey? {
        guard keyId.count == ImageCrypto.keyIdBytes,
              let stored = try secrets.load(service: service, account: account(keyId)),
              let data = Data(base64Encoded: stored), data.count == 32 else { return nil }
        let key = SymmetricKey(data: data)
        return ImageCrypto.keyId(for: key) == keyId ? key : nil
    }

    /// The current key and its id, or nil when none was made.
    public static func current(secrets: any SecretStore) throws -> (id: String, key: SymmetricKey)? {
        guard let id = try currentKeyId(secrets: secrets), let key = try load(secrets: secrets, keyId: id) else { return nil }
        return (id, key)
    }

    public static func exportKey(secrets: any SecretStore, keyId: String) throws -> String {
        guard let key = try load(secrets: secrets, keyId: keyId) else { throw DisklesslyError.usage("no image key \(keyId) on this Mac") }
        return key.withUnsafeBytes { Data($0) }.base64EncodedString()
    }
}

/// File-backed secrets for tests and `scripts/e2e.sh`, so they never write the
/// login keychain. Only debug builds honor `DISKLESSLY_TEST_SECRETS_DIR`.
public final class FileSecretStore: SecretStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> FileSecretStore? {
        #if DEBUG
        if let dir = env["DISKLESSLY_TEST_SECRETS_DIR"], !dir.isEmpty { return FileSecretStore(directory: URL(fileURLWithPath: dir)) }
        #endif
        _ = env
        return nil
    }

    private func url(_ service: String, _ account: String) -> URL {
        let name = "\(service)--\(account)".replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(name)
    }

    public func load(service: String, account: String) throws -> String? {
        let file = url(service, account)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    public func save(service: String, account: String, secret: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = url(service, account)
        try Data(secret.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func saveMountCredential(kind: String, host: String, account: String, secret: String) throws {}
}
