import XCTest
import Foundation
import DisklesslyCore
@testable import DisklesslyEngine

/// Records every command and answers from a script. Nothing reaches a real binary.
final class FakeSystemRunner: SystemCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var answer: (String, [String]) -> SystemCommandResult

    init(_ answer: @escaping (String, [String]) -> SystemCommandResult = { _, _ in SystemCommandResult(status: 0) }) {
        self.answer = answer
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> SystemCommandResult {
        lock.lock(); calls.append([executable] + arguments); lock.unlock()
        return answer(executable, arguments)
    }

    var recorded: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}

final class HiddenUsageTests: XCTestCase {
    private var root: URL!
    private let gib: UInt64 = 1 << 30

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func engine() -> DisklesslyEngine {
        let config = RuntimeConfig(repoPath: root.appendingPathComponent("no-repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        return DisklesslyEngine(config: config, secrets: MemorySecretStore())
    }

    private func user(_ name: String, _ bytes: UInt64) -> UsageInputs.Entry {
        var entry = UsageInputs.Entry(name: name, bytes: bytes)
        entry.path = "/Users/" + name
        return entry
    }

    // MARK: Reconciliation math

    func testBreakdownOrdersMeasuredThenEstimateThenLikelySpotlightAndSumsToGap() {
        var facts = HiddenUsageFacts()
        facts.otherUsers = [user("alice", 10 * gib), user("Shared", 5 * gib)]
        facts.snapshots = ["com.apple.TimeMachine.2026-11-20-101010.local"]
        facts.purgeableBytes = 30 * gib
        let parts = HiddenUsage.breakdown(gap: 100 * gib, facts: facts)
        XCTAssertEqual(parts.map(\.key), ["otherusers", "snapshots", "spotlight-likely"])
        XCTAssertEqual(parts.map(\.bytes), [15 * gib, 30 * gib, 55 * gib])
        XCTAssertEqual(parts.reduce(0) { $0 + $1.bytes }, 100 * gib)
        XCTAssertEqual(parts[0].children.map(\.name), ["alice", "Shared"])
        XCTAssertEqual(parts[1].reconcile, HiddenUsage.thinSnapshots)
        XCTAssertEqual(parts[2].reconcile, HiddenUsage.measureSpotlight)
    }

    func testLargePurgeableWithoutSnapshotsDoesNotHideTheSpotlightRemainder() {
        // This Mac's case: no local snapshots, a few GB purgeable (caches/iCloud files du already counted).
        var facts = HiddenUsageFacts()
        facts.purgeableBytes = 500 * gib
        let parts = HiddenUsage.breakdown(gap: 120 * gib, facts: facts)
        XCTAssertEqual(parts.map(\.key), ["spotlight-likely"])
        XCTAssertEqual(parts.first?.bytes, 120 * gib)
        XCTAssertFalse(parts.contains { $0.reconcile == HiddenUsage.thinSnapshots }, "no thin action without snapshots")
    }

    func testMeasuredSpotlightComesBeforeTheEstimateAndTheRestIsUnexplained() {
        var facts = HiddenUsageFacts()
        facts.usedBytes = 200 * gib
        facts.spotlight = SpotlightMeasurement(bytes: 40 * gib, measuredAt: Date())
        facts.snapshots = ["s1"]
        facts.purgeableBytes = 10 * gib
        let parts = HiddenUsage.breakdown(gap: 100 * gib, facts: facts)
        XCTAssertEqual(parts.map(\.key), ["spotlight", "snapshots", "unexplained"])
        XCTAssertEqual(parts.map(\.bytes), [40 * gib, 10 * gib, 50 * gib])
        XCTAssertEqual(parts[0].reconcile, HiddenUsage.rebuildSpotlight, "40 GB is above max(20 GB, 5% of 200 GB)")

        facts.purgeableBytes = 300 * gib
        let clamped = HiddenUsage.breakdown(gap: 100 * gib, facts: facts)
        XCTAssertEqual(clamped.map(\.key), ["spotlight", "snapshots"])
        XCTAssertEqual(clamped.map(\.bytes), [40 * gib, 60 * gib], "the estimate is clamped to what is left of the gap")
    }

    func testGapSmallerThanOtherUsersIsClampedAndZeroGapHasNoParts() {
        var facts = HiddenUsageFacts()
        facts.otherUsers = [user("bob", 50 * gib)]
        XCTAssertEqual(HiddenUsage.breakdown(gap: 8 * gib, facts: facts).map(\.bytes), [8 * gib])
        XCTAssertTrue(HiddenUsage.breakdown(gap: 0, facts: facts).isEmpty)
    }

    // MARK: Threshold

    func testSpotlightThresholdIsMaxOfTwentyGBAndFivePercentOfUsed() {
        XCTAssertEqual(HiddenUsage.spotlightThreshold(usedBytes: 100 * gib), 20 * gib)
        XCTAssertEqual(HiddenUsage.spotlightThreshold(usedBytes: 1000 * gib), 50 * gib)
        XCTAssertFalse(HiddenUsage.spotlightAbnormal(20 * gib, usedBytes: 100 * gib), "exactly the threshold is not abnormal")
        XCTAssertTrue(HiddenUsage.spotlightAbnormal(20 * gib + 1, usedBytes: 100 * gib))
        XCTAssertFalse(HiddenUsage.spotlightAbnormal(45 * gib, usedBytes: 1000 * gib))
        XCTAssertTrue(HiddenUsage.spotlightAbnormal(170 * gib, usedBytes: 1000 * gib))

        var facts = HiddenUsageFacts()
        facts.usedBytes = 1000 * gib
        facts.spotlight = SpotlightMeasurement(bytes: 6 * gib, measuredAt: Date())
        let healthy = HiddenUsage.breakdown(gap: 10 * gib, facts: facts)
        XCTAssertNil(healthy.first { $0.key == "spotlight" }?.reconcile, "a healthy index is not offered for rebuild")
        let report = ReconcileReport(facts: { var f = facts; f.gapBytes = 10 * gib; return f }(), models: [])
        XCTAssertFalse(report.suggestions().contains { $0.action == HiddenUsage.rebuildSpotlight })
    }

    // MARK: Command lines

    func testCommandLinesAreExact() {
        XCTAssertEqual(HiddenUsage.listSnapshotsCommand().0, "/usr/bin/tmutil")
        XCTAssertEqual(HiddenUsage.listSnapshotsCommand().1, ["listlocalsnapshots", "/"])
        XCTAssertEqual(HiddenUsage.thinSnapshotsCommand(bytes: 123).1, ["thinlocalsnapshots", "/", "123", "4"])
        XCTAssertEqual(HiddenUsage.thinSnapshotsCommand(bytes: 0).1, ["thinlocalsnapshots", "/", "1", "4"])
        let measure = HiddenUsage.measureSpotlightCommand()
        XCTAssertEqual(measure.0, "/usr/bin/osascript")
        XCTAssertEqual(measure.1, ["-e", "do shell script \"/usr/bin/du -skx \" & quoted form of \"/System/Volumes/Data/.Spotlight-V100\" with administrator privileges"])
        let rebuild = HiddenUsage.rebuildSpotlightCommand()
        XCTAssertEqual(rebuild.0, "/usr/bin/osascript")
        XCTAssertEqual(rebuild.1, ["-e", "do shell script \"/usr/bin/mdutil -E \" & quoted form of \"/System/Volumes/Data\" with administrator privileges"])
        XCTAssertEqual(HiddenUsage.openFilesCommand().1, ["-n", "-w", "-F", "n"])
    }

    func testLiveRunnerRefusesSystemChangingCommandsInsideTests() {
        XCTAssertTrue(LiveSystemCommandRunner.insideTests)
        for (exe, args) in [HiddenUsage.rebuildSpotlightCommand(), HiddenUsage.measureSpotlightCommand(), HiddenUsage.thinSnapshotsCommand(bytes: 1),
                            ("/usr/bin/mdutil", ["-E", "/"]), ("/usr/bin/mdutil", ["-i", "off", "/"]), ("/usr/bin/tmutil", ["deletelocalsnapshots", "/"]),
                            ("/usr/bin/sudo", ["true"])] {
            XCTAssertTrue(LiveSystemCommandRunner.changesSystem(exe, args), "\(exe) \(args)")
        }
        for (exe, args) in [("/usr/bin/mdutil", ["-s", "/"]), ("/usr/bin/mdutil", ["-s", "-v", "/System/Volumes/Data"]),
                            HiddenUsage.listSnapshotsCommand(), ("/usr/bin/osascript", ["-e", "return 1"]), ("/usr/bin/du", ["-sk", "/tmp"])] {
            XCTAssertFalse(LiveSystemCommandRunner.changesSystem(exe, args), "\(exe) \(args)")
        }
        // A path that cannot start (127) proves the refusal (126) happens before any process is launched.
        let refused = LiveSystemCommandRunner().run("/nonexistent-\(UUID().uuidString)/mdutil", ["-E", "/"], timeout: 1)
        XCTAssertEqual(refused.status, 126)
        XCTAssertTrue(refused.stderr.contains("refused inside tests"))
        let notRefused = LiveSystemCommandRunner().run("/nonexistent-\(UUID().uuidString)/mdutil", ["-s", "/"], timeout: 1)
        XCTAssertEqual(notRefused.status, 127)
    }

    // MARK: Parsing

    func testParsing() {
        XCTAssertEqual(HiddenUsage.parseSnapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-20-101010.local\n  com.apple.TimeMachine.2026-11-21-101010.local\n"),
                       ["com.apple.TimeMachine.2026-11-20-101010.local", "com.apple.TimeMachine.2026-11-21-101010.local"])
        XCTAssertEqual(HiddenUsage.parseSnapshots("Snapshots for disk /:\n"), [])
        XCTAssertEqual(HiddenUsage.parseDU("170000\t/System/Volumes/Data/.Spotlight-V100\n"), 170000 * 1024)
        XCTAssertNil(HiddenUsage.parseDU(""))
        XCTAssertTrue(HiddenUsage.isCancelled(SystemCommandResult(status: 1, stderr: "execution error: User canceled. (-128)")))
        XCTAssertFalse(HiddenUsage.isCancelled(SystemCommandResult(status: 0)))
        let denied = HiddenUsage.parseDenied("du: /Users/me/Library/Mail: Operation not permitted\ndu: /Users/me/Library/Mail/V10: Permission denied\ndu: weird\nsomething else\n")
        XCTAssertEqual(denied, ["/Users/me/Library/Mail", "/Users/me/Library/Mail/V10"])
        XCTAssertEqual(HiddenUsage.collapseDenied(denied + ["/Users/me/Library/Safari"]), ["/Users/me/Library/Mail", "/Users/me/Library/Safari"])
    }

    // MARK: Gathering through the runner

    func testGatherListsSnapshotsAndSizesReadableOtherUsersOnly() throws {
        let users = root.appendingPathComponent("Users")
        for name in ["me", "alice", "Shared", ".localized-dir"] {
            try FileManager.default.createDirectory(at: users.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let locked = users.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let runner = FakeSystemRunner { exe, args in
            if exe == "/usr/bin/tmutil" { return SystemCommandResult(status: 0, stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-22-080000.local\n") }
            if exe == "/usr/bin/du" { return SystemCommandResult(status: 1, stdout: "2048\t\(args.last ?? "")\n") }
            return SystemCommandResult(status: 99)
        }
        let facts = HiddenUsage.gather(runner: runner, home: users.appendingPathComponent("me").path, usersRoot: users.path, volume: root.path,
                                       stateDir: root.appendingPathComponent("state").path, unreadable: ["/a/b", "/a"])
        XCTAssertEqual(facts.snapshots, ["com.apple.TimeMachine.2026-11-22-080000.local"])
        // Root (Linux CI containers) can read a 000 folder, so it is sized there too.
        XCTAssertEqual(facts.otherUsers.map(\.name).sorted(), geteuid() == 0 ? ["Shared", "alice", "locked"] : ["Shared", "alice"])
        XCTAssertEqual(facts.otherUsers.first?.bytes, 2 * 1024 * 1024)
        XCTAssertEqual(facts.unreadable, ["/a"])
        XCTAssertNil(facts.spotlight)
        let executables = Set(runner.recorded.map { $0[0] })
        XCTAssertEqual(executables, ["/usr/bin/tmutil", "/usr/bin/du"], "gathering only lists snapshots and sizes folders")
        XCTAssertTrue(runner.recorded.contains(["/usr/bin/tmutil", "listlocalsnapshots", "/"]))
        XCTAssertFalse(runner.recorded.contains { $0.last?.hasSuffix("/me") == true }, "the user's own home is never sized here")
        if geteuid() != 0 { XCTAssertFalse(runner.recorded.contains { $0.last == locked.path }, "an unreadable folder is skipped") }
    }

    // MARK: Actions through the runner

    func testMeasureCachesTheSizeAndRebuildClearsItCancelKeepsIt() throws {
        let engine = engine()
        let state = engine.config.stateDir
        let now = Date()
        let runner = FakeSystemRunner { _, _ in SystemCommandResult(status: 0, stdout: "178257920\t/System/Volumes/Data/.Spotlight-V100\n") }
        XCTAssertEqual(try HiddenUsage.perform(HiddenUsage.measureSpotlight, engine: engine, runner: runner, processes: { [] }, home: root.path, now: now),
                       .done("Spotlight index: \(UInt64(178257920) * 1024) bytes"))
        XCTAssertEqual(runner.recorded, [[HiddenUsage.measureSpotlightCommand().0] + HiddenUsage.measureSpotlightCommand().1])
        XCTAssertEqual(HiddenUsage.loadSpotlight(stateDir: state, now: now)?.bytes, 178257920 * 1024)
        XCTAssertNil(HiddenUsage.loadSpotlight(stateDir: state, now: now.addingTimeInterval(8 * 86_400)), "an old measurement is not used")

        let cancel = FakeSystemRunner { _, _ in SystemCommandResult(status: 1, stderr: "0:85: execution error: User canceled. (-128)") }
        XCTAssertEqual(try HiddenUsage.perform(HiddenUsage.rebuildSpotlight, engine: engine, runner: cancel, processes: { [] }, home: root.path), .cancelled)
        XCTAssertNotNil(HiddenUsage.loadSpotlight(stateDir: state, now: now), "a cancelled rebuild keeps the measurement")

        let rebuild = FakeSystemRunner()
        _ = try HiddenUsage.perform(HiddenUsage.rebuildSpotlight, engine: engine, runner: rebuild, processes: { [] }, home: root.path)
        XCTAssertEqual(rebuild.recorded, [["/usr/bin/osascript"] + HiddenUsage.rebuildSpotlightCommand().1])
        XCTAssertNil(HiddenUsage.loadSpotlight(stateDir: state, now: now))

        let failing = FakeSystemRunner { _, _ in SystemCommandResult(status: 1, stderr: "boom") }
        XCTAssertThrowsError(try HiddenUsage.perform(HiddenUsage.measureSpotlight, engine: engine, runner: failing, processes: { [] }, home: root.path))
    }

    func testThinSnapshotsRunsTmutilThinOnly() throws {
        let runner = FakeSystemRunner()
        _ = try HiddenUsage.perform(HiddenUsage.thinSnapshots, engine: engine(), runner: runner, processes: { [] }, home: root.path, volume: root.path)
        XCTAssertEqual(runner.recorded.count, 1)
        XCTAssertEqual(Array(runner.recorded[0].prefix(3)), ["/usr/bin/tmutil", "thinlocalsnapshots", "/"])
        XCTAssertEqual(runner.recorded[0].last, "4")
    }

    // MARK: In-use gating

    func testModelInUseByOwnerProcessExecutableInsideOrOpenFile() {
        let ollama = AIModelLocations.location(id: "model-ollama")!
        let hf = AIModelLocations.location(id: "model-hf")!
        let path = "/Users/me/.ollama/models"
        XCTAssertEqual(HiddenUsage.inUse(ollama, path: path, processes: [(42, "/Applications/Ollama.app/Contents/Resources/ollama")], openFiles: []).count, 1)
        XCTAssertTrue(HiddenUsage.inUse(ollama, path: path, processes: [(7, "/usr/bin/vim")], openFiles: []).isEmpty)
        XCTAssertEqual(HiddenUsage.inUse(hf, path: "/Users/me/.cache/huggingface", processes: [], openFiles: ["/Users/me/.cache/huggingface/hub/models--x/blobs/abc"]).count, 1)
        XCTAssertTrue(HiddenUsage.inUse(hf, path: "/Users/me/.cache/huggingface", processes: [], openFiles: ["/Users/me/.cache/huggingface-other/x"]).isEmpty, "a sibling folder with the same prefix is not inside")
        XCTAssertEqual(HiddenUsage.inUse(hf, path: "/Users/me/.cache/huggingface", processes: [(9, "/Users/me/.cache/huggingface/bin/tool")], openFiles: []).count, 1)
    }

    func testModelActionsAreRefusedWhileInUseAndNothingIsChanged() throws {
        let models = root.appendingPathComponent(".ollama/models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: models.appendingPathComponent("blob"))
        let runner = FakeSystemRunner()
        for action in [HiddenUsage.modelTrashPrefix + "model-ollama", HiddenUsage.modelOffloadPrefix + "model-ollama"] {
            XCTAssertThrowsError(try HiddenUsage.perform(action, engine: engine(), runner: runner, processes: { [(42, "/usr/local/bin/ollama")] }, home: root.path)) { error in
                XCTAssertTrue("\(error)".contains("Quit it first"), "\(error)")
            }
        }
        // Not running, but a file under it is open (lsof answer from the fake runner).
        let open = FakeSystemRunner { exe, _ in
            exe == HiddenUsage.lsof ? SystemCommandResult(status: 0, stdout: "p99\nn\(HiddenUsage.realPath(models.path))/blob\n") : SystemCommandResult(status: 0)
        }
        XCTAssertThrowsError(try HiddenUsage.perform(HiddenUsage.modelTrashPrefix + "model-ollama", engine: engine(), runner: open, processes: { [] }, home: root.path))
        XCTAssertTrue(open.recorded.contains([HiddenUsage.lsof] + HiddenUsage.openFilesCommand().1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: models.appendingPathComponent("blob").path))

        let listed = HiddenUsage.models(home: root.path, runner: runner, processes: [(42, "/usr/local/bin/ollama")])
        XCTAssertEqual(listed.map(\.location.id), ["model-ollama"])
        XCTAssertTrue(listed[0].inUse)
        XCTAssertNotNil(listed[0].lastUsed)
        XCTAssertGreaterThan(listed[0].bytes, 0)
        XCTAssertFalse(ReconcileReport(facts: HiddenUsageFacts(), models: listed).suggestions().contains { $0.action.contains("model-ollama") }, "an in-use model is never suggested")
    }

    // MARK: Bulk safety and wiring

    func testReconcileActionsAreNeverCleanupsAndTheTreeCarriesThemApartFromAction() {
        for action in [HiddenUsage.thinSnapshots, HiddenUsage.measureSpotlight, HiddenUsage.rebuildSpotlight, HiddenUsage.modelTrashPrefix + "model-hf", HiddenUsage.modelOffloadPrefix + "model-hf"] {
            XCTAssertFalse(UsageCleanup.known(action), action)
            XCTAssertTrue(HiddenUsage.isAction(action), action)
        }
        XCTAssertFalse(HiddenUsage.isAction("model-trash:unknown"))
        XCTAssertFalse(HiddenUsage.isAction(UsageCleanup.derivedData))
        for location in AIModelLocations.all {
            XCTAssertFalse(KnownLocations.rebuildableCaches.contains { $0.relativePath == location.relativePath }, "model folders are not bulk-cleanable caches")
        }

        var input = UsageInputs(totalBytes: 500 * gib, freeBytes: 100 * gib)
        input.personal = [.init(name: "Documents", bytes: 200 * gib, kind: .personal)]
        input.system = [.init(name: "macOS", bytes: 50 * gib, key: "macos")]
        var facts = HiddenUsageFacts()
        facts.snapshots = ["s"]
        facts.purgeableBytes = 20 * gib
        input.hidden = facts
        let tree = UsageMap.assemble(input)
        let system = tree.children.first { $0.key == "system" }!
        let unmeasured = system.children.first { $0.key == "unmeasured" }!
        XCTAssertEqual(unmeasured.bytes, 150 * gib)
        XCTAssertEqual(unmeasured.children.map(\.key), ["snapshots", "spotlight-likely"])
        XCTAssertEqual(unmeasured.children.reduce(0) { $0 + $1.bytes }, unmeasured.bytes)
        XCTAssertTrue(unmeasured.children.allSatisfy { $0.action == nil }, "no cleanup id, so no cleanup list or bulk path can run them")
        XCTAssertEqual(unmeasured.children.map(\.reconcile), [HiddenUsage.thinSnapshots, HiddenUsage.measureSpotlight])
        let found = ReconcileReport.facts(in: tree)
        XCTAssertEqual(found?.gapBytes, 150 * gib)
        XCTAssertEqual(found?.usedBytes, 400 * gib)
        let json = unmeasured.jsonObject()
        XCTAssertNotNil(json["hidden"] as? [String: Any])
        XCTAssertEqual(((json["children"] as? [[String: Any]])?.first)?["reconcile"] as? String, HiddenUsage.thinSnapshots)

        // Without facts (Linux, or an injected tree), "Not measured" stays one box as before.
        input.hidden = nil
        let plain = UsageMap.assemble(input).children.first { $0.key == "system" }!.children.first { $0.key == "unmeasured" }!
        XCTAssertTrue(plain.children.isEmpty)
    }

    func testRemoteProbeSharesTheModelListAndKeepsTheOldRows() {
        let script = RemoteScanProbe.combinedScript
        XCTAssertTrue(script.contains("probe_dir \"model-hf\" \"model-cache\" \"HuggingFace Hub models\" \"$HOME/.cache/huggingface\" \"offload\" \"true\" \"Large AI model weights; can be offloaded to repo or re-downloaded\"\n"))
        XCTAssertTrue(script.contains("probe_dir \"model-ollama\" \"model-cache\" \"Ollama models\" \"$HOME/.ollama/models\" \"offload\" \"true\" \"Ollama LLM blobs; can be offloaded to repo\"\n"))
        for location in AIModelLocations.all { XCTAssertTrue(script.contains("\"\(location.id)\" \"model-cache\""), location.id) }
        XCTAssertTrue(script.contains("\"Crash core dump files\"\nprobe_dir \"model-hf\""), "the model rows join the script on their own lines")
        XCTAssertTrue(script.contains("can be offloaded to repo\"\nprobe_dir \"model-lmstudio\""))
    }

    // MARK: Dashboard API

    private func respond(_ engine: DisklesslyEngine, _ method: String, _ path: String, body: [String: Any]? = nil, context: ManagementUIContext) throws -> (Int, [String: Any]) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: method, path: path, body: data), context: context)
        return (response.status, try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
    }

    func testDashboardActionNeedsItsOwnConfirmationAndUsesTheInjectedRunner() throws {
        let engine = engine()
        let scans = Counter()
        let usage = UsageScanner(run: { _, _ in scans.add(); return (UsageMap.assemble(UsageInputs(totalBytes: 10, freeBytes: 5)), false) })
        let context = ManagementUIContext(platform: .macOS, usage: usage)
        let runner = FakeSystemRunner { _, _ in SystemCommandResult(status: 0, stdout: "1024\t/System/Volumes/Data/.Spotlight-V100\n") }
        context.reconcileRunner = runner
        context.reconcileProcesses = { [] }
        context.home = root.path

        let (noScan, empty) = try respond(engine, "GET", "/api/reconcile", context: context)
        XCTAssertEqual(noScan, 200)
        XCTAssertEqual(empty["state"] as? String, "noscan")

        XCTAssertEqual(try respond(engine, "POST", "/api/reconcile/action", body: ["action": "derived-data", "confirm": true], context: context).0, 400)
        let (unconfirmed, refusal) = try respond(engine, "POST", "/api/reconcile/action", body: ["action": HiddenUsage.rebuildSpotlight], context: context)
        XCTAssertEqual(unconfirmed, 400)
        XCTAssertEqual((refusal["error"] as? [String: Any])?["code"] as? String, "confirm_required")
        XCTAssertFalse(runner.recorded.contains { $0.contains { $0.contains("mdutil") } })
        // The bulk cleanup route refuses reconcile ids.
        XCTAssertEqual(try respond(engine, "POST", "/api/usage/clean", body: ["action": HiddenUsage.rebuildSpotlight], context: context).0, 400)

        let (accepted, _) = try respond(engine, "POST", "/api/reconcile/action", body: ["action": HiddenUsage.measureSpotlight, "confirm": true], context: context)
        XCTAssertEqual(accepted, 202)
        let deadline = Date().addingTimeInterval(10)
        while context.cleaner.snapshot()["state"] as? String == "running", Date() < deadline { usleep(20_000) }
        XCTAssertEqual(context.cleaner.snapshot()["state"] as? String, "done")
        XCTAssertEqual(runner.recorded, [["/usr/bin/osascript"] + HiddenUsage.measureSpotlightCommand().1])
        XCTAssertEqual(HiddenUsage.loadSpotlight(stateDir: engine.config.stateDir)?.bytes, 1024 * 1024)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
