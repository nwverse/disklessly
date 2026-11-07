import Foundation
import DisklesslyCore
import DisklesslyStubSupport
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
    public var imageFormat: String
    /// Seal the image with the current image key before upload (`ImageCrypto`).
    public var encrypt: Bool

    public init(name: String, identity: ImageIdentity, mode: ImageManifest.Mode, executable: String, originalPath: String, cdhash: String? = nil, postImageTreeHash: String? = nil, volumeName: String, appPathInVolume: String, documentTypes: [[String: AnyCodable]] = [], urlTypes: [[String: AnyCodable]] = [], imageFormat: String = "ULMO", encrypt: Bool = false) {
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
        self.imageFormat = imageFormat
        self.encrypt = encrypt
    }
}

public struct PublishResult: Equatable {
    public var manifest: ImageManifest
    public var reused: Bool
    public var uploaded: Bool
    public var warnings: [String]
    public var evicted: [String]
    /// Set when the original app must stay because the cloud copy is not confirmed.
    public var originalKept: String?
    public init(manifest: ImageManifest, reused: Bool, uploaded: Bool, warnings: [String] = [], evicted: [String] = [], originalKept: String? = nil) {
        self.manifest = manifest
        self.reused = reused
        self.uploaded = uploaded
        self.warnings = warnings
        self.evicted = evicted
        self.originalKept = originalKept
    }
}

public struct GCDryRunReport: Equatable {
    public var trash: [String]
    public var restoreFromTrash: [String]
    public var purge: [String]
    public var legacy: [String]
    public var warnings: [String]
    public var lru: [String]
    public var lruFreed: UInt64
    public var lruShortBy: UInt64

    public init(trash: [String], restoreFromTrash: [String], purge: [String], legacy: [String], warnings: [String], lru: [String], lruFreed: UInt64, lruShortBy: UInt64) {
        self.trash = trash
        self.restoreFromTrash = restoreFromTrash
        self.purge = purge
        self.legacy = legacy
        self.warnings = warnings
        self.lru = lru
        self.lruFreed = lruFreed
        self.lruShortBy = lruShortBy
    }

