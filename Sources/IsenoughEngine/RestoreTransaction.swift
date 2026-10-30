import Foundation
import IsenoughCore
import IsenoughStubSupport
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum RecoverResult: Equatable {
    case idle
    case terminal(String)
    case waiting(String)
    case rejected(String)
    case noop
}

public struct RestoreServices {
    public var attach: (URL, URL) throws -> URL
    public var extract: (URL, String, URL) throws -> Void
    public var detach: (URL) throws -> Void
    public var probe: ([String]) -> UsageClass
    public var isAlive: (ProcessOwner) -> Bool
    public var spawnWatch: (String) throws -> ProcessOwner
    public var openApp: (URL, [String], [String], [String], Bool) throws -> Void
    public var cdhash: (URL) throws -> String
    public var treeHash: (URL) throws -> String
    public var signatureValid: (URL) -> Bool
    public var archiveVerified: (RestoreJournal) -> Bool
    public var buildStub: (URL, RestoreJournal) throws -> Void
    public var now: () -> Date
    public var sleep: (TimeInterval) -> Void
    public var runHook: (URL, [String: String]) throws -> Int32
    /// Production launches hand the post-quit loop to a detached `hook watch`.
    /// Tests leave this false and recover in-process.
    public var detachWatcher: Bool

    public static func live(config: RuntimeConfig) -> RestoreServices {
        let fm = FileManager.default
        return RestoreServices(
            attach: { image, mount in
                #if os(macOS)
                try fm.createDirectory(at: mount, withIntermediateDirectories: true)
                try LiveDiskImage.attach(image: image, mountPoint: mount)
                return mount
                #else
                _ = image
                throw IsenoughError.unsupported("restore extraction requires macOS hdiutil or a test filesystem")
                #endif
            },
            extract: { mount, appPath, dest in
                let source = mount.appendingPathComponent(appPath)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                #if os(macOS)
                try ProcessRunner.run("/usr/bin/ditto", [source.path, dest.path])
                #else
                try fm.copyItem(at: source, to: dest)
                #endif
            },
            detach: { mount in
                #if os(macOS)
                try LiveDiskImage.detach(mountPoint: mount, force: false)
                #else
                _ = mount
                #endif
            },
            probe: { roots in ProcessProbe.usage(roots: roots) },
            isAlive: { ProcessStart.isAlive($0) },
            spawnWatch: { appId in try ProcessRunner.spawnWatch(appId: appId, stateDir: config.stateDir) },
            openApp: { app, docs, urls, arguments, alreadyRunning in
                #if os(macOS)
                let built = OpenInvocation.arguments(app: app.path, documents: docs, urls: urls, arguments: arguments, alreadyRunning: alreadyRunning)
                for warning in built.warnings {
                    FileHandle.standardError.write(Data("isenough: \(warning)\n".utf8))
                }
                // `open` without a bound waits forever when the stub never checks in
                // with Launch Services. The watcher must not sit inside that wait:
                // the journal is already `active`, and a later manual `hook watch`
                // is what used to finish it. A still-running `open` is ignored by
                // the usage probe.
                let pid = try DetachedProcess.spawn(executable: built.argv[0], arguments: built.argv, redirectOutput: nil, newSession: true)
                if let status = DetachedProcess.wait(pid: pid, timeout: 30), status != 0 {
                    throw IsenoughError.failure("open exited \(status)")
                }
                #else
                _ = (app, docs, urls, arguments, alreadyRunning)
                throw IsenoughError.unsupported("opening an app requires macOS Launch Services")
                #endif
            },
            cdhash: { try BundleHasher.cdhash(of: $0) },
            treeHash: { try BundleHasher.treeHash(of: $0) },
            signatureValid: { BundleHasher.signatureValid($0) },
            archiveVerified: { journal in RestoreArchive.verified(journal, config: config) },
            buildStub: { dest, journal in try StubRebuilder.write(at: dest, journal: journal, config: config) },
            now: { Date() },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            runHook: { url, env in try ProcessRunner.runHook(url, env) },
            detachWatcher: true
        )
    }
}

struct ProcessRow: Equatable {
    var pid: Int32
    var ppid: Int32
    var command: String
}

enum ProcessProbe {
    /// A process is using the restored bundle when its command names the destination or staging path.
    /// The launching stub and the `isenough` CLI are not users: the stub's own executable lives inside
    /// the destination, and on macOS that path is spelled both `/var/...` and `/private/var/...`.
    static func usage(roots: [String]) -> UsageClass {
        let text = ProcessRunner.capture("/bin/ps", ["-ax", "-o", "pid=,ppid=,command="])
        return usage(rows: parse(text), roots: roots, selfPid: getpid())
    }

    static func usage(rows: [ProcessRow], roots: [String], selfPid: Int32) -> UsageClass {
        let skip = ancestorPIDs(selfPid: selfPid, rows: rows)
        let needles = pathNeedles(roots)
        for row in rows {
            if skip.contains(row.pid) || isOwnTool(row.command) { continue }
            if needles.contains(where: { row.command.contains($0) }) { return .busy }
        }
        return .clean
    }

    static func parse(_ text: String) -> [ProcessRow] {
        var rows: [ProcessRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            rows.append(ProcessRow(pid: pid, ppid: ppid, command: parts.count == 3 ? String(parts[2]) : ""))
        }
        return rows
    }

    /// `/var` and `/private/var` (also `/tmp` and `/etc`) name the same file on macOS.
    static func pathNeedles(_ roots: [String]) -> [String] {
        var needles: [String] = []
        func add(_ path: String) {
            guard path.count > 1, !needles.contains(path) else { return }
            needles.append(path)
        }
        for root in roots {
            add(root)
            let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            add(resolved)
            for path in [root, resolved] {
                if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/etc/") {
                    add(String(path.dropFirst("/private".count)))
                } else if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") || path.hasPrefix("/etc/") {
                    add("/private" + path)
                }
            }
        }
        return needles
    }

    static func isOwnTool(_ command: String) -> Bool {
        if command.contains("hook watch") { return true }
        let token = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let base = (token as NSString).lastPathComponent
        // `open` / `open -n -a <app>` keeps the destination in argv for as long as
        // Launch Services is waiting on the stub. That is the launcher, not a user
        // of the bundle. The restored executable and `tail -f <dest>/...` still count.
        return base == "isenough" || base == "isenough-stub" || base == "open"
    }

    static func ancestorPIDs(selfPid: Int32, rows: [ProcessRow]) -> Set<Int32> {
        let parent = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { _, latest in latest })
        var skip: Set<Int32> = [selfPid]
        var pid = selfPid
        var guardCount = 0
        while let next = parent[pid], next > 1, skip.insert(next).inserted, guardCount < 64 {
            pid = next
            guardCount += 1
        }
        return skip
    }
}

enum ProcessRunner {
    static func run(_ path: String, _ args: [String]) throws {
        let process = ParsedCommand.process(path: path, arguments: args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // Record the tool's sentence without classifying on it. hdiutil's wording
            // follows AppleLanguages, including when LC_ALL=C.
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw IsenoughError.diskImage("Command failed: \(path) \(args.joined(separator: " ")) (exit \(process.terminationStatus))\(detail.isEmpty ? "" : "\n\(detail)")")
        }
    }

