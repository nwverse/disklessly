import Foundation
import IsenoughCore

public struct RuntimeConfig: Codable {
    public var schema = "config/1"
    public var backend = "local"
    public var repoPath: String
    public var cacheDir: String
    public var stateDir: String
    public var mountRoot: String
    public var stubDir: String
    public var quotaBytes: UInt64 = 20 * 1024 * 1024 * 1024
    public var minFreeBytes: UInt64 = 15 * 1024 * 1024 * 1024
    public var detachDelaySeconds: UInt64 = 120
    public var backends: [BackendEndpoint] = []
    public var activeBackendId: String?
    /// codesign identity. `-` is ad-hoc. `ISENOUGH_SIGN_IDENTITY` overrides this at pack time.
    public var signIdentity: String = "-"
    /// Files untouched for this many days are cold-tier candidates. The 24 hour guard still applies.
    public var sessionColdDays: Int = 14
    /// Extra session roots. When empty, the built-in pi, Claude Code, and Codex roots are used.
    public var sessionRoots: [SessionRoot] = []
    /// Home used to build the built-in session roots. Overrides `$HOME` when set. `--home` overrides this.
    public var sessionHome: String? = nil
    public init(repoPath: String, cacheDir: String, stateDir: String, mountRoot: String, stubDir: String) { self.repoPath=repoPath; self.cacheDir=cacheDir; self.stateDir=stateDir; self.mountRoot=mountRoot; self.stubDir=stubDir }

    private enum CodingKeys: String, CodingKey {
        case schema, backend, repoPath, cacheDir, stateDir, mountRoot, stubDir, quotaBytes, minFreeBytes, detachDelaySeconds, backends, activeBackendId, signIdentity, sessionColdDays, sessionRoots, sessionHome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? "config/1"
        backend = try container.decodeIfPresent(String.self, forKey: .backend) ?? "local"
        repoPath = try container.decode(String.self, forKey: .repoPath)
        cacheDir = try container.decode(String.self, forKey: .cacheDir)
        stateDir = try container.decode(String.self, forKey: .stateDir)
        mountRoot = try container.decode(String.self, forKey: .mountRoot)
        stubDir = try container.decode(String.self, forKey: .stubDir)
        quotaBytes = try container.decodeIfPresent(UInt64.self, forKey: .quotaBytes) ?? 20 * 1024 * 1024 * 1024
        minFreeBytes = try container.decodeIfPresent(UInt64.self, forKey: .minFreeBytes) ?? 15 * 1024 * 1024 * 1024
        detachDelaySeconds = try container.decodeIfPresent(UInt64.self, forKey: .detachDelaySeconds) ?? 120
        backends = try container.decodeIfPresent([BackendEndpoint].self, forKey: .backends) ?? []
        activeBackendId = try container.decodeIfPresent(String.self, forKey: .activeBackendId)
        signIdentity = try container.decodeIfPresent(String.self, forKey: .signIdentity) ?? "-"
        sessionColdDays = try container.decodeIfPresent(Int.self, forKey: .sessionColdDays) ?? 14
        sessionRoots = try container.decodeIfPresent([SessionRoot].self, forKey: .sessionRoots) ?? []
        sessionHome = try container.decodeIfPresent(String.self, forKey: .sessionHome)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(backend, forKey: .backend)
        try container.encode(repoPath, forKey: .repoPath)
        try container.encode(cacheDir, forKey: .cacheDir)
        try container.encode(stateDir, forKey: .stateDir)
        try container.encode(mountRoot, forKey: .mountRoot)
        try container.encode(stubDir, forKey: .stubDir)
        try container.encode(quotaBytes, forKey: .quotaBytes)
        try container.encode(minFreeBytes, forKey: .minFreeBytes)
        try container.encode(detachDelaySeconds, forKey: .detachDelaySeconds)
        try container.encode(backends, forKey: .backends)
        try container.encodeIfPresent(activeBackendId, forKey: .activeBackendId)
        try container.encode(signIdentity, forKey: .signIdentity)
        try container.encode(sessionColdDays, forKey: .sessionColdDays)
        try container.encode(sessionRoots, forKey: .sessionRoots)
        try container.encodeIfPresent(sessionHome, forKey: .sessionHome)
    }

