import Crypto
import Foundation
import DisklesslyCore

public enum SegmentCrypto {
    public static func keyId(for key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        return String(SHA256Digest.hex(raw).prefix(8))
    }

    public static func seal(plain: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad)
        var envelope = Data("ISEGENC1".utf8)
        envelope.append(Data(keyId(for: key).utf8))
        envelope.append(Data(nonce))
        envelope.append(sealed.ciphertext)
        envelope.append(Data(sealed.tag))
        return envelope
    }

    public static func open(envelope: Data, keyring: [String: SymmetricKey], aad: Data) throws -> Data {
        guard envelope.count >= 8 + 8 + 12 + 16 else {
            throw DisklesslyError.integrity("truncated session segment envelope")
        }
        guard envelope.prefix(8) == Data("ISEGENC1".utf8) else {
            throw DisklesslyError.integrity("session segment envelope is not ISEGENC1")
        }
        let id = String(decoding: envelope.subdata(in: 8..<16), as: UTF8.self)
        guard let key = keyring[id] else {
            throw DisklesslyError.integrity("segment encrypted with unknown key \(id)")
        }
        let nonceBytes = envelope.subdata(in: 16..<28)
        let tag = envelope.suffix(16)
        let ciphertext = envelope.subdata(in: 28..<(envelope.count - 16))
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch let error as DisklesslyError {
            throw error
        } catch {
            throw DisklesslyError.integrity("session segment authentication failed")
        }
    }
}

public enum SessionKeyStore {
    public static let service = "io.github.s546126.disklessly.sessions"

    public static func create(secrets: any SecretStore) throws -> String {
        if try secrets.load(service: service, account: "segment-key-current") != nil {
            throw DisklesslyError.usage("a session key already exists; disklessly sessions key status")
        }
        let key = SymmetricKey(size: .bits256)
        let id = SegmentCrypto.keyId(for: key)
        let raw = key.withUnsafeBytes { Data($0) }
        // Session keys replicate through iCloud Keychain. Encryption stays off
        // unless `sessionEncryption` is `aes-gcm` or the CLI passes `--encrypt`.
        try secrets.save(service: service, account: "segment-key-\(id)", secret: raw.base64EncodedString(), synchronizable: true)
        try secrets.save(service: service, account: "segment-key-current", secret: id, synchronizable: true)
        return id
    }

    public static func currentKeyId(secrets: any SecretStore) throws -> String? {
        try secrets.load(service: service, account: "segment-key-current")
    }

    public static func keyring(secrets: any SecretStore) throws -> [String: SymmetricKey] {
        guard let id = try currentKeyId(secrets: secrets) else { return [:] }
        guard let key = try load(secrets: secrets, keyId: id) else { return [:] }
        return [id: key]
    }

    public static func load(secrets: any SecretStore, keyId: String) throws -> SymmetricKey? {
        guard let stored = try secrets.load(service: service, account: "segment-key-\(keyId)"),
              let data = Data(base64Encoded: stored), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
