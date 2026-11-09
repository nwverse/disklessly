import Foundation

/// Which images still need an icon, and where the bytes should come from.
/// Attaching a disk image and rendering a PNG stay on macOS.
public enum IconBackfill {
    public struct Candidate: Equatable {
        public var imageId: String
        public var bundleId: String
        public var name: String
        public var mode: String
        public var originalPath: String

        public init(imageId: String, bundleId: String, name: String, mode: String, originalPath: String) {
            self.imageId = imageId
            self.bundleId = bundleId
            self.name = name
            self.mode = mode
            self.originalPath = originalPath
        }
    }

    public enum Source: Equatable {
        /// A PNG is already in the state-dir cache. Nothing is extracted.
        case cached
        /// Restore mode and the real app is on disk.
        case onDiskApp(String)
        /// Mount mode, or restore mode whose app is gone. Attach this DMG read-only.
        case diskImage(String)
        case unavailable(String)
    }

    public struct Job: Equatable {
        public var imageId: String
        public var bundleId: String
        public var stubPath: String?
        public var source: Source
        /// The shared repo does not yet have `icons/<id>.png`. Publishing stays write-once.
        public var publishRepo: Bool

        public init(imageId: String, bundleId: String, stubPath: String?, source: Source, publishRepo: Bool) {
            self.imageId = imageId
            self.bundleId = bundleId
            self.stubPath = stubPath
            self.source = source
            self.publishRepo = publishRepo
        }
    }

    public static func doctorHint(missing: Int) -> String? {
        guard missing > 0 else { return nil }
        return "\(missing) apps have no icon: run disklessly icons backfill"
    }

    public static func plan(
        candidates: [Candidate],
        only: String?,
        cacheExists: (String) -> Bool,
        repoIconExists: (String) -> Bool,
        isRealApp: (String) -> Bool,
        cachedImagePath: (String) -> String?,
        localImagePath: (String) -> String?,
        stubPath: (Candidate) -> String?
    ) -> [Job] {
        var jobs: [Job] = []
        for candidate in candidates {
            if let only, !matches(candidate, only) { continue }
            let publish = !repoIconExists(candidate.imageId)
            if cacheExists(candidate.imageId) {
                jobs.append(Job(imageId: candidate.imageId, bundleId: candidate.bundleId, stubPath: stubPath(candidate), source: .cached, publishRepo: publish))
                continue
            }
            if candidate.mode == "restore", isRealApp(candidate.originalPath) {
                jobs.append(Job(imageId: candidate.imageId, bundleId: candidate.bundleId, stubPath: stubPath(candidate), source: .onDiskApp(candidate.originalPath), publishRepo: publish))
                continue
            }
            if let image = cachedImagePath(candidate.imageId) ?? localImagePath(candidate.imageId) {
                jobs.append(Job(imageId: candidate.imageId, bundleId: candidate.bundleId, stubPath: stubPath(candidate), source: .diskImage(image), publishRepo: publish))
                continue
            }
            jobs.append(Job(imageId: candidate.imageId, bundleId: candidate.bundleId, stubPath: stubPath(candidate), source: .unavailable("no local app or disk image"), publishRepo: publish))
        }
        return jobs
    }

    private static func matches(_ candidate: Candidate, _ only: String) -> Bool {
        if candidate.imageId == only || candidate.bundleId == only { return true }
        return candidate.name.caseInsensitiveCompare(only) == .orderedSame || candidate.bundleId.caseInsensitiveCompare(only) == .orderedSame
    }
}

public struct IconsArguments: Equatable {
    public var app: String?
    /// `icons refresh`: rebuild every stub's icon from the cached PNG, with the cloud badge.
    public var refresh: Bool

    public init(app: String?, refresh: Bool = false) {
        self.app = app
        self.refresh = refresh
    }

    public static func parse(_ args: [String]) throws -> IconsArguments {
        guard let command = args.first else { throw DisklesslyError.usage("icons requires backfill or refresh") }
        guard command == "backfill" || command == "refresh" else { throw DisklesslyError.usage("Unknown icons command: \(command)") }
        var rest = Array(args.dropFirst())
        var app: String?
        while let flag = rest.first {
            rest.removeFirst()
            switch flag {
            case "--app":
                guard command == "backfill" else { throw DisklesslyError.usage("icons refresh applies to every stub and does not take --app") }
                guard let value = rest.first, !value.hasPrefix("-") else { throw DisklesslyError.usage("icons backfill --app requires an id") }
                rest.removeFirst()
                app = value
            default:
                throw DisklesslyError.usage(flag.hasPrefix("-") ? "Unknown option: \(flag)" : "icons \(command) does not take a positional argument: \(flag)")
            }
        }
        return IconsArguments(app: app, refresh: command == "refresh")
    }
}
