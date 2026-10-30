import Foundation

/// Facts gathered before any backup is deleted. The decision does not touch the filesystem.
public struct BackupFact: Equatable {
    public var path: String
    public var bundleId: String
    /// SHA-256 recorded in the installed stub's manifest. Nil when no single stub matches.
    public var stubSHA: String?
    /// SHA-256 recorded in the repo manifest for that image.
    public var repoSHA: String?
    /// SHA-256 of the local image bytes, when they could be read. Nil when the
    /// image is empty, could not be hashed, or is a dataless iCloud copy. Nil is
    /// never treated as verified.
    public var imageSHA: String?
    public var imageObjectExists: Bool
    /// The image is an iCloud placeholder (`.icloud` file or dataless item).
    public var imagePlaceholder: Bool
    /// Size the placeholder reports for the cloud copy, when known.
    public var placeholderSize: UInt64?
    /// Image size recorded in the repo manifest.
    public var repoSize: UInt64?

    public init(path: String, bundleId: String, stubSHA: String?, repoSHA: String?, imageSHA: String?, imageObjectExists: Bool, imagePlaceholder: Bool = false, placeholderSize: UInt64? = nil, repoSize: UInt64? = nil) {
        self.path = path
        self.bundleId = bundleId
        self.stubSHA = stubSHA
        self.repoSHA = repoSHA
        self.imageSHA = imageSHA
        self.imageObjectExists = imageObjectExists
        self.imagePlaceholder = imagePlaceholder
        self.placeholderSize = placeholderSize
        self.repoSize = repoSize
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
        if let imageSHA = fact.imageSHA {
            guard imageSHA == stubSHA else { return .keep("image sha does not match the stub") }
            return .remove
        }
        // No hash: a 0-byte DMG, a read failure, or an iCloud placeholder. Only a
        // placeholder whose cloud size equals the manifest size counts, which is
        // the rule PublishPlanner uses before it lets a pack drop the original.
        if fact.imagePlaceholder, let size = fact.placeholderSize, let expected = fact.repoSize, size > 0, size == expected {
            return .remove
        }
        return .keep(unverifiedReason)
    }

    public static let unverifiedReason = "kept: image unverified (the repo image is empty, unreadable, or an iCloud placeholder whose size does not match the manifest)"
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
        let repo = match.flatMap { manifestImage(imageId: $0.imageId, repoPath: repoPath) }
        let image = match.flatMap { imageState(imageId: $0.imageId, repoPath: repoPath) }
        return BackupFact(
            path: backup.path,
            bundleId: bundleId,
            stubSHA: match?.sha,
            repoSHA: repo?.sha256,
            imageSHA: image?.sha,
            imageObjectExists: image?.exists == true,
            imagePlaceholder: image?.placeholder == true,
            placeholderSize: image?.placeholderSize,
            repoSize: repo?.size
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

    private static func manifestImage(imageId: String, repoPath: String) -> ImageManifest.Image? {
        let url = URL(fileURLWithPath: repoPath).appendingPathComponent("manifests/\(imageId).json")
        guard let data = try? Data(contentsOf: url, options: []), let manifest = try? ImageManifest.decode(data) else { return nil }
        return manifest.image
    }

    private struct ImageState {
        var exists: Bool
        var sha: String?
        var placeholder: Bool = false
        var placeholderSize: UInt64?
    }

    private static func imageState(imageId: String, repoPath: String) -> ImageState {
        let images = URL(fileURLWithPath: repoPath).appendingPathComponent("images")
        let file = images.appendingPathComponent("\(imageId).dmg")
        let placeholders = [
            images.appendingPathComponent("\(imageId).dmg.icloud"),
            images.appendingPathComponent(".\(imageId).dmg.icloud"),
        ]
        if FileManager.default.fileExists(atPath: file.path) {
            #if os(macOS)
            if let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]),
               values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                // Dataless: hashing would download the image, so report the cloud size instead.
                return ImageState(exists: true, sha: nil, placeholder: true, placeholderSize: values.fileSize.map { UInt64(max(0, $0)) })
            }
            #endif
            let bytes = (try? ChunkedIO.byteCount(file)) ?? 0
            if bytes > 0, let sha = try? SHA256Digest.hexFile(file) {
                return ImageState(exists: true, sha: sha)
            }
            // 0 bytes or unreadable: exists, but unverified.
            return ImageState(exists: true, sha: nil)
        }
        if let stub = placeholders.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return ImageState(exists: true, sha: nil, placeholder: true, placeholderSize: placeholderSize(stub))
        }
        return ImageState(exists: false, sha: nil)
    }

    /// `.icloud` placeholder files are small property lists that carry the cloud
    /// copy's size under `NSURLFileSizeKey`.
    static func placeholderSize(_ url: URL) -> UInt64? {
        guard let data = try? ChunkedIO.prefix(url, maxBytes: 64 * 1024),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        if let number = plist["NSURLFileSizeKey"] as? NSNumber { return number.uint64Value }
        if let number = plist["NSURLFileSizeKey"] as? Int, number >= 0 { return UInt64(number) }
        return nil
    }

    private static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: []) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
