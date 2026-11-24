import Foundation
import DisklesslyCore

extension DisklesslyEngine {
    public var linkedBundleStore: LinkedBundleStore { LinkedBundleStore(stateDir: config.stateDir) }

    /// Packs the app (when it is still a real bundle on disk) and offloads every linked path that is still local.
    public func offloadLinkedBundle(
        id: String,
        progress: (String) -> Void = { _ in },
        onBytes: (UInt64, UInt64) -> Void = { _, _ in }
    ) throws {
        guard let bundle = linkedBundleStore.bundle(id: id) else {
            throw DisklesslyError.usage("unknown linked bundle \(id)")
        }
        let appURL = URL(fileURLWithPath: bundle.appPath)
        if FileManager.default.fileExists(atPath: appURL.path),
           !FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/stub.json").path) {
            progress("pack")
            try withoutActuallyEscaping(onBytes) { escOnBytes in
                _ = try pack(bundle.appPath, progress: progress, onBytes: { done, total in
                    escOnBytes(done, total)
                })
            }
        }
        var pendingPaths: [String] = []
        for path in bundle.paths {
            let source = URL(fileURLWithPath: path)
            let placeholder = FilePlaceholder.placeholderURL(for: source)
            if FileManager.default.fileExists(atPath: placeholder.path) { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) {
                if isDir.boolValue, Self.isColdLink(source, stateDir: config.stateDir) { continue }
                pendingPaths.append(path)
            }
        }
        if pendingPaths.count <= 1 {
            if let path = pendingPaths.first {
                _ = try offloadFile(path, progress: progress, onBytes: onBytes)
            }
            return
        }
        let progressLock = NSLock()
        try withoutActuallyEscaping(onBytes) { escOnBytes in
            let tracker = LinkedByteTracker(onBytes: escOnBytes)
            try Self.runConcurrentPaths(pendingPaths, maxConcurrent: 2) { path in
                _ = try self.offloadFile(path, progress: { phase in
                    progressLock.lock(); defer { progressLock.unlock() }
                    progress(phase)
                }, onBytes: { done, total in
                    tracker.update(path: path, done: done, total: total)
                })
            }
        }
    }

    /// Brings back every offloaded linked path and unpacks the app bundle when it is a stub.
    public func restoreLinkedBundle(id: String, progress: (String) -> Void = { _ in }) throws {
        guard let bundle = linkedBundleStore.bundle(id: id) else {
            throw DisklesslyError.usage("unknown linked bundle \(id)")
        }
        let placeholders = bundle.paths.compactMap { path -> String? in
            let placeholder = FilePlaceholder.placeholderURL(for: URL(fileURLWithPath: path))
            return FileManager.default.fileExists(atPath: placeholder.path) ? placeholder.path : nil
        }
        if placeholders.count <= 1 {
            if let placeholderPath = placeholders.first {
                _ = try fetchFile(placeholderPath, progress: progress)
            }
        } else {
            let progressLock = NSLock()
            try Self.runConcurrentPaths(placeholders, maxConcurrent: 2) { placeholderPath in
                _ = try self.fetchFile(placeholderPath, progress: { phase in
                    progressLock.lock(); defer { progressLock.unlock() }
                    progress(phase)
                })
            }
        }
        let appURL = URL(fileURLWithPath: bundle.appPath)
        if FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/stub.json").path),
           let manifest = (try? list())?.first(where: { $0.app.originalPath == bundle.appPath || $0.name.lowercased() == bundle.name.lowercased() }) {
            progress("unpack")
            _ = try unpack(manifest)
        }
    }

    private static func runConcurrentPaths(_ paths: [String], maxConcurrent: Int, _ body: (String) throws -> Void) throws {
        try withoutActuallyEscaping(body) { work in
            let group = DispatchGroup()
            let sem = DispatchSemaphore(value: max(1, maxConcurrent))
            let state = LinkedErrorBox()
            for path in paths {
                if state.error != nil { break }
                sem.wait()
                if state.error != nil { sem.signal(); break }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { sem.signal(); group.leave() }
                    if state.error != nil { return }
                    do { try work(path) } catch { state.set(error) }
                }
            }
            group.wait()
            if let err = state.error { throw err }
        }
    }

    private final class LinkedErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
    }

    private final class LinkedByteTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (done: UInt64, total: UInt64)] = [:]
        private let onBytes: (UInt64, UInt64) -> Void
        init(onBytes: @escaping (UInt64, UInt64) -> Void) { self.onBytes = onBytes }
        func update(path: String, done: UInt64, total: UInt64) {
            lock.lock()
            entries[path] = (done, max(done, total))
            var sumDone: UInt64 = 0, sumTotal: UInt64 = 0
            for item in entries.values {
                sumDone += item.done
                sumTotal += item.total
            }
            lock.unlock()
            onBytes(sumDone, sumTotal)
        }
    }

    /// Called before launching an offloaded app so any linked folders/files are brought back first.
    func restoreLinkedPathsIfNeeded(forAppPath appPath: String) throws {
        guard let bundle = linkedBundleStore.bundle(forAppPath: appPath) else { return }
        for path in bundle.paths {
            let placeholder = FilePlaceholder.placeholderURL(for: URL(fileURLWithPath: path))
            if FileManager.default.fileExists(atPath: placeholder.path) {
                _ = try fetchFile(placeholder.path)
            }
        }
    }
}
