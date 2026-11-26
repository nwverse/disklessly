import Foundation
import DisklesslyCore

/// What the container scan and actions touch: the CLIs, and the disk. Tests replace all of it.
public struct ContainerTools {
    public var home: String
    /// Runs a tool and returns its stdout; throws on a non-zero exit or when `timeout` passes.
    public var run: (_ path: String, _ arguments: [String], _ timeout: TimeInterval) throws -> Data
    public var isExecutable: (String) -> Bool
    public var exists: (String) -> Bool
    /// Allocated bytes of a file or folder tree.
    public var allocated: (String) -> UInt64
    public var read: (String) -> Data?
    public var modified: (String) -> Date?

    public init(home: String, run: @escaping (String, [String], TimeInterval) throws -> Data, isExecutable: @escaping (String) -> Bool,
                exists: @escaping (String) -> Bool, allocated: @escaping (String) -> UInt64, read: @escaping (String) -> Data?,
                modified: @escaping (String) -> Date?) {
        self.home = home
        self.run = run
        self.isExecutable = isExecutable
        self.exists = exists
        self.allocated = allocated
        self.read = read
        self.modified = modified
    }

    public static func live(home: String = NSHomeDirectory()) -> ContainerTools {
        ContainerTools(
            home: home,
            run: { path, arguments, timeout in try ContainerCLI.run(path, arguments, timeout: timeout) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            exists: { FileManager.default.fileExists(atPath: $0) },
            allocated: { AllocatedSize.tree(URL(fileURLWithPath: $0)) },
            read: { FileManager.default.contents(atPath: $0) },
            modified: { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date })
    }
}

/// Runs a container CLI with a deadline, so a stuck engine cannot hang the scan.
enum ContainerCLI {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw DisklesslyError.unsupported("\(path) is not available") }
        let process = ParsedCommand.process(path: path, arguments: arguments)
        var environment = process.environment ?? ProcessInfo.processInfo.environment
        // A GUI launch has no Homebrew in PATH; docker looks up credential helpers there.
        environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["DOCKER_CLI_HINTS"] = "false"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw DisklesslyError.failure("Could not start \(path): \(error.localizedDescription)")
        }
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.setOut(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.setErr(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); exited.signal() }
        let command = ([URL(fileURLWithPath: path).lastPathComponent] + arguments).joined(separator: " ")
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw DisklesslyError.failure("\(command) did not finish in \(Int(timeout)) s")
        }
        group.wait()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: box.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DisklesslyError.failure("\(command) failed (exit \(process.terminationStatus))\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return box.out
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var o = Data(), e = Data()
        func setOut(_ d: Data) { lock.lock(); o = d; lock.unlock() }
        func setErr(_ d: Data) { lock.lock(); e = d; lock.unlock() }
        var out: Data { lock.lock(); defer { lock.unlock() }; return o }
        var err: Data { lock.lock(); defer { lock.unlock() }; return e }
    }
}

/// One engine as the scan found it.
public struct ContainerEngineState: Equatable {
    public enum Status: String { case running, stopped, noCli }

    public var kind: ContainerEngineKind
    public var status: Status
    /// The CLI used for it (`container` or `docker`), when one was found.
    public var cli: String?
    /// Docker API socket for the Docker-compatible engines.
    public var socket: String?
    /// Folders or VM disk files where the engine keeps everything.
    public var dataPaths: [String]
    public var dataBytes: UInt64
    /// Why the image list is missing (engine stopped, CLI failed).
    public var note: String?

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["engine": kind.rawValue, "title": kind.title, "status": status.rawValue,
                                     "dataPaths": dataPaths, "dataBytes": NSNumber(value: dataBytes), "vmDisk": kind.usesVMDisk]
        if let cli { object["cli"] = cli }
        if let socket { object["socket"] = socket }
        if let note { object["note"] = note }
        return object
    }
}

public struct ContainerReport {
    public var engines: [ContainerEngineState]
    public var images: [ContainerImage]
    public var volumes: [ContainerVolume]
    public var offloaded: [ContainerImageRecord]
    /// Set when the repo could not be listed.
    public var repoError: String?