    public static func environment(_ env: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> RuntimeConfig {
        func v(_ key: String, _ fallback: String) -> String { env["ISENOUGH_\(key)"] ?? fallback }
        var config = RuntimeConfig(repoPath: v("REPO_PATH", "\(home)/Library/Mobile Documents/com~apple~CloudDocs/256isenough"), cacheDir: v("CACHE_DIR", "\(home)/Library/Caches/256isenough"), stateDir: v("STATE_DIR", "\(home)/Library/Application Support/256isenough"), mountRoot: v("MOUNT_ROOT", "\(home)/Library/Caches/256isenough/mnt"), stubDir: v("STUB_DIR", "/Applications"))
        if let quota = env["ISENOUGH_QUOTA_BYTES"].flatMap(UInt64.init) { config.quotaBytes = quota }
        if let floor = env["ISENOUGH_MIN_FREE_BYTES"].flatMap(UInt64.init) { config.minFreeBytes = floor }
        if let identity = env["ISENOUGH_SIGN_IDENTITY"], !identity.isEmpty { config.signIdentity = identity }
        return config
    }

    /// `--config` replaces the file outright. Otherwise `<stateDir>/config.json` is
    /// loaded and explicit `ISENOUGH_*` path overrides are applied on top. `backend`
    /// stays as stored, so `init --backend icloud` is what `status` reports.
    public static func resolved(environment env: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(), stateDirOverride: String?, explicitConfig: String?) -> RuntimeConfig {
        var config = environment(env, home: home)
        if let stateDirOverride { config.stateDir = stateDirOverride }
        if let explicitConfig {
            let url = URL(fileURLWithPath: explicitConfig)
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(RuntimeConfig.self, from: data) {
                config = saved
            }
            if let stateDirOverride { config.stateDir = stateDirOverride }
            return config
        }
        let savedURL = URL(fileURLWithPath: config.stateDir).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: savedURL), let saved = try? JSONDecoder().decode(RuntimeConfig.self, from: data) else {
            return config
        }
        var merged = saved
        if env["ISENOUGH_REPO_PATH"] != nil { merged.repoPath = config.repoPath }
        if env["ISENOUGH_CACHE_DIR"] != nil { merged.cacheDir = config.cacheDir }
        if env["ISENOUGH_STATE_DIR"] != nil || stateDirOverride != nil { merged.stateDir = config.stateDir }
        if env["ISENOUGH_MOUNT_ROOT"] != nil { merged.mountRoot = config.mountRoot }
        if env["ISENOUGH_STUB_DIR"] != nil { merged.stubDir = config.stubDir }
        if env["ISENOUGH_QUOTA_BYTES"] != nil { merged.quotaBytes = config.quotaBytes }
        if env["ISENOUGH_MIN_FREE_BYTES"] != nil { merged.minFreeBytes = config.minFreeBytes }
        if let identity = env["ISENOUGH_SIGN_IDENTITY"], !identity.isEmpty { merged.signIdentity = identity }
        if let stateDirOverride { merged.stateDir = stateDirOverride }
        return merged
    }

    public mutating func remember(_ endpoint: BackendEndpoint) {
        backends.removeAll { $0.id == endpoint.id }
        backends.append(endpoint)
        activeBackendId = endpoint.id
        backend = endpoint.type
        if let mount = endpoint.mountPoint { repoPath = mount }
    }
}

public enum Hashing {
    public static func sha256(_ url: URL) throws -> String {
        try SHA256Digest.hexFile(url)
    }
}

public enum StubGenerator {
    public static func infoPlist(source: [String:Any], appId: String, executable: String = "isenough-stub") -> [String:Any] {
        var p=source; p["CFBundleIdentifier"]="\(appId).256stub"; p["CFBundleExecutable"]=executable; p["LSUIElement"]=true
        for key in ["SUFeedURL","SUPublicEDKey","ElectronDefaultApp"] { p.removeValue(forKey:key) }
        return p
    }
    public static func stubInfo(manifest: ImageManifest, cliPath: String) -> [String:Any] {
        ["schema":"stub/1", "appId":manifest.bundleId, "imageId":manifest.imageId, "isenoughPath":cliPath, "engineVersion":EngineInstall.version, "engineRevision":EngineInstall.revision, "stubVersion":1]
    }

    public static func locateLauncher(cliExecutable: URL, environment: [String:String], isExecutable: (String)->Bool) throws -> URL {
        let cli=cliExecutable.resolvingSymlinksInPath().standardizedFileURL
        if let override=environment["ISENOUGH_STUB_BINARY"] {
            guard isExecutable(override) else { throw IsenoughError.usage("ISENOUGH_STUB_BINARY is not executable: \(override)") }
            let found=URL(fileURLWithPath:override).resolvingSymlinksInPath().standardizedFileURL
            guard found.path != cli.path else { throw IsenoughError.failure("Refusing to use CLI as isenough-stub launcher") }
            return found
        }
        let sibling=cli.deletingLastPathComponent().appendingPathComponent("isenough-stub").path
        guard isExecutable(sibling) else { throw IsenoughError.failure("isenough-stub launcher binary not found next to \(cli.path)") }
        let found=URL(fileURLWithPath:sibling).resolvingSymlinksInPath().standardizedFileURL
        guard found.path != cli.path else { throw IsenoughError.failure("Refusing to use CLI as isenough-stub launcher") }
        return found
    }

