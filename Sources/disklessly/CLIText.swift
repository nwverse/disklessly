import Foundation
import DisklesslyCore
import DisklesslyEngine

/// Human-readable output for commands run without `--json`.
/// Every string here is for people. Scripts should pass `--json`.
enum CLIText {
    static func size(_ bytes: UInt64) -> String { RecommendFormatting.byteText(bytes) }

    static func initialized(_ config: RuntimeConfig, platform: HostPlatform = .current) -> String {
        if platform == .linux {
            return """
            Initialized Disklessly.
              repo:   \(config.repoPath) (\(config.backend))
              state:  \(config.stateDir)
            Next: disklessly sessions
            """
        }
        return """
        Initialized Disklessly.
          repo:   \(config.repoPath) (\(config.backend))
          cache:  \(config.cacheDir), quota \(size(config.quotaBytes))
          stubs:  \(config.stubDir)
        Next: disklessly recommend
        """
    }

    static func packed(_ published: PublishResult, appPath: String, stubDir: String, noStub: Bool, keepOriginal: Bool) -> String {
        let m = published.manifest
        let appName = URL(fileURLWithPath: appPath).lastPathComponent
        var lines = ["Packed \(m.name) \(m.version) (\(size(m.image.size)), \(m.mode.rawValue) mode)"]
        if published.reused {
            lines.append("  image:    \(m.imageId), reused from the repo, nothing uploaded")
        } else if published.uploaded {
            lines.append("  image:    \(m.imageId), uploaded to the repo")
        } else {
            lines.append("  image:    \(m.imageId)")
        }
        let stub = URL(fileURLWithPath: stubDir).appendingPathComponent(appName).path
        if noStub {
            lines.append("  stub:     not installed (--no-stub)")
            lines.append("  original: left in place at \(appPath)")
        } else if let kept = published.originalKept {
            lines.append("  stub:     \(stub)")
            let retained = URL(fileURLWithPath: stubDir).appendingPathComponent(URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent + ".256orig.app").path
            lines.append("  original: kept at \(retained) (\(kept))")
        } else if keepOriginal {
            lines.append("  stub:     \(stub)")
            let retained = URL(fileURLWithPath: stubDir).appendingPathComponent(URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent + ".256orig.app").path
            lines.append("  original: kept at \(retained) (--keep-original)")
        } else {
            lines.append("  stub:     \(stub)")
            lines.append("  original: removed; the verified image in the repo is the copy now")
        }
        for warning in published.warnings { lines.append("  warning:  \(warning)") }
        lines.append("Open \(appName) as usual, or run: disklessly launch \(m.bundleId)")
        return lines.joined(separator: "\n")
    }

    static func launched(_ manifest: ImageManifest, wait: Bool, restore: Bool) -> String {
        if !wait { return "Started \(manifest.name). The watcher keeps running after this command exits." }
        return restore ? "\(manifest.name) quit and was put back in the repo." : "Opened \(manifest.name)."
    }

    static func prefetched(_ manifest: ImageManifest, path: String) -> String {
        "Cached \(manifest.name) \(manifest.version) (\(size(manifest.image.size))) at \(path)"
    }

    static func pinned(_ manifest: ImageManifest, pinned: Bool) -> String {
        pinned
            ? "Pinned \(manifest.name). Its image stays in the cache and gc will not evict it."
            : "Unpinned \(manifest.name). The cache may evict its image when space runs low."
    }

    static func licenseStatus(_ state: LicenseState, offloaded: Int) -> String {
        let limit = License.freeAppLimit
        switch state {
        case .licensed(let p):
            var line = p.edition == "promo" ? "Promo license, valid until \(p.expires ?? "?"). Unlimited offloaded apps." : "Licensed. Unlimited offloaded apps."
            if let updates = p.updatesUntil { line += " Updates included until \(updates)." }
            if let email = p.email { line += "\nLicensed to \(email)." }
            return line + "\nOffloaded now: \(offloaded)."
        case .expired(let p):
            return "Your license code expired on \(p.expires ?? "an earlier date"). The free limit applies: \(offloaded) of \(limit) apps offloaded. Starting, restoring and unpacking keep working."
        case .invalid(let reason):
            return "The saved license code is not usable: \(reason). The free limit applies: \(offloaded) of \(limit) apps offloaded.\nRun `disklessly license deactivate`, then `disklessly license activate CODE`."
        case .free:
            return "Free version: \(offloaded) of \(limit) apps offloaded. Starting, restoring and unpacking offloaded apps is always free.\nTo offload more, run `disklessly license activate CODE`."
        }
    }

    static func licenseActivated(_ p: LicensePayload) -> String {
        p.edition == "promo" ? "License activated (promo, valid until \(p.expires ?? "?")). You can offload as many apps as you like." : "License activated. You can offload as many apps as you like."
    }

    static func licenseDictionary(_ state: LicenseState, offloaded: Int) -> [String: Any] {
        var d: [String: Any] = ["ok": true, "freeLimit": License.freeAppLimit, "offloaded": offloaded]
        switch state {
        case .free: d["state"] = "free"
        case .licensed(let p):
            d["state"] = "licensed"; d["edition"] = p.edition; d["licenseId"] = p.id
            if let e = p.expires { d["expires"] = e }
            if let u = p.updatesUntil { d["updatesUntil"] = u }
        case .expired(let p): d["state"] = "expired"; d["expires"] = p.expires ?? ""
        case .invalid(let reason): d["state"] = "invalid"; d["reason"] = reason
        }
        return d
    }

    static func evicted(_ manifest: ImageManifest) -> String {
        "Removed the cached image of \(manifest.name). The copy in the repo is untouched; the next launch downloads it again."
    }

