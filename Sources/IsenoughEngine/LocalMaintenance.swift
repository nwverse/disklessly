import Foundation
import IsenoughCore
#if canImport(Darwin)
import Darwin
#endif

extension IsenoughEngine {
    public func materialFiles(now: Date = Date()) -> [MaterialFile] {
        if let materialFilesOverride { return materialFilesOverride }
        #if os(macOS)
        return LiveMaterialProbe.collect(config: config, now: now)
        #else
        return DiskMaterialProbe.files(repoPath: config.repoPath)
        #endif
    }

    public func materialSummary(now: Date = Date()) -> MaterialSummary {
        let files = materialFiles(now: now)
        let icloud = ICloudFolderBackend.looksLikeICloud(URL(fileURLWithPath: config.repoPath)) || files.contains(where: \.ubiquitous)
        return LocalEviction.summarize(files, repoLooksLikeICloud: icloud)
    }

    /// Drop local bytes of iCloud images that are fully uploaded and not needed on this Mac.
    /// A file that is still uploading, or that the system will not evict, is reported and left in place.
    public func evictLocalCopies(now: Date = Date()) -> LocalEvictReport {
        try? ensureDevice(now: now)
        let files = materialFiles(now: now)
        let plan = LocalEviction.plan(files, now: now)
        let chosen = Set(plan.evict)
        var evicted: [String] = []
        var retryLater = plan.retryLater
        for file in files where chosen.contains(file.relativePath) {
            switch performEvict(file) {
            case .evicted:
                evicted.append(file.relativePath)
            case .retryLater(let reason):
                retryLater.append("\(file.relativePath): \(reason)")
            }
        }
        return LocalEvictReport(evicted: evicted, retryLater: retryLater, skipped: plan.skipped)
    }

    func finishPublished(_ published: PublishResult, stubWarning: String?) -> PublishResult {
        var warnings: [String] = []
        if let stubWarning { warnings.append(stubWarning) }
        let eviction = evictLocalCopies()
        warnings.append(contentsOf: eviction.retryLater)
        return PublishResult(manifest: published.manifest, reused: published.reused, uploaded: published.uploaded, warnings: warnings, evicted: eviction.evicted, originalKept: published.originalKept)
    }

    /// Remove verified `.isenough-original-` backups. One remover call covers every path.
    public func cleanupBackups(roots: [URL]? = nil, remover: (([String]) throws -> Void)? = nil) throws -> BackupCleanupReport {
        try? ensureDevice()
        let facts: [BackupFact]
        if let backupFactsOverride {
            facts = backupFactsOverride
        } else {
            let search = roots ?? BackupScanner.defaultRoots(stubDir: config.stubDir, home: NSHomeDirectory())
            facts = BackupScanner.facts(roots: search, repoPath: config.repoPath)
        }
        var remove: [String] = []
        var kept: [String] = []
        for fact in facts {
            switch BackupCleanup.decide(fact) {
            case .remove:
                remove.append(fact.path)
            case .keep(let reason):
                kept.append("\(fact.path): \(reason)")
            }
        }
        if !remove.isEmpty {
            if let remover {
                try remover(remove)
            } else {
                try AdminShell.remove(remove)
            }
        }
        return BackupCleanupReport(removed: remove, kept: kept)
    }

    private func performEvict(_ file: MaterialFile) -> UbiquityEvictOutcome {
        if let ubiquityEvictor { return ubiquityEvictor(file) }
        #if os(macOS)
        return LiveMaterialProbe.evict(file, repoPath: config.repoPath)
        #else
        return .retryLater("cannot evict yet")
        #endif
    }
}

enum DiskMaterialProbe {
    static func files(repoPath: String) -> [MaterialFile] {
        let images = URL(fileURLWithPath: repoPath).appendingPathComponent("images")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: images.path) else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".dmg"), !RepoFileNames.isPlaceholder(name), !RepoFileNames.isConflictCopy(name) else { return nil }
            let url = images.appendingPathComponent(name)
            let logical = (try? ChunkedIO.byteCount(url)) ?? 0
            return MaterialFile(relativePath: "images/\(name)", logicalBytes: logical, allocatedBytes: logical, ubiquitous: false, uploaded: false, uploading: false, uploadFailed: false, pinned: false, dataless: false, inUse: false, protectedUntil: nil)
        }
    }
}