    static func capture(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func runHook(_ url: URL, _ env: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = url
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func spawnWatch(appId: String, stateDir: String, executable: String? = nil) throws -> ProcessOwner {
        let exe = executable ?? EngineInstall.runningExecutable().path
        let args = [exe, "--state-dir", stateDir, "hook", "watch", "--app", appId]
        let logDirectory = URL(fileURLWithPath: stateDir).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let log = logDirectory.appendingPathComponent("hook-watch.log").path
        // Redirect the watcher so a closed stub pipe cannot deliver SIGPIPE, and
        // start it in a new session so it is not in the stub's process group.
        let pid: Int32
        do {
            pid = try DetachedProcess.spawn(executable: exe, arguments: args, redirectOutput: log, newSession: true)
        } catch {
            pid = try DetachedProcess.spawn(executable: exe, arguments: args, redirectOutput: nil, newSession: true)
        }
        return ProcessOwner(pid: pid, start: ProcessStart.ticks(for: pid))
    }
}

enum RestoreArchive {
    /// The repo object is included only when reading it will not start an iCloud download.
    static func candidates(config: RuntimeConfig, journal: RestoreJournal, isLocal: (URL) -> Bool) -> [URL] {
        var urls = [URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(journal.imageId).dmg")]
        let repo = URL(fileURLWithPath: config.repoPath).appendingPathComponent(journal.imageFile)
        if isLocal(repo) { urls.append(repo) }
        return urls
    }

    static func verified(_ journal: RestoreJournal, config: RuntimeConfig) -> Bool {
        let urls = candidates(config: config, journal: journal, isLocal: repoIsHashedLocally)
        for url in urls {
            if ArchiveVerificationCache.shared.verify(url: url, expected: journal.imageSha256, hasher: { try SHA256Digest.hexFile($0) }) {
                return true
            }
        }
        return false
    }

    private static func repoIsHashedLocally(_ url: URL) -> Bool {
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
        #else
        _ = url
        return true
        #endif
    }
}

enum StubRebuilder {
    /// The manifest the stub embeds. Prefers the copy the restore staged next to the
    /// journal, then the copy pack left in the cache. The repo is not read here.
    static func manifestData(journal: RestoreJournal, config: RuntimeConfig) -> Data? {
        let staged = URL(fileURLWithPath: journal.staging).appendingPathComponent("manifest.json")
        for data in [try? Data(contentsOf: staged), StubManifestCache.load(imageId: journal.imageId, cacheDir: config.cacheDir)] {
            if let data, let manifest = try? ImageManifest.decode(data), manifest.imageId == journal.imageId, manifest.bundleId == journal.appId {
                return data
            }
        }
        return nil
    }

    /// Build a working stub at `dest`, or throw and leave `dest` absent. The bundle
    /// is assembled beside `dest` and renamed into place only once it is signed.
    static func write(at dest: URL, journal: RestoreJournal, config: RuntimeConfig, environment: [String: String] = ProcessInfo.processInfo.environment, cli explicitCLI: URL? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            throw IsenoughError.busy("refusing to regenerate a stub over an existing destination \(dest.path)")
        }
        let cli = explicitCLI ?? EngineInstall.runningExecutable()
        let launcher: URL
        do {
            launcher = try StubGenerator.locateLauncher(cliExecutable: cli, environment: environment, isExecutable: { fm.isExecutableFile(atPath: $0) })
        } catch {
            throw IsenoughError.failure("cannot rebuild the stub at \(dest.path): \(error.localizedDescription)")
        }
        guard let manifest = manifestData(journal: journal, config: config) else {
            throw IsenoughError.failure("cannot rebuild the stub at \(dest.path): no local copy of manifest \(journal.imageId)")
        }
        let temp = dest.deletingLastPathComponent().appendingPathComponent(".isenough-stub-\(UUID().uuidString).app")
        var placed = false
        defer { if !placed { try? fm.removeItem(at: temp) } }
        try fm.createDirectory(at: temp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: temp.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": journal.stubBundleId,
            "CFBundleExecutable": "isenough-stub",
            "CFBundleName": journal.appName,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: temp.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(at: launcher, to: temp.appendingPathComponent("Contents/MacOS/isenough-stub"))
        try manifest.write(to: temp.appendingPathComponent("Contents/Resources/manifest.json"))
        let enginePath: String
        if cli.lastPathComponent == "isenough" {
            enginePath = (try? EngineInstall.install(stateDir: config.stateDir, source: cli).path) ?? cli.path
        } else if FileManager.default.isExecutableFile(atPath: EngineInstall.binary(stateDir: config.stateDir).path) {
            enginePath = EngineInstall.binary(stateDir: config.stateDir).path
        } else {
            enginePath = cli.path
        }
        let stubInfo: [String: Any] = [
            "schema": "stub/1",
            "appId": journal.appId,
            "imageId": journal.imageId,
            "isenoughPath": enginePath,
            "engineVersion": EngineInstall.version,
            "engineRevision": EngineInstall.revision,
            "stubVersion": 1,
        ]
        let stubData = try JSONSerialization.data(withJSONObject: stubInfo, options: [.prettyPrinted, .sortedKeys])
        try stubData.write(to: temp.appendingPathComponent("Contents/Resources/stub.json"))
        #if os(macOS)
        StubIcon.backfill(stub: temp, imageId: journal.imageId, stateDir: config.stateDir, originals: StubIcon.originals(mountRoot: config.mountRoot, imageId: journal.imageId, stub: temp, recordedPath: nil), publish: { _ in })
        let identity = SigningIdentity.resolve(configured: config.signIdentity, environment: environment)
        try ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", identity, temp.path])
        #endif
        if fm.fileExists(atPath: dest.path) {
            throw IsenoughError.busy("refusing to regenerate a stub over an existing destination \(dest.path)")
        }
        try fm.moveItem(at: temp, to: dest)
        placed = true
        #if os(macOS)
        StubIcon.touch(dest)
        StubIcon.register(dest)
        #endif
        try DurableIO.syncItem(dest.deletingLastPathComponent())
    }
}

public final class RestoreCoordinator {
    public let config: RuntimeConfig
    public var services: RestoreServices
    public let faults: FaultController
    public private(set) var events: [String] = []
    public var probeIntervalOverride: Double?
    public var detachDelayOverride: Double?
    private var cleanStreak = 0
    private var streakPhase: RestorePhase?
    private let fm = FileManager.default

    public init(config: RuntimeConfig, services: RestoreServices, faults: FaultController) {
        self.config = config
        self.services = services
        self.faults = faults
    }

    public func loadConfiguredFaults() {
        let url = URL(fileURLWithPath: config.stateDir).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.contains("faults") else { return }
        let points = object["faults"] as? [String] ?? []
        faults.points = Set(points)
        if points.isEmpty {
            faults.mode = .off
        } else {
            let mode = object["faultMode"] as? String ?? "kill"
            faults.mode = (mode == "throw" || mode == "raised") ? .raised : .kill
        }
    }

    private func launchAlreadyRunning(_ journal: RestoreJournal) -> Bool {
        journal.phase == .active && services.probe(probeRoots(journal)) == .busy
    }

    public func launch(_ manifest: ImageManifest, documents: [String], urls: [String], arguments: [String], wait: Bool) throws {
        guard let cdhash = manifest.app.cdhash, let tree = manifest.app.treeHash, !cdhash.isEmpty, !tree.isEmpty else {
            throw IsenoughError.integrity("restore manifest is missing app.cdhash or app.treeHash")
        }
        if let journal = openJournal(manifest.bundleId), foreignOwnerAlive(journal) {
            try services.openApp(URL(fileURLWithPath: journal.dest), documents, urls, arguments, launchAlreadyRunning(journal))
            return
        }
        let existing = try recover(appId: manifest.bundleId, wait: false, shortLived: false)
        switch existing {
        case .rejected(let message):
            throw IsenoughError.busy(message)
        case .waiting:
            guard let journal = openJournal(manifest.bundleId) else { break }
            try services.openApp(URL(fileURLWithPath: journal.dest), documents, urls, arguments, launchAlreadyRunning(journal))
            try markLaunched(manifest.bundleId)
            try handoffOrWait(manifest.bundleId, wait: wait)
            return
        case .noop:
            if let journal = openJournal(manifest.bundleId) {
                try services.openApp(URL(fileURLWithPath: journal.dest), documents, urls, arguments, launchAlreadyRunning(journal))
            }
            return
        case .idle, .terminal:
            break
        }
        if let message = resolutionMessage(manifest.bundleId) { throw IsenoughError.resolution(message) }
        let image = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg")
        try forward(manifest, image: image)
        if try runHooks("pre-launch", appId: manifest.bundleId) != 0 {
            try withJournal(manifest.bundleId) { journal in
                journal.pendingOutcome = "rolledBack"
                try JournalStore.save(journal, stateDir: config.stateDir)
            }
            _ = try recover(appId: manifest.bundleId, wait: true, shortLived: false)
            throw IsenoughError.hook("pre-launch hook failed")
        }
        guard let journal = openJournal(manifest.bundleId) else { throw IsenoughError.failure("restore journal disappeared before launch") }
        try services.openApp(URL(fileURLWithPath: journal.dest), documents, urls, arguments, launchAlreadyRunning(journal))
        try markLaunched(manifest.bundleId)
        try handoffOrWait(manifest.bundleId, wait: wait)
    }

    /// Production `detachWatcher` hands the post-quit loop to a setsid `hook watch`
    /// and, when `wait` is set, polls until that journal closes. The parent adopts
    /// only after the watcher is gone, so a dead watcher is replaced and a live one
    /// is left alone. Tests keep `detachWatcher` false and recover in-process.
    private func handoffOrWait(_ appId: String, wait: Bool) throws {
        if services.detachWatcher || !wait {
            try handoffApp(appId)
        }
        if !wait { return }
        if services.detachWatcher {
            try waitUntilTerminal(appId)
        } else {
            let finished = try recover(appId: appId, wait: true, shortLived: false)
            if case .rejected(let message) = finished { throw IsenoughError.busy(message) }
        }
    }

    /// No step cap. A restored app can stay open for hours; the cap inside
    /// `recover` still applies once this process itself owns the journal.
    private func waitUntilTerminal(_ appId: String) throws {
        while openJournal(appId) != nil {
            let outcome = try recover(appId: appId, wait: false, shortLived: true)
            switch outcome {
            case .idle, .terminal:
                return
            case .rejected(let message):
                throw IsenoughError.busy(message)
            case .noop, .waiting:
                services.sleep(max(probeInterval(), 0.05))
            }
        }
    }

    public func watch(appId: String) throws {
        _ = try recover(appId: appId, wait: true, shortLived: false)
    }

    public func recoverAll(shortLived: Bool) throws -> [String] {
        var ids = Set(try JournalStore.loadAll(stateDir: config.stateDir).map(\.appId))
        ids.formUnion(StateStore(config.stateDir).load().restored.keys)
        var notes: [String] = []
        for appId in ids.sorted() {
            let result = try recover(appId: appId, wait: false, shortLived: shortLived)
            notes.append("\(appId) \(result)")
        }
        return notes
    }

    public func diagnose() -> [String] {
        var issues: [String] = []
        if let journals = try? JournalStore.loadAll(stateDir: config.stateDir) {
            for journal in journals {
                let layout = observe(journal)
                let decision = RestoreRecovery.decide(phase: journal.phase, layout: layout, probe: .clean, ownerAlive: false, context: context(journal, streak: 2))
                if case .reject(let message) = decision.action { issues.append(message) }
            }
        }
        let state = StateStore(config.stateDir).load()
        for appId in state.restored.keys where openJournal(appId) == nil {
            issues.append("restored mirror for \(appId) has no journal. Run isenough gc to retire it when the destination is the stub, or restore the missing journal before deleting anything.")
        }
        for (appId, app) in state.apps where app.needsResolution != nil {
            let path = app.needsResolution?["retainedPath"]?.string ?? ""
            issues.append("\(appId) needs resolution before launch. Retained bundle: \(path). Use isenough resolve --discard, --export, or --keep-updated --trust.")
        }
        return issues
    }

    public func blockReason(appId: String) -> String? {
        if let message = resolutionMessage(appId) { return message }
        if openJournal(appId) != nil { return "a restore journal is still open for \(appId)" }
        return nil
    }

    public func resolutionMessage(_ appId: String) -> String? {
        guard needsResolution(appId) != nil else { return nil }
        return "\(appId) was updated while restored; choose Keep update / Discard with isenough resolve"
    }

    @discardableResult
    public func recover(appId: String, wait: Bool, shortLived: Bool) throws -> RecoverResult {
        cleanStreak = 0
        streakPhase = nil
        var steps = 0
        // Each clean-twice gate costs two probes, and a live app can stay busy
        // across many short sleeps before it exits. 400 covers a restore-out
        // plus a few seconds of busy polling at a zero probe interval.
        while steps < 400 {
            steps += 1
            let outcome = try withLock(appId) { () -> RecoverResult in
                if openJournal(appId) == nil {
                    return try retireStaleMirror(appId)
                }
                var journal = try reload(appId)
                try claim(&journal)
                let step = try oneStep(&journal)
                if case .waiting(let why) = step, shortLived, isLiveWait(why) {
                    try handoff(&journal)
                }
                return step
            }
            switch outcome {
            case .waiting(let why):
                if isLiveWait(why) {
                    if shortLived || !wait { return outcome }
                    services.sleep(probeInterval())
                } else {
                    services.sleep(probeInterval())
                }
            case .idle, .terminal, .rejected, .noop:
                return outcome
            }
        }
        throw IsenoughError.failure("restore recovery exceeded its step budget for \(appId)")
    }

    public func trash(_ url: URL) throws {
        let dest = URL(fileURLWithPath: config.stateDir).appendingPathComponent("trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try moveBundle(url, dest)
    }

    public func export(_ url: URL, to directory: URL) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try moveBundle(url, directory.appendingPathComponent(url.lastPathComponent))
    }

    public func clearResolution(appId: String) throws {
        try StateStore(config.stateDir).update { state in
            var app = state.apps[appId] ?? AppState()
            app.needsResolution = nil
            if app.state == "needsResolution" { app.state = "cached" }
            state.apps[appId] = app
        }
    }

    public func switchImage(appId: String, imageId: String, cdhash: String) throws {
        try StateStore(config.stateDir).update { state in
            var app = state.apps[appId] ?? AppState()
            app.imageId = imageId
            var trusted = app.extra["trusted"]?.object ?? [:]
            trusted["cdhash"] = .string(cdhash)
            trusted["approvedBy"] = .string("resolve")
            app.extra["trusted"] = .object(trusted)
            state.apps[appId] = app
        }
    }

    public func needsResolution(_ appId: String) -> [String: Any]? {
        guard let needs = StateStore(config.stateDir).load().apps[appId]?.needsResolution else { return nil }
        return needs.mapValues { $0.foundation() }
    }

    private func forward(_ manifest: ImageManifest, image: URL) throws {
        let dest = URL(fileURLWithPath: manifest.app.originalPath)
        let txid = "R-\(UUID().uuidString)"
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".256isenough-staging").appendingPathComponent(txid)
        var journal = RestoreJournal(
            txid: txid,
            appId: manifest.bundleId,
            imageId: manifest.imageId,
            owner: ProcessOwner.current(),
            dest: dest.path,
            staging: staging.path,
            imagePath: image.path,
            imageFile: manifest.image.file,
            appName: manifest.name,
            stubBundleId: "\(manifest.bundleId).256stub",
            executable: manifest.app.executable,
            manifestCdhash: manifest.app.cdhash ?? "",
            manifestTreeHash: manifest.app.treeHash ?? "",
            imageSha256: manifest.image.sha256
        )
        let probe = services.probe([dest.path])
        if probe != .clean { throw IsenoughError.busy("\(manifest.name) is already in use at \(dest.path)") }
        let manifestData = try? manifest.encode()
        if let manifestData { StubManifestCache.store(manifestData, imageId: manifest.imageId, cacheDir: config.cacheDir) }
        try withLock(manifest.bundleId) {
            if openJournal(manifest.bundleId) != nil { throw IsenoughError.busy("a restore journal is already open for \(manifest.bundleId)") }
            let info = BundleFacts.readInfo(dest)
            guard (info?["CFBundleIdentifier"] as? String) == journal.stubBundleId else {
                throw IsenoughError.unsupported("restore destination is not the isenough stub at \(dest.path)")
            }
            guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
                throw IsenoughError.unsupported("restore destination parent is not writable: \(dest.deletingLastPathComponent().path)")
            }
            try phasePrepared(&journal)
            // The journal's own copy, for a stub rebuild if the parked stub is lost.
            if let manifestData {
                try? manifestData.write(to: URL(fileURLWithPath: journal.staging).appendingPathComponent("manifest.json"))
            }
            try phaseExtracted(&journal, manifest: manifest)
            try phaseStubParked(&journal)
            try phaseInstalled(&journal)
            try phaseActive(&journal)
        }
    }

    private func phasePrepared(_ journal: inout RestoreJournal) throws {
        try faults.hit("prepared", "beforeJournal")
        journal.phase = .prepared
        try JournalStore.save(journal, stateDir: config.stateDir)
        try faults.hit("prepared", "afterJournal")
        try fm.createDirectory(at: URL(fileURLWithPath: journal.staging), withIntermediateDirectories: true)
        try Data(journal.txid.utf8).write(to: URL(fileURLWithPath: journal.staging).appendingPathComponent(".txn"))
        try DurableIO.syncItem(URL(fileURLWithPath: journal.staging))
        try faults.hit("prepared", "afterMutation")
        events.append("prepared")
    }

    private func phaseExtracted(_ journal: inout RestoreJournal, manifest: ImageManifest) throws {
        let mountPoint = URL(fileURLWithPath: config.mountRoot).appendingPathComponent("restore-\(journal.txid)")
        // Held from before attach until this phase ends, so the orphan reaper
        // never detaches the extraction mount even if the journal is unreadable.
        var lease = MountLease.acquire(stateDir: config.stateDir, name: "restore-\(journal.txid)", waitSeconds: 0.5)
        defer { lease?.release() }
        journal.mountPath = mountPoint.path
        try JournalStore.save(journal, stateDir: config.stateDir)
        let mounted = try services.attach(URL(fileURLWithPath: journal.imagePath), mountPoint)
        events.append("attach")
        let staging = URL(fileURLWithPath: journal.staging)
        let appNew = staging.appendingPathComponent("app.new")
        do {
            try faults.hit("extracted", "beforeJournal")
            journal.phase = .extracted
            journal.mountPath = mounted.path
            try JournalStore.save(journal, stateDir: config.stateDir)
            try faults.hit("extracted", "afterJournal")
            try Data(journal.txid.utf8).write(to: staging.appendingPathComponent(".extracting"))
            try services.extract(mounted, manifest.image.appPathInVolume, appNew)
            events.append("extract")
            BundleHasher.removeMetadataSidecars(appNew)
            let cdhash = try services.cdhash(appNew)
            let tree = try services.treeHash(appNew)
            guard cdhash == journal.manifestCdhash, tree == journal.manifestTreeHash else {
                throw IsenoughError.integrity("extracted bundle does not match manifest cdhash and tree hash (cdhash \(cdhash) vs \(journal.manifestCdhash), tree \(tree) vs \(journal.manifestTreeHash))")
            }
            if manifest.mode == .restore, let warning = try MASReceiptStore.reconcile(app: appNew, bundleId: manifest.bundleId, stateDir: URL(fileURLWithPath: config.stateDir)) {
                events.append("masReceipt")
                FileHandle.standardError.write(Data("isenough: \(warning)\n".utf8))
            }
            try Data("\(cdhash) \(tree)".utf8).write(to: staging.appendingPathComponent(".extracted-ok"))
            try services.detach(mounted)
            events.append("detach")
            journal.detachedImage = true
            journal.mountPath = nil
            try JournalStore.save(journal, stateDir: config.stateDir)
            try? fm.removeItem(at: mountPoint)
            try DurableIO.syncItem(staging)
            try faults.hit("extracted", "afterMutation")
            events.append("extracted")
        } catch {
            if !journal.detachedImage {
                do {
                    try services.detach(mounted)
                    journal.detachedImage = true
                    journal.mountPath = nil
                    try? JournalStore.save(journal, stateDir: config.stateDir)
                    events.append("detach")
                } catch {
                    events.append("detachFailed")
                }
            }
            if case IsenoughError.integrity = error {
                let layout = observe(journal)
                try? rollbackFiles(&journal, layout: layout)
                try? retire(&journal, forced: "rolledBack")
            }
            throw error
        }
    }

    private func phaseStubParked(_ journal: inout RestoreJournal) throws {
        try faults.hit("stubParked", "beforeJournal")
        journal.phase = .stubParked
        journal.stubId = DurableIO.inode(URL(fileURLWithPath: journal.dest))
        try JournalStore.save(journal, stateDir: config.stateDir)
        try faults.hit("stubParked", "afterJournal")
        let dest = URL(fileURLWithPath: journal.dest)
        let parked = URL(fileURLWithPath: journal.staging).appendingPathComponent("stub.app")
        if fm.fileExists(atPath: dest.path) && !fm.fileExists(atPath: parked.path) {
            try fm.moveItem(at: dest, to: parked)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
            try DurableIO.syncItem(URL(fileURLWithPath: journal.staging))
        }
        try faults.hit("stubParked", "afterMutation")
        events.append("stubParked")
    }

    private func phaseInstalled(_ journal: inout RestoreJournal) throws {
        let appNew = URL(fileURLWithPath: journal.staging).appendingPathComponent("app.new")
        try faults.hit("installed", "beforeJournal")
        journal.phase = .installed
        journal.destId = DurableIO.inode(appNew)
        try JournalStore.save(journal, stateDir: config.stateDir)
        try faults.hit("installed", "afterJournal")
        let dest = URL(fileURLWithPath: journal.dest)
        if fm.fileExists(atPath: appNew.path) && !fm.fileExists(atPath: dest.path) {
            try fm.moveItem(at: appNew, to: dest)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
        }
        if fm.fileExists(atPath: dest.path) {
            journal.installedFingerprint = try? TreeFingerprint.of(dest)
            try JournalStore.save(journal, stateDir: config.stateDir)
        }
        try faults.hit("installed", "afterMutation")
        events.append("installed")
    }

    private func phaseActive(_ journal: inout RestoreJournal) throws {
        try faults.hit("active", "beforeJournal")
        journal.phase = .active
        journal.kind = "restore-in"
        journal.owner = ProcessOwner.current()
        journal.epoch = max(journal.epoch, 1)
        journal.destId = DurableIO.inode(URL(fileURLWithPath: journal.dest)) ?? journal.destId
        journal.stubId = DurableIO.inode(URL(fileURLWithPath: journal.staging).appendingPathComponent("stub.app")) ?? journal.stubId
        try JournalStore.save(journal, stateDir: config.stateDir)
        try faults.hit("active", "afterJournal")
        try writeMirror(journal)
        try faults.hit("active", "afterMutation")
        events.append("active")
    }

    private func oneStep(_ journal: inout RestoreJournal) throws -> RecoverResult {
        detachLeftover(&journal)
        let layout = observe(journal)
        let probe = services.probe(probeRoots(journal))
        if streakPhase != journal.phase {
            streakPhase = journal.phase
            cleanStreak = 0
        }
        if probe == .clean { cleanStreak += 1 } else { cleanStreak = 0 }
        let decision = RestoreRecovery.decide(phase: journal.phase, layout: layout, probe: probe, ownerAlive: foreignOwnerAlive(journal), context: context(journal, streak: cleanStreak))
        switch decision.action {
        case .noopLiveOwner:
            return .noop
        case .reject(let message):
            return .rejected(message)
        case .waitForAnotherClean:
            return try noteWait(&journal, reason: probe == .clean ? "clean" : probe.rawValue)
        case .waitOnStaging:
            return try noteWait(&journal, reason: probe == .clean ? "clean" : probe.rawValue)
        case .adoptAndWatch:
            if journal.phase == .installed {
                try journalNext(.active, &journal) { item in
                    item.epoch = max(item.epoch, 1)
                    item.destId = DurableIO.inode(URL(fileURLWithPath: item.dest)) ?? item.destId
                    item.stubId = DurableIO.inode(URL(fileURLWithPath: item.staging).appendingPathComponent("stub.app")) ?? item.stubId
                }
                try faults.hit("active", "afterMutation")
            }
            return try noteWait(&journal, reason: probe.rawValue)
        case .backToActive:
            journal.phase = .active
            journal.kind = "restore-in"
            journal.waitReason = probe.rawValue
            try JournalStore.save(journal, stateDir: config.stateDir)
            try writeMirror(journal)
            return .waiting(probe.rawValue)
        case .finishRollback:
            try rollbackFiles(&journal, layout: layout)
            try retire(&journal, forced: "rolledBack")
            return .terminal(journal.outcome ?? "rolledBack")
        case .startRestoreOut:
            // Installed-phase clean recovery is a rollback, not a user quit: skip the
            // detach delay the same way an explicit pre-launch `rolledBack` does.
            // The pending outcome is recorded with the quiesced journal below.
            let rollingBack = journal.pendingOutcome == "rolledBack" || journal.phase == .installed
            if !rollingBack {
                if journal.detachAfter == nil {
                    journal.detachAfter = services.now().addingTimeInterval(detachDelay())
                    try JournalStore.save(journal, stateDir: config.stateDir)
                }
                if let deadline = journal.detachAfter, services.now() < deadline {
                    return try noteWait(&journal, reason: "delay")
                }
            }
            if journal.didLaunch && journal.postQuitRanForEpoch < journal.epoch {
                _ = try runHooks("post-quit", journal: journal)
                journal.postQuitRanForEpoch = journal.epoch
                try JournalStore.save(journal, stateDir: config.stateDir)
            }
            let outcome = journal.phase == .installed ? "rolledBack" : (journal.pendingOutcome ?? "restoredOut")
            try journalNext(.quiesced, &journal) { item in
                item.pendingOutcome = outcome
                item.waitReason = nil
            }
            try faults.hit("quiesced", "afterMutation")
            events.append("quiesced")
            return .waiting("clean")
        case .recordInspection:
            try inspect(&journal)
            return .waiting("clean")
        case .moveAppAside:
            try moveAside(&journal)
            return .waiting("clean")
        case .restoreStub:
            try restoreStub(&journal)
            return .waiting("clean")
        case .regenerateStub:
            do {
                try regenerate(&journal)
            } catch let fault as InjectedFault {
                throw fault
            } catch {
                // The app stays in staging/app.old. Say so instead of retrying forever.
                journal.waitReason = "needsAttention"
                try? JournalStore.save(journal, stateDir: config.stateDir)
                events.append("stubRegenerationFailed")
                let old = URL(fileURLWithPath: journal.staging).appendingPathComponent("app.old").path
                return .rejected("needs attention: could not rebuild the stub at \(journal.dest) (\(error.localizedDescription)). The app is safe at \(old).")
            }
            return .waiting("clean")
        case .deleteIdenticalCopy:
            try dispose(&journal, retain: false)
            return .waiting("clean")
        case .retainUpdatedCopy:
            try dispose(&journal, retain: true)
            return .waiting("clean")
        case .writeRetirement:
            try retire(&journal, forced: nil)
            return .waiting("clean")
        case .closeTransaction:
            try close(&journal)
            return .terminal(journal.outcome ?? "closed")
        case .retireMirrorWithoutJournal:
            return .idle
        }
    }

    private func noteWait(_ journal: inout RestoreJournal, reason: String) throws -> RecoverResult {
        journal.waitReason = reason
        try JournalStore.save(journal, stateDir: config.stateDir)
        try writeMirror(journal)
        return .waiting(reason)
    }

    private func inspect(_ journal: inout RestoreJournal) throws {
        let url = inspectURL(journal)
        let fingerprint = try? TreeFingerprint.of(url)
        let paranoid = ProcessInfo.processInfo.environment["ISENOUGH_PARANOID_INSPECT"] == "1"
        let snapshot: InspectionSnapshot
        if let fingerprint, fingerprint == journal.installedFingerprint, !paranoid {
            snapshot = InspectionSnapshot(cdhash: journal.manifestCdhash, treeHash: journal.manifestTreeHash, bundleId: journal.appId, changed: false, inode: DurableIO.inode(url), fingerprint: fingerprint)
        } else {
            guard let ident = BundleFacts.identity(url, cdhash: services.cdhash, treeHash: services.treeHash) else {
                throw IsenoughError.integrity("cannot inspect bundle at \(url.path)")
            }
            let changed = ident.cdhash != journal.manifestCdhash || ident.treeHash != journal.manifestTreeHash || ident.bundleId != journal.appId
            snapshot = InspectionSnapshot(cdhash: ident.cdhash, treeHash: ident.treeHash, bundleId: ident.bundleId, changed: changed, inode: ident.inode, fingerprint: fingerprint)
        }
        if journal.phase.index < RestorePhase.inspected.index {
            try journalNext(.inspected, &journal) { $0.inspection = snapshot }
        } else {
            journal.inspection = snapshot
            try JournalStore.save(journal, stateDir: config.stateDir)
        }
        try faults.hit("inspected", "afterMutation")
        events.append("inspected")
    }

    private func moveAside(_ journal: inout RestoreJournal) throws {
        if journal.phase != .appMoved {
            try journalNext(.appMoved, &journal) { _ in }
        }
        let dest = URL(fileURLWithPath: journal.dest)
        let old = URL(fileURLWithPath: journal.staging).appendingPathComponent("app.old")
        if fm.fileExists(atPath: dest.path) && !fm.fileExists(atPath: old.path) {
            try fm.moveItem(at: dest, to: old)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
            try DurableIO.syncItem(old.deletingLastPathComponent())
        }
        try faults.hit("appMoved", "afterMutation")
        events.append("appMoved")
    }

    private func restoreStub(_ journal: inout RestoreJournal) throws {
        if journal.phase != .stubBack {
            try journalNext(.stubBack, &journal) { _ in }
        }
        let dest = URL(fileURLWithPath: journal.dest)
        let parked = URL(fileURLWithPath: journal.staging).appendingPathComponent("stub.app")
        if !fm.fileExists(atPath: dest.path) && fm.fileExists(atPath: parked.path) {
            try fm.moveItem(at: parked, to: dest)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
        }
        try faults.hit("stubBack", "afterMutation")
        events.append("stubBack")
    }

    private func regenerate(_ journal: inout RestoreJournal) throws {
        if journal.phase != .stubBack {
            try journalNext(.stubBack, &journal) { _ in }
        }
        let dest = URL(fileURLWithPath: journal.dest)
        if !fm.fileExists(atPath: dest.path) {
            try services.buildStub(dest, journal)
        }
        try faults.hit("stubBack", "afterMutation")
        events.append("stubRegenerated")
    }

    private func dispose(_ journal: inout RestoreJournal, retain: Bool) throws {
        let old = URL(fileURLWithPath: journal.staging).appendingPathComponent("app.old")
        if journal.inspection == nil, fm.fileExists(atPath: old.path) {
            let saved = journal.phase
            journal.phase = .stubBack
            try inspect(&journal)
            if journal.phase != saved && saved.index > RestorePhase.inspected.index {
                journal.phase = saved
                try JournalStore.save(journal, stateDir: config.stateDir)
            }
        }
        var ctx = context(journal, streak: cleanStreak)
        ctx.archiveVerified = services.archiveVerified(journal)
        let identical = RestoreRecovery.provenIdentical(ctx)
        if journal.phase != .disposed {
            let inspection = journal.inspection
            try journalNext(.disposed, &journal) { item in item.inspection = inspection }
        }
        if fm.fileExists(atPath: old.path) {
            if identical && !retain {
                try fm.removeItem(at: old)
            } else {
                try retainBundle(old, journal: &journal)
            }
            try DurableIO.syncItem(URL(fileURLWithPath: journal.staging))
        }
        try faults.hit("disposed", "afterMutation")
        events.append(journal.resolution == nil ? "disposed" : "retained")
    }

    private func retainBundle(_ source: URL, journal: inout RestoreJournal) throws {
        guard let ident = BundleFacts.identity(source, cdhash: services.cdhash, treeHash: services.treeHash) else {
            throw IsenoughError.integrity("refusing to move an unreadable bundle out of staging")
        }
        let directory = URL(fileURLWithPath: config.stateDir).appendingPathComponent("retained/\(journal.appId)")
        let dest = directory.appendingPathComponent("\(journal.txid)-\(journal.appName).app")
        if fm.fileExists(atPath: dest.path) {
            journal.retainedPath = dest.path
        } else {
            do {
                try moveBundle(source, dest)
                journal.retainedPath = dest.path
            } catch {
                journal.retainedPath = source.path
            }
        }
        journal.resolution = ResolutionSnapshot(retainedPath: journal.retainedPath ?? source.path, treeHash: ident.treeHash, cdhash: ident.cdhash, bundleId: ident.bundleId, fromImageId: journal.imageId, txid: journal.txid, since: services.now())
        if journal.inspection != nil { journal.inspection?.changed = true }
        try JournalStore.save(journal, stateDir: config.stateDir)
    }

    private func retire(_ journal: inout RestoreJournal, forced: String?) throws {
        let outcome = forced ?? finalOutcome(journal)
        if journal.outcome == nil {
            journal.outcome = outcome
            journal.outcomeAt = services.now()
        }
        if journal.phase != .retired && journal.phase != .closed {
            let outcome = journal.outcome
            let outcomeAt = journal.outcomeAt
            let resolution = journal.resolution
            let retainedPath = journal.retainedPath
            try journalNext(.retired, &journal) { item in
                item.outcome = outcome
                item.outcomeAt = outcomeAt
                item.resolution = resolution
                item.retainedPath = retainedPath
            }
        }
        let stateWritten = journal.retiredStateWritten || outcomeTxid(journal.appId) == journal.txid
        if !stateWritten {
            let updateLRU = journal.outcome != "rolledBack"
            try StateStore(config.stateDir).applyRetirement(
                appId: journal.appId,
                imageId: journal.imageId,
                outcome: journal.outcome ?? outcome,
                at: journal.outcomeAt ?? services.now(),
                txid: journal.txid,
                needsResolution: journal.resolution.map(resolutionDictionary),
                updateLastUsed: updateLRU
            )
            journal.retiredStateWritten = true
            try JournalStore.save(journal, stateDir: config.stateDir)
        }
        try faults.hit("retired", "afterMutation")
        events.append("retired")
        try close(&journal)
    }

    private func close(_ journal: inout RestoreJournal) throws {
        if journal.phase != .closed {
            try journalNext(.closed, &journal) { _ in }
        }
        let staging = URL(fileURLWithPath: journal.staging)
        let retained = journal.retainedPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let stagingReal = staging.resolvingSymlinksInPath().path
        let keepStaging = retained?.hasPrefix(stagingReal) == true
        if !keepStaging && fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
            try DurableIO.syncItem(staging.deletingLastPathComponent())
        }
        try JournalStore.remove(stateDir: config.stateDir, txid: journal.txid)
        try faults.hit("closed", "afterMutation")
        events.append("closed")
    }

