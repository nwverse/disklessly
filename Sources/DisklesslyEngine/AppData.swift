import Foundation
import DisklesslyCore

// Data follows the app, v1 (docs/app-data-offload.md): an offloaded app's
// `~/Library/Application Support` folders go to the repo after it quits and come back
// before it launches. Opt-in per app. Only Application Support; containers are not touched.
//
// The one rule everything here serves: the app never starts without its data. If the data
// cannot be brought back, the launch is refused; and a quit never uploads data unless this
// Mac holds the generation the repo calls current.

/// `data/<deviceId>/<bundleId>/manifest.json` in the repo, written only by that device.
public struct AppDataManifest: Codable, Equatable {
    public var schema = "data/1"
    public var deviceId: String
    public var bundleId: String
    public var generation: Int
    /// Repo path of the archive (tar+zstd of a folder holding each root, sealed when a key exists).
    public var object: String
    /// sha256 and size of the object as stored.
    public var sha256: String
    public var storedSize: UInt64
    /// Plain archive digest and size when the object is sealed.
    public var plainSha256: String?
    public var plainSize: UInt64?
    public var keyId: String?
    /// Folder names under Application Support.
    public var roots: [String]
    public var logicalSize: UInt64
    public var fingerprint: String
    public var packedAt: Date
    public var packedFromBuild: String
}

/// This Mac's view of one app's data (`<stateDir>/app-data.json`).
public struct AppDataRecord: Codable, Equatable {
    public enum State: String, Codable { case local, offloaded }
    public var enabled = false
    public var state: State = .local
    /// The generation this Mac last wrote or brought back; 0 = none in the repo yet.
    public var generation = 0
    /// Fingerprint of the folders right after they were brought back, to skip an upload when nothing changed.
    public var installedFingerprint: String?
    public var roots: [String] = []
    public var bytes: UInt64 = 0
    /// Set under the app lock by every launch, so a data-out from an older session can tell a new launch began.
    public var launchedAt: Date?
    public var lastError: String?
    /// A recovery found a live folder and a moved-aside copy of the same root. Both are kept and
    /// nothing moves until the user resolves it (path of the kept transaction folder).
    public var conflict: String?
    public var updatedAt: Date?
}

public struct AppDataStore {
    public var stateDir: String
    var url: URL { URL(fileURLWithPath: stateDir).appendingPathComponent("app-data.json") }

    public func load() -> [String: AppDataRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: AppDataRecord].self, from: data)) ?? [:]
    }

    public func record(_ appId: String) -> AppDataRecord { load()[appId] ?? AppDataRecord() }

    /// Load, change and write under an exclusive lock on `app-data.json.lock`, so the watcher of one
    /// app and the dashboard of another never write over each other's changes.
    @discardableResult
    public func update<T>(_ appId: String, _ body: (inout AppDataRecord) throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw DisklesslyError.failure("cannot open \(url.path).lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw DisklesslyError.failure("cannot lock \(url.path)") }
        defer { flock(fd, LOCK_UN) }
        var all = load()
        var record = all[appId] ?? AppDataRecord()
        let result = try body(&record)
        record.updatedAt = Date()
        all[appId] = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(all).write(to: url, options: .atomic)
        return result
    }
}

public struct AppDataStatus {
    public var appId: String
    public var name: String
    public var record: AppDataRecord
    /// Bytes of the roots on disk now (0 when offloaded).
    public var localBytes: UInt64

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "app": name, "bundleId": appId, "enabled": record.enabled, "state": record.state.rawValue,
            "generation": record.generation, "roots": record.roots, "bytes": NSNumber(value: record.bytes),
            "localBytes": NSNumber(value: localBytes),
        ]
        if let error = record.lastError { object["lastError"] = error }
        return object
    }
}

enum AppDataPaths {
    static func supportDir(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support", isDirectory: true)
    }
    /// Staging on the same volume as the roots, so snapshots clone and installs rename.
    static func workDir(home: String) -> URL {
        supportDir(home: home).appendingPathComponent(".disklessly-data", isDirectory: true)
    }
    static func txName(appId: String, id: String) -> String { appId + "--" + id }
    static func repoDir(deviceId: String, appId: String) -> String { "data/\(deviceId)/\(appId)" }
    static func manifest(deviceId: String, appId: String) -> String { repoDir(deviceId: deviceId, appId: appId) + "/manifest.json" }

