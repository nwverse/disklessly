import Foundation

/// In-place unpack bookkeeping. Stored under `unpack-journals/`, not `journals/`,
/// so `JournalStore.loadAll` never tries to decode it as a restore transaction.
public struct UnpackJournal: Codable, Equatable {
    public var schema: String
    public var txid: String
    public var appId: String
    public var imageId: String
    public var dest: String
    public var staging: String
    public var phase: String
    public var createdAt: Date
    public var manifestTreeHash: String
    public var manifestCdhash: String

    public init(txid: String, appId: String, imageId: String, dest: String, staging: String, phase: String, createdAt: Date = Date(), manifestTreeHash: String, manifestCdhash: String) {
        self.schema = "unpack/1"
        self.txid = txid
        self.appId = appId
        self.imageId = imageId
        self.dest = dest
        self.staging = staging
        self.phase = phase
        self.createdAt = createdAt
        self.manifestTreeHash = manifestTreeHash
        self.manifestCdhash = manifestCdhash
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> UnpackJournal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UnpackJournal.self, from: data)
    }
}

public enum UnpackStore {
    public static func directory(_ stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("unpack-journals")
    }

    public static func file(_ stateDir: String, txid: String) -> URL {
        directory(stateDir).appendingPathComponent("\(txid).json")
    }

    public static func save(_ journal: UnpackJournal, stateDir: String) throws {
        try DurableIO.atomicWrite(try journal.encode(), to: file(stateDir, txid: journal.txid))
    }

    public static func loadAll(stateDir: String) throws -> [UnpackJournal] {
        let dir = directory(stateDir)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
            try UnpackJournal.decode(Data(contentsOf: dir.appendingPathComponent(name)))
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

public enum UnpackAction: Equatable {
    /// Delete staging and drop the journal. The stub at dest stays.
    case rollback
    /// `app.new` is verified and dest is empty: move it into place, then finish.
    case installAndFinish
    /// Move the parked stub back to dest and drop the journal.
    case restoreStub
    /// Dest is the real app. Delete the parked stub and close the journal.
    case deleteParkedStub
    /// Dest is occupied by something else, or the staging pieces do not match the phase.
    case needsAttention
}

public enum UnpackRecovery {
    /// Pure decision for one open unpack journal.
    /// `destIsApp` means dest's bundle id is the real app. `destIsStub` means it is this image's stub.
    /// Both false means dest is absent or is neither of those bundles.
    public static func decide(phase: String, destIsStub: Bool, destIsApp: Bool, appNewVerified: Bool, parkedStubExists: Bool) -> UnpackAction {
        switch phase {
        case "prepared", "extracted":
            return destIsStub ? .rollback : .needsAttention
        case "stubParked":
            if !destIsStub && !destIsApp && appNewVerified { return .installAndFinish }
            if !destIsStub && !destIsApp && !appNewVerified && parkedStubExists { return .restoreStub }
            return .needsAttention
        case "installed", "stubDeleted":
            if destIsApp { return .deleteParkedStub }
            // The journal moved to `installed` before `app.new` was renamed. Dest is
            // empty and the verified bundle is still in staging. Finish that rename
            // so the crash window cannot leave the app only inside staging.
            if !destIsStub && !destIsApp && appNewVerified { return .installAndFinish }
            if !destIsStub && !destIsApp && parkedStubExists { return .restoreStub }
            return .needsAttention
        default:
            return .needsAttention
        }
    }
}
