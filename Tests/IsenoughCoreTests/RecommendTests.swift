import XCTest
import Foundation
import IsenoughCore
@testable import IsenoughEngine

final class RecommendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var mebi: UInt64 { 1024 * 1024 }
    private var hundred: UInt64 { 100 * mebi }

    func testScorePaysANeverUsedBonus() {
        let idleYear = RecommendScore.value(sizeBytes: 200 * mebi, daysIdle: 365, neverUsed: false)
        let never = RecommendScore.value(sizeBytes: 200 * mebi, daysIdle: nil, neverUsed: true)
        let idleYearAndBonus = RecommendScore.value(sizeBytes: 200 * mebi, daysIdle: 365 + 90, neverUsed: false)
        XCTAssertEqual(never, 200 * 455)
        XCTAssertGreaterThan(never, idleYear)
        XCTAssertEqual(never, idleYearAndBonus)
        XCTAssertEqual(RecommendScore.daysIdle(lastUsed: now.addingTimeInterval(-10 * 86_400 - 30), now: now), 10)
        XCTAssertEqual(RecommendScore.daysIdle(lastUsed: now.addingTimeInterval(50), now: now), 0)
        XCTAssertNil(RecommendScore.daysIdle(lastUsed: nil, now: now))
    }

    func testRankOrdersByScoreAndFilters() {
        let bigIdle = app(name: "Blender", bundleId: "org.blender", size: 400 * mebi, lastUsed: now.addingTimeInterval(-30 * 86_400))
        let bigRecent = app(name: "Recent", bundleId: "org.recent", size: 400 * mebi, lastUsed: now.addingTimeInterval(-2 * 86_400))
        let never = app(name: "Shelf", bundleId: "org.shelf", size: 150 * mebi, lastUsed: nil)
        let small = app(name: "Tiny", bundleId: "org.tiny", size: 10 * mebi, lastUsed: nil)
        let tieA = app(name: "A", bundleId: "org.a", size: hundred, lastUsed: now.addingTimeInterval(-10 * 86_400))
        let tieB = app(name: "B", bundleId: "org.b", size: hundred, lastUsed: now.addingTimeInterval(-10 * 86_400))
        var options = RecommendOptions(minSizeBytes: hundred, now: now)
        let report = RecommendRanking.rank([tieB, small, bigRecent, never, bigIdle, tieA], options: options)
        XCTAssertEqual(report.recommendations.map(\.name), ["Shelf", "Blender", "A", "B", "Recent"])
        XCTAssertEqual(report.recommendations[0].reason, "150 MiB, never used")
        XCTAssertEqual(report.recommendations[0].neverUsed, true)
        XCTAssertEqual(report.recommendations[0].daysIdle, nil)
        XCTAssertEqual(report.recommendations[1].reason, "400 MiB, last used 30 days ago")
        XCTAssertEqual(report.estimatedFreedBytes, (400 + 150 + 400 + 100 + 100) * mebi)
        options.minIdleDays = 14
        let idled = RecommendRanking.rank([bigIdle, bigRecent, never, small], options: options)
        XCTAssertEqual(idled.recommendations.map(\.name), ["Shelf", "Blender"])
        options.limit = 1
        options.minIdleDays = nil
        let limited = RecommendRanking.rank([bigIdle, never], options: options)
        XCTAssertEqual(limited.recommendations.map(\.name), ["Shelf"])
        XCTAssertEqual(limited.estimatedFreedBytes, 150 * mebi)
    }

    func testSkipsStubsRunningAndSystemApps() {
        let running = app(name: "Open", bundleId: "org.open", size: 200 * mebi, running: true)
        let stub = app(name: "Stub", bundleId: "org.real.256stub", size: 200 * mebi, stub: true)
        let product = app(name: "Isenough", bundleId: "io.github.s546126.256isenough", size: 200 * mebi, isenoughProduct: true)
        let system = app(name: "TextEdit", bundleId: "com.apple.TextEdit", size: 200 * mebi, systemLocation: true)
        let signed = app(name: "Mail", bundleId: "com.apple.mail", size: 200 * mebi, appleSystemSigned: true)
        let kept = app(name: "Kept", bundleId: "org.kept", size: 200 * mebi)
        let report = RecommendRanking.rank([running, stub, product, system, signed, kept], options: RecommendOptions(now: now))
        XCTAssertEqual(report.recommendations.map(\.name), ["Kept"])
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testWarnsAboutPoorCandidatesAndStoreReceipts() {
        let xcode = app(name: "Xcode", bundleId: "com.apple.dt.Xcode", size: 8 * 1024 * mebi, appleSystemSigned: true, toolchain: true)
        let login = app(name: "Dropbox", bundleId: "com.dropbox", size: 200 * mebi, loginItem: true, menuBarAgent: true)
        let helper = app(name: "HelperHost", bundleId: "org.helper", size: 200 * mebi, backgroundHelperRunning: true)
        let sysext = app(name: "VPN", bundleId: "org.vpn", size: 200 * mebi, systemExtension: true)
        let kext = app(name: "Driver", bundleId: "org.kext", size: 200 * mebi, kernelExtension: true)
        let pinned = app(name: "Pinned", bundleId: "org.pin", size: 200 * mebi, pinned: true)
        let packed = app(name: "Packed", bundleId: "org.packed", size: 200 * mebi, packed: true)
        let store = app(name: "Pages", bundleId: "com.apple.Pages", size: 200 * mebi, macAppStore: true)
        let timed = app(name: "Partial", bundleId: "org.partial", size: 20 * mebi, sizeIncomplete: true)
        let tinyMenu = app(name: "Menu", bundleId: "org.menu", size: 2 * mebi, menuBarAgent: true)
        let report = RecommendRanking.rank([tinyMenu, timed, store, packed, pinned, kext, sysext, helper, login, xcode], options: RecommendOptions(minSizeBytes: hundred, now: now))
        XCTAssertEqual(report.recommendations.map(\.bundleId), ["com.apple.Pages"])
        XCTAssertEqual(report.recommendations[0].suggestedMode, "restore")
        XCTAssertTrue(report.recommendations[0].reason.contains("Mac App Store receipt, restore mode"))
        XCTAssertEqual(report.warnings.map(\.name), ["Xcode", "Driver", "Dropbox", "HelperHost", "Packed", "Pinned", "VPN", "Partial"])
        XCTAssertEqual(report.warnings[0].warnings, ["toolchain"])
        XCTAssertEqual(report.warnings[0].suggestedMode, "unsupported")
        XCTAssertEqual(report.warnings[0].reason, "toolchain used by the engine")
        XCTAssertEqual(report.warnings.first { $0.name == "Dropbox" }?.warnings, ["loginItem", "menuBarAgent"])
        XCTAssertEqual(report.warnings.first { $0.name == "Dropbox" }?.suggestedMode, "restore")
        XCTAssertEqual(report.warnings.first { $0.name == "Partial" }?.warnings, ["sizeTimedOut"])
        XCTAssertEqual(report.estimatedFreedBytes, 200 * mebi)
        XCTAssertFalse(report.warnings.contains { $0.name == "Menu" })
    }

    func testByteTextIsPOSIX() {
        XCTAssertEqual(RecommendFormatting.byteText(0), "0 B")
        XCTAssertEqual(RecommendFormatting.byteText(1024 * 1024), "1.0 MiB")
        XCTAssertEqual(RecommendFormatting.byteText(10 * 1024 * 1024), "10 MiB")
        XCTAssertEqual(RecommendFormatting.byteText(1024 * 1024 * 1024), "1.0 GiB")
        XCTAssertEqual(RecommendFormatting.byteText(12 * 1024 * 1024 * 1024), "12 GiB")
    }

    func testArgumentParsing() throws {
        let parsed = try RecommendArguments.parse(["--json", "--min-size", "100MB", "--limit", "5", "--min-idle-days", "30"])
        XCTAssertTrue(parsed.json)
        XCTAssertEqual(parsed.minSizeBytes, 100_000_000)
        XCTAssertEqual(parsed.limit, 5)
        XCTAssertEqual(parsed.minIdleDays, 30)
        XCTAssertEqual(try RecommendArguments.parseSize("100MiB"), 100 * 1024 * 1024)
        XCTAssertEqual(try RecommendArguments.parseSize("1.5GiB"), UInt64(1.5 * 1024 * 1024 * 1024))
        XCTAssertEqual(try RecommendArguments.parseSize("2048"), 2048)
        XCTAssertEqual(RecommendArguments().minSizeBytes, RecommendLimits.defaultMinSizeBytes)
        XCTAssertThrowsError(try RecommendArguments.parse(["--min-size"]))
        XCTAssertThrowsError(try RecommendArguments.parse(["--limit", "-1"]))
        XCTAssertThrowsError(try RecommendArguments.parseSize("100 megabytes"))
        XCTAssertThrowsError(try RecommendArguments.parseSize("soon"))
        let query = try RecommendArguments.parse(query: ["min-size": "50MiB", "limit": "2", "minIdleDays": "0"])
        XCTAssertEqual(query.minSizeBytes, 50 * 1024 * 1024)
        XCTAssertEqual(query.limit, 2)
        XCTAssertEqual(query.minIdleDays, 0)
    }

    func testTextAndJSON() {
        let item = app(name: "Blender", bundleId: "org.blender", size: 1024 * mebi, lastUsed: nil)
        let report = RecommendRanking.rank([item], options: RecommendOptions(now: now))
        let text = report.text()
        XCTAssertTrue(text.contains("1 recommendation, 1.0 GiB estimated free"))
        XCTAssertTrue(text.contains("Blender (/Applications/Blender.app) org.blender"))
        XCTAssertTrue(text.contains("1.0 GiB, never used"))
        XCTAssertTrue(text.contains("mode mount"))
        XCTAssertTrue(text.contains("0 warnings"))
        let object = report.jsonObject()
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["scan"] as? String, "ok")
        let rows = object["recommendations"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["neverUsed"] as? Bool, true)
        XCTAssertTrue(rows?.first?["lastUsed"] is NSNull)
        XCTAssertEqual((rows?.first?["estimatedFreedBytes"] as? NSNumber)?.uint64Value, 1024 * mebi)
        let unavailable = RecommendRanking.rank([], options: RecommendOptions(now: now), scanAvailable: false)
        XCTAssertEqual(unavailable.jsonObject()["scan"] as? String, "unavailable")
        XCTAssertTrue(unavailable.text().contains("Scanning installed apps requires macOS."))
    }

    func testSystemPathAndToolchainHelpers() {
        XCTAssertTrue(RecommendPaths.isSystemLocation("/System/Applications/TextEdit.app"))
        XCTAssertTrue(RecommendPaths.isSystemLocation("/System"))
        XCTAssertFalse(RecommendPaths.isSystemLocation("/Applications/Xcode.app"))
        XCTAssertTrue(RecommendToolchain.matches(bundleId: "com.apple.dt.Xcode", bundlePath: "/Applications/Xcode.app", developerDirectories: []))
        XCTAssertTrue(RecommendToolchain.matches(bundleId: "com.example.Tool", bundlePath: "/Applications/Tool.app", developerDirectories: ["/Applications/Tool.app/Contents/Developer"]))
        XCTAssertFalse(RecommendToolchain.matches(bundleId: "org.blender", bundlePath: "/Applications/Blender.app", developerDirectories: ["/Applications/Xcode.app/Contents/Developer"]))
    }

    func testDirectoryMeasureMatchesBlocksAndStopsAtDeadline() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Measure.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent("payload")
        try Data(repeating: 7, count: 256 * 1024).write(to: file)
        let outside = root.appendingPathComponent("outside.bin")
        try Data(repeating: 9, count: 256 * 1024).write(to: outside)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("link"), withDestinationURL: outside)
        let full = DirectoryMeasure.allocatedBytes(at: root.appendingPathComponent("Measure.app"), deadline: Date().addingTimeInterval(30))
        XCTAssertFalse(full.incomplete)
        XCTAssertGreaterThan(full.bytes, 200 * 1024)
        XCTAssertLessThan(full.bytes, 256 * 1024 + 64 * 1024)
        let stopped = DirectoryMeasure.allocatedBytes(at: root.appendingPathComponent("Measure.app"), deadline: Date(timeIntervalSince1970: 0)) {
            Date(timeIntervalSince1970: 0)
        }
        XCTAssertTrue(stopped.incomplete)
        XCTAssertEqual(stopped.bytes, 0)
        var calls = 0
        let partial = DirectoryMeasure.allocatedBytes(at: root.appendingPathComponent("Measure.app"), deadline: Date(timeIntervalSince1970: 50)) {
            calls += 1
            return calls < 3 ? Date(timeIntervalSince1970: 0) : Date(timeIntervalSince1970: 50)
        }
        XCTAssertTrue(partial.incomplete)
        XCTAssertLessThan(partial.bytes, full.bytes)
    }

    func testDiscoveryReadsInjectedApps() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        let agents = root.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try makeApp(apps.appendingPathComponent("Big.app"), bundleId: "org.big", name: "Big", extra: [:])
        let receiptDir = apps.appendingPathComponent("Big.app/Contents/_MASReceipt")
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: receiptDir.appendingPathComponent("receipt"))
        try makeApp(apps.appendingPathComponent("Menu.app"), bundleId: "org.menu", name: "Menu", extra: ["LSUIElement": true])
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Menu.app/Contents/Library/LoginItems/Helper.app"), withIntermediateDirectories: true)
        try makeApp(apps.appendingPathComponent("Stub.app"), bundleId: "org.real.256stub", name: "Stub", executable: "isenough-stub", extra: [:])
        try makeApp(apps.appendingPathComponent("Nested.app"), bundleId: "org.outer", name: "Outer", extra: [:])
        try makeApp(apps.appendingPathComponent("Nested.app/Contents/Frameworks/Inner.app"), bundleId: "org.inner", name: "Inner", extra: [:])
        try makeApp(apps.appendingPathComponent("Ext.app"), bundleId: "org.ext", name: "Ext", extra: [:])
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Ext.app/Contents/Library/SystemExtensions/Guard.systemextension"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Ext.app/Contents/Library/Extensions/Guard.kext"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: apps.appendingPathComponent("notes.txt"))
        let agent: [String: Any] = ["ProgramArguments": [apps.appendingPathComponent("Big.app/Contents/MacOS/Big").path]]
        let agentData = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try agentData.write(to: agents.appendingPathComponent("big.plist"))
        let bigPath = apps.appendingPathComponent("Big.app").standardizedFileURL.path
        let environment = RecommendEnvironment(
            roots: [apps],
            launchAgentDirectories: [agents],
            developerDirectories: [apps.appendingPathComponent("Ext.app/Contents/Developer").path],
            runningPaths: [apps.appendingPathComponent("Menu.app/Contents/XPCServices/Agent.xpc/Contents/MacOS/Agent").path],
            lastUsed: { path in path == bigPath ? self.now.addingTimeInterval(-40 * 86_400) : nil },
            appleSystemSigned: { _ in false },
            legacyLoginItem: { _ in false },
            scanDeadline: Date().addingTimeInterval(30),
            now: now
        )
        let found = RecommendDiscovery.collect(environment: environment)
        let byId = Dictionary(uniqueKeysWithValues: found.map { ($0.bundleId, $0) })
        XCTAssertEqual(Set(byId.keys), ["org.big", "org.menu", "org.real.256stub", "org.outer", "org.ext"])
        XCTAssertEqual(byId["org.big"]?.macAppStore, true)
        XCTAssertEqual(byId["org.big"]?.loginItem, true)
        XCTAssertEqual(byId["org.big"]?.lastUsed, now.addingTimeInterval(-40 * 86_400))
        XCTAssertGreaterThan(byId["org.big"]?.sizeBytes ?? 0, 0)
        XCTAssertEqual(byId["org.menu"]?.menuBarAgent, true)
        XCTAssertEqual(byId["org.menu"]?.loginItem, true)
        XCTAssertEqual(byId["org.menu"]?.backgroundHelperRunning, true)
        XCTAssertEqual(byId["org.real.256stub"]?.stub, true)
        XCTAssertEqual(byId["org.ext"]?.systemExtension, true)
        XCTAssertEqual(byId["org.ext"]?.kernelExtension, true)
        XCTAssertEqual(byId["org.ext"]?.toolchain, true)
        let ranked = RecommendRanking.rank(found, options: RecommendOptions(minSizeBytes: 1, now: now))
        XCTAssertFalse(ranked.recommendations.contains { $0.bundleId == "org.real.256stub" })
        XCTAssertFalse(ranked.recommendations.contains { $0.bundleId == "org.inner" })
        XCTAssertTrue(ranked.warnings.contains { $0.bundleId == "org.ext" && $0.warnings.contains("toolchain") })
    }

    func testEngineUsesInjectedScanAndCatalog() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try makeApp(apps.appendingPathComponent("Pinned.app"), bundleId: "org.pinned", name: "Pinned", extra: [:])
        try makeApp(apps.appendingPathComponent("Free.app"), bundleId: "org.free", name: "Free", extra: [:])
        let repo = root.appendingPathComponent("repo")
        var engine = IsenoughEngine(config: RuntimeConfig(repoPath: repo.path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: apps.path), secrets: MemorySecretStore())
        engine.backendOverride = try LocalFolderBackend(root: repo)
        try engine.initialize()
        let bytes = Data("image".utf8)
        let sha = SHA256Digest.hex(bytes)
        let image = ImageManifest.Image(file: "images/test.dmg", format: "ULMO", sha256: sha, size: UInt64(bytes.count), volumeName: "Pinned", appPathInVolume: "Pinned.app")
        let manifest = ImageManifest(bundleId: "org.pinned", name: "Pinned", version: "1", image: image, app: .init(originalPath: apps.appendingPathComponent("Pinned.app").path, executable: "Pinned", documentTypes: [], urlTypes: []))
        try LocalFolderBackend(root: repo).put("manifests/\(manifest.imageId).json", data: try manifest.encode())
        var state = StateStore(engine.config.stateDir).read()
        var stored = state["apps"] as? [String: [String: Any]] ?? [:]
        stored["org.pinned"] = ["pinned": true, "imageId": manifest.imageId]
        state["apps"] = stored
        try StateStore(engine.config.stateDir).write(state)
        engine.recommendEnvironment = RecommendEnvironment(
            roots: [apps],
            lastUsed: { _ in nil },
            scanDeadline: Date().addingTimeInterval(30),
            now: now
        )
        let report = engine.recommend(options: RecommendOptions(minSizeBytes: 1, now: now))
        XCTAssertEqual(report.scanAvailable, true)
        XCTAssertEqual(report.recommendations.map(\.bundleId), ["org.free"])
        let warned = try XCTUnwrap(report.warnings.first { $0.bundleId == "org.pinned" })
        XCTAssertEqual(warned.warnings, ["pinned", "alreadyPacked"])
        XCTAssertTrue(warned.pinned)
        XCTAssertTrue(warned.packed)
        let response = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/recommend", query: ["limit": "1", "minSize": "1"], headers: [:], body: Data()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual((object["recommendations"] as? [[String: Any]])?.count, 1)
        let bad = ManagementUI.respond(engine: engine, webRoot: nil, request: UIRequest(method: "GET", path: "/api/recommend", query: ["limit": "-3"], headers: [:], body: Data()))
        XCTAssertEqual(bad.status, 400)
    }

    func testLiveScanIsUnavailableWithoutMacOSFacts() {
        #if os(macOS)
        let report = LiveRecommendScan.environment(home: NSHomeDirectory())
        XCTAssertTrue(report.available)
        XCTAssertEqual(report.roots.map(\.path).sorted(), ["/Applications", NSHomeDirectory() + "/Applications"].sorted())
        #else
        let environment = LiveRecommendScan.environment(home: NSHomeDirectory())
        XCTAssertFalse(environment.available)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.path)
        let engine = IsenoughEngine(config: config, secrets: MemorySecretStore())
        let report = engine.recommend(options: RecommendOptions(now: now))
        XCTAssertFalse(report.scanAvailable)
        XCTAssertTrue(report.recommendations.isEmpty)
        #endif
    }

    private func app(name: String, bundleId: String, size: UInt64, lastUsed: Date? = nil, macAppStore: Bool = false, pinned: Bool = false, packed: Bool = false, running: Bool = false, stub: Bool = false, isenoughProduct: Bool = false, systemLocation: Bool = false, appleSystemSigned: Bool = false, loginItem: Bool = false, menuBarAgent: Bool = false, backgroundHelperRunning: Bool = false, systemExtension: Bool = false, kernelExtension: Bool = false, toolchain: Bool = false, sizeIncomplete: Bool = false) -> RecommendApp {
        RecommendApp(path: "/Applications/\(name).app", name: name, bundleId: bundleId, sizeBytes: size, sizeIncomplete: sizeIncomplete, lastUsed: lastUsed, macAppStore: macAppStore, pinned: pinned, packed: packed, running: running, stub: stub, isenoughProduct: isenoughProduct, systemLocation: systemLocation, appleSystemSigned: appleSystemSigned, loginItem: loginItem, menuBarAgent: menuBarAgent, backgroundHelperRunning: backgroundHelperRunning, systemExtension: systemExtension, kernelExtension: kernelExtension, toolchain: toolchain)
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-recommend-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeApp(_ url: URL, bundleId: String, name: String, executable: String? = nil, extra: [String: Any]) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var plist = extra
        plist["CFBundleIdentifier"] = bundleId
        plist["CFBundleName"] = name
        plist["CFBundleExecutable"] = executable ?? name
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("bin".utf8).write(to: macOS.appendingPathComponent(executable ?? name))
    }
}
