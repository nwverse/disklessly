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

    /// Moves a file or folder into the repo and leaves `Name.disklessly` in its place.
    /// The original is deleted only after the repo object reads back with the same SHA-256.
    public func offloadFile(_ path: String, progress: (String) -> Void = { _ in }) throws -> FileOffloadResult {
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

        // A folder streams into the repo when the backend can. Otherwise it is archived into the cache first.
        // A file is uploaded as is.
        let backend = try repo
        try backend.ensureCollection("files")
        try backend.ensureCollection("files/objects")
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        var streamed: (sha256: String, stored: UInt64)?
        let staging = "files/staging/\(UUID().uuidString.lowercased()).part"
        if isFolder {
            try backend.ensureCollection("files/staging")
            progress("upload")
            streamed = try streamArchive(source, to: staging, backend: backend)
        }
        let sha: String
        let stored: UInt64
        let object: String
        let reused: Bool
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
                guard SpaceFloor.admits(freeBytes: free, incoming: need, floor: config.minFreeBytes) else {
                    throw DisklesslyError.noSpace("archiving \(source.lastPathComponent) needs up to \(need) bytes in \(config.cacheDir), which has \(free) free above the \(config.minFreeBytes) byte floor")
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
        let placeholder = FilePlaceholder(
            id: UUID().uuidString.lowercased(), kind: kind, name: source.lastPathComponent, size: logical, object: object,
            codec: isFolder ? "tar+zstd" : "none", sha256: sha, storedSize: stored, repoId: RepoIdentity.read(backend),
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
                records.removeAll { $0.placeholderPath == placeholderURL.path }
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

    /// Moves a file or folder to the Trash after the same checks an offload makes (inside home,
    /// not a standard folder, not Disklessly's own folders, not open in another app).
    public func trashPath(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let why = fileOffloadRefusal(url.path) { throw DisklesslyError.usage("\(url.path) \(why)") }
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

    /// Replaces a folder's path with a link to a new, empty cold folder that says how to bring it back.
    static func leaveColdLink(at source: URL, stateDir: String, id: String) throws {
        let folder = coldRoot(stateDir: stateDir).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = "This folder was offloaded to the Disklessly repo. Open Disklessly and click Bring back (取回) on it.\n"
        try Data(note.utf8).write(to: folder.appendingPathComponent("README.txt"))
        StubIcon.badgeColdFolder(folder)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: folder.path)
    }

    /// Whether `url` is a link left by `leaveColdLink`. The link may dangle.
    static func isColdLink(_ url: URL, stateDir: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
        return target.hasPrefix(coldRoot(stateDir: stateDir).path + "/")
    }

    /// Brings the file or folder of a placeholder back next to it, then removes the placeholder.
    @discardableResult
    public func fetchFile(_ placeholderPath: String, progress: (String) -> Void = { _ in }) throws -> URL {
        let placeholderURL = URL(fileURLWithPath: placeholderPath).standardizedFileURL
        let placeholder = try FilePlaceholder.read(placeholderURL)
        let parent = placeholderURL.deletingLastPathComponent()
        let target = parent.appendingPathComponent(placeholder.name)
        let backend = try repo
        if let repoId = placeholder.repoId, let current = RepoIdentity.read(backend), repoId != current {
            throw DisklesslyError.usage("\(placeholderURL.lastPathComponent) belongs to another repo (\(repoId)); switch to it with `disklessly backend use` first")
        }
        // Our own link at the target stands for the folder that was offloaded; it is replaced below.
        let coldLink = placeholder.kind == .folder && Self.isColdLink(target, stateDir: config.stateDir)
        if !coldLink, FileManager.default.fileExists(atPath: target.path) {
            // The crash window of an offload: the original is still here. Keep it if it matches.
            if placeholder.kind == .file, (try? SHA256Digest.hexFile(target)) == placeholder.sha256 {
                try finishFetch(placeholderURL)
                return target
            }
            throw DisklesslyError.usage("\(target.path) already exists; move it away, then bring \(placeholder.name) back")
        }
        progress("download")
        let need = placeholder.storedSize + (placeholder.kind == .folder ? placeholder.size : 0)
        let free = try VolumeSpace.availableBytes(at: parent.path)
        guard SpaceFloor.admits(freeBytes: free, incoming: need, floor: config.minFreeBytes) else {
            throw DisklesslyError.noSpace("bringing back \(placeholder.name) needs \(need) bytes and \(parent.path) has \(free) free above the \(config.minFreeBytes) byte floor")
        }
        let staging = parent.appendingPathComponent(".\(placeholder.name).disklessly-\(UUID().uuidString)")
        let download = staging.appendingPathExtension("download")
        defer {
            try? FileManager.default.removeItem(at: download)
            try? FileManager.default.removeItem(at: download.appendingPathExtension("partial"))
            try? FileManager.default.removeItem(at: staging)
        }
        try CacheFetcher.materialize(backend: backend, remote: placeholder.object, destination: download, partial: download.appendingPathExtension("partial"), expectedSize: placeholder.storedSize, expectedSHA256: placeholder.sha256)
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
        if coldLink { try FileManager.default.removeItem(at: target) }
        // moveItem refuses to replace, so a file that appeared meanwhile is kept.
        try FileManager.default.moveItem(at: ready, to: target)
        try finishFetch(placeholderURL)
        if placeholder.kind == .folder {
            try? FileManager.default.removeItem(at: Self.coldRoot(stateDir: config.stateDir).appendingPathComponent(placeholder.id))
        }
        return target
    }

    /// SHA-256 of the object as the repo now holds it. A file-backed repo is hashed in place; an HTTP
    /// repo is downloaded once into the cache, since ranged reads there may resend the rest of the object.
    func readBackDigest(_ backend: any StorageBackend, _ object: String, size: UInt64) throws -> String {
        if let root = backend.localRoot() {
            let file = root.appendingPathComponent(object)
            _ = try backend.stat(object)
            return try SHA256Digest.hexFile(file)
        }
        let free = try VolumeSpace.availableBytes(at: config.cacheDir)
        guard SpaceFloor.admits(freeBytes: free, incoming: size, floor: config.minFreeBytes) else {
            throw DisklesslyError.noSpace("checking the repo copy needs \(size) bytes in \(config.cacheDir), which has \(free) free above the \(config.minFreeBytes) byte floor; the original was not changed")
        }
        let temp = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try backend.download(object, to: temp, offset: 0)
        return try SHA256Digest.hexFile(temp)
    }

    /// Streams a folder's tar+zstd archive into the repo at `staging`, hashing it as it is written.
    /// Returns nil when the backend cannot stream, so the caller archives into the cache instead.
    func streamArchive(_ folder: URL, to staging: String, backend: any StorageBackend) throws -> (sha256: String, stored: UInt64)? {
        var sha = ""
        do {
            try backend.putStream(staging) { handle in sha = try FolderArchive.stream(folder: folder, to: handle) }
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

    private func finishFetch(_ placeholderURL: URL) throws {
        try FileManager.default.removeItem(at: placeholderURL)
        try OffloadedFileRegistry.update(stateDir: config.stateDir) { records in
            records.removeAll { $0.placeholderPath == placeholderURL.path }
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
    static func stream(folder: URL, to output: FileHandle) throws -> String {
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
        while true {
            let chunk = compressed.fileHandleForReading.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(chunk)
            if writeError == nil {
                do { try output.write(contentsOf: chunk) } catch { writeError = error; tar.terminate() }
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
        if let failure { throw failure }
        guard tar.terminationStatus == 0 else {
            throw DisklesslyError.integrity("tar could not extract \(archive.lastPathComponent) (exit \(tar.terminationStatus)): \(String(decoding: collected.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
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