    public func text() -> String {
        var lines: [String] = []
        if trash.isEmpty { lines.append("trash candidates  (none)") }
        else { lines.append(contentsOf: trash.map { "trash candidate  \($0)" }) }
        if legacy.isEmpty { lines.append("legacy  (none)") }
        else { lines.append(contentsOf: legacy.map { "legacy  \($0)" }) }
        if lru.isEmpty { lines.append("lru  (none)") }
        else { lines.append(contentsOf: lru.map { "lru  \($0)" }) }
        lines.append(contentsOf: restoreFromTrash.map { "restore  \($0)" })
        lines.append(contentsOf: purge.map { "purge  \($0)" })
        if lruShortBy > 0 { lines.append("lru short by  \(lruShortBy)") }
        lines.append(contentsOf: warnings.map { "warning  \($0)" })
        return lines.joined(separator: "\n") + "\n"
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

extension DisklesslyEngine {
    func currentDeviceFacts() -> DeviceFacts {
        deviceFactsOverride ?? LiveDeviceFacts.current()
    }

    /// Evidence for one repo object. Dataless iCloud files are not hashed.
    /// A failure here is reported as `.unreadable`; it does not throw.
    func imageEvidence(_ backend: any StorageBackend, _ path: String, expectedSize: UInt64?) -> ImageEvidence {
        if let imageEvidenceOverride { return imageEvidenceOverride(path) }
        #if os(macOS)
        if let root = backend.localRoot() {
            let url = root.appendingPathComponent(path)
            if let cloud = Self.ubiquitousEvidence(url, expectedSize: expectedSize) {
                return cloud
            }
        }
        #endif
        do {
            switch try WriteOnce.probe(backend, path) {
            case .absent:
                return .absent
            case .placeholder:
                return .placeholder(cloudConfirmed: false)
            case .sha256(let sha):
                return .local(sha256: sha, uploaded: nil)
            }
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    #if os(macOS)
    /// Nil means the file is not an iCloud item, so the caller should hash it normally.
    private static func ubiquitousEvidence(_ url: URL, expectedSize: UInt64?) -> ImageEvidence? {
        let folder = url.deletingLastPathComponent()
        let hidden = folder.appendingPathComponent("." + url.lastPathComponent + ".icloud")
        let visible = folder.appendingPathComponent(url.lastPathComponent + ".icloud")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) && (fm.fileExists(atPath: hidden.path) || fm.fileExists(atPath: visible.path)) {
            return .placeholder(cloudConfirmed: false)
        }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .fileSizeKey]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            if fm.fileExists(atPath: url.path) { return .unreadable(error.localizedDescription) }
            return nil
        }
        guard values.isUbiquitousItem == true else { return nil }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            let size = values.fileSize.map { UInt64(max(0, $0)) }
            let confirmed = size != nil && expectedSize != nil && size == expectedSize
            return .placeholder(cloudConfirmed: confirmed)
        }
        do {
            let sha = try SHA256Digest.hexFile(url)
            return .local(sha256: sha, uploaded: uploadedFlag(values))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    private static func uploadedFlag(_ values: URLResourceValues) -> Bool? {
        guard let raw = values.allValues[.ubiquitousItemIsUploadedKey] else { return nil }
        if raw is NSNull { return nil }
        if let number = raw as? NSNumber { return number.boolValue }
        if let flag = raw as? Bool { return flag }
        return nil
    }
    #endif

    public func publish(_ request: PublishRequest, imageFile: URL?, now: Date = Date()) throws -> PublishResult {
        let backend = try repo
        // Lists must succeed before any put. A failed manifest listing writes nothing.
        try ensureRepoCollections(backend)
        let manifests = try readManifests(backend)
        let decision = PublishPlanner.decide(identity: request.identity, manifests: manifests, evidence: { path in
            self.imageEvidence(backend, path, expectedSize: manifests.first { $0.image.file == path }?.image.size)
        }, inTrash: { id in
            (try? backend.stat("trash/images/\(id).dmg")) != nil
        })
        if case .refuse(let message, let code) = decision {
            if code == 4 { throw DisklesslyError.backend(message) }
            throw DisklesslyError.integrity(message)
        }
        // Snapshot legacy ids before this image exists, so a brand-new publish is not frozen as legacy.
        try ensureDevice(now: now)
        switch decision {
        case .reuse(let manifest, let disposition):
            try requireImageKey(manifest)
            try register(manifest, backend: backend, now: now, installPath: request.originalPath)
            try rewriteCatalog(backend, now: now)
            let kept: String?
            if case .keep(let reason) = disposition { kept = reason } else { kept = nil }
            return PublishResult(manifest: manifest, reused: true, uploaded: false, originalKept: kept)
        case .refuse(let message, let code):
            if code == 4 { throw DisklesslyError.backend(message) }
            throw DisklesslyError.integrity(message)
        case .create(let imageId):
            guard let plainFile = imageFile else { throw DisklesslyError.usage("publishing \(imageId) needs an image file") }
            guard try ChunkedIO.byteCount(plainFile) > 0 else { throw DisklesslyError.integrity("image file is empty") }
            // An encrypted image is sealed next to the plain one; the repo, the
            // manifest's sha256/size and the write-once checks all see ciphertext.
            var imageFile = plainFile
            var encryption: ImageManifest.Encryption?
            var staged: URL?
            defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
            let sha: String, size: UInt64
            if request.encrypt {
                guard let current = try ImageKeyStore.current(secrets: secrets) else {
                    throw DisklesslyError.usage("image encryption is on but this Mac has no image key; run disklessly images key init")
                }
                imageFile = plainFile.appendingPathExtension("dkli")
                staged = imageFile
                let sealed = try ImageCrypto.seal(plainFile, to: imageFile, key: current.key)
                encryption = ImageManifest.Encryption(scheme: ImageCrypto.scheme, keyId: current.id, plainSha256: sealed.plainSha256, plainSize: sealed.plainSize)
                sha = sealed.sha256
                size = sealed.size
            } else {
                sha = try SHA256Digest.hexFile(plainFile)
                size = try ChunkedIO.byteCount(plainFile)
            }
            let image = ImageManifest.Image(file: "images/\(imageId).dmg", format: request.imageFormat, sha256: sha, size: size, volumeName: request.volumeName, appPathInVolume: request.appPathInVolume, encryption: encryption)
            let app = ImageManifest.App(originalPath: request.originalPath, executable: request.executable, documentTypes: request.documentTypes, urlTypes: request.urlTypes, cdhash: request.cdhash, treeHash: request.postImageTreeHash ?? request.identity.treeHash)
            var manifest = ImageManifest(bundleId: request.identity.bundleId, name: request.name, version: request.identity.version, image: image, app: app, mode: request.mode, createdAt: now, build: request.identity.build, architectures: request.identity.architectures, contentTreeHash: request.identity.treeHash, imageId: imageId)
            try manifest.validate()
            // Exclusive publish: a Mac that loses the race for the image path never
            // writes a manifest, so the stub it would install is never created.
            let imageResult = try WriteOnce.publishFile(backend: backend, path: manifest.image.file, file: imageFile, sha256: sha)
            if case .conflict(let message) = imageResult {
                throw DisklesslyError.integrity("\(message). The original app was not changed; retry the pack to reuse the published image.")
            }
            let manifestPath = "manifests/\(manifest.imageId).json"
            switch try WriteOnce.publish(backend: backend, path: manifestPath, data: try manifest.encode()) {
            case .written, .reused:
                break
            case .conflict(let message):
                // Another Mac wrote the manifest for the same image bytes (its
                // createdAt or originalPath differ). Adopt it when it names our sha.
                guard let existing = try? ImageManifest.decode(backend.get(manifestPath, range: nil)),
                      existing.imageId == manifest.imageId,
                      existing.image.sha256 == sha,
                      existing.image.file == manifest.image.file else {
                    throw DisklesslyError.integrity("\(message). The original app was not changed.")
                }
                manifest = existing
            }
            try WriteOnce.confirmCanonical(backend: backend, imageId: manifest.imageId, imageSha: sha)
            try register(manifest, backend: backend, now: now, installPath: request.originalPath)
            try rewriteCatalog(backend, now: now)
            return PublishResult(manifest: manifest, reused: imageResult == .reused, uploaded: imageResult == .written)
        }
    }

    /// Refuses to adopt an encrypted image this Mac cannot open, so the caller
    /// keeps the original app instead of swapping in a stub that cannot launch.
    func requireImageKey(_ manifest: ImageManifest) throws {
        guard let encryption = manifest.image.encryption else { return }
        guard try ImageKeyStore.load(secrets: secrets, keyId: encryption.keyId) == nil else { return }
        throw DisklesslyError.integrity("image \(manifest.imageId) is encrypted with image key \(encryption.keyId), which this Mac's Keychain does not have. The original app was not changed. Turn on iCloud Keychain on both Macs or run disklessly images key import.")
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
        guard !trimmed.isEmpty else { throw DisklesslyError.usage("devices rename requires a name") }
        guard trimmed.count <= 80, !trimmed.contains("/") else { throw DisklesslyError.usage("device name must be a single path-free label") }
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
        guard confirmed else { throw DisklesslyError.usage("devices forget \(id) requires --yes") }
        guard DeviceIds.isSafe(id) else { throw DisklesslyError.usage("device id is not a safe file name") }
        let backend = try repo
        let path = "devices/\(id).json"
        let facts = try loadDeviceFacts(backend)
        if facts.contains(where: { RepoFileNames.logicalName($0.name) == "\(id).json" && ($0.placeholder || $0.notDownloaded) && !$0.conflictCopy }) {
            throw DisklesslyError.integrity("devices/\(id).json is not downloaded. Refusing to delete a placeholder.")
        }
        guard facts.contains(where: { $0.record?.deviceId == id && !$0.conflictCopy }) || ((try? backend.stat(path)) != nil) else {
            throw DisklesslyError.usage("no device file for \(id)")
        }
        if facts.contains(where: { $0.name == "\(id).json" && ($0.placeholder || $0.notDownloaded) }) {
            throw DisklesslyError.integrity("devices/\(id).json is not downloaded. Refusing to delete a placeholder.")
        }
        try backend.delete(path)
        if LocalDeviceStore.load(stateDir: stateDirectory)?.deviceId == id {
            try? FileManager.default.removeItem(at: deviceMirrorURL)
        }
    }

    /// Trash candidates, legacy ids, and cache LRU victims. Reads the repo and the cache and changes neither.
    public func gcDryRun(now: Date = Date(), includeLegacy: Bool = false) throws -> GCDryRunReport {
        let backend = try repo
        let devices = try loadDeviceFacts(backend)
        let census = try imageCensus(backend)
        let trash = try trashFacts(backend)
        let legacy = try loadLegacyIds(backend)
        let selfId = LocalDeviceStore.load(stateDir: stateDirectory)?.deviceId
        var plan = RepoGarbage.plan(liveImageIds: census.ids, trash: trash, devices: devices, now: now, legacyImageIds: legacy, includeLegacy: includeLegacy, selfDeviceId: selfId)
        try keepMismatchedStubImages(&plan, backend: backend)
        let scan = scanCache(justUsed: nil, now: now)
        let eviction = CachePlanner.planEviction(scan.items, leftovers: scan.leftovers, quota: config.quotaBytes, now: now)
        let trashed = plan.trash.filter { !census.placeholders.contains($0) }
        return GCDryRunReport(trash: trashed, restoreFromTrash: plan.restoreFromTrash, purge: plan.purge, legacy: legacy.sorted(), warnings: plan.warnings, lru: eviction.victims, lruFreed: eviction.freed, lruShortBy: eviction.shortBy)
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
        UbiquitousMaterializer.withBudget(ICloudLimits.metadataTimeout()) {
            self.syncReportUnbudgeted(now: now)
        }
    }

    private func syncReportUnbudgeted(now: Date) -> SyncReport {
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
            throw DisklesslyError.integrity(message)
        }
    }

    func ownDeviceRecord() throws -> DeviceRecord? {
        guard let local = LocalDeviceStore.load(stateDir: stateDirectory) else { return nil }
        let backend = try repo
        let facts = try loadDeviceFacts(backend)
        let fileName = "\(local.deviceId).json"
        guard let fact = facts.first(where: { RepoFileNames.logicalName($0.name) == fileName && !$0.conflictCopy }) else {
            return nil
        }
        if fact.placeholder || fact.notDownloaded || fact.record == nil {
            throw DisklesslyError.backend("cannot read devices/\(local.deviceId).json in the repo; nothing was changed: file is not a readable device record")
        }
        return fact.record
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

    /// Records `manifest` for this Mac. `installPath` is where the stub goes; it
    /// defaults to the manifest's original path. Only a ref with the same image id,
    /// or the same bundle id at the same install path, is replaced.
    func register(_ manifest: ImageManifest, backend: any StorageBackend, now: Date, installPath: String? = nil) throws {
        let local = try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname)
        let path = installPath ?? manifest.app.originalPath
        _ = try upsertDevice(local: local, manifest: manifest, installPath: path.isEmpty ? nil : path, backend: backend, now: now)
        try rememberLocal(manifest)
    }

    /// Drops one image from this Mac's device file. Only `unpack` calls this.
    ///
    /// Pass `imageId` (and `installPath` when known) so only that ref goes. With
    /// only a bundle id, every ref for the bundle is a candidate, but any image
    /// still claimed by a stub on disk (another installed copy) is kept.
    func unregister(bundleId: String, imageId: String? = nil, installPath: String? = nil, now: Date = Date()) throws {
        let backend = try repo
        let local = try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname)
        let target = Unregister(bundleId: bundleId, imageId: imageId?.isEmpty == false ? imageId : nil, installPath: installPath?.isEmpty == false ? installPath : nil)
        let claims = try stubClaims(backend: backend, now: now)
        _ = try upsertDevice(local: local, manifest: nil, claims: claims, unregister: target, backend: backend, now: now)
    }

