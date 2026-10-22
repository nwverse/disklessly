import XCTest
@testable import IsenoughCore

final class RestoreRecoveryTests: XCTestCase {
    private let bundle = "com.example.foo"
    private let cdhash = "cdhash-manifest"
    private let tree = "tree-manifest"
    private var stubID: String { bundle + ".256stub" }

    private func context(streak: Int = 0, inspection: InspectionSnapshot? = nil, archive: Bool = true, retired: Bool = false, regenerable: Bool = true, missing: Bool = false, pending: String? = nil) -> RestoreContext {
        RestoreContext(
            manifestBundleId: bundle,
            stubBundleId: stubID,
            manifestCdhash: cdhash,
            manifestTreeHash: tree,
            inspection: inspection,
            archiveVerified: archive,
            retiredStateWritten: retired,
            cleanStreak: streak,
            stubRegenerable: regenerable,
            journalMissing: missing,
            pendingOutcome: pending
        )
    }

    private func stubNode() -> BundleNode { .stub(bundleId: stubID, inode: InodeId(dev: 1, ino: 2)) }
    private func appNode(cd: String? = nil, treeHash: String? = nil) -> BundleNode {
        .app(bundleId: bundle, cdhash: cd ?? cdhash, treeHash: treeHash ?? tree, inode: InodeId(dev: 1, ino: 9))
    }

    private func decide(_ phase: RestorePhase, _ layout: RestoreLayout, probe: UsageClass = .clean, alive: Bool = false, streak: Int = 2, inspection: InspectionSnapshot? = nil, archive: Bool = true, retired: Bool = false, regenerable: Bool = true, missing: Bool = false) -> RestoreAction {
        RestoreRecovery.decide(
            phase: phase,
            layout: layout,
            probe: probe,
            ownerAlive: alive,
            context: context(streak: streak, inspection: inspection, archive: archive, retired: retired, regenerable: regenerable, missing: missing)
        ).action
    }

    private func session(dest: BundleNode, parked: BundleNode, staging: StagingState = .owned) -> RestoreLayout {
        RestoreLayout(destination: dest, parkedStub: parked, staging: staging)
    }

    func testLiveOwnerIsAlwaysANoOp() {
        let layouts = [
            RestoreLayout(destination: .symlink, pathsEscape: true, unexpected: ["mystery"]),
            session(dest: appNode(cd: "replaced"), parked: stubNode()),
            RestoreLayout(destination: .absent),
        ]
        for phase in RestorePhase.allCases {
            for probe in UsageClass.allCases {
                for layout in layouts {
                    XCTAssertEqual(decide(phase, layout, probe: probe, alive: true, streak: 0), .noopLiveOwner, "\(phase) \(probe)")
                }
            }
        }
    }

    func testRejectHasNoMutatingAction() {
        let escaped = RestoreLayout(destination: stubNode(), pathsEscape: true)
        let unexpected = RestoreLayout(destination: stubNode(), staging: .ownedEmpty, unexpected: ["mystery"])
        let symlink = RestoreLayout(destination: .symlink, parkedStub: stubNode(), staging: .owned)
        for phase in RestorePhase.allCases {
            for layout in [escaped, unexpected, symlink] {
                let action = decide(phase, layout, streak: 2)
                guard case .reject = action else {
                    XCTFail("\(phase) \(layout) -> \(action)")
                    continue
                }
            }
        }
    }

    func testEarlyPhasesRollBackPrePostAndUndone() {
        let undone = RestoreLayout(destination: stubNode(), staging: .absent)
        let preparedPost = RestoreLayout(destination: stubNode(), staging: .ownedEmpty)
        let extractedPre = RestoreLayout(destination: stubNode(), staging: .owned, extractionOwned: true)
        let extractedPost = RestoreLayout(destination: stubNode(), appNew: appNode(), staging: .owned, extractionOwned: true, extractionVerified: true)
        let parkedPre = RestoreLayout(destination: stubNode(), appNew: appNode(), staging: .owned, extractionOwned: true, extractionVerified: true)
        let parkedPost = RestoreLayout(destination: .absent, appNew: appNode(), parkedStub: stubNode(), staging: .owned, extractionOwned: true, extractionVerified: true)
        let cases: [(RestorePhase, RestoreLayout)] = [
            (.prepared, undone), (.prepared, preparedPost),
            (.extracted, undone), (.extracted, extractedPre), (.extracted, extractedPost),
            (.stubParked, undone), (.stubParked, parkedPre), (.stubParked, parkedPost),
        ]
        for (phase, layout) in cases {
            XCTAssertEqual(decide(phase, layout, probe: .busy, streak: 0), .finishRollback, "\(phase)")
        }
        let foreignExtract = RestoreLayout(destination: stubNode(), appNew: .foreign("other"), staging: .owned)
        guard case .reject = decide(.extracted, foreignExtract) else { XCTFail("unexplained extraction must be rejected"); return }
    }