    /// Names a root may never have: our own folders and anything hidden.
    static func forbidden(_ name: String) -> Bool {
        name.isEmpty || name.hasPrefix(".") || name.contains("/") || name == "Disklessly" || name.lowercased().contains("isenough")
    }

    /// A real directory directly under Application Support: no link anywhere on the way.
    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }
}

extension DisklesslyEngine {
    var appDataStore: AppDataStore { AppDataStore(stateDir: config.stateDir) }

    // MARK: - Status and opt-in

    public func appDataStatus() throws -> [AppDataStatus] {
        let manifests = try list()
        let records = appDataStore.load()
        return records.keys.sorted().map { appId in
            let record = records[appId] ?? AppDataRecord()
            let name = manifests.first { $0.bundleId == appId }?.name ?? appId
            let local = record.state == .local ? appDataRoots(appId: appId, name: name, recorded: record.roots).reduce(UInt64(0)) { $0 + AllocatedSize.tree($1) } : 0
            return AppDataStatus(appId: appId, name: name, record: record, localBytes: local)
        }
    }

    /// Why data offload cannot be turned on for this app, or nil.
    public func appDataRefusal(_ manifest: ImageManifest) -> String? {
        let id = manifest.bundleId
        if id.hasPrefix("com.apple.") { return "is an Apple app; its data is managed by macOS" }
        if id == "io.github.s546126.disklessly" || id.hasSuffix(".256stub") { return "is Disklessly itself" }
        if let ids = try? (offloadedOverride?() ?? offloadedBundleIds()), !ids.contains(id) { return "is not offloaded on this Mac; offload the app first" }
        if let label = appDataLaunchAgent(manifest) {
            return "has a background job (\(label)) that can start while the app is closed and would find its data gone. Turn it off in System Settings → General → Login Items first"
        }
        if appDataRoots(appId: id, name: manifest.name, recorded: []).isEmpty {
            return "has no folder under ~/Library/Application Support"
        }
        return nil
    }

    public func appDataEnable(_ manifest: ImageManifest, progress: (String) -> Void = { _ in }) throws -> AppDataStatus {
        if let why = appDataRefusal(manifest) { throw DisklesslyError.usage("\(manifest.name) \(why)") }
        let roots = appDataRoots(appId: manifest.bundleId, name: manifest.name, recorded: [])
        try appDataStore.update(manifest.bundleId) { record in
            record.enabled = true
            record.roots = roots.map(\.lastPathComponent)
            record.lastError = nil
        }
        // Offload now if the app is closed; otherwise the next quit does it.
        do { try appDataOut(manifest, since: Date(), progress: progress) }
        catch DisklesslyError.busy(let why) {
            try appDataStore.update(manifest.bundleId) { $0.lastError = why }
        }
        return try appDataStatus().first { $0.appId == manifest.bundleId }!
    }

    /// Brings the data back if it is in the repo, then stops offloading it.
    public func appDataDisable(_ manifest: ImageManifest, progress: (String) -> Void = { _ in }) throws {
        try restore.withLock(manifest.bundleId) {
            try appDataIn(manifest, progress: progress)
        }
        try appDataStore.update(manifest.bundleId) { record in
            record.enabled = false
            record.lastError = nil
        }
    }

    // MARK: - Roots

    /// `Application Support/<bundleId>` and `Application Support/<app name>`, real directories only.
    /// The name is used only when no other app in /Applications or ~/Applications has that name.
    func appDataRoots(appId: String, name: String, recorded: [String]) -> [URL] {
        let support = AppDataPaths.supportDir(home: homeDirectory)
        var names = recorded
        if names.isEmpty {
            names = [appId]
            if name != appId, !appNameIsShared(name) { names.append(name) }
        }
        var seen = Set<String>()
        return names.compactMap { item in
            guard !AppDataPaths.forbidden(item), seen.insert(item).inserted else { return nil }
            let url = support.appendingPathComponent(item, isDirectory: true)
            return AppDataPaths.isRealDirectory(url) ? url : nil
        }
    }