    private struct Unregister {
        var bundleId: String
        var imageId: String?
        var installPath: String?

        func matches(_ ref: DeviceImageRef) -> Bool {
            if let imageId { return ref.imageId == imageId }
            guard ref.bundleId == bundleId else { return false }
            if let installPath, let recorded = ref.installPath {
                return Self.samePath(recorded, installPath)
            }
            return true
        }

        static func samePath(_ a: String, _ b: String) -> Bool {
            URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
        }
    }

    /// Creates this Mac's device file, fills gaps from local stubs, then freezes
    /// still-unreferenced images as legacy. Later runs do not recompute that set.
    func ensureDevice(now: Date = Date()) throws {
        let backend = try repo
        try ensureRepoCollections(backend)
        let local = try LocalDeviceStore.loadOrCreate(stateDir: stateDirectory, suggestedName: currentDeviceFacts().hostname)
        let manifests = try readManifests(backend)
        let scope = try stubScope(backend, manifests: manifests)
        let claims = stubClaims(manifests: manifests, scope: scope, now: now)
        _ = try upsertDevice(local: local, manifest: nil, claims: claims, expel: { self.isForeignStubRef($0, scope: scope) }, backend: backend, now: now)
        try snapshotLegacyIfAbsent(backend)
    }

    /// Writes only `devices/<this Mac's id>.json`. Refs are keyed by image id.
    /// Stub claims found on disk are always unioned in (de-duplicated by image id),
    /// so an installed stub's image stays referenced even when another copy of
    /// the same bundle id was packed later.
    /// The image set may shrink only when `manifest` replaces the ref with the same
    /// image id or the same bundle id at the same install path, or `unregister`
    /// drops one ref. Every other write must be a superset.
    private func upsertDevice(local: LocalDevice, manifest: ImageManifest?, installPath: String? = nil, claims: [DeviceImageRef] = [], unregister: Unregister? = nil, expel: ((DeviceImageRef) -> Bool)? = nil, backend: any StorageBackend, now: Date) throws -> DeviceRecord {
        guard local.deviceId == LocalDeviceStore.load(stateDir: stateDirectory)?.deviceId else {
            throw DisklesslyError.integrity("refusing to write a device file for another Mac")
        }
        let facts = currentDeviceFacts()
        let remote = try ownDeviceRecord()
        let mirror = loadDeviceMirror()
        var images = mergeDeviceImages(remote?.images ?? [], mirror?.images ?? [])
        var previousIds = Set(images.map(\.mergeKey))
        if let expel {
            // Another repo's stub claims, written by an older engine. Dropping
            // them is the one shrink a plain refresh may make.
            let expelled = Set(images.filter(expel).map(\.mergeKey))
            images.removeAll { expelled.contains($0.mergeKey) }
            previousIds.subtract(expelled)
        }
        if let manifest {
            let reference = DeviceImageRef(imageId: manifest.imageId, bundleId: manifest.bundleId, version: manifest.version, build: manifest.build, architectures: manifest.architectures, mode: manifest.mode.rawValue, packedAt: now, installPath: installPath)
            images.removeAll { ref in
                if ref.imageId == manifest.imageId { return true }
                guard ref.bundleId == manifest.bundleId else { return false }
                // A legacy ref without an image id was keyed by bundle id; the new pack supersedes it.
                if ref.imageId.isEmpty { return true }
                guard let installPath, let recorded = ref.installPath else { return false }
                return Unregister.samePath(recorded, installPath)
            }
            images.append(reference)
        }
        if let unregister {
            images.removeAll { unregister.matches($0) }
        }
        for claim in claims {
            if let index = images.firstIndex(where: { $0.mergeKey == claim.mergeKey }) {
                if images[index].installPath == nil, let path = claim.installPath {
                    images[index].installPath = path
                }
            } else {
                images.append(claim)
            }
        }
        let explicitShrink = manifest != nil || unregister != nil
        if !explicitShrink && !previousIds.isSubset(of: Set(images.map(\.mergeKey))) {
            throw DisklesslyError.integrity("device record would shrink")
        }
        let generation = max(remote?.generation ?? 0, mirror?.generation ?? 0) + 1
        let record = DeviceRecord(deviceId: local.deviceId, hostname: facts.hostname, displayName: local.displayName, arch: facts.arch, osVersion: facts.osVersion, lastSeen: now, images: images.sorted { ($0.imageId, $0.bundleId) < ($1.imageId, $1.bundleId) }, generation: generation, writer: EngineInstall.version)
        let data = try record.encode()
        let relative = "devices/\(local.deviceId).json"
        if let root = backend.localRoot() {
            try AtomicFile.write(data, to: root.appendingPathComponent(relative))
        } else {
            try backend.put(relative, data: data)
        }
        try AtomicFile.write(data, to: deviceMirrorURL)
        return record
    }

