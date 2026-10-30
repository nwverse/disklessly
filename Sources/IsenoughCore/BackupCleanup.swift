import Foundation

/// Facts gathered before any backup is deleted. The decision does not touch the filesystem.
public struct BackupFact: Equatable {
    public var path: String
    public var bundleId: String
    /// SHA-256 recorded in the installed stub's manifest. Nil when no single stub matches.
    public var stubSHA: String?
    /// SHA-256 recorded in the repo manifest for that image.
    public var repoSHA: String?
    /// SHA-256 of the local image bytes, when they could be read. Nil for a dataless copy.
    public var imageSHA: String?
    public var imageObjectExists: Bool

    public init(path: String, bundleId: String, stubSHA: String?, repoSHA: String?, imageSHA: String?, imageObjectExists: Bool) {
        self.path = path
        self.bundleId = bundleId
        self.stubSHA = stubSHA
        self.repoSHA = repoSHA
        self.imageSHA = imageSHA
        self.imageObjectExists = imageObjectExists
    }
}

public enum BackupDecision: Equatable {
    case remove
    case keep(String)
}

public struct BackupCleanupReport: Equatable {
    public var removed: [String]
    public var kept: [String]
    public init(removed: [String], kept: [String]) {
        self.removed = removed
        self.kept = kept
    }
}

public enum BackupCleanup {
    public static func decide(_ fact: BackupFact) -> BackupDecision {
        guard fact.path.hasPrefix("/"), !fact.path.contains("\n"), !fact.path.contains("\u{0}") else {
            return .keep("path is not a single absolute path")
        }
        guard fact.path.contains(".isenough-original-") else {
            return .keep("not an isenough original backup")
        }
        guard let stubSHA = fact.stubSHA, !stubSHA.isEmpty else {
            return .keep("no stub for this backup")
        }
        guard let repoSHA = fact.repoSHA, !repoSHA.isEmpty else {
            return .keep("no repo manifest for the stub image")
        }
        guard stubSHA == repoSHA else {
            return .keep("stub manifest does not match the repo image")
        }
        guard fact.imageObjectExists else {
            return .keep("repo image is missing")
        }
        if let imageSHA = fact.imageSHA, imageSHA != stubSHA {
            return .keep("image sha does not match the stub")
        }
        return .remove
    }
}

public enum BackupRemoval {
    /// The stub and the image are already in place. Failing to delete the backup is not a failed pack.
    public static func warning(backupPath: String) -> String {
        "Stub installed, but the original backup could not be removed (it may be owned by root): \(backupPath). Run `isenough cleanup-backups` to remove leftover backups with one administrator prompt."
    }
}

/// One macOS administrator prompt for every verified backup. The script never carries a password.
public enum AdminShell {
    public static func appleScript(removing paths: [String]) -> String {
        let quoted = paths.map { "quoted form of \(appleString($0))" }.joined(separator: " & \" \" & ")
        return "do shell script \"rm -rf -- \" & \(quoted) with administrator privileges"
    }

    /// An AppleScript string literal. Backslashes and quotes are escaped. The result is not a shell word.
    public static func appleString(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public static func remove(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        for path in paths where !path.hasPrefix("/") || path.contains("\n") || path.contains("\u{0}") {
            throw IsenoughError.usage("refusing to remove a backup path that is not a single absolute path")
        }
        let script = appleScript(removing: paths)
        #if os(macOS)
        let process = ParsedCommand.process(path: "/usr/bin/osascript", arguments: ["-e", script])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw IsenoughError.failure("could not start the administrator prompt")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IsenoughError.failure("administrator removal did not complete (osascript exit \(process.terminationStatus)). The backups were left in place.")
        }
        #else
        _ = script
        throw IsenoughError.unsupported("cleanup-backups removes root-owned backups with a macOS administrator prompt")
        #endif
    }
}

