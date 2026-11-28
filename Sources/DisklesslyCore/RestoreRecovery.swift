import Foundation

/// Observable bundle role at one path. The decision function never touches the filesystem.
public enum BundleNode: Equatable {
    case absent
    case symlink
    case incomplete
    case stub(bundleId: String, inode: InodeId?)
    case app(bundleId: String, cdhash: String, treeHash: String, inode: InodeId?)
    case foreign(String)
}

public enum StagingState: Equatable {
    case absent
    case ownedEmpty
    case owned
    case foreign
}

public struct RestoreLayout: Equatable {
    public var destination: BundleNode
    public var appNew: BundleNode
    public var appOld: BundleNode
    public var parkedStub: BundleNode
    public var retained: BundleNode
    /// `journal.retainedPath` aliases `staging/app.old` because the retention move
    /// failed. This is deliberately separate from `retained` so two independent
    /// copies can never be mistaken for the in-place fallback.
    public var retainedInPlace: Bool
    public var staging: StagingState
    public var extractionOwned: Bool
    public var extractionVerified: Bool
    public var pathsEscape: Bool
    public var unexpected: [String]

    public init(destination: BundleNode, appNew: BundleNode = .absent, appOld: BundleNode = .absent, parkedStub: BundleNode = .absent, retained: BundleNode = .absent, retainedInPlace: Bool = false, staging: StagingState = .absent, extractionOwned: Bool = false, extractionVerified: Bool = false, pathsEscape: Bool = false, unexpected: [String] = []) {
        self.destination = destination
        self.appNew = appNew
        self.appOld = appOld
        self.parkedStub = parkedStub
        self.retained = retained
        self.retainedInPlace = retainedInPlace
        self.staging = staging
        self.extractionOwned = extractionOwned
        self.extractionVerified = extractionVerified
        self.pathsEscape = pathsEscape
        self.unexpected = unexpected
    }
}

public struct RestoreContext: Equatable {
    public var manifestBundleId: String
    public var stubBundleId: String
    public var manifestCdhash: String
    public var manifestTreeHash: String
    public var recordedDestId: InodeId?
    public var recordedStubId: InodeId?
    public var inspection: InspectionSnapshot?
    public var archiveVerified: Bool
    public var retiredStateWritten: Bool
    public var cleanStreak: Int
    public var stubRegenerable: Bool
    public var journalMissing: Bool
    public var mirrorPresent: Bool
    public var pendingOutcome: String?

    public init(manifestBundleId: String, stubBundleId: String, manifestCdhash: String, manifestTreeHash: String, recordedDestId: InodeId? = nil, recordedStubId: InodeId? = nil, inspection: InspectionSnapshot? = nil, archiveVerified: Bool = false, retiredStateWritten: Bool = false, cleanStreak: Int = 0, stubRegenerable: Bool = true, journalMissing: Bool = false, mirrorPresent: Bool = false, pendingOutcome: String? = nil) {
        self.manifestBundleId = manifestBundleId
        self.stubBundleId = stubBundleId
        self.manifestCdhash = manifestCdhash
        self.manifestTreeHash = manifestTreeHash
        self.recordedDestId = recordedDestId
        self.recordedStubId = recordedStubId
        self.inspection = inspection
        self.archiveVerified = archiveVerified
        self.retiredStateWritten = retiredStateWritten
        self.cleanStreak = cleanStreak
        self.stubRegenerable = stubRegenerable
        self.journalMissing = journalMissing
        self.mirrorPresent = mirrorPresent
        self.pendingOutcome = pendingOutcome
    }
}

public enum RestoreAction: Equatable {
    case noopLiveOwner
    case reject(String)
    case finishRollback
    case adoptAndWatch
    case waitForAnotherClean
    case backToActive
    case startRestoreOut
    case recordInspection
    case moveAppAside
    case waitOnStaging
    case restoreStub
    case regenerateStub
    case deleteIdenticalCopy
    case retainUpdatedCopy
    case writeRetirement
    case closeTransaction
    case retireMirrorWithoutJournal
}