    private var deviceMirrorURL: URL { stateDirectory.appendingPathComponent("device-record.json") }

    private func loadDeviceMirror() -> DeviceRecord? {
        guard let data = try? Data(contentsOf: deviceMirrorURL) else { return nil }
        return try? DeviceRecord.decode(data)
    }

    /// Union by image id. The remote copy wins when both sides name the same id.
    private func mergeDeviceImages(_ remote: [DeviceImageRef], _ mirror: [DeviceImageRef]) -> [DeviceImageRef] {
        var byId: [String: DeviceImageRef] = [:]
        for image in mirror { byId[image.mergeKey] = image }
        for image in remote {
            var merged = image
            if merged.installPath == nil { merged.installPath = byId[image.mergeKey]?.installPath }
            byId[image.mergeKey] = merged
        }
        return Array(byId.values)
    }

    private func rememberLocal(_ manifest: ImageManifest) throws {
        try StateStore(config.stateDir).update { state in
            var item = state.apps[manifest.bundleId] ?? AppState()
            item.imageId = manifest.imageId
            item.mode = manifest.mode.rawValue
            state.apps[manifest.bundleId] = item
        }
    }

    private func ensureRepoCollections(_ backend: any StorageBackend) throws {
        for name in ["images", "manifests", "catalog", "devices", "trash"] {
            try? backend.ensureCollection(name)
        }
    }

