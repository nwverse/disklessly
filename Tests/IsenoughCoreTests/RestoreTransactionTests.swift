import XCTest
@testable import IsenoughCore
@testable import IsenoughEngine

/// Filesystem fixture for one restore-mode app. Services are in-process fakes;
/// the journal, staging directory and bundles are real.
final class RestoreWorld {
    let root: URL
    let dest: URL
    let template: URL
    let bundleID = "com.example.foo"
    var stubBundleID: String { bundleID + ".256stub" }
    let manifest: ImageManifest
    let engine: IsenoughEngine
    let trace: RestoreTrace
    var probe: UsageClass = .clean

    var stateURL: URL { URL(fileURLWithPath: engine.config.stateDir).appendingPathComponent("state.json") }

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("isenough-restore-\(UUID().uuidString)")
        dest = root.appendingPathComponent("Applications/Foo.app")
        template = root.appendingPathComponent("volume/Foo.app")
        let stubID = bundleID + ".256stub"
        try Self.writeBundle(template, bundleID: bundleID, executable: "Foo", body: "real-binary-v1")
        try Self.writeBundle(dest, bundleID: stubID, executable: "isenough-stub", body: "stub-binary")
        let imageBytes = Data("restore-image-bytes-v1".utf8)
        let imageFile = root.appendingPathComponent("image.dmg")
        try imageBytes.write(to: imageFile)
        let sha = SHA256Digest.hex(imageBytes)
        let summed = try Hashing.sha256(imageFile)
        if sha != summed {
            throw IsenoughError.failure("SHA256Digest \(sha) != sha256sum \(summed)")
        }
        let cdhash = try BundleHasher.cdhash(of: template)
        let tree = try BundleHasher.treeHash(of: template)
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mounts").path,
            stubDir: root.appendingPathComponent("Applications").path
        )
        config.detachDelaySeconds = 0
        let image = ImageManifest.Image(file: "", format: "ULMO", sha256: sha, size: UInt64(imageBytes.count), volumeName: "Foo", appPathInVolume: "Foo.app")
        manifest = ImageManifest(
            bundleId: bundleID,
            name: "Foo",
            version: "1.0",
            image: image,
            app: .init(originalPath: dest.path, executable: "Foo", documentTypes: [], urlTypes: [], cdhash: cdhash, treeHash: tree),
            mode: .restore
        )
        try fm.createDirectory(at: URL(fileURLWithPath: config.repoPath).appendingPathComponent("images"), withIntermediateDirectories: true)
        try imageBytes.write(to: URL(fileURLWithPath: config.repoPath).appendingPathComponent(manifest.image.file))
        try fm.createDirectory(at: URL(fileURLWithPath: config.repoPath).appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try manifest.encode().write(to: URL(fileURLWithPath: config.repoPath).appendingPathComponent("manifests/\(manifest.imageId).json"))
        try fm.createDirectory(at: URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images"), withIntermediateDirectories: true)
        try imageBytes.write(to: URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg"))
        try fm.createDirectory(at: URL(fileURLWithPath: config.stateDir), withIntermediateDirectories: true)
        let trace = RestoreTrace()
        let template = self.template
        let services = RestoreServices(
            attach: { _, mount in
                try fm.createDirectory(at: mount, withIntermediateDirectories: true)
                let placed = mount.appendingPathComponent("Foo.app")
                if fm.fileExists(atPath: placed.path) { try fm.removeItem(at: placed) }
                try fm.copyItem(at: template, to: placed)
                trace.attached.append(mount)
                return mount
            },
            extract: { mount, appPath, dest in
                let source = mount.appendingPathComponent(appPath)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source, to: dest)
                if trace.plantSidecar {
                    try Data("provenance-\(UUID().uuidString)".utf8).write(to: dest.appendingPathComponent("Contents/._Info.plist"))
                }
                if trace.corruptExtraction {
                    try Data("tampered\n".utf8).write(to: dest.appendingPathComponent("Contents/tamper.txt"))
                }
            },
            detach: { mount in
                trace.detached.append(mount)
                if fm.fileExists(atPath: mount.path) { try? fm.removeItem(at: mount) }
            },
            probe: { _ in trace.probe },
            isAlive: { trace.alive.contains($0.pid) },
            spawnWatch: { _ in
                let owner = ProcessOwner(pid: 4242, start: 7)
                trace.spawned.append(owner)
                trace.alive.insert(owner.pid)
                return owner
            },
            openApp: { url, _, _, _ in trace.opened.append(url.path) },
            cdhash: { try BundleHasher.cdhash(of: $0) },
            treeHash: { try BundleHasher.treeHash(of: $0) },
            signatureValid: { trace.signatureValid($0) },
            archiveVerified: { RestoreArchive.verified($0, config: config) },
            buildStub: { dest, journal in try StubRebuilder.write(at: dest, journal: journal, config: config) },
            now: { trace.now },
            sleep: { _ in trace.sleeps += 1 },
            runHook: { url, env in
                trace.hooks.append(env["ISENOUGH_PHASE"] ?? "")
                return try ProcessRunner.runHook(url, env)
            }
        )
        engine = IsenoughEngine(config: config, services: services, faults: FaultController())
        self.trace = trace
        engine.restore.probeIntervalOverride = 0
        engine.restore.detachDelayOverride = 0
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func launch(wait: Bool) throws {
        trace.probe = probe
        try engine.launch(manifest, wait: wait)
    }

    func recover(wait: Bool = false, shortLived: Bool = false) throws -> RecoverResult {
        trace.probe = probe
        return try engine.restore.recover(appId: bundleID, wait: wait, shortLived: shortLived)
    }

    func journals() -> [RestoreJournal] {
        (try? JournalStore.loadAll(stateDir: engine.config.stateDir))?.filter { $0.appId == bundleID } ?? []
    }

    func bundleID(at url: URL) -> String? {
        BundleFacts.readInfo(url)?["CFBundleIdentifier"] as? String
    }

    var outcomeName: String? {
        let apps = StateStore(engine.config.stateDir).read()["apps"] as? [String: [String: Any]]
        return (apps?[bundleID]?["lastOutcome"] as? [String: Any])?["name"] as? String
    }

    var needsResolution: [String: Any]? { engine.restore.needsResolution(bundleID) }

    func stateBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return Data() }
        return try Data(contentsOf: stateURL)
    }

    func arm(_ phase: String, _ edge: String) {
        engine.faults.mode = .raised
        engine.faults.points = ["\(phase):\(edge)"]
    }

    func disarm() {
        engine.faults.mode = .off
        engine.faults.points = []
    }

    static func writeBundle(_ url: URL, bundleID: String, executable: String, body: String, extra: String? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundleExecutable</key><string>\(executable)</string>
        <key>CFBundleName</key><string>Foo</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(body.utf8).write(to: url.appendingPathComponent("Contents/MacOS/\(executable)"))
        if let extra {
            try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data(extra.utf8).write(to: url.appendingPathComponent("Contents/Resources/extra.txt"))
        }
    }

    func installHook(_ phase: String, _ script: String) throws {
        let url = URL(fileURLWithPath: engine.config.stateDir).appendingPathComponent("hooks/\(bundleID)/\(phase)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func assertTerminalStub(file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try recover()
        switch result {
        case .idle, .terminal: break
        default: XCTFail("first recovery \(result) \(debugDump())", file: file, line: line)
        }
        let again = try recover()
        switch again {
        case .idle, .terminal: break
        default: XCTFail("second recovery \(again) \(debugDump())", file: file, line: line)
        }
        XCTAssertTrue(journals().isEmpty, debugDump(), file: file, line: line)
        XCTAssertEqual(bundleID(at: dest), stubBundleID, debugDump(), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: template.path), file: file, line: line)
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".256isenough-staging")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "staging leftovers \(leftovers) \(debugDump())", file: file, line: line)
        let restored = StateStore(engine.config.stateDir).read()["restored"] as? [String: Any] ?? [:]
        XCTAssertNil(restored[bundleID], file: file, line: line)
        let first = try stateBytes()
        _ = try recover()
        XCTAssertEqual(try stateBytes(), first, "third recovery rewrote state", file: file, line: line)
    }

    func debugDump() -> String {
        let phase = journals().map(\.phase.rawValue).joined(separator: ",")
        let events = engine.restore.events.joined(separator: ",")
        return "phase=\(phase) events=\(events) opened=\(trace.opened) detached=\(trace.detached.map(\.path))"
    }
}

