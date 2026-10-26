import Foundation

/// One image file in the repo, as far as local iCloud copies are concerned.
/// Tests build these directly. The macOS probe fills them from URL resource values.
public struct MaterialFile: Equatable {
    public var relativePath: String
    public var logicalBytes: UInt64
    public var allocatedBytes: UInt64
    public var ubiquitous: Bool
    public var uploaded: Bool
    public var uploading: Bool
    public var uploadFailed: Bool
    public var pinned: Bool
    public var dataless: Bool
    /// Mounted, running, detaching, or in an open restore.
    public var inUse: Bool
    /// When set and still in the future, this Mac may need the repo bytes before detach.
    public var protectedUntil: Date?

    public init(relativePath: String, logicalBytes: UInt64, allocatedBytes: UInt64, ubiquitous: Bool, uploaded: Bool, uploading: Bool, uploadFailed: Bool, pinned: Bool, dataless: Bool, inUse: Bool, protectedUntil: Date?) {
        self.relativePath = relativePath
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.ubiquitous = ubiquitous
        self.uploaded = uploaded
        self.uploading = uploading
        self.uploadFailed = uploadFailed
        self.pinned = pinned
        self.dataless = dataless
        self.inUse = inUse
        self.protectedUntil = protectedUntil
    }

    public var imageId: String {
        let base = (relativePath as NSString).lastPathComponent
        return (base as NSString).deletingPathExtension
    }
}

public enum LocalEvictChoice: Equatable {
    case evict
    case retryLater(String)
    case skip(String)
}

public struct LocalEvictPlan: Equatable {
    public var evict: [String]
    public var retryLater: [String]
    public var skipped: [String]
    public init(evict: [String], retryLater: [String], skipped: [String]) {
        self.evict = evict
        self.retryLater = retryLater
        self.skipped = skipped
    }
}

public struct MaterialSummary: Equatable {
    public var status: String
    public var detail: String
    public var localBytes: UInt64
    public var logicalBytes: UInt64
    public init(status: String, detail: String, localBytes: UInt64, logicalBytes: UInt64) {
        self.status = status
        self.detail = detail
        self.localBytes = localBytes
        self.logicalBytes = logicalBytes
    }
}

public enum UbiquityEvictOutcome: Equatable {
    case evicted
    case retryLater(String)
}

public struct LocalEvictReport: Equatable {
    public var evicted: [String]
    public var retryLater: [String]
    public var skipped: [String]
    public init(evicted: [String], retryLater: [String], skipped: [String]) {
        self.evicted = evicted
        self.retryLater = retryLater
        self.skipped = skipped
    }
}

public enum LocalEviction {
    /// An open restore, or a detach deadline that has not arrived, still needs the image.
    public static func protects(phase: RestorePhase, outcome: String?, detachAfter: Date?, now: Date) -> (inUse: Bool, until: Date?) {
        let until = detachAfter.flatMap { $0 > now ? $0 : nil }
        let terminal = phase == .disposed || phase == .retired || phase == .closed
        let inUse = !terminal && (outcome == nil || outcome?.isEmpty == true)
        return (inUse, until)
    }

    /// Never selects a file whose upload is unfinished. "Cannot evict yet" is `retryLater`, not a failure.
    public static func decide(_ file: MaterialFile, now: Date) -> LocalEvictChoice {
        guard file.ubiquitous else { return .skip("not in iCloud") }
        if file.dataless || (file.allocatedBytes == 0 && file.logicalBytes > 0) {
            return .skip("already evicted")
        }
        if file.inUse { return .skip("in use on this Mac") }
        if let until = file.protectedUntil, now < until {
            return .skip("needed until the detach delay elapses")
        }
        if file.uploading || file.uploadFailed || !file.uploaded {
            return .retryLater("upload is not finished")
        }
        if file.pinned { return .skip("kept downloaded on this Mac") }
        return .evict
    }

    public static func plan(_ files: [MaterialFile], now: Date) -> LocalEvictPlan {
        var evict: [String] = []
        var retryLater: [String] = []
        var skipped: [String] = []
        for file in files {
            switch decide(file, now: now) {
            case .evict:
                evict.append(file.relativePath)
            case .retryLater(let reason):
                retryLater.append("\(file.relativePath): \(reason)")
            case .skip(let reason):
                skipped.append("\(file.relativePath): \(reason)")
            }
        }
        return LocalEvictPlan(evict: evict, retryLater: retryLater, skipped: skipped)
    }

    public static func summarize(_ files: [MaterialFile], repoLooksLikeICloud: Bool) -> MaterialSummary {
        let cloud = files.filter(\.ubiquitous)
        let logical = cloud.reduce(UInt64(0)) { $0 + $1.logicalBytes }
        let local = cloud.reduce(UInt64(0)) { total, file in
            if file.dataless { return total }
            return total + file.allocatedBytes
        }
        if cloud.isEmpty && !repoLooksLikeICloud {
            return MaterialSummary(status: "ok", detail: "repository is not in iCloud Drive", localBytes: 0, logicalBytes: 0)
        }
        if local == 0 {
            let detail = logical == 0 ? "iCloud copies are dataless" : "iCloud copies are dataless (\(RecommendFormatting.byteText(logical)) in the repo)"
            return MaterialSummary(status: "ok", detail: detail, localBytes: 0, logicalBytes: logical)
        }
        let detail = "iCloud keeps full copies: repo occupies \(RecommendFormatting.byteText(local)) locally of \(RecommendFormatting.byteText(logical))"
        return MaterialSummary(status: "warn", detail: detail, localBytes: local, logicalBytes: logical)
    }
}
