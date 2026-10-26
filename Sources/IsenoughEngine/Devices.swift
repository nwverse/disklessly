import Foundation
import IsenoughCore
#if canImport(Darwin)
import Darwin
#endif

public struct PublishRequest: Equatable {
    public var name: String
    public var identity: ImageIdentity
    public var mode: ImageManifest.Mode
    public var executable: String
    public var originalPath: String
    public var cdhash: String?
    public var postImageTreeHash: String?
    public var volumeName: String
    public var appPathInVolume: String
    public var documentTypes: [[String: AnyCodable]]
    public var urlTypes: [[String: AnyCodable]]

    public init(name: String, identity: ImageIdentity, mode: ImageManifest.Mode, executable: String, originalPath: String, cdhash: String? = nil, postImageTreeHash: String? = nil, volumeName: String, appPathInVolume: String, documentTypes: [[String: AnyCodable]] = [], urlTypes: [[String: AnyCodable]] = []) {
        self.name = name
        self.identity = identity
        self.mode = mode
        self.executable = executable
        self.originalPath = originalPath
        self.cdhash = cdhash
        self.postImageTreeHash = postImageTreeHash
        self.volumeName = volumeName
        self.appPathInVolume = appPathInVolume
        self.documentTypes = documentTypes
        self.urlTypes = urlTypes
    }
}

public struct PublishResult: Equatable {
    public var manifest: ImageManifest
    public var reused: Bool
    public var uploaded: Bool
    public var warnings: [String]
    public var evicted: [String]
    public init(manifest: ImageManifest, reused: Bool, uploaded: Bool, warnings: [String] = [], evicted: [String] = []) {
        self.manifest = manifest
        self.reused = reused
        self.uploaded = uploaded
        self.warnings = warnings
        self.evicted = evicted
    }
}

public struct MaintenanceReport: Equatable {
    public var journals: [String]
    public var trashed: [String]
    public var restored: [String]
    public var purged: [String]
    public var warnings: [String]
    public var kept: [String]
    public var evictedLocal: [String]
    public init(journals: [String], trashed: [String], restored: [String], purged: [String], warnings: [String], kept: [String], evictedLocal: [String] = []) {
        self.journals = journals
        self.trashed = trashed
        self.restored = restored
        self.purged = purged
        self.warnings = warnings
        self.kept = kept
        self.evictedLocal = evictedLocal
    }

    public var lines: [String] {
        journals + warnings + trashed.map { "trashed \($0)" } + restored.map { "restored \($0)" } + purged.map { "purged \($0)" } + evictedLocal.map { "evicted \($0)" }
    }
}

public struct DeviceListing: Equatable {
    public var devices: [DeviceRecord]
    public var placeholders: [String]
    public var conflicts: [String]
    public var localDeviceId: String
    public init(devices: [DeviceRecord], placeholders: [String], conflicts: [String], localDeviceId: String) {
        self.devices = devices
        self.placeholders = placeholders
        self.conflicts = conflicts
        self.localDeviceId = localDeviceId
    }
}

extension IsenoughEngine {
    func currentDeviceFacts() -> DeviceFacts {
        deviceFactsOverride ?? LiveDeviceFacts.current()
    }

    public func publish(_ request: PublishRequest, imageFile: URL?, now: Date = Date()) throws -> PublishResult {
        let backend = try repo
        // Snapshot legacy ids before this image exists, so a brand-new publish is not frozen as legacy.
        try ensureDevice(now: now)
        let manifests = try readManifests(backend)
        let decision = PublishPlanner.decide(identity: request.identity, manifests: manifests) { path in
            (try? WriteOnce.probe(backend, path)) ?? .absent
        }
        switch decision {
        case .reuse(let manifest):
            try register(manifest, backend: backend, now: now)
            try rewriteCatalog(backend, now: now)
            return PublishResult(manifest: manifest, reused: true, uploaded: false)
        case .refuse(let message):
            throw IsenoughError.integrity(message)
        case .create(let imageId):
            guard let imageFile else { throw IsenoughError.usage("publishing \(imageId) needs an image file") }
            let sha = try SHA256Digest.hexFile(imageFile)
            let size = try ChunkedIO.byteCount(imageFile)
            guard size > 0 else { throw IsenoughError.integrity("image file is empty") }
            let image = ImageManifest.Image(file: "images/\(imageId).dmg", format: "ULMO", sha256: sha, size: size, volumeName: request.volumeName, appPathInVolume: request.appPathInVolume)
            let app = ImageManifest.App(originalPath: request.originalPath, executable: request.executable, documentTypes: request.documentTypes, urlTypes: request.urlTypes, cdhash: request.cdhash, treeHash: request.postImageTreeHash ?? request.identity.treeHash)
            let manifest = ImageManifest(bundleId: request.identity.bundleId, name: request.name, version: request.identity.version, image: image, app: app, mode: request.mode, createdAt: now, build: request.identity.build, architectures: request.identity.architectures, contentTreeHash: request.identity.treeHash, imageId: imageId)
            try manifest.validate()
            try WriteOnce.putFile(backend: backend, path: manifest.image.file, file: imageFile, sha256: sha)
            try WriteOnce.put(backend: backend, path: "manifests/\(manifest.imageId).json", data: try manifest.encode())
            try register(manifest, backend: backend, now: now)
            try rewriteCatalog(backend, now: now)
            return PublishResult(manifest: manifest, reused: false, uploaded: true)
        }
    }