    /// Compare filesystem paths lexically after collapsing redundant separators and dot components.
    /// URL equality is stricter than filesystem path equivalence (notably for `//`).
    public static func pathsReferToSameLocation(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).standardizingPath == (rhs as NSString).standardizingPath
    }
}

public struct IsenoughEngine {
    public var config: RuntimeConfig
    public var services: RestoreServices
    public let faults: FaultController
    public let restore: RestoreCoordinator
    public var secrets: any SecretStore
    public var shareOpener: ShareOpener
    public var backendOverride: (any StorageBackend)?
    /// Replaces the live `/Applications` scan. Tests inject roots and Spotlight dates.
    /// Production leaves it nil, which uses the macOS probes.
    public var recommendEnvironment: RecommendEnvironment?
    /// Tests inject hostname, architecture, and OS version. Nil uses the live Mac facts.
    public var deviceFactsOverride: DeviceFacts?
    /// Replaces `FileManager.fileExists` for the repository path. Tests use this to
    /// prove a stuck probe cannot block `doctor`. Production leaves it nil.
    var doctorRepositoryProbe: ((String) -> Bool)?
    /// Replaces the iCloud materialization probe. Tests pass file facts directly.
    public var materialFilesOverride: [MaterialFile]?
    /// Replaces `FileManager.evictUbiquitousItem`. Nil uses the macOS API.
    public var ubiquityEvictor: ((MaterialFile) -> UbiquityEvictOutcome)?
    /// Replaces the Applications scan for `cleanup-backups`.
    public var backupFactsOverride: [BackupFact]?
    /// Replaces `/Applications`, `~/Applications`, and `stubDir` when backfilling this Mac's device file.
    /// Nil uses those folders. An empty array scans nowhere.
    public var stubRootsOverride: [URL]?
    public init(config: RuntimeConfig, services: RestoreServices? = nil, faults: FaultController? = nil, secrets: (any SecretStore)? = nil, shareOpener: ShareOpener = .system) {
        self.config=config
        let faults=faults ?? FaultController()
        self.faults=faults
        let services=services ?? RestoreServices.live(config: config)
        self.services=services
        self.restore=RestoreCoordinator(config: config, services: services, faults: faults)
        self.secrets = secrets ?? KeychainSecretStore()
        self.shareOpener = shareOpener
        self.backendOverride = nil
        self.recommendEnvironment = nil
        self.deviceFactsOverride = nil
        self.materialFilesOverride = nil
        self.ubiquityEvictor = nil
        self.backupFactsOverride = nil
        self.stubRootsOverride = nil
    }
    public func openBackend() throws -> any StorageBackend {
        if let backendOverride { return backendOverride }
        if let id = config.activeBackendId, let endpoint = config.backends.first(where: { $0.id == id }) {
            return try BackendFactory.open(endpoint, secrets: secrets, opener: shareOpener)
        }
        let root = URL(fileURLWithPath: config.repoPath)
        if ICloudFolderBackend.looksLikeICloud(root) {
            return try ICloudFolderBackend(root: root)
        }
        return try LocalFolderBackend(root: root)
    }
    public var repo: any StorageBackend { get throws { try openBackend() } }
    public func saveConfig() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cfg = try encoder.encode(config)
        try FileManager.default.createDirectory(atPath: config.stateDir, withIntermediateDirectories: true)
        try cfg.write(to: URL(fileURLWithPath: config.stateDir).appendingPathComponent("config.json"), options: .atomic)
    }
    public func initialize() throws {
        let fm = FileManager.default
        for p in [config.cacheDir, config.stateDir, config.mountRoot, config.stubDir] { try fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
        let backend = try repo
        if let root = backend.localRoot() {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        if try backend.stat("repo.json") == nil {
            try backend.put("repo.json", data: Data("{\"schema\":\"repo/1\",\"repoId\":\"\(UUID().uuidString)\",\"layoutVersion\":1}".utf8))
        }
        for p in ["images", "manifests", "catalog", "devices", "trash"] { try backend.ensureCollection(p) }
        try saveConfig()
        if EngineInstall.runningExecutable().lastPathComponent == "isenough" {
            try installEngine()
        }
    }

    /// Copy the running `isenough` to `<stateDir>/bin/isenough` and refresh the stamp.
    /// Unit tests run under an xctest host, which is not an engine, so callers that
    /// always want a copy pass `source`.
    @discardableResult
    public func installEngine(source: URL? = nil) throws -> URL {
        let binary = source ?? EngineInstall.runningExecutable()
        return try EngineInstall.install(stateDir: config.stateDir, source: binary)
    }

    /// Path written into new stubs. Prefers the stable copy once it exists.
    public func installedEnginePath() throws -> String {
        if EngineInstall.runningExecutable().lastPathComponent == "isenough" {
            try installEngine()
        }
        let binary = EngineInstall.binary(stateDir: config.stateDir)
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary.path }
        return EngineInstall.runningExecutable().path
    }

    /// Rewrite `stub.json` in installed stubs so `isenoughPath` is the stable engine, then re-sign on macOS.
    public func refreshStubs(appId: String) throws -> [String] {
        let enginePath = try installedEnginePath()
        let bundles = locatedStubs(matching: appId)
        guard !bundles.isEmpty else { throw IsenoughError.usage("no installed stub for \(appId)") }
        var updated: [String] = []
        for bundle in bundles {
            try rewriteStubEngine(bundle: bundle, enginePath: enginePath)
            updated.append(bundle.path)
        }
        return updated
    }

    /// Warnings for `doctor`. A missing or older engine does not fail the command.
    public func engineWarnings() -> [String] {
        let fm = FileManager.default
        var lines: [String] = []
        let installed = EngineInstall.binary(stateDir: config.stateDir).path
        switch EngineInstall.freshness(at: installed) {
        case .current:
            break
        case .missing:
            lines.append("installed engine is missing at \(installed); run isenough install-engine")
        case .older(let detail):
            lines.append("\(detail); run isenough install-engine")
        }
        guard case .missing = EngineInstall.freshness(at: installed) else { return lines }
        for bundle in locatedStubs(matching: nil) {
            let stubJSON = bundle.appendingPathComponent("Contents/Resources/stub.json")
            guard let data = try? Data(contentsOf: stubJSON),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recorded = object["isenoughPath"] as? String,
                  !StubGenerator.pathsReferToSameLocation(recorded, installed) else { continue }
            let app = object["appId"] as? String ?? bundle.deletingPathExtension().lastPathComponent
            switch EngineInstall.freshness(at: recorded, fileManager: fm) {
            case .current:
                break
            case .missing:
                lines.append("stub \(bundle.path) engine is missing at \(recorded); run isenough stub refresh --app \(app)")
            case .older(let detail):
                lines.append("stub \(bundle.path) \(detail); run isenough stub refresh --app \(app)")
            }
        }
        return lines
    }

    private func locatedStubs(matching appId: String?) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        func consider(_ url: URL) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            let stubJSON = url.appendingPathComponent("Contents/Resources/stub.json")
            guard let data = try? Data(contentsOf: stubJSON),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let appId {
                let id = object["appId"] as? String ?? ""
                let image = object["imageId"] as? String ?? ""
                let info = (try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))).flatMap {
                    try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
                }
                let bundle = info?["CFBundleIdentifier"] as? String ?? ""
                let names = [id, image, bundle, id + ".256stub"]
                guard names.contains(appId) || id.caseInsensitiveCompare(appId) == .orderedSame else { return }
            }
            if !urls.contains(where: { StubGenerator.pathsReferToSameLocation($0.path, url.path) }) {
                urls.append(url)
            }
        }
        if let manifests = try? list() {
            for manifest in manifests {
                let wanted = appId == nil || manifest.bundleId == appId || manifest.imageId == appId || manifest.name.caseInsensitiveCompare(appId ?? "") == .orderedSame
                if wanted { consider(URL(fileURLWithPath: manifest.app.originalPath)) }
            }
        }
        let stubDir = URL(fileURLWithPath: config.stubDir)
        if let names = try? fm.contentsOfDirectory(atPath: stubDir.path) {
            for name in names where name.hasSuffix(".app") {
                consider(stubDir.appendingPathComponent(name))
            }
        }
        return urls
    }

    private func rewriteStubEngine(bundle: URL, enginePath: String) throws {
        let stubJSON = bundle.appendingPathComponent("Contents/Resources/stub.json")
        let data = try Data(contentsOf: stubJSON)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IsenoughError.failure("stub.json in \(bundle.path) is not an object")
        }
        object["isenoughPath"] = enginePath
        object["engineVersion"] = EngineInstall.version
        object["engineRevision"] = EngineInstall.revision
        if object["schema"] == nil { object["schema"] = "stub/1" }
        if object["stubVersion"] == nil { object["stubVersion"] = 1 }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: stubJSON, options: .atomic)
        #if os(macOS)
        let identity = SigningIdentity.resolve(configured: config.signIdentity, environment: ProcessInfo.processInfo.environment)
        try ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", identity, bundle.path])
        #endif
    }

    public func pack(_ appPath: String, mode: ImageManifest.Mode? = nil, keepOriginal: Bool = false, noStub: Bool = false) throws -> PublishResult {
        #if !os(macOS)
        throw IsenoughError.unsupported("pack requires macOS hdiutil and codesign")
        #else
        let app=URL(fileURLWithPath:appPath).standardizedFileURL, plistURL=app.appendingPathComponent("Contents/Info.plist")
        guard let info=NSDictionary(contentsOf:plistURL) as? [String:Any], let bid=info["CFBundleIdentifier"] as? String else { throw IsenoughError.usage("Not a valid .app bundle") }
        let name=info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent, version=info["CFBundleShortVersionString"] as? String ?? "0"
        let selected=mode ?? ((FileManager.default.fileExists(atPath:app.appendingPathComponent("Contents/_MASReceipt/receipt").path) ? .restore : .mount))
        let staging=URL(fileURLWithPath:config.cacheDir).appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:staging.appendingPathComponent("src"),withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:staging) }
        let stagedApp=staging.appendingPathComponent("src").appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto",[app.path,stagedApp.path])
        BundleHasher.removeMetadataSidecars(stagedApp)
        let executableName = info["CFBundleExecutable"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? "0"
        _ = try MASReceiptStore.preserve(from: stagedApp, bundleId: bid, stateDir: URL(fileURLWithPath: config.stateDir))
        BundleHasher.removeMachineReceipt(stagedApp)
        let contentHash = try BundleHasher.treeHash(of: stagedApp)
        let architectures = MachArchitectures.slices(at: stagedApp.appendingPathComponent("Contents/MacOS/\(executableName)"))
        let identity = ImageIdentity(bundleId: bid, version: version, build: build, architectures: architectures.isEmpty ? ["unknown"] : architectures, treeHash: contentHash)
        let backend = try repo
        let decision = PublishPlanner.decide(identity: identity, manifests: try readManifests(backend)) { path in
            (try? WriteOnce.probe(backend, path)) ?? .absent
        }
        if case .reuse(let existing) = decision {
            try register(existing, backend: backend, now: Date())
            if EngineInstall.runningExecutable().lastPathComponent == "isenough" { try installEngine() }
            let stubWarning = noStub ? nil : try installStub(info: info, manifest: existing, path: app.path, keepOriginal: keepOriginal)
            return finishPublished(PublishResult(manifest: existing, reused: true, uploaded: false), stubWarning: stubWarning)
        }
        if case .refuse(let message) = decision { throw IsenoughError.integrity(message) }
        let dmg=staging.appendingPathComponent("image.dmg")
        try run("/usr/bin/hdiutil",["create","-quiet","-srcfolder",staging.appendingPathComponent("src").path,"-format","ULMO","-volname",name,"-o",dmg.deletingPathExtension().path])
        // Hash the ditto restore will verify, not the pre-image staged app. hdiutil
        // can change modes and materialize AppleDouble files; the manifest has to
        // describe that tree. The content hash above is what other Macs compare.
        let mount=staging.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at:mount,withIntermediateDirectories:true)
        try LiveDiskImage.attach(image: dmg, mountPoint: mount)
        var detachedPackMount=false
        defer { if !detachedPackMount { try? LiveDiskImage.detach(mountPoint: mount, force: true) } }
        let checked=staging.appendingPathComponent("checked-\(app.lastPathComponent)")
        try run("/usr/bin/ditto",[mount.appendingPathComponent(app.lastPathComponent).path,checked.path])
        BundleHasher.removeMetadataSidecars(checked)
        BundleHasher.removeMachineReceipt(checked)
        let treeHash=try BundleHasher.treeHash(of: checked)
        let cdhash=try BundleHasher.cdhash(of: checked)
        try LiveDiskImage.detach(mountPoint: mount, force: false)
        detachedPackMount=true
        let docs = (info["CFBundleDocumentTypes"] as? [[String:Any]] ?? []).map { $0.mapValues(AnyCodable.init) }
        let urls = (info["CFBundleURLTypes"] as? [[String:Any]] ?? []).map { $0.mapValues(AnyCodable.init) }
        let request = PublishRequest(name: name, identity: identity, mode: selected, executable: executableName, originalPath: app.path, cdhash: cdhash, postImageTreeHash: treeHash, volumeName: name, appPathInVolume: app.lastPathComponent, documentTypes: docs, urlTypes: urls)
        let published = try publish(request, imageFile: dmg)
        if EngineInstall.runningExecutable().lastPathComponent == "isenough" { try installEngine() }
        let stubWarning = noStub ? nil : try installStub(info: info, manifest: published.manifest, path: app.path, keepOriginal: keepOriginal)
        return finishPublished(published, stubWarning: stubWarning)
        #endif
    }
    #if os(macOS)
    private func installStub(info:[String:Any],manifest:ImageManifest,path:String,keepOriginal:Bool) throws -> String? {
        let source=URL(fileURLWithPath:path).standardizedFileURL
        let dest=URL(fileURLWithPath:config.stubDir).standardizedFileURL.appendingPathComponent(source.lastPathComponent)
        let temp=dest.deletingLastPathComponent().appendingPathComponent(".isenough-\(UUID().uuidString).app")
        let backup=dest.deletingLastPathComponent().appendingPathComponent(".isenough-original-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        let plistPath=temp.appendingPathComponent("Contents/Info.plist")
        guard (StubGenerator.infoPlist(source:info,appId:manifest.bundleId) as NSDictionary).write(to:plistPath,atomically:true) else {
            throw IsenoughError.failure("Could not write generated stub Info.plist at \(plistPath.path)")
        }
        let cli=Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0])
        let launcher=try StubGenerator.locateLauncher(cliExecutable:cli,environment:ProcessInfo.processInfo.environment,isExecutable:{ FileManager.default.isExecutableFile(atPath:$0) })
        let stubExecutable=temp.appendingPathComponent("Contents/MacOS/isenough-stub")
        try FileManager.default.copyItem(at:launcher,to:stubExecutable)
        if FileManager.default.contentsEqual(atPath: stubExecutable.path, andPath: cli.path) {
            throw IsenoughError.failure("Refusing to install CLI binary as isenough-stub launcher")
        }
        try manifest.encode().write(to:temp.appendingPathComponent("Contents/Resources/manifest.json"))
        let enginePath = try installedEnginePath()
        try JSONSerialization.data(withJSONObject:StubGenerator.stubInfo(manifest:manifest,cliPath:enginePath),options:[.prettyPrinted,.sortedKeys]).write(to:temp.appendingPathComponent("Contents/Resources/stub.json"))
        // Signing the bundle re-signs its main executable isenough-stub in place.
        // No --deep is needed because there are no nested code items.
        let identity = SigningIdentity.resolve(configured: config.signIdentity, environment: ProcessInfo.processInfo.environment)
        try run("/usr/bin/codesign",["--force","--sign",identity,temp.path])
        try run("/usr/bin/codesign",["--verify","--strict",temp.path])
        guard StubGenerator.pathsReferToSameLocation(source.path, dest.path) else { throw IsenoughError.unsupported("Stub must replace the app at its original path (source: \(source.path), destination: \(dest.path))") }
        do {
            try FileManager.default.moveItem(at:source,to:backup)
        } catch {
            throw IsenoughError.failure("Could not move original app to transaction backup \(backup.path): \(error.localizedDescription)")
        }
        do {
            try FileManager.default.moveItem(at:temp,to:dest)
        } catch {
            try? FileManager.default.moveItem(at:backup,to:source)
            throw IsenoughError.failure("Could not install signed stub at \(dest.path): \(error.localizedDescription)")
        }
        if keepOriginal {
            let retained=dest.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent+".256orig.app")
            do { try FileManager.default.moveItem(at:backup,to:retained) }
            catch {
                try? FileManager.default.removeItem(at:dest)
                try? FileManager.default.moveItem(at:backup,to:source)
                throw IsenoughError.failure("Could not retain original app at \(retained.path): \(error.localizedDescription)")
            }
        } else {
            do { try FileManager.default.removeItem(at: backup) }
            catch { return BackupRemoval.warning(backupPath: backup.path) }
        }
        return nil
    }
    #endif
    public func list() throws -> [ImageManifest] {
        try ensureDevice()
        return try readManifests(try repo)
    }
    public func status() -> [String:Any] {
        let state=StateStore(config.stateDir).load().dictionary()
        return ["backend":config.backend,"activeBackendId":config.activeBackendId ?? "","repoPath":config.repoPath,"cacheDir":config.cacheDir,"quotaBytes":NSNumber(value: config.quotaBytes),"minFreeBytes":NSNumber(value: config.minFreeBytes),"detachDelaySeconds":NSNumber(value: config.detachDelaySeconds),"apps":state["apps"] ?? [:],"cache":state["cache"] ?? [:],"restored":state["restored"] ?? [:]]
    }
    public func manifest(named name: String, in manifests: [ImageManifest]) -> ImageManifest? {
        if let exact=manifests.first(where: { $0.imageId == name }) { return exact }
        let apps=StateStore(config.stateDir).load().apps
        if let imageId=apps[name]?.imageId, let pinned=manifests.first(where: { $0.imageId == imageId }) { return pinned }
        if let record = try? ownDeviceRecord(), let imageId = record.currentImage(bundleId: name)?.imageId ?? record.images.first(where: { $0.bundleId.caseInsensitiveCompare(name) == .orderedSame })?.imageId, let recorded = manifests.first(where: { $0.imageId == imageId }) { return recorded }
        let matches = manifests.filter { $0.bundleId == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }
    public func setPinned(_ manifest: ImageManifest, pinned: Bool) throws {
        try StateStore(config.stateDir).update { state in
            var item = state.apps[manifest.bundleId] ?? AppState()
            item.imageId = manifest.imageId
            item.pinned = pinned
            state.apps[manifest.bundleId] = item
        }
        if pinned { _ = try prefetch(manifest) }
    }
    public func evict(_ manifest: ImageManifest) throws {
        if let reason=restore.blockReason(appId: manifest.bundleId) { throw IsenoughError.busy(reason) }
        let path=URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    public func gc(now: Date = Date(), includeLegacy: Bool = false) throws -> [String] {
        try maintain(now: now, includeLegacy: includeLegacy).lines
    }
    /// Each check is bounded. `onCheck` runs on the caller as soon as that check finishes,
    /// so a stuck iCloud `fileExists` cannot hide every later result.
    public func doctor(checkTimeout: TimeInterval = DoctorLimits.timeout(), fix: Bool = false, onCheck: (([String: Any]) -> Void)? = nil) -> [String: Any] {
        Doctor.run(engine: self, checkTimeout: checkTimeout, fix: fix, onCheck: onCheck)
    }

    /// Rank installed apps worth offloading. The scan is read-only. On Linux the
    /// live scan is unavailable unless `recommendEnvironment` injects facts.
    public func recommend(options: RecommendOptions) -> RecommendReport {
        let environment = recommendEnvironment ?? LiveRecommendScan.environment(home: NSHomeDirectory(), now: options.now)
        var ranked = options
        ranked.repoImages = repoImagePresences()
        guard environment.available else {
            return RecommendRanking.rank([], options: ranked, scanAvailable: false)
        }
        let apps = RecommendDiscovery.collect(environment: environment, catalog: recommendCatalog())
        var report = RecommendRanking.rank(apps, options: ranked, scanAvailable: true)
        report.leftovers = RecommendDiscovery.leftovers(environment: environment)
        return report
    }

    private func recommendCatalog() -> RecommendCatalog {
        let manifests = (try? list()) ?? []
        let stored = StateStore(config.stateDir).load().apps
        var pinned = Set<String>()
        for (bundleId, item) in stored where item.pinned {
            pinned.insert(bundleId)
        }
        return RecommendCatalog(pinnedBundleIds: pinned, packedBundleIds: Set(manifests.map(\.bundleId)), packedPaths: Set(manifests.map(\.app.originalPath)))
    }
    public func resolve(_ manifest: ImageManifest, keepUpdated: Bool, trust: Bool, export: String?, discard: Bool) throws {
        guard let record=restore.needsResolution(manifest.bundleId), let path=record["retainedPath"] as? String, let tree=record["treeHash"] as? String else {
            throw IsenoughError.usage("no retained bundle to resolve for \(manifest.bundleId)")
        }
        let url=URL(fileURLWithPath: path)
        let actual=try restore.services.treeHash(url)
        guard actual == tree else { throw IsenoughError.integrity("retained bundle tree hash does not match the resolution record") }
        if keepUpdated {
            guard restore.services.signatureValid(url) else { throw IsenoughError.integrity("retained bundle has an invalid code signature; export or discard it") }
            let cdhash=try restore.services.cdhash(url)
            if cdhash != manifest.app.cdhash && !trust { throw IsenoughError.usage("updated bundle cdhash differs from the packed image; pass --trust to approve it") }
            #if os(macOS)
            let packed=try pack(path, mode: manifest.mode, keepOriginal: true, noStub: true)
            try restore.switchImage(appId: manifest.bundleId, imageId: packed.manifest.imageId, cdhash: cdhash)
            try restore.trash(url)
            try restore.clearResolution(appId: manifest.bundleId)
            return
            #else
            throw IsenoughError.unsupported("resolve --keep-updated packs a new image and requires macOS")
            #endif
        }
        if let export {
            try restore.export(url, to: URL(fileURLWithPath: export))
        } else if discard {
            try restore.trash(url)
        } else {
            throw IsenoughError.usage("resolve requires --discard, --export, or --keep-updated")
        }
        try restore.clearResolution(appId: manifest.bundleId)
    }
    public func watch(appId: String) throws {
        restore.loadConfiguredFaults()
        try restore.watch(appId: appId)
    }
    public func prefetch(_ manifest:ImageManifest) throws -> URL {
        let backend = try repo
        let paths = CachePaths(cacheDir: config.cacheDir, mountRoot: config.mountRoot)
        let cache = paths.image(manifest.imageId)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: cache.path), (try? SHA256Digest.hexFile(cache)) == manifest.image.sha256 { return cache }
        let free = try VolumeSpace.availableBytes(at: config.cacheDir)
        guard SpaceFloor.admits(freeBytes: free, incoming: manifest.image.size, floor: config.minFreeBytes) else {
            throw IsenoughError.noSpace("free space \(free) bytes would fall below the \(config.minFreeBytes) byte floor after fetching \(manifest.image.size) bytes")
        }
        // Keep the fetched image byte-for-byte identical to the published artifact.
        // The manifest hashes the remote ULMO image; converting it on download both
        // invalidates that identity and relies on hdiutil's output-name conventions.
        try CacheFetcher.materialize(backend: backend, remote: manifest.image.file, destination: cache, partial: paths.partial(manifest.imageId), expectedSize: manifest.image.size, expectedSHA256: manifest.image.sha256)
        return cache
    }
    public func launch(_ manifest:ImageManifest, documents:[String]=[], urls:[String]=[], arguments:[String]=[], wait:Bool=true) throws {
        try assertDeviceLaunch(manifest)
        restore.loadConfiguredFaults()
        if EngineInstall.runningExecutable().lastPathComponent == "isenough" {
            try installEngine()
        }
        if manifest.mode == .restore {
            _ = try prefetch(manifest)
            try restore.launch(manifest, documents: documents, urls: urls, arguments: arguments, wait: wait)
            return
        }
        let image=try prefetch(manifest)
        #if !os(macOS)
        throw IsenoughError.unsupported("launch requires macOS hdiutil and Launch Services")
        #else
        let rawMount=URL(fileURLWithPath:config.mountRoot).appendingPathComponent(manifest.imageId)
        try FileManager.default.createDirectory(at:rawMount,withIntermediateDirectories:true)
        let mount=rawMount.resolvingSymlinksInPath().standardizedFileURL
        try LiveDiskImage.attach(image: image, mountPoint: mount)
        let state=StateStore(config.stateDir)
        try state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"running",mountPoint:mount.path)
        let app=mount.appendingPathComponent(manifest.image.appPathInVolume)
        var args=["-n","-a",app.path]; args += documents; args += urls
        if !arguments.isEmpty { args.append("--args"); args += arguments }
        try run("/usr/bin/open",args)
        if wait {
            while true {
                Thread.sleep(forTimeInterval:0.5)
                let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/pgrep"); p.arguments=["-f",app.appendingPathComponent("Contents/MacOS/"+manifest.app.executable).path]
                try? p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { break }
            }
            Thread.sleep(forTimeInterval:Double(config.detachDelaySeconds))
            try state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"detaching",mountPoint:mount.path)
            do {
                try LiveDiskImage.detach(mountPoint: mount, force: false)
                try state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"cached")
            } catch {
                try? state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"backoff",mountPoint:mount.path)
                FileHandle.standardError.write(Data("isenough: detach failed: \(error)\n".utf8))
                throw error
            }
        }
        #endif
    }
    #if os(macOS)
    private func run(_ path:String,_ args:[String]) throws {
        let p=ParsedCommand.process(path:path, arguments:args)
        let output=Pipe(); p.standardOutput=output; p.standardError=output
        do { try p.run() } catch {
            throw IsenoughError.failure("Could not start \(path) \(args.joined(separator:" ")): \(error.localizedDescription)")
        }
        let data=output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus==0 else {
            // The tool's own sentence is recorded and not interpreted. hdiutil follows
            // AppleLanguages, so the words are not a stable classifier.
            let detail=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            throw IsenoughError.diskImage("Command failed: \(path) \(args.joined(separator:" ")) (exit \(p.terminationStatus))\(detail.isEmpty ? "" : "\n\(detail)")")
        }
    }
    #endif
}