public struct RestoreDecision: Equatable {
    public var action: RestoreAction
    public var diagnostic: String?
    public init(_ action: RestoreAction, diagnostic: String? = nil) {
        self.action = action
        self.diagnostic = diagnostic
    }
}

public enum RestoreRecovery {
    /// `ownerAlive` is true only when a *different* process still holds the journal owner identity.
    /// The current owner passes false. A live foreign owner is a no-op: recovery does not rename or delete.
    /// Both the pre-effect and post-effect layout of the journaled phase are accepted, because the phase is written before the mutation.
    public static func decide(phase: RestorePhase, layout: RestoreLayout, probe: UsageClass, ownerAlive: Bool, context: RestoreContext) -> RestoreDecision {
        if context.journalMissing {
            if layout.pathsEscape { return reject("restored mirror path escapes its parent") }
            if isStub(layout.destination, context), layout.staging == .absent, isAbsent(layout.parkedStub), isAbsent(layout.appOld) {
                return RestoreDecision(.retireMirrorWithoutJournal, diagnostic: "stale restored mirror; destination holds the stub and staging is gone")
            }
            return reject("stale restored mirror without a journal, and the destination is not the installed stub. Repair: put the stub back at the destination (or leave the real bundle and its staging untouched) and run disklessly doctor. Nothing was deleted.")
        }
        if ownerAlive {
            return RestoreDecision(.noopLiveOwner, diagnostic: "journal owner is alive")
        }
        if layout.pathsEscape {
            return reject("a journal path escapes its parent directory")
        }
        if !layout.unexpected.isEmpty {
            return reject("staging contains unexplained entries \(layout.unexpected.joined(separator: ", ")). Repair: move them out of the transaction staging directory, then run disklessly gc. Nothing was deleted.")
        }
        switch phase {
        case .prepared:
            return early(prepared(layout, context), context)
        case .extracted:
            return early(extracted(layout, context), context)
        case .stubParked:
            return early(stubParked(layout, context), context)
        case .installed:
            switch installed(layout, context) {
            case .invalid(let message): return reject(message)
            case .undone, .pre: return RestoreDecision(.finishRollback)
            case .post:
                if probe != .clean { return RestoreDecision(.adoptAndWatch) }
                if context.cleanStreak < 2 { return RestoreDecision(.waitForAnotherClean) }
                return RestoreDecision(.startRestoreOut)
            }
        case .active:
            switch session(layout, context) {
            case .invalid(let message): return reject(message)
            case .post:
                if probe != .clean { return RestoreDecision(.adoptAndWatch) }
                if context.cleanStreak < 2 { return RestoreDecision(.waitForAnotherClean) }
                return RestoreDecision(.startRestoreOut)
            case .undone, .pre: return reject("active journal does not have the restored bundle at the destination and the stub parked")
            }
        case .quiesced:
            switch session(layout, context) {
            case .invalid(let message): return reject(message)
            case .post:
                if probe != .clean { return RestoreDecision(.backToActive) }
                if context.cleanStreak < 2 { return RestoreDecision(.waitForAnotherClean) }
                return RestoreDecision(.recordInspection)
            case .undone, .pre: return reject("quiesced journal lost the restored bundle or parked stub")
            }
        case .inspected:
            switch session(layout, context) {
            case .invalid(let message): return reject(message)
            case .post:
                if probe != .clean { return RestoreDecision(.backToActive) }
                if context.inspection == nil || inspectionStale(layout, context) { return RestoreDecision(.recordInspection) }
                if context.cleanStreak < 2 { return RestoreDecision(.waitForAnotherClean) }
                return RestoreDecision(.moveAppAside)
            case .undone, .pre: return reject("inspected journal lost the restored bundle or parked stub")
            }
        case .appMoved:
            switch appMoved(layout, context) {
            case .invalid(let message): return reject(message)
            case .pre:
                if probe != .clean || context.cleanStreak < 2 { return RestoreDecision(.waitForAnotherClean) }
                return RestoreDecision(.moveAppAside)
            case .post:
                if probe != .clean { return RestoreDecision(.waitOnStaging) }
                if context.cleanStreak < 2 { return RestoreDecision(.waitForAnotherClean) }
                if isStub(layout.parkedStub, context) { return RestoreDecision(.restoreStub) }
                if context.stubRegenerable, isAbsent(layout.destination) { return RestoreDecision(.regenerateStub) }
                return reject("app is in staging but the parked stub is missing and cannot be regenerated")
            case .undone: return reject("appMoved journal has neither the destination app nor staging/app.old")
            }
        case .stubBack:
            switch stubBack(layout, context) {
            case .invalid(let message): return reject(message)
            case .pre:
                if probe != .clean || context.cleanStreak < 2 { return RestoreDecision(.waitOnStaging) }
                if isStub(layout.parkedStub, context) { return RestoreDecision(.restoreStub) }
                if context.stubRegenerable, isAbsent(layout.destination) { return RestoreDecision(.regenerateStub) }
                return reject("stubBack cannot restore a stub onto a non-empty destination")
            case .post:
                return disposeDecision(probe, context, haveOld: true)
            case .undone: return reject("stubBack lost both the stub and the staged app")
            }
        case .disposed:
            switch disposed(layout, context) {
            case .invalid(let message): return reject(message)
            case .pre: return disposeDecision(probe, context, haveOld: true)
            case .post: return RestoreDecision(.writeRetirement)
            case .undone: return reject("disposed journal lost the stub or the only copy of an updated app")
            }
        case .retired:
            switch terminal(layout, context) {
            case .invalid(let message): return reject(message)
            case .post, .pre, .undone:
                if !context.retiredStateWritten { return RestoreDecision(.writeRetirement) }
                return RestoreDecision(.closeTransaction)
            }
        case .closed:
            switch terminal(layout, context) {
            case .invalid(let message): return reject(message)
            case .post, .pre, .undone: return RestoreDecision(.closeTransaction)
            }
        }
    }

