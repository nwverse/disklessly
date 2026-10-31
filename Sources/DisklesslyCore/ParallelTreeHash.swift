import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension BundleHasher {
    /// SHA-256 of the same byte stream the original serial hasher built: entries sorted by relative path,
    /// each recorded as `l`/`d`/`f` plus mode, symlink target, and raw file bytes. File bodies are read on
    /// a bounded worker pool (about the active core count) and folded in that sorted order, so the digest
    /// matches manifests already stored in repos. Reads are chunked; a file larger than 1 MiB is not held
    /// in one buffer. SHA-256's compression chain is serial, so the workers parallelize the reads and the
    /// single streaming hasher combines them. `DISKLESSLY_TREE_HASH_WORKERS` overrides the pool size.
    public static func treeHash(of root: URL) throws -> String {
        let start = root.resolvingSymlinksInPath()
        var files: [URL] = []
        try collect(start, &files)
        var entries: [Entry] = []
        entries.reserveCapacity(files.count)
        for url in files {
            guard let relative = relativePath(url.path, root: start.path) else {
                throw DisklesslyError.failure("cannot relativize \(url.path) under \(start.path)")
            }
            guard !relative.isEmpty, !relative.split(separator: "/").contains(".."), !relative.hasPrefix("/") else { continue }
            // The Mac App Store receipt is per Apple ID and per Mac. Leaving it out of the
            // digest keeps the digest format and lets two machines share one image.
            if MASReceiptPaths.excluded(relative) { continue }
            entries.append(classify(url, relative: relative))
        }
        entries.sort { $0.relative < $1.relative }
        var hasher = SHA256Digest.Hasher()
        var index = 0
        let workers = workerCount()
        while index < entries.count {
            switch entries[index].kind {
            case .symlink(let target):
                hasher.update("l \(entries[index].mode) \(entries[index].relative)\n")
                hasher.update("target \(target)\n")
                index += 1
            case .directory:
                hasher.update("d \(entries[index].mode) \(entries[index].relative)\n")
                index += 1
            case .file:
                var end = index
                let limit = index + workers
                while end < entries.count && end < limit {
                    if case .file = entries[end].kind { end += 1 } else { break }
                }
                hashFiles(Array(entries[index..<end]), workers: workers, into: &hasher)
                index = end
            }
        }
        return hasher.finalize()
    }

    static func workerCount() -> Int {
        if let raw = getenv("DISKLESSLY_TREE_HASH_WORKERS") {
            let text = String(cString: raw)
            if let value = Int(text), value > 0 { return min(value, 256) }
        }
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 32))
    }

    /// Files at or under this size are read whole, in parallel, inside one batch. Larger regular files are streamed.
    private static let streamAbove = 1 << 20

    private struct Entry {
        var relative: String
        var path: String
        var mode: String
        enum Kind {
            case symlink(String)
            case directory
            case file(stream: Bool)
        }
        var kind: Kind
    }

    private static func classify(_ url: URL, relative: String) -> Entry {
        let path = url.path
        let mode = fileMode(url)
        if DurableIO.isSymlink(url) {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
            return Entry(relative: relative, path: path, mode: mode, kind: .symlink(target))
        }
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            return Entry(relative: relative, path: path, mode: mode, kind: .directory)
        }
        var st = stat()
        let stream = lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_size > streamAbove
        return Entry(relative: relative, path: path, mode: mode, kind: .file(stream: stream))
    }

    private final class Loaded {
        var data: Data?
    }

    private static func hashFiles(_ entries: [Entry], workers: Int, into hasher: inout SHA256Digest.Hasher) {
        let boxes = entries.map { _ in Loaded() }
        let paths = entries.map(\.path)
        let streamFlags: [Bool] = entries.map { entry in
            if case .file(let stream) = entry.kind { return stream }
            return false
        }
        let load: (Int) -> Void = { index in
            if streamFlags[index] { return }
            boxes[index].data = readEntire(paths[index])
        }
        if workers > 1 && entries.count > 1 {
            DispatchQueue.concurrentPerform(iterations: entries.count, execute: load)
        } else {
            for index in entries.indices { load(index) }
        }
        for (index, entry) in entries.enumerated() {
            if let data = boxes[index].data {
                emitFile(entry, data: data, into: &hasher)
            } else {
                streamFile(entry, into: &hasher)
            }
        }
    }

    /// Whole-file read. A failure or a short read becomes `Data(contentsOf:)`, which is what the serial hasher used,
    /// including the empty-body fallback when that also fails.
    private static func readEntire(_ path: String) -> Data {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return contentsOrEmpty(path) }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else {
            return contentsOrEmpty(path)
        }
        let size = Int(st.st_size)
        if size == 0 { return Data() }
        guard let data = readExactly(fd, size) else { return contentsOrEmpty(path) }
        return data
    }

    private static func readExactly(_ fd: Int32, _ size: Int) -> Data? {
        var data = Data(count: size)
        var offset = 0
        let failed = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < size {
                let n = read(fd, base.advanced(by: offset), size - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return true
                }
                if n == 0 { return true }
                offset += n
            }
            return false
        }
        if failed || offset != size { return nil }
        return data
    }

    private static func contentsOrEmpty(_ path: String) -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    }

    private static func emitFile(_ entry: Entry, data: Data, into hasher: inout SHA256Digest.Hasher) {
        hasher.update("f \(entry.mode) \(entry.relative)\n")
        hasher.update("bytes \(data.count)\n")
        hasher.update(data)
        hasher.update("\n")
    }

    /// Stream a regular file in 1 MiB chunks. The header has to name the byte count first, so the count is the
    /// on-disk size. If the read does not deliver exactly that many bytes, the hasher is rewound and the file is
    /// taken the same way as the serial implementation (`Data(contentsOf:)` or empty).
    private static func streamFile(_ entry: Entry, into hasher: inout SHA256Digest.Hasher) {
        let saved = hasher.checkpoint()
        let fd = open(entry.path, O_RDONLY)
        if fd < 0 {
            emitFile(entry, data: contentsOrEmpty(entry.path), into: &hasher)
            return
        }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else {
            emitFile(entry, data: contentsOrEmpty(entry.path), into: &hasher)
            return
        }
        let size = UInt64(st.st_size)
        hasher.update("f \(entry.mode) \(entry.relative)\n")
        hasher.update("bytes \(size)\n")
        var buffer = [UInt8](repeating: 0, count: streamAbove)
        var left = size
        var failed = false
        while left > 0 {
            let want = Int(min(UInt64(buffer.count), left))
            let n: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                while true {
                    let count = read(fd, base, want)
                    if count < 0 && errno == EINTR { continue }
                    return count
                }
            }
            if n <= 0 {
                failed = true
                break
            }
            buffer.withUnsafeBytes { raw in
                hasher.update(UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
            }
            left -= UInt64(n)
        }
        if failed || left != 0 {
            hasher.restore(saved)
            emitFile(entry, data: contentsOrEmpty(entry.path), into: &hasher)
            return
        }
        hasher.update("\n")
    }
}