public enum BackupScanner {
    public static func defaultRoots(stubDir: String, home: String) -> [URL] {
        var seen = Set<String>()
        var roots: [URL] = []
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: stubDir, isDirectory: true),
        ]
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, path != "/", seen.insert(path).inserted else { continue }
            roots.append(url.standardizedFileURL)
        }
        return roots
    }

    public static func facts(roots: [URL], repoPath: String) -> [BackupFact] {
        var facts: [BackupFact] = []
        for root in roots {
            let rootReal = root.resolvingSymlinksInPath().standardizedFileURL.path
            for backup in RecommendPaths.leftoverBackups(in: root) where isOriginalBackup(backup) {
                let real = backup.resolvingSymlinksInPath().standardizedFileURL
                let prefix = rootReal.hasSuffix("/") ? rootReal : rootReal + "/"
                guard real.path == rootReal || real.path.hasPrefix(prefix) else { continue }
                facts.append(fact(backup: real, root: root, repoPath: repoPath))
            }
        }
        return facts
    }

    private static func isOriginalBackup(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix(".isenough-original-") && name.hasSuffix(".app")
    }

    private static func fact(backup: URL, root: URL, repoPath: String) -> BackupFact {
        let bundleId = bundleIdentifier(backup) ?? ""
        let match = stubMatch(bundleId: bundleId, root: root, ignoring: backup)
        let repoSHA = match.flatMap { manifestSHA(imageId: $0.imageId, repoPath: repoPath) }
        let image = match.flatMap { imageState(imageId: $0.imageId, repoPath: repoPath) }
        return BackupFact(
            path: backup.path,
            bundleId: bundleId,
            stubSHA: match?.sha,
            repoSHA: repoSHA,
            imageSHA: image?.sha,
            imageObjectExists: image?.exists == true
        )
    }

    private static func bundleIdentifier(_ app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        let identifier = info["CFBundleIdentifier"] as? String
        return identifier?.isEmpty == false ? identifier : nil
    }

    private struct StubMatch {
        var sha: String
        var imageId: String
    }

    private static func stubMatch(bundleId: String, root: URL, ignoring backup: URL) -> StubMatch? {
        guard !bundleId.isEmpty else { return nil }
        let apps = RecommendPaths.topLevelApps(in: root).filter { $0.standardizedFileURL.path != backup.standardizedFileURL.path }
        var matches: [StubMatch] = []
        for app in apps {
            guard let object = jsonObject(app.appendingPathComponent("Contents/Resources/stub.json")),
                  object["appId"] as? String == bundleId,
                  let manifest = jsonObject(app.appendingPathComponent("Contents/Resources/manifest.json")),
                  let image = manifest["image"] as? [String: Any],
                  let sha = image["sha256"] as? String, !sha.isEmpty,
                  let imageId = manifest["imageId"] as? String, !imageId.isEmpty,
                  manifest["bundleId"] as? String == bundleId else { continue }
            matches.append(StubMatch(sha: sha, imageId: imageId))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func manifestSHA(imageId: String, repoPath: String) -> String? {
        let url = URL(fileURLWithPath: repoPath).appendingPathComponent("manifests/\(imageId).json")
        guard let data = try? Data(contentsOf: url, options: []), let manifest = try? ImageManifest.decode(data) else { return nil }
        return manifest.image.sha256
    }

    private struct ImageState {
        var exists: Bool
        var sha: String?
    }

    private static func imageState(imageId: String, repoPath: String) -> ImageState {
        let images = URL(fileURLWithPath: repoPath).appendingPathComponent("images")
        let file = images.appendingPathComponent("\(imageId).dmg")
        let placeholders = [
            images.appendingPathComponent("\(imageId).dmg.icloud"),
            images.appendingPathComponent(".\(imageId).dmg.icloud"),
        ]
        if FileManager.default.fileExists(atPath: file.path) {
            let bytes = (try? ChunkedIO.byteCount(file)) ?? 0
            if bytes > 0, let sha = try? SHA256Digest.hexFile(file) {
                return ImageState(exists: true, sha: sha)
            }
            return ImageState(exists: true, sha: nil)
        }
        if placeholders.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return ImageState(exists: true, sha: nil)
        }
        return ImageState(exists: false, sha: nil)
    }

    private static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: []) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
