import Foundation
import DisklesslyCore
import DisklesslySessions
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FileOffloadResult {
    public var placeholder: FilePlaceholder
    public var placeholderPath: String
    /// The repo already held the same bytes.
    public var reused: Bool
    public var warnings: [String]

    public func jsonObject() -> [String: Any] {
        ["ok": true, "id": placeholder.id, "kind": placeholder.kind.rawValue, "name": placeholder.name,
         "sizeBytes": NSNumber(value: placeholder.size), "storedBytes": NSNumber(value: placeholder.storedSize),
         "object": placeholder.object, "sha256": placeholder.sha256, "placeholder": placeholderPath,
         "reused": reused, "warnings": warnings]
    }
}

public struct FileFetchResult {
    public var target: URL
    public var warnings: [String]

    public init(target: URL, warnings: [String]) {
        self.target = target
        self.warnings = warnings
    }

    public func jsonObject() -> [String: Any] {
        ["ok": true, "restored": target.path, "warnings": warnings]
    }
}

extension DisklesslyEngine {
    /// Paths an offload never touches: the repo, cache and state folders.
    var protectedPaths: [String] { [config.repoPath, config.cacheDir, config.stateDir, config.mountRoot].filter { !$0.isEmpty } }

    /// Why `path` cannot be offloaded right now, or nil. The page and the CLI both ask this.
    public func fileOffloadRefusal(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "does not exist" }
        // iCloud Drive syncs it already; deleting it would delete it on every device.
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { return "is in iCloud Drive, which already offloads it" }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else { return "is not a regular file or folder" }
        return FileOffloadPolicy.refusal(path: url.path, home: homeDirectory, protected: protectedPaths, isDirectory: kind == S_IFDIR, isSymlink: kind == S_IFLNK)
    }

    /// Why `path` cannot be moved to the Trash right now, or nil.
    /// Keeps offload safety guards while allowing direct deletion of rebuildable app/tool caches under `~/Library/Caches`.
    public func trashPathRefusal(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "does not exist" }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { return "is in iCloud Drive, which already offloads it" }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else { return "is not a regular file or folder" }
        let extraAllowed = KnownLocations.rebuildableCaches.map(\.relativePath) + [KnownLocations.derivedData]
        return FileOffloadPolicy.trashRefusal(
            path: url.path,
            home: homeDirectory,
            protected: protectedPaths,
            isDirectory: kind == S_IFDIR,
            isSymlink: kind == S_IFLNK,
            extraAllowedRelativePaths: extraAllowed
        )
    }

    /// Moves a file or folder into the repo and leaves `Name.disklessly` in its place.
    /// The original is deleted only after the repo object reads back with the same SHA-256.
    public func offloadFile(_ path: String, progress: (String) -> Void = { _ in }, onBytes: (UInt64, UInt64) -> Void = { _, _ in }) throws -> FileOffloadResult {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        if let why = fileOffloadRefusal(source.path) { throw DisklesslyError.usage("\(source.path) \(why)") }
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let kind: FilePlaceholder.Kind = isFolder ? .folder : .file
        let placeholderURL = FilePlaceholder.placeholderURL(for: source)
        if FileManager.default.fileExists(atPath: placeholderURL.path) {
            throw DisklesslyError.usage("\(placeholderURL.path) already exists; bring that one back or move it first")
        }
        try License.checkOffloadFile(state: License.load(stateDir: config.stateDir), apps: try offloadedOverride?().count ?? offloadedBundleIds().count, files: offloadedFileCount())
        progress("check")
        if isOpen(source.path, folder: isFolder) {
            throw DisklesslyError.busy("\(source.lastPathComponent) is open in another app. Quit it, then offload again.")
        }
        let before = try fingerprint(source, folder: isFolder)
        let logical = isFolder ? Self.logicalSize(source) : try FileFingerprint.of(url: source).size
        let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        let permissions = (try? FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue

        // Large files/folders on remote backends chunk into 64 MiB content-addressed pieces so
        // upload, verification, and download run concurrently across multiple streams.
        let backend = try repo
        let transferConfig = ChunkedTransferConfig.current()
        let useChunks = transferConfig.shouldChunk(logicalBytes: logical, isRemote: backend.localRoot() == nil)
        try backend.ensureCollection("files")
        try backend.ensureCollection("files/objects")
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }

        let sha: String
        let stored: UInt64
        let object: String
        let codec: String
        let reused: Bool
        if useChunks {
            progress("upload")
            onBytes(0, logical)
            let result: ChunkedTransfer.UploadResult
            if isFolder {
                result = try ChunkedTransfer.uploadFolder(source, expectedLogicalBytes: logical, backend: backend, cacheDir: config.cacheDir, minFreeBytes: config.minFreeBytes, config: transferConfig, onBytes: onBytes)
                codec = "tar+zstd+chunks"
            } else {
                result = try ChunkedTransfer.uploadFile(source, backend: backend, cacheDir: config.cacheDir, minFreeBytes: config.minFreeBytes, config: transferConfig, onBytes: onBytes)
                if try fingerprint(source, folder: false) != before {
                    throw DisklesslyError.busy("\(source.lastPathComponent) changed while it was being read; nothing was offloaded")
                }
                codec = "none+chunks"
            }
            sha = result.manifest.sha256
            stored = result.manifest.totalSize
            object = result.manifestPath
            reused = result.reused
            progress("verify")
            try ChunkedTransfer.verify(backend: backend, manifestPath: object, expected: result.manifest, cacheDir: config.cacheDir, minFreeBytes: config.minFreeBytes, streams: transferConfig.streams)
        } else {
            codec = isFolder ? "tar+zstd" : "none"
            var streamed: (sha256: String, stored: UInt64)?
            let staging = "files/staging/\(UUID().uuidString.lowercased()).part"
            if isFolder {
                try backend.ensureCollection("files/staging")
                progress("upload")
                onBytes(0, logical)
                streamed = try streamArchive(source, to: staging, backend: backend, onBytes: { sent in onBytes(sent, logical) })
            }
            if let streamed {
                sha = streamed.sha256
                stored = streamed.stored
                object = FilePlaceholder.objectPath(sha256: sha, kind: kind)
                reused = try publishStreamed(backend, staging: staging, object: object, sha: sha, stored: stored)
            } else {
                let upload: URL
                if isFolder {
                    try FileManager.default.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
                    let free = try VolumeSpace.availableBytes(at: config.cacheDir)
                    let need = AllocatedSize.tree(source)
                    let offloadFloor = SpaceFloor.offloadFloor(config.minFreeBytes)
                    guard SpaceFloor.admits(freeBytes: free, incoming: need, floor: offloadFloor) else {
                        throw DisklesslyError.noSpace("archiving \(source.lastPathComponent) needs up to \(need) bytes in \(config.cacheDir), which has \(free) free above the \(offloadFloor) byte reserve")
                    }
                    progress("archive")
                    let archive = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("offload-\(UUID().uuidString).tar.zst")
                    staged = archive
                    try FolderArchive.create(folder: source, to: archive)
                    upload = archive
                } else {
                    upload = source
                }
                progress("hash")
                sha = try SHA256Digest.hexFile(upload)
                stored = try ChunkedIO.byteCount(upload)
                if !isFolder, try fingerprint(source, folder: false) != before {
                    throw DisklesslyError.busy("\(source.lastPathComponent) changed while it was being read; nothing was offloaded")
                }
                object = FilePlaceholder.objectPath(sha256: sha, kind: kind)
                progress("upload")
                let result = try WriteOnce.publishFile(backend: backend, path: object, file: upload, sha256: sha)
                if case .conflict(let message) = result { throw DisklesslyError.integrity("\(message). \(source.lastPathComponent) was not changed.") }
                reused = result == .reused
            }
            progress("verify")
            guard let remote = try backend.stat(object), remote.size == stored else {
                throw DisklesslyError.integrity("the repo copy of \(source.lastPathComponent) has the wrong size; the original was not changed")
            }
            let readBack = try readBackDigest(backend, object, size: stored)
            guard readBack == sha else {
                throw DisklesslyError.integrity("the repo copy of \(source.lastPathComponent) does not match (sha256 \(readBack), expected \(sha)); the original was not changed")
            }
        }
        let placeholder = FilePlaceholder(
            id: UUID().uuidString.lowercased(), kind: kind, name: source.lastPathComponent, size: logical, object: object,
            codec: codec, sha256: sha, storedSize: stored, repoId: RepoIdentity.read(backend),
            originalPath: source.path, createdAt: Date(), modifiedAt: modified, posixPermissions: permissions,
            device: LocalDeviceStore.load(stateDir: URL(fileURLWithPath: config.stateDir))?.deviceId)
        // Placeholder first, then the original goes. A crash between the two leaves both,
        // and `fetch` then sees the original and only removes the placeholder.
        try Self.writeExclusively(placeholder.encode(), to: placeholderURL)
        Self.tagPlaceholder(placeholderURL)
        // The original is renamed aside first, so a failure before that point changes nothing,
        // and a delete that stops halfway still leaves the placeholder pointing at the whole copy.
        let aside = source.deletingLastPathComponent().appendingPathComponent(".\(source.lastPathComponent).disklessly-removing-\(UUID().uuidString)")
        do {
            if try fingerprint(source, folder: isFolder) != before {
                throw DisklesslyError.busy("\(source.lastPathComponent) changed while it was uploaded; it was kept and the placeholder removed")
            }
            if isOpen(source.path, folder: isFolder) {
                throw DisklesslyError.busy("\(source.lastPathComponent) was opened while it was uploaded; it was kept and the placeholder removed")
            }
            progress("remove")
            try FileManager.default.moveItem(at: source, to: aside)
        } catch {
            try? FileManager.default.removeItem(at: placeholderURL)
            throw error
        }
        var warnings: [String] = []
        if (try? FileManager.default.removeItem(at: aside)) == nil, FileManager.default.fileExists(atPath: aside.path) {
            warnings.append("could not delete all of \(aside.path); the repo copy is complete, so delete what is left yourself")
        }
        if isFolder {
            // The folder's path now links to an empty cold folder, so tools that look for it still find something there.
            do { try Self.leaveColdLink(at: source, stateDir: config.stateDir, id: placeholder.id) }
            catch { warnings.append("\(source.lastPathComponent) is offloaded, but no link was left in its place: \(error.localizedDescription)") }
        }
        do {
            try OffloadedFileRegistry.update(stateDir: config.stateDir) { records in
                records.removeAll { $0.id == placeholder.id || $0.placeholderPath == placeholderURL.path }
                records.append(OffloadedFileRecord(id: placeholder.id, placeholderPath: placeholderURL.path, name: placeholder.name, kind: kind, size: logical, object: object, createdAt: placeholder.createdAt))
            }
        } catch {
            warnings.append("offloaded, but the local list of offloaded files could not be updated: \(error.localizedDescription)")
        }
        if let root = backend.localRoot() {
            let objectURL = root.appendingPathComponent(object)
            if ICloudFolderBackend.looksLikeICloud(root) {
                // The space comes back once iCloud has uploaded the object and drops the local copy.
                #if os(macOS)
                do { try FileManager.default.evictUbiquitousItem(at: objectURL) }
                catch { warnings.append("iCloud keeps a local copy of \(object) until it finishes uploading; run `disklessly evict-local` later to free the space") }
                #endif
            } else if PackPreflight.deviceID(root.path) == PackPreflight.deviceID(placeholderURL.deletingLastPathComponent().path) {
                warnings.append("the repo is on this disk, so offloading \(source.lastPathComponent) frees no space here")
            }
        }
        return FileOffloadResult(placeholder: placeholder, placeholderPath: placeholderURL.path, reused: reused, warnings: warnings)
    }

    /// Moves a file or folder to the Trash after the same safety checks as offload
    /// (plus allowing disposable app/build caches under `~/Library/Caches`).
    public func trashPath(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let why = trashPathRefusal(url.path) { throw DisklesslyError.usage("\(url.path) \(why)") }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isOpen(url.path, folder: isFolder) {
            throw DisklesslyError.busy("\(url.lastPathComponent) is open in another app. Quit it, then delete again.")
        }
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }

    /// Where the cold folders of offloaded folders live; each one is named by its placeholder id.
    static func coldRoot(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("cold")
    }

    static let coldFolderNote = "This folder was offloaded to the Disklessly repo. Open Disklessly and click Bring back (取回) on it.\n"

    /// Replaces a folder's path with a link to a new, empty cold folder that says how to bring it back.
    static func leaveColdLink(at source: URL, stateDir: String, id: String) throws {
        let folder = coldRoot(stateDir: stateDir).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(coldFolderNote.utf8).write(to: folder.appendingPathComponent("README.txt"))
        #if os(macOS)
        StubIcon.badgeColdFolder(folder)
        #endif
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: folder.path)
    }

    /// Whether `url` is a link left by `leaveColdLink`. The link may dangle.
    static func isColdLink(_ url: URL, stateDir: String) -> Bool {
        coldLinkTarget(url, stateDir: stateDir) != nil
    }

    static func isColdLink(_ url: URL, stateDir: String, id: String) -> Bool {
        coldLinkTarget(url, stateDir: stateDir)?.lastPathComponent == id
    }

    private static func coldLinkTarget(_ url: URL, stateDir: String) -> URL? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
              let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let destination: URL
        if raw.hasPrefix("/") {
            destination = URL(fileURLWithPath: raw)
        } else {
            destination = url.deletingLastPathComponent().appendingPathComponent(raw)
        }
        let target = destination.standardizedFileURL
        let root = coldRoot(stateDir: stateDir).standardizedFileURL
        guard target.deletingLastPathComponent().path == root.path else { return nil }
        return target
    }

    private static func entryMode(_ url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw DisklesslyError.failure("could not inspect \(url.path): \(String(cString: strerror(errno)))")
    }

    /// Only the note written by `leaveColdLink` is ours. Anything else may have been
    /// created through the cold link, so it is reported and preserved.
    private static func addedEntriesInColdFolder(id: String, stateDir: String) throws -> [String] {
        let folder = coldRoot(stateDir: stateDir).appendingPathComponent(id)
        guard let mode = try entryMode(folder) else { return [] }
        guard mode == S_IFDIR else {
            throw DisklesslyError.usage("the cold recovery path \(folder.path) is not a directory; move it aside, then retry")
        }
        var added: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
            if !isGeneratedColdEntry(name, at: folder.appendingPathComponent(name)) { added.append(name) }
        }
        return added
    }

    private static func isGeneratedColdEntry(_ name: String, at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        if name == ".DS_Store" { return true }
        if name == "Icon\r" {
            #if os(macOS)
            guard info.st_size == 0 else { return false }
            return url.path.withCString { path in
                let finder = "com.apple.FinderInfo".withCString { getxattr(path, $0, nil, 0, 0, 0) > 0 }
                let resource = "com.apple.ResourceFork".withCString { getxattr(path, $0, nil, 0, 0, 0) > 0 }
                return finder || resource
            }
            #else
            return false
            #endif
        }
        guard name == "README.txt" else { return false }
        return (try? Data(contentsOf: url)) == Data(coldFolderNote.utf8)
    }

    private static func listEntries(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        return names.count > 5 ? "\(shown), and \(names.count - 5) more" : shown
    }

    private static func coldFolderHasAddedEntriesError(_ target: URL, name: String, entries: [String]) -> DisklesslyError {
        .usage("cannot bring back \(name): \(target.path) links to a cold folder that contains items added after offload (\(listEntries(entries))). Move them somewhere safe, then retry; nothing was changed")
    }

    private static func restoreQuarantinedTarget(_ aside: URL, to target: URL) throws {
        guard try entryMode(target) == nil else {
            throw DisklesslyError.usage("\(target.path) was recreated during restore; the replacement was kept at \(aside.path)")
        }
        do {
            try FileManager.default.moveItem(at: aside, to: target)
        } catch {
            throw DisklesslyError.usage("\(target.path) changed during restore; the replacement could not be put back and was kept at \(aside.path): \(error.localizedDescription)")
        }
    }

    /// Atomically moves whatever is at `target` aside, accepts only the exact cold
    /// symlink this placeholder owns, and puts every other object back unchanged.
    private static func clearColdLinkForRestore(target: URL, stateDir: String, placeholder: FilePlaceholder) throws {
        guard try entryMode(target) != nil else { return }
        let aside = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).disklessly-target-\(UUID().uuidString)")
        guard rename(target.path, aside.path) == 0 else {
            if errno == ENOENT { return }
            throw DisklesslyError.failure("could not move \(target.path) aside for restore: \(String(cString: strerror(errno)))")
        }
        guard isColdLink(aside, stateDir: stateDir, id: placeholder.id) else {
            try restoreQuarantinedTarget(aside, to: target)
            throw DisklesslyError.usage("\(target.path) already exists; it was preserved and nothing was replaced. Move it away, then retry")
        }

        let entries: [String]
        do {
            entries = try addedEntriesInColdFolder(id: placeholder.id, stateDir: stateDir)
        } catch {
            try restoreQuarantinedTarget(aside, to: target)
            throw error
        }
        guard entries.isEmpty else {
            try restoreQuarantinedTarget(aside, to: target)
            throw coldFolderHasAddedEntriesError(target, name: placeholder.name, entries: entries)
        }
        guard unlink(aside.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? restoreQuarantinedTarget(aside, to: target)
            throw DisklesslyError.failure("could not remove the cold link at \(target.path): \(message)")
        }
    }

    /// Removes only the generated note, then removes the folder only when it is empty.
    /// Nothing is ever deleted recursively.
    private static func cleanColdFolder(id: String, stateDir: String) -> [String] {
        let folder = coldRoot(stateDir: stateDir).appendingPathComponent(id)
        do {
            guard let mode = try entryMode(folder) else { return [] }
            guard mode == S_IFDIR else {
                return ["restored, but the cold recovery path \(folder.path) is not a directory; it was left untouched"]
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let unknown = names.filter { !isGeneratedColdEntry($0, at: folder.appendingPathComponent($0)) }
            if !unknown.isEmpty {
                return ["restored, but items added through the cold link were preserved in \(folder.path): \(listEntries(unknown))"]
            }
            for name in names {
                let generated = folder.appendingPathComponent(name)
                guard unlink(generated.path) == 0 || errno == ENOENT else {
                    return ["restored, but \(generated.path) could not be removed: \(String(cString: strerror(errno)))"]
                }
            }
            if rmdir(folder.path) != 0, errno != ENOENT {
                return ["restored, but the cold folder \(folder.path) could not be removed because it is no longer empty; its contents were preserved"]
            }
            return []
        } catch {
            return ["restored, but the cold folder \(folder.path) could not be cleaned up: \(error.localizedDescription); it was left untouched"]
        }
    }

    /// Brings the file or folder of a placeholder back next to it, then removes the placeholder.
    @discardableResult
    public func fetchFile(_ placeholderPath: String, progress: (String) -> Void = { _ in }) throws -> URL {
        try fetchFileDetailed(placeholderPath, progress: progress).target
    }

    /// Detailed fetch result. The extra warnings cover a completed restore whose
    /// optional bookkeeping or cold-folder cleanup could not be finished.
    public func fetchFileDetailed(_ placeholderPath: String, progress: (String) -> Void = { _ in }) throws -> FileFetchResult {
        let placeholderURL = URL(fileURLWithPath: placeholderPath).standardizedFileURL
        let placeholder = try FilePlaceholder.read(placeholderURL)
        let parent = placeholderURL.deletingLastPathComponent()
        let target = parent.appendingPathComponent(placeholder.name)
        let backend = try repo
        if let repoId = placeholder.repoId, let current = RepoIdentity.read(backend), repoId != current {
            throw DisklesslyError.usage("\(placeholderURL.lastPathComponent) belongs to another repo (\(repoId)); switch to it with `disklessly backend use` first")
        }
        if let targetMode = try Self.entryMode(target) {
            if placeholder.kind == .folder, Self.isColdLink(target, stateDir: config.stateDir, id: placeholder.id) {
                let added = try Self.addedEntriesInColdFolder(id: placeholder.id, stateDir: config.stateDir)
                if !added.isEmpty {
                    throw Self.coldFolderHasAddedEntriesError(target, name: placeholder.name, entries: added)
                }
            } else if placeholder.kind == .file, targetMode == S_IFREG, (try? SHA256Digest.hexFile(target)) == placeholder.sha256 {
            // The crash window of an offload: the original is still here. Keep it if it matches.
                return FileFetchResult(target: target, warnings: try finishFetch(placeholderURL, id: placeholder.id))
            } else {
                throw DisklesslyError.usage("\(target.path) already exists; move it away, then bring \(placeholder.name) back")
            }
        }
        progress("download")
        let need = placeholder.storedSize + (placeholder.kind == .folder ? placeholder.size : 0)
        let free = try VolumeSpace.availableBytes(at: parent.path)
        guard SpaceFloor.admits(freeBytes: free, incoming: need, floor: config.minFreeBytes) else {
            throw DisklesslyError.noSpace("bringing back \(placeholder.name) needs \(need) bytes and \(parent.path) has \(free) free above the \(config.minFreeBytes) byte floor")
        }
        let staging = parent.appendingPathComponent(".\(placeholder.name).disklessly-\(UUID().uuidString)")
        let download = staging.appendingPathExtension("download")
        // Chunk parts get their own scratch folder: `staging` itself must not exist yet, because a
        // folder is extracted into it with `createDirectory(withIntermediateDirectories: false)`.
        let chunkScratch = staging.appendingPathExtension("chunks")
        defer {
            try? FileManager.default.removeItem(at: chunkScratch)
            try? FileManager.default.removeItem(at: download)
            try? FileManager.default.removeItem(at: download.appendingPathExtension("partial"))
            try? FileManager.default.removeItem(at: staging)
        }
        if placeholder.isChunked {
            try ChunkedTransfer.download(
                backend: backend,
                manifestPath: placeholder.object,
                destination: download,
                expectedSize: placeholder.storedSize,
                expectedSHA256: placeholder.sha256,
                stagingDir: chunkScratch,
                streams: ChunkedTransferConfig.current().streams
            )
        } else {
            try CacheFetcher.materialize(backend: backend, remote: placeholder.object, destination: download, partial: download.appendingPathExtension("partial"), expectedSize: placeholder.storedSize, expectedSHA256: placeholder.sha256)
        }
        let ready: URL
        if placeholder.kind == .folder {
            progress("extract")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try FolderArchive.extract(archive: download, into: staging)
            let inside = staging.appendingPathComponent(placeholder.name)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            guard entries == [placeholder.name], FileManager.default.fileExists(atPath: inside.path) else {
                throw DisklesslyError.integrity("the archive of \(placeholder.name) does not hold that one folder")
            }
            ready = inside
        } else {
            ready = download
            if let mode = placeholder.posixPermissions { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: ready.path) }
            if let date = placeholder.modifiedAt { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ready.path) }
        }
        progress("place")
        if let failureInjector { try failureInjector("fetch.beforePlace") }
        if placeholder.kind == .folder {
            try Self.clearColdLinkForRestore(target: target, stateDir: config.stateDir, placeholder: placeholder)
        } else if try Self.entryMode(target) != nil {
            throw DisklesslyError.usage("\(target.path) appeared while it was being restored; it was kept and nothing was replaced")
        }
        // moveItem refuses to replace, so a file that appeared meanwhile is kept.
        try FileManager.default.moveItem(at: ready, to: target)
        var warnings = try finishFetch(placeholderURL, id: placeholder.id)
        if placeholder.kind == .folder {
            warnings.append(contentsOf: Self.cleanColdFolder(id: placeholder.id, stateDir: config.stateDir))
        }
        return FileFetchResult(target: target, warnings: warnings)
    }

    /// SHA-256 of the object as the repo now holds it. Uses server-side hash when available,
    /// otherwise hashes local repos in place or downloads HTTP objects once into cache.
    func readBackDigest(_ backend: any StorageBackend, _ object: String, size: UInt64) throws -> String {
        if let root = backend.localRoot() {
            let file = root.appendingPathComponent(object)
            _ = try backend.stat(object)
            return try SHA256Digest.hexFile(file)
        }
        if let probed = try backend.statWithHash(object) {
            guard probed.stat.size == size else {
                throw DisklesslyError.integrity("the repo copy has size \(probed.stat.size), expected \(size)")
            }
            if let sha = probed.sha256 {
                return sha
            }
        }
        let free = try VolumeSpace.availableBytes(at: config.cacheDir)
        let offloadFloor = SpaceFloor.offloadFloor(config.minFreeBytes)
        guard SpaceFloor.admits(freeBytes: free, incoming: size, floor: offloadFloor) else {
            throw DisklesslyError.noSpace("checking the repo copy needs \(size) bytes in \(config.cacheDir), which has \(free) free above the \(offloadFloor) byte reserve; the original was not changed")
        }
        try FileManager.default.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
        let temp = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try backend.download(object, to: temp, offset: 0)
        return try SHA256Digest.hexFile(temp)
    }

    /// Streams a folder's tar+zstd archive into the repo at `staging`, hashing it as it is written.
    /// Returns nil when the backend cannot stream, so the caller archives into the cache instead.
    func streamArchive(_ folder: URL, to staging: String, backend: any StorageBackend, onBytes: (UInt64) -> Void = { _ in }) throws -> (sha256: String, stored: UInt64)? {
        var sha = ""
        do {
            try backend.putStream(staging) { handle in sha = try FolderArchive.stream(folder: folder, to: handle, onBytes: onBytes) }
        } catch DisklesslyError.unsupported(_) {
            return nil
        } catch {
            try? backend.delete(staging)
            throw error
        }
        guard let remote = try backend.stat(staging) else {
            throw DisklesslyError.integrity("the streamed archive of \(folder.lastPathComponent) is missing from the repo")
        }
        return (sha, remote.size)
    }

    /// Moves a streamed archive from `staging` to its content-addressed `object`. Returns true when the object
    /// already held the same sha (the staging copy is deleted). An object with other bytes is never overwritten.
    func publishStreamed(_ backend: any StorageBackend, staging: String, object: String, sha: String, stored: UInt64) throws -> Bool {
        do {
            if try backend.stat(object) != nil {
                guard try readBackDigest(backend, object, size: stored) == sha else {
                    throw DisklesslyError.integrity("\(object) already exists with other bytes; nothing was overwritten")
                }
                try? backend.delete(staging)
                return true
            }
            try backend.move(staging, to: object)
            return false
        } catch {
            try? backend.delete(staging)
            throw error
        }
    }

    private func finishFetch(_ placeholderURL: URL, id: String) throws -> [String] {
        let current = try FilePlaceholder.read(placeholderURL)
        guard current.id == id else {
            throw DisklesslyError.usage("\(placeholderURL.path) changed during fetch; it was kept")
        }
        guard unlink(placeholderURL.path) == 0 else {
            throw DisklesslyError.failure("could not remove \(placeholderURL.path): \(String(cString: strerror(errno)))")
        }
        do {
            try OffloadedFileRegistry.update(stateDir: config.stateDir) { records in
                records.removeAll { $0.id == id }
            }
            return []
        } catch {
            return ["restored, but the local list of offloaded files could not be updated: \(error.localizedDescription)"]
        }
    }

    func isOpen(_ path: String, folder: Bool) -> Bool {
        if let fileOpenOverride { return fileOpenOverride(path, folder) }
        return OpenFiles.isOpen(path, folder: folder)
    }

    /// What must not change between reading the original and deleting it.
    private func fingerprint(_ url: URL, folder: Bool) throws -> String {
        if folder { return try TreeFingerprint.of(url) }
        let f = try FileFingerprint.of(url: url)
        return "\(f.dev):\(f.ino):\(f.size):\(f.mtimeNs)"
    }

    static func logicalSize(_ root: URL) -> UInt64 {
        var total: UInt64 = 0
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Writes a complete file at `url`, failing if something is already there: temp file, then `link`.
    static func writeExclusively(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temp)
        defer { unlink(temp.path) }
        guard link(temp.path, url.path) == 0 else {
            if errno == EEXIST { throw DisklesslyError.usage("\(url.path) already exists") }
            throw DisklesslyError.failure("could not write \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Finder tag `Disklessly` on the placeholder, so it is easy to find. Best effort.
    static func tagPlaceholder(_ url: URL) {
        #if os(macOS)
        try? (url as NSURL).setResourceValue([FilePlaceholder.finderTag], forKey: .tagNamesKey)
        #endif
    }
}

/// Is a file open, or anything inside a folder?
enum OpenFiles {
    static func isOpen(_ path: String, folder: Bool) -> Bool {
        guard let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            #if os(Linux)
            // No lsof: the `/proc/<pid>/fd` links. When `/proc` is unreadable, treat it as open so nothing is moved.
            guard let held = OpenFileProbe.procOpenPaths() else { return true }
            let root = SessionPaths.canonical(path)
            return held.contains { target in
                let open = SessionPaths.canonical(target)
                return open == root || (folder && open.hasPrefix(root + "/"))
            }
            #else
            return false
            #endif
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsof)
        process.arguments = folder ? ["-Fn", "+D", path] : ["-Fn", "--", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if !folder { return OpenFileProbe.isOpen(lsofStatus: process.terminationStatus, lsofStdout: text, path: path) }
        guard process.terminationStatus == 0 else { return false }
        let root = SessionPaths.canonical(path)
        return text.split(separator: "\n").contains { line in
            guard line.hasPrefix("n"), line.count > 1 else { return false }
            let open = SessionPaths.canonical(String(line.dropFirst()))
            return open == root || open.hasPrefix(root + "/")
        }
    }
}

/// A folder as one `tar` stream compressed with zstd, written and read without holding it in memory.
enum FolderArchive {
    static func create(folder: URL, to archive: URL) throws {
        guard FileManager.default.createFile(atPath: archive.path, contents: nil) else {
            throw DisklesslyError.failure("could not create \(archive.path)")
        }
        let out = try FileHandle(forWritingTo: archive)
        defer { try? out.close() }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
        let pipe = Pipe()
        let errors = Pipe()
        tar.standardOutput = pipe
        tar.standardError = errors
        try tar.run()
        let failure = Failure()
        let collected = Collected()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async { collected.set(errors.fileHandleForReading.readDataToEndOfFile()); reader.leave() }
        do { try ZstdStream.compress(from: pipe.fileHandleForReading, to: out) } catch { failure.set(error); tar.terminate() }
        tar.waitUntilExit()
        reader.wait()
        if let error = failure.error { throw error }
        guard tar.terminationStatus == 0 else {
            throw DisklesslyError.failure("tar could not archive \(folder.lastPathComponent) (exit \(tar.terminationStatus)): \(String(decoding: collected.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Writes the same tar+zstd archive as `create` straight to `output`, without a local file, and returns
    /// the SHA-256 of the bytes written. Compressed bytes are read back from a pipe on the way out, so a
    /// write failure drains the rest instead of breaking the pipe.
    static func stream(folder: URL, to output: FileHandle, onBytes: (UInt64) -> Void = { _ in }) throws -> String {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
        let tarOut = Pipe()
        let errors = Pipe()
        tar.standardOutput = tarOut
        tar.standardError = errors
        try tar.run()
        let compressed = Pipe()
        let failure = Failure()
        let collected = Collected()
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global().async { collected.set(errors.fileHandleForReading.readDataToEndOfFile()); workers.leave() }
        workers.enter()
        DispatchQueue.global().async {
            do { try ZstdStream.compress(from: tarOut.fileHandleForReading, to: compressed.fileHandleForWriting) } catch { failure.set(error); tar.terminate() }
            try? compressed.fileHandleForWriting.close()
            workers.leave()
        }
        var hasher = SHA256Digest.Stream()
        var writeError: Error?
        var written: UInt64 = 0
        while true {
            let chunk = drainingPool { compressed.fileHandleForReading.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(chunk)
            if writeError == nil {
                do {
                    try output.write(contentsOf: chunk)
                    written += UInt64(chunk.count)
                    onBytes(written)
                } catch { writeError = error; tar.terminate() }
            }
        }
        try? compressed.fileHandleForReading.close()
        workers.wait()
        tar.waitUntilExit()
        if let error = failure.error { throw error }
        if let writeError { throw writeError }
        guard tar.terminationStatus == 0 else {
            throw DisklesslyError.failure("tar could not archive \(folder.lastPathComponent) (exit \(tar.terminationStatus)): \(String(decoding: collected.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return hasher.finalize()
    }

    /// Streams a folder's tar+zstd archive into `chunkSize` staging files inside `stageDir`, calling
    /// `onChunk` with each completed file's `(index, url, sha256, size)` and returning total digest/size.
    static func streamToChunks(
        folder: URL,
        chunkSize: UInt64,
        stageDir: URL,
        reserveStage: () -> Bool,
        releaseStage: () -> Void,
        shouldAbort: () -> Bool,
        onChunk: (Int, URL, String, UInt64) throws -> Void
    ) throws -> (sha256: String, totalSize: UInt64) {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
        let tarOut = Pipe()
        let errors = Pipe()
        tar.standardOutput = tarOut
        tar.standardError = errors
        try tar.run()
        let compressed = Pipe()
        let failure = Failure()
        let collected = Collected()
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global().async { collected.set(errors.fileHandleForReading.readDataToEndOfFile()); workers.leave() }
        workers.enter()
        DispatchQueue.global().async {
            do { try ZstdStream.compress(from: tarOut.fileHandleForReading, to: compressed.fileHandleForWriting) } catch { failure.set(error); tar.terminate() }
            try? compressed.fileHandleForWriting.close()
            workers.leave()
        }

        var wholeHasher = SHA256Digest.Stream()
        var totalSize: UInt64 = 0
        var chunkIndex = 0
        var currentHandle: FileHandle?
        var currentURL: URL?
        var currentSize: UInt64 = 0
        var currentHasher = SHA256Digest.Stream()

        func cleanupOpenChunk(release: Bool) {
            let hadSlot = currentHandle != nil || currentURL != nil
            if let handle = currentHandle { try? handle.close() }
            if let url = currentURL { try? FileManager.default.removeItem(at: url) }
            currentHandle = nil
            currentURL = nil
            currentSize = 0
            if release && hadSlot { releaseStage() }
        }

        func flushCurrentChunk() throws {
            guard let handle = currentHandle, let url = currentURL else { return }
            try handle.close()
            currentHandle = nil
            let sha = currentHasher.finalize()
            let size = currentSize
            let idx = chunkIndex
            chunkIndex += 1
            currentURL = nil
            currentSize = 0
            currentHasher = SHA256Digest.Stream()
            try onChunk(idx, url, sha, size)
        }

        func openChunkIfNeeded() throws -> Bool {
            if currentHandle != nil { return true }
            guard reserveStage() else { return false }
            let url = stageDir.appendingPathComponent("chunk-\(chunkIndex).bin")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                releaseStage()
                throw DisklesslyError.failure("could not create chunk file \(url.path)")
            }
            do {
                currentHandle = try FileHandle(forWritingTo: url)
                currentURL = url
                currentSize = 0
                currentHasher = SHA256Digest.Stream()
                return true
            } catch {
                try? FileManager.default.removeItem(at: url)
                releaseStage()
                throw error
            }
        }

        var streamErr: Error?
        var aborted = false
        do {
            while true {
                if shouldAbort() {
                    aborted = true
                    tar.terminate()
                    break
                }
                let buffer = drainingPool { compressed.fileHandleForReading.readData(ofLength: 1 << 20) }
                if buffer.isEmpty { break }
                wholeHasher.update(buffer)
                totalSize += UInt64(buffer.count)

                var offset = 0
                while offset < buffer.count {
                    if shouldAbort() {
                        aborted = true
                        tar.terminate()
                        break
                    }
                    guard try openChunkIfNeeded() else {
                        aborted = true
                        tar.terminate()
                        break
                    }
                    let room = Int(min(UInt64(buffer.count - offset), chunkSize - currentSize))
                    let slice = buffer.subdata(in: offset..<(offset + room))
                    try currentHandle!.write(contentsOf: slice)
                    currentHasher.update(slice)
                    currentSize += UInt64(room)
                    offset += room
                    if currentSize >= chunkSize {
                        try flushCurrentChunk()
                    }
                }
                if aborted { break }
            }
            if !aborted && currentHandle != nil {
                try flushCurrentChunk()
            } else if currentHandle != nil {
                cleanupOpenChunk(release: true)
            }
        } catch {
            cleanupOpenChunk(release: true)
            tar.terminate()
            streamErr = error
        }

        try? compressed.fileHandleForReading.close()
        workers.wait()
        tar.waitUntilExit()
        if let streamErr { throw streamErr }
        if let error = failure.error { throw error }
        if aborted { throw DisklesslyError.failure("chunked upload aborted") }
        guard tar.terminationStatus == 0 else {
            throw DisklesslyError.failure("tar could not archive \(folder.lastPathComponent) (exit \(tar.terminationStatus)): \(String(decoding: collected.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (wholeHasher.finalize(), totalSize)
    }

    /// Extracts into `directory`. tar refuses absolute paths and `..` unless `-P` is given, and it never is.
    static func extract(archive: URL, into directory: URL) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", "-", "-C", directory.path]
        let pipe = Pipe()
        let errors = Pipe()
        tar.standardInput = pipe
        tar.standardError = errors
        tar.standardOutput = FileHandle.nullDevice
        // bsdtar exits as soon as it reads the end-of-archive blocks, so the record padding after them
        // may still be unwritten. Writing it then must fail with EPIPE, not kill this process (SIGPIPE).
        #if canImport(Darwin)
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        // Linux has no per-descriptor flag; GNU tar also stops early. Ignore SIGPIPE process-wide (as the
        // remote-machine SSH path already does): writes then fail with EPIPE, handled below.
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        try tar.run()
        let collected = Collected()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async { collected.set(errors.fileHandleForReading.readDataToEndOfFile()); reader.leave() }
        var failure: Error?
        do { try ZstdStream.decompress(from: input, to: pipe.fileHandleForWriting) } catch { failure = error }
        try? pipe.fileHandleForWriting.close()
        tar.waitUntilExit()
        reader.wait()
        // tar succeeded and stopped reading early: the rest was padding after the end-of-archive marker
        // (the archive's SHA-256 was checked before extraction).
        if let failure, !(tar.terminationStatus == 0 && Self.isBrokenPipe(failure)) { throw failure }
        guard tar.terminationStatus == 0 else {
            throw DisklesslyError.integrity("tar could not extract \(archive.lastPathComponent) (exit \(tar.terminationStatus)): \(String(decoding: collected.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func isBrokenPipe(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSPOSIXErrorDomain && e.code == Int(EPIPE) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
