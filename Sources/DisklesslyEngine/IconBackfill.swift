import Foundation
import DisklesslyCore

public struct IconBackfillReport: Equatable {
    public var updated: [String]
    public var skipped: [String]
    public var warnings: [String]

    public init(updated: [String], skipped: [String], warnings: [String]) {
        self.updated = updated
        self.skipped = skipped
        self.warnings = warnings
    }
}

extension DisklesslyEngine {
    /// Images whose state-dir PNG is missing. Read-only.
    func missingIconCount() -> Int {
        guard let manifests = try? list() else { return 0 }
        return manifests.filter { manifest in
            AppIcon.existingPath(stateDir: config.stateDir, repoPath: config.repoPath, imageId: manifest.imageId) == nil
        }.count
    }

    /// Fills `<stateDir>/icons/<id>.png` and, once, `icons/<id>.png` in the repo.
    /// Does not register this Mac. On Linux, a job that needs an app or a disk image is unsupported.
    public func backfillIcons(appId: String?) throws -> IconBackfillReport {
        let manifests = try list()
        let candidates = manifests.map { manifest in
            IconBackfill.Candidate(
                imageId: manifest.imageId,
                bundleId: manifest.bundleId,
                name: manifest.name,
                mode: manifest.mode.rawValue,
                originalPath: manifest.app.originalPath
            )
        }
        let jobs = IconBackfill.plan(
            candidates: candidates,
            only: appId,
            cacheExists: { imageId in
                guard let cache = AppIcon.cacheURL(stateDir: self.config.stateDir, imageId: imageId) else { return false }
                return FileManager.default.fileExists(atPath: cache.path)
            },
            repoIconExists: { imageId in
                guard let relative = AppIcon.repoRelativePath(imageId: imageId) else { return false }
                let repo = URL(fileURLWithPath: self.config.repoPath, isDirectory: true).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: repo.path) { return true }
                return (try? self.repo.stat(relative)) != nil
            },
            isRealApp: isRealApp,
            cachedImagePath: cachedImagePath,
            localImagePath: localImagePath,
            stubPath: stubPath(for:)
        )
        var updated: [String] = []
        var skipped: [String] = []
        var warnings: [String] = []
        for job in jobs {
            switch job.source {
            case .cached:
                if job.publishRepo, let cache = AppIcon.cacheURL(stateDir: config.stateDir, imageId: job.imageId),
                   let data = try? Data(contentsOf: cache) {
                    publishIcon(job.imageId, data: data)
                }
                skipped.append(job.imageId)
            case .unavailable(let reason):
                warnings.append("\(job.imageId): \(reason)")
            case .onDiskApp, .diskImage:
                #if os(macOS)
                let note = applyIcon(job)
                if let note {
                    warnings.append(note)
                } else {
                    updated.append(job.imageId)
                }
                #else
                warnings.append("\(job.imageId): icon backfill requires macOS")
                #endif
            }
        }
        return IconBackfillReport(updated: updated, skipped: skipped, warnings: warnings)
    }

    private func isRealApp(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard url.pathExtension.lowercased() == "app" else { return false }
        return !FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/stub.json").path)
    }

    private func cachedImagePath(_ imageId: String) -> String? {
        let url = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(imageId).dmg")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    private func localImagePath(_ imageId: String) -> String? {
        guard let root = try? openBackend().localRoot() else { return nil }
        let url = root.appendingPathComponent("images/\(imageId).dmg")
        guard !url.lastPathComponent.hasPrefix(".") else { return nil }
        // An encrypted repo object is not a disk image; only the decrypted cache copy is.
        guard FileManager.default.fileExists(atPath: url.path), !ImageCrypto.looksSealed(url) else { return nil }
        return url.path
    }

    private func stubPath(for candidate: IconBackfill.Candidate) -> String? {
        let original = URL(fileURLWithPath: candidate.originalPath)
        if FileManager.default.fileExists(atPath: original.appendingPathComponent("Contents/Resources/stub.json").path) {
            return original.path
        }
        let named = URL(fileURLWithPath: config.stubDir).appendingPathComponent(original.deletingPathExtension().lastPathComponent + ".app")
        if FileManager.default.fileExists(atPath: named.appendingPathComponent("Contents/Resources/stub.json").path) {
            return named.path
        }
        return nil
    }

    #if os(macOS)
    /// Nil when the icon was stored. A string is a warning and this image is not listed as updated.
    private func applyIcon(_ job: IconBackfill.Job) -> String? {
        let app: URL
        switch job.source {
        case .onDiskApp(let path):
            app = URL(fileURLWithPath: path)
        case .diskImage(let path):
            // Keeps the orphan reaper off this mount while it is in use.
            var lease = MountLease.tryAcquire(stateDir: config.stateDir, name: ".icon-\(job.imageId)")
            defer { lease?.release() }
            guard let mounted = mountReadOnly(image: URL(fileURLWithPath: path), imageId: job.imageId) else {
                return "\(job.imageId): could not attach the disk image read-only"
            }
            defer { unmount(mounted) }
            guard let found = mountedApp(in: mounted) else {
                return "\(job.imageId): the disk image has no app"
            }
            app = found
            return storeIcon(from: app, job: job)
        case .cached, .unavailable:
            return nil
        }
        return storeIcon(from: app, job: job)
    }

    private func storeIcon(from app: URL, job: IconBackfill.Job) -> String? {
        let publish = { (data: Data) in
            if job.publishRepo { self.publishIcon(job.imageId, data: data) }
        }
        if let stubPath = job.stubPath {
            let stub = URL(fileURLWithPath: stubPath)
            StubIcon.capture(from: app, into: stub, imageId: job.imageId, stateDir: config.stateDir, publish: publish)
            let identity = SigningIdentity.resolve(configured: config.signIdentity, environment: ProcessInfo.processInfo.environment)
            do {
                try ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", identity, stub.path])
            } catch {
                return "\(job.imageId): codesign failed: \(error.localizedDescription)"
            }
            StubIcon.touch(stub)
            StubIcon.register(stub)
        } else {
            StubIcon.cacheOnly(from: app, imageId: job.imageId, stateDir: config.stateDir, publish: publish)
        }
        guard let cache = AppIcon.cacheURL(stateDir: config.stateDir, imageId: job.imageId),
              FileManager.default.fileExists(atPath: cache.path) else {
            return "\(job.imageId): icon was not cached"
        }
        return nil
    }

    private func mountReadOnly(image: URL, imageId: String) -> URL? {
        let mount = URL(fileURLWithPath: config.mountRoot).appendingPathComponent(".icon-\(imageId)")
        if FileManager.default.fileExists(atPath: mount.path) {
            try? LiveDiskImage.detach(mountPoint: mount, force: true)
            try? FileManager.default.removeItem(at: mount)
        }
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try LiveDiskImage.attach(image: image, mountPoint: mount)
            return mount
        } catch {
            try? LiveDiskImage.detach(mountPoint: mount, force: true)
            try? FileManager.default.removeItem(at: mount)
            FileHandle.standardError.write(Data("disklessly: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    private func unmount(_ mount: URL) {
        do {
            try LiveDiskImage.detach(mountPoint: mount, force: true)
        } catch {
            FileHandle.standardError.write(Data("disklessly: \(error.localizedDescription)\n".utf8))
        }
        try? FileManager.default.removeItem(at: mount)
    }

    private func mountedApp(in mount: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil) else { return nil }
        return children.first { $0.pathExtension.lowercased() == "app" }
    }
    #endif
}
