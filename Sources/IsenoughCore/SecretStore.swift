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

/// What the last `save` actually stored.
public enum KeychainSaveOutcome: Equatable {
    /// Stored as a local (non-synchronizable) item, as requested.
    case local
    /// Stored as an iCloud Keychain (synchronizable) item.
    case synchronizable
    /// Synchronizable was requested but the binary lacks the keychain entitlement
    /// (errSecMissingEntitlement, -34018, typical of ad-hoc CLI builds). A local
    /// item was stored instead, so it does not replicate to other Macs.
    case localFallback(status: Int32)
}

public final class KeychainSecretStore: SecretStore {
    /// errSecMissingEntitlement.
    public static let missingEntitlement: Int32 = -34018

    /// Outcome of the most recent `save` on this instance.
    public private(set) var lastSaveOutcome: KeychainSaveOutcome?

    public init() {}

    public func load(service: String, account: String) throws -> String? {
        #if os(macOS)
        // Match synchronizable and local items alike. Without this attribute a
        // query only sees non-synchronizable items, so a session key saved with
        // synchronizable: true read back as missing.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == Self.missingEntitlement {
            // Some keychains reject the synchronizable attribute; retry the plain query.
            query.removeValue(forKey: kSecAttrSynchronizable as String)
            item = nil
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
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
        try save(service: service, account: account, secret: secret, synchronizable: false)
    }

    public func save(service: String, account: String, secret: String, synchronizable: Bool) throws {
        lastSaveOutcome = try saveReporting(service: service, account: account, secret: secret, synchronizable: synchronizable)
    }

    /// Saves and reports whether the item is synchronizable. A synchronizable save
    /// that fails with errSecMissingEntitlement falls back to a local item and
    /// returns `.localFallback` instead of failing.
    @discardableResult
    public func saveReporting(service: String, account: String, secret: String, synchronizable: Bool) throws -> KeychainSaveOutcome {
        #if os(macOS)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        Self.deleteAll(base)
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard synchronizable else {
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw IsenoughError.backend("Keychain save failed (\(status))") }
            return .local
        }
        // Session keys pass synchronizable: true and become iCloud Keychain items.
        // Backend passwords use save() and do not set this attribute.
        var synced = add
        synced[kSecAttrSynchronizable as String] = kCFBooleanTrue
        let status = SecItemAdd(synced as CFDictionary, nil)
        if status == errSecSuccess { return .synchronizable }
        guard status == Self.missingEntitlement else {
            throw IsenoughError.backend("Keychain save failed (\(status))")
        }
        let fallback = SecItemAdd(add as CFDictionary, nil)
        guard fallback == errSecSuccess else { throw IsenoughError.backend("Keychain save failed (\(fallback))") }
        FileHandle.standardError.write(Data("isenough: warning: this build cannot write iCloud Keychain items (\(status)); \(account) was saved to this Mac's keychain only and will not sync to other Macs.\n".utf8))
        return .localFallback(status: status)
        #else
        _ = (service, account, secret, synchronizable)
        throw IsenoughError.unsupported("Keychain is available on macOS")
        #endif
    }

    /// Removes the item for `service`/`account`, synchronizable or not.
    public func delete(service: String, account: String) {
        #if os(macOS)
        Self.deleteAll([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ])
        #else
        _ = (service, account)
        #endif
    }

    #if os(macOS)
    private static func deleteAll(_ base: [String: Any]) {
        var any = base
        any[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(any as CFDictionary)
        SecItemDelete(base as CFDictionary)
    }
    #endif

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
