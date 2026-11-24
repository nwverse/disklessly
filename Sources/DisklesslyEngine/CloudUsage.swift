import Foundation
import DisklesslyCore

/// What the repo holds for this Mac, as rows from the local catalog. Tests build this by hand.
/// `bytes` is always the size the item had on disk (what a restore takes back), not the stored size.
public struct CloudUsageInputs {
    public struct Item {
        public var id: String
        public var name: String
        public var bytes: UInt64
        public var storedBytes: UInt64?
        public var originPath: String?
        public var stubPath: String?
        public var localBytes: UInt64 = 0
        public var offloadedAt: Date?
        public var lastUsed: Date?
        public var restore: String?
        public var restoreId: String?
        public var otherDevice: String?
        public init(id: String, name: String, bytes: UInt64, storedBytes: UInt64? = nil, originPath: String? = nil, stubPath: String? = nil, localBytes: UInt64 = 0, offloadedAt: Date? = nil, lastUsed: Date? = nil, restore: String? = nil, restoreId: String? = nil, otherDevice: String? = nil) {
            self.id = id; self.name = name; self.bytes = bytes; self.storedBytes = storedBytes; self.originPath = originPath; self.stubPath = stubPath
            self.localBytes = localBytes; self.offloadedAt = offloadedAt; self.lastUsed = lastUsed; self.restore = restore; self.restoreId = restoreId; self.otherDevice = otherDevice
        }
    }

    /// A packed app. `installPath` is where it lived (and where its stub sits now).
    public struct App {
        public var item: Item
        public var bundleId: String
        public init(item: Item, bundleId: String) { self.item = item; self.bundleId = bundleId }
    }

    /// A linked bundle's offloaded paths; it goes under its app when that app is packed.
    public struct Linked {
        public var id: String
        public var name: String
        public var appPath: String
        public var items: [Item]
        public init(id: String, name: String, appPath: String, items: [Item]) { self.id = id; self.name = name; self.appPath = appPath; self.items = items }
    }

    /// An app's data folders offloaded with it (`AppDataRecord` in state `offloaded`).
    public struct DataOffload {
        public var item: Item
        public var bundleId: String
        public init(item: Item, bundleId: String) { self.item = item; self.bundleId = bundleId }
    }

    /// An archived agent session, grouped by tool.
    public struct Session {
        public var item: Item
        public var tool: String
        public init(item: Item, tool: String) { self.item = item; self.tool = tool }
    }

    public var apps: [App] = []
    public var files: [Item] = []
    public var linked: [Linked] = []
    public var data: [DataOffload] = []
    public var sessions: [Session] = []

    public init() {}

    /// Where every item came from on this Mac (for the cloud badges on the local map).
    public var originPaths: [String] {
        apps.compactMap(\.item.originPath) + files.compactMap(\.originPath)
            + linked.flatMap { $0.items.compactMap(\.originPath) }
            + data.compactMap(\.item.originPath) + sessions.compactMap(\.item.originPath)
    }
}

