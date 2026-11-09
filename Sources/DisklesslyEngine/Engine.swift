import Foundation
import DisklesslyCore
import DisklesslyStubSupport
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
    /// Image format used when `pack --mode restore` does not pass `--image-format`.
    public var restoreImageFormat: String = "ULMO"
    public var backends: [BackendEndpoint] = []
    public var activeBackendId: String?
    /// Extra copies of the repo (`backends` ids, or `default` for the folder at `repoPath`).
    /// Reads fail over to them; `repo mirror sync` fills them. Never holds the active repo.
    public var mirrorBackendIds: [String] = []
    /// codesign identity. `-` is ad-hoc. `DISKLESSLY_SIGN_IDENTITY` overrides this at pack time.
    public var signIdentity: String = "-"
    /// Files untouched for this many days are cold-tier candidates. The 24 hour guard still applies.
    public var sessionColdDays: Int = 14
    /// Session roots. When empty, the built-in agent roots (`SessionRoot.defaults`) are used.
    public var sessionRoots: [SessionRoot] = []
    /// Home used to build the built-in session roots. Overrides `$HOME` when set. `--home` overrides this.
    public var sessionHome: String? = nil
    public var sessionSegmentMaxBytes: UInt64 = 64 * 1024 * 1024
    public var sessionSoloBytes: UInt64 = 8 * 1024 * 1024
    public var sessionMaxFileBytes: UInt64 = 512 * 1024 * 1024
    /// `off` or `aes-gcm`. Schema stays `config/1`.
    public var sessionEncryption: String = "off"
    /// `off` or `aes-gcm`: whether `pack` encrypts new images before upload (`ImageCrypto`).
    /// `pack --encrypt` / `--no-encrypt` and `DISKLESSLY_IMAGE_ENCRYPTION` override it.
    public var imageEncryption: String = "off"
    public init(repoPath: String, cacheDir: String, stateDir: String, mountRoot: String, stubDir: String) { self.repoPath=repoPath; self.cacheDir=cacheDir; self.stateDir=stateDir; self.mountRoot=mountRoot; self.stubDir=stubDir }

    private enum CodingKeys: String, CodingKey {
        case schema, backend, repoPath, cacheDir, stateDir, mountRoot, stubDir, quotaBytes, minFreeBytes, detachDelaySeconds, restoreImageFormat, backends, activeBackendId, mirrorBackendIds, signIdentity, sessionColdDays, sessionRoots, sessionHome, sessionSegmentMaxBytes, sessionSoloBytes, sessionMaxFileBytes, sessionEncryption, imageEncryption
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
        restoreImageFormat = try container.decodeIfPresent(String.self, forKey: .restoreImageFormat) ?? "ULMO"
        backends = try container.decodeIfPresent([BackendEndpoint].self, forKey: .backends) ?? []
        activeBackendId = try container.decodeIfPresent(String.self, forKey: .activeBackendId)
        mirrorBackendIds = try container.decodeIfPresent([String].self, forKey: .mirrorBackendIds) ?? []
        signIdentity = try container.decodeIfPresent(String.self, forKey: .signIdentity) ?? "-"
        sessionColdDays = try container.decodeIfPresent(Int.self, forKey: .sessionColdDays) ?? 14
        sessionRoots = try container.decodeIfPresent([SessionRoot].self, forKey: .sessionRoots) ?? []
        sessionHome = try container.decodeIfPresent(String.self, forKey: .sessionHome)
        sessionSegmentMaxBytes = try container.decodeIfPresent(UInt64.self, forKey: .sessionSegmentMaxBytes) ?? 64 * 1024 * 1024
        sessionSoloBytes = try container.decodeIfPresent(UInt64.self, forKey: .sessionSoloBytes) ?? 8 * 1024 * 1024
        sessionMaxFileBytes = try container.decodeIfPresent(UInt64.self, forKey: .sessionMaxFileBytes) ?? 512 * 1024 * 1024
        sessionEncryption = try container.decodeIfPresent(String.self, forKey: .sessionEncryption) ?? "off"
        imageEncryption = try container.decodeIfPresent(String.self, forKey: .imageEncryption) ?? "off"
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
        try container.encode(restoreImageFormat, forKey: .restoreImageFormat)
        try container.encode(backends, forKey: .backends)
        try container.encodeIfPresent(activeBackendId, forKey: .activeBackendId)
        if !mirrorBackendIds.isEmpty { try container.encode(mirrorBackendIds, forKey: .mirrorBackendIds) }
        try container.encode(signIdentity, forKey: .signIdentity)
        try container.encode(sessionColdDays, forKey: .sessionColdDays)
        try container.encode(sessionRoots, forKey: .sessionRoots)
        try container.encodeIfPresent(sessionHome, forKey: .sessionHome)
        try container.encode(sessionSegmentMaxBytes, forKey: .sessionSegmentMaxBytes)
        try container.encode(sessionSoloBytes, forKey: .sessionSoloBytes)
        try container.encode(sessionMaxFileBytes, forKey: .sessionMaxFileBytes)
        try container.encode(sessionEncryption, forKey: .sessionEncryption)
        try container.encode(imageEncryption, forKey: .imageEncryption)
    }

    public static func environment(_ env: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(), platform: HostPlatform = .current) -> RuntimeConfig {
        func v(_ key: String, _ fallback: String) -> String { env["DISKLESSLY_\(key)"] ?? fallback }
        if platform == .linux { return linuxEnvironment(env, home: home) }
        // An install made before the rename keeps its `256isenough` folders; nothing is moved or copied.
        func dir(_ parent: String) -> String {
            let current = "\(home)/\(parent)/Disklessly", legacy = "\(home)/\(parent)/256isenough"
            let fm = FileManager.default
            return !fm.fileExists(atPath: current) && fm.fileExists(atPath: legacy) ? legacy : current
        }
        let stateDefault = dir("Library/Application Support")
        // The cache is disposable, so it never reuses a legacy folder; only state and the repo do.
        let cacheDefault = "\(home)/Library/Caches/Disklessly"
        let repoDefault = dir("Library/Mobile Documents/com~apple~CloudDocs")
        var config = RuntimeConfig(repoPath: v("REPO_PATH", repoDefault), cacheDir: v("CACHE_DIR", cacheDefault), stateDir: v("STATE_DIR", stateDefault), mountRoot: v("MOUNT_ROOT", "\(cacheDefault)/mnt"), stubDir: v("STUB_DIR", "/Applications"))
        if let quota = env["DISKLESSLY_QUOTA_BYTES"].flatMap(UInt64.init) { config.quotaBytes = quota }
        if let floor = env["DISKLESSLY_MIN_FREE_BYTES"].flatMap(UInt64.init) { config.minFreeBytes = floor }
        if let identity = env["DISKLESSLY_SIGN_IDENTITY"], !identity.isEmpty { config.signIdentity = identity }
        if let format = env["DISKLESSLY_RESTORE_IMAGE_FORMAT"], !format.isEmpty { config.restoreImageFormat = format }
        if let encryption = env["DISKLESSLY_IMAGE_ENCRYPTION"], !encryption.isEmpty { config.imageEncryption = encryption }
        return config
    }

    /// XDG folders. There is no iCloud Drive, so the default repo is a plain folder
    /// under the data dir until `init --root` or `backend add` points elsewhere.
    /// Stubs are never written on Linux; `~/Applications` is where AppImages usually live.
    static func linuxEnvironment(_ env: [String: String], home: String) -> RuntimeConfig {
        func v(_ key: String, _ fallback: String) -> String { env["DISKLESSLY_\(key)"] ?? fallback }
        func xdg(_ key: String, _ fallback: String) -> String {
            if let value = env[key], value.hasPrefix("/") { return value }
            return "\(home)/\(fallback)"
        }
        let stateDefault = xdg("XDG_DATA_HOME", ".local/share") + "/disklessly"
        let cacheDefault = xdg("XDG_CACHE_HOME", ".cache") + "/disklessly"
        let cacheDir = v("CACHE_DIR", cacheDefault)
        var config = RuntimeConfig(repoPath: v("REPO_PATH", "\(stateDefault)/repo"), cacheDir: cacheDir, stateDir: v("STATE_DIR", stateDefault), mountRoot: v("MOUNT_ROOT", "\(cacheDefault)/mnt"), stubDir: v("STUB_DIR", "\(home)/Applications"))
        if let quota = env["DISKLESSLY_QUOTA_BYTES"].flatMap(UInt64.init) { config.quotaBytes = quota }
        if let floor = env["DISKLESSLY_MIN_FREE_BYTES"].flatMap(UInt64.init) { config.minFreeBytes = floor }
        return config
    }

    /// `--config` replaces the file outright. Otherwise `<stateDir>/config.json` is
    /// loaded and explicit `DISKLESSLY_*` path overrides are applied on top. `backend`
    /// stays as stored, so `init --backend icloud` is what `status` reports.
    public static func resolved(environment env: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(), stateDirOverride: String?, explicitConfig: String?, platform: HostPlatform = .current) -> RuntimeConfig {
        var config = environment(env, home: home, platform: platform)
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
        // A config saved before the rename keeps the legacy cache folder, which the running app then
        // keeps filling. The cache is disposable, so it moves to the Disklessly folder.
        if env["DISKLESSLY_CACHE_DIR"] == nil, merged.cacheDir.contains("/Library/Caches/256isenough") { merged.cacheDir = config.cacheDir }
        if env["DISKLESSLY_MOUNT_ROOT"] == nil, merged.mountRoot.contains("/Library/Caches/256isenough") { merged.mountRoot = config.mountRoot }
        if env["DISKLESSLY_REPO_PATH"] != nil { merged.repoPath = config.repoPath }
        if env["DISKLESSLY_CACHE_DIR"] != nil { merged.cacheDir = config.cacheDir }
        if env["DISKLESSLY_STATE_DIR"] != nil || stateDirOverride != nil { merged.stateDir = config.stateDir }
        if env["DISKLESSLY_MOUNT_ROOT"] != nil { merged.mountRoot = config.mountRoot }
        if env["DISKLESSLY_STUB_DIR"] != nil { merged.stubDir = config.stubDir }
        if env["DISKLESSLY_QUOTA_BYTES"] != nil { merged.quotaBytes = config.quotaBytes }
        if env["DISKLESSLY_MIN_FREE_BYTES"] != nil { merged.minFreeBytes = config.minFreeBytes }
        if let identity = env["DISKLESSLY_SIGN_IDENTITY"], !identity.isEmpty { merged.signIdentity = identity }
        if let encryption = env["DISKLESSLY_IMAGE_ENCRYPTION"], !encryption.isEmpty { merged.imageEncryption = encryption }
        if let stateDirOverride { merged.stateDir = stateDirOverride }
        return merged
    }

    public mutating func remember(_ endpoint: BackendEndpoint) {
        backends.removeAll { $0.id == endpoint.id }
        backends.append(endpoint)
        activeBackendId = endpoint.id
        backend = endpoint.type
        if let mount = endpoint.mountPoint { repoPath = mount }
        mirrorBackendIds.removeAll { $0 == endpoint.id }
    }

    /// Adds or replaces `endpoint` without switching the active repo to it.
    public mutating func store(_ endpoint: BackendEndpoint) {
        backends.removeAll { $0.id == endpoint.id }
        backends.append(endpoint)
    }

    /// Id that names the folder at `repoPath` (the repo when `activeBackendId` is nil).
    public static let defaultRepoId = "default"

    /// `activeBackendId` when it names a known backend, else `default`.
    public var activeRepoId: String {
        if let id = activeBackendId, backends.contains(where: { $0.id == id }) { return id }
        return Self.defaultRepoId
    }

    /// Back to the repo at `repoPath` (iCloud Drive or a local folder).
    public mutating func useDefaultRepo() {
        activeBackendId = nil
        mirrorBackendIds.removeAll { $0 == Self.defaultRepoId }
        backend = ICloudFolderBackend.looksLikeICloud(URL(fileURLWithPath: repoPath)) ? "icloud" : "local"
    }
}

