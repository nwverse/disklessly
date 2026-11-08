import Foundation
import Crypto

/// What a signed license code says. The code is `DSL1.<payload>.<signature>`, both parts base64url:
/// the payload is this struct as JSON and the signature is Ed25519 over the payload bytes.
public struct LicensePayload: Codable, Equatable {
    public var v: Int
    public var product: String
    /// Unique id of the code, for support and for telling codes apart.
    public var id: String
    /// "pro" is a paid buyout. "promo" is a time-limited code that must carry `expires`.
    public var edition: String
    public var email: String?
    /// yyyy-MM-dd (UTC).
    public var issued: String
    /// yyyy-MM-dd (UTC), the last day the code works. Nil for a buyout.
    public var expires: String?
    /// yyyy-MM-dd (UTC). Informational: releases after this day are not covered by a buyout.
    public var updatesUntil: String?

    public init(id: String, edition: String, email: String? = nil, issued: String, expires: String? = nil, updatesUntil: String? = nil) {
        self.v = 1
        self.product = License.product
        self.id = id
        self.edition = edition
        self.email = email
        self.issued = issued
        self.expires = expires
        self.updatesUntil = updatesUntil
    }
}

public enum LicenseState: Equatable {
    /// No code. The free limit applies.
    case free
    case licensed(LicensePayload)
    /// A signed promo code past its last day. The free limit applies again.
    case expired(LicensePayload)
    /// A code was present but is not a valid Disklessly license.
    case invalid(String)

    public var unlimited: Bool {
        if case .licensed = self { return true }
        return false
    }
}

/// Free tier and license codes. Only `pack` and `offload` check the limit: starting, restoring, unpacking,
/// evicting and detaching already packed apps, and fetching offloaded files, never depend on a license.
public enum License {
    public static let product = "disklessly"
    /// Apps, files and folders that may be offloaded at the same time without a license.
    public static let freeAppLimit = 2

    /// The switch for the free limit. Off for now: every pack and offload is allowed, nothing asks for a
    /// license code, and the dashboard hides the license card. Turn it on here (or with
    /// `DISKLESSLY_LICENSE_LIMIT=1`) when paid licenses start.
    public static let limitEnabledByDefault = false
    /// Tests set this to exercise the limit whatever the default is.
    public static var limitOverride: Bool?
    public static var limitEnabled: Bool {
        if let limitOverride { return limitOverride }
        if let value = ProcessInfo.processInfo.environment["DISKLESSLY_LICENSE_LIMIT"], !value.isEmpty { return value == "1" }
        return limitEnabledByDefault
    }
    public static let tokenPrefix = "DSL1"
    public static let fileName = "license.key"

    /// Ed25519 public key, base64 (32 bytes). The private key never ships.
    public static let publicKeyBase64 = "HdMpAsQVxLgX/02DU10yGfQRkLEWDgN/feRpUuxONgw="

    public static var publicKey: Curve25519.Signing.PublicKey? {
        #if DEBUG
        // Tests and scripts/e2e.sh sign throwaway codes with their own key. Release builds
        // do not compile this in, so the variable does nothing there.
        if let text = ProcessInfo.processInfo.environment["DISKLESSLY_LICENSE_PUBLIC_KEY"], let raw = Data(base64Encoded: text),
           let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) { return key }
        #endif
        return Data(base64Encoded: publicKeyBase64).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    // MARK: Encoding

    public static func issue(_ payload: LicensePayload, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        let signature = try privateKey.signature(for: body)
        return [tokenPrefix, base64url(body), base64url(signature)].joined(separator: ".")
    }

    /// Checks the signature and the dates. Never throws: a bad code is `.invalid`.
    public static func verify(_ token: String, publicKey: Curve25519.Signing.PublicKey? = License.publicKey, now: Date = Date()) -> LicenseState {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == tokenPrefix else { return .invalid("not a Disklessly license code") }
        guard let body = decodeBase64url(parts[1]), let signature = decodeBase64url(parts[2]) else {
            return .invalid("the license code is damaged")
        }
        guard let publicKey else { return .invalid("this build has no license key") }
        guard publicKey.isValidSignature(signature, for: body) else { return .invalid("the license code is not valid") }
        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: body), payload.v == 1, payload.product == product else {
            return .invalid("the license code is for a different product")
        }
        let today = day(now)
        if payload.edition == "promo" {
            guard let expires = payload.expires else { return .invalid("a promo code needs an expiry date") }
            return expires < today ? .expired(payload) : .licensed(payload)
        }
        guard payload.edition == "pro" else { return .invalid("unknown license edition") }
        if let expires = payload.expires, expires < today { return .expired(payload) }
        return .licensed(payload)
    }

    // MARK: Storage

    public static func load(stateDir: String, publicKey: Curve25519.Signing.PublicKey? = License.publicKey, now: Date = Date()) -> LicenseState {
        let url = URL(fileURLWithPath: stateDir).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), let token = String(data: data, encoding: .utf8) else { return .free }
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .free }
        return verify(token, publicKey: publicKey, now: now)
    }

    /// Verifies and saves. An invalid or expired code is refused and nothing is written.
    @discardableResult
    public static func activate(_ token: String, stateDir: String, publicKey: Curve25519.Signing.PublicKey? = License.publicKey, now: Date = Date()) throws -> LicensePayload {
        switch verify(token, publicKey: publicKey, now: now) {
        case .licensed(let payload):
            try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: stateDir).appendingPathComponent(fileName)
            try Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8).write(to: url, options: .atomic)
            return payload
        case .expired(let payload):
            throw DisklesslyError.usage("this license code expired on \(payload.expires ?? "an earlier date")")
        case .invalid(let reason):
            throw DisklesslyError.usage(reason)
        case .free:
            throw DisklesslyError.usage("empty license code")
        }
    }

    public static func deactivate(stateDir: String) throws {
        let url = URL(fileURLWithPath: stateDir).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    // MARK: The limit

    /// Refuses a pack that would push the number of offloaded items over the free limit.
    /// Offloaded files and folders (`files`) count too: the limit is on things offloaded at once.
    /// Re-packing an app that is already offloaded is not a new app.
    public static func checkPack(state: LicenseState, offloaded: Set<String>, packing bundleId: String, files: Int = 0) throws {
        if state.unlimited || offloaded.contains(bundleId) { return }
        try checkLimit(state: state, count: offloaded.count + files)
    }

    /// Refuses offloading one more file or folder past the free limit. `apps` and `files` are what is offloaded now.
    public static func checkOffloadFile(state: LicenseState, apps: Int, files: Int) throws {
        if state.unlimited { return }
        try checkLimit(state: state, count: apps + files)
    }

    private static func checkLimit(state: LicenseState, count: Int) throws {
        if !limitEnabled || count < freeAppLimit { return }
        var why = "The free version offloads up to \(freeAppLimit) apps or files at once and \(count) are offloaded already."
        if case .expired(let payload) = state { why = "Your promo code expired on \(payload.expires ?? "an earlier date"). " + why }
        throw DisklesslyError.licenseRequired(why + " Starting, restoring and unpacking your offloaded apps, and bringing back offloaded files, stays free. Enter a license code with `disklessly license activate CODE` to offload more.")
    }

    // MARK: Helpers

    public static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