public enum CloudUsage {
    /// Builds the cloud side: groups `apps`, `files`, `linked`, `data`, `sessions`, largest first, each list
    /// capped at `UsageMap.maxListed` with the rest merged into one "other" box. Linked bundles and data
    /// offloads sit under their app when the app is packed. Every box has kind `offloaded`.
    public static func assemble(_ input: CloudUsageInputs) -> UsageNode {
        var appsByBundle: [String: Int] = [:]
        var appsByPath: [String: Int] = [:]
        var appExtras: [[UsageNode]] = Array(repeating: [], count: input.apps.count)
        for (index, app) in input.apps.enumerated() {
            appsByBundle[app.bundleId] = index
            if let path = app.item.originPath { appsByPath[standard(path)] = index }
        }

        var looseLinked: [UsageNode] = []
        for linked in input.linked {
            let children = UsageMap.merged(linked.items.map { leaf($0, key: nil) }, kind: .offloaded)
            guard !children.isEmpty else { continue }
            var node = UsageNode.group(name: linked.name, key: "linked", kind: .offloaded, children)
            var info = UsageNode.CloudInfo(id: "linked:" + linked.id)
            info.originPath = linked.items.count == 1 ? linked.items[0].originPath : nil
            info.offloadedAt = linked.items.compactMap(\.offloadedAt).max()
            info.restore = "links/restore"
            info.restoreId = linked.id
            info.storedBytes = sum(linked.items.map(\.storedBytes))
            node.cloud = info
            if let index = appsByPath[standard(linked.appPath)] { appExtras[index].append(node) } else { looseLinked.append(node) }
        }

        var looseData: [UsageNode] = []
        for data in input.data {
            let node = leaf(data.item, key: "data")
            if let index = appsByBundle[data.bundleId] { appExtras[index].append(node) } else { looseData.append(node) }
        }

        let appNodes: [UsageNode] = input.apps.enumerated().map { index, app in
            let extras = appExtras[index]
            guard !extras.isEmpty else { return leaf(app.item, key: nil) }
            // The app box restores the whole app; its first child is the image alone.
            var image = leaf(app.item, key: "bundle")
            image.cloud?.id = app.item.id + "#image"
            var node = UsageNode.group(name: app.item.name, kind: .offloaded, [image] + extras.sorted { $0.bytes > $1.bytes })
            node.cloud = leaf(app.item, key: nil).cloud
            return node
        }

        var toolNodes: [String: [UsageNode]] = [:]
        for session in input.sessions { toolNodes[session.tool, default: []].append(leaf(session.item, key: nil)) }
        let tools: [UsageNode] = toolNodes.map { tool, sessions in
            var node = UsageNode.group(name: tool, kind: .offloaded, UsageMap.merged(sessions, kind: .offloaded))
            node.cloud = nil
            return node
        }

        let groups: [UsageNode] = [
            UsageNode.group(name: "Apps", key: "apps", kind: .offloaded, UsageMap.merged(appNodes, kind: .offloaded)),
            UsageNode.group(name: "Files and folders", key: "files", kind: .offloaded, UsageMap.merged(input.files.map { leaf($0, key: nil) }, kind: .offloaded)),
            UsageNode.group(name: "Linked bundles", key: "linked", kind: .offloaded, UsageMap.merged(looseLinked, kind: .offloaded)),
            UsageNode.group(name: "App data", key: "data", kind: .offloaded, UsageMap.merged(looseData, kind: .offloaded)),
            UsageNode.group(name: "Sessions", key: "sessions", kind: .offloaded, UsageMap.merged(tools, kind: .offloaded)),
        ].filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        return UsageNode.group(name: "Cloud", key: "cloud", kind: .root, groups)
    }

    /// Sum of `storedBytes` over the tree's leaves (items whose stored size is unknown count nothing).
    public static func storedBytes(_ node: UsageNode) -> UInt64 {
        if node.children.isEmpty { return node.cloud?.storedBytes ?? 0 }
        return node.children.reduce(0) { $0 + storedBytes($1) }
    }

    static func leaf(_ item: CloudUsageInputs.Item, key: String?) -> UsageNode {
        var node = UsageNode(name: item.name, key: key, kind: .offloaded, bytes: item.bytes)
        var info = UsageNode.CloudInfo(id: item.id)
        info.storedBytes = item.storedBytes
        info.originPath = item.originPath
        info.stubPath = item.stubPath
        info.localBytes = item.localBytes
        info.offloadedAt = item.offloadedAt
        info.lastUsed = item.lastUsed
        info.restore = item.restore
        info.restoreId = item.restoreId
        info.otherDevice = item.otherDevice
        node.cloud = info
        // Age on the cloud side: last use when known, else when it was offloaded.
        node.modified = item.lastUsed ?? item.offloadedAt
        return node
    }

    private static func sum(_ values: [UInt64?]) -> UInt64? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    private static func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}

// MARK: - Reading the local catalog

/// The packed apps `dashboard()` last listed. Kept so `/api/usage/cloud` never waits on the backend;
/// replaced only by a listing that succeeded, so an offline repo keeps showing the last known catalog.
public struct CloudAppCatalog {
    public var apps: [CloudUsageInputs.App]
    public var listedAt: Date
    public init(apps: [CloudUsageInputs.App], listedAt: Date) { self.apps = apps; self.listedAt = listedAt }
}

extension CloudUsage {
    /// The most placeholders read for their stored size; past this the stored size is left out.
    static let placeholderReadLimit = 2000