public enum Hashing {
    public static func sha256(_ url: URL) throws -> String {
        try SHA256Digest.hexFile(url)
    }
}

public enum StubGenerator {
    public static func infoPlist(source: [String:Any], appId: String, executable: String = "disklessly-stub") -> [String:Any] {
        var p=source; p["CFBundleIdentifier"]="\(appId).256stub"; p["CFBundleExecutable"]=executable; p["LSUIElement"]=true
        for key in ["SUFeedURL","SUPublicEDKey","ElectronDefaultApp"] { p.removeValue(forKey:key) }
        return p
    }
    /// `repoId` scopes the stub to one repo. Nil writes a legacy stub without it.
    public static func stubInfo(manifest: ImageManifest, cliPath: String, repoId: String? = nil) -> [String:Any] {
        var info: [String:Any] = ["schema":"stub/1", "appId":manifest.bundleId, "imageId":manifest.imageId, "disklesslyPath":cliPath, "engineVersion":EngineInstall.version, "engineRevision":EngineInstall.revision, "stubVersion":1]
        if let repoId, !repoId.isEmpty { info["repoId"] = repoId }
        return info
    }

    public static func locateLauncher(cliExecutable: URL, environment: [String:String], isExecutable: (String)->Bool) throws -> URL {
        let cli=cliExecutable.resolvingSymlinksInPath().standardizedFileURL
        if let override=environment["DISKLESSLY_STUB_BINARY"] {
            guard isExecutable(override) else { throw DisklesslyError.usage("DISKLESSLY_STUB_BINARY is not executable: \(override)") }
            let found=URL(fileURLWithPath:override).resolvingSymlinksInPath().standardizedFileURL
            guard found.path != cli.path else { throw DisklesslyError.failure("Refusing to use CLI as disklessly-stub launcher") }
            return found
        }
        let sibling=cli.deletingLastPathComponent().appendingPathComponent("disklessly-stub").path
        guard isExecutable(sibling) else { throw DisklesslyError.failure("disklessly-stub launcher binary not found next to \(cli.path)") }
        let found=URL(fileURLWithPath:sibling).resolvingSymlinksInPath().standardizedFileURL
        guard found.path != cli.path else { throw DisklesslyError.failure("Refusing to use CLI as disklessly-stub launcher") }
        return found
    }

    /// Compare filesystem paths lexically after collapsing redundant separators and dot components.
    /// URL equality is stricter than filesystem path equivalence (notably for `//`).
    public static func pathsReferToSameLocation(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).standardizingPath == (rhs as NSString).standardizingPath
    }
}