    func testInstalledAndActiveBranchOnProbeAndCleanTwice() {
        let pre = RestoreLayout(destination: .absent, appNew: appNode(), parkedStub: stubNode(), staging: .owned, extractionVerified: true)
        let post = session(dest: appNode(cd: "replaced", treeHash: "other"), parked: stubNode())
        let undone = RestoreLayout(destination: stubNode(), staging: .absent)
        XCTAssertEqual(decide(.installed, pre, probe: .busy, streak: 9), .finishRollback)
        XCTAssertEqual(decide(.installed, undone), .finishRollback)
        for probe in [UsageClass.busy, .unknown, .held] {
            XCTAssertEqual(decide(.installed, post, probe: probe, streak: 9), .adoptAndWatch)
            XCTAssertEqual(decide(.active, post, probe: probe, streak: 9), .adoptAndWatch)
        }
        XCTAssertEqual(decide(.installed, post, streak: 1), .waitForAnotherClean)
        XCTAssertEqual(decide(.installed, post, streak: 2), .startRestoreOut)
        XCTAssertEqual(decide(.active, post, streak: 1), .waitForAnotherClean)
        XCTAssertEqual(decide(.active, post, streak: 2), .startRestoreOut)
        guard case .reject = decide(.active, undone) else { XCTFail("active undone"); return }
    }

    func testRestoreOutPhasesWaitUnlessCleanTwice() {
        let live = session(dest: appNode(), parked: stubNode())
        let inspection = InspectionSnapshot(cdhash: cdhash, treeHash: tree, bundleId: bundle, changed: false)
        let changed = InspectionSnapshot(cdhash: "new", treeHash: "new-tree", bundleId: bundle, changed: true)
        XCTAssertEqual(decide(.quiesced, live, probe: .busy, streak: 9), .backToActive)
        XCTAssertEqual(decide(.quiesced, live, streak: 1), .waitForAnotherClean)
        XCTAssertEqual(decide(.quiesced, live, streak: 2), .recordInspection)
        XCTAssertEqual(decide(.inspected, live, probe: .held, streak: 9), .backToActive)
        XCTAssertEqual(decide(.inspected, live, streak: 2, inspection: nil), .recordInspection)
        XCTAssertEqual(decide(.inspected, live, streak: 1, inspection: inspection), .waitForAnotherClean)
        XCTAssertEqual(decide(.inspected, live, streak: 2, inspection: inspection), .moveAppAside)

        let movedPre = RestoreLayout(destination: appNode(), parkedStub: stubNode(), staging: .owned)
        let movedPost = RestoreLayout(destination: .absent, appOld: appNode(), parkedStub: stubNode(), staging: .owned)
        XCTAssertEqual(decide(.appMoved, movedPre, probe: .busy, streak: 0), .waitForAnotherClean)
        XCTAssertEqual(decide(.appMoved, movedPre, streak: 2), .moveAppAside)
        XCTAssertEqual(decide(.appMoved, movedPost, probe: .unknown, streak: 9), .waitOnStaging)
        XCTAssertEqual(decide(.appMoved, movedPost, streak: 1), .waitForAnotherClean)
        XCTAssertEqual(decide(.appMoved, movedPost, streak: 2), .restoreStub)
        let missingParked = RestoreLayout(destination: .absent, appOld: appNode(), staging: .owned)
        XCTAssertEqual(decide(.appMoved, missingParked, streak: 2, regenerable: true), .regenerateStub)
        guard case .reject = decide(.appMoved, missingParked, streak: 2, regenerable: false) else { XCTFail("cannot regenerate"); return }

        let stubPre = RestoreLayout(destination: .absent, appOld: appNode(), parkedStub: stubNode(), staging: .owned)
        let stubPost = RestoreLayout(destination: stubNode(), appOld: appNode(), staging: .owned)
        XCTAssertEqual(decide(.stubBack, stubPre, streak: 1), .waitOnStaging)
        XCTAssertEqual(decide(.stubBack, stubPre, streak: 2), .restoreStub)
        XCTAssertEqual(decide(.stubBack, RestoreLayout(destination: .absent, appOld: appNode(), staging: .owned), streak: 2), .regenerateStub)
        XCTAssertEqual(decide(.stubBack, stubPost, streak: 1, inspection: inspection), .waitOnStaging)
        XCTAssertEqual(decide(.stubBack, stubPost, streak: 2, inspection: inspection, archive: true), .deleteIdenticalCopy)
        XCTAssertEqual(decide(.stubBack, stubPost, streak: 2, inspection: inspection, archive: false), .retainUpdatedCopy)
        XCTAssertEqual(decide(.stubBack, stubPost, streak: 2, inspection: changed, archive: true), .retainUpdatedCopy)
        XCTAssertEqual(decide(.stubBack, stubPost, streak: 2, inspection: nil), .recordInspection)
    }