final class RestoreTrace {
    var probe: UsageClass = .clean
    var probeProvider: () -> UsageClass = { .clean }
    var alive: Set<Int32> = []
    var spawned: [ProcessOwner] = []
    var opened: [String] = []
    var attached: [URL] = []
    var detached: [URL] = []
    var plantSidecar = false
    var corruptExtraction = false
    var hooks: [String] = []
    var sleeps = 0
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var signatureValid: (URL) -> Bool = { BundleHasher.signatureValid($0) }
}

final class RestoreTransactionTests: XCTestCase {
    func testProbeIgnoresLaunchingStubAcrossPrivateVar() {
        let root = "/var/folders/ab/T/isenough-e2e.x/Applications/Restore.app"
        let privateRoot = "/private" + root
        let stub = privateRoot + "/Contents/MacOS/isenough-stub"
        let app = privateRoot + "/Contents/MacOS/Restore"
        let launching = [
            ProcessRow(pid: 10, ppid: 1, command: "bash scripts/e2e.sh"),
            ProcessRow(pid: 20, ppid: 10, command: stub),
            ProcessRow(pid: 30, ppid: 20, command: "/opt/debug/isenough launch io.example.restore"),
        ]
        XCTAssertEqual(ProcessProbe.usage(rows: launching, roots: [root], selfPid: 30), .clean)
        let running = launching + [ProcessRow(pid: 40, ppid: 1, command: app)]
        XCTAssertEqual(ProcessProbe.usage(rows: running, roots: [root], selfPid: 30), .busy)
        let helper = launching + [ProcessRow(pid: 41, ppid: 10, command: "tail -f \(root)/Contents/Info.plist")]
        XCTAssertEqual(ProcessProbe.usage(rows: helper, roots: [root], selfPid: 30), .busy)
        let symlinkShown = launching + [ProcessRow(pid: 42, ppid: 1, command: root + "/Contents/MacOS/Restore")]
        XCTAssertEqual(ProcessProbe.usage(rows: symlinkShown, roots: [privateRoot], selfPid: 30), .busy)
        let watcher = launching + [ProcessRow(pid: 43, ppid: 1, command: "/opt/debug/isenough --state-dir /s hook watch --app io.example.restore")]
        XCTAssertEqual(ProcessProbe.usage(rows: watcher, roots: [root], selfPid: 30), .clean)
    }