    private func rollbackFiles(_ journal: inout RestoreJournal, layout: RestoreLayout) throws {
        if case .app = layout.destination {
            throw IsenoughError.failure("refusing to roll back a real app at \(journal.dest)")
        }
        detachLeftover(&journal)
        let staging = URL(fileURLWithPath: journal.staging)
        let appNew = staging.appendingPathComponent("app.new")
        if layout.extractionOwned || layout.extractionVerified {
            if fm.fileExists(atPath: appNew.path) {
                // observe already compared this tree with the manifest when it set extractionVerified.
                if layout.extractionVerified && !services.archiveVerified(journal) {
                    try retainBundle(appNew, journal: &journal)
                } else {
                    try? fm.removeItem(at: appNew)
                }
            }
            try? fm.removeItem(at: staging.appendingPathComponent(".extracting"))
            try? fm.removeItem(at: staging.appendingPathComponent(".extracted-ok"))
        }
        let parked = staging.appendingPathComponent("stub.app")
        let dest = URL(fileURLWithPath: journal.dest)
        if fm.fileExists(atPath: parked.path) && !fm.fileExists(atPath: dest.path) {
            try fm.moveItem(at: parked, to: dest)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
        }
    }

    private func finalOutcome(_ journal: RestoreJournal) -> String {
        if journal.resolution != nil {
            return journal.pendingOutcome == "rolledBack" || journal.outcome == "rolledBack" ? "rolledBack" : "restoredOutRetained"
        }
        return journal.pendingOutcome ?? journal.outcome ?? "restoredOut"
    }

