import Foundation

/// A user-defined linked group tying an app bundle to one or more extra folders/files
/// (for example `vphone.app` + `~/.vphone`) so they offload, restore, and launch together.
public struct LinkedBundle: Codable, Equatable {
    public var id: String
    public var name: String
    public var appPath: String
    public var paths: [String]

    public init(id: String, name: String, appPath: String, paths: [String]) {
        self.id = id
        self.name = name
        self.appPath = appPath
        self.paths = paths
    }

    public func jsonObject() -> [String: Any] {
        ["id": id, "name": name, "appPath": appPath, "paths": paths]
    }
}

public struct LinkedBundleStore {
    public var stateDir: String
    public var url: URL { URL(fileURLWithPath: stateDir, isDirectory: true).appendingPathComponent("linked-bundles.json") }

    public init(stateDir: String) {
        self.stateDir = stateDir
    }

    public func load() -> [LinkedBundle] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LinkedBundle].self, from: data)) ?? []
    }

    public func save(_ bundles: [LinkedBundle]) throws {
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(bundles).write(to: url, options: .atomic)
    }

    @discardableResult
    public func link(appPath: String, appName: String, extraPath: String) throws -> LinkedBundle {
        let normApp = URL(fileURLWithPath: appPath).standardizedFileURL.path
        let normExtra = URL(fileURLWithPath: extraPath).standardizedFileURL.path
        var all = load()
        if let idx = all.firstIndex(where: { $0.appPath == normApp }) {
            if !all[idx].paths.contains(normExtra) {
                all[idx].paths.append(normExtra)
            }
            if !appName.isEmpty { all[idx].name = appName }
            try save(all)
            return all[idx]
        }
        let id = SHA256Digest.hex(Data(normApp.utf8)).prefix(16)
        let created = LinkedBundle(
            id: String(id),
            name: appName.isEmpty ? URL(fileURLWithPath: normApp).deletingPathExtension().lastPathComponent : appName,
            appPath: normApp,
            paths: [normExtra]
        )
        all.append(created)
        try save(all)
        return created
    }

    public func unlink(appPath: String, extraPath: String) throws {
        let normApp = URL(fileURLWithPath: appPath).standardizedFileURL.path
        let normExtra = URL(fileURLWithPath: extraPath).standardizedFileURL.path
        var all = load()
        guard let idx = all.firstIndex(where: { $0.appPath == normApp }) else { return }
        all[idx].paths.removeAll { $0 == normExtra }
        if all[idx].paths.isEmpty { all.remove(at: idx) }
        try save(all)
    }

    public func bundle(id: String) -> LinkedBundle? {
        load().first { $0.id == id }
    }

    public func bundle(forAppPath appPath: String) -> LinkedBundle? {
        let norm = URL(fileURLWithPath: appPath).standardizedFileURL.path
        return load().first { $0.appPath == norm }
    }

    public func bundle(forPath path: String) -> LinkedBundle? {
        let norm = URL(fileURLWithPath: path).standardizedFileURL.path
        return load().first { $0.appPath == norm || $0.paths.contains(norm) }
    }
}
