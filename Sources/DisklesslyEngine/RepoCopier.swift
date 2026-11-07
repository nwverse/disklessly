import Foundation
import DisklesslyCore

/// Where a repo copy stands. `dictionary` is what `/api/cloud` jobs report as `progress`.
public struct RepoCopyProgress: Equatable {
    /// `scan`, `copy`, `verify`, `switch`, or `done`.
    public var phase: String
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var currentPath: String?
    /// Set while syncing mirrors: which mirror this is.
    public var target: String?

    public init(phase: String, filesDone: Int = 0, filesTotal: Int = 0, bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0, currentPath: String? = nil, target: String? = nil) {
        self.phase = phase; self.filesDone = filesDone; self.filesTotal = filesTotal
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.currentPath = currentPath; self.target = target
    }

    public var dictionary: [String: Any] {
        var object: [String: Any] = ["phase": phase, "filesDone": filesDone, "filesTotal": filesTotal,
                                     "bytesDone": NSNumber(value: bytesDone), "bytesTotal": NSNumber(value: bytesTotal)]
        if let currentPath { object["path"] = currentPath }
        if let target { object["target"] = target }
        return object
    }
}

public struct RepoCopyReport: Equatable {
    public var copied: [String] = []
    public var skipped: [String] = []
    /// Path to error message.
    public var failed: [String: String] = [:]
    public var bytesCopied: UInt64 = 0
    public init() {}

    public var dictionary: [String: Any] {
        ["copied": copied.count, "skipped": skipped.count, "failed": failed.count,
         "bytesCopied": NSNumber(value: bytesCopied), "errors": failed.sorted { $0.key < $1.key }.prefix(20).map { "\($0.key): \($0.value)" }]
    }
}

/// Copies every object of one repo onto another backend.
///
/// - Walks the source with `entries` (typed listings), skipping transient names
///   (`.x.tmp-…`, staging files, locks, conflict copies). iCloud placeholders
///   (`.x.dmg.icloud`) are real objects and are copied by their logical name; the
///   iCloud backend downloads them on read.
/// - Copies only what the destination lacks or holds differently: large objects
///   compare by size, small ones (JSON) by content.
/// - Streams each object through one staging file (`download` then `put(file:)`),
///   checks a disk image against the sha256 in its manifest before upload, and
///   checks the uploaded size afterwards.
/// - Copies images and other data first, then manifests, catalog, and device files,
///   then `repo.json` last, so a reader of the destination never sees a manifest
///   whose image is not there yet. With `repo.json` the destination becomes the same
///   repo (same `repoId`), so existing stubs keep working.
/// - Re-running skips everything already copied, so an interrupted copy resumes.
public struct RepoCopier {
    public let source: any StorageBackend
    public let destination: any StorageBackend
    /// Folder for the one staging file. Lives on this Mac's disk; the caller picks one with room.
    public let staging: URL
    /// Objects at or below this size are compared by content, not size.
    public var smallObjectBytes: UInt64 = 4 * 1024 * 1024
    /// Free space kept on the staging volume beyond the object being copied.
    public var freeSpaceMargin: UInt64 = 256 * 1024 * 1024
    /// Tests: replaces the free-space probe.
    public var availableBytes: ((URL) -> UInt64?)?

    public init(source: any StorageBackend, destination: any StorageBackend, staging: URL) {
        self.source = source
        self.destination = destination
        self.staging = staging
    }

    public struct Item: Equatable {
        public var path: String
        public var size: UInt64?
    }

    // MARK: - Walk

    /// Names never copied: our own staging files, locks, Finder litter, and conflict copies.
    /// iCloud placeholders are not transient (see `RepoFileNames.logicalName`).
    public static func isTransient(_ name: String) -> Bool {
        if RepoFileNames.isPlaceholder(name) { return false }
        if name.hasPrefix(".") { return true }
        if name.hasPrefix("disklessly-") || name == "locks" { return true }
        for marker in [".tmp-", ".fetch-", ".rest-", ".partial"] where name.contains(marker) { return true }
        for suffix in [".tmp", ".lock", ".part", ".partial"] where name.hasSuffix(suffix) { return true }
        if RepoFileNames.isConflictCopy(name) { return true }
        return false
    }

