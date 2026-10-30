import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Names

/// iCloud Drive conflict copies and evicted placeholders. These are detected by
/// file name. Localized Finder sentences are not parsed.
public enum RepoFileNames {
    public static func isPlaceholder(_ name: String) -> Bool {
        (name as NSString).lastPathComponent.hasSuffix(".icloud")
    }

    /// `.Foo.json.icloud` and `Foo.json.icloud` both stand for `Foo.json`.
    public static func logicalName(_ name: String) -> String {
        var base = (name as NSString).lastPathComponent
        guard base.hasSuffix(".icloud") else { return base }
        if base.hasPrefix(".") { base.removeFirst() }
        if base.hasSuffix(".icloud") { base.removeLast(".icloud".count) }
        return base
    }

    /// `file 2.json` and names containing `conflicted copy`. A trailing ` 1` is not a conflict.
    public static func isConflictCopy(_ name: String) -> Bool {
        let stem = ((logicalName(name) as NSString).deletingPathExtension)
        if stem.lowercased().contains("conflicted copy") { return true }
        guard let space = stem.lastIndex(of: " "), space != stem.startIndex else { return false }
        let suffix = stem[stem.index(after: space)...]
        guard let number = Int(suffix), number >= 2, suffix.allSatisfy(\.isNumber) else { return false }
        return true
    }
}

// MARK: - Image identity

/// bundle id + version + build + architecture slices + content tree hash.
/// The tree hash is the existing `BundleHasher` digest (64 hex characters).
public struct ImageIdentity: Equatable, Codable {
    public var bundleId: String
    public var version: String
    public var build: String
    public var architectures: [String]
    public var treeHash: String

    public init(bundleId: String, version: String, build: String, architectures: [String], treeHash: String) {
        self.bundleId = bundleId
        self.version = version
        self.build = build
        self.architectures = Self.normalize(architectures)
        self.treeHash = treeHash.lowercased()
    }

    public static func normalize(_ architectures: [String]) -> [String] {
        var seen: [String] = []
        for raw in architectures {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen.sorted()
    }

    public func matches(_ other: ImageIdentity) -> Bool {
        bundleId == other.bundleId
            && version == other.version
            && build == other.build
            && architectures == other.architectures
            && treeHash == other.treeHash
    }

    /// 8 hex digits of the tree hash, extended while `takenBy` reports a different image.
    public func imageId(takenBy: (String) -> ImageIdentity? = { _ in nil }) -> String {
        let hex = treeHash.filter(\.isHexDigit)
        let body = hex.isEmpty ? String(repeating: "0", count: 64) : hex
        var length = min(8, body.count)
        while true {
            let id = Self.compose(bundleId: bundleId, version: version, build: build, architectures: architectures, prefix: String(body.prefix(length)))
            if let existing = takenBy(id), !existing.matches(self), length < body.count {
                length = min(body.count, length + 8)
                continue
            }
            return id
        }
    }

    static func compose(bundleId: String, version: String, build: String, architectures: [String], prefix: String) -> String {
        let versionPart = sanitize(version.isEmpty ? "0" : version)
        let buildPart = sanitize(build.isEmpty ? "0" : build)
        let archPart = sanitize(architectures.isEmpty ? "unknown" : architectures.joined(separator: "+"))
        return "\(sanitize(bundleId))-\(versionPart)_b\(buildPart)-\(archPart)-\(prefix)"
    }

    static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+")
        let mapped = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "0" : mapped
    }
}

public enum ExistingImage: Equatable {
    case absent
    case placeholder
    case sha256(String)
}

public enum ImageEvidence: Equatable {
    /// The object does not exist and there is no placeholder.
    case absent
    /// Dataless or `.icloud`. `cloudConfirmed` means the cloud copy's size matches the manifest.
    case placeholder(cloudConfirmed: Bool)
    /// Bytes are on this Mac. `uploaded == nil` is unknown or not iCloud; `false` is still uploading.
    case local(sha256: String, uploaded: Bool?)
    /// stat or resource values failed.
    case unreadable(String)
}

public enum OriginalDisposition: Equatable {
    case dispose
    case keep(reason: String)
}

