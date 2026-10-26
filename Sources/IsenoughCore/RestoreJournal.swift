import Foundation

public enum RestorePhase: String, Codable, CaseIterable, Equatable {
    case prepared, extracted, stubParked, installed, active
    case quiesced, inspected, appMoved, stubBack, disposed, retired, closed

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public var isRestoreOut: Bool { index >= RestorePhase.quiesced.index }
}

public struct InspectionSnapshot: Codable, Equatable {
    public var cdhash: String
    public var treeHash: String
    public var bundleId: String
    public var changed: Bool
    public var inode: InodeId?
    /// Stat-only tree digest recorded with this snapshot. Nil on older journals.
    public var fingerprint: String?
    public init(cdhash: String, treeHash: String, bundleId: String, changed: Bool, inode: InodeId? = nil, fingerprint: String? = nil) {
        self.cdhash = cdhash; self.treeHash = treeHash; self.bundleId = bundleId; self.changed = changed; self.inode = inode; self.fingerprint = fingerprint
    }
}

public struct ResolutionSnapshot: Codable, Equatable {
    public var retainedPath: String
    public var treeHash: String
    public var cdhash: String
    public var bundleId: String
    public var fromImageId: String
    public var txid: String
    public var since: Date
    public init(retainedPath: String, treeHash: String, cdhash: String, bundleId: String, fromImageId: String, txid: String, since: Date) {
        self.retainedPath = retainedPath; self.treeHash = treeHash; self.cdhash = cdhash; self.bundleId = bundleId
        self.fromImageId = fromImageId; self.txid = txid; self.since = since
    }
}

public struct RestoreJournal: Codable, Equatable {
    public var schema: String
    public var txid: String
    public var kind: String
    public var appId: String
    public var imageId: String
    public var owner: ProcessOwner
    public var phase: RestorePhase
    public var dest: String
    public var staging: String
    public var imagePath: String
    public var imageFile: String
    public var mountPath: String?
    public var retainedPath: String?
    public var appName: String
    public var stubBundleId: String
    public var executable: String
    public var manifestCdhash: String
    public var manifestTreeHash: String
    public var imageSha256: String
    public var createdAt: Date
    public var epoch: Int
    public var postQuitRanForEpoch: Int
    public var destId: InodeId?
    public var stubId: InodeId?
    public var inspection: InspectionSnapshot?
    public var resolution: ResolutionSnapshot?
    public var outcome: String?
    public var outcomeAt: Date?
    public var pendingOutcome: String?
    public var retiredStateWritten: Bool
    public var waitReason: String?
    public var detachedImage: Bool
    public var detachAfter: Date?
    public var didLaunch: Bool
    /// Stat-only digest of `dest` after `app.new` was renamed into place. Nil on older journals.
    public var installedFingerprint: String?

    public init(txid: String, appId: String, imageId: String, owner: ProcessOwner, dest: String, staging: String, imagePath: String, imageFile: String, appName: String, stubBundleId: String, executable: String, manifestCdhash: String, manifestTreeHash: String, imageSha256: String, createdAt: Date = Date()) {
        self.schema = "tx/1"
        self.txid = txid
        self.kind = "restore-in"
        self.appId = appId
        self.imageId = imageId
        self.owner = owner
        self.phase = .prepared
        self.dest = dest
        self.staging = staging
        self.imagePath = imagePath
        self.imageFile = imageFile
        self.mountPath = nil
        self.retainedPath = nil
        self.appName = appName
        self.stubBundleId = stubBundleId
        self.executable = executable
        self.manifestCdhash = manifestCdhash
        self.manifestTreeHash = manifestTreeHash
        self.imageSha256 = imageSha256
        self.createdAt = createdAt
        self.epoch = 1
        self.postQuitRanForEpoch = 0
        self.destId = nil
        self.stubId = nil
        self.inspection = nil
        self.resolution = nil
        self.outcome = nil
        self.outcomeAt = nil
        self.pendingOutcome = nil
        self.retiredStateWritten = false
        self.waitReason = nil
        self.detachedImage = false
        self.detachAfter = nil
        self.didLaunch = false
        self.installedFingerprint = nil
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RestoreJournal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RestoreJournal.self, from: data)
    }
}

public enum JournalStore {
    public static func directory(_ stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("journals")
    }

    public static func file(_ stateDir: String, txid: String) -> URL {
        directory(stateDir).appendingPathComponent("\(txid).json")
    }

    public static func save(_ journal: RestoreJournal, stateDir: String) throws {
        try DurableIO.atomicWrite(try journal.encode(), to: file(stateDir, txid: journal.txid))
        // Directory fsync is inside atomicWrite.
    }

    public static func load(stateDir: String, txid: String) throws -> RestoreJournal {
        let url = file(stateDir, txid: txid)
        guard let data = try? Data(contentsOf: url) else { throw IsenoughError.failure("missing journal \(txid)") }
        return try RestoreJournal.decode(data)
    }

    public static func loadAll(stateDir: String) throws -> [RestoreJournal] {
        let dir = directory(stateDir)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
            try RestoreJournal.decode(Data(contentsOf: dir.appendingPathComponent(name)))
        }
    }

    public static func remove(stateDir: String, txid: String) throws {
        let url = file(stateDir, txid: txid)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try DurableIO.syncItem(url.deletingLastPathComponent())
        }
    }
}

public struct InjectedFault: Error, Equatable {
    public let point: String
    public init(_ point: String) { self.point = point }
}

public final class FaultController {
    public enum Mode: Equatable { case off, raised, kill }
    public var points: Set<String>
    public var mode: Mode
    public private(set) var hits: [String] = []

    public init(points: Set<String> = [], mode: Mode = .off) {
        self.points = points
        self.mode = mode
    }

    public func hit(_ phase: String, _ edge: String) throws {
        let key = "\(phase):\(edge)"
        guard mode != .off, points.contains(key) else { return }
        hits.append(key)
        switch mode {
        case .off: return
        case .raised: throw InjectedFault(key)
        case .kill:
            kill(getpid(), SIGKILL)
            throw InjectedFault(key)
        }
    }
}

public enum UsageClass: String, Codable, CaseIterable, Equatable {
    case clean, busy, unknown, held
}