    func testDisposedRetiredAndClosed() {
        let inspection = InspectionSnapshot(cdhash: cdhash, treeHash: tree, bundleId: bundle, changed: false)
        let changed = InspectionSnapshot(cdhash: "new", treeHash: "new-tree", bundleId: bundle, changed: true)
        let withOld = RestoreLayout(destination: stubNode(), appOld: appNode(), staging: .owned)
        let deleted = RestoreLayout(destination: stubNode(), staging: .ownedEmpty)
        let retained = RestoreLayout(destination: stubNode(), retained: appNode(cd: "new", treeHash: "new-tree"), staging: .ownedEmpty)
        XCTAssertEqual(decide(.disposed, withOld, streak: 1, inspection: inspection), .waitOnStaging)
        XCTAssertEqual(decide(.disposed, withOld, streak: 2, inspection: inspection), .deleteIdenticalCopy)
        XCTAssertEqual(decide(.disposed, withOld, streak: 2, inspection: changed), .retainUpdatedCopy)
        XCTAssertEqual(decide(.disposed, deleted, streak: 2, inspection: inspection), .writeRetirement)
        XCTAssertEqual(decide(.disposed, retained, streak: 2, inspection: changed), .writeRetirement)
        guard case .reject = decide(.disposed, deleted, streak: 2, inspection: changed) else { XCTFail("lost updated copy"); return }
        XCTAssertEqual(decide(.retired, deleted, inspection: inspection, retired: false), .writeRetirement)
        XCTAssertEqual(decide(.retired, deleted, inspection: inspection, retired: true), .closeTransaction)
        XCTAssertEqual(decide(.closed, deleted, inspection: inspection, retired: false), .closeTransaction)
        guard case .reject = decide(.retired, withOld, inspection: inspection, retired: true) else { XCTFail("old copy still staged"); return }
    }

    func testMissingJournalMirrorVariants() {
        let stubDest = RestoreLayout(destination: stubNode(), staging: .absent)
        XCTAssertEqual(decide(.closed, stubDest, missing: true), .retireMirrorWithoutJournal)
        let realDest = RestoreLayout(destination: appNode(), staging: .owned)
        guard case .reject = decide(.active, realDest, alive: true, missing: true) else {
            XCTFail("a live owner must not authorize deleting a mirror with no journal")
            return
        }
        guard case .reject = decide(.active, realDest, missing: true) else { XCTFail("real dest without journal"); return }
    }

    func testDestructiveActionsRequireCleanTwice() {
        let live = session(dest: appNode(), parked: stubNode())
        let inspection = InspectionSnapshot(cdhash: cdhash, treeHash: tree, bundleId: bundle, changed: false)
        let moved = RestoreLayout(destination: .absent, appOld: appNode(), parkedStub: stubNode(), staging: .owned)
        let back = RestoreLayout(destination: stubNode(), appOld: appNode(), staging: .owned)
        let gated: [(RestorePhase, RestoreLayout, InspectionSnapshot?, RestoreAction)] = [
            (.installed, live, nil, .startRestoreOut),
            (.active, live, nil, .startRestoreOut),
            (.quiesced, live, nil, .recordInspection),
            (.inspected, live, inspection, .moveAppAside),
            (.appMoved, moved, nil, .restoreStub),
            (.stubBack, back, inspection, .deleteIdenticalCopy),
            (.disposed, back, inspection, .deleteIdenticalCopy),
        ]
        for (phase, layout, snapshot, expected) in gated {
            let early = decide(phase, layout, streak: 1, inspection: snapshot)
            XCTAssertNotEqual(early, expected, "\(phase) must not \(expected) on the first clean probe")
            if case .reject = early { XCTFail("\(phase) rejected a clean layout") }
            XCTAssertEqual(decide(phase, layout, streak: 2, inspection: snapshot), expected)
            let busy = decide(phase, layout, probe: .busy, streak: 2, inspection: snapshot)
            XCTAssertNotEqual(busy, expected)
        }
    }
}