public enum PublishDecision: Equatable {
    case create(imageId: String)
    case reuse(ImageManifest, OriginalDisposition)
    case refuse(String, code: Int)
}

public enum PublishPlanner {
    /// Same identity reuses the manifest and does not upload. A manifest whose image
    /// is absent is refused so the original app is left in place. A different version,
    /// build, architecture, or tree hash is a new image. An existing object is never replaced.
    public static func decide(identity: ImageIdentity, manifests: [ImageManifest], evidence: (String) -> ImageEvidence, inTrash: (String) -> Bool) -> PublishDecision {
        if let manifest = manifests.first(where: { $0.resolvedIdentity?.matches(identity) == true }) {
            switch evidence(manifest.image.file) {
            case .absent:
                if inTrash(manifest.imageId) {
                    return .refuse("image \(manifest.imageId) is in the trash. Run isenough gc before packing again; a reference restores it. The original app was not changed.", code: 5)
                }
                return .refuse("manifest \(manifest.imageId) exists but its image is missing and may still be syncing from another Mac. The original app was not changed. Retry later.", code: 5)
            case .placeholder(true):
                return .reuse(manifest, .dispose)
            case .placeholder(false):
                return .reuse(manifest, .keep(reason: "cloud copy not confirmed"))
            case .local(let sha, let uploaded) where sha == manifest.image.sha256 && uploaded != false:
                return .reuse(manifest, .dispose)
            case .local(let sha, _) where sha == manifest.image.sha256:
                return .reuse(manifest, .keep(reason: "image is still uploading"))
            case .local:
                return .refuse("image \(manifest.image.file) is already in the repo but its sha256 does not match the manifest. Refusing to overwrite it.", code: 5)
            case .unreadable(let message):
                return .refuse(message, code: 4)
            }
        }
        let imageId = identity.imageId { id in
            manifests.first { $0.imageId == id }?.resolvedIdentity
        }
        if let clash = manifests.first(where: { $0.imageId == imageId }) {
            return .refuse("image \(imageId) already exists for \(clash.bundleId) \(clash.version) and does not match this app. Refusing to overwrite the manifest.", code: 5)
        }
        let path = "images/\(imageId).dmg"
        switch evidence(path) {
        case .absent:
            return .create(imageId: imageId)
        case .placeholder:
            return .refuse("\(path) is an iCloud placeholder. Refusing to overwrite it.", code: 5)
        case .local:
            return .refuse("\(path) already exists. Refusing to overwrite it.", code: 5)
        case .unreadable(let message):
            return .refuse(message, code: 4)
        }
    }
}

public enum WriteOnce {
    public static func put(backend: any StorageBackend, path: String, data: Data) throws {
        let digest = SHA256Digest.hex(data)
        switch try probe(backend, path) {
        case .absent:
            try backend.put(path, data: data)
        case .sha256(let sha) where sha == digest:
            return
        case .placeholder:
            throw IsenoughError.integrity("refusing to overwrite iCloud placeholder \(path)")
        case .sha256:
            throw IsenoughError.integrity("refusing to overwrite \(path): the existing bytes differ")
        }
    }

    public static func putFile(backend: any StorageBackend, path: String, file: URL, sha256: String) throws {
        switch try probe(backend, path) {
        case .absent:
            try backend.put(path, file: file)
        case .sha256(let sha) where sha == sha256:
            return
        case .placeholder:
            throw IsenoughError.integrity("refusing to overwrite iCloud placeholder \(path)")
        case .sha256:
            throw IsenoughError.integrity("refusing to overwrite \(path): the existing bytes differ")
        }
    }

    public static func probe(_ backend: any StorageBackend, _ path: String) throws -> ExistingImage {
        let base = (path as NSString).lastPathComponent
        if RepoFileNames.isPlaceholder(base) { return .placeholder }
        if let root = backend.localRoot() {
            let url = root.appendingPathComponent(path)
            let hidden = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
            let visible = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".icloud")
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) && (fm.fileExists(atPath: hidden.path) || fm.fileExists(atPath: visible.path)) {
                return .placeholder
            }
        }
        guard try backend.stat(path) != nil else { return .absent }
        if let root = backend.localRoot() {
            let url = root.appendingPathComponent(path)
            return .sha256(try SHA256Digest.hexFile(url))
        }
        return .sha256(SHA256Digest.hex(try backend.get(path, range: nil)))
    }
}

