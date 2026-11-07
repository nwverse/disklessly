import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

/// The Linux build's rules. Everything here takes the platform as a value, so both
/// platforms' behavior is checked on either host.
final class LinuxSupportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-linux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAppCommandsAreRefusedOnLinuxOnly() {
        for command in ["pack", "launch", "unpack", "recommend", "stub", "gc", "doctor"] {
            let refusal = PlatformCommands.refusal(command, on: .linux)
            XCTAssertEqual(refusal?.exitCode, 3, command)
            XCTAssertTrue(refusal?.errorDescription?.contains("macOS only") == true, command)
            XCTAssertNil(PlatformCommands.refusal(command, on: .macOS), command)
        }
        for command in PlatformCommands.linux {
            XCTAssertNil(PlatformCommands.refusal(command, on: .linux), command)
        }
        XCTAssertTrue(PlatformCommands.linux.isDisjoint(with: PlatformCommands.macOSOnly))
        XCTAssertNil(PlatformCommands.refusal("no-such-command", on: .linux), "unknown commands stay usage errors")
    }

    func testLinuxDefaultsFollowXDG() {
        let home = "/home/u"
        let plain = RuntimeConfig.environment([:], home: home, platform: .linux)
        XCTAssertEqual(plain.stateDir, "/home/u/.local/share/disklessly")
        XCTAssertEqual(plain.cacheDir, "/home/u/.cache/disklessly")
        XCTAssertEqual(plain.repoPath, "/home/u/.local/share/disklessly/repo")
        XCTAssertEqual(plain.mountRoot, "/home/u/.cache/disklessly/mnt")
        XCTAssertEqual(plain.stubDir, "/home/u/Applications")
        XCTAssertEqual(plain.backend, "local")

        let xdg = RuntimeConfig.environment(["XDG_DATA_HOME": "/data", "XDG_CACHE_HOME": "/c", "XDG_CONFIG_HOME": "relative"], home: home, platform: .linux)
        XCTAssertEqual(xdg.stateDir, "/data/disklessly")
        XCTAssertEqual(xdg.cacheDir, "/c/disklessly")
        let overridden = RuntimeConfig.environment(["DISKLESSLY_STATE_DIR": "/s", "XDG_DATA_HOME": "/data"], home: home, platform: .linux)
        XCTAssertEqual(overridden.stateDir, "/s")
        XCTAssertEqual(overridden.repoPath, "/data/disklessly/repo")

        XCTAssertEqual(RuntimeConfig.environment([:], home: home, platform: .macOS).stateDir, "/home/u/Library/Application Support/Disklessly")
    }

    func testFileSecretStoreIsPrivateAndRoundTrips() throws {
        let url = JSONFileSecretStore.defaultURL(environment: ["XDG_CONFIG_HOME": root.path], home: "/unused")
        XCTAssertEqual(url.path, root.appendingPathComponent("disklessly/secrets.json").path)
        let store = JSONFileSecretStore(url: url)
        XCTAssertNil(try store.load(service: "s", account: "a"))
        try store.save(service: "s", account: "a", secret: "one")
        try store.save(service: "s", account: "b", secret: "two")
        try store.save(service: "s", account: "a", secret: "three")
        XCTAssertEqual(try store.load(service: "s", account: "a"), "three")
        XCTAssertEqual(try JSONFileSecretStore(url: url).load(service: "s", account: "b"), "two")
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(dirMode?.intValue, 0o700)
        try store.delete(service: "s", account: "a")
        XCTAssertNil(try store.load(service: "s", account: "a"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["secrets.json"], "no temp files are left behind")
    }

    /// A stand-in `secret-tool` that keeps items in a folder, one file per service/account.
    private func fakeSecretTool() throws -> URL {
        let bin = root.appendingPathComponent("bin")
        let db = root.appendingPathComponent("keyring")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        cmd="$1"; shift
        [ "$cmd" = store ] && shift
        key="$2--$4"
        case "$cmd" in
          store) cat > "\(db.path)/$key" ;;
          lookup) [ -f "\(db.path)/$key" ] || exit 1; cat "\(db.path)/$key" ;;
          *) echo "bad command" >&2; exit 2 ;;
        esac
        """
        let tool = bin.appendingPathComponent("secret-tool")
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return bin
    }

    func testLinuxStoreUsesSecretToolWithADBusSessionAndReadsTheFileToo() throws {
        let bin = try fakeSecretTool()
        let env = ["PATH": bin.path, "DBUS_SESSION_BUS_ADDRESS": "unix:path=/x", "WAYLAND_DISPLAY": "wayland-0", "XDG_CONFIG_HOME": root.path]
        // A secret saved to the file before the keyring was used is still found.
        try JSONFileSecretStore(url: JSONFileSecretStore.defaultURL(environment: env, home: "/unused")).save(service: "svc", account: "old", secret: "from-file")
        let store = LinuxSecretStore(environment: env, home: "/unused")
        XCTAssertEqual(try store.load(service: "svc", account: "old"), "from-file")
        try store.save(service: "svc", account: "new", secret: "pa ss\nword")
        XCTAssertEqual(try store.load(service: "svc", account: "new"), "pa ss\nword")
        XCTAssertNil(try store.file.load(service: "svc", account: "new"), "the keyring copy is not mirrored to the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keyring/svc--new").path))
        XCTAssertNil(try store.load(service: "svc", account: "missing"))
    }

    func testLinuxStoreWithoutADesktopSessionUsesTheFile() throws {
        let bin = try fakeSecretTool()
        // No D-Bus at all, and an SSH login (D-Bus from pam_systemd but no display).
        for env in [["PATH": bin.path, "XDG_CONFIG_HOME": root.path],
                    ["PATH": bin.path, "XDG_CONFIG_HOME": root.path, "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"]] {
            let store = LinuxSecretStore(environment: env, home: "/unused")
            XCTAssertNil(store.tool)
            try store.save(service: "svc", account: "a", secret: "x")
            XCTAssertEqual(try store.file.load(service: "svc", account: "a"), "x")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("keyring/svc--a").path))
        }

        let forced = LinuxSecretStore(environment: ["PATH": "/nonexistent", "DISKLESSLY_SECRET_STORE": "secret-tool", "XDG_CONFIG_HOME": root.path], home: "/unused")
        XCTAssertThrowsError(try forced.save(service: "svc", account: "a", secret: "x"))
    }

    func testAFailingSecretToolIsNotAskedAgain() throws {
        let bin = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("secret-tool")
        try "#!/bin/sh\necho 'Cannot autolaunch D-Bus' >&2\nexit 1\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let store = LinuxSecretStore(environment: ["PATH": bin.path, "DBUS_SESSION_BUS_ADDRESS": "x", "DISPLAY": ":0", "XDG_CONFIG_HOME": root.path], home: "/unused")
        XCTAssertNotNil(store.tool)
        XCTAssertNil(try store.load(service: "svc", account: "a"))
        XCTAssertNil(store.tool, "the file is used for the rest of the run")
        try store.save(service: "svc", account: "a", secret: "x")
        XCTAssertEqual(try store.file.load(service: "svc", account: "a"), "x")
    }

    func testLinuxUsageGivesAppsTheirDataAndCountsDotFoldersOnce() {
        var m = UsageScan.LinuxMeasurements()
        m.home = [".cache": 500, ".local": 900, ".config": 60, ".var": 300, "snap": 80, "Videos": 1000, "code": 200]
        m.cache = ["Foo": 40, "pip": 100, "disklessly": 300]
        m.share = ["flatpak": 450, "foo": 20, "Trash": 30, "disklessly": 200]
        m.config = ["foo": 5, "git": 1]
        m.varApp = ["org.example.App": 250]
        m.snapHome = ["firefox": 70]
        m.opt = ["Foo": 400]
        m.flatpakSystem = ["org.example.App": 600]
        m.flatpakUser = ["org.other.Tool": 400]
        m.snaps = ["firefox": 900]
        m.homeClaimed = ["code": 50]
        var input = UsageInputs(totalBytes: 10_000, freeBytes: 2_000)
        UsageScan.linuxInputs(m, into: &input)

        let apps = Dictionary(uniqueKeysWithValues: input.apps.map { ($0.name, $0) })
        XCTAssertEqual(apps["org.example.App"]?.dataBytes, 250)
        XCTAssertEqual(apps["org.other.Tool"]?.bundleBytes, 400)
        XCTAssertEqual(apps["firefox"]?.bundleBytes, 900)
        XCTAssertEqual(apps["firefox"]?.dataBytes, 70)
        XCTAssertEqual(apps["Foo"]?.cacheBytes, 40)
        XCTAssertEqual(apps["Foo"]?.dataBytes, 25, "~/.local/share/foo and ~/.config/foo match case-insensitively")

        let personal = Dictionary(uniqueKeysWithValues: input.personal.map { ($0.name, $0.bytes) })
        XCTAssertEqual(personal, ["Videos": 1000, "code": 150], "dot folders leave personal files; the repo is not counted twice")
        let data = Dictionary(uniqueKeysWithValues: input.library.map { ($0.name, $0) })
        XCTAssertEqual(data[".cache"]?.bytes, 500 - 40 - 300)
        XCTAssertEqual(data[".cache"]?.children.map(\.name), ["pip"])
        XCTAssertEqual(data[".local"]?.bytes, 900 - 400 - 20 - 200, "user Flatpak apps and Disklessly's own folder are counted elsewhere")
        XCTAssertEqual(data[".local"]?.children.first { $0.name == "flatpak" }?.bytes, 50)
        XCTAssertEqual(data[".var"]?.bytes, 50)
        XCTAssertEqual(data["snap"]?.bytes, 10)
        XCTAssertEqual(input.libraryKey, "appdata")

        let tree = UsageMap.assemble(input)
        XCTAssertEqual(tree.bytes, 10_000)
        XCTAssertNotNil(tree.children.first { $0.key == "appdata" })
        XCTAssertNil(tree.children.first { $0.key == "library" })
    }

    func testDashboardOnLinuxRefusesAppRoutes() throws {
        var config = RuntimeConfig.environment([:], home: root.path, platform: .linux)
        config.stateDir = root.appendingPathComponent("state").path
        config.repoPath = root.appendingPathComponent("repo").path
        config.cacheDir = root.appendingPathComponent("cache").path
        let engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        let context = ManagementUIContext(platform: .linux)
        for (method, path) in [("POST", "/api/pack"), ("POST", "/api/launch"), ("GET", "/api/recommend"), ("POST", "/api/icons/backfill")] {
            let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: method, path: path, body: Data("{\"app\":\"X\"}".utf8)), context: context)
            XCTAssertEqual(response.status, 501, path)
            let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            XCTAssertEqual((object?["error"] as? [String: Any])?["code"] as? String, "unsupported", path)
        }
        let license = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/license"), context: context)
        XCTAssertEqual(license.status, 200)
        XCTAssertEqual(ManagementUI.dashboard(engine, context: context)["platform"] as? String, "linux")
        XCTAssertEqual(ManagementUI.dashboard(engine, context: ManagementUIContext(platform: .macOS))["platform"] as? String, "macos")
    }

    func testProcListsThisProcessOpenFiles() throws {
        guard FileManager.default.fileExists(atPath: "/proc/self/fd") else { throw XCTSkip("no /proc on this host") }
        let file = root.appendingPathComponent("live.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data("{}\n".utf8))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let open = try XCTUnwrap(OpenFileProbe.procOpenPaths())
        XCTAssertTrue(open.contains(SessionPaths.canonical(file.path)))
    }
}