    public static func repairHint(phase: RestorePhase) -> String {
        "Layout for phase \(phase.rawValue) is not a recognized pre-effect or post-effect state. No files were changed. Repair: move unexpected bundles out of the transaction staging directory without deleting the destination, then run disklessly gc. If the destination is neither the stub nor the restored app, restore it manually from the disk image."
    }

    private enum Side: Equatable { case pre, post, undone, invalid(String) }

    private static func reject(_ message: String) -> RestoreDecision {
        RestoreDecision(.reject(message), diagnostic: message)
    }

    private static func early(_ side: Side, _ context: RestoreContext) -> RestoreDecision {
        switch side {
        case .invalid(let message): return reject(message)
        case .pre, .post, .undone: return RestoreDecision(.finishRollback)
        }
    }

    private static func disposeDecision(_ probe: UsageClass, _ context: RestoreContext, haveOld: Bool) -> RestoreDecision {
        if probe != .clean || context.cleanStreak < 2 { return RestoreDecision(.waitOnStaging) }
        if context.inspection == nil { return RestoreDecision(.recordInspection) }
        if provenIdentical(context) { return RestoreDecision(.deleteIdenticalCopy) }
        return RestoreDecision(.retainUpdatedCopy, diagnostic: haveOld ? nil : "updated or unverified copy is retained")
    }

    public static func provenIdentical(_ context: RestoreContext) -> Bool {
        guard let inspection = context.inspection, !inspection.changed, context.archiveVerified else { return false }
        return inspection.cdhash == context.manifestCdhash && inspection.treeHash == context.manifestTreeHash && inspection.bundleId == context.manifestBundleId
    }

    private static func inspectionStale(_ layout: RestoreLayout, _ context: RestoreContext) -> Bool {
        guard let inspection = context.inspection, let app = app(layout.destination, context) else { return true }
        return inspection.cdhash != app.cdhash || inspection.treeHash != app.treeHash || inspection.bundleId != app.bundleId
    }