public struct DisklesslyEngine {
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
    /// Replaces iCloud/stat evidence during publish. Nil uses `imageEvidence`.
    public var imageEvidenceOverride: ((String) -> ImageEvidence)?
    /// Replaces the process probe during pack. Nil asks `ps`.
    public var packUsageOverride: ((String) -> UsageClass)?
    /// Tests: bundle ids counted against the free limit instead of scanning this Mac's stubs.
    public var offloadedOverride: (() throws -> Set<String>)?
    /// Tests: whether a file (false) or folder (true) is open, instead of asking lsof.
    public var fileOpenOverride: ((String, Bool) -> Bool)? = nil
    /// Tests: the last time a scanned item was opened, instead of asking Spotlight.
    public var lastUsedOverride: ((URL) -> Date?)? = nil
    /// The home folder that `files` scans and `offload` accepts paths in. Nil uses `DISKLESSLY_HOME`, then the user's home.
    public var homeOverride: String? = nil
    /// Decides what happens to an offloaded app's data when it quits: put it back in the repo, or keep it on this Mac.
    /// Nil asks with a dialog when there is a GUI session (`DISKLESSLY_QUIT_ASK=0` turns that off). Tests inject a choice.
    public var quitChooser: ((String) -> QuitChoice)? = nil
    public var homeDirectory: String { homeOverride ?? ProcessInfo.processInfo.environment["DISKLESSLY_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() }
    /// Replaces `SHA256Digest.hexFile` for prefetch. Nil hashes the file.
    public var hasherOverride: ((URL) throws -> String)?
    /// Replaces the disk-image tool and process probe for `detach` and the
    /// orphan mount reaper. Nil uses `MountOps.live`.
    public var mountOpsOverride: MountOps? = nil
    /// Tests: replaces `evictUbiquitousItem` for iCloud objects a repo copy read.
    public var placeholderEvictOverride: ((URL) -> Void)? = nil
    /// Tests: whether an offloaded app runs, for `caches`. Nil asks the state file and `ps`.
    public var appRunningOverride: ((ImageManifest) -> Bool)? = nil
    /// Tests: fake container CLIs and disk for `containers`. Nil runs the real tools.
    public var containerToolsOverride: ContainerTools? = nil
    /// Tests: fake or loopback SSH transport for `remote` / Machines UI. Nil uses `/usr/bin/ssh`.
    public var sshTransportOverride: SSHTransport? = nil
    /// Test hook. Called with a point name such as `pack.swapped` or
    /// `unpack.installed.beforeMutation`; a throw there is an ordinary failure,
    /// not a simulated crash. Production leaves it nil.
    var failureInjector: ((String) throws -> Void)? = nil
    /// Test hook. Forces the two-rename path that Linux and volumes without
    /// `RENAME_SWAP` use.
    var packSwapUnsupported = false
    public init(config: RuntimeConfig, services: RestoreServices? = nil, faults: FaultController? = nil, secrets: (any SecretStore)? = nil, shareOpener: ShareOpener = .system) {
        self.config=config
        let faults=faults ?? FaultController()
        self.faults=faults
        let services=services ?? RestoreServices.live(config: config)
        self.services=services
        self.restore=RestoreCoordinator(config: config, services: services, faults: faults)
        self.secrets = secrets ?? FileSecretStore.fromEnvironment() ?? PlatformSecrets.store()
        self.shareOpener = shareOpener
        self.backendOverride = nil
        self.recommendEnvironment = nil
        self.deviceFactsOverride = nil
        self.materialFilesOverride = nil
        self.ubiquityEvictor = nil
        self.backupFactsOverride = nil
        self.stubRootsOverride = nil
        self.imageEvidenceOverride = nil
        self.packUsageOverride = nil
        self.hasherOverride = nil
    }
    /// The active repo. With mirrors configured, reads fail over to them (`FailoverBackend`).
    public func openBackend() throws -> any StorageBackend {
        let primary = try openPrimaryBackend()
        let mirrors = config.mirrorBackendIds.filter { $0 != config.activeRepoId }
        guard !mirrors.isEmpty else { return primary }
        let engine = self
        return FailoverBackend(primary: primary, mirrors: mirrors.map { id in (id: id, open: { try engine.openRepo(id: id) }) })
    }

    /// The active repo alone, without mirror failover. Copies and migrations use this.
    public func openPrimaryBackend() throws -> any StorageBackend {
        if let backendOverride { return backendOverride }
        return try openRepo(id: config.activeRepoId)
    }

    /// A repo by id: a `backends` entry, or `default` for the folder at `repoPath`.
    public func openRepo(id: String) throws -> any StorageBackend {
        if id != RuntimeConfig.defaultRepoId {
            guard let endpoint = config.backends.first(where: { $0.id == id }) else {
                throw DisklesslyError.usage("unknown backend: \(id)")
            }
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
        // Linux writes no stubs, so it does not create the stub folder.
        let folders = HostPlatform.current.offloadsApps ? [config.cacheDir, config.stateDir, config.mountRoot, config.stubDir] : [config.cacheDir, config.stateDir]
        for p in folders { try fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
        let backend = try repo
        if let root = backend.localRoot() {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try RepoIdentity.ensure(backend)
        for p in ["images", "manifests", "catalog", "devices", "trash"] { try backend.ensureCollection(p) }
        try saveConfig()
        // The installed engine is what stubs call; Linux has no stubs.
        if HostPlatform.current.offloadsApps, EngineInstall.runningExecutable().lastPathComponent == "disklessly" {
            try installEngine()
        }
    }

    /// Copy the running `disklessly` to `<stateDir>/bin/disklessly` and refresh the stamp.
    /// Unit tests run under an xctest host, which is not an engine, so callers that
    /// always want a copy pass `source`.
    @discardableResult
    public func installEngine(source: URL? = nil) throws -> URL {
        let binary = source ?? EngineInstall.runningExecutable()
        let installed = try EngineInstall.install(stateDir: config.stateDir, source: binary)
        try ensureDevice()
        return installed
    }

    /// Path written into new stubs. Prefers the stable copy once it exists.
    public func installedEnginePath() throws -> String {
        // The installed engine is what stubs call; Linux has no stubs.
        if HostPlatform.current.offloadsApps, EngineInstall.runningExecutable().lastPathComponent == "disklessly" {
            try installEngine()
        }
        let binary = EngineInstall.binary(stateDir: config.stateDir)
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary.path }
        return EngineInstall.runningExecutable().path
    }

    /// Rewrite `stub.json` in installed stubs so `disklesslyPath` is the stable engine, then re-sign on macOS.
    /// A stub that names another repo is reported in `foreign` and not touched,
    /// the same as `refreshOwnedStubs`.
    public func refreshStubs(appId: String) throws -> StubRefreshReport {
        try ensureDevice()
        let bundles = locatedStubs(matching: appId)
        guard !bundles.isEmpty else { throw DisklesslyError.usage("no installed stub for \(appId)") }
        let backend = try repo
        try RepoIdentity.ensure(backend)
        let scope = try stubScope(backend, manifests: try readManifests(backend))
        let enginePath = try installedEnginePath()
        var report = StubRefreshReport()
        for bundle in bundles {
            if let stub = StubIdentity.read(bundle: bundle), stub.isForeign(toRepo: scope.repoId) {
                let imageId = stub.imageId ?? Self.embeddedImageId(bundle) ?? ""
                if !imageId.isEmpty, scope.isMismatched(stub, imageId: imageId) {
                    report.mismatched.append(bundle.path)
                } else {
                    report.foreign.append(bundle.path)
                }
                continue
            }
            try rewriteStubEngine(bundle: bundle, enginePath: enginePath, repoId: scope.repoId, knownImageIds: scope.manifestIds.union(scope.trashedIds))
            report.updated.append(bundle.path)
        }
        let icons = try backfillIcons(appId: appId)
        for warning in icons.warnings {
            FileHandle.standardError.write(Data("disklessly: \(warning)\n".utf8))
        }
        return report
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
            lines.append("installed engine is missing at \(installed); run disklessly install-engine")
        case .older(let detail):
            lines.append("\(detail); run disklessly install-engine")
        }
        guard case .missing = EngineInstall.freshness(at: installed) else { return lines }
        for bundle in locatedStubs(matching: nil) {
            let stubJSON = bundle.appendingPathComponent("Contents/Resources/stub.json")
            guard let data = try? Data(contentsOf: stubJSON),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recorded = object["disklesslyPath"] as? String,
                  !StubGenerator.pathsReferToSameLocation(recorded, installed) else { continue }
            let app = object["appId"] as? String ?? bundle.deletingPathExtension().lastPathComponent
            switch EngineInstall.freshness(at: recorded, fileManager: fm) {
            case .current:
                break
            case .missing:
                lines.append("stub \(bundle.path) engine is missing at \(recorded); run disklessly stub refresh --app \(app)")
            case .older(let detail):
                lines.append("stub \(bundle.path) \(detail); run disklessly stub refresh --app \(app)")
            }
        }
        return lines
    }

    func locatedStubs(matching appId: String?) -> [URL] {
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

    /// Also stamps `repoId` on a legacy stub whose image has a manifest in this
    /// repo (`knownImageIds`). A stub that already names a repo keeps it unless
    /// `adopt` is set (`stub refresh --all --adopt` for a mismatched stub).
    func rewriteStubEngine(bundle: URL, enginePath: String, repoId: String? = nil, knownImageIds: Set<String> = [], adopt: Bool = false) throws {
        let stubJSON = bundle.appendingPathComponent("Contents/Resources/stub.json")
        let data = try Data(contentsOf: stubJSON)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DisklesslyError.failure("stub.json in \(bundle.path) is not an object")
        }
        object["disklesslyPath"] = enginePath
        object["engineVersion"] = EngineInstall.version
        object["engineRevision"] = EngineInstall.revision
        if object["schema"] == nil { object["schema"] = "stub/1" }
        if object["stubVersion"] == nil { object["stubVersion"] = 1 }
        let stub = StubIdentity(object: object)
        if stub.isLegacy || adopt, let repoId, let image = stub.imageId, knownImageIds.contains(image) {
            object["repoId"] = repoId
        }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: stubJSON, options: .atomic)
        #if os(macOS)
        let imageId = object["imageId"] as? String ?? ""
        if AppIcon.isSafeImageId(imageId) {
            let recorded = (try? list())?.first { $0.imageId == imageId }?.app.originalPath
            StubIcon.backfill(stub: bundle, imageId: imageId, stateDir: config.stateDir, originals: StubIcon.originals(mountRoot: config.mountRoot, imageId: imageId, stub: bundle, recordedPath: recorded), publish: { data in
                self.publishIcon(imageId, data: data)
            })
        }
        let identity = SigningIdentity.resolve(configured: config.signIdentity, environment: ProcessInfo.processInfo.environment)
        try ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", identity, bundle.path])
        StubIcon.touch(bundle)
        StubIcon.register(bundle)
        #endif
    }

    func publishIcon(_ imageId: String, data: Data) {
        do {
            guard let relative = AppIcon.repoRelativePath(imageId: imageId) else { return }
            let backend = try repo
            if try backend.stat(relative) == nil {
                try backend.ensureCollection("icons")
                try backend.put(relative, data: data)
            }
        } catch {
            FileHandle.standardError.write(Data("disklessly: could not publish the icon: \(error.localizedDescription)\n".utf8))
        }
    }

    public func pack(_ appPath: String, mode: ImageManifest.Mode? = nil, keepOriginal: Bool = false, noStub: Bool = false, imageFormat requestedFormat: String? = nil, encrypt requestedEncrypt: Bool? = nil) throws -> PublishResult {
        #if !os(macOS)
        _ = (requestedFormat, requestedEncrypt)
        throw DisklesslyError.unsupported("pack requires macOS hdiutil and codesign")
        #else
        let app=URL(fileURLWithPath:appPath).standardizedFileURL, plistURL=app.appendingPathComponent("Contents/Info.plist")
        guard let info=NSDictionary(contentsOf:plistURL) as? [String:Any], let bid=info["CFBundleIdentifier"] as? String else { throw DisklesslyError.usage("Not a valid .app bundle") }
        let name=info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent, version=info["CFBundleShortVersionString"] as? String ?? "0"
        let selected=mode ?? ((FileManager.default.fileExists(atPath:app.appendingPathComponent("Contents/_MASReceipt/receipt").path) ? .restore : .mount))
        let requested = requestedFormat ?? (selected == .restore ? config.restoreImageFormat : "ULMO")
        let imageFormat = requested.uppercased()
        let encrypt = try requestedEncrypt ?? imageEncryptionDefault()
        if encrypt, try ImageKeyStore.current(secrets: secrets) == nil {
            throw DisklesslyError.usage("image encryption is on but this Mac has no image key; run disklessly images key init")
        }
        guard imageFormat == "ULMO" || imageFormat == "ULFO" else {
            throw DisklesslyError.usage("invalid --image-format \(requested); expected ULMO or ULFO")
        }
        try PackGuard.refuseStub(app, bundleId: bid)
        try License.checkPack(state: License.load(stateDir: config.stateDir), offloaded: try offloadedOverride?() ?? offloadedBundleIds(), packing: bid, files: offloadedFileCount())
        let usage = packUsageOverride?(app.path) ?? ProcessProbe.usage(roots: [app.path])
        if let blocked = PackPreflight.running(usage, name: name) { throw blocked }
        let allocated = AllocatedSize.tree(app)
        // A fresh state (first pack on this Mac) has no cache folder yet.
        try FileManager.default.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
        let free = try VolumeSpace.availableBytes(at: config.cacheDir)
        let cacheDevice = PackPreflight.deviceID(config.cacheDir)
        let cloneSupported = cacheDevice != nil && cacheDevice == PackPreflight.deviceID(app.path)
        let repoDevice = PackPreflight.deviceID(config.repoPath)
        let localRoot = (try? openBackend().localRoot()) != nil
        let repoOnSameVolume = localRoot && cacheDevice != nil && cacheDevice == repoDevice
        let room = PackPreflight.space(appAllocated: allocated, free: free, cloneSupported: cloneSupported, repoOnSameVolume: repoOnSameVolume, minFree: config.minFreeBytes, volume: config.cacheDir)
        if let blocked = room.error { throw blocked }
        let staging=URL(fileURLWithPath:config.cacheDir).appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:staging.appendingPathComponent("src"),withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:staging) }
        let stagedApp=staging.appendingPathComponent("src").appendingPathComponent(app.lastPathComponent)
        // Taken before the copy. The stub swap compares it again under the app lock,
        // so an update or a launch that lands while the image is built aborts the swap.
        let cloneFingerprint = try TreeFingerprint.of(app)
        if cloneSupported {
            let cloned = clonefile(app.path, stagedApp.path, UInt32(CLONE_NOFOLLOW))
            if cloned != 0 {
                if errno == EEXIST {
                    throw DisklesslyError.failure("refusing to replace an existing staged copy at \(stagedApp.path)")
                }
                let again = PackPreflight.space(appAllocated: allocated, free: free, cloneSupported: false, repoOnSameVolume: repoOnSameVolume, minFree: config.minFreeBytes, volume: config.cacheDir)
                if let blocked = again.error { throw blocked }
                try run("/usr/bin/ditto",[app.path,stagedApp.path])
            }
        } else {
            try run("/usr/bin/ditto",[app.path,stagedApp.path])
        }
        BundleHasher.removeMetadataSidecars(stagedApp)
        let executableName = BundleExecutable.name(info: info, app: app)
        let build = info["CFBundleVersion"] as? String ?? "0"
        _ = try MASReceiptStore.preserve(from: stagedApp, bundleId: bid, stateDir: URL(fileURLWithPath: config.stateDir))
        BundleHasher.removeMachineReceipt(stagedApp)
        let contentHash = try BundleHasher.treeHash(of: stagedApp)
        let architectures = MachArchitectures.slices(at: stagedApp.appendingPathComponent("Contents/MacOS/\(executableName)"))
        let identity = ImageIdentity(bundleId: bid, version: version, build: build, architectures: architectures.isEmpty ? ["unknown"] : architectures, treeHash: contentHash)
        let backend = try repo
        let manifests = try readManifests(backend)
        let decision = PublishPlanner.decide(identity: identity, manifests: manifests, evidence: { path in
            self.imageEvidence(backend, path, expectedSize: manifests.first { $0.image.file == path }?.image.size)
        }, inTrash: { id in
            (try? backend.stat("trash/images/\(id).dmg")) != nil
        })
        if case .reuse(let existing, let disposition) = decision {
            try requireImageKey(existing)
            try register(existing, backend: backend, now: Date())
            if EngineInstall.runningExecutable().lastPathComponent == "disklessly" { try installEngine() }
            let forcedKeep = { if case .keep = disposition { return true }; return false }()
            let stubWarning = noStub ? nil : try installStub(info: info, manifest: existing, path: app.path, keepOriginal: keepOriginal || forcedKeep, cloneFingerprint: cloneFingerprint)
            let kept: String? = { if case .keep(let reason) = disposition { return reason }; return nil }()
            return finishPublished(PublishResult(manifest: existing, reused: true, uploaded: false, originalKept: kept), stubWarning: stubWarning)
        }
        if case .refuse(let message, let code) = decision {
            if code == 4 { throw DisklesslyError.backend(message) }
            throw DisklesslyError.integrity(message)
        }
        let dmg=staging.appendingPathComponent("image.dmg")
        try run("/usr/bin/hdiutil",["create","-quiet","-srcfolder",staging.appendingPathComponent("src").path,"-format",imageFormat,"-volname",name,"-o",dmg.deletingPathExtension().path])
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
        let request = PublishRequest(name: name, identity: identity, mode: selected, executable: executableName, originalPath: app.path, cdhash: cdhash, postImageTreeHash: treeHash, volumeName: name, appPathInVolume: app.lastPathComponent, documentTypes: docs, urlTypes: urls, imageFormat: imageFormat, encrypt: encrypt)
        let published = try publish(request, imageFile: dmg)
        if EngineInstall.runningExecutable().lastPathComponent == "disklessly" { try installEngine() }
        let stubWarning = noStub ? nil : try installStub(info: info, manifest: published.manifest, path: app.path, keepOriginal: keepOriginal, cloneFingerprint: cloneFingerprint)
        return finishPublished(published, stubWarning: stubWarning)
        #endif
    }
    #if os(macOS)
    private func installStub(info:[String:Any],manifest:ImageManifest,path:String,keepOriginal:Bool,cloneFingerprint:String) throws -> String? {
        let source=URL(fileURLWithPath:path).standardizedFileURL
        let dest=URL(fileURLWithPath:config.stubDir).standardizedFileURL.appendingPathComponent(source.lastPathComponent)
        guard StubGenerator.pathsReferToSameLocation(source.path, dest.path) else { throw DisklesslyError.unsupported("Stub must replace the app at its original path (source: \(source.path), destination: \(dest.path))") }
        let temp=dest.deletingLastPathComponent().appendingPathComponent(".disklessly-\(UUID().uuidString).app")
        var committed=false
        defer { if !committed { try? FileManager.default.removeItem(at: temp) } }
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        let plistPath=temp.appendingPathComponent("Contents/Info.plist")
        guard (StubGenerator.infoPlist(source:info,appId:manifest.bundleId) as NSDictionary).write(to:plistPath,atomically:true) else {
            throw DisklesslyError.failure("Could not write generated stub Info.plist at \(plistPath.path)")
        }
        let cli=EngineInstall.runningExecutable()
        let launcher=try StubGenerator.locateLauncher(cliExecutable:cli,environment:ProcessInfo.processInfo.environment,isExecutable:{ FileManager.default.isExecutableFile(atPath:$0) })
        let stubExecutable=temp.appendingPathComponent("Contents/MacOS/disklessly-stub")
        try FileManager.default.copyItem(at:launcher,to:stubExecutable)
        if FileManager.default.contentsEqual(atPath: stubExecutable.path, andPath: cli.path) {
            throw DisklesslyError.failure("Refusing to install CLI binary as disklessly-stub launcher")
        }
        let manifestData = try manifest.encode()
        try manifestData.write(to:temp.appendingPathComponent("Contents/Resources/manifest.json"))
        // A later stub rebuild reads this copy instead of the repo.
        StubManifestCache.store(manifestData, imageId: manifest.imageId, cacheDir: config.cacheDir)
        let enginePath = try installedEnginePath()
        let repoId = repoIdentity()
        try JSONSerialization.data(withJSONObject:StubGenerator.stubInfo(manifest:manifest,cliPath:enginePath,repoId:repoId),options:[.prettyPrinted,.sortedKeys]).write(to:temp.appendingPathComponent("Contents/Resources/stub.json"))
        StubIcon.capture(from: source, into: temp, imageId: manifest.imageId, stateDir: config.stateDir, publish: { data in
            self.publishIcon(manifest.imageId, data: data)
        })
        // Signing the bundle re-signs its main executable disklessly-stub in place.
        // No --deep is needed because there are no nested code items.
        let identity = SigningIdentity.resolve(configured: config.signIdentity, environment: ProcessInfo.processInfo.environment)
        try run("/usr/bin/codesign",["--force","--sign",identity,temp.path])
        try run("/usr/bin/codesign",["--verify","--strict",temp.path])
        committed = true
        let warning = try commitStub(staged: temp, source: source, bundleId: manifest.bundleId, name: manifest.name, cloneFingerprint: cloneFingerprint, keepOriginal: keepOriginal)
        StubIcon.touch(dest)
        StubIcon.register(dest)
        return warning
    }
    #endif
    /// Read-only. Uses manifests already in the repo and does not register this Mac.
    /// iCloud metadata waits share one short budget for this call.
    public func list() throws -> [ImageManifest] {
        try UbiquitousMaterializer.withBudget(ICloudLimits.metadataTimeout()) {
            try readManifests(try repo)
        }
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
    /// True when `path` is a live mount point. Launch leaves an empty folder behind
    /// after detach, so a folder that merely exists does not mean "mounted".
    /// The parent is resolved first: through a symlinked parent, lstat of the
    /// link itself would report the link's device, not the target folder's.
    static func isActiveMountPoint(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != "/", let real = realpath((path as NSString).deletingLastPathComponent, nil) else { return false }
        let parentPath = String(cString: real)
        free(real)
        let child = (parentPath as NSString).appendingPathComponent(name)
        var mount = stat(), parent = stat()
        guard lstat(child, &mount) == 0, lstat(parentPath, &parent) == 0 else { return false }
        return mount.st_dev != parent.st_dev
    }
    /// design §4: refuses a pinned app unless `force`, and a mounted or in-use
    /// image even with `force` (EX_BUSY). See `evictRefusal`.
    public func evict(_ manifest: ImageManifest, force: Bool = false) throws {
        if let refusal = evictRefusal(manifest, force: force) { throw refusal.error }
        let path=URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }
    public func gc(now: Date = Date(), includeLegacy: Bool = false) throws -> [String] {
        var lines = try recoverPackJournals()
        lines.append(contentsOf: try recoverUnpackJournals())
        lines.append(contentsOf: try maintain(now: now, includeLegacy: includeLegacy).lines)
        lines.append(contentsOf: reapOrphanMounts(deep: false).actionLines)
        let enforced = try enforceCacheQuota(justUsed: nil, now: now)
        lines.append(contentsOf: enforced.lines)
        return lines
    }

    struct CacheScan {
        var items: [CacheItem]
        var leftovers: [(path: String, bytes: UInt64)]
        var recorded: [String: UInt64]
        var fingers: [String: FileFingerprint]
    }

    /// Read the cache. Does not write state or delete files.
    func scanCache(justUsed: String?, now: Date) -> CacheScan {
        let fm = FileManager.default
        let images = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images")
        let names = (try? fm.contentsOfDirectory(atPath: images.path)) ?? []
        let loaded = StateStore(config.stateDir).load()
        #if os(macOS)
        let usage = LiveMaterialProbe.usageMap(config: config, now: now)
        let imageListing = Data(ProcessRunner.capture("/usr/bin/hdiutil", ["info", "-plist"]).utf8)
        #endif
        var items: [CacheItem] = []
        var recorded: [String: UInt64] = [:]
        var fingers: [String: FileFingerprint] = [:]
        for name in names where name.hasSuffix(".dmg") {
            let url = images.appendingPathComponent(name)
            let id = (name as NSString).deletingPathExtension
            let bytes = allocatedBlocks(url)
            recorded[id] = bytes
            if let finger = try? FileFingerprint.of(url: url) { fingers[id] = finger }
            let owners = loaded.apps.filter { $0.value.imageId == id }
            let pinned = owners.values.contains { $0.pinned }
            let needs = owners.values.contains { $0.needsResolution != nil }
            var mounted = Self.isActiveMountPoint(URL(fileURLWithPath: config.mountRoot).appendingPathComponent(id).path)
            var inUse = owners.values.contains { ($0.state == "running" || $0.state == "detaching") }
            var protected: Date? = nil
            #if os(macOS)
            if usage.inUse.contains(id) { inUse = true }
            protected = usage.until[id]
            if DiskImageTool.plistListsMountPoint(imageListing, url.path) { mounted = true }
            #endif
            items.append(CacheItem(imageId: id, bytes: bytes, lastUsed: loaded.cache[id]?.lastUsed ?? owners.values.compactMap(\.lastUsed).max(), pinned: pinned, mounted: mounted, inUse: inUse, protectedUntil: protected, needsResolution: needs, justUsed: id == justUsed))
        }
        return CacheScan(items: items, leftovers: cacheLeftovers(now: now), recorded: recorded, fingers: fingers)
    }

    /// Drop cached images until `quotaBytes` holds. `justUsed` is evicted last, and never when it alone exceeds the quota.
    @discardableResult
    public func enforceCacheQuota(justUsed: String?, now: Date = Date()) throws -> (plan: EvictionPlan, lines: [String]) {
        let fm = FileManager.default
        let images = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images")
        let scan = scanCache(justUsed: justUsed, now: now)
        if !scan.recorded.isEmpty {
            try StateStore(config.stateDir).update { state in
                for (id, bytes) in scan.recorded {
                    var entry = state.cache[id] ?? CacheEntry()
                    entry.bytes = bytes
                    state.cache[id] = entry
                }
            }
        }
        let plan = CachePlanner.planEviction(scan.items, leftovers: scan.leftovers, quota: config.quotaBytes, now: now)
        if plan.shortBy > 0 {
            FileHandle.standardError.write(Data("disklessly: cache still exceeds quota by \(plan.shortBy) bytes\n".utf8))
        }
        let loaded = StateStore(config.stateDir).load()
        var lines: [String] = []
        for victim in plan.victims {
            if victim.contains("/") {
                let url = URL(fileURLWithPath: config.cacheDir).appendingPathComponent(victim)
                if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
                continue
            }
            guard let bundleId = loaded.apps.first(where: { $0.value.imageId == victim })?.key else {
                try deleteCacheImage(victim, bytes: scan.recorded[victim] ?? 0, lines: &lines)
                continue
            }
            let directory = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/app")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var lock = FileLock(path: directory.appendingPathComponent(bundleId + ".lock").path)
            guard try lock.tryLock() else { continue }
            defer { lock.unlock() }
            let fresh = StateStore(config.stateDir).load()
            if fresh.apps[bundleId]?.pinned == true { continue }
            if fresh.apps[bundleId]?.needsResolution != nil { continue }
            let url = images.appendingPathComponent(victim + ".dmg")
            guard let before = scan.fingers[victim] else { continue }
            guard let again = try? FileFingerprint.of(url: url), again == before else { continue }
            try deleteCacheImage(victim, bytes: scan.recorded[victim] ?? 0, lines: &lines)
        }
        return (plan, lines)
    }

    private func cacheLeftovers(now: Date) -> [(path: String, bytes: UInt64)] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: config.cacheDir)
        var found: [(path: String, bytes: UInt64)] = []
        let partial = root.appendingPathComponent("partial")
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        if let names = try? fm.contentsOfDirectory(atPath: partial.path) {
            for name in names {
                let url = partial.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
                if modified < cutoff {
                    found.append((path: "partial/\(name)", bytes: allocatedBlocks(url)))
                }
            }
        }
        let bad = root.appendingPathComponent("bad")
        if let names = try? fm.contentsOfDirectory(atPath: bad.path) {
            for name in names {
                let url = bad.appendingPathComponent(name)
                found.append((path: "bad/\(name)", bytes: allocatedBlocks(url)))
            }
        }
        return found
    }

    private func allocatedBlocks(_ url: URL) -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_blocks > 0 else { return 0 }
        return UInt64(info.st_blocks) * 512
    }

    private func deleteCacheImage(_ id: String, bytes: UInt64, lines: inout [String]) throws {
        let url = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images/\(id).dmg")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try StateStore(config.stateDir).update { state in
            guard var entry = state.cache[id] else { return }
            entry.verified = nil
            entry.bytes = nil
            state.cache[id] = entry
        }
        lines.append("evicted cache \(id) (\(bytes))")
    }
    /// Each check is bounded. `onCheck` runs on the caller as soon as that check finishes,
    /// so a stuck iCloud `fileExists` cannot hide every later result.
    public func doctor(checkTimeout: TimeInterval = DoctorLimits.timeout(), fix: Bool = false, onCheck: (([String: Any]) -> Void)? = nil) -> [String: Any] {
        Doctor.run(engine: self, checkTimeout: checkTimeout, fix: fix, onCheck: onCheck)
    }

    /// Rank installed apps worth offloading. The scan is read-only. On Linux the
    /// live scan is unavailable unless `recommendEnvironment` injects facts.
    /// `repoReachable: false` (the dashboard's probe says offline) skips the repo
    /// lookups, which would otherwise block for the transport timeout; the local scan
    /// still runs and pins still count.
    public func recommend(options: RecommendOptions, repoReachable: Bool = true) -> RecommendReport {
        let environment = recommendEnvironment ?? LiveRecommendScan.environment(home: NSHomeDirectory(), now: options.now)
        var ranked = options
        let catalog = repoReachable ? UbiquitousMaterializer.withBudget(ICloudLimits.metadataTimeout()) { () -> RecommendCatalog in
            ranked.repoImages = self.repoImagePresences()
            return self.recommendCatalog()
        } : self.recommendCatalog(manifests: [])
        guard environment.available else {
            return RecommendRanking.rank([], options: ranked, scanAvailable: false)
        }
        let apps = RecommendDiscovery.collect(environment: environment, catalog: catalog)
        var report = RecommendRanking.rank(apps, options: ranked, scanAvailable: true)
        report.leftovers = RecommendDiscovery.leftovers(environment: environment)
        return report
    }

    private func recommendCatalog(manifests listed: [ImageManifest]? = nil) -> RecommendCatalog {
        let manifests = listed ?? ((try? list()) ?? [])
        let stored = StateStore(config.stateDir).load().apps
        var pinned = Set<String>()
        for (bundleId, item) in stored where item.pinned {
            pinned.insert(bundleId)
        }
        return RecommendCatalog(pinnedBundleIds: pinned, packedBundleIds: Set(manifests.map(\.bundleId)), packedPaths: Set(manifests.map(\.app.originalPath)))
    }
    public func resolve(_ manifest: ImageManifest, keepUpdated: Bool, trust: Bool, export: String?, discard: Bool) throws {
        guard let record=restore.needsResolution(manifest.bundleId), let path=record["retainedPath"] as? String, let tree=record["treeHash"] as? String else {
            throw DisklesslyError.usage("no retained bundle to resolve for \(manifest.bundleId)")
        }
        try ensureDevice()
        let url=URL(fileURLWithPath: path)
        let actual=try restore.services.treeHash(url)
        guard actual == tree else { throw DisklesslyError.integrity("retained bundle tree hash does not match the resolution record") }
        if keepUpdated {
            guard restore.services.signatureValid(url) else { throw DisklesslyError.integrity("retained bundle has an invalid code signature; export or discard it") }
            let cdhash=try restore.services.cdhash(url)
            if cdhash != manifest.app.cdhash && !trust { throw DisklesslyError.usage("updated bundle cdhash differs from the packed image; pass --trust to approve it") }
            #if os(macOS)
            let packed=try pack(path, mode: manifest.mode, keepOriginal: true, noStub: true)
            try restore.switchImage(appId: manifest.bundleId, imageId: packed.manifest.imageId, cdhash: cdhash)
            try restore.trash(url)
            try restore.clearResolution(appId: manifest.bundleId)
            return
            #else
            throw DisklesslyError.unsupported("resolve --keep-updated packs a new image and requires macOS")
            #endif
        }
        if let export {
            try restore.export(url, to: URL(fileURLWithPath: export))
        } else if discard {
            try restore.trash(url)
        } else {
            throw DisklesslyError.usage("resolve requires --discard, --export, or --keep-updated")
        }
        try restore.clearResolution(appId: manifest.bundleId)
    }
    public func watch(appId: String) throws {
        let since = Date()
        restore.loadConfiguredFaults()
        try restore.watch(appId: appId)
        #if os(macOS)
        try superviseRunningMount(appId: appId)
        appDataAfterQuit(appId: appId, since: since)
        #endif
    }
    /// `imageEncryption` from the config: `off` or `aes-gcm`.
    public func imageEncryptionDefault() throws -> Bool {
        switch config.imageEncryption {
        case "off", "": return false
        case "aes-gcm": return true
        default: throw DisklesslyError.usage("imageEncryption must be off or aes-gcm, not \(config.imageEncryption)")
        }
    }

    public func prefetch(_ manifest:ImageManifest) throws -> URL {
        let backend = try repo
        let paths = CachePaths(cacheDir: config.cacheDir, mountRoot: config.mountRoot)
        let cache = paths.image(manifest.imageId)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: cache.path) {
            let paranoid = ProcessInfo.processInfo.environment["DISKLESSLY_PARANOID_VERIFY"] == "1"
            if !paranoid, let stamp = StateStore(config.stateDir).load().cache[manifest.imageId]?.verified,
               stamp.sha256 == manifest.image.plainSha256,
               let finger = try? FileFingerprint.of(url: cache), finger == stamp.fingerprint {
                _ = try enforceCacheQuota(justUsed: manifest.imageId)
                return cache
            }
            if (try? hashCached(cache)) == manifest.image.plainSha256 {
                try rememberVerified(manifest.imageId, file: cache)
                _ = try enforceCacheQuota(justUsed: manifest.imageId)
                return cache
            }
        }
        // Look the key up before downloading anything: without it the fetch is wasted.
        var decryption: ImageDecryption?
        if let encryption = manifest.image.encryption {
            guard let key = try ImageKeyStore.load(secrets: secrets, keyId: encryption.keyId) else {
                throw DisklesslyError.integrity("\(manifest.name) is encrypted with image key \(encryption.keyId), which this Mac's Keychain does not have. Turn on iCloud Keychain on both Macs or run disklessly images key import.")
            }
            decryption = ImageDecryption(key: key, keyId: encryption.keyId, plainSha256: encryption.plainSha256, plainSize: encryption.plainSize)
        }
        try FileManager.default.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
        let free = try VolumeSpace.availableBytes(at: config.cacheDir)
        // An encrypted image briefly needs the ciphertext and the plaintext side by side.
        let incoming = manifest.image.size + (manifest.image.encryption == nil ? 0 : manifest.image.plainSize)
        guard SpaceFloor.admits(freeBytes: free, incoming: incoming, floor: config.minFreeBytes) else {
            throw DisklesslyError.noSpace("free space \(free) bytes would fall below the \(config.minFreeBytes) byte floor after fetching \(incoming) bytes")
        }
        // Keep the fetched image byte-for-byte identical to the published artifact.
        // The manifest hashes the remote ULMO image; converting it on download both
        // invalidates that identity and relies on hdiutil's output-name conventions.
        try CacheFetcher.materialize(backend: backend, remote: manifest.image.file, destination: cache, partial: paths.partial(manifest.imageId), expectedSize: manifest.image.size, expectedSHA256: manifest.image.sha256, decryption: decryption)
        try rememberVerified(manifest.imageId, file: cache)
        _ = try enforceCacheQuota(justUsed: manifest.imageId)
        return cache
    }

    private func hashCached(_ url: URL) throws -> String {
        if let hasherOverride { return try hasherOverride(url) }
        return try SHA256Digest.hexFile(url)
    }

    private func rememberVerified(_ imageId: String, file: URL) throws {
        guard let finger = try? FileFingerprint.of(url: file) else { return }
        let sha = try hashCached(file)
        try StateStore(config.stateDir).update { state in
            var entry = state.cache[imageId] ?? CacheEntry()
            entry.verified = VerifiedStamp(sha256: sha, fingerprint: finger)
            state.cache[imageId] = entry
        }
    }
    public func launch(_ manifest:ImageManifest, documents:[String]=[], urls:[String]=[], arguments:[String]=[], wait:Bool=true) throws {
        try assertDeviceLaunch(manifest)
        restore.loadConfiguredFaults()
        // The installed engine is what stubs call; Linux has no stubs.
        if HostPlatform.current.offloadsApps, EngineInstall.runningExecutable().lastPathComponent == "disklessly" {
            try installEngine()
        }
        // The app's data comes back first; if it cannot, the app is not opened at all.
        try restore.withLock(manifest.bundleId) { try appDataBeforeLaunch(manifest) }
        let since = Date()
        if manifest.mode == .restore {
            _ = try prefetch(manifest)
            try restore.launch(manifest, documents: documents, urls: urls, arguments: arguments, wait: wait)
            _ = try enforceCacheQuota(justUsed: manifest.imageId)
            if wait { appDataAfterQuit(appId: manifest.bundleId, since: since) }
            return
        }
        let image=try prefetch(manifest)
        #if !os(macOS)
        throw DisklesslyError.unsupported("launch requires macOS hdiutil and Launch Services")
        #else
        let rawMount=URL(fileURLWithPath:config.mountRoot).appendingPathComponent(manifest.imageId)
        try FileManager.default.createDirectory(at:rawMount,withIntermediateDirectories:true)
        let mount=rawMount.resolvingSymlinksInPath().standardizedFileURL
        let app=mount.appendingPathComponent(manifest.image.appPathInVolume)
        let state=StateStore(config.stateDir)
        var handOff = false
        // Held from attach until supervision ends so the reaper never takes a live mount.
        var lease: MountLease?
        defer { lease?.release() }
        try restore.withLock(manifest.bundleId) {
            // Taken before the reuse check too: an existing mount must not be reaped
            // in the window before the app process shows up in the usage probe.
            lease = MountLease.acquire(stateDir: config.stateDir, name: manifest.imageId, waitSeconds: 0.5)
            let recorded = state.load().apps[manifest.bundleId]?.mountPoint
            let info = ProcessRunner.capture("/usr/bin/hdiutil", ["info", "-plist"])
            let listed = recorded.map { DiskImageTool.plistListsMountPoint(Data(info.utf8), $0) } ?? false
            if listed, let recorded, FileManager.default.fileExists(atPath: recorded) {
                let busy = ProcessProbe.usage(roots: [recorded]) == .busy
                let built = OpenInvocation.arguments(app: app.path, documents: documents, urls: urls, arguments: arguments, alreadyRunning: busy)
                for warning in built.warnings { FileHandle.standardError.write(Data("disklessly: \(warning)\n".utf8)) }
                try run(built.argv[0], Array(built.argv.dropFirst()))
                if busy { handOff = true }
                return
            }
            try LiveDiskImage.attach(image: image, mountPoint: mount)
            try state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"running",mountPoint:mount.path)
            let built = OpenInvocation.arguments(app: app.path, documents: documents, urls: urls, arguments: arguments, alreadyRunning: false)
            try run(built.argv[0], Array(built.argv.dropFirst()))
        }
        // Opportunistic, and only once the user's app is open: images a crashed
        // watcher left attached. Fast scan; a recently failed detach is not retried.
        // This process still holds the lease, so its own mount stays excluded.
        for line in reapOrphanMounts(deep: false, excluding: [manifest.imageId], retryAfter: 600).actionLines {
            FileHandle.standardError.write(Data("disklessly: \(line)\n".utf8))
        }
        if handOff { return }
        if !wait {
            // design: `--no-wait` returns once the app runs; a detached supervisor
            // still detaches the image after the app quits.
            // The watcher blocks on the lease until this process returns and lets go.
            do { _ = try ProcessRunner.spawnWatch(appId: manifest.bundleId, stateDir: config.stateDir) }
            catch { FileHandle.standardError.write(Data("disklessly: could not start the detach supervisor: \(error)\n".utf8)) }
            return
        }
        try superviseMount(manifest, app: app, mount: mount)
        appDataAfterQuit(appId: manifest.bundleId, since: since)
        #endif
    }
    #if os(macOS)
    /// Waits for a mount-mode app to quit, then detaches its image after the delay.
    private func superviseMount(_ manifest: ImageManifest, app: URL, mount: URL) throws {
        let state = StateStore(config.stateDir)
        while true {
            Thread.sleep(forTimeInterval:0.5)
            if !Self.isActiveMountPoint(mount.path) {
                // Someone else (another supervisor, a manual detach) already detached it.
                if state.load().apps[manifest.bundleId]?.state == "running" { try state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"cached") }
                return
            }
            let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/pgrep"); p.arguments=["-f",app.appendingPathComponent("Contents/MacOS/"+manifest.app.executable).path]
            p.standardOutput=FileHandle.nullDevice; p.standardError=FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 { continue }
            Thread.sleep(forTimeInterval:Double(config.detachDelaySeconds))
            var detached = false
            // Under the app lock so a concurrent launch cannot open the app mid-detach.
            try restore.withLock(manifest.bundleId) {
                guard Self.isActiveMountPoint(mount.path), ProcessProbe.usage(roots: [mount.path]) != .busy else { return }
                try state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"detaching",mountPoint:mount.path)
                do {
                    try LiveDiskImage.detach(mountPoint: mount, force: false)
                    if !Self.isActiveMountPoint(mount.path) { rmdir(mount.path) }
                    try state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"cached")
                    detached = true
                } catch {
                    try? state.setAppState(bundleId:manifest.bundleId,imageId:manifest.imageId,state:"backoff",mountPoint:mount.path)
                    FileHandle.standardError.write(Data("disklessly: detach failed: \(error)\n".utf8))
                    throw error
                }
            }
            if detached {
                _ = try enforceCacheQuota(justUsed: manifest.imageId)
                return
            }
        }
    }

    /// `hook watch` for a mount-mode app started with `launch --no-wait`.
    func superviseRunningMount(appId: String) throws {
        guard let record = StateStore(config.stateDir).load().apps[appId], record.state == "running",
              let imageId = record.imageId, let mountPath = record.mountPoint,
              let manifest = try list().first(where: { $0.imageId == imageId }), manifest.mode == .mount else { return }
        let mount = URL(fileURLWithPath: mountPath)
        var lease = MountLease.acquire(stateDir: config.stateDir, name: imageId)
        defer { lease?.release() }
        try superviseMount(manifest, app: mount.appendingPathComponent(manifest.image.appPathInVolume), mount: mount)
    }
    private func run(_ path:String,_ args:[String]) throws {
        let p=ParsedCommand.process(path:path, arguments:args)
        let output=Pipe(); p.standardOutput=output; p.standardError=output
        do { try p.run() } catch {
            throw DisklesslyError.failure("Could not start \(path) \(args.joined(separator:" ")): \(error.localizedDescription)")
        }
        let data=output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus==0 else {
            // The tool's own sentence is recorded and not interpreted. hdiutil follows
            // AppleLanguages, so the words are not a stable classifier.
            let detail=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            throw DisklesslyError.diskImage("Command failed: \(path) \(args.joined(separator:" ")) (exit \(p.terminationStatus))\(detail.isEmpty ? "" : "\n\(detail)")")
        }
    }
    #endif
}

