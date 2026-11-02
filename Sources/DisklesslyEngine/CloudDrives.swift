import Foundation
import DisklesslyCore

/// Cloud drives through the bundled rclone, with Disklessly's own rclone.conf under the state
/// dir. Connecting stores a backend; it never switches the active repo by itself.
public struct CloudDrives {
    public let stateDir: String
    public let binary: URL?

    public init(stateDir: String, binary: URL? = RcloneTool.locate()) {
        self.stateDir = stateDir
        self.binary = binary
    }

    public var configPath: String { RcloneTool.configPath(stateDir: stateDir) }

    func requireBinary() throws -> URL {
        guard let binary else { throw DisklesslyError.unsupported("rclone is not available; reinstall Disklessly or set DISKLESSLY_RCLONE") }
        return binary
    }

    public static func provider(_ id: String) -> (id: String, type: String, name: String, extra: [String])? {
        RcloneTool.providers.first { $0.id == id }
    }

    public func remotes() throws -> [String] {
        try RcloneTool.remotes(binary: try requireBinary(), config: configPath)
    }

    /// `gdrive`, then `gdrive-2`, ... whichever is free in Disklessly's rclone.conf.
    public static func freeName(_ base: String, taken: [String]) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Runs `rclone config create`, which opens the provider's sign-in page in the browser and
    /// waits for it (up to 10 minutes). Returns the backend to store.
    public func connect(provider id: String, name: String? = nil, root: String? = nil) throws -> BackendEndpoint {
        guard let provider = Self.provider(id) else {
            throw DisklesslyError.usage("unknown cloud drive: \(id) (use \(RcloneTool.providers.map(\.id).joined(separator: ", ")))")
        }
        let binary = try requireBinary()
        let taken = try remotes()
        let remote = name ?? Self.freeName(provider.id, taken: taken)
        guard RcloneTool.validRemoteName(remote) else { throw DisklesslyError.usage("a remote name may use letters, digits, - and _") }
        guard !taken.contains(remote) else { throw DisklesslyError.usage("a remote named \(remote) already exists; pick another --name") }
        try FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let result = try RcloneTool.run(binary: binary, config: configPath, ["config", "create", remote, provider.type] + RcloneTool.createArguments(provider: provider.id), timeout: 600)
        guard result.status == 0, try remotes().contains(remote) else {
            // A sign-in that timed out or was cancelled leaves a section without a token.
            _ = try? RcloneTool.run(binary: binary, config: configPath, ["config", "delete", remote])
            let reason = RcloneTool.lastLine(result.stderr)
            throw DisklesslyError.backend("could not connect \(provider.name)\(reason.isEmpty ? "" : ": \(reason)")")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        return try endpoint(remote: remote, root: root)
    }

    public func endpoint(remote: String, root: String? = nil) throws -> BackendEndpoint {
        var draft = BackendDraft(type: "rclone")
        draft.id = "rclone-\(remote)"
        draft.remote = remote
        draft.remoteRoot = root
        draft.configPath = configPath
        return try BackendCatalog.endpoint(from: draft)
    }

    /// Removes the remote from Disklessly's rclone.conf. The files on the drive stay.
    public func disconnect(_ remote: String) throws {
        let result = try RcloneTool.run(binary: try requireBinary(), config: configPath, ["config", "delete", remote])
        guard result.status == 0 else { throw DisklesslyError.backend("rclone config delete failed: \(RcloneTool.lastLine(result.stderr))") }
    }

    /// What the dashboard and `disklessly cloud list` show.
    public func listing(config: RuntimeConfig) -> [String: Any] {
        var object: [String: Any] = [
            "rclone": binary?.path ?? "",
            "bundledVersion": RcloneTool.bundledVersion,
            "providers": RcloneTool.providers.map { ["id": $0.id, "name": $0.name] },
            "activeBackendId": config.activeBackendId ?? "",
        ]
        if let binary { object["version"] = RcloneTool.version(binary: binary) ?? "" }
        var remotes: [[String: Any]] = []
        var names: [String] = []
        do { names = try binary == nil ? [] : self.remotes() } catch { object["error"] = (error as? DisklesslyError)?.errorDescription ?? String(describing: error) }
        for name in names {
            let backend = config.backends.first { $0.type == "rclone" && $0.remote == name }
            var row: [String: Any] = ["name": name, "type": remoteType(name) ?? ""]
            if let backend {
                row["backendId"] = backend.id
                row["root"] = backend.root
                row["active"] = backend.id == config.activeBackendId
            }
            remotes.append(row)
        }
        object["remotes"] = remotes
        return object
    }

    /// The `type = ...` line of `[name]` in rclone.conf.
    func remoteType(_ name: String) -> String? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        var inSection = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[\(name)]"; continue }
            if inSection, line.hasPrefix("type") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }
}

extension DisklesslyEngine {
    /// Creates the repo layout on the active backend (what `init` does), for a backend just
    /// switched to.
    public func prepareRepo() throws {
        let backend = try repo
        if let root = backend.localRoot() {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try RepoIdentity.ensure(backend)
        for p in ["images", "manifests", "catalog", "devices", "trash"] { try backend.ensureCollection(p) }
    }

    /// Apps offloaded from this Mac (in its local state). Switching the repo leaves their
    /// launchers pointing at images the new repo does not have.
    public func appsOnActiveRepo() -> [String] {
        let apps = StateStore(config.stateDir).load().dictionary()["apps"] as? [String: Any] ?? [:]
        return apps.keys.sorted()
    }
}

/// Runs one long cloud task at a time (connect a drive, install OpenList) off the request thread.
public final class CloudTaskRunner {
    private let lock = NSLock()
    private var current: [String: Any] = [:]

    public init() {}

    /// False when a task is already running.
    public func start(_ action: String, work: @escaping (_ progress: @escaping (String) -> Void) throws -> [String: Any]) -> Bool {
        lock.lock()
        if current["state"] as? String == "running" { lock.unlock(); return false }
        current = ["action": action, "state": "running"]
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            var result: [String: Any] = ["action": action]
            do {
                let extra = try work { phase in
                    self?.lock.lock(); self?.current["phase"] = phase; self?.lock.unlock()
                }
                result.merge(extra) { $1 }
                result["state"] = "done"
            } catch {
                result["state"] = "failed"
                result["message"] = (error as? DisklesslyError)?.errorDescription ?? String(describing: error)
            }
            self?.lock.lock(); self?.current = result; self?.lock.unlock()
        }
        return true
    }

    public func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}