    public var reclaimableBytes: UInt64 { images.filter { !$0.use.blocksRemoval }.reduce(0) { $0 + $1.bytes } }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "engines": engines.map { $0.jsonObject() },
            "images": images.map { $0.jsonObject() },
            "volumes": volumes.map { $0.jsonObject() },
            "offloaded": offloaded.map { $0.jsonObject(present: $0.present(in: images)) },
            "bytes": NSNumber(value: images.reduce(0) { $0 + $1.bytes }),
            "reclaimableBytes": NSNumber(value: reclaimableBytes),
            "recentDays": ContainerImages.recentDays,
        ]
        if let repoError { object["repoError"] = repoError }
        return object
    }
}

public struct ContainerActionResult {
    public var title: String
    public var record: ContainerImageRecord?
    /// Space the Mac got back, measured on the engine's data folders or VM disk.
    public var freedBytes: UInt64
    public var uploaded: Bool
    public var warning: String?

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["ok": true, "title": title, "freedBytes": NSNumber(value: freedBytes), "uploaded": uploaded]
        if let record { object["record"] = record.jsonObject(present: false) }
        if let warning { object["warning"] = warning }
        return object
    }
}

/// Where each engine lives on disk. Docker-compatible engines are reached through their own
/// socket, so no docker context has to be switched.
struct ContainerEndpoint {
    var kind: ContainerEngineKind
    var socket: String?
    var dataPaths: [String]
    var markers: [String]

    static func all(home: String) -> [ContainerEndpoint] {
        [
            ContainerEndpoint(kind: .apple, socket: nil,
                              dataPaths: [home + "/Library/Application Support/com.apple.container"], markers: []),
            ContainerEndpoint(kind: .docker, socket: "/var/run/docker.sock",
                              dataPaths: ["/var/lib/docker"],
                              markers: ["/var/run/docker.sock"]),
            ContainerEndpoint(kind: .dockerDesktop, socket: home + "/.docker/run/docker.sock",
                              dataPaths: [home + "/Library/Containers/com.docker.docker/Data/vms"],
                              markers: ["/Applications/Docker.app"]),
            ContainerEndpoint(kind: .orbstack, socket: home + "/.orbstack/run/docker.sock",
                              dataPaths: [home + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"],
                              markers: ["/Applications/OrbStack.app"]),
            ContainerEndpoint(kind: .colima, socket: home + "/.colima/default/docker.sock",
                              dataPaths: [home + "/.colima/_lima"], markers: [home + "/.colima"]),
            ContainerEndpoint(kind: .dory, socket: home + "/.dory/dory.sock",
                              dataPaths: [home + "/.dory"], markers: ["/Applications/Dory.app"]),
        ]
    }

    static func appleCLI(_ tools: ContainerTools) -> String? {
        ["/opt/homebrew/bin/container", "/usr/local/bin/container"].first(where: tools.isExecutable)
    }

    /// Any docker CLI talks to any of these sockets with `-H`.
    static func dockerCLI(_ tools: ContainerTools) -> String? {
        ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker", "/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker",
         tools.home + "/.orbstack/bin/docker", "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
         tools.home + "/.dory/bin/docker", "/Applications/Dory.app/Contents/Resources/bin/docker"].first(where: tools.isExecutable)
    }
}

extension DisklesslyEngine {
    var containerTools: ContainerTools { containerToolsOverride ?? .live(home: homeDirectory) }
    var containersDir: URL { URL(fileURLWithPath: config.cacheDir).appendingPathComponent("containers") }

    static let containerListTimeout: TimeInterval = 30
    /// Saving or loading a big image can take a while; a stuck engine still ends.
    static let containerTransferTimeout: TimeInterval = 4 * 3600

    // MARK: reading

    /// Images, containers and volumes of every engine on this Mac. Reads only.
    public func containerReport(now: Date = Date()) -> ContainerReport {
        let tools = containerTools
        var report = ContainerReport(engines: [], images: [], volumes: [], offloaded: [])
        for endpoint in ContainerEndpoint.all(home: tools.home) {
            guard case let (state, images, volumes)? = scanEngine(endpoint, tools: tools, now: now) else { continue }
            report.engines.append(state)
            report.images += images
            report.volumes += volumes
        }
        report.images.sort { ($0.use.blocksRemoval ? 1 : 0, $1.bytes) < ($1.use.blocksRemoval ? 1 : 0, $0.bytes) }
        do { report.offloaded = try offloadedContainerImages() } catch { report.repoError = error.localizedDescription }
        return report
    }