    private func appNameIsShared(_ name: String) -> Bool {
        let folders = ["/Applications", homeDirectory + "/Applications"]
        var count = 0
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            count += items.filter { $0 == name + ".app" }.count
        }
        return count > 1
    }

    /// A launchd job of this app that could run while it is closed: a plist in ~/Library/LaunchAgents
    /// naming the app, or a loaded job whose label starts with the bundle id.
    func appDataLaunchAgent(_ manifest: ImageManifest) -> String? {
        let agents = URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/LaunchAgents")
        let appPath = manifest.app.originalPath
        for file in (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? [] where file.hasSuffix(".plist") {
            let url = agents.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? (try? PropertyListSerialization.propertyList(from: data, format: nil)).map({ "\($0)" }) else { continue }
            if text.contains(appPath + "/") || file.hasPrefix(manifest.bundleId) { return (file as NSString).deletingPathExtension }
        }
        if homeOverride == nil, ProcessInfo.processInfo.environment["DISKLESSLY_HOME"]?.isEmpty ?? true {
            let listing = ProcessRunner.capture("/bin/launchctl", ["list"])
            for line in listing.split(separator: "\n") {
                guard let label = line.split(separator: "\t").last.map(String.init) else { continue }
                if label.hasPrefix(manifest.bundleId + ".") || label == manifest.bundleId { return label }
            }
        }
        return nil
    }

    private func appDataFingerprint(_ roots: [URL]) throws -> String {
        var lines: [String] = []
        for root in roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            lines.append(root.lastPathComponent + "\t" + (try TreeFingerprint.of(root)))
        }
        return SHA256Digest.hex(Data(lines.joined(separator: "\n").utf8))
    }

    // MARK: - Gate

    /// Nil when nothing of the app runs and nothing holds its data; else why not.
    func appDataBusy(_ manifest: ImageManifest, roots: [URL]) -> String? {
        if let appRunningOverride { return appRunningOverride(manifest) ? "\(manifest.name) is running" : nil }
        let state = StateStore(config.stateDir).load().apps[manifest.bundleId]?.state
        if state == "running" || state == "detaching" { return "\(manifest.name) is running" }
        let mount = URL(fileURLWithPath: config.mountRoot).appendingPathComponent(manifest.imageId).path
        if !BundleProcesses.pids(inBundle: manifest.app.originalPath).isEmpty || !BundleProcesses.pids(inBundle: mount).isEmpty {
            return "\(manifest.name) or one of its helpers is running"
        }
        let paths = roots.map(\.path)
        if ProcessProbe.usage(roots: paths) == .busy { return "a process names \(manifest.name)'s data folder" }
        for root in roots where isOpen(root.path, folder: true) { return "a file in \(root.lastPathComponent) is open" }
        return nil
    }

    // MARK: - Data-out

    /// After the app quit: upload its data if it changed, then remove it from this Mac.
    /// `since` is when the caller's session began; a launch after that cancels the move.
    /// Throws `.busy` when the app or a helper is still using the data (nothing changed).
    public func appDataOut(_ manifest: ImageManifest, since: Date, progress: (String) -> Void = { _ in }) throws {
        let appId = manifest.bundleId
        var record = appDataStore.record(appId)
        guard record.enabled, record.state == .local else { return }
        try restore.withLock(appId) { try appDataRecover(appId) }
        record = appDataStore.record(appId)
        guard record.enabled, record.state == .local else { return }
        if let conflict = record.conflict { throw DisklesslyError.resolution(appDataConflictText(manifest, conflict)) }
        let roots = appDataRoots(appId: appId, name: manifest.name, recorded: record.roots)
        guard !roots.isEmpty else { return }
        if let busy = appDataBusy(manifest, roots: roots) { throw DisklesslyError.busy(busy) }
        if LocalDeviceStore.load(stateDir: URL(fileURLWithPath: config.stateDir)) == nil { try ensureDevice() }
        guard let device = LocalDeviceStore.load(stateDir: URL(fileURLWithPath: config.stateDir)) else {
            throw DisklesslyError.failure("this Mac has no device id")
        }
        let backend = try repo
        let manifestPath = AppDataPaths.manifest(deviceId: device.deviceId, appId: appId)
        let current = try readDataManifest(backend, manifestPath)
        progress("check")
        let fingerprint = try appDataFingerprint(roots)
        // A crash right after the manifest was written: the repo already holds exactly these folders.
        if let current, current.generation == record.generation + 1, current.fingerprint == fingerprint {
            try appDataStore.update(appId) { $0.generation = current.generation; $0.installedFingerprint = fingerprint }
            record = appDataStore.record(appId)
        }
        // Never write over a generation this Mac did not see: that data would be lost.
        if (current?.generation ?? 0) != record.generation {
            throw DisklesslyError.integrity("the repo holds data generation \(current?.generation ?? 0) of \(manifest.name) but this Mac last had \(record.generation); nothing was moved. Run disklessly doctor.")
        }
        let work = AppDataPaths.workDir(home: homeDirectory)
        let txid = UUID().uuidString.lowercased()
        let tx = work.appendingPathComponent(AppDataPaths.txName(appId: appId, id: txid), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tx) }
        var next: AppDataManifest
        var uploadedObject: String?
        if let current, record.installedFingerprint == fingerprint, Set(current.roots) == Set(roots.map(\.lastPathComponent)) {
            next = current // unchanged since it came back: the repo copy is still exact
        } else {
            // Snapshot by clone (APFS: instant), so a late write cannot tear the archive.
            let rootBytes = roots.reduce(UInt64(0)) { $0 + AllocatedSize.tree($1) }
            let homeFree = try VolumeSpace.availableBytes(at: AppDataPaths.supportDir(home: homeDirectory).path)
            if !Self.cloneSupported(at: AppDataPaths.supportDir(home: homeDirectory)),
               !SpaceFloor.admits(freeBytes: homeFree, incoming: rootBytes, floor: config.minFreeBytes) {
                throw DisklesslyError.noSpace("a snapshot of \(manifest.name)'s data needs \(rootBytes) bytes; \(homeFree) are free above the \(config.minFreeBytes) byte floor")
            }
            progress("snapshot")
            let snapshot = tx.appendingPathComponent("data", isDirectory: true)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            for root in roots { try FileManager.default.copyItem(at: root, to: snapshot.appendingPathComponent(root.lastPathComponent)) }
            if try appDataFingerprint(roots) != fingerprint { throw DisklesslyError.busy("\(manifest.name)'s data changed while it was read") }
            let logical = roots.reduce(UInt64(0)) { $0 + Self.logicalSize($1) }
            try FileManager.default.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
            let free = try VolumeSpace.availableBytes(at: config.cacheDir)
            guard SpaceFloor.admits(freeBytes: free, incoming: logical, floor: config.minFreeBytes) else {
                throw DisklesslyError.noSpace("archiving \(manifest.name)'s data needs up to \(logical) bytes in \(config.cacheDir), which has \(free) free above the \(config.minFreeBytes) byte floor")
            }
            progress("archive")
            let archive = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("appdata-\(txid).tar.zst")
            defer { try? FileManager.default.removeItem(at: archive) }
            try FolderArchive.create(folder: snapshot, to: archive)
            try? FileManager.default.removeItem(at: snapshot)
            var upload = archive
            var plainSha: String?
            var plainSize: UInt64?
            var keyId: String?
            var sealedFile: URL?
            defer { if let sealedFile { try? FileManager.default.removeItem(at: sealedFile) } }
            if let key = try ImageKeyStore.current(secrets: secrets) {
                progress("encrypt")
                let sealed = archive.appendingPathExtension("dkli")
                let result = try ImageCrypto.seal(archive, to: sealed, key: key.key)
                try? FileManager.default.removeItem(at: archive)
                sealedFile = sealed
                upload = sealed
                plainSha = result.plainSha256
                plainSize = result.plainSize
                keyId = key.id
            }
            progress("hash")
            let sha = try SHA256Digest.hexFile(upload)
            let stored = try ChunkedIO.byteCount(upload)
            let dir = AppDataPaths.repoDir(deviceId: device.deviceId, appId: appId)
            let object = "\(dir)/\(sha).tar.zst" + (keyId == nil ? "" : ".dkli")
            try backend.ensureCollection("data")
            try backend.ensureCollection("data/\(device.deviceId)")
            try backend.ensureCollection(dir)
            progress("upload")
            if case .conflict(let message) = try WriteOnce.publishFile(backend: backend, path: object, file: upload, sha256: sha) {
                throw DisklesslyError.integrity("\(message); \(manifest.name)'s data was not moved")
            }
            uploadedObject = object
            progress("verify")
            guard let remote = try backend.stat(object), remote.size == stored, try readBackDigest(backend, object, size: stored) == sha else {
                throw DisklesslyError.integrity("the repo copy of \(manifest.name)'s data does not match; nothing was moved")
            }
            next = AppDataManifest(deviceId: device.deviceId, bundleId: appId, generation: record.generation + 1, object: object,
                                   sha256: sha, storedSize: stored, plainSha256: plainSha, plainSize: plainSize, keyId: keyId,
                                   roots: roots.map(\.lastPathComponent), logicalSize: logical, fingerprint: fingerprint,
                                   packedAt: Date(), packedFromBuild: manifest.build)
        }
        // Commit under the app lock: no launch can start between the last check and the move.
        let aside = tx.appendingPathComponent("aside", isDirectory: true)
        let committed: Bool = try restore.withLock(appId) {
            record = appDataStore.record(appId)
            if let launched = record.launchedAt, launched > since { return false }
            if appDataBusy(manifest, roots: roots) != nil { return false }
            if try appDataFingerprint(roots) != fingerprint { return false }
            if next.generation != record.generation {
                try writeDataManifest(backend, manifestPath, next)
            }
            // From here the repo has a verified copy of exactly these folders.
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            try Data("\(next.generation)".utf8).write(to: tx.appendingPathComponent("committed"))
            for root in roots { try FileManager.default.moveItem(at: root, to: aside.appendingPathComponent(root.lastPathComponent)) }
            try appDataStore.update(appId) { record in
                record.state = .offloaded
                record.generation = next.generation
                record.installedFingerprint = nil
                record.roots = next.roots
                record.bytes = next.logicalSize
                record.lastError = nil
            }
            return true
        }
        guard committed else {
            if let uploadedObject { try? backend.delete(uploadedObject) }
            throw DisklesslyError.busy("\(manifest.name) was opened again or its data changed; its data stays on this Mac")
        }
        progress("remove")
        try? FileManager.default.removeItem(at: tx)
        if let current, current.object != next.object { try? backend.delete(current.object) }
        #if os(macOS)
        // On iCloud the space comes back only once iCloud drops its local copy of the object.
        if let root = backend.localRoot(), ICloudFolderBackend.looksLikeICloud(root) {
            try? FileManager.default.evictUbiquitousItem(at: root.appendingPathComponent(next.object))
        }
        #endif
    }

    // MARK: - Data-in

    /// Before launch, under the app lock: bring the data back. Any failure throws, so the app does not start.
    func appDataIn(_ manifest: ImageManifest, progress: (String) -> Void = { _ in }) throws {
        let appId = manifest.bundleId
        try appDataRecover(appId)
        let record = appDataStore.record(appId)
        if let conflict = record.conflict { throw DisklesslyError.resolution(appDataConflictText(manifest, conflict)) }
        guard record.state == .offloaded else { return }
        guard let device = LocalDeviceStore.load(stateDir: URL(fileURLWithPath: config.stateDir)) else {
            throw DisklesslyError.failure("this Mac has no device id; \(manifest.name)'s data cannot be found")
        }
        let backend = try repo
        guard let data = try readDataManifest(backend, AppDataPaths.manifest(deviceId: device.deviceId, appId: appId)) else {
            throw DisklesslyError.integrity("\(manifest.name)'s data is not in the repo; it was not opened so it does not start empty. Run disklessly doctor.")
        }
        guard data.generation == record.generation else {
            throw DisklesslyError.integrity("the repo holds data generation \(data.generation) of \(manifest.name) but this Mac expects \(record.generation); it was not opened")
        }
        let support = AppDataPaths.supportDir(home: homeDirectory)
        for name in data.roots where FileManager.default.fileExists(atPath: support.appendingPathComponent(name).path) {
            throw DisklesslyError.integrity("~/Library/Application Support/\(name) appeared while \(manifest.name)'s data was in the repo (a helper may have made it). Move it away, then open \(manifest.name) again.")
        }
        var decryption: ImageDecryption?
        if let keyId = data.keyId {
            guard let key = try ImageKeyStore.load(secrets: secrets, keyId: keyId), let plainSha = data.plainSha256, let plainSize = data.plainSize else {
                throw DisklesslyError.integrity("\(manifest.name)'s data is encrypted with image key \(keyId), which this Mac's Keychain does not have; it was not opened")
            }
            decryption = ImageDecryption(key: key, keyId: keyId, plainSha256: plainSha, plainSize: plainSize)
        }
        // Peak: the download (and its plain copy while it is opened), then the plain archive and the unpacked folders.
        let plain = data.plainSize ?? data.storedSize
        let need = max(data.storedSize + (data.plainSize ?? 0), plain + data.logicalSize)
        let free = try VolumeSpace.availableBytes(at: support.path)
        guard SpaceFloor.admits(freeBytes: free, incoming: need, floor: config.minFreeBytes) else {
            throw DisklesslyError.noSpace("bringing back \(manifest.name)'s data needs \(need) bytes; \(free) are free above the \(config.minFreeBytes) byte floor")
        }
        let work = AppDataPaths.workDir(home: homeDirectory)
        let tx = work.appendingPathComponent(AppDataPaths.txName(appId: appId, id: UUID().uuidString.lowercased()), isDirectory: true)
        try FileManager.default.createDirectory(at: tx, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tx) }
        let download = tx.appendingPathComponent("archive.tar.zst")
        progress("download")
        try CacheFetcher.materialize(backend: backend, remote: data.object, destination: download, partial: tx.appendingPathComponent("archive.partial"),
                                     expectedSize: data.storedSize, expectedSHA256: data.sha256, decryption: decryption)
        progress("extract")
        let unpacked = tx.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FolderArchive.extract(archive: download, into: unpacked)
        let inner = unpacked.appendingPathComponent("data", isDirectory: true)
        let found = Set((try? FileManager.default.contentsOfDirectory(atPath: inner.path)) ?? [])
        guard found == Set(data.roots) else {
            throw DisklesslyError.integrity("\(manifest.name)'s data archive does not hold the expected folders; it was not opened")
        }
        guard data.roots.allSatisfy({ AppDataPaths.isRealDirectory(inner.appendingPathComponent($0)) }) else {
            throw DisklesslyError.integrity("\(manifest.name)'s data archive holds something other than folders; it was not opened")
        }
        progress("place")
        var placed: [URL] = []
        do {
            for name in data.roots {
                let target = support.appendingPathComponent(name)
                try FileManager.default.moveItem(at: inner.appendingPathComponent(name), to: target)
                placed.append(target)
            }
        } catch {
            // Put the ones already placed back into staging; the repo copy stays the only truth.
            for url in placed { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        let fingerprint = try appDataFingerprint(placed)
        try appDataStore.update(appId) { record in
            record.state = .local
            record.installedFingerprint = fingerprint
            record.lastError = nil
        }
    }

    /// Called by every launch under the app lock: marks the launch, then brings data back.
    func appDataBeforeLaunch(_ manifest: ImageManifest) throws {
        let record = appDataStore.record(manifest.bundleId)
        guard record.enabled || record.state == .offloaded else { return }
        try appDataStore.update(manifest.bundleId) { $0.launchedAt = Date() }
        try appDataIn(manifest) { phase in
            FileHandle.standardError.write(Data("disklessly: \(manifest.name) data: \(phase)\n".utf8))
        }
    }

    /// After a session ends: move the data out if it is enabled. Errors are recorded, not thrown.
    func appDataAfterQuit(appId: String, since: Date) {
        let record = appDataStore.record(appId)
        guard record.enabled, record.state == .local else { return }
        guard let manifest = try? list().first(where: { $0.bundleId == appId }) else { return }
        do {
            try appDataOut(manifest, since: since)
        } catch {
            let message = (error as? DisklesslyError)?.errorDescription ?? error.localizedDescription
            try? appDataStore.update(appId) { $0.lastError = message }
            FileHandle.standardError.write(Data("disklessly: \(manifest.name) data stays on this Mac: \(message)\n".utf8))
        }
    }

    /// APFS clones a copy instantly and shares its blocks; elsewhere a snapshot is a full copy.
    static func cloneSupported(at url: URL) -> Bool {
        #if os(macOS)
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "apfs"
        #else
        return false
        #endif
    }

    // MARK: - Recovery

    func appDataConflictText(_ manifest: ImageManifest, _ folder: String) -> String {
        "\(manifest.name)'s data was being moved when something stopped it, and a new folder of the same name appeared since. Both are kept: compare ~/Library/Application Support with \(folder), keep the right one, delete that folder, then run disklessly data status."
    }

    /// Leftovers of an interrupted move. A transaction with `committed` had its data verified in the
    /// repo before anything was moved aside, so its aside copy goes once the live folder is gone;
    /// anything else in the work folder is a snapshot or download and is removed.
    func appDataRecover(_ appId: String) throws {
        if let conflict = appDataStore.record(appId).conflict, !FileManager.default.fileExists(atPath: conflict) {
            try appDataStore.update(appId) { $0.conflict = nil; $0.lastError = nil }
        }
        let work = AppDataPaths.workDir(home: homeDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: work.path) else { return }
        let support = AppDataPaths.supportDir(home: homeDirectory)
        for entry in entries where entry.hasPrefix(appId + "--") {
            let tx = work.appendingPathComponent(entry)
            if appDataStore.record(appId).conflict == tx.path { continue }
            let aside = tx.appendingPathComponent("aside")
            let marker = tx.appendingPathComponent("committed")
            guard let text = try? String(contentsOf: marker, encoding: .utf8), let generation = Int(text) else {
                // Before the commit nothing was taken from the live folders: only a snapshot or download.
                try? FileManager.default.removeItem(at: tx)
                continue
            }
            let record = appDataStore.record(appId)
            let moved = (try? FileManager.default.contentsOfDirectory(atPath: aside.path)) ?? []
            if record.state == .local, generation >= record.generation {
                // Crashed during the move. The repo has a verified copy of these folders.
                if Set(moved) == Set(record.roots) {
                    try appDataStore.update(appId) { record in
                        record.state = .offloaded
                        record.generation = generation
                        record.installedFingerprint = nil
                    }
                } else {
                    // Partly moved: put them back; the data stays here, at the generation the repo holds.
                    // A live folder of the same name means something recreated it: keep both, stop.
                    if moved.contains(where: { FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path) }) {
                        try appDataStore.update(appId) { $0.conflict = tx.path; $0.lastError = "needs attention" }
                        continue
                    }
                    for name in moved {
                        try FileManager.default.moveItem(at: aside.appendingPathComponent(name), to: support.appendingPathComponent(name))
                    }
                    try appDataStore.update(appId) { record in
                        record.generation = generation
                        record.installedFingerprint = nil
                    }
                }
            }
            try? FileManager.default.removeItem(at: tx)
        }
    }

    // MARK: - Repo manifest

    func readDataManifest(_ backend: any StorageBackend, _ path: String) throws -> AppDataManifest? {
        guard try backend.stat(path) != nil else { return nil }
        let data = try backend.get(path, range: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppDataManifest.self, from: data)
    }

    func writeDataManifest(_ backend: any StorageBackend, _ path: String, _ manifest: AppDataManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try backend.put(path, data: encoder.encode(manifest))
        guard let back = try readDataManifest(backend, path), back.generation == manifest.generation, back.object == manifest.object else {
            throw DisklesslyError.integrity("the data manifest in the repo did not read back")
        }
    }
}