    private func journalNext(_ phase: RestorePhase, _ journal: inout RestoreJournal, _ fill: (inout RestoreJournal) -> Void) throws {
        try faults.hit(phase.rawValue, "beforeJournal")
        journal.phase = phase
        if phase.isRestoreOut { journal.kind = "restore-out" }
        fill(&journal)
        try JournalStore.save(journal, stateDir: config.stateDir)
        fputs("isenough: restore \(journal.appId) phase=\(phase.rawValue)\n", stderr)
        try faults.hit(phase.rawValue, "afterJournal")
    }

    private func claim(_ journal: inout RestoreJournal) throws {
        let me = ProcessOwner.current()
        if isSelf(journal.owner, me) { return }
        if services.isAlive(journal.owner) { return }
        journal.owner = me
        try JournalStore.save(journal, stateDir: config.stateDir)
        try writeMirror(journal)
        appendEvent(["event": "adopt", "mode": "restore", "appId": journal.appId, "pid": Int(me.pid), "txid": journal.txid])
        events.append("adopt")
    }

    private func handoff(_ journal: inout RestoreJournal) throws {
        let child = try services.spawnWatch(journal.appId)
        journal.owner = child
        try JournalStore.save(journal, stateDir: config.stateDir)
        try writeMirror(journal)
        events.append("handoff")
    }

