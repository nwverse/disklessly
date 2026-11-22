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
            _ = try pack(bundle.appPath)
        }
        for path in bundle.paths {
            let source = URL(fileURLWithPath: path)
            let placeholder = FilePlaceholder.placeholderURL(for: source)
            if FileManager.default.fileExists(atPath: placeholder.path) { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) {
                if isDir.boolValue, Self.isColdLink(source, stateDir: config.stateDir) { continue }
                _ = try offloadFile(path, progress: progress, onBytes: onBytes)
            }
        }
    }

    /// Brings back every offloaded linked path and unpacks the app bundle when it is a stub.
    public func restoreLinkedBundle(id: String, progress: (String) -> Void = { _ in }) throws {
        guard let bundle = linkedBundleStore.bundle(id: id) else {
            throw DisklesslyError.usage("unknown linked bundle \(id)")
        }
        for path in bundle.paths {
            let placeholder = FilePlaceholder.placeholderURL(for: URL(fileURLWithPath: path))
            if FileManager.default.fileExists(atPath: placeholder.path) {
                _ = try fetchFile(placeholder.path, progress: progress)
            }
        }
        let appURL = URL(fileURLWithPath: bundle.appPath)
        if FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/stub.json").path),
           let manifest = (try? list())?.first(where: { $0.app.originalPath == bundle.appPath || $0.name.lowercased() == bundle.name.lowercased() }) {
            progress("unpack")
            _ = try unpack(manifest)
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