    private static func isAbsent(_ node: BundleNode) -> Bool {
        if case .absent = node { return true }
        return false
    }

    /// Stub identity is the bundle id (`*.256stub`). The recorded inode is diagnostic:
    /// regeneration allocates a new inode, and a replaced stub must not be treated as
    /// an unexplained bundle. Recovery never overwrites a non-empty destination.
    private static func isStub(_ node: BundleNode, _ context: RestoreContext) -> Bool {
        guard case .stub(let id, _) = node, id == context.stubBundleId else { return false }
        return true
    }

    private static func app(_ node: BundleNode, _ context: RestoreContext) -> (cdhash: String, treeHash: String, bundleId: String, inode: InodeId?)? {
        guard case .app(let id, let cdhash, let tree, let inode) = node, id == context.manifestBundleId else { return nil }
        return (cdhash, tree, id, inode)
    }

    private static func manifestApp(_ node: BundleNode, _ context: RestoreContext) -> Bool {
        guard let app = app(node, context) else { return false }
        return app.cdhash == context.manifestCdhash && app.treeHash == context.manifestTreeHash
    }

    private static func rolesClear(_ layout: RestoreLayout) -> Bool {
        isAbsent(layout.appOld) && isAbsent(layout.parkedStub) && isAbsent(layout.retained)
    }

    private static func baseOK(_ layout: RestoreLayout) -> Bool {
        !layout.pathsEscape && layout.unexpected.isEmpty
    }

    private static func stubAtDestUndone(_ layout: RestoreLayout, _ context: RestoreContext) -> Bool {
        baseOK(layout) && isStub(layout.destination, context) && isAbsent(layout.appNew) && rolesClear(layout) && (layout.staging == .absent || layout.staging == .ownedEmpty)
    }

    private static func prepared(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        guard baseOK(layout), isStub(layout.destination, context), isAbsent(layout.appNew), rolesClear(layout) else {
            return .invalid(repairHint(phase: .prepared))
        }
        switch layout.staging {
        case .absent: return .undone
        case .ownedEmpty: return .post
        case .owned, .foreign: return .invalid(repairHint(phase: .prepared))
        }
    }

    private static func extracted(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        if stubAtDestUndone(layout, context) { return .undone }
        guard baseOK(layout), isStub(layout.destination, context), layout.staging == .owned || layout.staging == .ownedEmpty, rolesClear(layout) else {
            return .invalid(repairHint(phase: .extracted))
        }
        if isAbsent(layout.appNew) { return .pre }
        if layout.extractionOwned && (layout.appNew == .incomplete || manifestApp(layout.appNew, context)) {
            return layout.extractionVerified && manifestApp(layout.appNew, context) ? .post : .pre
        }
        return .invalid("extracted staging has a bundle that is not this transaction's verified extraction. Nothing was deleted.")
    }

    private static func stubParked(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        if stubAtDestUndone(layout, context) { return .undone }
        guard baseOK(layout), layout.staging == .owned, isAbsent(layout.appOld), isAbsent(layout.retained), manifestApp(layout.appNew, context), layout.extractionVerified else {
            return .invalid(repairHint(phase: .stubParked))
        }
        if isStub(layout.destination, context) && isAbsent(layout.parkedStub) { return .pre }
        if isAbsent(layout.destination) && isStub(layout.parkedStub, context) { return .post }
        return .invalid("stubParked has both or neither of the destination stub and the parked stub. Nothing was moved.")
    }

    private static func installed(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        if stubAtDestUndone(layout, context) { return .undone }
        guard baseOK(layout), layout.staging == .owned, isAbsent(layout.appOld), isAbsent(layout.retained) else {
            return .invalid(repairHint(phase: .installed))
        }
        if isAbsent(layout.destination), isStub(layout.parkedStub, context), manifestApp(layout.appNew, context) { return .pre }
        if isAbsent(layout.destination), isStub(layout.parkedStub, context), isAbsent(layout.appNew) { return .pre }
        if app(layout.destination, context) != nil, isAbsent(layout.appNew), isStub(layout.parkedStub, context) { return .post }
        return .invalid(repairHint(phase: .installed))
    }