    private func handoffApp(_ appId: String) throws {
        try withLock(appId) {
            guard var journal = openJournal(appId) else { return }
            try handoff(&journal)
        }
    }

    private func markLaunched(_ appId: String) throws {
        try withLock(appId) {
            guard var journal = openJournal(appId) else { return }
            journal.didLaunch = true
            try JournalStore.save(journal, stateDir: config.stateDir)
        }
    }

    private func writeMirror(_ journal: RestoreJournal) throws {
        try StateStore(config.stateDir).update { state in
            state.restored[journal.appId] = RestoredMirror(
                journal: "journals/\(journal.txid).json",
                txid: journal.txid,
                phase: journal.waitReason == nil ? "running" : "waiting",
                waitReason: journal.waitReason ?? "",
                dest: journal.dest,
                staging: journal.staging,
                epoch: journal.epoch,
                postQuitRanForEpoch: journal.postQuitRanForEpoch,
                owner: journal.owner
            )
        }
    }

    private func retireStaleMirror(_ appId: String) throws -> RecoverResult {
        let state = StateStore(config.stateDir).load()
        guard let mirror = state.restored[appId] else { return .idle }
        let dest = mirror.dest
        let staging = mirror.staging
        let stubId = "\(appId).256stub"
        let destURL = URL(fileURLWithPath: dest)
        let stagingExists = !staging.isEmpty && fm.fileExists(atPath: staging)
        let info = BundleFacts.readInfo(destURL)
        let isStub = (info?["CFBundleIdentifier"] as? String) == stubId
        if isStub && !stagingExists {
            _ = try StateStore(config.stateDir).update { state in
                state.restored.removeValue(forKey: appId)
            }
            return .terminal("mirrorRetired")
        }
        return .rejected("stale restored mirror for \(appId) has no journal and the destination is not the stub. Nothing was deleted. Repair: restore the stub at \(dest) or put the journal back, then run isenough gc.")
    }

