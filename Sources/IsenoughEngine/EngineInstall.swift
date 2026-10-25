import Foundation

/// Copy of the `isenough` CLI kept at `<stateDir>/bin/isenough`.
///
/// Stubs used to bake `CommandLine.arguments[0]` into `stub.json`. A pack from
/// `~/code/256isenough/.build/.../isenough` then kept execing that path, including
/// after it had been replaced by an older build. `init`, `pack`, `launch`, and
/// `install-engine` refresh this copy and write `isenough.stamp`. The stub tries
/// the copy before the baked path. `revision` moves when the CLI gains behavior
/// the previous binary does not have; the `0.1.0` version string alone does not.
public enum EngineInstall {
    public static let version = "0.1.0"
    /// 1 was the pre-streaming-hash CLI. 2 is the copy installed beside the stamp.
    public static let revision = 2

    public static func binary(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("bin/isenough")
    }

    public static func stampFile(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("bin/isenough.stamp")
    }

    public static func runningExecutable() -> URL {
        if let bundled = Bundle.main.executableURL {
            return bundled.resolvingSymlinksInPath()
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
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".isenough-install-\(UUID().uuidString)")
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
        let stampURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().appendingPathComponent("isenough.stamp")
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
