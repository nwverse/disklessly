import Foundation
import DisklesslyCore

/// One cache folder of an offloaded app and what it holds.
public struct AppCacheFolder: Equatable {
    public var path: String
    public var bytes: UInt64
    public init(path: String, bytes: UInt64) { self.path = path; self.bytes = bytes }
}

/// The cache folders found for one offloaded app.
public struct AppCacheEntry: Equatable {
    public var name: String
    public var bundleId: String
    public var imageId: String
    public var folders: [AppCacheFolder]
    /// Set when the app runs (or is otherwise busy); its caches are left alone.
    public var refusal: String?
    public var bytes: UInt64 { folders.reduce(0) { $0 + $1.bytes } }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "name": name, "bundleId": bundleId, "imageId": imageId, "bytes": NSNumber(value: bytes),
            "folders": folders.map { ["path": $0.path, "bytes": NSNumber(value: $0.bytes)] as [String: Any] },
        ]
        if let refusal { object["refused"] = refusal }
        return object
    }
}

/// What `disklessly caches` found, and with `--apply` what it removed.
public struct AppCacheReport: Equatable {
    public var applied: Bool
    public var entries: [AppCacheEntry]
    /// Bytes actually freed (apply) or that would be freed (dry run), refused apps excluded.
    public var freedBytes: UInt64
    public var failed: [String] = []

    public func jsonObject() -> [String: Any] {
        ["ok": failed.isEmpty, "applied": applied, "freedBytes": NSNumber(value: freedBytes), "apps": entries.map { $0.jsonObject() }, "failed": failed]
    }

    public var text: String {
        let found = entries.filter { !$0.folders.isEmpty }
        guard !found.isEmpty else { return "No caches found for offloaded apps." }
        var lines: [String] = []
        for entry in found {
            let size = RecommendFormatting.byteText(entry.bytes)
            if let refusal = entry.refusal { lines.append("\(entry.name): \(size), skipped (\(refusal))") }
            else { lines.append("\(entry.name): \(size)\(applied ? " cleared" : "")") }
            for folder in entry.folders { lines.append("  \(folder.path)") }
        }
        lines += failed.map { "failed: \($0)" }
        let total = RecommendFormatting.byteText(freedBytes)
        lines.append(applied ? "Freed \(total)." : "Would free \(total). Run `disklessly caches --apply` to clear them.")
        return lines.joined(separator: "\n")
    }
}

/// Finds and clears the caches of offloaded apps. Only cache folders: Application
/// Support and the data of a sandbox container are never touched.
public enum AppCaches {
    /// A name usable as one path component under `~/Library/Caches`. Rejects
    /// anything that could reach outside it or name the whole folder.
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && name.trimmingCharacters(in: .whitespaces) == name
    }

    /// The folders that may hold the app's caches, in a fixed order, whether or not they exist:
    /// `~/Library/Caches/<bundleId>`, `~/Library/Caches/<name>`, and the sandbox
    /// container's `Data/Library/Caches`.
    public static func candidates(bundleId: String, name: String, home: String) -> [String] {
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library")
        let caches = library.appendingPathComponent("Caches")
        var paths: [String] = []
        for key in [bundleId, name] where isSafeComponent(key) {
            let path = caches.appendingPathComponent(key).path
            if !paths.contains(path) { paths.append(path) }
        }
        if isSafeComponent(bundleId) {
            paths.append(library.appendingPathComponent("Containers").appendingPathComponent(bundleId).appendingPathComponent("Data/Library/Caches").path)
        }
        return paths
    }

    /// Existing, readable cache folders and their allocated size. A symlink is
    /// never followed: whatever it points at is not the app's cache folder.
    public static func folders(bundleId: String, name: String, home: String, fileManager: FileManager = .default) -> [AppCacheFolder] {
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library").path
        return candidates(bundleId: bundleId, name: name, home: home).compactMap { path in
            guard isRealDirectory(path, below: library, fileManager: fileManager), fileManager.isReadableFile(atPath: path),
                  (try? fileManager.contentsOfDirectory(atPath: path)) != nil else { return nil }
            let bytes = size(of: path, fileManager: fileManager)
            return bytes > 0 ? AppCacheFolder(path: path, bytes: bytes) : nil
        }
    }

    /// Every component from `~/Library` down must be a real folder, so a link
    /// planted at `Caches/<id>`, `Containers/<id>` or `Data/Library` cannot redirect the delete.
    static func isRealDirectory(_ path: String, below library: String, fileManager: FileManager) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path != library {
            // attributesOfItem does not follow a final link: a link reports .typeSymbolicLink.
            guard url.path.hasPrefix(library + "/"),
                  let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
                  type == .typeDirectory else { return false }
            url.deleteLastPathComponent()
        }
        return true
    }

    /// Allocated bytes under `path`, links not followed.
    static func size(of path: String, fileManager: FileManager) -> UInt64 {
        guard let walker = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            total += UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Empties the folder and keeps it, with its owner and permissions, so a
    /// sandboxed app finds its container layout unchanged. Returns paths it could not remove.
    static func empty(_ path: String, fileManager: FileManager) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: path) else { return [path] }
        var failed: [String] = []
        for name in names {
            let child = URL(fileURLWithPath: path).appendingPathComponent(name).path
            do { try fileManager.removeItem(atPath: child) } catch { failed.append(child) }
        }
        return failed
    }
}

