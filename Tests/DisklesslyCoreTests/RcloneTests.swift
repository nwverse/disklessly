import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class RcloneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-rclone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A real rclone (bundled, Homebrew, or DISKLESSLY_RCLONE). Integration tests skip without one.
    private func rclone() throws -> URL {
        guard let found = RcloneTool.locate() else { throw XCTSkip("rclone is not installed") }
        return found
    }

    /// `t:` is an alias remote for a folder under the test root.
    private func aliasConfig() throws -> String {
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("rclone.conf")
        try "[t]\ntype = alias\nremote = \(store.path)\n".write(to: config, atomically: true, encoding: .utf8)
        return config.path
    }

    func testTargetJoinsRootAndRefusesEscapes() throws {
        let backend = RcloneBackend(binary: URL(fileURLWithPath: "/bin/false"), config: "/dev/null", remote: "gdrive", root: "/Disklessly/")
        XCTAssertEqual(try backend.target("images/a.dmg"), "gdrive:Disklessly/images/a.dmg")
        XCTAssertEqual(try backend.target(""), "gdrive:Disklessly")
        XCTAssertThrowsError(try backend.target("images/../../x"))
        let bare = RcloneBackend(binary: URL(fileURLWithPath: "/bin/false"), config: "/dev/null", remote: "box", root: "")
        XCTAssertEqual(try bare.target("/manifests"), "box:manifests")
    }

    func testBackendAddParsesRcloneRemote() throws {
        var draft = try BackendCommands.parseAdd(["rclone", "--remote", "gdrive:"])
        XCTAssertEqual(draft.remote, "gdrive")
        XCTAssertEqual(draft.id, "rclone-gdrive")
        draft.configPath = "/state/rclone/rclone.conf"
        let endpoint = try BackendCatalog.endpoint(from: draft)
        XCTAssertEqual(endpoint.type, "rclone")
        XCTAssertEqual(endpoint.root, "Disklessly")
        XCTAssertEqual(endpoint.url, "rclone://gdrive/Disklessly")
        XCTAssertEqual(endpoint.configPath, "/state/rclone/rclone.conf")
        XCTAssertThrowsError(try BackendCommands.parseAdd(["rclone"]))
        XCTAssertThrowsError(try BackendCommands.parseAdd(["rclone", "--remote", "a/b"]))
    }

    func testEndpointRoundTripsThroughConfigJSON() throws {
        let endpoint = BackendEndpoint(id: "rclone-gdrive", type: "rclone", url: "rclone://gdrive/Disklessly", root: "Disklessly", remote: "gdrive", configPath: "/x/rclone.conf")
        let decoded = try JSONDecoder().decode(BackendEndpoint.self, from: try JSONEncoder().encode(endpoint))
        XCTAssertEqual(decoded, endpoint)
    }

    func testStoreDoesNotActivateAndDefaultRepoClearsActive() {
        var config = RuntimeConfig.environment([:], home: root.path)
        let endpoint = BackendEndpoint(id: "rclone-gdrive", type: "rclone", root: "Disklessly", remote: "gdrive", configPath: "/x")
        config.store(endpoint)
        XCTAssertNil(config.activeBackendId)
        XCTAssertEqual(config.backends.map(\.id), ["rclone-gdrive"])
        config.store(endpoint)
        XCTAssertEqual(config.backends.count, 1)
        config.remember(endpoint)
        XCTAssertEqual(config.activeBackendId, "rclone-gdrive")
        config.useDefaultRepo()
        XCTAssertNil(config.activeBackendId)
        XCTAssertNotEqual(config.backend, "rclone")
    }

    func testRemoteNamesAndFreeName() {
        XCTAssertTrue(RcloneTool.validRemoteName("gdrive-2_x"))
        XCTAssertFalse(RcloneTool.validRemoteName(""))
        XCTAssertFalse(RcloneTool.validRemoteName("a b"))
        XCTAssertFalse(RcloneTool.validRemoteName("a:b"))
        XCTAssertFalse(RcloneTool.validRemoteName("网盘"))
        XCTAssertEqual(CloudDrives.freeName("gdrive", taken: []), "gdrive")
        XCTAssertEqual(CloudDrives.freeName("gdrive", taken: ["gdrive", "gdrive-2"]), "gdrive-3")
    }

    func testLocateHonorsOverrideAndSibling() {
        XCTAssertNil(RcloneTool.locate(environment: ["DISKLESSLY_RCLONE": "/nope/rclone"], isExecutable: { _ in false }))
        XCTAssertEqual(RcloneTool.locate(environment: ["DISKLESSLY_RCLONE": "/opt/r"], isExecutable: { $0 == "/opt/r" })?.path, "/opt/r")
        let found = RcloneTool.locate(environment: ["PATH": ""], executable: URL(fileURLWithPath: "/App.app/Contents/MacOS/disklessly"), isExecutable: { $0 == "/App.app/Contents/MacOS/rclone" })
        XCTAssertEqual(found?.path, "/App.app/Contents/MacOS/rclone")
    }

    func testEngineInstallCopiesRcloneBesideTheStableEngine() throws {
        let app = root.appendingPathComponent("App/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let cli = app.appendingPathComponent("disklessly")
        try Data("cli".utf8).write(to: cli)
        try Data("rclone-binary".utf8).write(to: app.appendingPathComponent("rclone"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("rclone").path)
        let state = root.appendingPathComponent("state").path
        let installed = try EngineInstall.install(stateDir: state, source: cli)
        let helper = installed.deletingLastPathComponent().appendingPathComponent("rclone")
        XCTAssertEqual(try Data(contentsOf: helper), Data("rclone-binary".utf8))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    func testRemoteTypeReadsConfigSection() throws {
        let state = root.appendingPathComponent("state").path
        let drives = CloudDrives(stateDir: state, binary: nil)
        try FileManager.default.createDirectory(atPath: (drives.configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "[gdrive]\ntype = drive\nscope = drive.file\n\n[box]\ntype = box\n".write(toFile: drives.configPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(drives.remoteType("gdrive"), "drive")
        XCTAssertEqual(drives.remoteType("box"), "box")
        XCTAssertNil(drives.remoteType("dropbox"))
        let listing = drives.listing(config: RuntimeConfig.environment([:], home: root.path))
        XCTAssertEqual(listing["rclone"] as? String, "")
        XCTAssertEqual((listing["providers"] as? [[String: String]])?.first?["id"], "gdrive")
    }

    func testBackendRoundTripThroughRcloneDaemon() throws {
        let binary = try rclone()
        let config = try aliasConfig()
        XCTAssertNotNil(RcloneDaemon.shared(binary: binary, config: config), "rclone rcd should start")
        try roundTrip(RcloneBackend(binary: binary, config: config, remote: "t", root: "repo", streams: 4))
    }

    func testBackendRoundTripThroughRcloneCLI() throws {
        let binary = try rclone()
        let config = try aliasConfig()
        setenv("DISKLESSLY_RCLONE_DAEMON", "0", 1)
        defer { unsetenv("DISKLESSLY_RCLONE_DAEMON") }
        XCTAssertNil(RcloneDaemon.shared(binary: binary, config: config))
        try roundTrip(RcloneBackend(binary: binary, config: config, remote: "t", root: "repo", streams: 4))
    }

    func testLocationSplitsFsAndPath() throws {
        let backend = RcloneBackend(binary: URL(fileURLWithPath: "/bin/false"), config: "/dev/null", remote: "gdrive", root: "Disklessly")
        XCTAssertEqual(try backend.location("images/a b.dmg").fs, "gdrive:Disklessly")
        XCTAssertEqual(try backend.location("images/a b.dmg").remote, "images/a b.dmg")
        let bare = RcloneBackend(binary: URL(fileURLWithPath: "/bin/false"), config: "/dev/null", remote: "box", root: "")
        XCTAssertEqual(try bare.location("/manifests").fs, "box:")
        XCTAssertEqual(try bare.location("/manifests").remote, "manifests")
    }

    private func roundTrip(_ backend: RcloneBackend) throws {
        XCTAssertEqual(try backend.list("manifests"), [])
        XCTAssertNil(try backend.stat("manifests/missing.json"))
        try backend.ensureCollection("manifests")
        try backend.put("manifests/a.json", data: Data("{\"a\":1}".utf8))
        XCTAssertEqual(try backend.list("manifests"), ["a.json"])
        XCTAssertEqual(try backend.stat("manifests/a.json")?.size, 7)
        XCTAssertEqual(try backend.get("manifests/a.json", range: 1..<4), Data("\"a\"".utf8))
        XCTAssertEqual(try backend.get("manifests/a.json", range: nil), Data("{\"a\":1}".utf8))
        try backend.put("manifests/with space+[x].json", data: Data("s".utf8))
        XCTAssertEqual(try backend.get("manifests/with space+[x].json", range: nil), Data("s".utf8))
        try backend.delete("manifests/with space+[x].json")

        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("payload.bin")
        try payload.write(to: source)
        try backend.put("images/p.bin", file: source)
        let whole = root.appendingPathComponent("whole.bin")
        let first = try backend.download("images/p.bin", to: whole, offset: 0)
        XCTAssertEqual(first.bytesWritten, UInt64(payload.count))
        XCTAssertEqual(try Data(contentsOf: whole), payload)

        let partial = root.appendingPathComponent("partial.bin")
        try payload.prefix(1000).write(to: partial)
        let resumed = try backend.download("images/p.bin", to: partial, offset: 1000)
        XCTAssertEqual(resumed.bytesWritten, UInt64(payload.count - 1000))
        XCTAssertEqual(try Data(contentsOf: partial), payload)

        try backend.delete("manifests/a.json")
        try backend.delete("manifests/a.json")
        XCTAssertEqual(try backend.list("manifests"), [])
        XCTAssertThrowsError(try backend.get("manifests/a.json", range: nil))
    }

    func testFactoryOpensRcloneEndpoint() throws {
        let binary = try rclone()
        setenv("DISKLESSLY_RCLONE", binary.path, 1)
        defer { unsetenv("DISKLESSLY_RCLONE") }
        let config = try aliasConfig()
        let endpoint = BackendEndpoint(id: "rclone-t", type: "rclone", root: "repo", remote: "t", configPath: config)
        let backend = try BackendFactory.open(endpoint, secrets: MemorySecretStore(), opener: ShareOpener.system)
        try backend.put("x.txt", data: Data("hi".utf8))
        XCTAssertEqual(try backend.get("x.txt", range: nil), Data("hi".utf8))
        XCTAssertEqual(try RcloneTool.remotes(binary: binary, config: config), ["t"])
    }

    func testGoogleClientFromEnvironmentOrBundle() throws {
        XCTAssertEqual(RcloneTool.googleClient(environment: ["DISKLESSLY_GDRIVE_CLIENT_ID": "id", "DISKLESSLY_GDRIVE_CLIENT_SECRET": "s"])?.id, "id")
        let app = root.appendingPathComponent("D.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data(#"{"client_id":"bundled","client_secret":"x"}"#.utf8).write(to: app.appendingPathComponent("Resources/google-oauth.json"))
        let found = RcloneTool.googleClient(environment: ["HOME": root.path], executable: app.appendingPathComponent("MacOS/disklessly"))
        XCTAssertEqual(found?.id, "bundled")
        XCTAssertEqual(found?.secret, "x")
        XCTAssertEqual(RcloneTool.createArguments(provider: "gdrive", googleClient: ("i", "s")),
                       ["scope", "drive.file", "client_id", "i", "client_secret", "s"])
        XCTAssertEqual(RcloneTool.createArguments(provider: "gdrive", googleClient: nil), ["scope", "drive.file"])
        XCTAssertEqual(RcloneTool.createArguments(provider: "dropbox", googleClient: ("i", "s")), [])
    }
}