    /// Every object in `backend`, with its folders. A listing error aborts: a copy that
    /// cannot see the whole repo must not be taken as complete.
    public static func scan(_ backend: any StorageBackend) throws -> (items: [Item], folders: [String]) {
        var items: [String: Item] = [:]
        var folders: [String] = []
        func walk(_ path: String) throws {
            let prefix = path.isEmpty ? "" : path + "/"
            for entry in try backend.entries(path) where !isTransient(entry.name) {
                if entry.isDirectory {
                    folders.append(prefix + entry.name)
                    try walk(prefix + entry.name)
                    continue
                }
                if RepoFileNames.isPlaceholder(entry.name) {
                    let logical = prefix + RepoFileNames.logicalName(entry.name)
                    if items[logical] == nil { items[logical] = Item(path: logical, size: nil) }
                } else {
                    items[prefix + entry.name] = Item(path: prefix + entry.name, size: entry.size)
                }
            }
        }
        try walk("")
        return (items.values.sorted { order($0.path) < order($1.path) }, folders)
    }

    /// True when the repo holds anything besides `repo.json` and empty folders.
    public static func hasContent(_ backend: any StorageBackend) throws -> Bool {
        struct Found: Error {}
        func walk(_ path: String) throws {
            let prefix = path.isEmpty ? "" : path + "/"
            for entry in try backend.entries(path) where !isTransient(entry.name) {
                if entry.isDirectory { try walk(prefix + entry.name); continue }
                if prefix.isEmpty && RepoFileNames.logicalName(entry.name) == RepoIdentity.path { continue }
                throw Found()
            }
        }
        do { try walk("") } catch is Found { return true }
        return false
    }

    /// Data first, then the files that point at data, then the repo identity.
    static func order(_ path: String) -> (Int, String) {
        if path == RepoIdentity.path { return (3, path) }
        for prefix in ["manifests/", "catalog/", "devices/", "trash/manifests/", "trash/meta/"] where path.hasPrefix(prefix) {
            return (2, path)
        }
        return (1, path)
    }

    /// `image.file` → (sha256, size) from the source's manifests, live and trashed.
    func imageDigests(_ items: [Item]) -> [String: (sha256: String, size: UInt64)] {
        var digests: [String: (String, UInt64)] = [:]
        for item in items where item.path.hasSuffix(".json") && (item.path.hasPrefix("manifests/") || item.path.hasPrefix("trash/manifests/")) {
            guard let data = try? source.get(item.path, range: nil), let manifest = try? ImageManifest.decode(data) else { continue }
            let value = (manifest.image.sha256.lowercased(), manifest.image.size)
            digests[manifest.image.file] = value
            digests["trash/" + manifest.image.file] = value
        }
        return digests
    }

    // MARK: - Copy