/// Bookkeeping for one stub swap. Stored under `pack-journals/`, not `journals/`:
/// `JournalStore.loadAll` decodes every file in `journals/` as a restore
/// transaction and would fail on this schema.
public struct PackJournal: Codable, Equatable {
    public var schema: String
    public var txid: String
    public var appId: String
    /// The app's path. It is also where the stub goes.
    public var source: String
    /// The signed stub before the swap. Right after a `RENAME_SWAP` it holds the original.
    public var temp: String
    /// Where the original sits after the swap until it is retained or deleted.
    public var backup: String
    /// Set when the original is kept as `<Name>.256orig.app`.
    public var retained: String?
    /// `staged`, `originalMoved` (two-rename path only), `swapped`, `parked`.
    public var phase: String
    public var createdAt: Date

    public init(txid: String, appId: String, source: String, temp: String, backup: String, retained: String?, phase: String, createdAt: Date = Date()) {
        self.schema = "pack/1"
        self.txid = txid
        self.appId = appId
        self.source = source
        self.temp = temp
        self.backup = backup
        self.retained = retained
        self.phase = phase
        self.createdAt = createdAt
    }
}

public enum PackJournalStore {
    public static func directory(_ stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("pack-journals")
    }

    public static func file(_ stateDir: String, txid: String) -> URL {
        directory(stateDir).appendingPathComponent("pack-\(txid).json")
    }