    public func deviceListing(createLocal: Bool = true, now: Date = Date()) throws -> DeviceListing {
        let backend = try repo
        if createLocal {
            try ensureDevice(now: now)
        }
        let facts = try loadDeviceFacts(backend)
        let local = try localIdentity(create: false, now: now, backend: backend)
        return DeviceListing(
            devices: facts.compactMap(\.record).sorted { $0.displayName < $1.displayName },
            placeholders: facts.filter(\.placeholder).map(\.name).sorted(),
            conflicts: facts.filter(\.conflictCopy).map(\.name).sorted(),
            localDeviceId: local?.deviceId ?? ""
        )
    }

    public func renameDevice(to name: String, now: Date = Date()) throws -> DeviceRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IsenoughError.usage("devices rename requires a name") }
        guard trimmed.count <= 80, !trimmed.contains("/") else { throw IsenoughError.usage("device name must be a single path-free label") }
        let backend = try repo
        try ensureRepoCollections(backend)
        var local = try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname)
        local.displayName = trimmed
        try LocalDeviceStore.save(local, stateDir: stateDirectory)
        let record = try upsertDevice(local: local, manifest: nil, backend: backend, now: now)
        return record
    }

    /// Deletes `devices/<id>.json`. Another Mac's file is removed only after confirmation.
    /// A placeholder that has not downloaded is left in place.
    public func forgetDevice(id: String, confirmed: Bool) throws {
        guard confirmed else { throw IsenoughError.usage("devices forget \(id) requires --yes") }
        guard DeviceIds.isSafe(id) else { throw IsenoughError.usage("device id is not a safe file name") }
        let backend = try repo
        let path = "devices/\(id).json"
        let facts = try loadDeviceFacts(backend)
        if facts.contains(where: { RepoFileNames.logicalName($0.name) == "\(id).json" && ($0.placeholder || $0.notDownloaded) && !$0.conflictCopy }) {
            throw IsenoughError.integrity("devices/\(id).json is not downloaded. Refusing to delete a placeholder.")
        }
        guard facts.contains(where: { $0.record?.deviceId == id && !$0.conflictCopy }) || ((try? backend.stat(path)) != nil) else {
            throw IsenoughError.usage("no device file for \(id)")
        }
        if facts.contains(where: { $0.name == "\(id).json" && ($0.placeholder || $0.notDownloaded) }) {
            throw IsenoughError.integrity("devices/\(id).json is not downloaded. Refusing to delete a placeholder.")
        }
        try backend.delete(path)
    }

    public func maintain(now: Date = Date(), includeLegacy: Bool = false) throws -> MaintenanceReport {
        restore.loadConfiguredFaults()
        let journals = try restore.recoverAll(shortLived: true)
        try ensureDevice(now: now)
        let remote = try remoteMaintenance(now: now, includeLegacy: includeLegacy)
        let eviction = evictLocalCopies(now: now)
        var warnings = remote.warnings
        warnings.append(contentsOf: eviction.retryLater)
        return MaintenanceReport(journals: journals, trashed: remote.trash, restored: remote.restoreFromTrash, purged: remote.purge, warnings: warnings, kept: remote.kept, evictedLocal: eviction.evicted)
    }

    public func syncReport(now: Date = Date()) -> SyncReport {
        guard let backend = try? repo else {
            return SyncReport(conflicts: [], placeholders: [], stale: [])
        }
        let folders = ["manifests", "devices", "images", "catalog", "trash"]
        var names: [String] = []
        for folder in folders {
            let entries = (try? backend.list(folder)) ?? []
            names.append(contentsOf: entries.map { "\(folder)/\($0)" })
        }
        let devices = (try? loadDeviceFacts(backend)) ?? []
        return RepoSync.inspect(names: names, devices: devices, now: now)
    }

    func assertDeviceLaunch(_ manifest: ImageManifest) throws {
        guard let record = try? ownDeviceRecord() else { return }
        if case .refused(let message) = StubLaunch.check(record: record, manifest: manifest) {
            throw IsenoughError.integrity(message)
        }
    }

    func ownDeviceRecord() throws -> DeviceRecord? {
        guard let local = LocalDeviceStore.load(stateDir: stateDirectory) else { return nil }
        let backend = try repo
        let facts = try loadDeviceFacts(backend)
        return facts.first { $0.record?.deviceId == local.deviceId && !$0.conflictCopy && !$0.placeholder }?.record
    }

    func repoImagePresences() -> [RepoImagePresence] {
        guard let backend = try? repo else { return [] }
        let manifests = (try? readManifests(backend)) ?? []
        let devices = (try? loadDeviceFacts(backend)) ?? []
        let localId = LocalDeviceStore.load(stateDir: stateDirectory)?.deviceId
        return manifests.map { manifest in
            let names = devices.compactMap { file -> String? in
                guard let record = file.record, !file.conflictCopy else { return nil }
                guard record.deviceId != localId else { return nil }
                guard record.images.contains(where: { $0.imageId == manifest.imageId || $0.bundleId == manifest.bundleId && $0.version == manifest.version && ImageIdentity.normalize($0.architectures) == ImageIdentity.normalize(manifest.architectures) }) else { return nil }
                return record.displayName.isEmpty ? record.hostname : record.displayName
            }
            return RepoImagePresence(bundleId: manifest.bundleId, version: manifest.version, build: manifest.build, architectures: manifest.architectures, imageId: manifest.imageId, devices: names)
        }
    }

    private var stateDirectory: URL { URL(fileURLWithPath: config.stateDir, isDirectory: true) }

    private func localIdentity(create: Bool, now: Date, backend: any StorageBackend) throws -> LocalDevice? {
        if let existing = LocalDeviceStore.load(stateDir: stateDirectory) { return existing }
        guard create else { return nil }
        let created = try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname)
        _ = try upsertDevice(local: created, manifest: nil, backend: backend, now: now)
        return created
    }

    func register(_ manifest: ImageManifest, backend: any StorageBackend, now: Date) throws {
        let local = try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname)
        _ = try upsertDevice(local: local, manifest: manifest, backend: backend, now: now)
        try rememberLocal(manifest)
    }

    /// Creates this Mac's device file, fills gaps from local stubs, then freezes
    /// still-unreferenced images as legacy. Later runs do not recompute that set.
    func ensureDevice(now: Date = Date()) throws {
        let backend = try repo
        try ensureRepoCollections(backend)
        let local = try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname)
        let claims = stubClaims(backend: backend, now: now)
        _ = try upsertDevice(local: local, manifest: nil, claims: claims, backend: backend, now: now)
        try snapshotLegacyIfAbsent(backend)
    }

    /// Writes only `devices/<this Mac's id>.json`.
    /// Stub claims fill bundle ids this file does not already name. A pack that
    /// already recorded the bundle is left in place.
    private func upsertDevice(local: LocalDevice, manifest: ImageManifest?, claims: [DeviceImageRef] = [], backend: any StorageBackend, now: Date) throws -> DeviceRecord {
        guard local.deviceId == LocalDeviceStore.load(stateDir: stateDirectory)?.deviceId else {
            throw IsenoughError.integrity("refusing to write a device file for another Mac")
        }
        let facts = currentDeviceFacts()
        var images = (try ownDeviceRecord())?.images ?? []
        for claim in claims where !images.contains(where: { $0.bundleId == claim.bundleId }) {
            images.append(claim)
        }
        if let manifest {
            let reference = DeviceImageRef(imageId: manifest.imageId, bundleId: manifest.bundleId, version: manifest.version, build: manifest.build, architectures: manifest.architectures, mode: manifest.mode.rawValue, packedAt: now)
            images.removeAll { $0.bundleId == manifest.bundleId }
            images.append(reference)
        }
        let record = DeviceRecord(deviceId: local.deviceId, hostname: facts.hostname, displayName: local.displayName, arch: facts.arch, osVersion: facts.osVersion, lastSeen: now, images: images.sorted { $0.imageId < $1.imageId })
        let data = try record.encode()
        let relative = "devices/\(local.deviceId).json"
        if let root = backend.localRoot() {
            try AtomicFile.write(data, to: root.appendingPathComponent(relative))
        } else {
            try backend.put(relative, data: data)
        }
        return record
    }

    private func rememberLocal(_ manifest: ImageManifest) throws {
        var state = StateStore(config.stateDir).read()
        var apps = state["apps"] as? [String: [String: Any]] ?? [:]
        var item = apps[manifest.bundleId] ?? [:]
        let pinned = item["pinned"] as? Bool ?? false
        item["imageId"] = manifest.imageId
        item["mode"] = manifest.mode.rawValue
        item["pinned"] = pinned
        apps[manifest.bundleId] = item
        state["apps"] = apps
        if state["schema"] == nil { state["schema"] = "state/1" }
        try StateStore(config.stateDir).write(state)
    }

    private func ensureRepoCollections(_ backend: any StorageBackend) throws {
        for name in ["images", "manifests", "catalog", "devices", "trash"] {
            try? backend.ensureCollection(name)
        }
    }

    func readManifests(_ backend: any StorageBackend) throws -> [ImageManifest] {
        let names = (try? backend.list("manifests")) ?? []
        var manifests: [ImageManifest] = []
        for name in names where name.hasSuffix(".json") && !RepoFileNames.isConflictCopy(name) && !RepoFileNames.isPlaceholder(name) {
            let data = try backend.get("manifests/\(name)", range: nil)
            if let manifest = try? ImageManifest.decode(data) { manifests.append(manifest) }
        }
        return manifests
    }

    private func loadDeviceFacts(_ backend: any StorageBackend) throws -> [DeviceFileFact] {
        let names = (try? backend.list("devices")) ?? []
        var facts: [DeviceFileFact] = []
        for name in names {
            let placeholder = RepoFileNames.isPlaceholder(name)
            let conflict = RepoFileNames.isConflictCopy(name)
            if placeholder {
                facts.append(DeviceFileFact(name: name, placeholder: true, conflictCopy: conflict, notDownloaded: true, record: nil))
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            do {
                let data = try backend.get("devices/\(name)", range: nil)
                let record = try DeviceRecord.decode(data)
                facts.append(DeviceFileFact(name: name, placeholder: false, conflictCopy: conflict, notDownloaded: false, record: record))
            } catch {
                facts.append(DeviceFileFact(name: name, placeholder: false, conflictCopy: conflict, notDownloaded: true, record: nil))
            }
        }
        return facts
    }

    private func rewriteCatalog(_ backend: any StorageBackend, now: Date) throws {
        let manifests = try readManifests(backend)
        let deviceId = LocalDeviceStore.load(stateDir: stateDirectory)?.deviceId ?? ""
        let data = try CatalogIndex.encode(manifests: manifests, deviceId: deviceId, now: now)
        try backend.put("catalog/manifest.json", data: data)
    }

    private func remoteMaintenance(now: Date, includeLegacy: Bool) throws -> GCPlan {
        let backend = try repo
        try ensureRepoCollections(backend)
        if LocalDeviceStore.load(stateDir: stateDirectory) != nil {
            _ = try upsertDevice(local: try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname), manifest: nil, backend: backend, now: now)
        }
        let devices = try loadDeviceFacts(backend)
        let census = try imageCensus(backend)
        let trash = try trashFacts(backend)
        let legacy = try loadLegacyIds(backend)
        let plan = RepoGarbage.plan(liveImageIds: census.ids, trash: trash, devices: devices, now: now, legacyImageIds: legacy, includeLegacy: includeLegacy)
        for imageId in plan.restoreFromTrash {
            try restoreTrashed(imageId, backend: backend)
        }
        for imageId in plan.trash where !census.placeholders.contains(imageId) {
            try moveToTrash(imageId, backend: backend, now: now)
        }
        for imageId in plan.purge {
            try purgeTrash(imageId, backend: backend)
        }
        let trashed = plan.trash.filter { !census.placeholders.contains($0) }
        if includeLegacy {
            let gone = Set(trashed).union(plan.purge)
            if !gone.isEmpty {
                try storeLegacy(legacy.subtracting(gone), backend)
            }
        }
        var warnings = plan.warnings
        for imageId in census.placeholders where plan.trash.contains(imageId) {
            warnings.append("\(imageId) is an iCloud placeholder, so it was not deleted.")
        }
        return GCPlan(trash: trashed, restoreFromTrash: plan.restoreFromTrash, purge: plan.purge, warnings: warnings, kept: plan.kept + census.placeholders.filter { plan.trash.contains($0) }.sorted())
    }

    private func stubSearchRoots() -> [URL] {
        if let stubRootsOverride { return stubRootsOverride }
        return BackupScanner.defaultRoots(stubDir: config.stubDir, home: NSHomeDirectory())
    }

    /// Stubs in the Applications folders, plus journals whose destination is a stub on this Mac.
    private func stubClaims(backend: any StorageBackend, now: Date) -> [DeviceImageRef] {
        let manifests = (try? readManifests(backend)) ?? []
        let byId = Dictionary(manifests.map { ($0.imageId, $0) }, uniquingKeysWith: { current, _ in current })
        var claims: [DeviceImageRef] = []
        var seen = Set<String>()
        for root in stubSearchRoots() {
            for app in RecommendPaths.topLevelApps(in: root) {
                guard let claim = stubClaim(app: app, manifests: byId, now: now) else { continue }
                if seen.insert(claim.bundleId).inserted { claims.append(claim) }
            }
        }
        let journals = (try? JournalStore.loadAll(stateDir: config.stateDir)) ?? []
        for journal in journals {
            guard !journal.dest.isEmpty else { continue }
            let dest = URL(fileURLWithPath: journal.dest)
            guard FileManager.default.fileExists(atPath: dest.appendingPathComponent("Contents/Resources/stub.json").path) else { continue }
            let claim = stubClaim(app: dest, manifests: byId, now: journal.createdAt)
                ?? byId[journal.imageId].map(deviceRef)
            guard let claim, seen.insert(claim.bundleId).inserted else { continue }
            claims.append(claim)
        }
        return claims
    }

    private func stubClaim(app: URL, manifests: [String: ImageManifest], now: Date) -> DeviceImageRef? {
        let resources = app.appendingPathComponent("Contents/Resources")
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("stub.json"), options: []),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let embedded: ImageManifest?
        if let bytes = try? Data(contentsOf: resources.appendingPathComponent("manifest.json"), options: []),
           let manifest = try? ImageManifest.decode(bytes) {
            embedded = manifest
        } else {
            embedded = nil
        }
        let stated = object["imageId"] as? String
        let resolvedId = (stated?.isEmpty == false ? stated : nil) ?? embedded?.imageId
        guard let resolvedId, !resolvedId.isEmpty else { return nil }
        if let manifest = embedded, manifest.imageId == resolvedId { return deviceRef(manifest) }
        if let manifest = manifests[resolvedId] { return deviceRef(manifest) }
        let appId = object["appId"] as? String
        let bundleId = (appId?.isEmpty == false ? appId : nil) ?? embedded?.bundleId ?? ""
        guard !bundleId.isEmpty else { return nil }
        return DeviceImageRef(imageId: resolvedId, bundleId: bundleId, version: embedded?.version ?? "", build: embedded?.build ?? "", architectures: embedded?.architectures ?? [], mode: embedded?.mode.rawValue ?? "mount", packedAt: embedded?.createdAt ?? now)
    }

    private func deviceRef(_ manifest: ImageManifest) -> DeviceImageRef {
        DeviceImageRef(imageId: manifest.imageId, bundleId: manifest.bundleId, version: manifest.version, build: manifest.build, architectures: manifest.architectures, mode: manifest.mode.rawValue, packedAt: manifest.createdAt)
    }

    private func snapshotLegacyIfAbsent(_ backend: any StorageBackend) throws {
        if try backend.stat(LegacyImages.path) != nil { return }
        let census = try imageCensus(backend)
        let devices = try loadDeviceFacts(backend)
        var referenced = Set<String>()
        for file in devices {
            guard let record = file.record else { continue }
            referenced.formUnion(record.images.map(\.imageId))
        }
        let legacy = census.ids.filter { !referenced.contains($0) }.sorted()
        try storeLegacy(Set(legacy), backend)
    }

    private func loadLegacyIds(_ backend: any StorageBackend) throws -> Set<String> {
        guard try backend.stat(LegacyImages.path) != nil else { return [] }
        let data = try backend.get(LegacyImages.path, range: nil)
        if let ids = LegacyImages.decode(data) { return Set(ids) }
        return Set(try imageCensus(backend).ids)
    }

    private func storeLegacy(_ ids: Set<String>, _ backend: any StorageBackend) throws {
        try backend.put(LegacyImages.path, data: try LegacyImages.encode(ids.sorted()))
    }

    private func imageCensus(_ backend: any StorageBackend) throws -> (ids: [String], placeholders: Set<String>) {
        let names = (try? backend.list("images")) ?? []
        var ids: [String] = []
        var placeholders = Set<String>()
        for name in names {
            let logical = RepoFileNames.logicalName(name)
            guard logical.hasSuffix(".dmg"), !RepoFileNames.isConflictCopy(name) else { continue }
            let id = (logical as NSString).deletingPathExtension
            guard !id.isEmpty else { continue }
            if !ids.contains(id) { ids.append(id) }
            if RepoFileNames.isPlaceholder(name) { placeholders.insert(id) }
        }
        return (ids, placeholders)
    }

    private static func parseStamp(_ stamp: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: stamp) { return date }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: stamp)
    }

    private func trashFacts(_ backend: any StorageBackend) throws -> [TrashFact] {
        let names = (try? backend.list("trash/meta")) ?? []
        var facts: [TrashFact] = []
        for name in names where name.hasSuffix(".json") && !RepoFileNames.isConflictCopy(name) && !RepoFileNames.isPlaceholder(name) {
            guard let data = try? backend.get("trash/meta/\(name)", range: nil),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let imageId = object["imageId"] as? String,
                  let stamp = object["trashedAt"] as? String,
                  let date = Self.parseStamp(stamp) else { continue }
            facts.append(TrashFact(imageId: imageId, trashedAt: date))
        }
        return facts
    }

    private func moveToTrash(_ imageId: String, backend: any StorageBackend, now: Date) throws {
        try moveRepo("images/\(imageId).dmg", to: "trash/images/\(imageId).dmg", backend: backend)
        try moveRepo("manifests/\(imageId).json", to: "trash/manifests/\(imageId).json", backend: backend)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let meta: [String: Any] = ["schema": "trash/1", "imageId": imageId, "trashedAt": formatter.string(from: now)]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try backend.put("trash/meta/\(imageId).json", data: data)
    }

    private func restoreTrashed(_ imageId: String, backend: any StorageBackend) throws {
        try moveRepo("trash/images/\(imageId).dmg", to: "images/\(imageId).dmg", backend: backend)
        try moveRepo("trash/manifests/\(imageId).json", to: "manifests/\(imageId).json", backend: backend)
        try? backend.delete("trash/meta/\(imageId).json")
    }

    private func purgeTrash(_ imageId: String, backend: any StorageBackend) throws {
        try? backend.delete("trash/images/\(imageId).dmg")
        try? backend.delete("trash/manifests/\(imageId).json")
        try? backend.delete("trash/meta/\(imageId).json")
    }

    private func moveRepo(_ from: String, to: String, backend: any StorageBackend) throws {
        guard try backend.stat(from) != nil else { return }
        if try backend.stat(to) != nil {
            let fromSHA = try WriteOnce.probe(backend, from)
            let toSHA = try WriteOnce.probe(backend, to)
            if fromSHA == toSHA {
                try? backend.delete(from)
                return
            }
            throw IsenoughError.integrity("refusing to overwrite \(to) while moving \(from)")
        }
        if let root = backend.localRoot() {
            let source = root.appendingPathComponent(from)
            let destination = root.appendingPathComponent(to)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }
        let data = try backend.get(from, range: nil)
        try backend.put(to, data: data)
        try backend.delete(from)
    }
}

enum LiveDeviceFacts {
    static func current() -> DeviceFacts {
        #if os(macOS)
        var system = utsname()
        uname(&system)
        let host = text(system.nodename)
        let machine = text(system.machine)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return DeviceFacts(hostname: host.isEmpty ? "mac" : host, arch: machine.isEmpty ? "unknown" : machine, osVersion: os)
        #else
        return DeviceFacts(hostname: ProcessInfo.processInfo.hostName, arch: "unknown", osVersion: "")
        #endif
    }

    #if os(macOS)
    /// `utsname` fields are fixed C-string tuples. Read them as bytes so the
    /// conversion does not depend on the tuple's exact arity.
    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes.prefix(end), as: UTF8.self)
        }
    }
    #endif
}