    func readManifests(_ backend: any StorageBackend) throws -> [ImageManifest] {
        let names = try listRepo(backend, "manifests")
        var manifests: [ImageManifest] = []
        for name in names where name.hasSuffix(".json") && !RepoFileNames.isConflictCopy(name) && !RepoFileNames.isPlaceholder(name) {
            let data: Data
            do {
                data = try backend.get("manifests/\(name)", range: nil)
            } catch {
                throw DisklesslyError.backend("cannot read manifests/\(name) in the repo; nothing was changed: \(error)")
            }
            if let manifest = try? ImageManifest.decode(data) {
                manifests.append(manifest)
            } else {
                FileHandle.standardError.write(Data("disklessly: warning: skipping undecodable manifest \(name)\n".utf8))
            }
        }
        return manifests
    }

    private func loadDeviceFacts(_ backend: any StorageBackend) throws -> [DeviceFileFact] {
        try UbiquitousMaterializer.withBudget(ICloudLimits.metadataTimeout()) {
            try self.deviceFacts(backend)
        }
    }

    private func deviceFacts(_ backend: any StorageBackend) throws -> [DeviceFileFact] {
        let names = try listRepo(backend, "devices")
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
        let selfId = LocalDeviceStore.load(stateDir: stateDirectory)?.deviceId
        var plan = RepoGarbage.plan(liveImageIds: census.ids, trash: trash, devices: devices, now: now, legacyImageIds: legacy, includeLegacy: includeLegacy, selfDeviceId: selfId)
        try keepMismatchedStubImages(&plan, backend: backend)
        for imageId in plan.restoreFromTrash {
            try stopOnMoveFailure { try restoreTrashed(imageId, backend: backend) }
        }
        for imageId in plan.trash where !census.placeholders.contains(imageId) {
            try stopOnMoveFailure { try moveToTrash(imageId, backend: backend, now: now) }
        }
        for imageId in plan.purge {
            try stopOnMoveFailure { try purgeTrash(imageId, backend: backend) }
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

    func stubSearchRoots() -> [URL] {
        if let stubRootsOverride { return stubRootsOverride }
        return BackupScanner.defaultRoots(stubDir: config.stubDir, home: NSHomeDirectory())
    }

    /// What this repo is: its id and the images it has manifests, image files,
    /// or trash entries for. Stub claims are filtered through it so another
    /// repo's stubs on this Mac (for example the user's real `/Applications`
    /// stubs seen from a test repo) are never counted.
    struct StubScope {
        var repoId: String?
        /// Image ids with a manifest in `manifests/`, placeholders included.
        var manifestIds: Set<String>
        /// Image ids with a file in `images/`, placeholders included.
        var imageIds: Set<String>
        /// Image ids in `trash/` (manifests, images, or meta). These are still
        /// this repo's: a ref to one restores it during the GC grace period.
        var trashedIds: Set<String> = []
        /// False when a trash folder could not be listed; nothing is expelled then.
        var trashListed = true

        /// Ids whose manifest is here, live or in the trash. The legacy-stub rule.
        func hasManifest(_ imageId: String) -> Bool {
            manifestIds.contains(imageId) || trashedIds.contains(imageId)
        }

        /// Any trace of the image in this repo.
        func knows(_ imageId: String) -> Bool {
            hasManifest(imageId) || imageIds.contains(imageId)
        }

        func owns(_ stub: StubIdentity, imageId: String) -> Bool {
            stub.belongs(toRepo: repoId, imageInRepo: hasManifest(imageId))
        }

        /// A stub that names another repo although its image is in this one, for
        /// example after `repo.json` was recreated or two Macs minted different
        /// ids. It is not claimed, but `gc` keeps its image and
        /// `stub refresh --all --adopt` can restamp it.
        func isMismatched(_ stub: StubIdentity, imageId: String) -> Bool {
            stub.isForeign(toRepo: repoId) && knows(imageId)
        }
    }

    /// Reads only: the repo id is never created here (see `RepoIdentity.ensure`).
    func stubScope(_ backend: any StorageBackend, manifests: [ImageManifest]) throws -> StubScope {
        let repoId = RepoIdentity.read(backend)
        var manifestIds = Set(manifests.map(\.imageId))
        for name in try listRepo(backend, "manifests") where !RepoFileNames.isConflictCopy(name) {
            let logical = RepoFileNames.logicalName(name)
            guard logical.hasSuffix(".json") else { continue }
            manifestIds.insert((logical as NSString).deletingPathExtension)
        }
        var trashedIds = Set<String>()
        var trashListed = true
        for (dir, suffix) in [("trash/manifests", ".json"), ("trash/images", ".dmg"), ("trash/meta", ".json")] {
            // Some backends fail to list a folder that was never created. That
            // must not block routine commands; it only disables expelling refs.
            guard let names = try? listRepo(backend, dir) else { trashListed = false; continue }
            for name in names where !RepoFileNames.isConflictCopy(name) {
                let logical = RepoFileNames.logicalName(name)
                guard logical.hasSuffix(suffix) else { continue }
                let id = (logical as NSString).deletingPathExtension
                if !id.isEmpty { trashedIds.insert(id) }
            }
        }
        let census = try imageCensus(backend)
        return StubScope(repoId: repoId, manifestIds: manifestIds, imageIds: Set(census.ids), trashedIds: trashedIds, trashListed: trashListed)
    }

    /// A stub on this Mac names another repo id but uses this repo's image. It
    /// is not claimed, so `gc` keeps the image (neither trashed nor purged)
    /// until `stub refresh --all --adopt` restamps the stub.
    func keepMismatchedStubImages(_ plan: inout GCPlan, backend: any StorageBackend) throws {
        let mismatched = mismatchedStubImageIds(scope: try stubScope(backend, manifests: try readManifests(backend)))
        let hit = mismatched.filter { plan.trash.contains($0) || plan.purge.contains($0) }.sorted()
        guard !hit.isEmpty else { return }
        for imageId in hit {
            plan.warnings.append("\(imageId) is used by a stub on this Mac that names another repo id, so it was kept. Run disklessly stub refresh --all --adopt.")
        }
        plan.kept.append(contentsOf: plan.trash.filter { mismatched.contains($0) })
        plan.trash.removeAll { mismatched.contains($0) }
        plan.purge.removeAll { mismatched.contains($0) }
    }

    /// Image ids of stubs on this Mac that name another repo although the image
    /// is this repo's. `gc` does not trash or purge these.
    func mismatchedStubImageIds(scope: StubScope) -> Set<String> {
        var ids = Set<String>()
        for root in stubSearchRoots() {
            for app in RecommendPaths.topLevelApps(in: root) {
                guard let stub = StubIdentity.read(bundle: app) else { continue }
                let imageId = stub.imageId ?? Self.embeddedImageId(app) ?? ""
                if !imageId.isEmpty, scope.isMismatched(stub, imageId: imageId) { ids.insert(imageId) }
            }
        }
        return ids
    }

    /// Bundle ids of this repo's apps that are offloaded on this Mac right now. The free-tier limit counts these.
    public func offloadedBundleIdCount() throws -> Int { try offloadedBundleIds().count }

    func offloadedBundleIds() throws -> Set<String> {
        Set(try stubClaims(backend: try repo, now: Date()).map(\.bundleId))
    }

    /// Stubs in the Applications folders, plus journals whose destination is a stub on this Mac.
    /// Only stubs of this repo count (see `StubIdentity.belongs`).
    private func stubClaims(backend: any StorageBackend, now: Date) throws -> [DeviceImageRef] {
        let manifests = try readManifests(backend)
        let scope = try stubScope(backend, manifests: manifests)
        return stubClaims(manifests: manifests, scope: scope, now: now)
    }

    private func stubClaims(manifests: [ImageManifest], scope: StubScope, now: Date) -> [DeviceImageRef] {
        let byId = Dictionary(manifests.map { ($0.imageId, $0) }, uniquingKeysWith: { current, _ in current })
        // De-duplicated by image id: two stubs for one bundle id with different
        // images are two claims; two stubs for the same image are one.
        var claims: [DeviceImageRef] = []
        var seen = Set<String>()
        for root in stubSearchRoots() {
            for app in RecommendPaths.topLevelApps(in: root) {
                guard let claim = stubClaim(app: app, manifests: byId, scope: scope, now: now) else { continue }
                if seen.insert(claim.mergeKey).inserted { claims.append(claim) }
            }
        }
        let journals = (try? JournalStore.loadAll(stateDir: config.stateDir)) ?? []
        for journal in journals {
            guard !journal.dest.isEmpty else { continue }
            let dest = URL(fileURLWithPath: journal.dest)
            guard let stub = StubIdentity.read(bundle: dest), !stub.isForeign(toRepo: scope.repoId) else { continue }
            let claim = stubClaim(app: dest, manifests: byId, scope: scope, now: journal.createdAt)
                ?? byId[journal.imageId].map { deviceRef($0, installPath: dest.path) }
            guard let claim, seen.insert(claim.mergeKey).inserted else { continue }
            claims.append(claim)
        }
        return claims
    }

    /// Refs in this Mac's device file that an older engine claimed from another
    /// repo's stub. A ref goes only when its stub is still on disk at
    /// `installPath`, names the same image, is not this repo's, and the image has
    /// no manifest, image file, or trash entry here, so nothing of this repo
    /// loses GC protection (a trashed image's ref is what restores it).
    func isForeignStubRef(_ ref: DeviceImageRef, scope: StubScope) -> Bool {
        guard scope.trashListed, !ref.imageId.isEmpty, let path = ref.installPath, !path.isEmpty,
              !scope.knows(ref.imageId) else { return false }
        guard let stub = StubIdentity.read(bundle: URL(fileURLWithPath: path)) else { return false }
        if let image = stub.imageId, image != ref.imageId { return false }
        return !scope.owns(stub, imageId: ref.imageId)
    }

    private func stubClaim(app: URL, manifests: [String: ImageManifest], scope: StubScope, now: Date) -> DeviceImageRef? {
        let resources = app.appendingPathComponent("Contents/Resources")
        guard let object = StubIdentity.readObject(bundle: app) else { return nil }
        let stub = StubIdentity(object: object)
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
        guard scope.owns(stub, imageId: resolvedId) else { return nil }
        let path = app.standardizedFileURL.path
        if let manifest = embedded, manifest.imageId == resolvedId { return deviceRef(manifest, installPath: path) }
        if let manifest = manifests[resolvedId] { return deviceRef(manifest, installPath: path) }
        let appId = object["appId"] as? String
        let bundleId = (appId?.isEmpty == false ? appId : nil) ?? embedded?.bundleId ?? ""
        guard !bundleId.isEmpty else { return nil }
        return DeviceImageRef(imageId: resolvedId, bundleId: bundleId, version: embedded?.version ?? "", build: embedded?.build ?? "", architectures: embedded?.architectures ?? [], mode: embedded?.mode.rawValue ?? "mount", packedAt: embedded?.createdAt ?? now, installPath: path)
    }

    private func deviceRef(_ manifest: ImageManifest, installPath: String? = nil) -> DeviceImageRef {
        DeviceImageRef(imageId: manifest.imageId, bundleId: manifest.bundleId, version: manifest.version, build: manifest.build, architectures: manifest.architectures, mode: manifest.mode.rawValue, packedAt: manifest.createdAt, installPath: installPath)
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
        let names = try listRepo(backend, "images")
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
        let names = try listRepo(backend, "trash/meta")
        var facts: [TrashFact] = []
        for name in names where name.hasSuffix(".json") && !RepoFileNames.isConflictCopy(name) && !RepoFileNames.isPlaceholder(name) {
            let data: Data
            do {
                data = try backend.get("trash/meta/\(name)", range: nil)
            } catch {
                throw DisklesslyError.backend("cannot read trash/meta/\(name) in the repo; nothing was changed: \(error)")
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let imageId = object["imageId"] as? String,
                  let stamp = object["trashedAt"] as? String,
                  let date = Self.parseStamp(stamp) else { continue }
            facts.append(TrashFact(imageId: imageId, trashedAt: date))
        }
        return facts
    }

    /// A missing collection is an empty list. Any other list error aborts before a write or delete.
    private func listRepo(_ backend: any StorageBackend, _ dir: String) throws -> [String] {
        do {
            return try backend.list(dir)
        } catch let error as DisklesslyError {
            throw DisklesslyError.backend("cannot list \(dir)/ in the repo; nothing was changed: \(error.errorDescription ?? String(describing: error))")
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
                return []
            }
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) {
                return []
            }
            throw DisklesslyError.backend("cannot list \(dir)/ in the repo; nothing was changed: \(error)")
        }
    }

    private func stopOnMoveFailure(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as DisklesslyError where error.exitCode == 4 {
            throw error
        } catch {
            throw DisklesslyError.backend("repo move failed; later moves were not attempted: \(error)")
        }
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
            throw DisklesslyError.integrity("refusing to overwrite \(to) while moving \(from)")
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