// MARK: - Device identity

public struct DeviceFacts: Equatable, Codable {
    public var hostname: String
    public var arch: String
    public var osVersion: String
    public init(hostname: String, arch: String, osVersion: String) {
        self.hostname = hostname
        self.arch = arch
        self.osVersion = osVersion
    }
}

public struct LocalDevice: Equatable, Codable {
    public var schema: String
    public var deviceId: String
    public var displayName: String
    public init(deviceId: String, displayName: String) {
        self.schema = "local-device/1"
        self.deviceId = deviceId
        self.displayName = displayName
    }
}

public struct DeviceImageRef: Equatable, Codable {
    public var imageId: String
    public var bundleId: String
    public var version: String
    public var build: String
    public var architectures: [String]
    public var mode: String
    public var packedAt: Date
    public init(imageId: String, bundleId: String, version: String, build: String, architectures: [String], mode: String, packedAt: Date) {
        self.imageId = imageId
        self.bundleId = bundleId
        self.version = version
        self.build = build
        self.architectures = architectures
        self.mode = mode
        self.packedAt = packedAt
    }
}

public struct DeviceRecord: Equatable, Codable {
    public var schema: String
    public var deviceId: String
    public var hostname: String
    public var displayName: String
    public var arch: String
    public var osVersion: String
    public var lastSeen: Date
    public var images: [DeviceImageRef]
    /// Monotonic write counter. Nil on records written before this field existed.
    public var generation: UInt64?
    /// `EngineInstall.version` of the writer. Nil on older records.
    public var writer: String?

    public init(deviceId: String, hostname: String, displayName: String, arch: String, osVersion: String, lastSeen: Date, images: [DeviceImageRef], generation: UInt64? = nil, writer: String? = nil) {
        self.schema = "device/1"
        self.deviceId = deviceId
        self.hostname = hostname
        self.displayName = displayName
        self.arch = arch
        self.osVersion = osVersion
        self.lastSeen = lastSeen
        self.images = images
        self.generation = generation
        self.writer = writer
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DeviceRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DeviceRecord.self, from: data)
        guard record.schema == "device/1" else { throw IsenoughError.failure("unsupported device schema \(record.schema)") }
        guard DeviceIds.isSafe(record.deviceId) else { throw IsenoughError.integrity("device id is not a safe file name") }
        return record
    }

    /// The image this Mac's stub is allowed to launch for `bundleId`.
    public func currentImage(bundleId: String) -> DeviceImageRef? {
        images.filter { $0.bundleId == bundleId }.sorted { $0.packedAt > $1.packedAt }.first
    }
}

public enum DeviceIds {
    public static func isSafe(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 80 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }
}

