import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

/// Container images: parsing each CLI's output, the in-use decision, and offload / restore /
/// clean against fake CLIs. Nothing here runs a real `docker` or `container`.
final class ContainerImagesTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    let fm = FileManager.default
    let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("disklessly-containers-\(UUID().uuidString)")
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    // MARK: fixtures (shapes taken from the real CLIs)

    /// `container image list --format json`, container CLI 1.6.1 (trimmed).
    let appleImageList = """
    [{"configuration":{"creationDate":"2026-10-23T18:56:40Z","descriptor":{"digest":"sha256:407b89cd11a8cb67d388d21739a226c74acbbebe1ac59e3b83b11b43ce76b98f","mediaType":"application/vnd.oci.image.index.v1+json","size":1609},"name":"ghcr.io/home-assistant/home-assistant:stable"},"id":"407b89cd11a8cb67d388d21739a226c74acbbebe1ac59e3b83b11b43ce76b98f","variants":[{"config":{"architecture":"arm64"},"digest":"sha256:c2bb99de7179fe0c192757bc70a53db5f2ded6672a1ced0007accccd3f0de44c","platform":{"architecture":"arm64","os":"linux"},"size":644498092}]},
     {"configuration":{"creationDate":"2025-01-02T00:00:00Z","descriptor":{"digest":"sha256:aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000","mediaType":"application/vnd.oci.image.index.v1+json","size":900},"name":"docker.io/library/alpine:3.20"},"id":"aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000","variants":[{"digest":"sha256:bbbb0000bbbb0000bbbb0000bbbb0000bbbb0000bbbb0000bbbb0000bbbb0000","platform":{"architecture":"arm64","os":"linux"},"size":4000000}]}]
    """

    let appleContainerList = """
    [{"configuration":{"id":"hass","image":{"reference":"ghcr.io/home-assistant/home-assistant:stable","descriptor":{"digest":"sha256:407b89cd11a8cb67d388d21739a226c74acbbebe1ac59e3b83b11b43ce76b98f","size":1609}}},"status":"stopped","networks":[]}]
    """

    /// `docker image inspect` (trimmed to the fields read).
    let dockerImageInspect = """
    [{"Id":"sha256:1111111111111111111111111111111111111111111111111111111111111111","RepoTags":["nginx:latest"],"Created":"2025-06-01T10:00:00.123456789Z","Size":192000000,"Metadata":{"LastTagTime":"2025-06-02T10:00:00.987654321Z"}},
     {"Id":"sha256:2222222222222222222222222222222222222222222222222222222222222222","RepoTags":["postgres:16"],"Created":"2025-01-01T00:00:00Z","Size":450000000,"Metadata":{"LastTagTime":"0001-01-01T00:00:00Z"}},
     {"Id":"sha256:3333333333333333333333333333333333333333333333333333333333333333","RepoTags":[],"Created":"2024-01-01T00:00:00Z","Size":80000000,"Metadata":{"LastTagTime":"0001-01-01T00:00:00Z"}},
     {"Id":"sha256:4444444444444444444444444444444444444444444444444444444444444444","RepoTags":["ghcr.io/me/app:dev","me/app:dev"],"Created":"2026-11-01T00:00:00Z","Size":1200000000,"Metadata":{"LastTagTime":"2026-11-05T08:00:00Z"}},
     {"Id":"sha256:5555555555555555555555555555555555555555555555555555555555555555","RepoTags":["redis:7"],"Created":"2025-02-01T00:00:00Z","Size":120000000,"Metadata":{"LastTagTime":"2025-02-02T00:00:00Z"}}]
    """

    /// `docker container inspect`: web runs nginx; db is an exited postgres whose tag moved on
    /// (it refers to image 2 by id only).
    let dockerContainerInspect = """
    [{"Id":"c1","Name":"/web","Image":"sha256:1111111111111111111111111111111111111111111111111111111111111111","Config":{"Image":"nginx"},"State":{"Status":"running","Running":true,"StartedAt":"2026-11-07T09:00:00.5Z","FinishedAt":"0001-01-01T00:00:00Z"}},
     {"Id":"c2","Name":"/db","Image":"sha256:2222222222222222222222222222222222222222222222222222222222222222","Config":{"Image":"postgres:15"},"State":{"Status":"exited","Running":false,"StartedAt":"2025-03-01T00:00:00Z","FinishedAt":"2025-03-02T00:00:00Z"}}]
    """

    let dockerSystemDF = """
    {"Images":[],"Containers":[],"Volumes":[{"Driver":"local","Links":1,"Name":"pgdata","Size":"1.5GB"},{"Driver":"local","Links":0,"Name":"old","Size":"12.3MB"}],"BuildCache":[]}
    """

    // MARK: parsing and in-use

    func testAppleImageListParses() throws {
        let images = try ContainerParse.appleImages(Data(appleImageList.utf8))
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].image.id, "sha256:407b89cd11a8cb67d388d21739a226c74acbbebe1ac59e3b83b11b43ce76b98f")
        XCTAssertEqual(images[0].image.references, ["ghcr.io/home-assistant/home-assistant:stable"])
        XCTAssertEqual(images[0].manifestDigests, ["sha256:c2bb99de7179fe0c192757bc70a53db5f2ded6672a1ced0007accccd3f0de44c"])
        XCTAssertEqual(images[0].image.bytes, 0, "sizes come from disk, not the compressed variant size")
        XCTAssertEqual(images[0].image.key, "apple/sha256:407b89cd11a8cb67d388d21739a226c74acbbebe1ac59e3b83b11b43ce76b98f")
    }

    func testAppleStoppedContainerKeepsImageInUse() throws {
        let images = try ContainerParse.appleImages(Data(appleImageList.utf8)).map(\.image)
        let containers = try ContainerParse.appleContainers(Data(appleContainerList.utf8))
        XCTAssertEqual(containers, [ContainerRef(name: "hass", imageId: "sha256:407b89cd11a8cb67d388d21739a226c74acbbebe1ac59e3b83b11b43ce76b98f",
                                                 imageReference: "ghcr.io/home-assistant/home-assistant:stable", running: false)])
        let classified = ContainerParse.classify(images, containers: containers, now: now)
        XCTAssertEqual(classified[0].use, .stopped)
        XCTAssertEqual(classified[0].containers, ["hass"])
        XCTAssertTrue(classified[0].use.blocksRemoval)
        XCTAssertEqual(classified[1].use, .idle)
    }

    func testDockerInUseByIdRecentDanglingIdle() throws {
        let images = try ContainerParse.dockerImages(Data(dockerImageInspect.utf8), engine: .orbstack)
        let containers = try ContainerParse.dockerContainers(Data(dockerContainerInspect.utf8))
        XCTAssertEqual(containers.map(\.name), ["web", "db"])
        XCTAssertEqual(containers.map(\.running), [true, false])
        let use = Dictionary(uniqueKeysWithValues: ContainerParse.classify(images, containers: containers, now: now).map { (String($0.id.suffix(1)), $0) })
        XCTAssertEqual(use["1"]?.use, .running)
        XCTAssertEqual(use["1"]?.containers, ["web"])
        XCTAssertEqual(use["2"]?.use, .stopped, "matched by id even though the container was made from postgres:15")
        XCTAssertEqual(use["3"]?.use, .dangling)
        XCTAssertEqual(use["4"]?.use, .recent, "tagged two days ago")
        XCTAssertEqual(use["5"]?.use, .idle)
        XCTAssertEqual(use["1"]?.bytes, 192_000_000)
        XCTAssertEqual(use["1"]?.pulled, ContainerParse.date("2025-06-02T10:00:00.987Z"))
        XCTAssertNil(use["2"]?.pulled.flatMap { $0 < ContainerParse.date("2000-01-01T00:00:00Z")! ? $0 : nil }, "0001-01-01 is not a date")
        XCTAssertEqual(use["2"]?.lastRun, ContainerParse.date("2025-03-02T00:00:00Z"))
        XCTAssertEqual(use["3"]?.title, "<none> 333333333333")
    }

    func testReferenceMatchingFallbackAndNormalization() {
        XCTAssertEqual(ContainerParse.normalizedReference("nginx"), "docker.io/library/nginx:latest")
        XCTAssertEqual(ContainerParse.normalizedReference("me/app:dev"), "docker.io/me/app:dev")
        XCTAssertEqual(ContainerParse.normalizedReference("localhost:5000/app"), "localhost:5000/app:latest")
        XCTAssertEqual(ContainerParse.normalizedReference("ghcr.io/a/b:1@sha256:abc"), "ghcr.io/a/b:1")
        let image = ContainerImage(engine: .colima, id: "sha256:9999", references: ["nginx:latest"], bytes: 1)
        let byName = ContainerRef(name: "x", imageId: "", imageReference: "docker.io/library/nginx", running: true)
        XCTAssertTrue(ContainerParse.refers(byName, to: image))
        XCTAssertTrue(ContainerParse.sameId("sha256:1111111111111111111111", "111111111111"))
        XCTAssertFalse(ContainerParse.sameId("sha256:11112222", "1111"), "prefixes under 12 digits do not match")
    }

    func testSizesDatesAndVolumes() {
        XCTAssertEqual(ContainerParse.dockerSize("1.5GB"), 1_500_000_000)
        XCTAssertEqual(ContainerParse.dockerSize("512kB"), 512_000)
        XCTAssertEqual(ContainerParse.dockerSize("0B"), 0)
        XCTAssertEqual(ContainerParse.dockerSize("2GiB"), 2_147_483_648)
        XCTAssertNil(ContainerParse.dockerSize("lots"))
        XCTAssertNotNil(ContainerParse.date("2026-10-23T18:56:40.591251774Z"))
        XCTAssertNotNil(ContainerParse.date("2026-10-23 18:56:40 +0000 UTC"))
        XCTAssertNil(ContainerParse.date("0001-01-01T00:00:00Z"))
        let volumes = ContainerParse.dockerVolumes(Data(dockerSystemDF.utf8), engine: .dockerDesktop)
        XCTAssertEqual(volumes, [ContainerVolume(engine: .dockerDesktop, name: "pgdata", bytes: 1_500_000_000, links: 1),
                                 ContainerVolume(engine: .dockerDesktop, name: "old", bytes: 12_300_000, links: 0)])
        XCTAssertEqual(ContainerParse.ids(Data("a\nb\n\na\n".utf8)), ["a", "b"])
    }

    func testAppleBlobWalkFollowsIndexManifestConfigAndLayers() throws {
        let blobs: [String: String] = [
            "idx": #"{"manifests":[{"digest":"sha256:man"},{"digest":"sha256:other-arch"}]}"#,
            "man": #"{"config":{"digest":"sha256:cfg"},"layers":[{"digest":"sha256:l1"},{"digest":"sha256:l2"}]}"#,
            "cfg": "{}", "l1": "x", "l2": "y",
        ]
        let found = ContainerParse.appleBlobDigests(index: "sha256:idx") { blobs[$0].map { Data($0.utf8) } }
        XCTAssertEqual(found, ["idx", "man", "cfg", "l1", "l2"], "blobs not stored here (other-arch) are skipped")
    }

    func testRecordRoundTripAndPresence() throws {
        let record = ContainerImageRecord(engine: .orbstack, imageId: "sha256:5555555555555555555555555555555555555555555555555555555555555555",
                                          references: ["redis:7"], sha256: String(repeating: "AB", count: 32), size: 10, localBytes: 20, host: "mac")
        XCTAssertEqual(record.id, String(repeating: "ab", count: 8))
        XCTAssertEqual(record.tar, "containers/images/abababababababab.tar")
        XCTAssertEqual(try ContainerImageRecord.decode(try record.encode()), record)
        let here = ContainerImage(engine: .orbstack, id: record.imageId, references: [], bytes: 1)
        XCTAssertTrue(record.present(in: [here]))
        XCTAssertFalse(record.present(in: [ContainerImage(engine: .colima, id: record.imageId, references: [], bytes: 1)]))
    }

    func testContainerJobsAreNotAppRoutes() {
        XCTAssertEqual(UIJobKind(path: "/api/containers/offload"), .containersOffload)
        XCTAssertTrue(UIJobKind.containersRestore.isContainers)
        XCTAssertFalse(ManagementUI.isAppRoute(UIRequest(method: "POST", path: "/api/containers/clean", query: [:], headers: [:], body: Data())))
        XCTAssertTrue(ManagementUI.isAppRoute(UIRequest(method: "POST", path: "/api/pack", query: [:], headers: [:], body: Data())))
    }

    // MARK: engine with fake CLIs

    final class FakeCLI: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var responses: [(match: [String], reply: ([String]) throws -> Data)] = []
        func on(_ match: [String], _ reply: @escaping ([String]) throws -> Data) { responses.append((match, reply)) }
        func on(_ match: [String], _ text: String) { on(match) { _ in Data(text.utf8) } }
        func run(_ path: String, _ args: [String]) throws -> Data {
            lock.lock(); calls.append(args); lock.unlock()
            // Last registration wins, so a test can change an answer half way.
            for response in responses.reversed() where Self.contains(args, response.match) { return try response.reply(args) }
            throw DisklesslyError.failure("unexpected call: \(path) \(args.joined(separator: " "))")
        }
        static func contains(_ args: [String], _ match: [String]) -> Bool {
            guard match.count <= args.count else { return false }
            return (0...(args.count - match.count)).contains { Array(args[$0..<($0 + match.count)]) == match }
        }
        func called(_ match: [String]) -> Bool { lock.lock(); defer { lock.unlock() }; return calls.contains { Self.contains($0, match) } }
    }

    func makeEngine(_ cli: FakeCLI, executables: Set<String>) throws -> DisklesslyEngine {
        let repo = root.appendingPathComponent("repo")
        let config = RuntimeConfig(repoPath: repo.path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path,
                                   mountRoot: root.appendingPathComponent("mnt").path, stubDir: root.appendingPathComponent("apps").path)
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.backendOverride = try LocalFolderBackend(root: repo)
        try engine.initialize()
        let homePath = home.path
        engine.containerToolsOverride = ContainerTools(
            home: homePath,
            run: { path, args, _ in try cli.run(path, args) },
            isExecutable: { executables.contains($0) },
            // Only the temp home exists, so a real /Applications/Docker.app does not leak in.
            exists: { $0.hasPrefix(homePath) && FileManager.default.fileExists(atPath: $0) },
            allocated: { AllocatedSize.tree(URL(fileURLWithPath: $0)) },
            read: { FileManager.default.contents(atPath: $0) },
            modified: { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date })
        return engine
    }

    func write(_ relative: String, bytes: Int) throws {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    /// OrbStack socket and data folder in the temp home, docker in /opt/homebrew/bin.
    func orbstack() throws -> (FakeCLI, DisklesslyEngine) {
        try write(".orbstack/run/docker.sock", bytes: 0)
        try write("Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img", bytes: 400_000)
        let cli = FakeCLI()
        cli.on(["version"], "28.0.1\n")
        cli.on(["image", "ls", "-q", "--no-trunc"], (1...5).map { "sha256:" + String(repeating: "\($0)", count: 64) }.joined(separator: "\n"))
        let inspect = try JSONSerialization.jsonObject(with: Data(dockerImageInspect.utf8)) as! [[String: Any]]
        cli.on(["image", "inspect"]) { args in
            try JSONSerialization.data(withJSONObject: inspect.filter { args.contains($0["Id"] as! String) })
        }
        cli.on(["ps", "-aq", "--no-trunc"], "c1\nc2\n")
        cli.on(["container", "inspect"], dockerContainerInspect)
        cli.on(["system", "df"], dockerSystemDF)
        let engine = try makeEngine(cli, executables: ["/opt/homebrew/bin/docker"])
        return (cli, engine)
    }

    func testDockerReportUsesSocketAndClassifies() throws {
        let (cli, engine) = try orbstack()
        let report = engine.containerReport(now: now)
        XCTAssertEqual(report.engines.map(\.kind), [.orbstack])
        XCTAssertEqual(report.engines[0].status, .running)
        XCTAssertGreaterThan(report.engines[0].dataBytes, 0)
        XCTAssertTrue(cli.called(["-H", "unix://" + home.path + "/.orbstack/run/docker.sock", "version"]))
        XCTAssertEqual(report.images.count, 5)
        XCTAssertEqual(report.images.last.map(\.use.blocksRemoval), true, "in-use images sort last")
        XCTAssertEqual(report.volumes.map(\.name), ["pgdata", "old"])
        XCTAssertEqual(report.reclaimableBytes, 80_000_000 + 1_200_000_000 + 120_000_000)
        let json = report.jsonObject()
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testOffloadWritesVerifiedTarThenRemovesByAllNames() throws {
        let (cli, engine) = try orbstack()
        var savedNames: [String] = []
        cli.on(["save", "--output"]) { args in
            let index = args.firstIndex(of: "--output")!
            savedNames = Array(args[(index + 2)...])
            try Data("fake image tar".utf8).write(to: URL(fileURLWithPath: args[index + 1]))
            return Data()
        }
        cli.on(["image", "rm"]) { _ in Data() }
        let key = "orbstack/sha256:" + String(repeating: "4", count: 64)
        let result = try engine.offloadContainerImage(key)
        XCTAssertEqual(savedNames, ["ghcr.io/me/app:dev", "me/app:dev"], "saved with its tags so load brings them back")
        XCTAssertTrue(cli.called(["image", "rm", "ghcr.io/me/app:dev", "me/app:dev"]))
        let record = try XCTUnwrap(result.record)
        XCTAssertTrue(result.uploaded)
        XCTAssertEqual(record.sha256, SHA256Digest.hex(Data("fake image tar".utf8)))
        let repo = root.appendingPathComponent("repo")
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(record.tar)), Data("fake image tar".utf8))
        XCTAssertEqual(try engine.offloadedContainerImages(), [record])
        XCTAssertNotNil(result.warning, "the VM disk did not shrink, so the result says so")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: engine.containersDir.path).filter { $0.hasSuffix(".tar") }, [], "staging tar removed")
    }

    func testOffloadAndCleanRefuseImagesContainersUse() throws {
        let (cli, engine) = try orbstack()
        cli.on(["save"]) { _ in XCTFail("must not save"); return Data() }
        cli.on(["image", "rm"]) { _ in XCTFail("must not remove"); return Data() }
        for digit in ["1", "2"] {
            let key = "orbstack/sha256:" + String(repeating: digit, count: 64)
            XCTAssertThrowsError(try engine.offloadContainerImage(key)) { error in
                guard case DisklesslyError.busy(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains(digit == "1" ? "web" : "db"), message)
            }
            XCTAssertThrowsError(try engine.cleanContainerImage(key))
        }
        XCTAssertThrowsError(try engine.cleanContainerImage("nope/123"))
    }

    func testCleanRemovesDanglingImageById() throws {
        let (cli, engine) = try orbstack()
        cli.on(["image", "rm"]) { _ in Data() }
        let id = "sha256:" + String(repeating: "3", count: 64)
        let result = try engine.cleanContainerImage("orbstack/" + id)
        XCTAssertNil(result.record)
        XCTAssertTrue(cli.called(["image", "rm", id]))
        XCTAssertFalse(cli.called(["save"]))
    }

    func testOffloadKeepsImageWhenRepoCopyDiffers() throws {
        let (cli, engine) = try orbstack()
        cli.on(["save", "--output"]) { args in
            try Data("tar bytes".utf8).write(to: URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1]))
            return Data()
        }
        cli.on(["image", "rm"]) { _ in XCTFail("must not remove"); return Data() }
        // Someone else's different bytes already sit at the same path: write-once refuses.
        let sha = SHA256Digest.hex(Data("tar bytes".utf8))
        let path = root.appendingPathComponent("repo").appendingPathComponent(ContainerImages.tarPath(id: ContainerImages.recordId(sha256: sha)))
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other".utf8).write(to: path)
        XCTAssertThrowsError(try engine.offloadContainerImage("orbstack/sha256:" + String(repeating: "5", count: 64)))
    }

    func testRestoreLoadsCheckedTarAndForgetDeletes() throws {
        let (cli, engine) = try orbstack()
        cli.on(["save", "--output"]) { args in
            try Data("redis tar".utf8).write(to: URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1]))
            return Data()
        }
        cli.on(["image", "rm"]) { _ in Data() }
        let redis = "sha256:" + String(repeating: "5", count: 64)
        let record = try XCTUnwrap(try engine.offloadContainerImage("orbstack/" + redis).record)

        // The image is gone from OrbStack now.
        cli.on(["image", "ls", "-q", "--no-trunc"], (1...4).map { "sha256:" + String(repeating: "\($0)", count: 64) }.joined(separator: "\n"))
        var loaded: Data?
        cli.on(["load", "--input"]) { args in
            loaded = try Data(contentsOf: URL(fileURLWithPath: args[args.firstIndex(of: "--input")! + 1]))
            cli.on(["image", "ls", "-q", "--no-trunc"], (1...5).map { "sha256:" + String(repeating: "\($0)", count: 64) }.joined(separator: "\n"))
            return Data()
        }
        let restored = try engine.restoreContainerImage(record.id)
        XCTAssertEqual(loaded, Data("redis tar".utf8))
        XCTAssertNil(restored.warning)
        XCTAssertTrue(try engine.containerReport(now: now).offloaded.first.map { $0.present(in: engine.containerReport(now: now).images) } ?? false)

        // Already here: a second restore does not load again.
        loaded = nil
        XCTAssertNotNil(try engine.restoreContainerImage(record.id).warning)
        XCTAssertNil(loaded)

        _ = try engine.forgetContainerImage(record.id)
        XCTAssertEqual(try engine.offloadedContainerImages(), [])
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("repo").appendingPathComponent(record.tar).path))
    }

    func testAppleSizesComeFromSnapshotsAndBlobs() throws {
        let data = "Library/Application Support/com.apple.container"
        try write("\(data)/snapshots/c2bb99de7179fe0c192757bc70a53db5f2ded6672a1ced0007accccd3f0de44c/snapshot", bytes: 300_000)
        let blobs = "\(data)/content/blobs/sha256"
        let index = #"{"manifests":[{"digest":"sha256:c2bb99de7179fe0c192757bc70a53db5f2ded6672a1ced0007accccd3f0de44c"}]}"#
        let manifest = #"{"config":{"digest":"sha256:cfg"},"layers":[{"digest":"sha256:layer"}]}"#
        try fm.createDirectory(at: home.appendingPathComponent(blobs), withIntermediateDirectories: true)
        try Data(index.utf8).write(to: home.appendingPathComponent("\(blobs)/407b89cd11a8cb67d388d21739a226c74acbbebe1ac59e3b83b11b43ce76b98f"))
        try Data(manifest.utf8).write(to: home.appendingPathComponent("\(blobs)/c2bb99de7179fe0c192757bc70a53db5f2ded6672a1ced0007accccd3f0de44c"))
        try write("\(blobs)/cfg", bytes: 10)
        try write("\(blobs)/layer", bytes: 100_000)

        let cli = FakeCLI()
        cli.on(["system", "status"], "status running\n")
        cli.on(["image", "list", "--format", "json"], appleImageList)
        cli.on(["list", "--all", "--format", "json"], "[]")
        cli.on(["volume", "list", "--format", "json"], "[]")
        let engine = try makeEngine(cli, executables: ["/opt/homebrew/bin/container"])
        let report = engine.containerReport(now: now)
        XCTAssertEqual(report.engines.map(\.kind), [.apple])
        let hass = try XCTUnwrap(report.images.first { $0.references == ["ghcr.io/home-assistant/home-assistant:stable"] })
        XCTAssertGreaterThanOrEqual(hass.bytes, 400_000, "snapshot plus layer blob")
        XCTAssertLessThan(hass.bytes, 600_000)
        XCTAssertEqual(hass.use, .recent, "the snapshot was just written, so it was pulled today")
        let alpine = try XCTUnwrap(report.images.first { $0.references == ["docker.io/library/alpine:3.20"] })
        XCTAssertEqual(alpine.bytes, 0, "nothing of it on disk")
        XCTAssertFalse(cli.called(["system", "start"]))

        cli.on(["image", "save", "--output"]) { args in
            try Data("apple tar".utf8).write(to: URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1]))
            return Data()
        }
        cli.on(["image", "delete"]) { _ in Data() }
        _ = try engine.offloadContainerImage(hass.key)
        XCTAssertTrue(cli.called(["image", "save", "--output"]))
        XCTAssertTrue(cli.called(["image", "delete", "ghcr.io/home-assistant/home-assistant:stable"]))
    }

    func testStoppedEngineAndMissingCLIReportOnlyDiskSize() throws {
        try write("Library/Application Support/com.apple.container/content/blob", bytes: 50_000)
        try write(".colima/_lima/colima/diffdisk", bytes: 70_000)
        let cli = FakeCLI()
        cli.on(["system", "status"]) { _ in throw DisklesslyError.failure("container system status failed (exit 1): apiserver is not running") }
        let engine = try makeEngine(cli, executables: ["/opt/homebrew/bin/container"])
        let report = engine.containerReport(now: now)
        let byKind = Dictionary(uniqueKeysWithValues: report.engines.map { ($0.kind, $0) })
        XCTAssertEqual(byKind[.apple]?.status, .stopped)
        XCTAssertNotNil(byKind[.apple]?.note)
        XCTAssertGreaterThan(byKind[.apple]?.dataBytes ?? 0, 0)
        XCTAssertEqual(byKind[.colima]?.status, .noCli)
        XCTAssertGreaterThan(byKind[.colima]?.dataBytes ?? 0, 0)
        XCTAssertTrue(report.images.isEmpty)
        XCTAssertFalse(cli.called(["image", "list"]), "nothing past the status probe while the engine is down")
        XCTAssertThrowsError(try engine.offloadContainerImage("apple/sha256:407b"))
    }
}