    /// Nil when the engine is not on this Mac at all.
    func scanEngine(_ endpoint: ContainerEndpoint, tools: ContainerTools, now: Date) -> (ContainerEngineState, [ContainerImage], [ContainerVolume])? {
        let dataPaths = endpoint.dataPaths.filter(tools.exists)
        let socketHere = endpoint.socket.map(tools.exists) ?? false
        let cli = endpoint.kind == .apple ? ContainerEndpoint.appleCLI(tools) : ContainerEndpoint.dockerCLI(tools)
        let installed = !dataPaths.isEmpty || socketHere || endpoint.markers.contains(where: tools.exists) || (endpoint.kind == .apple && cli != nil)
        guard installed else { return nil }
        var state = ContainerEngineState(kind: endpoint.kind, status: .stopped, cli: cli, socket: endpoint.socket, dataPaths: dataPaths,
                                         dataBytes: dataPaths.reduce(0) { $0 + tools.allocated($1) })
        guard let cli else {
            state.status = .noCli
            state.note = endpoint.kind == .apple ? "container CLI not found" : "docker CLI not found"
            return (state, [], [])
        }
        do {
            let (images, volumes) = endpoint.kind == .apple
                ? try scanApple(cli: cli, tools: tools, dataDir: endpoint.dataPaths[0], now: now)
                : try scanDocker(cli: cli, socket: endpoint.socket ?? "", kind: endpoint.kind, tools: tools, now: now, socketHere: socketHere)
            state.status = .running
            return (state, images, volumes)
        } catch {
            state.note = error.localizedDescription
            return (state, [], [])
        }
    }

    private func scanApple(cli: String, tools: ContainerTools, dataDir: String, now: Date) throws -> ([ContainerImage], [ContainerVolume]) {
        // `system status` fails when the services are not started; nothing here starts them.
        _ = try tools.run(cli, ["system", "status"], 10)
        let listed = try ContainerParse.appleImages(try tools.run(cli, ["image", "list", "--format", "json"], Self.containerListTimeout))
        let containers = (try? ContainerParse.appleContainers(try tools.run(cli, ["list", "--all", "--format", "json"], Self.containerListTimeout))) ?? []
        let hex: (String) -> String = { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : $0 }
        let blobs = dataDir + "/content/blobs/sha256/"
        var images: [ContainerImage] = []
        for entry in listed {
            var image = entry.image
            let snapshots = entry.manifestDigests.map { dataDir + "/snapshots/" + hex($0) }.filter(tools.exists)
            let owned = ContainerParse.appleBlobDigests(index: image.id) { tools.read(blobs + $0) }
            image.bytes = snapshots.reduce(0) { $0 + tools.allocated($1) } + owned.reduce(0) { $0 + tools.allocated(blobs + $1) }
            // The snapshot is unpacked at pull time; its date is when the image came here.
            image.pulled = (snapshots + [blobs + hex(image.id)]).compactMap(tools.modified).max()
            images.append(image)
        }
        let volumes = ContainerParse.appleVolumes((try? tools.run(cli, ["volume", "list", "--format", "json"], Self.containerListTimeout)) ?? Data())
            .map { ContainerVolume(engine: .apple, name: $0, bytes: tools.allocated(dataDir + "/volumes/" + $0), links: nil) }
        return (ContainerParse.classify(images, containers: containers, now: now), volumes)
    }

    private func scanDocker(cli: String, socket: String, kind: ContainerEngineKind, tools: ContainerTools, now: Date, socketHere: Bool) throws -> ([ContainerImage], [ContainerVolume]) {
        guard socketHere else { throw DisklesslyError.unsupported("\(kind.title) is not running") }
        let host = ["-H", "unix://" + socket]
        _ = try tools.run(cli, host + ["version", "--format", "{{.Server.Version}}"], 10)
        let imageIds = ContainerParse.ids(try tools.run(cli, host + ["image", "ls", "-q", "--no-trunc"], Self.containerListTimeout))
        let images = imageIds.isEmpty ? [] : try ContainerParse.dockerImages(try tools.run(cli, host + ["image", "inspect"] + imageIds, Self.containerListTimeout), engine: kind)
        let containerIds = ContainerParse.ids(try tools.run(cli, host + ["ps", "-aq", "--no-trunc"], Self.containerListTimeout))
        let containers = containerIds.isEmpty ? [] : try ContainerParse.dockerContainers(try tools.run(cli, host + ["container", "inspect"] + containerIds, Self.containerListTimeout))
        // Volume sizes need a full `system df`, which can be slow; leave them out if it is.
        let volumes = ContainerParse.dockerVolumes((try? tools.run(cli, host + ["system", "df", "-v", "--format", "{{json .}}"], 60)) ?? Data(), engine: kind)
        return (ContainerParse.classify(images, containers: containers, now: now), volumes)
    }

