import Foundation
import DisklesslyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Multi-stream chunked upload, verification, and download for large offloaded files and
/// compressed folder archives (`files/chunks/<sha256>.bin` + `files/objects/<sha256>.chunks.json`).
public enum ChunkedTransfer {
    public typealias UploadResult = (manifest: ChunkedObjectManifest, manifestPath: String, reused: Bool)

    public static func uploadFile(
        _ source: URL,
        backend: any StorageBackend,
        cacheDir: String,
        minFreeBytes: UInt64,
        config: ChunkedTransferConfig = .current(),
        onBytes: (UInt64, UInt64) -> Void = { _, _ in }
    ) throws -> UploadResult {
        let totalSize = try ChunkedIO.byteCount(source)
        guard totalSize > 0 else {
            throw DisklesslyError.usage("cannot chunk an empty file")
        }
        try ensureCollections(backend)
        let offloadFloor = SpaceFloor.offloadFloor(minFreeBytes)
        let need = min(totalSize, UInt64(config.streams + 1) * config.chunkSize)
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let free = try VolumeSpace.availableBytes(at: cacheDir)
        guard SpaceFloor.admits(freeBytes: free, incoming: need, floor: offloadFloor) else {
            throw DisklesslyError.noSpace("chunked upload of \(source.lastPathComponent) needs up to \(need) bytes in \(cacheDir), which has \(free) free above the \(offloadFloor) byte reserve")
        }

        let stageDir = URL(fileURLWithPath: cacheDir).appendingPathComponent("chunk-stage-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageDir) }

        return try withEscapableBytes(onBytes) { escOnBytes in
            let session = UploadSession(backend: backend, streams: config.streams, estimatedTotal: totalSize, onBytes: escOnBytes)
            var finished = false
            defer { if !finished { session.abort(DisklesslyError.failure("aborted")); session.waitForWorkers() } }

            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }

            var wholeHasher = SHA256Digest.Stream()
            var totalStored: UInt64 = 0
            var index = 0
            let ioBufferSize = 1 << 20

            while !session.isAborted {
                guard session.reserveStageSlot() else { break }
                let chunkURL = stageDir.appendingPathComponent("chunk-\(index).bin")
                guard FileManager.default.createFile(atPath: chunkURL.path, contents: nil) else {
                    session.releaseStageSlot()
                    throw DisklesslyError.failure("could not create staging chunk \(chunkURL.path)")
                }
                var chunkSizeRead: UInt64 = 0
                var chunkHasher = SHA256Digest.Stream()
                do {
                    let handle = try FileHandle(forWritingTo: chunkURL)
                    do {
                        while chunkSizeRead < config.chunkSize {
                            let remaining = Int(min(UInt64(ioBufferSize), config.chunkSize - chunkSizeRead))
                            let slice = try input.read(upToCount: remaining) ?? Data()
                            if slice.isEmpty { break }
                            try handle.write(contentsOf: slice)
                            chunkHasher.update(slice)
                            wholeHasher.update(slice)
                            chunkSizeRead += UInt64(slice.count)
                        }
                        try handle.close()
                    } catch {
                        try? handle.close()
                        try? FileManager.default.removeItem(at: chunkURL)
                        session.releaseStageSlot()
                        throw error
                    }
                } catch {
                    try? FileManager.default.removeItem(at: chunkURL)
                    session.releaseStageSlot()
                    throw error
                }
                if chunkSizeRead == 0 {
                    try? FileManager.default.removeItem(at: chunkURL)
                    session.releaseStageSlot()
                    break
                }
                let chunkSha = chunkHasher.finalize()
                totalStored += chunkSizeRead
                session.submitChunk(index: index, file: chunkURL, sha256: chunkSha, size: chunkSizeRead)
                index += 1
            }

            finished = true
            let chunks = try session.finish(finalTotal: totalStored)
            let wholeSha = wholeHasher.finalize()
            return try publishManifest(codec: "none", sha256: wholeSha, totalSize: totalStored, chunkSize: config.chunkSize, chunks: chunks, backend: backend, label: source.lastPathComponent)
        }
    }