    /// One packed app as the cloud side shows it, or nil when the repo holds it for this Mac only in
    /// name (the full app is installed here again, or it was never here).
    public static func appItem(_ manifest: ImageManifest, presence: LocalPresence, cachedBytes: UInt64, lastUsed: Date?, holders: [String]) -> CloudUsageInputs.App? {
        let here = presence.kind == .stub || (presence.mine && presence.kind != .installed)
        guard here else { return nil }
        var item = CloudUsageInputs.Item(id: manifest.imageId, name: manifest.name, bytes: manifest.image.plainSize)
        item.storedBytes = manifest.image.size
        item.originPath = manifest.app.originalPath
        item.stubPath = presence.kind == .stub ? presence.path : nil
        item.localBytes = cachedBytes
        item.offloadedAt = manifest.createdAt
        item.lastUsed = lastUsed
        item.restore = "unpack"
        item.restoreId = manifest.name
        item.otherDevice = holders.isEmpty ? nil : holders.joined(separator: ", ")
        return .init(item: item, bundleId: manifest.bundleId)
    }

    /// Everything but the apps comes from this Mac's state folder: offloaded files, linked bundles,
    /// app data records and the session index. No backend call.
    /// `readPlaceholders` false skips the stored sizes (enough for `originPaths`).
    public static func inputs(engine: DisklesslyEngine, apps: [CloudUsageInputs.App], readPlaceholders: Bool = true) -> CloudUsageInputs {
        var input = CloudUsageInputs()
        input.apps = apps
        let stateDir = engine.config.stateDir
        let bundles = engine.linkedBundleStore.load()
        var linkedOf: [String: Int] = [:]
        for (index, bundle) in bundles.enumerated() {
            for path in bundle.paths { linkedOf[URL(fileURLWithPath: path).standardizedFileURL.path] = index }
        }
        var linkedItems: [[CloudUsageInputs.Item]] = Array(repeating: [], count: bundles.count)
        for (count, record) in OffloadedFileRegistry.live(stateDir: stateDir).enumerated() {
            let suffix = "." + FilePlaceholder.fileExtension
            let origin = record.placeholderPath.hasSuffix(suffix) ? String(record.placeholderPath.dropLast(suffix.count)) : record.placeholderPath
            var item = CloudUsageInputs.Item(id: record.id, name: record.name, bytes: record.size)
            item.originPath = origin
            item.stubPath = record.placeholderPath
            item.offloadedAt = record.createdAt
            item.restore = "fetch"
            item.restoreId = record.placeholderPath
            if readPlaceholders, count < placeholderReadLimit, let placeholder = try? FilePlaceholder.read(URL(fileURLWithPath: record.placeholderPath)) {
                item.storedBytes = placeholder.storedSize
                item.lastUsed = placeholder.modifiedAt
            }
            if let index = linkedOf[URL(fileURLWithPath: origin).standardizedFileURL.path] {
                linkedItems[index].append(item)
            } else {
                input.files.append(item)
            }
        }
        input.linked = bundles.enumerated().compactMap { index, bundle in
            linkedItems[index].isEmpty ? nil : .init(id: bundle.id, name: bundle.name, appPath: bundle.appPath, items: linkedItems[index])
        }
        let names = Dictionary(apps.map { ($0.bundleId, $0.item.name) }, uniquingKeysWith: { first, _ in first })
        let support = AppDataPaths.supportDir(home: engine.homeDirectory).path + "/"
        for (bundleId, record) in engine.appDataStore.load() where record.state == .offloaded && record.bytes > 0 {
            let name = names[bundleId] ?? bundleId
            var item = CloudUsageInputs.Item(id: "data:" + bundleId, name: name, bytes: record.bytes)
            item.originPath = record.roots.count == 1 ? support + record.roots[0] : nil
            item.offloadedAt = record.updatedAt
            item.restore = "data/disable"
            item.restoreId = name
            input.data.append(.init(item: item, bundleId: bundleId))
        }
        for entry in (try? SessionArchive.archivedEntries(config: engine.config)) ?? [] {
            var item = CloudUsageInputs.Item(id: "session:" + entry.id, name: URL(fileURLWithPath: entry.path).lastPathComponent, bytes: entry.size)
            item.originPath = entry.path
            item.lastUsed = entry.modified
            item.restore = "sessions/restore"
            item.restoreId = entry.id
            input.sessions.append(.init(item: item, tool: entry.tool))
        }
        return input
    }
}