    // MARK: repo

    public func offloadedContainerImages() throws -> [ContainerImageRecord] {
        let backend = try repo
        guard (try? backend.stat(ContainerImages.folder)) != nil else { return [] }
        var records: [ContainerImageRecord] = []
        for name in (try? backend.list(ContainerImages.folder)) ?? [] where name.hasSuffix(".json") {
            if let data = try? backend.get("\(ContainerImages.folder)/\(name)", range: nil), let record = try? ContainerImageRecord.decode(data) {
                records.append(record)
            }
        }
        return records.sorted { $0.offloadedAt > $1.offloadedAt }
    }

    func containerRecord(_ id: String) throws -> ContainerImageRecord {
        let matches = try offloadedContainerImages().filter { $0.id == id || $0.id.hasPrefix(id) }
        guard matches.count == 1 else {
            throw DisklesslyError.usage(matches.isEmpty ? "No saved container image \(id)" : "\(id) matches more than one saved image")
        }
        return matches[0]
    }

    /// Removes a saved image and its record from the repo.
    public func forgetContainerImage(_ id: String) throws -> ContainerImageRecord {
        let record = try containerRecord(id)
        let backend = try repo
        try backend.delete(record.tar)
        try backend.delete(ContainerImages.recordPath(id: record.id))
        return record
    }

    // MARK: actions

    /// Finds the image by `<engine>/<id>` in a fresh scan of its engine, and refuses one a container uses.
    private func liveImage(_ key: String, tools: ContainerTools) throws -> (ContainerEngineState, ContainerImage) {
        guard let slash = key.firstIndex(of: "/"), let kind = ContainerEngineKind(rawValue: String(key[..<slash])) else {
            throw DisklesslyError.usage("Container image keys look like <engine>/<id>, e.g. apple/sha256:…")
        }
        let id = String(key[key.index(after: slash)...])
        guard let endpoint = ContainerEndpoint.all(home: tools.home).first(where: { $0.kind == kind }),
              case let (state, images, _)? = scanEngine(endpoint, tools: tools, now: Date()) else {
            throw DisklesslyError.unsupported("\(kind.title) is not on this Mac")
        }
        guard state.status == .running else { throw DisklesslyError.unsupported("\(kind.title) is not running\(state.note.map { ": \($0)" } ?? "")") }
        guard let image = images.first(where: { ContainerParse.sameId($0.id, id) }) else {
            throw DisklesslyError.usage("No image \(id) in \(kind.title)")
        }
        if image.use.blocksRemoval {
            throw DisklesslyError.busy("\(image.title) is used by \(image.containers.joined(separator: ", ")); remove those containers first")
        }
        return (state, image)
    }

    private func engineCommand(_ state: ContainerEngineState, _ arguments: [String]) -> (String, [String]) {
        let cli = state.cli ?? ""
        if state.kind == .apple { return (cli, arguments) }
        return (cli, ["-H", "unix://" + (state.socket ?? "")] + arguments)
    }

    private func removeImage(_ image: ContainerImage, state: ContainerEngineState, tools: ContainerTools) throws {
        // Remove by every name (all tags gone = image gone) rather than force by id,
        // so an image another tag still needs is never pulled out from under it.
        let names = image.references.isEmpty ? [image.id] : image.references
        let arguments = state.kind == .apple ? ["image", "delete"] + names : ["image", "rm"] + names
        let (cli, args) = engineCommand(state, arguments)
        _ = try tools.run(cli, args, 600)
    }

    private func freed(before: UInt64, state: ContainerEngineState, tools: ContainerTools) -> UInt64 {
        let after = state.dataPaths.reduce(0) { $0 + tools.allocated($1) }
        return before > after ? before - after : 0
    }

