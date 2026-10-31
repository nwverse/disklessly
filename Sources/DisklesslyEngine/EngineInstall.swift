import Foundation

/// Copy of the `disklessly` CLI kept at `<stateDir>/bin/disklessly`.
///
/// Stubs used to bake `CommandLine.arguments[0]` into `stub.json`. A pack from
/// `~/code/Disklessly/.build/.../disklessly` then kept execing that path, including
/// after it had been replaced by an older build. `init`, `pack`, `launch`, and
/// `install-engine` refresh this copy and write `disklessly.stamp`. The stub tries
/// the copy before the baked path. `revision` moves when the CLI gains behavior
/// the previous binary does not have; the `0.1.0` version string alone does not.
public enum EngineInstall {
    // scripts/gen-version.sh rewrites the lines between the BEGIN/END markers for
    // release builds. Checked-in values describe an unstamped development build.
    // BEGIN GENERATED VERSION
    public static let version = "0.1.0"
    public static let commit = "unknown"
    public static let buildDate = "unknown"
    // END GENERATED VERSION
    /// Slice of the running binary. A universal binary reports the slice that is executing.
    public static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
    /// 1 was the pre-streaming-hash CLI. 2 is the copy installed beside the stamp.
    public static let revision = 2

    public static func binary(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("bin/disklessly")
    }

    public static func stampFile(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("bin/disklessly.stamp")
    }

    public static func runningExecutable() -> URL {
        if let bundled = Bundle.main.executableURL {
            let resolved = bundled.resolvingSymlinksInPath()
            // Inside Disklessly.app the main executable is the menu-bar app. The
            // engine is the `disklessly` CLI shipped next to it in Contents/MacOS.
            if Bundle.main.bundleURL.pathExtension == "app", resolved.lastPathComponent != "disklessly" {
                let cli = resolved.deletingLastPathComponent().appendingPathComponent("disklessly")
                if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
            }
            return resolved
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    /// Copy `source` into the stable location and write the stamp.
    /// The running stable binary is not copied over itself; the stamp is refreshed.
    @discardableResult
    public static func install(stateDir: String, source: URL, fileManager: FileManager = .default) throws -> URL {
        let dest = binary(stateDir: stateDir)
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let destPath = dest.standardizedFileURL.path
        if sourcePath != destPath {
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".disklessly-install-\(UUID().uuidString)")
            if fileManager.fileExists(atPath: tmp.path) { try fileManager.removeItem(at: tmp) }
            try fileManager.copyItem(at: source, to: tmp)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
            try fileManager.moveItem(at: tmp, to: dest)
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        let stamp: [String: Any] = ["version": version, "revision": revision]
        let data = try JSONSerialization.data(withJSONObject: stamp, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stampFile(stateDir: stateDir), options: .atomic)
        return dest
    }

    public enum Freshness: Equatable {
        case current
        case missing
        case older(String)
    }

    public static func freshness(at binaryPath: String, fileManager: FileManager = .default) -> Freshness {
        guard fileManager.isExecutableFile(atPath: binaryPath) else {
            return .missing
        }
        let stampURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().appendingPathComponent("disklessly.stamp")
        guard let data = try? Data(contentsOf: stampURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .older("\(binaryPath) has no engine stamp and is older than \(version) revision \(revision)")
        }
        let installedRevision = object["revision"] as? Int ?? 0
        let installedVersion = object["version"] as? String ?? ""
        if installedRevision < revision || versionIsOlder(installedVersion, version) {
            return .older("\(binaryPath) is \(installedVersion.isEmpty ? "unversioned" : installedVersion) revision \(installedRevision); this CLI is \(version) revision \(revision)")
        }
        return .current
    }

    static func versionIsOlder(_ installed: String, _ current: String) -> Bool {
        let lhs = installed.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