#if os(macOS)
enum LiveMaterialProbe {
    static func collect(config: RuntimeConfig, now: Date) -> [MaterialFile] {
        let root = URL(fileURLWithPath: config.repoPath)
        let images = root.appendingPathComponent("images")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: images.path) else { return [] }
        let usage = usageMap(config: config, now: now)
        let icloudRoot = ICloudFolderBackend.looksLikeICloud(root)
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".dmg"), !RepoFileNames.isPlaceholder(name), !RepoFileNames.isConflictCopy(name) else { return nil }
            let url = images.appendingPathComponent(name)
            let imageId = (name as NSString).deletingPathExtension
            return describe(url: url, relativePath: "images/\(name)", imageId: imageId, icloudRoot: icloudRoot, usage: usage)
        }
    }

    static func evict(_ file: MaterialFile, repoPath: String) -> UbiquityEvictOutcome {
        let url = URL(fileURLWithPath: repoPath).appendingPathComponent(file.relativePath)
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
        } catch {
            return .retryLater("cannot evict yet")
        }
        if stillMaterialized(url) {
            return .retryLater("cannot evict yet")
        }
        return .evicted
    }

    struct Usage {
        var inUse: Set<String>
        var until: [String: Date]
    }

    static func usageMap(config: RuntimeConfig, now: Date) -> Usage {
        var inUse = Set<String>()
        var until: [String: Date] = [:]
        let delay = TimeInterval(config.detachDelaySeconds)
        let apps = StateStore(config.stateDir).load().apps
        for item in apps.values {
            guard let imageId = item.imageId, !imageId.isEmpty else { continue }
            let name = item.state ?? ""
            if name == "running" || name == "detaching" { inUse.insert(imageId) }
            if let mount = item.mountPoint, !mount.isEmpty, FileManager.default.fileExists(atPath: mount) {
                inUse.insert(imageId)
            }
            if let used = item.lastUsed {
                let deadline = used.addingTimeInterval(delay)
                let cache = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(imageId).dmg")
                if deadline > now, !FileManager.default.fileExists(atPath: cache.path) {
                    until[imageId] = deadline
                }
            }
        }
        if !config.mountRoot.isEmpty, let mounts = try? FileManager.default.contentsOfDirectory(atPath: config.mountRoot) {
            for name in mounts where !name.hasPrefix(".") { inUse.insert(name) }
        }
        for journal in (try? JournalStore.loadAll(stateDir: config.stateDir)) ?? [] {
            let protection = LocalEviction.protects(phase: journal.phase, outcome: journal.outcome, detachAfter: journal.detachAfter, now: now)
            if protection.inUse { inUse.insert(journal.imageId) }
            if let deadline = protection.until {
                if let existing = until[journal.imageId], existing > deadline {
                    continue
                }
                until[journal.imageId] = deadline
            }
        }
        return Usage(inUse: inUse, until: until)
    }

    private static func describe(url: URL, relativePath: String, imageId: String, icloudRoot: Bool, usage: Usage) -> MaterialFile {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let fallback = (try? ChunkedIO.byteCount(url)) ?? 0
        guard let values else {
            return MaterialFile(relativePath: relativePath, logicalBytes: fallback, allocatedBytes: fallback, ubiquitous: icloudRoot, uploaded: false, uploading: false, uploadFailed: false, pinned: finderPinned(url), dataless: false, inUse: usage.inUse.contains(imageId), protectedUntil: usage.until[imageId], uploadKnown: false, uploadPercent: nil)
        }
        let ubiquitous = values.isUbiquitousItem == true
        let logical = UInt64(max(0, values.fileSize ?? Int(fallback)))
        let allocatedRaw = values.fileAllocatedSize.map { UInt64(max(0, $0)) } ?? logical
        let dataless = ubiquitous && (values.ubiquitousItemDownloadingStatus == .notDownloaded || (allocatedRaw == 0 && logical > 0))
        // A null NSURLUbiquitousItemIsUploadedKey is "not reported", not false.
        // Reading allValues keeps that distinction if the typed Bool is ever non-optional.
        let uploaded = optionalBool(values, .ubiquitousItemIsUploadedKey)
        let uploading = optionalBool(values, .ubiquitousItemIsUploadingKey)
        let failed = values.ubiquitousItemUploadingError != nil
        return MaterialFile(
            relativePath: relativePath,
            logicalBytes: logical,
            allocatedBytes: dataless ? 0 : allocatedRaw,
            ubiquitous: ubiquitous,
            uploaded: uploaded == true,
            uploading: uploading == true,
            uploadFailed: failed,
            pinned: finderPinned(url),
            dataless: dataless,
            inUse: usage.inUse.contains(imageId),
            protectedUntil: usage.until[imageId],
            uploadKnown: uploaded != nil || uploading != nil || failed,
            uploadPercent: uploadPercent(of: url)
        )
    }

    private static func optionalBool(_ values: URLResourceValues, _ key: URLResourceKey) -> Bool? {
        guard let raw = values.allValues[key] else { return nil }
        if raw is NSNull { return nil }
        if let number = raw as? NSNumber { return number.boolValue }
        if let flag = raw as? Bool { return flag }
        return nil
    }

    /// Percent is read on its own. A missing key must not fail the upload-state read above.
    /// `NSURLUbiquitousItemPercentUploadedKey` is not a typed property on every SDK, so the
    /// raw resource key (and the NSMetadata name for the same percentage) are requested directly.
    private static func uploadPercent(of url: URL) -> Double? {
        let keys: Set<URLResourceKey> = [
            URLResourceKey(rawValue: "NSURLUbiquitousItemPercentUploadedKey"),
            URLResourceKey(rawValue: "NSMetadataUbiquitousItemPercentUploadedKey"),
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        for key in keys {
            guard let raw = values.allValues[key] else { continue }
            if let number = raw as? NSNumber { return number.doubleValue }
            if let number = raw as? Double { return number }
        }
        return nil
    }

    private static func stillMaterialized(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return false }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded { return false }
        let logical = values.fileSize ?? 0
        let allocated = values.fileAllocatedSize ?? logical
        return allocated > 0 && logical > 0
    }

    private static func finderPinned(_ url: URL) -> Bool {
        url.path.withCString { path in
            "com.apple.fileprovider.pinned".withCString { name in
                getxattr(path, name, nil, 0, 0, 0) >= 0
            }
        }
    }
}
#endif