    private func spaceWarning(_ image: ContainerImage, freed: UInt64, state: ContainerEngineState) -> String? {
        guard freed < image.bytes / 4 else { return nil }
        if state.kind.usesVMDisk {
            return "\(state.kind.title) removed \(image.title), but its VM disk has not shrunk yet; the space comes back once \(state.kind.title) trims the disk (a restart of \(state.kind.title) usually does it)."
        }
        return "\(image.title) is gone from \(state.kind.title), but the Mac got back less than expected; layers other images share stay."
    }

    /// Saves the image to a tar, writes it to the repo once, checks the repo copy's sha256,
    /// and only then removes the image here.
    public func offloadContainerImage(_ key: String, progress: (String) -> Void = { _ in }) throws -> ContainerActionResult {
        let tools = containerTools
        progress("check")
        let (state, image) = try liveImage(key, tools: tools)
        try FileManager.default.createDirectory(at: containersDir, withIntermediateDirectories: true)
        let free = try VolumeSpace.availableBytes(at: containersDir.path)
        guard SpaceFloor.admits(freeBytes: free, incoming: image.bytes, floor: SpaceFloor.offloadFloor(config.minFreeBytes)) else {
            throw DisklesslyError.noSpace("Saving \(image.title) needs about \(image.bytes) bytes free in \(containersDir.path); \(free) are free")
        }
        let staging = containersDir.appendingPathComponent("save-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: staging) }
        progress("save")
        let names = image.references.isEmpty ? [image.id] : image.references
        let saveArgs = state.kind == .apple ? ["image", "save", "--output", staging.path] + names : ["save", "--output", staging.path] + names
        let (cli, args) = engineCommand(state, saveArgs)
        do {
            _ = try tools.run(cli, args, Self.containerTransferTimeout)
        } catch where state.kind == .apple && Self.isPartialMultiPlatform(error) {
            // A multi-platform image pulled for one platform lacks the others' layers, and
            // `container image save` exports every platform by default. Save this Mac's platform.
            try? FileManager.default.removeItem(at: staging)
            progress("save \(Self.hostPlatform)")
            let (cli, args) = engineCommand(state, ["image", "save", "--platform", Self.hostPlatform, "--output", staging.path] + names)
            _ = try tools.run(cli, args, Self.containerTransferTimeout)
        }
        guard FileManager.default.fileExists(atPath: staging.path) else {
            throw DisklesslyError.failure("\(state.kind.title) did not write \(image.title) to \(staging.path)")
        }
        let size = try ChunkedIO.byteCount(staging)
        let sha = try SHA256Digest.hexFile(staging)
        let record = ContainerImageRecord(engine: state.kind, imageId: image.id, references: image.references, sha256: sha, size: size,
                                          localBytes: image.bytes, host: (deviceFactsOverride ?? LiveDeviceFacts.current()).hostname)
        progress("upload")
        let backend = try repo
        if backend.localRoot() != nil {
            try? backend.ensureCollection(ContainerImages.root)
            try? backend.ensureCollection(ContainerImages.folder)
        }
        let written = try WriteOnce.putFile(backend: backend, path: record.tar, file: staging, sha256: sha)
        progress("verify")
        guard let stat = try backend.stat(record.tar), stat.size == size else {
            throw DisklesslyError.integrity("The repo copy of \(image.title) has the wrong size; the image was not removed")
        }
        let readBack = try readBackDigest(backend, record.tar, size: size)
        guard readBack == sha else {
            throw DisklesslyError.integrity("The repo copy of \(image.title) does not match what was saved; the image was not removed")
        }
        let recordPath = ContainerImages.recordPath(id: record.id)
        if (try? backend.stat(recordPath)) == nil { try backend.put(recordPath, data: try record.encode()) }
        progress("remove")
        let before = state.dataPaths.reduce(0) { $0 + tools.allocated($1) }
        try removeImage(image, state: state, tools: tools)
        let gained = freed(before: before, state: state, tools: tools)
        var uploaded = false
        if case .written = written { uploaded = true }
        return ContainerActionResult(title: image.title, record: record, freedBytes: gained, uploaded: uploaded,
                                     warning: spaceWarning(image, freed: gained, state: state))
    }

    /// Removes an image nothing uses, without saving it. It can be pulled again.
    public func cleanContainerImage(_ key: String) throws -> ContainerActionResult {
        let tools = containerTools
        let (state, image) = try liveImage(key, tools: tools)
        let before = state.dataPaths.reduce(0) { $0 + tools.allocated($1) }
        try removeImage(image, state: state, tools: tools)
        let gained = freed(before: before, state: state, tools: tools)
        return ContainerActionResult(title: image.title, record: nil, freedBytes: gained, uploaded: false,
                                     warning: spaceWarning(image, freed: gained, state: state))
    }

    /// Downloads a saved image (sha256 checked) and loads it into its engine again.
    public func restoreContainerImage(_ id: String, progress: (String) -> Void = { _ in }) throws -> ContainerActionResult {
        let tools = containerTools
        let record = try containerRecord(id)
        guard let endpoint = ContainerEndpoint.all(home: tools.home).first(where: { $0.kind == record.engine }),
              case let (state, images, _)? = scanEngine(endpoint, tools: tools, now: Date()) else {
            throw DisklesslyError.unsupported("\(record.engine.title) is not on this Mac")
        }
        guard state.status == .running else { throw DisklesslyError.unsupported("Start \(record.engine.title) first\(state.note.map { " (\($0))" } ?? "")") }
        if record.present(in: images) {
            return ContainerActionResult(title: record.title, record: record, freedBytes: 0, uploaded: false, warning: "\(record.title) is already in \(record.engine.title)")
        }
        try FileManager.default.createDirectory(at: containersDir, withIntermediateDirectories: true)
        let free = try VolumeSpace.availableBytes(at: containersDir.path)
        // The tar and the loaded image are both on disk until the tar is removed.
        guard SpaceFloor.admits(freeBytes: free, incoming: record.size + record.localBytes, floor: config.minFreeBytes) else {
            throw DisklesslyError.noSpace("\(record.title) needs about \(record.size + record.localBytes) bytes free to come back; \(free) are free")
        }
        progress("download")
        let file = containersDir.appendingPathComponent("\(record.id).tar")
        defer { try? FileManager.default.removeItem(at: file) }
        try CacheFetcher.materialize(backend: try repo, remote: record.tar, destination: file,
                                     partial: containersDir.appendingPathComponent("\(record.id).partial"),
                                     expectedSize: record.size, expectedSHA256: record.sha256)
        progress("load")
        let (cli, args) = engineCommand(state, state.kind == .apple ? ["image", "load", "--input", file.path] : ["load", "--input", file.path])
        _ = try tools.run(cli, args, Self.containerTransferTimeout)
        let after = scanEngine(endpoint, tools: tools, now: Date())?.1 ?? []
        let warning = record.present(in: after) ? nil : "\(record.engine.title) loaded the tar, but no image with id \(ContainerImage.shortId(record.imageId)) showed up"
        return ContainerActionResult(title: record.title, record: record, freedBytes: 0, uploaded: false, warning: warning)
    }
}

/// One container scan at a time off the request thread; the page polls `/api/containers`.
public final class ContainerScanner {
    private let lock = NSLock()
    private var scanning = false
    private var result: (report: [String: Any], at: Date)?
    private let run: (DisklesslyEngine) -> [String: Any]