    public static func save(_ journal: PackJournal, stateDir: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try DurableIO.atomicWrite(try encoder.encode(journal), to: file(stateDir, txid: journal.txid))
    }

    public static func loadAll(stateDir: String) throws -> [PackJournal] {
        let dir = directory(stateDir)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return try names.filter { $0.hasPrefix("pack-") && $0.hasSuffix(".json") }.sorted().map { name in
            try decoder.decode(PackJournal.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
        }
    }

    public static func remove(stateDir: String, txid: String) throws {
        let url = file(stateDir, txid: txid)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try DurableIO.syncItem(url.deletingLastPathComponent())
        }
    }
}

/// Exchange two directory entries in one step.
enum AtomicSwap {
    /// `true` when the two names were exchanged. `false` when the platform or
    /// filesystem has no exchange (`EINVAL`, `ENOTSUP`), so the caller falls back to
    /// two renames. Any other error throws and nothing was moved.
    static func exchange(_ a: URL, _ b: URL) throws -> Bool {
        #if canImport(Darwin)
        if renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 { return true }
        let code = errno
        if code == EINVAL || code == ENOTSUP { return false }
        throw DisklesslyError.failure("Could not swap \(a.path) and \(b.path): \(String(cString: strerror(code)))")
        #else
        _ = (a, b)
        return false
        #endif
    }
}

