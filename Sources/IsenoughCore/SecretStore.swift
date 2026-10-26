import Foundation
#if os(macOS)
import Security
#endif

/// Credentials for SMB, NFS, and WebDAV. Config files never carry these values.
public protocol SecretStore: AnyObject {
    func load(service: String, account: String) throws -> String?
    func save(service: String, account: String, secret: String) throws
    /// `synchronizable` asks iCloud Keychain to replicate the item. The default calls `save` and ignores the flag.
    func save(service: String, account: String, secret: String, synchronizable: Bool) throws
    /// Extra mount-system credential (SMB internet password). The generic item remains the one isenough reads back.
    func saveMountCredential(kind: String, host: String, account: String, secret: String) throws
}

extension SecretStore {
    public func save(service: String, account: String, secret: String, synchronizable: Bool) throws {
        _ = synchronizable
        try save(service: service, account: account, secret: secret)
    }
}

public final class MemorySecretStore: SecretStore {
    public var values: [String: String] = [:]
    public var synchronizable: [String: Bool] = [:]
    public var mountCredentials: [(kind: String, host: String, account: String, secret: String)] = []
    public init() {}
    private func key(_ service: String, _ account: String) -> String { "\(service)\u{0}\(account)" }
    public func load(service: String, account: String) throws -> String? { values[key(service, account)] }
    public func save(service: String, account: String, secret: String) throws { values[key(service, account)] = secret }
    public func save(service: String, account: String, secret: String, synchronizable: Bool) throws {
        try save(service: service, account: account, secret: secret)
        self.synchronizable[key(service, account)] = synchronizable
    }
    public func saveMountCredential(kind: String, host: String, account: String, secret: String) throws {
        mountCredentials.append((kind, host, account, secret))
    }
}

public final class KeychainSecretStore: SecretStore {
    public init() {}

    public func load(service: String, account: String) throws -> String? {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw IsenoughError.backend("Keychain read failed (\(status))")
        }
        return String(data: data, encoding: .utf8)
        #else
        throw IsenoughError.unsupported("Keychain is available on macOS")
        #endif
    }

    public func save(service: String, account: String, secret: String) throws {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw IsenoughError.backend("Keychain save failed (\(status))") }
        #else
        throw IsenoughError.unsupported("Keychain is available on macOS")
        #endif
    }

    public func save(service: String, account: String, secret: String, synchronizable: Bool) throws {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if synchronizable {
            add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw IsenoughError.backend("Keychain save failed (\(status))") }
        #else
        _ = synchronizable
        throw IsenoughError.unsupported("Keychain is available on macOS")
        #endif
    }

    public func saveMountCredential(kind: String, host: String, account: String, secret: String) throws {
        #if os(macOS)
        guard kind == "smb" else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw IsenoughError.backend("Keychain SMB save failed (\(status))") }
        #else
        _ = (kind, host, account, secret)
        #endif
    }
}