    /// Copies everything missing or different. Per-object failures are collected in
    /// the report and the rest still copy; a listing failure throws.
    public func run(progress: (RepoCopyProgress) -> Void = { _ in }) throws -> RepoCopyReport {
        progress(RepoCopyProgress(phase: "scan"))
        let (items, folders) = try Self.scan(source)
        let digests = imageDigests(items)
        try checkIdentity()
        let total = items.reduce(UInt64(0)) { $0 + ($1.size ?? digests[$1.path]?.size ?? 0) }
        var report = RepoCopyReport()
        var state = RepoCopyProgress(phase: "copy", filesTotal: items.count, bytesTotal: total)
        progress(state)
        var collections: Set<String> = []
        for folder in folders.sorted() { ensure(folder, &collections) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for item in items {
            state.currentPath = item.path
            progress(state)
            let expected = item.size ?? digests[item.path]?.size
            do {
                if try same(item, expected: expected) {
                    report.skipped.append(item.path)
                } else {
                    let bytes = try copy(item, expected: expected, digest: digests[item.path], collections: &collections)
                    report.copied.append(item.path)
                    report.bytesCopied += bytes
                }
            } catch {
                report.failed[item.path] = (error as? DisklesslyError)?.errorDescription ?? String(describing: error)
            }
            state.filesDone += 1
            state.bytesDone += expected ?? 0
            progress(state)
        }
        state.phase = "done"
        state.currentPath = nil
        progress(state)
        return report
    }

    /// Refuses to turn another repo into a copy of this one.
    func checkIdentity() throws {
        guard let wanted = RepoIdentity.read(source), let present = RepoIdentity.read(destination), present != wanted else { return }
        if try hasRepoData(destination) {
            throw DisklesslyError.usage("the destination already holds another repo (id \(present)); pick an empty folder or that repo's own copy")
        }
    }

    private func hasRepoData(_ backend: any StorageBackend) throws -> Bool {
        for dir in ["manifests", "images"] {
            if let names = try? backend.list(dir), names.contains(where: { !Self.isTransient($0) }) { return true }
        }
        return false
    }

    private func ensure(_ folder: String, _ done: inout Set<String>) {
        var path = ""
        for part in folder.split(separator: "/") {
            path = path.isEmpty ? String(part) : path + "/" + part
            if done.insert(path).inserted { try? destination.ensureCollection(path) }
        }
    }

    /// Whether the destination already holds this object.
    private func same(_ item: Item, expected: UInt64?) throws -> Bool {
        guard let present = try? destination.stat(item.path) else { return false }
        guard let expected else { return false }
        guard present.size == expected else { return false }
        if expected > smallObjectBytes { return true }
        guard let mine = try? source.get(item.path, range: nil), let theirs = try? destination.get(item.path, range: nil) else { return false }
        return mine == theirs
    }

    private func copy(_ item: Item, expected: UInt64?, digest: (sha256: String, size: UInt64)?, collections: inout Set<String>) throws -> UInt64 {
        if let expected {
            let free = availableBytes?(staging) ?? (try? VolumeSpace.availableBytes(at: staging.path))
            if let free, free < expected + freeSpaceMargin {
                throw DisklesslyError.noSpace("copying \(item.path) needs \(expected) bytes of free space on this Mac to stage it")
            }
        }
        let file = staging.appendingPathComponent("object-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try source.download(item.path, to: file, offset: 0)
        if !FileManager.default.fileExists(atPath: file.path) {
            // Some backends write nothing for an empty object.
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        let size = try ChunkedIO.byteCount(file)
        if let digest {
            guard size == digest.size else {
                throw DisklesslyError.integrity("\(item.path) is \(size) bytes in the source repo; its manifest says \(digest.size)")
            }
            let sha = try SHA256Digest.hexFile(file)
            guard sha == digest.sha256 else {
                throw DisklesslyError.integrity("\(item.path) in the source repo hashes to \(sha), not the manifest's \(digest.sha256)")
            }
        }
        let parent = (item.path as NSString).deletingLastPathComponent
        if !parent.isEmpty { ensure(parent, &collections) }
        // WebDAV publishes with Overwrite: F, so an outdated copy goes first.
        if (try? destination.stat(item.path)) != nil { try destination.delete(item.path) }
        try destination.put(item.path, file: file)
        guard let written = try destination.stat(item.path) else {
            throw DisklesslyError.backend("\(item.path) is missing from the destination right after upload")
        }
        guard written.size == size else {
            throw DisklesslyError.integrity("\(item.path) is \(written.size) bytes on the destination after upload, expected \(size)")
        }
        return size
    }

    // MARK: - Verify

    /// Every live manifest the source can back up is usable on the destination: the
    /// manifest is there and its image is there with the recorded size. Returns the problems.
    public func verify() throws -> [String] {
        var problems: [String] = []
        let names = (try? source.list("manifests")) ?? []
        for name in names where name.hasSuffix(".json") && !Self.isTransient(name) && !RepoFileNames.isPlaceholder(name) {
            let path = "manifests/\(name)"
            guard let data = try? source.get(path, range: nil), let manifest = try? ImageManifest.decode(data) else { continue }
            // An image the source itself lacks cannot be copied; that is not the copy's fault.
            guard (try? source.stat(manifest.image.file)) != nil || imageIsPlaceholder(manifest.image.file) else { continue }
            guard (try? destination.stat(path)) != nil else { problems.append("\(path) was not copied"); continue }
            guard let image = try? destination.stat(manifest.image.file) else { problems.append("\(manifest.image.file) was not copied"); continue }
            if image.size != manifest.image.size {
                problems.append("\(manifest.image.file) is \(image.size) bytes on the destination, the manifest says \(manifest.image.size)")
            }
        }
        if let wanted = RepoIdentity.read(source), RepoIdentity.read(destination) != wanted {
            problems.append("repo.json on the destination does not carry repo id \(wanted)")
        }
        return problems
    }

    private func imageIsPlaceholder(_ path: String) -> Bool {
        guard let root = source.localRoot() else { return false }
        let url = root.appendingPathComponent(path)
        let hidden = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: hidden.path)
    }
}