enum PackGuard {
    enum Kind: Equatable { case absent, original, stub, other }

    /// A stub is never a pack source. Neither is anything carrying `stub.json`.
    static func refuseStub(_ app: URL, bundleId: String) throws {
        if bundleId.hasSuffix(".256stub") || FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/stub.json").path) {
            throw DisklesslyError.usage("\(app.path) is an disklessly stub, not an app; nothing to pack")
        }
    }

    static func kind(_ url: URL, appId: String) -> Kind {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let identifier = BundleFacts.readInfo(url)?["CFBundleIdentifier"] as? String
        let hasStubJSON = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/stub.json").path)
        if identifier == appId + ".256stub" && hasStubJSON { return .stub }
        if identifier == appId && !hasStubJSON { return .original }
        return .other
    }
}

/// Copies of the manifests embedded in stubs, so a stub rebuild never reads the repo.
enum StubManifestCache {
    static func url(imageId: String, cacheDir: String) -> URL {
        URL(fileURLWithPath: cacheDir).appendingPathComponent("manifests/\(imageId).json")
    }

    static func store(_ data: Data, imageId: String, cacheDir: String) {
        guard AppIcon.isSafeImageId(imageId) else { return }
        let target = url(imageId: imageId, cacheDir: cacheDir)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }

    static func load(imageId: String, cacheDir: String) -> Data? {
        guard AppIcon.isSafeImageId(imageId) else { return nil }
        return try? Data(contentsOf: url(imageId: imageId, cacheDir: cacheDir))
    }
}

