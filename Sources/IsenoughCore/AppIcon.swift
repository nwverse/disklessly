import Foundation

/// Icon names and cache locations that do not need AppKit. macOS capture lives in the engine.
public enum AppIcon {
    public struct PlistKeys: Equatable {
        public var file: String?
        public var name: String?
        public init(file: String?, name: String?) {
            self.file = file
            self.name = name
        }
    }

    /// `CFBundleIconFile` and `CFBundleIconName`, with blank strings treated as absent.
    public static func plistKeys(_ info: [String: Any]) -> PlistKeys {
        PlistKeys(file: text(info["CFBundleIconFile"]), name: text(info["CFBundleIconName"]))
    }

    /// `CFBundleIconFile` often omits `.icns`. The returned name always includes it.
    public static func icnsFileName(_ fileKey: String) -> String {
        let trimmed = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".icns") { return trimmed }
        return trimmed + ".icns"
    }

    /// Where an `CFBundleIconFile` value lives inside a bundle.
    public static func icnsURL(app: URL, fileKey: String) -> URL? {
        let name = icnsFileName(fileKey)
        let resources = app.appendingPathComponent("Contents/Resources")
        let candidates = [
            resources.appendingPathComponent(name),
            app.appendingPathComponent("Contents").appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func isSafeImageId(_ imageId: String) -> Bool {
        guard !imageId.isEmpty, imageId.count < 256, !imageId.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+")
        return imageId.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `/api/icon/<id>` after percent-decoding. Nil when the id could escape the cache directory.
    public static func imageId(apiPath: String) -> String? {
        let prefix = "/api/icon/"
        guard apiPath.hasPrefix(prefix) else { return nil }
        let raw = String(apiPath.dropFirst(prefix.count))
        guard !raw.isEmpty, !raw.contains("/"), let decoded = raw.removingPercentEncoding, isSafeImageId(decoded) else { return nil }
        return decoded
    }

    public static func cacheURL(stateDir: String, imageId: String) -> URL? {
        guard isSafeImageId(imageId) else { return nil }
        return URL(fileURLWithPath: stateDir, isDirectory: true)
            .appendingPathComponent("icons", isDirectory: true)
            .appendingPathComponent(imageId + ".png")
    }

    public static func repoRelativePath(imageId: String) -> String? {
        guard isSafeImageId(imageId) else { return nil }
        return "icons/\(imageId).png"
    }

    /// State-dir cache when that file exists, otherwise the shared repo copy.
    public static func existingPath(stateDir: String, repoPath: String, imageId: String) -> String? {
        if let cache = cacheURL(stateDir: stateDir, imageId: imageId), FileManager.default.fileExists(atPath: cache.path) {
            return cache.path
        }
        guard let relative = repoRelativePath(imageId: imageId) else { return nil }
        let repo = URL(fileURLWithPath: repoPath, isDirectory: true).appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: repo.path) ? repo.path : nil
    }

    /// Cached PNG, then the repo copy, then a generic PNG. Never throws.
    public static func png(stateDir: String, repoPath: String, imageId: String) -> Data {
        for url in candidateFiles(stateDir: stateDir, repoPath: repoPath, imageId: imageId) {
            if let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024, data.starts(with: pngMagic) {
                return data
            }
        }
        return genericPNG
    }

    /// 1×1 PNG used when no app icon is cached.
    public static let genericPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==") ?? Data()

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])

    private static func candidateFiles(stateDir: String, repoPath: String, imageId: String) -> [URL] {
        var urls: [URL] = []
        if let cache = cacheURL(stateDir: stateDir, imageId: imageId) { urls.append(cache) }
        if let relative = repoRelativePath(imageId: imageId) {
            urls.append(URL(fileURLWithPath: repoPath, isDirectory: true).appendingPathComponent(relative))
        }
        return urls
    }

    private static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