    public init(run: ((DisklesslyEngine) -> [String: Any])? = nil) {
        self.run = run ?? { $0.containerReport().jsonObject() }
    }

    @discardableResult
    public func start(engine: DisklesslyEngine) -> Bool {
        lock.lock()
        if scanning { lock.unlock(); return false }
        scanning = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            let report = run(engine)
            lock.lock()
            result = (report, Date())
            scanning = false
            lock.unlock()
        }
        return true
    }

    public func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var object: [String: Any] = ["ok": true, "state": scanning ? "scanning" : (result == nil ? "idle" : "ready")]
        if let result {
            object.merge(result.report) { $1 }
            object["scannedAt"] = ISO8601DateFormatter().string(from: result.at)
        }
        return object
    }
}

extension DisklesslyEngine {
    /// `linux/arm64` on Apple silicon, `linux/amd64` on Intel: the platform Apple's `container` pulls by default.
    static var hostPlatform: String {
        #if arch(arm64)
        return "linux/arm64"
        #else
        return "linux/amd64"
        #endif
    }

    /// `container image save` of a multi-platform image whose other platforms were never pulled
    /// fails with "content with digest sha256:… not found".
    static func isPartialMultiPlatform(_ error: Error) -> Bool {
        let text = ((error as? LocalizedError)?.errorDescription ?? String(describing: error)).lowercased()
        return text.contains("content with digest")
    }
}
