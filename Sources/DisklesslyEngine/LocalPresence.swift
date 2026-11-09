import Foundation

/// What this Mac has for an image in the shared repo. The repo is shared by every Mac on the
/// account, so a manifest alone says nothing about this Mac: the image may have been packed on
/// another Mac, and the app may never have been installed here.
public struct LocalPresence: Equatable {
    public enum Kind: String {
        /// A Disklessly launcher for this app is installed here.
        case stub
        /// The full app (same bundle id) is installed here, not a launcher.
        case installed
        /// Neither: the image belongs to another Mac, or this Mac's launcher was removed.
        case absent
    }
    public var kind: Kind
    /// This Mac's own device record lists the image (it was packed or adopted here).
    public var mine: Bool
    public var path: String?
    /// Version of the full app, when `kind` is `.installed`.
    public var version: String?

    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue, "mine": mine]
        if let path { object["path"] = path }
        if let version { object["version"] = version }
        return object
    }
}

/// Reads the app folder once, then answers per manifest.
public struct LocalAppIndex {
    struct Bundle: Equatable {
        var path: String
        var bundleId: String
        var version: String?
        var isStub: Bool
    }
    var bundles: [Bundle]

    public init(folders: [String]) {
        let fm = FileManager.default
        var out: [Bundle] = []
        for folder in folders {
            let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            for name in names where name.hasSuffix(".app") && !name.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(name)
                if let bundle = Self.read(path) { out.append(bundle) }
            }
        }
        bundles = out
    }

    init(bundles: [Bundle]) { self.bundles = bundles }

    static func read(_ path: String) -> Bundle? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        let stubJSON = URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources/stub.json").path
        let isStub = id.hasSuffix(".256stub") || FileManager.default.fileExists(atPath: stubJSON)
        return Bundle(path: path, bundleId: id, version: info["CFBundleShortVersionString"] as? String, isStub: isStub)
    }

    /// `ownImageIds` are the images in this Mac's device record.
    public func presence(bundleId: String, imageId: String, ownImageIds: Set<String>) -> LocalPresence {
        let mine = ownImageIds.contains(imageId)
        let stubId = bundleId + ".256stub"
        if let stub = bundles.first(where: { $0.isStub && ($0.bundleId == stubId || $0.bundleId == bundleId) }) {
            return LocalPresence(kind: .stub, mine: mine, path: stub.path, version: nil)
        }
        if let full = bundles.first(where: { !$0.isStub && $0.bundleId == bundleId }) {
            return LocalPresence(kind: .installed, mine: mine, path: full.path, version: full.version)
        }
        return LocalPresence(kind: .absent, mine: mine, path: nil, version: nil)
    }
}