    /// Same URL listing `BundleHasher` uses. `subpathsOfDirectory` is not a substitute:
    /// on macOS it can name an AppleDouble file that `contentsOfDirectory` hides.
    private func hasherListing(_ directory: URL) throws -> [String] {
        let fm = FileManager.default
        var names: [String] = []
        func walk(_ dir: URL) throws {
            let children = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            for child in children {
                names.append(child.lastPathComponent)
                if DurableIO.isSymlink(child) { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                    try walk(child)
                }
            }
        }
        try walk(directory)
        return names
    }

    func testTreeHashIgnoresPrivateVarSpellingAndSidecarsAreRemovedBeforeHashing() throws {
        XCTAssertEqual(
            BundleHasher.relativePath("/private/var/folders/ab/T/e/Restore.app/Contents/Info.plist", root: "/var/folders/ab/T/e/Restore.app"),
            "Contents/Info.plist"
        )
        XCTAssertEqual(
            BundleHasher.relativePath("/var/folders/ab/T/e/Restore.app/Contents/MacOS/Restore", root: "/private/var/folders/ab/T/e/Restore.app"),
            "Contents/MacOS/Restore"
        )
        XCTAssertNil(BundleHasher.relativePath("/etc/passwd", root: "/var/folders/ab/T/e/Restore.app"))

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("isenough-hash-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("real/Restore.app")
        try RestoreWorld.writeBundle(real, bundleID: "com.example.hash", executable: "Restore", body: "binary", extra: "marker")
        let link = root.appendingPathComponent("link/Restore.app")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let linked = try BundleHasher.treeHash(of: link)
        XCTAssertEqual(try BundleHasher.treeHash(of: real), linked)
        let sidecar = real.appendingPathComponent("Contents/._Info.plist")
        try Data("provenance-unique".utf8).write(to: sidecar)
        let withSidecar = try BundleHasher.treeHash(of: real)
        if withSidecar != linked {
            // A listed AppleDouble file is part of the tree and must be deleted before hashing.
            BundleHasher.removeMetadataSidecars(real)
            XCTAssertFalse(fm.fileExists(atPath: sidecar.path))
            XCTAssertEqual(try BundleHasher.treeHash(of: real), linked)
        } else {
            // macOS can hide this AppleDouble name from contentsOfDirectory, which is the
            // listing the hasher uses, while subpathsOfDirectory still prints it. The hash
            // stays equal because that walk never sees the bytes. A sidecar the hasher
            // itself lists must change the hash.
            let seen = try hasherListing(real.resolvingSymlinksInPath())
            XCTAssertFalse(seen.contains { $0.hasPrefix("._") }, seen.joined(separator: ","))
            BundleHasher.removeMetadataSidecars(real)
            XCTAssertEqual(try BundleHasher.treeHash(of: real), linked)
        }
        let visible = real.appendingPathComponent("Contents/visible-extra.txt")
        try Data("visible".utf8).write(to: visible)
        XCTAssertNotEqual(try BundleHasher.treeHash(of: real), linked)
        BundleHasher.removeMetadataSidecars(real)
        XCTAssertTrue(fm.fileExists(atPath: visible.path))
        XCTAssertNotEqual(try BundleHasher.treeHash(of: real), linked)
    }

    func testMismatchedExtractionDetachesRollsBackAndLeavesNoMount() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.trace.corruptExtraction = true
        XCTAssertThrowsError(try world.launch(wait: true)) { error in
            guard case IsenoughError.integrity(let message) = error else {
                return XCTFail("expected integrity, got \(error) \(world.debugDump())")
            }
            XCTAssertTrue(message.hasPrefix("extracted bundle does not match manifest cdhash and tree hash"), message)
        }
        XCTAssertFalse(world.trace.attached.isEmpty, world.debugDump())
        XCTAssertEqual(world.trace.attached.count, world.trace.detached.count, world.debugDump())
        XCTAssertTrue(world.journals().isEmpty, world.debugDump())
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID, world.debugDump())
        XCTAssertEqual(world.outcomeName, "rolledBack", world.debugDump())
        let left = (try? FileManager.default.contentsOfDirectory(atPath: world.root.appendingPathComponent("mounts").path)) ?? []
        XCTAssertTrue(left.isEmpty, "mounts left behind: \(left)")
    }

    func testAppleDoubleSidecarIsStrippedBeforeTheManifestHash() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.trace.plantSidecar = true
        try world.launch(wait: true)
        XCTAssertEqual(world.outcomeName, "restoredOut", world.debugDump())
        XCTAssertEqual(world.trace.attached.count, world.trace.detached.count, world.debugDump())
    }

    private let phases = RestorePhase.allCases.map(\.rawValue)
    private let edges = ["beforeJournal", "afterJournal", "afterMutation"]

    func testFaultMatrixRecoversEveryPhaseEdge() throws {
        for phase in phases {
            for edge in edges {
                let world = try RestoreWorld()
                defer { world.cleanup() }
                world.arm(phase, edge)
                XCTAssertThrowsError(try world.launch(wait: true), "\(phase):\(edge) did not fault") { error in
                    guard let fault = error as? InjectedFault else {
                        XCTFail("\(phase):\(edge) threw \(error) \(world.debugDump())")
                        return
                    }
                    XCTAssertEqual(fault.point, "\(phase):\(edge)")
                }
                world.disarm()
                let attachedBeforeRecovery = world.trace.attached.count
                try world.assertTerminalStub()
                if phase == "extracted" && edge == "beforeJournal" {
                    XCTAssertGreaterThan(attachedBeforeRecovery, 0, "attach must happen before the extracted journal write")
                    XCTAssertFalse(world.trace.detached.isEmpty, "crash during attach must detach on recovery \(world.debugDump())")
                }
                if let detachAt = world.engine.restore.events.firstIndex(of: "detach"), let activeAt = world.engine.restore.events.firstIndex(of: "active") {
                    XCTAssertLessThan(detachAt, activeAt, "\(phase):\(edge) \(world.engine.restore.events)")
                }
                let name = world.outcomeName
                // prepared:beforeJournal fires before any journal, so recovery is a no-op.
                // active:beforeJournal is still the installed post-effect, which rolls back.
                // Every later edge completed forward and finishes as restoredOut.
                let rolledBack = ["prepared", "extracted", "stubParked", "installed"].contains(phase) || (phase == "active" && edge == "beforeJournal")
                if phase == "prepared" && edge == "beforeJournal" {
                    XCTAssertNil(name, world.debugDump())
                } else if rolledBack {
                    XCTAssertEqual(name, "rolledBack", "\(phase):\(edge) outcome \(name ?? "nil") \(world.debugDump())")
                } else {
                    XCTAssertEqual(name, "restoredOut", "\(phase):\(edge) outcome \(name ?? "nil") \(world.debugDump())")
                }
                XCTAssertNil(world.needsResolution, "\(phase):\(edge) unexpectedly retained \(world.debugDump())")
            }
        }
    }

    func testBusyOwnerHandsOffOnceAndSecondCallerNoops() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.arm("active", "afterMutation")
        XCTAssertThrowsError(try world.launch(wait: true))
        world.disarm()
        var journal = try XCTUnwrap(world.journals().first)
        journal.owner = ProcessOwner(pid: 1111, start: 3)
        try JournalStore.save(journal, stateDir: world.engine.config.stateDir)
        world.trace.alive = [1111]
        world.probe = .busy
        let joined = try world.recover(wait: false, shortLived: true)
        XCTAssertEqual(joined, .noop)
        XCTAssertFalse(world.engine.restore.events.contains("adopt"))
        XCTAssertEqual(world.journals().first?.owner.pid, 1111)
        XCTAssertEqual(world.bundleID(at: world.dest), world.bundleID)
        world.trace.alive = []
        let adopted = try world.recover(wait: false, shortLived: true)
        XCTAssertEqual(adopted, .waiting("busy"))
        XCTAssertEqual(world.engine.restore.events.filter { $0 == "adopt" }.count, 1)
        XCTAssertEqual(world.journals().first?.owner.pid, 4242)
        XCTAssertEqual(world.trace.spawned.count, 1)
        XCTAssertEqual(world.bundleID(at: world.dest), world.bundleID)
        let parked = URL(fileURLWithPath: world.journals().first!.staging).appendingPathComponent("stub.app")
        XCTAssertEqual(world.bundleID(at: parked), world.stubBundleID)
        let second = try world.recover(wait: false, shortLived: true)
        XCTAssertEqual(second, .noop)
        XCTAssertEqual(world.engine.restore.events.filter { $0 == "adopt" }.count, 1)
        XCTAssertEqual(world.trace.spawned.count, 1)
    }

    func testInstalledCleanRollbackDoesNotUpdateLastUsed() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.arm("installed", "afterMutation")
        XCTAssertThrowsError(try world.launch(wait: true))
        world.disarm()
        try world.assertTerminalStub()
        XCTAssertEqual(world.outcomeName, "rolledBack")
        let apps = StateStore(world.engine.config.stateDir).read()["apps"] as? [String: [String: Any]]
        XCTAssertNil(apps?[world.bundleID]?["lastUsed"])
    }

    func testReplacementAndTreeOnlyChangeAreRetained() throws {
        for mutateExecutable in [true, false] {
            let world = try RestoreWorld()
            defer { world.cleanup() }
            world.arm("active", "afterMutation")
            XCTAssertThrowsError(try world.launch(wait: true))
            world.disarm()
            if mutateExecutable {
                try Data("real-binary-v2".utf8).write(to: world.dest.appendingPathComponent("Contents/MacOS/Foo"))
            } else {
                try FileManager.default.createDirectory(at: world.dest.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
                try Data("note".utf8).write(to: world.dest.appendingPathComponent("Contents/Resources/note.txt"))
            }
            try world.assertTerminalStub()
            XCTAssertEqual(world.outcomeName, "restoredOutRetained")
            let record = try XCTUnwrap(world.needsResolution)
            let retained = try XCTUnwrap(record["retainedPath"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained))
            XCTAssertThrowsError(try world.launch(wait: true)) { error in
                XCTAssertEqual((error as? IsenoughError)?.exitCode, 14)
            }
            let again = try world.recover()
            switch again { case .idle, .terminal: break; default: XCTFail("\(again)") }
            let retainedDir = URL(fileURLWithPath: world.engine.config.stateDir).appendingPathComponent("retained/\(world.bundleID)")
            let copies = (try? FileManager.default.contentsOfDirectory(atPath: retainedDir.path)) ?? []
            XCTAssertEqual(copies.count, 1)
        }
    }

    func testMissingArchiveRetainsEvenAnIdenticalBundle() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.arm("active", "afterMutation")
        XCTAssertThrowsError(try world.launch(wait: true))
        world.disarm()
        let cache = URL(fileURLWithPath: world.engine.config.cacheDir).appendingPathComponent("images/\(world.manifest.imageId).dmg")
        let remote = URL(fileURLWithPath: world.engine.config.repoPath).appendingPathComponent(world.manifest.image.file)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.removeItem(at: remote)
        try world.assertTerminalStub()
        XCTAssertNotNil(world.needsResolution)
        XCTAssertEqual(world.outcomeName, "restoredOutRetained")
    }

    func testAmbiguousLayoutAndSymlinkAreNotDeleted() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.arm("active", "afterMutation")
        XCTAssertThrowsError(try world.launch(wait: true))
        world.disarm()
        let journal = try XCTUnwrap(world.journals().first)
        let mystery = URL(fileURLWithPath: journal.staging).appendingPathComponent("mystery")
        try Data("keep".utf8).write(to: mystery)
        let rejected = try world.recover()
        guard case .rejected = rejected else { XCTFail("expected reject, got \(rejected)"); return }
        XCTAssertEqual(try Data(contentsOf: mystery), Data("keep".utf8))
        XCTAssertEqual(world.bundleID(at: world.dest), world.bundleID)
        try FileManager.default.removeItem(at: mystery)
        try FileManager.default.removeItem(at: world.dest)
        try FileManager.default.createSymbolicLink(at: world.dest, withDestinationURL: world.template)
        let sym = try world.recover()
        guard case .rejected = sym else { XCTFail("symlink \(sym)"); return }
        XCTAssertTrue(DurableIO.isSymlink(world.dest))
        XCTAssertFalse(world.journals().isEmpty)
    }

    func testStaleMirrorRetiresOnlyAStubWithNoStaging() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        var object = StateStore(world.engine.config.stateDir).read()
        object["restored"] = [world.bundleID: ["dest": world.dest.path, "staging": world.root.appendingPathComponent("missing-staging").path, "txid": "gone"]]
        try StateStore(world.engine.config.stateDir).write(object)
        let retired = try world.recover()
        XCTAssertEqual(retired, .terminal("mirrorRetired"))
        let restored = StateStore(world.engine.config.stateDir).read()["restored"] as? [String: Any] ?? [:]
        XCTAssertNil(restored[world.bundleID])

        let real = world.root.appendingPathComponent("Applications/Bar.app")
        try RestoreWorld.writeBundle(real, bundleID: world.bundleID, executable: "Foo", body: "only-copy")
        object = StateStore(world.engine.config.stateDir).read()
        object["restored"] = [world.bundleID: ["dest": real.path, "staging": world.root.appendingPathComponent("still-here").path]]
        try FileManager.default.createDirectory(at: world.root.appendingPathComponent("still-here"), withIntermediateDirectories: true)
        try StateStore(world.engine.config.stateDir).write(object)
        let blocked = try world.recover()
        guard case .rejected = blocked else { XCTFail("\(blocked)"); return }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
        let issues = world.engine.doctor()["issues"] as? [String] ?? []
        XCTAssertFalse(issues.isEmpty)
    }

    func testPreLaunchHookMutationRollsBackAndRetains() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        try world.installHook("pre-launch", """
        #!/bin/sh
        mkdir -p "$ISENOUGH_APP_PATH/Contents/Resources"
        echo hooked >> "$ISENOUGH_APP_PATH/Contents/Resources/hooked.txt"
        exit 1
        """)
        try world.installHook("post-quit", "#!/bin/sh\necho post >> \"$ISENOUGH_STATE_DIR/post-quit.log\"\nexit 0\n")
        XCTAssertThrowsError(try world.launch(wait: true)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 10)
        }
        try world.assertTerminalStub()
        XCTAssertEqual(world.outcomeName, "rolledBack")
        XCTAssertNotNil(world.needsResolution)
        XCTAssertFalse(world.trace.hooks.contains("post-quit"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.engine.config.stateDir + "/post-quit.log"))
    }

    func testPostQuitHookRunsOnceAcrossRepeatedRecovery() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        try world.installHook("post-quit", "#!/bin/sh\necho post >> \"$ISENOUGH_STATE_DIR/post-quit.log\"\nexit 0\n")
        try world.launch(wait: true)
        try world.assertTerminalStub()
        let log = try String(contentsOfFile: world.engine.config.stateDir + "/post-quit.log", encoding: .utf8)
        XCTAssertEqual(log.filter { $0 == "\n" }.count, 1)
    }

    func testCorruptStubIsRegeneratedWithoutOverwritingARealBundle() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.arm("stubBack", "afterJournal")
        XCTAssertThrowsError(try world.launch(wait: true))
        world.disarm()
        let journal = try XCTUnwrap(world.journals().first)
        XCTAssertEqual(journal.phase, .stubBack)
        let parked = URL(fileURLWithPath: journal.staging).appendingPathComponent("stub.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
        try FileManager.default.removeItem(at: parked)
        try world.assertTerminalStub()
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
        XCTAssertTrue(world.engine.restore.events.contains("stubRegenerated"))
    }

    func testBusyDestinationDoesNotStartASecondTransaction() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.probe = .busy
        XCTAssertThrowsError(try world.launch(wait: true)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 9)
        }
        XCTAssertTrue(world.journals().isEmpty)
        XCTAssertEqual(world.bundleID(at: world.dest), world.stubBundleID)
    }

    func testResolveDiscardClearsResolutionAndKeepUpdatedRefusesOnLinux() throws {
        let world = try RestoreWorld()
        defer { world.cleanup() }
        world.arm("active", "afterMutation")
        XCTAssertThrowsError(try world.launch(wait: true))
        world.disarm()
        try Data("edited".utf8).write(to: world.dest.appendingPathComponent("Contents/MacOS/Foo"))
        try world.assertTerminalStub()
        // The text fixture is not a signed Mach-O. macOS `codesign --verify --strict` fails
        // before the cdhash check; force a valid signature so both platforms still require
        // EX_USAGE when the cdhash changed and `--trust` was not passed.
        world.trace.signatureValid = { _ in true }
        world.engine.restore.services.signatureValid = { _ in true }
        XCTAssertThrowsError(try world.engine.resolve(world.manifest, keepUpdated: true, trust: false, export: nil, discard: false)) { error in
            XCTAssertEqual((error as? IsenoughError)?.exitCode, 2)
        }
        XCTAssertNotNil(world.needsResolution)
        world.trace.signatureValid = { _ in false }
        world.engine.restore.services.signatureValid = { _ in false }
        XCTAssertThrowsError(try world.engine.resolve(world.manifest, keepUpdated: true, trust: true, export: nil, discard: false)) { error in
            XCTAssertEqual((error as? IsenoughError)?.errorDescription, "retained bundle has an invalid code signature; export or discard it")
        }
        world.engine.restore.services.signatureValid = { BundleHasher.signatureValid($0) }
        let export = world.root.appendingPathComponent("export")
        try world.engine.resolve(world.manifest, keepUpdated: false, trust: false, export: nil, discard: true)
        XCTAssertNil(world.needsResolution)
        _ = export
    }
}