extension DisklesslyEngine {
    /// Swap a signed stub in for the app at `source`. Runs under the app lock and
    /// re-checks the app first: still the same bundle, not a stub, not running, no
    /// open restore journal, and unchanged since it was cloned. A refusal deletes
    /// the staged stub and leaves the app alone. The swap is journaled so a crash
    /// at any point leaves something `recoverPackJournals` can put back.
    func commitStub(staged temp: URL, source: URL, bundleId: String, name: String, cloneFingerprint: String, keepOriginal: Bool) throws -> String? {
        let fm = FileManager.default
        let parent = source.deletingLastPathComponent()
        let retained = parent.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".256orig.app")
        return try restore.withLock(bundleId) { () -> String? in
            let txid = UUID().uuidString.lowercased()
            let backup = parent.appendingPathComponent(".disklessly-original-\(txid).app")
            var journal = PackJournal(txid: txid, appId: bundleId, source: source.path, temp: temp.path, backup: backup.path, retained: keepOriginal ? retained.path : nil, phase: "staged")
            do {
                try recheckPackSource(source, bundleId: bundleId, name: name, cloneFingerprint: cloneFingerprint)
                if keepOriginal, fm.fileExists(atPath: retained.path) {
                    throw DisklesslyError.failure("Could not retain original app at \(retained.path): it already exists")
                }
                try PackJournalStore.save(journal, stateDir: config.stateDir)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
            try faults.hit("pack.staged", "afterJournal")
            let swapped: Bool
            do {
                try failureInjector?("pack.staged")
                swapped = packSwapUnsupported ? false : try AtomicSwap.exchange(temp, source)
            } catch {
                try? fm.removeItem(at: temp)
                try? PackJournalStore.remove(stateDir: config.stateDir, txid: txid)
                throw error
            }
            if swapped {
                // source is the stub now and temp is the original.
                try? DurableIO.syncItem(parent)
                try faults.hit("pack.swapped", "afterMutation")
                journal.phase = "swapped"
                do { try PackJournalStore.save(journal, stateDir: config.stateDir) }
                catch { try rollbackPack(journal); throw error }
                try faults.hit("pack.swapped", "afterJournal")
                do {
                    try failureInjector?("pack.swapped")
                    try fm.moveItem(at: temp, to: backup)
                } catch {
                    try rollbackPack(journal)
                    throw DisklesslyError.failure("Could not move original app to transaction backup \(backup.path): \(error.localizedDescription)")
                }
            } else {
                do {
                    try fm.moveItem(at: source, to: backup)
                } catch {
                    try? fm.removeItem(at: temp)
                    try? PackJournalStore.remove(stateDir: config.stateDir, txid: txid)
                    throw DisklesslyError.failure("Could not move original app to transaction backup \(backup.path): \(error.localizedDescription)")
                }
                try faults.hit("pack.originalMoved", "afterMutation")
                journal.phase = "originalMoved"
                do { try PackJournalStore.save(journal, stateDir: config.stateDir) }
                catch { try rollbackPack(journal); throw error }
                try faults.hit("pack.originalMoved", "afterJournal")
                do {
                    try failureInjector?("pack.originalMoved")
                    try fm.moveItem(at: temp, to: source)
                } catch {
                    try rollbackPack(journal)
                    throw DisklesslyError.failure("Could not install signed stub at \(source.path): \(error.localizedDescription)")
                }
            }
            try? DurableIO.syncItem(parent)
            journal.phase = "parked"
            do { try PackJournalStore.save(journal, stateDir: config.stateDir) }
            catch { try rollbackPack(journal); throw error }
            try faults.hit("pack.parked", "afterJournal")
            var warning: String? = nil
            if keepOriginal {
                do {
                    try failureInjector?("pack.retain")
                    try fm.moveItem(at: backup, to: retained)
                } catch {
                    try rollbackPack(journal)
                    throw DisklesslyError.failure("Could not retain original app at \(retained.path): \(error.localizedDescription)")
                }
            } else {
                do { try fm.removeItem(at: backup) }
                catch { warning = BackupRemoval.warning(backupPath: backup.path) }
            }
            try? PackJournalStore.remove(stateDir: config.stateDir, txid: txid)
            return warning
        }
    }