    public static func uploadFolder(
        _ folder: URL,
        expectedLogicalBytes: UInt64,
        backend: any StorageBackend,
        cacheDir: String,
        minFreeBytes: UInt64,
        config: ChunkedTransferConfig = .current(),
        onBytes: (UInt64, UInt64) -> Void = { _, _ in }
    ) throws -> UploadResult {
        try ensureCollections(backend)
        let offloadFloor = SpaceFloor.offloadFloor(minFreeBytes)
        let fastFloorNeed = min(max(expectedLogicalBytes, UInt64(1)), config.chunkSize)
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let free = try VolumeSpace.availableBytes(at: cacheDir)
        guard SpaceFloor.admits(freeBytes: free, incoming: fastFloorNeed, floor: offloadFloor) else {
            throw DisklesslyError.noSpace("archiving \(folder.lastPathComponent) needs up to \(fastFloorNeed) bytes in \(cacheDir), which has \(free) free above the \(offloadFloor) byte reserve")
        }

        let stageDir = URL(fileURLWithPath: cacheDir).appendingPathComponent("chunk-stage-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageDir) }

        return try withEscapableBytes(onBytes) { escOnBytes in
            let session = UploadSession(backend: backend, streams: config.streams, estimatedTotal: max(expectedLogicalBytes, 1), onBytes: escOnBytes)
            var archiveError: Error?
            var wholeResult: (sha256: String, totalSize: UInt64)?
            do {
                wholeResult = try FolderArchive.streamToChunks(
                    folder: folder,
                    chunkSize: config.chunkSize,
                    stageDir: stageDir,
                    reserveStage: { session.reserveStageSlot() },
                    releaseStage: { session.releaseStageSlot() },
                    shouldAbort: { session.isAborted },
                    onChunk: { index, file, sha256, size in
                        session.submitChunk(index: index, file: file, sha256: sha256, size: size)
                    }
                )
            } catch {
                archiveError = error
                session.abort(error)
            }

            let chunks: [ChunkedObjectManifest.Chunk]
            do {
                chunks = try session.finish(finalTotal: wholeResult?.totalSize ?? 0)
            } catch {
                throw archiveError ?? error
            }
            if let archiveError { throw archiveError }
            guard let whole = wholeResult else {
                throw DisklesslyError.failure("folder chunk stream produced no result")
            }
            return try publishManifest(codec: "tar+zstd", sha256: whole.sha256, totalSize: whole.totalSize, chunkSize: config.chunkSize, chunks: chunks, backend: backend, label: folder.lastPathComponent)
        }
    }

    public static func verify(
        backend: any StorageBackend,
        manifestPath: String,
        expected: ChunkedObjectManifest,
        cacheDir: String,
        minFreeBytes: UInt64,
        streams: Int = ChunkedTransferConfig.current().streams
    ) throws {
        guard let remoteStat = try withRetry({ try backend.stat(manifestPath) }) else {
            throw DisklesslyError.integrity("the chunk manifest \(manifestPath) is missing after upload")
        }
        _ = remoteStat
        let data = try withRetry { try backend.get(manifestPath, range: nil) }
        let decoded = try ChunkedObjectManifest.decode(data)
        guard decoded == expected else {
            throw DisklesslyError.integrity("the repo copy of chunk manifest \(manifestPath) does not match what was uploaded")
        }
        if let root = backend.localRoot() {
            for chunk in uniqueChunks(decoded.chunks) {
                let file = root.appendingPathComponent(chunk.path)
                guard let stat = try backend.stat(chunk.path), stat.size == chunk.size else {
                    throw DisklesslyError.integrity("chunk \(chunk.path) has an unexpected size")
                }
                let actual = try SHA256Digest.hexFile(file)
                guard actual == chunk.sha256 else {
                    throw DisklesslyError.integrity("chunk \(chunk.path) sha256 \(actual) does not match \(chunk.sha256)")
                }
            }
            return
        }

        let unique = uniqueChunks(decoded.chunks)
        let statConcurrency = max(max(1, streams), 8)
        let statGroup = DispatchGroup()
        let statSem = DispatchSemaphore(value: statConcurrency)
        let statError = LockedError()
        let downloadLock = NSLock()
        var needsDownload: [ChunkedObjectManifest.Chunk] = []

        for chunk in unique {
            if statError.error != nil { break }
            statSem.wait()
            if statError.error != nil { statSem.signal(); break }
            statGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { statSem.signal(); statGroup.leave() }
                if statError.error != nil { return }
                do {
                    guard let probed = try withRetry({ try backend.statWithHash(chunk.path) }) else {
                        throw DisklesslyError.integrity("chunk \(chunk.path) is missing after upload")
                    }
                    guard probed.stat.size == chunk.size else {
                        throw DisklesslyError.integrity("chunk \(chunk.path) has size \(probed.stat.size), expected \(chunk.size)")
                    }
                    if let sha = probed.sha256 {
                        guard sha == chunk.sha256 else {
                            throw DisklesslyError.integrity("chunk \(chunk.path) sha256 \(sha) does not match \(chunk.sha256)")
                        }
                    } else {
                        downloadLock.lock()
                        needsDownload.append(chunk)
                        downloadLock.unlock()
                    }
                } catch {
                    statError.set(error)
                }
            }
        }
        statGroup.wait()
        if let err = statError.error { throw err }
        if needsDownload.isEmpty { return }

        let activeStreams = max(1, streams)
        let verifyNeed = needsDownload.sorted { $0.size > $1.size }.prefix(activeStreams).reduce(UInt64(0)) { $0 + $1.size }
        let free = try VolumeSpace.availableBytes(at: cacheDir)
        let offloadFloor = SpaceFloor.offloadFloor(minFreeBytes)
        guard SpaceFloor.admits(freeBytes: free, incoming: verifyNeed, floor: offloadFloor) else {
            throw DisklesslyError.noSpace("verifying the repo chunks needs \(verifyNeed) bytes in \(cacheDir), which has \(free) free above the \(offloadFloor) byte reserve; the original was not changed")
        }

        let verifyDir = URL(fileURLWithPath: cacheDir).appendingPathComponent("chunk-verify-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: verifyDir) }

        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: activeStreams)
        let errorBox = LockedError()

        for (offset, chunk) in needsDownload.enumerated() {
            if errorBox.error != nil { break }
            sem.wait()
            if errorBox.error != nil { sem.signal(); break }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let temp = verifyDir.appendingPathComponent("verify-\(offset).bin")
                defer {
                    try? FileManager.default.removeItem(at: temp)
                    sem.signal()
                    group.leave()
                }
                if errorBox.error != nil { return }
                do {
                    _ = try withRetry {
                        try? FileManager.default.removeItem(at: temp)
                        return try backend.download(chunk.path, to: temp, offset: 0)
                    }
                    let size = try ChunkedIO.byteCount(temp)
                    guard size == chunk.size else {
                        throw DisklesslyError.integrity("chunk \(chunk.path) read back with size \(size), expected \(chunk.size)")
                    }
                    let sha = try SHA256Digest.hexFile(temp)
                    guard sha == chunk.sha256 else {
                        throw DisklesslyError.integrity("chunk \(chunk.path) read back with sha256 \(sha), expected \(chunk.sha256)")
                    }
                } catch {
                    errorBox.set(error)
                }
            }
        }
        group.wait()
        if let err = errorBox.error { throw err }
    }

    public static func download(
        backend: any StorageBackend,
        manifestPath: String,
        destination: URL,
        expectedSize: UInt64,
        expectedSHA256: String,
        stagingDir: URL,
        streams: Int = ChunkedTransferConfig.current().streams
    ) throws {
        let data = try withRetry { try backend.get(manifestPath, range: nil) }
        let manifest = try ChunkedObjectManifest.decode(data)
        let wantedSha = expectedSHA256.lowercased()
        guard manifest.sha256 == wantedSha, manifest.totalSize == expectedSize else {
            throw DisklesslyError.integrity("chunk manifest \(manifestPath) digest/size does not match placeholder")
        }

        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let dlDir = stagingDir.appendingPathComponent("chunk-dl-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dlDir) }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DisklesslyError.failure("could not create \(destination.path)")
        }

        let activeStreams = max(1, streams)
        let window = max(2, activeStreams * 2)
        let state = DownloadState(chunks: manifest.chunks)
        let feederGroup = DispatchGroup()
        let workerGroup = DispatchGroup()
        let workerSem = DispatchSemaphore(value: activeStreams)

        feederGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { feederGroup.leave() }
            for (idx, chunk) in manifest.chunks.enumerated() {
                guard state.waitWindow(index: idx, window: window) else { break }
                guard let action = state.claimDownload(sha256: chunk.sha256) else { continue }
                _ = action
                workerSem.wait()
                if state.isAborted { workerSem.signal(); break }
                workerGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { workerSem.signal(); workerGroup.leave() }
                    if state.isAborted { return }
                    let localFile = dlDir.appendingPathComponent("chunk-\(chunk.sha256).bin")
                    do {
                        _ = try withRetry {
                            try? FileManager.default.removeItem(at: localFile)
                            return try backend.download(chunk.path, to: localFile, offset: 0)
                        }
                        let size = try ChunkedIO.byteCount(localFile)
                        guard size == chunk.size else {
                            throw DisklesslyError.integrity("downloaded chunk \(chunk.path) has size \(size), expected \(chunk.size)")
                        }
                        let sha = try SHA256Digest.hexFile(localFile)
                        guard sha == chunk.sha256 else {
                            throw DisklesslyError.integrity("downloaded chunk \(chunk.path) has sha256 \(sha), expected \(chunk.sha256)")
                        }
                        state.markReady(sha256: chunk.sha256, file: localFile)
                    } catch {
                        try? FileManager.default.removeItem(at: localFile)
                        state.fail(error)
                    }
                }
            }
        }

        let out = try FileHandle(forWritingTo: destination)
        var wholeHasher = SHA256Digest.Stream()
        var writtenBytes: UInt64 = 0
        var writeErr: Error?
        do {
            for (idx, chunk) in manifest.chunks.enumerated() {
                guard let file = state.waitReady(sha256: chunk.sha256) else { break }
                _ = try ChunkedIO.read(file) { piece in
                    try out.write(contentsOf: piece)
                    wholeHasher.update(piece)
                    writtenBytes += UInt64(piece.count)
                }
                state.didConsume(index: idx, sha256: chunk.sha256)
            }
            try out.close()
        } catch {
            try? out.close()
            writeErr = error
            state.fail(error)
        }

        feederGroup.wait()
        workerGroup.wait()
        if let err = state.storedError { throw err }
        if let writeErr { throw writeErr }

        let actualSha = wholeHasher.finalize()
        guard writtenBytes == expectedSize, actualSha == wantedSha else {
            try? FileManager.default.removeItem(at: destination)
            throw DisklesslyError.integrity("reassembled archive failed integrity check (size \(writtenBytes)/\(expectedSize), sha256 \(actualSha)/\(wantedSha))")
        }
    }

    // MARK: - Helpers

    private static func ensureCollections(_ backend: any StorageBackend) throws {
        try backend.ensureCollection("files")
        try backend.ensureCollection("files/chunks")
        try backend.ensureCollection("files/objects")
    }

    private static func uniqueChunks(_ chunks: [ChunkedObjectManifest.Chunk]) -> [ChunkedObjectManifest.Chunk] {
        var seen: Set<String> = []
        var out: [ChunkedObjectManifest.Chunk] = []
        for chunk in chunks where seen.insert(chunk.sha256).inserted {
            out.append(chunk)
        }
        return out
    }

    private static func publishManifest(
        codec: String,
        sha256: String,
        totalSize: UInt64,
        chunkSize: UInt64,
        chunks: [ChunkedObjectManifest.Chunk],
        backend: any StorageBackend,
        label: String
    ) throws -> UploadResult {
        let manifest = ChunkedObjectManifest(codec: codec, sha256: sha256, totalSize: totalSize, chunkSize: chunkSize, chunks: chunks)
        try manifest.validate()
        let path = ChunkedObjectManifest.manifestPath(sha256: sha256)
        let data = try manifest.encode()
        let result = try WriteOnce.publish(backend: backend, path: path, data: data)
        if case .conflict(let message) = result {
            throw DisklesslyError.integrity("\(message). \(label) was not changed.")
        }
        return (manifest, path, result == .reused)
    }

    private static func withRetry<T>(attempts: Int = 3, _ work: () throws -> T) throws -> T {
        var last: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                return try work()
            } catch let error as DisklesslyError {
                last = error
                switch error {
                case .backend, .failure:
                    if attempt + 1 < attempts {
                        Thread.sleep(forTimeInterval: TimeInterval(1 << (attempt * 1)))
                        continue
                    }
                    throw error
                default:
                    throw error
                }
            } catch {
                if error is WriteOnceConflict { throw error }
                last = error
                if attempt + 1 < attempts {
                    Thread.sleep(forTimeInterval: TimeInterval(1 << (attempt * 1)))
                    continue
                }
                throw error
            }
        }
        throw last ?? DisklesslyError.failure("operation failed")
    }

    private final class UploadSession: @unchecked Sendable {
        private let backend: any StorageBackend
        private let stageSem: DispatchSemaphore
        private let workerSem: DispatchSemaphore
        private let group = DispatchGroup()
        private let lock = NSLock()
        private let onBytes: (UInt64, UInt64) -> Void
        private var chunks: [ChunkedObjectManifest.Chunk] = []
        private var seenShas: Set<String> = []
        private var uploadedBytes: UInt64 = 0
        private var observedTotalBytes: UInt64
        private var storedError: Error?

        init(backend: any StorageBackend, streams: Int, estimatedTotal: UInt64, onBytes: @escaping (UInt64, UInt64) -> Void) {
            let active = max(1, streams)
            self.backend = backend
            self.stageSem = DispatchSemaphore(value: active + 1)
            self.workerSem = DispatchSemaphore(value: active)
            self.observedTotalBytes = estimatedTotal
            self.onBytes = onBytes
        }

        var isAborted: Bool {
            lock.lock(); defer { lock.unlock() }
            return storedError != nil
        }

        func reserveStageSlot() -> Bool {
            stageSem.wait()
            if isAborted {
                stageSem.signal()
                return false
            }
            return true
        }

        func releaseStageSlot() {
            stageSem.signal()
        }

        func abort(_ error: Error) {
            lock.lock()
            if storedError == nil { storedError = error }
            lock.unlock()
        }

        func submitChunk(index: Int, file: URL, sha256: String, size: UInt64) {
            let chunkPath = ChunkedObjectManifest.chunkPath(sha256: sha256)
            lock.lock()
            chunks.append(ChunkedObjectManifest.Chunk(index: index, path: chunkPath, sha256: sha256, size: size))
            let duplicate = !seenShas.insert(sha256).inserted
            let aborted = storedError != nil
            lock.unlock()

            if aborted || duplicate {
                try? FileManager.default.removeItem(at: file)
                stageSem.signal()
                if duplicate && !aborted { addUploaded(size) }
                return
            }

            workerSem.wait()
            if isAborted {
                try? FileManager.default.removeItem(at: file)
                workerSem.signal()
                stageSem.signal()
                return
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer {
                    try? FileManager.default.removeItem(at: file)
                    workerSem.signal()
                    stageSem.signal()
                    group.leave()
                }
                if isAborted { return }
                do {
                    let remote = try ChunkedTransfer.withRetry { try backend.stat(chunkPath) }
                    if let remote {
                        guard remote.size == size else {
                            throw DisklesslyError.integrity("chunk \(chunkPath) has unexpected size \(remote.size), expected \(size)")
                        }
                    } else {
                        do {
                            try ChunkedTransfer.withRetry { try backend.put(chunkPath, file: file) }
                        } catch is WriteOnceConflict {
                            let raced = try ChunkedTransfer.withRetry { try backend.stat(chunkPath) }
                            guard let raced, raced.size == size else {
                                throw DisklesslyError.integrity("chunk \(chunkPath) write race left unexpected state")
                            }
                        }
                    }
                    addUploaded(size)
                } catch {
                    abort(error)
                }
            }
        }

        func waitForWorkers() {
            group.wait()
        }

        func finish(finalTotal: UInt64) throws -> [ChunkedObjectManifest.Chunk] {
            group.wait()
            lock.lock()
            let err = storedError
            let sorted = chunks.sorted { $0.index < $1.index }
            let finalDone = uploadedBytes
            lock.unlock()
            if let err { throw err }
            if finalTotal > 0 { onBytes(max(finalDone, finalTotal), finalTotal) }
            return sorted
        }

        private func addUploaded(_ delta: UInt64) {
            lock.lock()
            uploadedBytes += delta
            let done = uploadedBytes
            let total = max(observedTotalBytes, done)
            onBytes(done, total)
            lock.unlock()
        }
    }

    private final class DownloadState: @unchecked Sendable {
        private let cond = NSCondition()
        private var remainingUses: [String: Int] = [:]
        private var inProgress: Set<String> = []
        private var downloaded: [String: URL] = [:]
        private var nextWriteIndex = 0
        private var error: Error?

        init(chunks: [ChunkedObjectManifest.Chunk]) {
            for chunk in chunks { remainingUses[chunk.sha256, default: 0] += 1 }
        }

        var isAborted: Bool {
            cond.lock(); defer { cond.unlock() }
            return error != nil
        }

        var storedError: Error? {
            cond.lock(); defer { cond.unlock() }
            return error
        }

        func waitWindow(index: Int, window: Int) -> Bool {
            cond.lock(); defer { cond.unlock() }
            while error == nil && index >= nextWriteIndex + window { cond.wait() }
            return error == nil
        }

        func claimDownload(sha256: String) -> Bool? {
            cond.lock(); defer { cond.unlock() }
            if error != nil || downloaded[sha256] != nil || inProgress.contains(sha256) { return nil }
            inProgress.insert(sha256)
            return true
        }

        func markReady(sha256: String, file: URL) {
            cond.lock()
            inProgress.remove(sha256)
            downloaded[sha256] = file
            cond.broadcast()
            cond.unlock()
        }

        func fail(_ err: Error) {
            cond.lock()
            if error == nil { error = err }
            cond.broadcast()
            cond.unlock()
        }

        func waitReady(sha256: String) -> URL? {
            cond.lock(); defer { cond.unlock() }
            while error == nil {
                if let file = downloaded[sha256] { return file }
                cond.wait()
            }
            return nil
        }

        func didConsume(index: Int, sha256: String) {
            var removeURL: URL?
            cond.lock()
            if let count = remainingUses[sha256] {
                if count <= 1 {
                    remainingUses.removeValue(forKey: sha256)
                    removeURL = downloaded.removeValue(forKey: sha256)
                } else {
                    remainingUses[sha256] = count - 1
                }
            }
            nextWriteIndex = index + 1
            cond.broadcast()
            cond.unlock()
            if let removeURL { try? FileManager.default.removeItem(at: removeURL) }
        }
    }

    private final class LockedError: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
    }
}