    static func unpacked(_ manifest: ImageManifest, to directory: String?) -> String {
        if let directory {
            let target = URL(fileURLWithPath: directory).appendingPathComponent("\(manifest.name).app").path
            return "Copied \(manifest.name) \(manifest.version) to \(target). The stub stays installed."
        }
        return "Put \(manifest.name) \(manifest.version) back in place of its stub. The image stays in the repo."
    }

    static func status(_ config: RuntimeConfig, state: LocalState, app: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines: [String] = []
        // state.cache keeps records for evicted images; only count files still in the cache.
        let images = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images")
        let present = state.cache.filter { FileManager.default.fileExists(atPath: images.appendingPathComponent("\($0.key).dmg").path) }
        let used = present.values.reduce(UInt64(0)) { $0 + ($1.bytes ?? 0) }
        if app == nil {
            lines.append("repo:   \(config.repoPath) (\(config.backend))")
            lines.append("cache:  \(config.cacheDir), \(size(used)) of \(size(config.quotaBytes)) used, \(present.count) image\(present.count == 1 ? "" : "s")")
            lines.append("stubs:  \(config.stubDir)")
        }
        let apps = state.apps.filter { key, value in
            guard let app else { return true }
            return key.caseInsensitiveCompare(app) == .orderedSame || value.imageId == app
        }.sorted { $0.key < $1.key }
        if apps.isEmpty {
            lines.append(app.map { "no local state for \($0)" } ?? "apps:   none packed or launched on this Mac yet")
        } else {
            if app == nil { lines.append("apps:") }
            for (id, item) in apps {
                var parts = [id, item.state ?? "idle"]
                if item.pinned { parts.append("pinned") }
                if let mode = item.mode { parts.append(mode) }
                if let imageId = item.imageId, let bytes = present[imageId]?.bytes { parts.append("cached \(size(bytes))") }
                if let last = item.lastUsed { parts.append("last used \(formatter.string(from: last))") }
                if item.needsResolution != nil { parts.append("needs: disklessly resolve \(id)") }
                lines.append("  " + parts.joined(separator: "  "))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func gc(_ lines: [String]) -> String {
        lines.isEmpty ? "nothing to remove" : lines.joined(separator: "\n")
    }

    /// Names from the repo that look like `query`: a substring either way, or a small edit distance.
    static func suggestions(for query: String, in manifests: [ImageManifest], limit: Int = 3) -> [String] {
        let needle = query.lowercased().replacingOccurrences(of: ".app", with: "")
        guard !needle.isEmpty else { return [] }
        var scored: [(String, Int)] = []
        var seen = Set<String>()
        for manifest in manifests {
            for candidate in [manifest.name, manifest.bundleId] where !candidate.isEmpty {
                let lower = candidate.lowercased()
                let score: Int
                if lower.contains(needle) || needle.contains(lower) { score = 0 }
                else {
                    let distance = editDistance(needle, lower)
                    guard distance <= max(2, needle.count / 3) else { continue }
                    score = distance
                }
                if seen.insert(manifest.name).inserted { scored.append((manifest.name, score)) }
                break
            }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }

    static func unknownApp(_ name: String, suggestions: [String]) -> String {
        guard !suggestions.isEmpty else { return "Unknown app: \(name). Run disklessly list to see packed apps." }
        return "Unknown app: \(name). Did you mean: \(suggestions.joined(separator: ", "))?"
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }
}

/// Where `disklessly ui` finds the management page. `Bundle.module` traps when its
/// build-tree path is gone, so a copied release binary must not depend on it.
enum WebRoot {
    static func candidates(environment: [String: String], executable: URL) -> [URL] {
        var out: [URL] = []
        if let override = environment["DISKLESSLY_WEB_ROOT"], !override.isEmpty {
            out.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        let dir = executable.deletingLastPathComponent()
        let parent = dir.deletingLastPathComponent()
        out.append(parent.appendingPathComponent("Resources/web", isDirectory: true))
        out.append(parent.appendingPathComponent("share/disklessly/web", isDirectory: true))
        return out
    }

    static func resolve(environment: [String: String], executable: URL, fileManager: FileManager = .default) throws -> URL {
        let listed = candidates(environment: environment, executable: executable)
        if let override = environment["DISKLESSLY_WEB_ROOT"], !override.isEmpty,
           !fileManager.fileExists(atPath: URL(fileURLWithPath: override).appendingPathComponent("index.html").path) {
            throw DisklesslyError.usage("DISKLESSLY_WEB_ROOT has no index.html: \(override)")
        }
        if let found = listed.first(where: { fileManager.fileExists(atPath: $0.appendingPathComponent("index.html").path) }) {
            return found
        }
        // SwiftPM resource bundle next to a build-tree binary. Looked up by path, never through Bundle.module.
        let dir = executable.deletingLastPathComponent()
        for name in ["Disklessly_disklessly.bundle", "Disklessly_disklessly.resources"] {
            let url = dir.appendingPathComponent(name)
            if let bundle = Bundle(url: url), let web = bundle.url(forResource: "web", withExtension: nil),
               fileManager.fileExists(atPath: web.appendingPathComponent("index.html").path) {
                return web
            }
            let flat = url.appendingPathComponent("web", isDirectory: true)
            if fileManager.fileExists(atPath: flat.appendingPathComponent("index.html").path) { return flat }
        }
        let tried = listed.map(\.path) + [dir.appendingPathComponent("Disklessly_disklessly.bundle").path]
        throw DisklesslyError.failure("Cannot find the management page (index.html). Set DISKLESSLY_WEB_ROOT, or reinstall so web/ sits beside the binary. Looked in: \(tried.joined(separator: ", "))")
    }
}