    private func observe(_ journal: RestoreJournal) -> RestoreLayout {
        let staging = URL(fileURLWithPath: journal.staging)
        let marker = staging.appendingPathComponent(".txn")
        let markerOK = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == journal.txid
        let appNew = staging.appendingPathComponent("app.new")
        let appOld = staging.appendingPathComponent("app.old")
        let parked = staging.appendingPathComponent("stub.app")
        var unexpected: [String] = []
        if fm.fileExists(atPath: staging.path), let names = try? fm.contentsOfDirectory(atPath: staging.path) {
            let known: Set<String> = [".txn", ".extracting", ".extracted-ok", "app.new", "app.old", "stub.app", "manifest.json"]
            unexpected = names.filter { !known.contains($0) }.sorted()
        }
        let hasRole = exists(appNew) || exists(appOld) || exists(parked)
        let stagingState: StagingState
        if !exists(staging) {
            stagingState = .absent
        } else if !markerOK {
            stagingState = .foreign
        } else if hasRole {
            stagingState = .owned
        } else {
            stagingState = .ownedEmpty
        }
        let extracting = exists(staging.appendingPathComponent(".extracting"))
        let okFile = exists(staging.appendingPathComponent(".extracted-ok"))
        let inner = exists(appNew.appendingPathComponent(".isenough-extract"))
        let retainedURL = journal.retainedPath.map { URL(fileURLWithPath: $0) }
        // A full tree hash is required only where the decision compares one:
        // `manifestApp` / the extraction marker read `app.new`, and `inspectionStale`
        // re-reads the destination after `inspected`. The active probe loop (and the
        // parked stub, `app.old`, and retained path) classifies by bundle id. Post-quit
        // `inspect` is what records whether the restored tree changed. Hashing the live
        // app on every probe repeated the same multi-gigabyte walk and did not feed
        // the decision.
        var memo = IdentityMemo()
        let destination = destinationNode(journal, memo: &memo)
        return RestoreLayout(
            destination: destination,
            appNew: node(appNew, journal, full: true, memo: &memo),
            appOld: node(appOld, journal, full: false, memo: &memo),
            parkedStub: node(parked, journal, full: false, memo: &memo),
            retained: retainedURL.map { node($0, journal, full: false, memo: &memo) } ?? .absent,
            staging: stagingState,
            extractionOwned: extracting || okFile || inner,
            extractionVerified: okFile && manifestMatch(appNew, journal, memo: &memo),
            pathsEscape: escapes(journal),
            unexpected: unexpected
        )
    }

