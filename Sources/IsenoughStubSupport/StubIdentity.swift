import Foundation

/// The identity fields of a stub's `Contents/Resources/stub.json`.
///
/// `repoId` names the repo the stub's image lives in. Stubs written before it
/// existed have no `repoId`; the launcher never reads it, so those stubs still
/// launch. Only the engine uses it, to decide which repo may claim a stub.
public struct StubIdentity: Equatable {
    public static let schema = "stub/1"
    public static let fileName = "stub.json"

    public var appId: String?
    public var imageId: String?
    public var repoId: String?

    public init(appId: String? = nil, imageId: String? = nil, repoId: String? = nil) {
        self.appId = appId
        self.imageId = imageId
        self.repoId = repoId
    }

    /// Reads the fields from a decoded `stub.json`. Empty strings count as absent.
    public init(object: [String: Any]) {
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        self.init(appId: text("appId"), imageId: text("imageId"), repoId: text("repoId"))
    }

    /// Reads `<bundle>/Contents/Resources/stub.json`. Nil when it is missing or not an object.
    public static func read(bundle: URL) -> StubIdentity? {
        guard let object = readObject(bundle: bundle) else { return nil }
        return StubIdentity(object: object)
    }

    public static func readObject(bundle: URL) -> [String: Any]? {
        let url = bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// True for stubs written before `repoId` was recorded.
    public var isLegacy: Bool { repoId == nil }

    /// Whether the repo `currentRepoId` may count this stub as its own.
    ///
    /// - A stub that names a repo belongs to that repo only.
    /// - A legacy stub belongs to a repo that has a manifest for its image
    ///   (`imageInRepo`). Without one it is some other repo's stub.
    /// - When the current repo's id is unknown, only the manifest test applies.
    public func belongs(toRepo currentRepoId: String?, imageInRepo: Bool) -> Bool {
        if let repoId, let currentRepoId {
            return repoId == currentRepoId
        }
        return imageInRepo
    }

    /// Whether this stub names a different repo than `currentRepoId`.
    public func isForeign(toRepo currentRepoId: String?) -> Bool {
        guard let repoId, let currentRepoId else { return false }
        return repoId != currentRepoId
    }
}