    private func recheckPackSource(_ source: URL, bundleId: String, name: String, cloneFingerprint: String) throws {
        guard let info = BundleFacts.readInfo(source), let current = info["CFBundleIdentifier"] as? String else {
            throw DisklesslyError.busy("\(source.path) is gone or is no longer an app bundle; nothing was replaced")
        }
        try PackGuard.refuseStub(source, bundleId: current)
        guard current == bundleId else {
            throw DisklesslyError.busy("\(source.path) is now \(current), not \(bundleId); pack again")
        }
        let usage = packUsageOverride?(source.path) ?? ProcessProbe.usage(roots: [source.path])
        if let blocked = PackPreflight.running(usage, name: name) { throw blocked }
        if let reason = restore.blockReason(appId: bundleId) { throw DisklesslyError.busy(reason) }
        guard try TreeFingerprint.of(source) == cloneFingerprint else {
            throw DisklesslyError.busy("\(name) changed while it was being packed; the original was left alone. Pack again.")
        }
    }

    /// Undo a swap in progress: the original goes back to `source` and the stub is deleted.
    private func rollbackPack(_ journal: PackJournal) throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: journal.source)
        let temp = URL(fileURLWithPath: journal.temp)
        let backup = URL(fileURLWithPath: journal.backup)
        guard let original = [temp, backup].first(where: { PackGuard.kind($0, appId: journal.appId) == .original }) else {
            throw DisklesslyError.failure("pack of \(journal.appId) cannot find the original to roll back; the journal \(PackJournalStore.file(config.stateDir, txid: journal.txid).path) is kept")
        }
        switch PackGuard.kind(source, appId: journal.appId) {
        case .stub:
            if (try? AtomicSwap.exchange(original, source)) == true {
                // `original` now names the stub.
                try? fm.removeItem(at: original)
            } else {
                try fm.removeItem(at: source)
                try fm.moveItem(at: original, to: source)
            }
        case .absent:
            try fm.moveItem(at: original, to: source)
        case .original, .other:
            throw DisklesslyError.failure("pack of \(journal.appId) found an unexpected bundle at \(source.path); the journal is kept")
        }
        try? DurableIO.syncItem(source.deletingLastPathComponent())
        for leftover in [temp, backup] where PackGuard.kind(leftover, appId: journal.appId) == .stub {
            try? fm.removeItem(at: leftover)
        }
        try PackJournalStore.remove(stateDir: config.stateDir, txid: journal.txid)
    }

    /// Replay open pack journals. `gc` and `doctor --fix` call this. A journal whose
    /// app lock is held belongs to a pack that is still running and is skipped.
    @discardableResult
    public func recoverPackJournals() throws -> [String] {
        let journals = try PackJournalStore.loadAll(stateDir: config.stateDir)
        var lines: [String] = []
        for journal in journals {
            let directory = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/app")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var lock = FileLock(path: directory.appendingPathComponent(journal.appId + ".lock").path)
            guard try lock.tryLock() else {
                lines.append("pack \(journal.txid) is still running")
                continue
            }
            defer { lock.unlock() }
            lines.append(try recoverPack(journal))
        }
        return lines
    }

    private func recoverPack(_ journal: PackJournal) throws -> String {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: journal.source)
        let temp = URL(fileURLWithPath: journal.temp)
        let backup = URL(fileURLWithPath: journal.backup)
        let retained = journal.retained.map { URL(fileURLWithPath: $0) }
        let original = [temp, backup].first { PackGuard.kind($0, appId: journal.appId) == .original }
        func dropStubLeftovers() {
            for leftover in [temp, backup] where PackGuard.kind(leftover, appId: journal.appId) == .stub {
                try? fm.removeItem(at: leftover)
            }
        }
        switch PackGuard.kind(source, appId: journal.appId) {
        case .absent:
            guard let original else {
                return "pack \(journal.appId) needs attention: \(source.path) is empty and the original is at neither \(temp.path) nor \(backup.path)"
            }
            try fm.moveItem(at: original, to: source)
            try? DurableIO.syncItem(source.deletingLastPathComponent())
            dropStubLeftovers()
            try PackJournalStore.remove(stateDir: config.stateDir, txid: journal.txid)
            return "restored original for pack \(journal.txid) at \(source.path)"
        case .original:
            dropStubLeftovers()
            try PackJournalStore.remove(stateDir: config.stateDir, txid: journal.txid)
            return "rolled back pack \(journal.txid)"
        case .stub:
            // The stub is signed and in place, and the image was published before the
            // swap. Finish what pack started.
            if let original {
                if let retained {
                    if fm.fileExists(atPath: retained.path) {
                        return "pack \(journal.appId) needs attention: the original is at \(original.path) and \(retained.path) already exists"
                    }
                    try fm.moveItem(at: original, to: retained)
                } else if original.path != backup.path {
                    try fm.moveItem(at: original, to: backup)
                }
            }
            var line = "finished pack \(journal.txid)"
            if retained == nil, PackGuard.kind(backup, appId: journal.appId) == .original {
                do { try fm.removeItem(at: backup) }
                catch { line = BackupRemoval.warning(backupPath: backup.path) }
            }
            try PackJournalStore.remove(stateDir: config.stateDir, txid: journal.txid)
            return line
        case .other:
            return "pack \(journal.appId) needs attention: \(source.path) is neither the app nor its stub"
        }
    }
}