    private static func session(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        guard baseOK(layout), layout.staging == .owned || layout.staging == .ownedEmpty, isAbsent(layout.appNew), isAbsent(layout.appOld), isAbsent(layout.retained), app(layout.destination, context) != nil, isStub(layout.parkedStub, context) else {
            return .invalid(repairHint(phase: .active))
        }
        return .post
    }

    private static func appMoved(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        guard baseOK(layout), layout.staging == .owned, isAbsent(layout.appNew), isAbsent(layout.retained) else {
            return .invalid(repairHint(phase: .appMoved))
        }
        let parkedOK = isStub(layout.parkedStub, context) || (isAbsent(layout.parkedStub) && context.stubRegenerable)
        guard parkedOK else { return .invalid(repairHint(phase: .appMoved)) }
        if app(layout.destination, context) != nil && isAbsent(layout.appOld) { return .pre }
        if isAbsent(layout.destination) && app(layout.appOld, context) != nil { return .post }
        return .invalid(repairHint(phase: .appMoved))
    }

    private static func stubBack(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        guard baseOK(layout), isAbsent(layout.appNew), isAbsent(layout.retained), app(layout.appOld, context) != nil else {
            return .invalid(repairHint(phase: .stubBack))
        }
        if isAbsent(layout.destination) && (isStub(layout.parkedStub, context) || (isAbsent(layout.parkedStub) && context.stubRegenerable)) { return .pre }
        if isStub(layout.destination, context) && isAbsent(layout.parkedStub) { return .post }
        return .invalid("stubBack destination is occupied by something other than the parked stub. Nothing was overwritten.")
    }

    private static func disposed(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        guard baseOK(layout), isStub(layout.destination, context), isAbsent(layout.parkedStub), isAbsent(layout.appNew) else {
            return .invalid(repairHint(phase: .disposed))
        }
        if layout.retainedInPlace {
            return validInPlaceRetention(layout, context) ? .post : .invalid("disposed journal has an invalid in-place retention layout. Nothing further was deleted.")
        }
        if app(layout.appOld, context) != nil && isAbsent(layout.retained) { return .pre }
        if isAbsent(layout.appOld) && isAbsent(layout.retained) && context.inspection?.changed != true { return .post }
        if isAbsent(layout.appOld), case .app = layout.retained { return .post }
        if isAbsent(layout.appOld) && isAbsent(layout.retained) && context.inspection?.changed == true {
            return .invalid("disposed journal says the bundle changed, but neither staging nor the retained path holds it. Nothing further was deleted.")
        }
        return .invalid(repairHint(phase: .disposed))
    }

    private static func terminal(_ layout: RestoreLayout, _ context: RestoreContext) -> Side {
        guard baseOK(layout), isStub(layout.destination, context), isAbsent(layout.parkedStub), isAbsent(layout.appNew) else {
            return .invalid(repairHint(phase: .retired))
        }
        if layout.retainedInPlace {
            return validInPlaceRetention(layout, context) ? .post : .invalid("retired journal has an invalid in-place retention layout. Nothing further was deleted.")
        }
        if context.inspection?.changed == true && isAbsent(layout.appOld) && isAbsent(layout.retained) {
            return .invalid("retired journal lost the updated bundle. Nothing further was deleted.")
        }
        if !isAbsent(layout.appOld) { return .invalid("retired journal still has staging/app.old. Re-run recovery of disposed before closing.") }
        return .post
    }

    private static func validInPlaceRetention(_ layout: RestoreLayout, _ context: RestoreContext) -> Bool {
        guard app(layout.appOld, context) != nil, app(layout.retained, context) != nil else { return false }
        return layout.appOld == layout.retained
    }
}