    private struct IdentityMemo {
        private var hits: [String: BundleIdentity] = [:]
        private var misses = Set<String>()

        mutating func identity(_ url: URL, full: Bool, services: RestoreServices) -> BundleIdentity? {
            let key = (full ? "f\t" : "b\t") + url.path
            if misses.contains(key) { return nil }
            if let hit = hits[key] { return hit }
            let value = BundleFacts.identity(url, cdhash: services.cdhash, treeHash: services.treeHash, verifyContent: full)
            if let value {
                hits[key] = value
            } else {
                misses.insert(key)
            }
            return value
        }
    }

    private func destinationNode(_ journal: RestoreJournal, memo: inout IdentityMemo) -> BundleNode {
        let url = URL(fileURLWithPath: journal.dest)
        let paranoid = ProcessInfo.processInfo.environment["ISENOUGH_PARANOID_INSPECT"] == "1"
        if journal.phase == .inspected, let snap = journal.inspection, !paranoid,
           let current = try? TreeFingerprint.of(url), current == snap.fingerprint {
            return .app(bundleId: snap.bundleId, cdhash: snap.cdhash, treeHash: snap.treeHash, inode: snap.inode)
        }
        return node(url, journal, full: journal.phase == .inspected, memo: &memo)
    }

    private func node(_ url: URL, _ journal: RestoreJournal, full: Bool, memo: inout IdentityMemo) -> BundleNode {
        if DurableIO.isSymlink(url) { return .symlink }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return .absent }
        guard isDir.boolValue else { return .foreign("not a bundle directory") }
        guard let ident = memo.identity(url, full: full, services: services) else { return .incomplete }
        if ident.isStub {
            return ident.bundleId == journal.stubBundleId ? .stub(bundleId: ident.bundleId, inode: ident.inode) : .foreign(ident.bundleId)
        }
        if ident.bundleId == journal.appId {
            return .app(bundleId: ident.bundleId, cdhash: ident.cdhash, treeHash: ident.treeHash, inode: ident.inode)
        }
        return .foreign(ident.bundleId)
    }

    private func escapes(_ journal: RestoreJournal) -> Bool {
        let parent = URL(fileURLWithPath: journal.dest).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let paths = [journal.dest, journal.staging, journal.retainedPath].compactMap { $0 }
        for path in paths {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            if real != parent && !real.hasPrefix(parent + "/") && !real.hasPrefix(URL(fileURLWithPath: config.stateDir).resolvingSymlinksInPath().path) {
                return true
            }
        }
        return false
    }

    private func context(_ journal: RestoreJournal, streak: Int) -> RestoreContext {
        return RestoreContext(
            manifestBundleId: journal.appId,
            stubBundleId: journal.stubBundleId,
            manifestCdhash: journal.manifestCdhash,
            manifestTreeHash: journal.manifestTreeHash,
            recordedDestId: journal.destId,
            recordedStubId: journal.stubId,
            inspection: journal.inspection,
            archiveVerified: services.archiveVerified(journal),
            retiredStateWritten: journal.retiredStateWritten || outcomeTxid(journal.appId) == journal.txid,
            cleanStreak: streak,
            stubRegenerable: true,
            pendingOutcome: journal.pendingOutcome
        )
    }

    private func manifestMatch(_ url: URL, _ journal: RestoreJournal, memo: inout IdentityMemo) -> Bool {
        guard let ident = memo.identity(url, full: true, services: services) else { return false }
        return ident.bundleId == journal.appId && ident.cdhash == journal.manifestCdhash && ident.treeHash == journal.manifestTreeHash
    }

    private func inspectURL(_ journal: RestoreJournal) -> URL {
        let old = URL(fileURLWithPath: journal.staging).appendingPathComponent("app.old")
        if journal.phase.index >= RestorePhase.appMoved.index && !exists(URL(fileURLWithPath: journal.dest)) && exists(old) {
            return old
        }
        if exists(old) && !exists(URL(fileURLWithPath: journal.dest)) { return old }
        return URL(fileURLWithPath: journal.dest)
    }

    private func probeRoots(_ journal: RestoreJournal) -> [String] {
        var roots = [journal.dest, journal.staging]
        if journal.phase.index >= RestorePhase.appMoved.index {
            roots.append(URL(fileURLWithPath: journal.staging).appendingPathComponent("app.old").path)
        }
        return roots
    }

    private func detachLeftover(_ journal: inout RestoreJournal) {
        guard !journal.detachedImage, let mount = journal.mountPath else { return }
        do {
            try services.detach(URL(fileURLWithPath: mount))
            journal.detachedImage = true
            journal.mountPath = nil
            try? JournalStore.save(journal, stateDir: config.stateDir)
            events.append("detach")
        } catch {
            events.append("detachFailed")
        }
    }

    private func moveBundle(_ from: URL, _ to: URL) throws {
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: to.path) { throw IsenoughError.failure("refusing to overwrite \(to.path)") }
        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            try fm.copyItem(at: from, to: to)
            let source = try services.treeHash(from)
            let copy = try services.treeHash(to)
            guard source == copy else {
                try? fm.removeItem(at: to)
                throw IsenoughError.integrity("cross-volume copy of \(from.path) failed tree-hash verification")
            }
            try fm.removeItem(at: from)
        }
    }

    private func resolutionDictionary(_ snapshot: ResolutionSnapshot) -> [String: Any] {
        [
            "retainedPath": snapshot.retainedPath,
            "treeHash": snapshot.treeHash,
            "cdhash": snapshot.cdhash,
            "bundleId": snapshot.bundleId,
            "fromImageId": snapshot.fromImageId,
            "txid": snapshot.txid,
            "since": ISO8601DateFormatter().string(from: snapshot.since),
        ]
    }

    private func outcomeTxid(_ appId: String) -> String? {
        StateStore(config.stateDir).load().apps[appId]?.lastOutcome?.txid
    }

    private func runHooks(_ phase: String, appId: String) throws -> Int32 {
        guard let journal = openJournal(appId) else { return 0 }
        return try runHooks(phase, journal: journal)
    }

    private func runHooks(_ phase: String, journal: RestoreJournal) throws -> Int32 {
        let root = URL(fileURLWithPath: config.stateDir).appendingPathComponent("hooks/\(journal.appId)")
        var files: [URL] = []
        let direct = root.appendingPathComponent(phase)
        if isRunnable(direct) { files.append(direct) }
        let directory = root.appendingPathComponent(phase + ".d")
        for name in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() {
            let url = directory.appendingPathComponent(name)
            if isRunnable(url) { files.append(url) }
        }
        guard !files.isEmpty else { return 0 }
        var env = ProcessInfo.processInfo.environment
        env["ISENOUGH_PHASE"] = phase
        env["ISENOUGH_APP_ID"] = journal.appId
        env["ISENOUGH_BUNDLE_ID"] = journal.appId
        env["ISENOUGH_IMAGE_ID"] = journal.imageId
        env["ISENOUGH_MODE"] = "restore"
        env["ISENOUGH_APP_PATH"] = journal.dest
        env["ISENOUGH_SESSION_ID"] = journal.txid
        env["ISENOUGH_STATE_DIR"] = config.stateDir
        env["ISENOUGH_EXIT_STATUS"] = "unknown"
        for file in files {
            let code = try services.runHook(file, env)
            if code != 0 { return code }
        }
        return 0
    }

    private func isRunnable(_ url: URL) -> Bool {
        guard fm.isExecutableFile(atPath: url.path) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    func withLock<T>(_ appId: String, _ body: () throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/app")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var lock = FileLock(path: directory.appendingPathComponent(appId + ".lock").path)
        try lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func withJournal(_ appId: String, _ body: (inout RestoreJournal) throws -> Void) throws {
        try withLock(appId) {
            guard var journal = openJournal(appId) else { return }
            try body(&journal)
        }
    }

    private func reload(_ appId: String) throws -> RestoreJournal {
        guard let journal = openJournal(appId) else { throw IsenoughError.failure("restore journal for \(appId) disappeared") }
        return journal
    }

    private func openJournal(_ appId: String) -> RestoreJournal? {
        (try? JournalStore.loadAll(stateDir: config.stateDir))?.filter { $0.appId == appId }.sorted { $0.createdAt < $1.createdAt }.last
    }

    private func foreignOwnerAlive(_ journal: RestoreJournal) -> Bool {
        let me = ProcessOwner.current()
        if isSelf(journal.owner, me) { return false }
        return services.isAlive(journal.owner)
    }

    private func isSelf(_ owner: ProcessOwner, _ me: ProcessOwner) -> Bool {
        owner.pid == me.pid && (owner.start == me.start || owner.start == 0 || me.start == 0)
    }

    private func isLiveWait(_ reason: String) -> Bool {
        reason == "busy" || reason == "unknown" || reason == "held" || reason == "delay"
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    private func probeInterval() -> Double {
        if let probeIntervalOverride { return probeIntervalOverride }
        if let raw = ProcessInfo.processInfo.environment["ISENOUGH_PROBE_INTERVAL"], let value = Double(raw) { return value }
        return 5
    }

    private func detachDelay() -> Double {
        if let detachDelayOverride { return detachDelayOverride }
        if let raw = ProcessInfo.processInfo.environment["ISENOUGH_DETACH_DELAY"], let value = Double(raw) { return value }
        return Double(config.detachDelaySeconds)
    }

    private func appendEvent(_ object: [String: Any]) {
        let url = URL(fileURLWithPath: config.stateDir).appendingPathComponent("events.jsonl")
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        var line = data
        line.append(0x0a)
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