extension DisklesslyEngine {
    /// Why an offloaded app's caches must stay: it runs, its image is attached for
    /// a launch, or a restore of it is still open. Nil when they can be cleared.
    public func cacheClearRefusal(_ manifest: ImageManifest) -> String? {
        if let probe = appRunningOverride {
            if probe(manifest) { return "\(manifest.name) is running; quit it first" }
        }
        if let state = StateStore(config.stateDir).load().apps[manifest.bundleId]?.state, state == "running" || state == "detaching" {
            return "\(manifest.name) is running; quit it first"
        }
        if let reason = restore.blockReason(appId: manifest.bundleId) { return reason }
        if appRunningOverride == nil, liveAppRunning(manifest) { return "\(manifest.name) is running; quit it first" }
        return nil
    }

    /// Any process running the app's executable: from its mount, its restored
    /// bundle, or wherever `<name>.app` was copied.
    private func liveAppRunning(_ manifest: ImageManifest) -> Bool {
        let mount = URL(fileURLWithPath: config.mountRoot).appendingPathComponent(manifest.imageId).path
        if ProcessProbe.usage(roots: [mount, manifest.app.originalPath]) == .busy { return true }
        guard !manifest.app.executable.isEmpty else { return false }
        let needle = "/\(manifest.name).app/Contents/MacOS/\(manifest.app.executable)"
        let rows = ProcessProbe.parse(ProcessRunner.capture("/bin/ps", ["-ax", "-o", "pid=,ppid=,command="]))
        return rows.contains { $0.command.contains(needle) && !ProcessProbe.isOwnTool($0.command) }
    }

    /// Finds the caches of every offloaded app and, with `apply`, empties the
    /// folders of the apps that are not running. Never touches Application Support
    /// or a container's data outside `Data/Library/Caches`.
    public func clearAppCaches(apply: Bool, home: String = NSHomeDirectory(), fileManager: FileManager = .default) throws -> AppCacheReport {
        // Only apps replaced by a stub on this Mac: a shared repo also lists apps
        // another Mac offloaded that may be installed and in use here.
        let offloaded = try offloadedOverride?() ?? offloadedBundleIds()
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library").path
        var seen: Set<String> = []
        var entries: [AppCacheEntry] = []
        for manifest in try list() where offloaded.contains(manifest.bundleId) && seen.insert(manifest.bundleId).inserted {
            let folders = AppCaches.folders(bundleId: manifest.bundleId, name: manifest.name, home: home, fileManager: fileManager)
            let refusal = folders.isEmpty ? nil : cacheClearRefusal(manifest)
            entries.append(AppCacheEntry(name: manifest.name, bundleId: manifest.bundleId, imageId: manifest.imageId, folders: folders, refusal: refusal))
        }
        entries.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        var report = AppCacheReport(applied: apply, entries: entries, freedBytes: 0)
        for entry in entries where entry.refusal == nil && !entry.folders.isEmpty {
            guard apply else { report.freedBytes += entry.bytes; continue }
            // Under the app lock, and re-checked, so a launch cannot start mid-clear.
            try restore.withLock(entry.bundleId) {
                guard let manifest = try list().first(where: { $0.imageId == entry.imageId }), cacheClearRefusal(manifest) == nil else {
                    if let index = report.entries.firstIndex(of: entry) { report.entries[index].refusal = "\(entry.name) started; skipped" }
                    return
                }
                for folder in entry.folders {
                    // Checked again under the lock: a folder swapped for a link since the scan is left alone.
                    guard AppCaches.isRealDirectory(folder.path, below: library, fileManager: fileManager) else {
                        report.failed.append(folder.path)
                        continue
                    }
                    let failed = AppCaches.empty(folder.path, fileManager: fileManager)
                    report.failed += failed
                    report.freedBytes += failed.isEmpty ? folder.bytes : folder.bytes &- min(folder.bytes, AppCaches.size(of: folder.path, fileManager: fileManager))
                }
            }
        }
        return report
    }
}
