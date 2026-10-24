import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct ShareSpec: Equatable {
    public var kind: String
    public var host: String
    public var share: String
    public var user: String?
    public var mountPoint: String
    public var alreadyMounted: Bool
    public init(kind: String, host: String, share: String, user: String?, mountPoint: String, alreadyMounted: Bool) {
        self.kind = kind
        self.host = host
        self.share = share
        self.user = user
        self.mountPoint = mountPoint
        self.alreadyMounted = alreadyMounted
    }
}

public struct ShareMountCommand: Equatable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
    public var rendered: String { ([executable] + arguments).joined(separator: " ") }
}

public struct ShareOpener {
    public var isMounted: (String) -> Bool
    public var run: (ShareMountCommand) throws -> Void
    public init(isMounted: @escaping (String) -> Bool, run: @escaping (ShareMountCommand) throws -> Void) {
        self.isMounted = isMounted
        self.run = run
    }

    /// macOS: `stat -f %T` (a format code, not a sentence) with a 3s cap.
    /// Linux treats an existing directory as the stand-in for an already-mounted share
    /// and refuses to spawn mount_smbfs/mount_nfs.
    public static let system = ShareOpener(
        isMounted: { path in
            #if os(macOS)
            guard let kind = ShareMount.liveFilesystemType(path) else { return false }
            return kind == "smbfs" || kind == "nfs" || kind == "webdav"
            #else
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            #endif
        },
        run: { command in
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch {
                throw IsenoughError.backend("Could not start \(command.rendered): \(error.localizedDescription)")
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw IsenoughError.backend("Command failed: \(command.rendered) (exit \(process.terminationStatus))")
            }
            #else
            throw IsenoughError.unsupported("mounting SMB/NFS requires macOS (\(command.rendered))")
            #endif
        }
    )
}

public enum ShareMount {
    public static func validate(user: String?, host: String, share: String) throws {
        if let user, user.contains(":") {
            throw IsenoughError.usage("SMB user must not include a password; store it in the Keychain")
        }
        for (label, value) in [("host", host), ("share", share)] {
            if value.isEmpty || value.contains(" ") || value.contains("@") {
                throw IsenoughError.usage("Invalid \(label)")
            }
        }
    }

    /// `nil` when the share is already mounted. The password is never an argument.
    /// SMB uses `mount_smbfs -N` so the tool reads the Keychain instead of prompting.
    /// There is no `--noautoopen` equivalent; this is a volume mount, not a disk image.
    public static func command(_ spec: ShareSpec) -> ShareMountCommand? {
        if spec.alreadyMounted { return nil }
        switch spec.kind {
        case "smb":
            let user = spec.user ?? "guest"
            let remote = "//\(user)@\(spec.host)/\(spec.share)"
            return ShareMountCommand(executable: "/sbin/mount_smbfs", arguments: ["-N", remote, spec.mountPoint])
        case "nfs":
            let remote = "\(spec.host):\(spec.share)"
            return ShareMountCommand(executable: "/sbin/mount_nfs", arguments: [remote, spec.mountPoint])
        default:
            return nil
        }
    }

    /// `stat -f %T` prints a filesystem type name such as `smbfs`. Anything else, including
    /// a translated sentence, is not a mounted share. Non-zero exit is not mounted.
    public static func filesystemType(statExit: Int32, statStdout: String) -> String? {
        guard statExit == 0 else { return nil }
        let value = statStdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "smbfs", "nfs", "webdav": return value
        default: return nil
        }
    }

    #if os(macOS)
    static func liveFilesystemType(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        process.arguments = ["-f", "%T", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return filesystemType(statExit: process.terminationStatus, statStdout: text)
    }
    #endif
}

/// A directory that is the mounted share (or a temp dir standing in for one).
/// Eviction of the local cache must not call `delete` on the share root.
public struct MountedShareBackend: StorageBackend {
    public let root: URL
    public var probe: () throws -> Bool
    private let folder: LocalFolderBackend

    public init(root: URL, probe: @escaping () throws -> Bool = { true }) throws {
        self.root = root.standardizedFileURL
        self.probe = probe
        self.folder = try LocalFolderBackend(root: root)
    }

    private func online() throws {
        guard try probe() else { throw IsenoughError.backend("share is offline or not mounted at \(root.path)") }
    }

    public func list(_ path: String) throws -> [String] { try online(); return try folder.list(path) }
    public func stat(_ path: String) throws -> BackendStat? { try online(); return try folder.stat(path) }
    public func get(_ path: String, range: Range<UInt64>?) throws -> Data { try online(); return try folder.get(path, range: range) }
    public func put(_ path: String, data: Data) throws { try online(); try folder.put(path, data: data) }
    public func put(_ path: String, file: URL) throws { try online(); try folder.put(path, file: file) }
    public func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody { try online(); return try folder.getResumable(path, offset: offset) }
    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile { try online(); return try folder.download(path, to: destination, offset: offset) }
    public func localRoot() -> URL? { root }
    public func ensureCollection(_ path: String) throws { try online(); try folder.ensureCollection(path) }

    public func delete(_ path: String) throws {
        try online()
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "." {
            throw IsenoughError.usage("refusing to delete the share root")
        }
        try folder.delete(path)
    }
}

public enum CacheEviction {
    /// Removes a local cache file and checks that the remote object is still there.
    public static func evictLocal(cacheFile: URL, remoteStillPresent: () throws -> Bool) throws {
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            try FileManager.default.removeItem(at: cacheFile)
        }
        guard try remoteStillPresent() else {
            throw IsenoughError.failure("eviction removed the remote object")
        }
    }
}