public enum AtomicFile {
    /// Write `url` by creating a sibling temp file, fsyncing it, and renaming it into place.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
            let fd = open(temporary.path, O_RDONLY)
            if fd >= 0 {
                _ = fsync(fd)
                _ = close(fd)
            }
            try ChunkedIO.replaceFile(url, with: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

public enum LocalDeviceStore {
    public static func file(stateDir: URL) -> URL { stateDir.appendingPathComponent("device.json") }

    public static func load(stateDir: URL) -> LocalDevice? {
        guard let data = try? Data(contentsOf: file(stateDir: stateDir)) else { return nil }
        let decoder = JSONDecoder()
        guard let device = try? decoder.decode(LocalDevice.self, from: data), device.schema == "local-device/1", DeviceIds.isSafe(device.deviceId) else { return nil }
        return device
    }

    /// The id is a random UUID stored in the state directory. It is not derived from the hostname.
    public static func loadOrCreate(stateDir: URL, suggestedName: String, makeId: () -> String = { UUID().uuidString.lowercased() }) throws -> LocalDevice {
        if let existing = load(stateDir: stateDir) { return existing }
        let raw = makeId().lowercased()
        guard DeviceIds.isSafe(raw) else { throw IsenoughError.failure("generated device id is not a safe file name") }
        let name = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = LocalDevice(deviceId: raw, displayName: name.isEmpty ? raw : name)
        try save(device, stateDir: stateDir)
        return device
    }

    public static func save(_ device: LocalDevice, stateDir: URL) throws {
        guard device.schema == "local-device/1", DeviceIds.isSafe(device.deviceId) else {
            throw IsenoughError.integrity("refusing to store an unsafe device id")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(device), to: file(stateDir: stateDir))
    }
}

// MARK: - Stub launch

public enum StubLaunchDecision: Equatable {
    case allowed
    case refused(String)
}

public enum StubLaunch {
    /// A stub launches the image id recorded for this Mac. Another version or architecture is refused.
    public static func check(record: DeviceRecord?, manifest: ImageManifest) -> StubLaunchDecision {
        guard let record, let current = record.currentImage(bundleId: manifest.bundleId) else { return .allowed }
        let recordedArch = current.architectures
        let wantedArch = manifest.architectures
        let sameImage = current.imageId == manifest.imageId
        let sameArch = recordedArch == wantedArch || recordedArch.isEmpty || wantedArch.isEmpty
        if sameImage && sameArch { return .allowed }
        let recordedLabel = recordedArch.isEmpty ? "unknown" : recordedArch.joined(separator: "+")
        let wantedLabel = wantedArch.isEmpty ? "unknown" : wantedArch.joined(separator: "+")
        let message = "Refusing to launch \(manifest.bundleId) \(manifest.version) (\(wantedLabel)) image \(manifest.imageId). This Mac recorded \(current.version) (\(recordedLabel)) image \(current.imageId). A stub opens only the image this Mac recorded, so a different version or architecture is not launched."
        return .refused(message)
    }
}

// MARK: - Mac App Store receipt

public enum MASReceiptPaths {
    public static let directory = "Contents/_MASReceipt"
    public static let receipt = "Contents/_MASReceipt/receipt"

    public static func excluded(_ relative: String) -> Bool {
        relative == directory || relative.hasPrefix(directory + "/")
    }
}

/// What restore does with a store receipt. The shared image is not a source of receipts.
public struct MASRestorePlan: Equatable {
    public var useImageReceipt: Bool
    public var installLocalReceipt: Bool
    public var warning: String?
    public init(useImageReceipt: Bool, installLocalReceipt: Bool, warning: String?) {
        self.useImageReceipt = useImageReceipt
        self.installLocalReceipt = installLocalReceipt
        self.warning = warning
    }
}

public enum MASReceiptPolicy {
    public static let warning = "Mac App Store receipt is per Apple ID and per Mac. The shared image does not include Contents/_MASReceipt. This Mac has no receipt saved under its state directory, so restore will not copy one from the image. Open the app from the App Store once if it asks for a receipt."

    public static func plan(imageHadReceipt: Bool, localReceiptAvailable: Bool) -> MASRestorePlan {
        if !imageHadReceipt && !localReceiptAvailable {
            return MASRestorePlan(useImageReceipt: false, installLocalReceipt: false, warning: nil)
        }
        if localReceiptAvailable {
            return MASRestorePlan(useImageReceipt: false, installLocalReceipt: true, warning: nil)
        }
        return MASRestorePlan(useImageReceipt: false, installLocalReceipt: false, warning: warning)
    }
}

public enum MASReceiptStore {
    public static func location(bundleId: String, stateDir: URL) -> URL {
        stateDir.appendingPathComponent("receipts").appendingPathComponent(ImageIdentity.sanitize(bundleId)).appendingPathComponent("receipt")
    }

    /// Copy the machine-local receipt out of a bundle before the image is built.
    @discardableResult
    public static func preserve(from app: URL, bundleId: String, stateDir: URL) throws -> Bool {
        let source = app.appendingPathComponent(MASReceiptPaths.receipt)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let destination = location(bundleId: bundleId, stateDir: stateDir)
        try AtomicFile.write(try Data(contentsOf: source), to: destination)
        return true
    }

    /// Drop a receipt that arrived inside an image, then install this Mac's copy when one was saved.
    public static func reconcile(app: URL, bundleId: String, stateDir: URL) throws -> String? {
        let imageReceipt = app.appendingPathComponent(MASReceiptPaths.receipt)
        let hadImageReceipt = FileManager.default.fileExists(atPath: imageReceipt.path)
        let local = location(bundleId: bundleId, stateDir: stateDir)
        let localAvailable = FileManager.default.fileExists(atPath: local.path)
        let plan = MASReceiptPolicy.plan(imageHadReceipt: hadImageReceipt, localReceiptAvailable: localAvailable)
        if hadImageReceipt {
            BundleHasher.removeMachineReceipt(app)
        }
        if plan.installLocalReceipt {
            let destination = app.appendingPathComponent(MASReceiptPaths.receipt)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFile.write(try Data(contentsOf: local), to: destination)
        }
        return plan.warning
    }
}

// MARK: - Garbage collection

public struct DeviceFileFact: Equatable {
    public var name: String
    public var placeholder: Bool
    public var conflictCopy: Bool
    public var notDownloaded: Bool
    public var record: DeviceRecord?
    public init(name: String, placeholder: Bool, conflictCopy: Bool, notDownloaded: Bool, record: DeviceRecord?) {
        self.name = name
        self.placeholder = placeholder
        self.conflictCopy = conflictCopy
        self.notDownloaded = notDownloaded
        self.record = record
    }
}

public struct TrashFact: Equatable {
    public var imageId: String
    public var trashedAt: Date
    public init(imageId: String, trashedAt: Date) {
        self.imageId = imageId
        self.trashedAt = trashedAt
    }
}

public struct GCPlan: Equatable {
    public var trash: [String]
    public var restoreFromTrash: [String]
    public var purge: [String]
    public var warnings: [String]
    public var kept: [String]
    public init(trash: [String], restoreFromTrash: [String], purge: [String], warnings: [String], kept: [String]) {
        self.trash = trash
        self.restoreFromTrash = restoreFromTrash
        self.purge = purge
        self.warnings = warnings
        self.kept = kept
    }
}

/// Images that already lived in the repo when this Mac first wrote device files.
/// The set is snapshotted once (`catalog/legacy.json`) after stub backfill. It is
/// not recomputed: a later forget must still be able to trash an image this Mac
/// registered and then dropped.
public enum LegacyImages {
    public static let path = "catalog/legacy.json"

    public static func encode(_ imageIds: [String]) throws -> Data {
        let object: [String: Any] = ["schema": "legacy/1", "imageIds": imageIds]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func decode(_ data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schema"] as? String) == "legacy/1",
              let ids = object["imageIds"] as? [String] else { return nil }
        return ids
    }
}

public enum RepoGarbage {
    /// A device that has not checked in for this long is reported. Its images stay.
    public static let staleInterval: TimeInterval = 90 * 24 * 60 * 60
    /// Trash is kept at least this long so a device file that has not synced yet can still reference it.
    public static let graceInterval: TimeInterval = 7 * 24 * 60 * 60

    public static func plan(liveImageIds: [String], trash: [TrashFact], devices: [DeviceFileFact], now: Date, staleInterval: TimeInterval = RepoGarbage.staleInterval, graceInterval: TimeInterval = RepoGarbage.graceInterval, legacyImageIds: Set<String> = [], includeLegacy: Bool = false, selfDeviceId: String? = nil) -> GCPlan {
        let live = Array(Set(liveImageIds)).sorted()
        let trashed = trash.sorted { $0.imageId < $1.imageId }
        var warnings: [String] = []
        if let selfDeviceId {
            let visible = devices.contains { file in
                file.record?.deviceId == selfDeviceId && !file.conflictCopy && !file.placeholder && !file.notDownloaded
            }
            if !visible {
                warnings.append("this Mac's device file is not visible in devices/; gc moved nothing")
                return GCPlan(trash: [], restoreFromTrash: [], purge: [], warnings: warnings, kept: live)
            }
        }
        var referenced = Set<String>()
        let blocked = devices.contains { $0.placeholder || $0.notDownloaded }
        let protected = includeLegacy ? Set<String>() : legacyImageIds
        for file in devices {
            if file.placeholder || file.notDownloaded {
                warnings.append("\(file.name) is not downloaded. Treating it as present, so no image is deleted.")
            }
            if file.conflictCopy {
                warnings.append("conflict copy \(file.name) is left as-is and is not merged.")
            }
            guard let record = file.record else { continue }
            referenced.formUnion(record.images.map(\.imageId))
            if now.timeIntervalSince(record.lastSeen) > staleInterval {
                let days = Int(now.timeIntervalSince(record.lastSeen) / 86_400)
                warnings.append("device \(record.displayName) (\(record.deviceId)) was last seen \(days) days ago. Its images are kept. Forget it with isenough devices forget \(record.deviceId) --yes if that Mac is gone.")
            }
        }
        for id in live where protected.contains(id) && !referenced.contains(id) {
            warnings.append("\(id) predates device files and has no owner. It was not deleted. Pass --include-legacy to include it.")
        }
        if blocked {
            return GCPlan(trash: [], restoreFromTrash: trashed.map(\.imageId), purge: [], warnings: warnings, kept: live)
        }
        let trashIds = trashed.filter { referenced.contains($0.imageId) }.map(\.imageId)
        let purgeIds = trashed.filter { fact in
            !referenced.contains(fact.imageId) && !protected.contains(fact.imageId) && now.timeIntervalSince(fact.trashedAt) >= graceInterval
        }.map(\.imageId)
        for fact in trashed where !referenced.contains(fact.imageId) && !protected.contains(fact.imageId) && now.timeIntervalSince(fact.trashedAt) < graceInterval {
            warnings.append("\(fact.imageId) is in trash and still inside the grace period, so it is not purged.")
        }
        let trashNow = live.filter { !referenced.contains($0) && !protected.contains($0) }
        let kept = live.filter { referenced.contains($0) || protected.contains($0) }
        return GCPlan(trash: trashNow, restoreFromTrash: trashIds, purge: purgeIds, warnings: warnings, kept: kept)
    }
}

public struct SyncReport: Equatable {
    public var conflicts: [String]
    public var placeholders: [String]
    public var stale: [String]
    public var status: String
    public var detail: String
    public init(conflicts: [String], placeholders: [String], stale: [String]) {
        self.conflicts = conflicts
        self.placeholders = placeholders
        self.stale = stale
        var parts: [String] = []
        if !conflicts.isEmpty { parts.append("conflict copies: " + conflicts.joined(separator: ", ")) }
        if !placeholders.isEmpty { parts.append("not downloaded: " + placeholders.joined(separator: ", ")) }
        if !stale.isEmpty { parts.append(stale.joined(separator: " ")) }
        if parts.isEmpty {
            status = "ok"
            detail = ""
        } else {
            status = "warn"
            detail = parts.joined(separator: "; ")
        }
    }
}

public enum RepoSync {
    /// Conflict copies are reported and never merged into the canonical file.
    public static func inspect(names: [String], devices: [DeviceFileFact], now: Date, staleInterval: TimeInterval = RepoGarbage.staleInterval) -> SyncReport {
        let conflicts = names.filter { RepoFileNames.isConflictCopy($0) }.sorted()
        let placeholders = names.filter { RepoFileNames.isPlaceholder($0) && !RepoFileNames.isConflictCopy($0) }.sorted()
        var stale: [String] = []
        for file in devices {
            guard let record = file.record, now.timeIntervalSince(record.lastSeen) > staleInterval else { continue }
            let days = Int(now.timeIntervalSince(record.lastSeen) / 86_400)
            stale.append("device \(record.displayName) (\(record.deviceId)) last seen \(days) days ago.")
        }
        return SyncReport(conflicts: conflicts, placeholders: placeholders, stale: stale)
    }
}

// MARK: - Mach-O slices

/// Reads Mach-O and fat headers. Tool output is not parsed, so this works on Linux with injected bytes.
public enum MachArchitectures {
    public static func slices(at url: URL) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return slices(header: data)
    }

    public static func slices(header data: Data) -> [String] {
        guard data.count >= 8 else { return [] }
        let magic = readU32(data, 0, little: false)
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF {
            return fatSlices(data, magic64: magic == 0xCAFEBABF)
        }
        let native = readU32(data, 0, little: true)
        if native == 0xFEEDFACF { return thinSlice(data, little: true) }
        if native == 0xCFFAEDFE { return thinSlice(data, little: false) }
        return []
    }

    private static func fatSlices(_ data: Data, magic64: Bool) -> [String] {
        let count = Int(readU32(data, 4, little: false))
        guard count > 0, count < 64 else { return [] }
        let record = magic64 ? 32 : 20
        var names: [String] = []
        for index in 0..<count {
            let start = 8 + index * record
            guard data.count >= start + 8 else { break }
            let cpu = readU32(data, start, little: false)
            let sub = readU32(data, start + 4, little: false)
            if let name = cpuName(cpu, sub) { names.append(name) }
        }
        return ImageIdentity.normalize(names)
    }

    private static func thinSlice(_ data: Data, little: Bool) -> [String] {
        guard data.count >= 12 else { return [] }
        let cpu = readU32(data, 4, little: little)
        let sub = readU32(data, 8, little: little)
        return cpuName(cpu, sub).map { [$0] } ?? []
    }

    private static func cpuName(_ cpu: UInt32, _ sub: UInt32) -> String? {
        let subtype = sub & 0xff
        switch cpu {
        case 0x01000007: return "x86_64"
        case 0x0100000C: return subtype == 2 ? "arm64e" : "arm64"
        case 0x00000007: return "i386"
        default: return nil
        }
    }

    private static func readU32(_ data: Data, _ offset: Int, little: Bool) -> UInt32 {
        guard offset >= 0, data.count >= offset + 4 else { return 0 }
        let bytes = [UInt8](data[offset..<(offset + 4)])
        if little {
            return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }
}

// MARK: - Recommend presence

public struct RepoImagePresence: Equatable {
    public var bundleId: String
    public var version: String
    public var build: String
    public var architectures: [String]
    public var imageId: String
    public var devices: [String]
    public init(bundleId: String, version: String, build: String, architectures: [String], imageId: String, devices: [String]) {
        self.bundleId = bundleId
        self.version = version
        self.build = build
        self.architectures = architectures
        self.imageId = imageId
        self.devices = devices
    }
}

public enum RepoPresence {
    /// Same bundle id, version, and architecture slices. The tree hash is checked again at pack time.
    public static func match(bundleId: String, version: String, build: String, architectures: [String], images: [RepoImagePresence]) -> RepoImagePresence? {
        let arch = ImageIdentity.normalize(architectures)
        guard !bundleId.isEmpty, !version.isEmpty, !arch.isEmpty else { return nil }
        let hits = images.filter { image in
            image.bundleId == bundleId
                && image.version == version
                && ImageIdentity.normalize(image.architectures) == arch
                && (build.isEmpty || image.build.isEmpty || image.build == build)
        }
        guard let first = hits.first else { return nil }
        var devices: [String] = []
        for hit in hits {
            for name in hit.devices where !devices.contains(name) { devices.append(name) }
        }
        return RepoImagePresence(bundleId: first.bundleId, version: first.version, build: first.build, architectures: first.architectures, imageId: first.imageId, devices: devices)
    }
}

public enum CatalogIndex {
    public static func encode(manifests: [ImageManifest], deviceId: String, now: Date) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var apps: [String: [String: Any]] = [:]
        let sorted = manifests.sorted { $0.imageId < $1.imageId }
        for manifest in sorted {
            var entry = apps[manifest.bundleId] ?? ["name": manifest.name, "images": [String]()]
            var images = entry["images"] as? [String] ?? []
            if !images.contains(manifest.imageId) { images.append(manifest.imageId) }
            entry["name"] = manifest.name
            entry["images"] = images
            entry["latest"] = images.last ?? manifest.imageId
            apps[manifest.bundleId] = entry
        }
        let object: [String: Any] = [
            "schema": "catalog/1",
            "updatedAt": formatter.string(from: now),
            "updatedBy": deviceId,
            "apps": apps,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
