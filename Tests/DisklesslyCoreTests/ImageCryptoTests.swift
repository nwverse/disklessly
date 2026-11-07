import Crypto
import XCTest
import Foundation
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class ImageCryptoTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-imagecrypto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func open(_ sealed: URL, key: SymmetricKey) throws -> (ImageCrypto.Opened, Data) {
        let out = root.appendingPathComponent("opened-\(UUID().uuidString)")
        let opened = try ImageCrypto.open(sealed, to: out) { id in id == ImageCrypto.keyId(for: key) ? key : nil }
        return (opened, try Data(contentsOf: out))
    }

    private func assertRejected(_ sealed: URL, key: SymmetricKey, file: StaticString = #filePath, line: UInt = #line) {
        let out = root.appendingPathComponent("rejected-\(UUID().uuidString)")
        XCTAssertThrowsError(try ImageCrypto.open(sealed, to: out) { _ in key }, file: file, line: line) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5, "\(error)", file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no plaintext left behind", file: file, line: line)
    }

    /// Seals `count` random bytes with 4 KiB segments.
    private func sealSmall(_ count: Int, key: SymmetricKey) throws -> (plain: Data, sealed: URL) {
        let plain = randomBytes(count)
        let source = try file("plain-\(count)", plain)
        let sealed = root.appendingPathComponent("sealed-\(count)")
        try ImageCrypto.seal(source, to: sealed, key: key, segmentShift: 12)
        return (plain, sealed)
    }

    // MARK: - Format

    func testRoundTripAcrossSegmentBoundaries() throws {
        let key = SymmetricKey(size: .bits256)
        for count in [0, 1, 4095, 4096, 4097, 3 * 4096, 3 * 4096 + 5] {
            let plain = randomBytes(count)
            let source = try file("plain-\(count)", plain)
            let sealed = root.appendingPathComponent("sealed-\(count)")
            let result = try ImageCrypto.seal(source, to: sealed, key: key, segmentShift: 12)
            let bytes = try Data(contentsOf: sealed)
            XCTAssertEqual(UInt64(bytes.count), result.size, "size \(count)")
            XCTAssertEqual(result.size, ImageCrypto.sealedSize(plainSize: UInt64(count), segmentShift: 12))
            XCTAssertEqual(ImageCrypto.plainSize(sealedSize: result.size, segmentShift: 12), UInt64(count))
            XCTAssertEqual(result.sha256, SHA256Digest.hex(bytes))
            XCTAssertEqual(result.plainSha256, SHA256Digest.hex(plain))
            XCTAssertEqual(result.plainSize, UInt64(count))
            XCTAssertEqual(Array(bytes.prefix(4)), Array("DKLI".utf8))
            let (opened, back) = try open(sealed, key: key)
            XCTAssertEqual(back, plain, "size \(count)")
            XCTAssertEqual(opened, ImageCrypto.Opened(plainSha256: result.plainSha256, plainSize: UInt64(count)))
        }
    }

    func testEmptyImageIsOneEmptyLastSegment() throws {
        let key = SymmetricKey(size: .bits256)
        let (_, sealed) = try sealSmall(0, key: key)
        XCTAssertEqual(try ChunkedIO.byteCount(sealed), UInt64(ImageCrypto.headerBytes + ImageCrypto.tagBytes))
        XCTAssertEqual(try open(sealed, key: key).1, Data())
        // A header with no segment at all is not a valid file.
        let headerOnly = try file("header-only", try Data(contentsOf: sealed).prefix(ImageCrypto.headerBytes))
        assertRejected(headerOnly, key: key)
    }

    func testMultiSegmentAtDefaultSegmentSize() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = randomBytes(2 * (1 << 20) + 12345)
        let source = try file("big", plain)
        let sealed = root.appendingPathComponent("big.dkli")
        let result = try ImageCrypto.seal(source, to: sealed, key: key)
        XCTAssertEqual(result.size, UInt64(plain.count + ImageCrypto.headerBytes + 3 * ImageCrypto.tagBytes))
        XCTAssertEqual(try ImageCrypto.header(of: sealed).segmentShift, 20)
        XCTAssertEqual(try ImageCrypto.header(of: sealed).keyId, ImageCrypto.keyId(for: key))
        XCTAssertEqual(try open(sealed, key: key).1, plain)
    }

    func testFreshNoncePrefixPerSeal() throws {
        let key = SymmetricKey(size: .bits256)
        let source = try file("same", Data("same bytes".utf8))
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try ImageCrypto.seal(source, to: a, key: key)
        try ImageCrypto.seal(source, to: b, key: key)
        XCTAssertNotEqual(try Data(contentsOf: a), try Data(contentsOf: b))
    }

    func testTamperedBodyAndHeaderAreRejected() throws {
        let key = SymmetricKey(size: .bits256)
        let (_, sealed) = try sealSmall(3 * 4096 + 5, key: key)
        let original = try Data(contentsOf: sealed)
        for offset in [ImageCrypto.headerBytes + 10, original.count - 1, 5, ImageCrypto.headerBytes - 1] {
            var bytes = original
            bytes[offset] ^= 0x01
            let tampered = try file("tampered-\(offset)", bytes)
            assertRejected(tampered, key: key)
        }
    }

    func testTruncationIsRejected() throws {
        let key = SymmetricKey(size: .bits256)
        let (_, sealed) = try sealSmall(3 * 4096, key: key)
        let original = try Data(contentsOf: sealed)
        let segment = 4096 + ImageCrypto.tagBytes
        // Dropping the whole last segment leaves a valid length: the last flag catches it.
        let lastDropped = try file("last-dropped", original.prefix(original.count - segment))
        XCTAssertNotNil(ImageCrypto.plainSize(sealedSize: UInt64(original.count - segment), segmentShift: 12))
        assertRejected(lastDropped, key: key)
        let midCut = try file("mid-cut", original.prefix(original.count - 100))
        assertRejected(midCut, key: key)
        let appended = try file("appended", original + Data(repeating: 0, count: ImageCrypto.tagBytes))
        assertRejected(appended, key: key)
        let appendedSegment = try file("appended-segment", original + original.suffix(segment))
        assertRejected(appendedSegment, key: key)
    }

    func testSwappedSegmentsAreRejected() throws {
        let key = SymmetricKey(size: .bits256)
        let (_, sealed) = try sealSmall(3 * 4096, key: key)
        let bytes = try Data(contentsOf: sealed)
        let h = ImageCrypto.headerBytes, segment = 4096 + ImageCrypto.tagBytes
        var swapped = bytes.prefix(h)
        swapped.append(bytes[(h + segment)..<(h + 2 * segment)])
        swapped.append(bytes[h..<(h + segment)])
        swapped.append(bytes[(h + 2 * segment)...])
        assertRejected(try file("swapped", swapped), key: key)
    }

    func testWrongOrMissingKeyIsRejected() throws {
        let key = SymmetricKey(size: .bits256)
        let (_, sealed) = try sealSmall(5000, key: key)
        assertRejected(sealed, key: SymmetricKey(size: .bits256))
        let out = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try ImageCrypto.open(sealed, to: out) { _ in nil }) { error in
            XCTAssertTrue("\(error)".contains(ImageCrypto.keyId(for: key)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testPlainFileIsNotMistakenForSealed() throws {
        let plain = try file("plain.dmg", Data(repeating: 7, count: 100))
        XCTAssertFalse(ImageCrypto.looksSealed(plain))
        assertRejected(plain, key: SymmetricKey(size: .bits256))
    }

    func testPlainSizeRejectsImpossibleLengths() {
        let h = UInt64(ImageCrypto.headerBytes), t = UInt64(ImageCrypto.tagBytes), s: UInt64 = 4096
        XCTAssertNil(ImageCrypto.plainSize(sealedSize: h - 1, segmentShift: 12))
        XCTAssertNil(ImageCrypto.plainSize(sealedSize: h, segmentShift: 12))
        XCTAssertEqual(ImageCrypto.plainSize(sealedSize: h + t, segmentShift: 12), 0)
        XCTAssertNil(ImageCrypto.plainSize(sealedSize: h + t - 1, segmentShift: 12))
        XCTAssertNil(ImageCrypto.plainSize(sealedSize: h + (s + t) + t, segmentShift: 12), "trailing empty segment")
        XCTAssertNil(ImageCrypto.plainSize(sealedSize: h + (s + t) + 3, segmentShift: 12))
        XCTAssertEqual(ImageCrypto.plainSize(sealedSize: h + (s + t) + t + 1, segmentShift: 12), s + 1)
    }

    // MARK: - Keys and manifest

    func testImageKeyStoreUsesSynchronizableItems() throws {
        let secrets = MemorySecretStore()
        XCTAssertNil(try ImageKeyStore.current(secrets: secrets))
        let id = try ImageKeyStore.create(secrets: secrets)
        XCTAssertEqual(id.count, 8)
        XCTAssertThrowsError(try ImageKeyStore.create(secrets: secrets))
        let key = try XCTUnwrap(ImageKeyStore.load(secrets: secrets, keyId: id))
        XCTAssertEqual(ImageCrypto.keyId(for: key), id)
        XCTAssertEqual(secrets.synchronizable["\(ImageKeyStore.service)\u{0}image-key-\(id)"], true)
        XCTAssertEqual(secrets.synchronizable["\(ImageKeyStore.service)\u{0}image-key-current"], true)
        XCTAssertNil(try secrets.load(service: "io.github.s546126.disklessly.sessions", account: "segment-key-current"), "separate from session keys")

        let other = MemorySecretStore()
        XCTAssertEqual(try ImageKeyStore.importKey(base64: try ImageKeyStore.exportKey(secrets: secrets, keyId: id) + "\n", secrets: other), id)
        XCTAssertNotNil(try ImageKeyStore.load(secrets: other, keyId: id))
        XCTAssertThrowsError(try ImageKeyStore.importKey(base64: "c2hvcnQ=", secrets: other))
    }

    func testManifestEncryptionFieldIsOptional() throws {
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: String(repeating: "a", count: 64), size: 10, volumeName: "A", appPathInVolume: "A.app")
        let plain = ImageManifest(bundleId: "com.example.A", name: "A", version: "1", image: image, app: .init(originalPath: "/Applications/A.app", executable: "A", documentTypes: [], urlTypes: []), createdAt: now)
        let plainJSON = String(decoding: try plain.encode(), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("encryption"), "plain manifests are unchanged")
        let decoded = try ImageManifest.decode(Data(plainJSON.utf8))
        XCTAssertNil(decoded.image.encryption)
        XCTAssertEqual(decoded.image.plainSha256, image.sha256)

        var sealed = plain
        sealed.image.encryption = .init(scheme: ImageCrypto.scheme, keyId: "0123abcd", plainSha256: String(repeating: "b", count: 64), plainSize: 9)
        let back = try ImageManifest.decode(try sealed.encode())
        XCTAssertEqual(back.image.encryption, sealed.image.encryption)
        XCTAssertEqual(back.image.plainSha256, String(repeating: "b", count: 64))
        XCTAssertEqual(back.image.plainSize, 9)

        sealed.image.encryption?.scheme = "future/9"
        XCTAssertThrowsError(try ImageManifest.decode(try sealed.encode()))
    }

    func testFileSecretStoreRoundTrip() throws {
        let store = FileSecretStore(directory: root.appendingPathComponent("secrets"))
        XCTAssertNil(try store.load(service: "s", account: "a"))
        try store.save(service: "s", account: "a", secret: "v", synchronizable: true)
        XCTAssertEqual(try store.load(service: "s", account: "a"), "v")
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("secrets/s--a").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testPackEncryptFlagsAndConfigDefault() throws {
        XCTAssertNil(try PackArguments.parse(["App.app"]).encrypt)
        XCTAssertEqual(try PackArguments.parse(["App.app", "--encrypt"]).encrypt, true)
        XCTAssertEqual(try PackArguments.parse(["App.app", "--no-encrypt"]).encrypt, false)
        var config = RuntimeConfig(repoPath: "/r", cacheDir: "/c", stateDir: "/s", mountRoot: "/m", stubDir: "/a")
        XCTAssertEqual(try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(config)).imageEncryption, "off")
        config.imageEncryption = "aes-gcm"
        XCTAssertEqual(try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(config)).imageEncryption, "aes-gcm")
        XCTAssertEqual(RuntimeConfig.environment(["DISKLESSLY_IMAGE_ENCRYPTION": "aes-gcm"], home: root.path).imageEncryption, "aes-gcm")
        // A saved config.json does not hide the environment override.
        let state = root.appendingPathComponent("state-env")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try JSONEncoder().encode(RuntimeConfig(repoPath: "/r", cacheDir: "/c", stateDir: state.path, mountRoot: "/m", stubDir: "/a")).write(to: state.appendingPathComponent("config.json"))
        let merged = RuntimeConfig.resolved(environment: ["DISKLESSLY_STATE_DIR": state.path, "DISKLESSLY_IMAGE_ENCRYPTION": "aes-gcm"], home: root.path, stateDirOverride: nil, explicitConfig: nil)
        XCTAssertEqual(merged.imageEncryption, "aes-gcm")
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        XCTAssertTrue(try engine.imageEncryptionDefault())
        engine.config.imageEncryption = "rot13"
        XCTAssertThrowsError(try engine.imageEncryptionDefault())
    }

    // MARK: - Engine

    private func makeEngine(mac: String, secrets: MemorySecretStore) throws -> DisklesslyEngine {
        let macRoot = root.appendingPathComponent(mac)
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: macRoot.appendingPathComponent("cache").path,
            stateDir: macRoot.appendingPathComponent("state").path,
            mountRoot: macRoot.appendingPathComponent("mnt").path,
            stubDir: macRoot.appendingPathComponent("apps").path
        )
        config.minFreeBytes = 0
        var engine = DisklesslyEngine(config: config, secrets: secrets)
        engine.deviceFactsOverride = DeviceFacts(hostname: mac, arch: "arm64", osVersion: "15.6")
        engine.stubRootsOverride = [URL(fileURLWithPath: config.stubDir, isDirectory: true)]
        try engine.initialize()
        return engine
    }

    private func request(encrypt: Bool) -> PublishRequest {
        let hash = String(repeating: "c", count: 64)
        return PublishRequest(name: "Sealed", identity: ImageIdentity(bundleId: "com.example.Sealed", version: "1.0", build: "1", architectures: ["arm64"], treeHash: hash), mode: .mount, executable: "Sealed", originalPath: root.appendingPathComponent("Applications/Sealed.app").path, cdhash: "cd", postImageTreeHash: hash, volumeName: "Sealed", appPathInVolume: "Sealed.app", encrypt: encrypt)
    }

    func testEncryptedPublishAndPrefetchRoundTrip() throws {
        let secrets = MemorySecretStore()
        let keyId = try ImageKeyStore.create(secrets: secrets)
        let engine = try makeEngine(mac: "a", secrets: secrets)
        let plain = randomBytes((1 << 20) + 777)
        let dmg = try file("image.dmg", plain)
        let manifest = try engine.publish(request(encrypt: true), imageFile: dmg, now: now).manifest

        let encryption = try XCTUnwrap(manifest.image.encryption)
        XCTAssertEqual(encryption.keyId, keyId)
        XCTAssertEqual(encryption.scheme, ImageCrypto.scheme)
        XCTAssertEqual(encryption.plainSha256, SHA256Digest.hex(plain))
        XCTAssertEqual(encryption.plainSize, UInt64(plain.count))
        let remote = URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent(manifest.image.file)
        let remoteBytes = try Data(contentsOf: remote)
        XCTAssertEqual(Array(remoteBytes.prefix(4)), Array("DKLI".utf8))
        XCTAssertEqual(manifest.image.sha256, SHA256Digest.hex(remoteBytes))
        XCTAssertEqual(manifest.image.size, UInt64(remoteBytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmg.appendingPathExtension("dkli").path), "staged ciphertext removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dmg.path), "plain image left to the caller")

        let cache = try engine.prefetch(manifest)
        XCTAssertEqual(try Data(contentsOf: cache), plain)
        let stamp = try XCTUnwrap(StateStore(engine.config.stateDir).load().cache[manifest.imageId]?.verified)
        XCTAssertEqual(stamp.sha256, encryption.plainSha256)
        let partial = URL(fileURLWithPath: engine.config.cacheDir).appendingPathComponent("partial")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: partial.path)) ?? [], [], "no ciphertext or temp plaintext left")

        // The fast stamp holds: a second prefetch does not fetch again.
        let modified = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        _ = try engine.prefetch(manifest)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date, modified)

        // A corrupted cache is re-fetched and decrypted again.
        try Data("junk".utf8).write(to: cache)
        _ = try engine.prefetch(manifest)
        XCTAssertEqual(try Data(contentsOf: cache), plain)
    }

    func testMacWithoutTheKeyRefusesReuseAndPrefetch() throws {
        let secretsA = MemorySecretStore()
        _ = try ImageKeyStore.create(secrets: secretsA)
        let engineA = try makeEngine(mac: "a", secrets: secretsA)
        let manifest = try engineA.publish(request(encrypt: true), imageFile: try file("image.dmg", randomBytes(5000)), now: now).manifest

        let engineB = try makeEngine(mac: "b", secrets: MemorySecretStore())
        XCTAssertThrowsError(try engineB.publish(request(encrypt: false), imageFile: try file("b.dmg", randomBytes(10)), now: now)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 5)
            XCTAssertTrue("\(error)".contains("original app was not changed"), "\(error)")
        }
        XCTAssertThrowsError(try engineB.prefetch(manifest)) { error in
            XCTAssertTrue("\(error)".contains(manifest.image.encryption!.keyId), "\(error)")
        }
        let cache = URL(fileURLWithPath: engineB.config.cacheDir).appendingPathComponent("partial/\(manifest.imageId).dmg.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "nothing downloaded without a key")
    }

    func testEncryptWithoutKeyFailsBeforeUpload() throws {
        let engine = try makeEngine(mac: "a", secrets: MemorySecretStore())
        XCTAssertThrowsError(try engine.publish(request(encrypt: true), imageFile: try file("image.dmg", randomBytes(10)), now: now)) { error in
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 2)
        }
        let images = URL(fileURLWithPath: engine.config.repoPath).appendingPathComponent("images")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [], [])
    }

    func testPlainPublishIsUnchanged() throws {
        let secrets = MemorySecretStore()
        _ = try ImageKeyStore.create(secrets: secrets)
        let engine = try makeEngine(mac: "a", secrets: secrets)
        let plain = randomBytes(3000)
        let manifest = try engine.publish(request(encrypt: false), imageFile: try file("image.dmg", plain), now: now).manifest
        XCTAssertNil(manifest.image.encryption)
        XCTAssertEqual(manifest.image.sha256, SHA256Digest.hex(plain))
        XCTAssertEqual(try Data(contentsOf: try engine.prefetch(manifest)), plain)
    }

    func testRestoreArchiveChecksRepoObjectAgainstCipherHash() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = randomBytes(5000)
        let repo = root.appendingPathComponent("repo-r"), cache = root.appendingPathComponent("cache-r")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("images"), withIntermediateDirectories: true)
        let source = try file("restore-plain", plain)
        let sealed = try ImageCrypto.seal(source, to: repo.appendingPathComponent("images/img.dmg"), key: key)
        let config = RuntimeConfig(repoPath: repo.path, cacheDir: cache.path, stateDir: root.path, mountRoot: root.path, stubDir: root.path)
        let journal = RestoreJournal(txid: "t", appId: "com.example.App", imageId: "img", owner: ProcessOwner(pid: 1, start: 1), dest: "/Applications/App.app", staging: "/tmp/stage", imagePath: cache.appendingPathComponent("images/img.dmg").path, imageFile: "images/img.dmg", appName: "App", stubBundleId: "com.example.App.256stub", executable: "App", manifestCdhash: "cd", manifestTreeHash: "tree", imageSha256: sealed.plainSha256, imageCipherSha256: sealed.sha256)
        XCTAssertTrue(RestoreArchive.verified(journal, config: config), "repo ciphertext verifies with the cipher hash")
        var legacy = journal
        legacy.imageCipherSha256 = nil
        XCTAssertFalse(RestoreArchive.verified(legacy, config: config))
        let decoded = try RestoreJournal.decode(try legacy.encode())
        XCTAssertNil(decoded.imageCipherSha256)
    }
}
