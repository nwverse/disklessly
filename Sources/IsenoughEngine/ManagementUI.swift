import Foundation
import IsenoughCore

/// Local management page and JSON API. The loopback server checks the token
/// before this runs, so every page and `/api` call already presented it.
public enum ManagementUI {
    /// Process-wide jobs and scan cache used by `isenough ui`.
    public static let shared = ManagementUIContext()

    public static func respond(engine: IsenoughEngine, webRoot: URL?, request: UIRequest) -> UIResponse {
        respond(engine: engine, webRoot: webRoot, request: request, context: shared)
    }

    public static func respond(engine: IsenoughEngine, webRoot: URL?, request: UIRequest, context: ManagementUIContext) -> UIResponse {
        if request.path.hasPrefix("/api/") { return api(engine: engine, request: request, context: context) }
        return staticFile(webRoot: webRoot, request: request)
    }

    public static func dashboard(_ engine: IsenoughEngine) -> [String: Any] {
        dashboard(engine, context: shared)
    }

    public static func dashboard(_ engine: IsenoughEngine, context: ManagementUIContext) -> [String: Any] {
        var apps: [[String: Any]] = []
        var appsError = ""
        let isoFormatter = ISO8601DateFormatter()
        let loaded = StateStore(engine.config.stateDir).load()
        let state = loaded.dictionary()
        let stored = state["apps"] as? [String: [String: Any]] ?? [:]
        let loadedApps = UbiquitousMaterializer.withBudget(ICloudLimits.metadataTimeout()) { () -> (DeviceListing?, [ImageManifest], String) in
            let listing = try? engine.deviceListing(createLocal: false)
            do {
                return (listing, try engine.list(), "")
            } catch {
                return (listing, [], (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        let listing = loadedApps.0
        let deviceRows = listing?.devices ?? []
        let manifests = loadedApps.1
        appsError = loadedApps.2
        for manifest in manifests {
                let cached = URL(fileURLWithPath: engine.config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg")
                let exists = FileManager.default.fileExists(atPath: cached.path)
                let size = exists ? ((try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0) : 0
                let restoredMap = state["restored"] as? [String: Any] ?? [:]
                let record = loaded.apps[manifest.bundleId]
                var appState = record?.state ?? ""
                if let pending = record?.needsResolution, !pending.isEmpty { appState = "needsResolution" }
                let restored = restoredMap[manifest.bundleId] != nil || appState == "restored" || appState == "needsResolution"
                // Other Macs that hold this image ("Also on …"); this Mac is not listed.
                let holders = deviceRows.filter { device in
                    device.deviceId != listing?.localDeviceId && device.images.contains { $0.imageId == manifest.imageId }
                }.map(\.displayName)
                var row: [String: Any] = [
                    "imageId": manifest.imageId,
                    "bundleId": manifest.bundleId,
                    "name": manifest.name,
                    "version": manifest.version,
                    "build": manifest.build,
                    "architectures": manifest.architectures,
                    "mode": manifest.mode.rawValue,
                    "pinned": stored[manifest.bundleId]?["pinned"] as? Bool ?? false,
                    "cached": exists,
                    "remote": !exists,
                    "restored": restored,
                    "state": appState,
                    "needsResolution": appState == "needsResolution",
                    "mounted": appState == "running",
                    "cachedBytes": NSNumber(value: size),
                    "imageBytes": NSNumber(value: manifest.image.size),
                    "devices": holders,
                    "iconPath": AppIcon.existingPath(stateDir: engine.config.stateDir, repoPath: engine.config.repoPath, imageId: manifest.imageId) ?? "",
                ]
                if let used = record?.lastUsed { row["lastUsed"] = isoFormatter.string(from: used) }
                apps.append(row)
        }
        let index = (try? SessionArchive.loadIndex(engine.config.stateDir)) ?? SessionIndex()
        let formatter = ISO8601DateFormatter()
        let sessions: [[String: Any]] = index.entries.map { entry in
            [
                "id": entry.id,
                "tool": entry.tool,
                "path": entry.path,
                "preview": entry.preview,
                "archive": entry.archive,
                "tier": "cold",
                "modified": formatter.string(from: entry.modified),
            ]
        }
        let endpoints: [[String: Any]] = engine.config.backends.map { endpoint in
            [
                "id": endpoint.id,
                "type": endpoint.type,
                "host": endpoint.host ?? "",
                "mountPoint": endpoint.mountPoint ?? "",
                "url": endpoint.url ?? "",
            ]
        }
        let health = backendHealth(engine)
        return [
            "ok": true,
            "backend": [
                "kind": engine.config.backend,
                "activeId": engine.config.activeBackendId ?? "",
                "repoPath": engine.config.repoPath,
                "health": health.status,
                "healthDetail": health.detail,
                "endpoints": endpoints,
            ] as [String: Any],
            "cache": [
                "usedBytes": NSNumber(value: directoryBytes(engine.config.cacheDir)),
                "quotaBytes": NSNumber(value: engine.config.quotaBytes),
                "minFreeBytes": NSNumber(value: engine.config.minFreeBytes),
                "detachDelaySeconds": NSNumber(value: engine.config.detachDelaySeconds),
            ] as [String: Any],
            "apps": apps,
            "appsError": appsError,
            "devices": deviceRows.map { device in
                [
                    "deviceId": device.deviceId,
                    "displayName": device.displayName,
                    "hostname": device.hostname,
                    "arch": device.arch,
                    "osVersion": device.osVersion,
                    "lastSeen": formatter.string(from: device.lastSeen),
                    "self": device.deviceId == listing?.localDeviceId,
                    "images": device.images.map { ["imageId": $0.imageId, "bundleId": $0.bundleId, "version": $0.version, "architectures": $0.architectures, "mode": $0.mode] },
                ] as [String: Any]
            },
            "jobs": context.jobs.active().map { $0.jsonObject() },
            "devicePlaceholders": listing?.placeholders ?? [],
            "deviceConflicts": listing?.conflicts ?? [],
            "sessions": [
                "coldDays": NSNumber(value: engine.config.sessionColdDays),
                "offloaded": sessions,
            ] as [String: Any],
        ]
    }

    private static func api(engine: IsenoughEngine, request: UIRequest, context: ManagementUIContext) -> UIResponse {
        if request.method == "GET", request.path.hasPrefix("/api/icon/") {
            guard let imageId = AppIcon.imageId(apiPath: request.path) else { return .text(404, "not found") }
            let body = AppIcon.png(stateDir: engine.config.stateDir, repoPath: engine.config.repoPath, imageId: imageId)
            return UIResponse(status: 200, contentType: "image/png", body: body)
        }
        if request.method == "GET", request.path.hasPrefix("/api/jobs/") {
            let id = String(request.path.dropFirst("/api/jobs/".count))
            guard let job = context.jobs.job(id) else {
                return failure(code: "unknown_job", message: "No job with id \(id)", status: 404)
            }
            var object = job.jsonObject()
            object["ok"] = true
            return .json(object)
        }
        if request.method == "POST", let kind = UIJobKind(path: request.path) {
            guard let name = appName(request) else { return failure(code: "bad_request", message: "app is required", status: 400) }
            let actions = context.actions ?? .live(engine)
            switch context.jobs.start(kind: kind, app: name, work: { progress in try actions.run(kind, name, progress) }) {
            case .started(let job):
                var object = job.jsonObject()
                object["ok"] = true
                object["jobId"] = job.id
                return .json(object, status: 202)
            case .busy(let job):
                var object = failureObject(code: "busy", message: "\(job.app) already has a \(job.kind.rawValue) job running")
                object["jobId"] = job.id
                return .json(object, status: 409)
            }
        }
        switch (request.method, request.path) {
        case ("GET", "/api/status"):
            return .json(dashboard(engine, context: context))
        case ("GET", "/api/jobs"):
            return .json(["ok": true, "jobs": context.jobs.all().map { $0.jsonObject() }])
        case ("GET", "/api/recommend"):
            do {
                let arguments = try RecommendArguments.parse(query: request.query)
                let rescan = ["1", "true", "yes"].contains((request.query["rescan"] ?? "").lowercased())
                let cached = context.recommendations(key: recommendKey(engine, request.query), rescan: rescan) {
                    engine.recommend(options: arguments.options()).jsonObject()
                }
                var object = cached.report
                object["scannedAt"] = ISO8601DateFormatter().string(from: cached.scannedAt)
                object["cached"] = cached.fromCache
                return .json(object)
            } catch {
                return failure(error, status: 400)
            }
        case ("POST", "/api/icons/backfill"):
            do {
                let report = try engine.backfillIcons(appId: request.query["app"])
                return .json(["ok": true, "updated": report.updated, "skipped": report.skipped, "warnings": report.warnings])
            } catch {
                return failure(error, status: error is IsenoughError ? 400 : 500)
            }
        default:
            return .text(404, "not found")
        }
    }

    /// Stable error code and readable message. The page maps the code to localized text.
    public static func errorInfo(_ error: Error) -> (code: String, message: String) {
        if let error = error as? UIJobError {
            switch error {
            case .unknownApp(let name): return ("unknown_app", "Unknown app: \(name)")
            }
        }
        if let error = error as? IsenoughError {
            let message = error.errorDescription ?? String(describing: error)
            switch error {
            case .backend: return ("offline", message)
            case .integrity: return ("integrity", message)
            case .noSpace: return ("no_space", message)
            case .busy: return ("busy", message)
            case .usage: return ("bad_request", message)
            case .unsupported: return ("unsupported", message)
            case .resolution: return ("needs_resolution", message)
            case .diskImage, .failure, .hook: return ("failed", message)
            }
        }
        let nsError = error as NSError
        if (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError) {
            return ("no_space", nsError.localizedDescription)
        }
        if nsError.domain == NSURLErrorDomain { return ("offline", nsError.localizedDescription) }
        return ("failed", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private static func failure(_ error: Error, status: Int) -> UIResponse {
        let info = errorInfo(error)
        return failure(code: info.code, message: info.message, status: status)
    }

    private static func failure(code: String, message: String, status: Int) -> UIResponse {
        .json(failureObject(code: code, message: message), status: status)
    }

    private static func failureObject(code: String, message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }

    private static func recommendKey(_ engine: IsenoughEngine, _ query: [String: String]) -> String {
        let relevant = query.filter { !["token", "rescan", "_"].contains($0.key) }
        let options = relevant.keys.sorted().map { "\($0)=\(relevant[$0] ?? "")" }.joined(separator: "&")
        return engine.config.stateDir + "?" + options
    }

    private static func appName(_ request: UIRequest) -> String? {
        if let query = request.query["app"], !query.isEmpty { return query }
        if let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
           let app = object["app"] as? String, !app.isEmpty {
            return app
        }
        return nil
    }

    private static func staticFile(webRoot: URL?, request: UIRequest) -> UIResponse {
        guard let webRoot else { return .text(404, "web assets are not installed") }
        let name: String
        switch request.path {
        case "/", "/index.html", "/ui", "/ui/": name = "index.html"
        case "/app.js", "/ui/app.js": name = "app.js"
        case "/style.css", "/ui/style.css": name = "style.css"
        default: return .text(404, "not found")
        }
        let file = webRoot.appendingPathComponent(name)
        guard file.path.hasPrefix(webRoot.path), let data = try? Data(contentsOf: file) else { return .text(404, "not found") }
        let type: String
        switch name {
        case "index.html": type = "text/html; charset=utf-8"
        case "app.js": type = "text/javascript; charset=utf-8"
        default: type = "text/css; charset=utf-8"
        }
        if name == "index.html", let token = request.token, var html = String(data: data, encoding: .utf8) {
            let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?#+"))) ?? token
            html = html.replacingOccurrences(of: "href=\"style.css\"", with: "href=\"style.css?token=\(encoded)\"")
            html = html.replacingOccurrences(of: "src=\"app.js\"", with: "src=\"app.js?token=\(encoded)\"")
            return UIResponse(status: 200, contentType: type, body: Data(html.utf8))
        }
        return UIResponse(status: 200, contentType: type, body: data)
    }

    private static func backendHealth(_ engine: IsenoughEngine) -> (status: String, detail: String) {
        do {
            let backend = try engine.openBackend()
            if try backend.stat("repo.json") != nil {
                return ("ok", "")
            }
            return ("missing", "repo.json is not in the backend")
        } catch {
            return ("offline", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func directoryBytes(_ path: String) -> UInt64 {
        let root = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - Background jobs

/// Actions the page starts with `POST /api/<kind>`. Each runs as a job so the
/// request returns at once and the page polls `GET /api/jobs/:id`.
public enum UIJobKind: String, CaseIterable {
    case launch, prefetch, evict, restore, unpack, pin, unpin

    public init?(path: String) {
        guard path.hasPrefix("/api/") else { return nil }
        self.init(rawValue: String(path.dropFirst("/api/".count)))
    }
}

public enum UIJobError: Error, Equatable {
    case unknownApp(String)
}

public enum UIJobState: String {
    case running, done, failed
}

public struct UIJobSnapshot {
    public var id: String
    public var kind: UIJobKind
    public var app: String
    public var state: UIJobState
    public var phase: String
    public var errorCode: String?
    public var errorMessage: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public func jsonObject() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "app": app,
            "state": state.rawValue,
            "phase": phase,
            "startedAt": formatter.string(from: startedAt),
        ]
        if let finishedAt { object["finishedAt"] = formatter.string(from: finishedAt) }
        if let errorCode { object["error"] = ["code": errorCode, "message": errorMessage ?? ""] }
        return object
    }
}

/// Lets a running action report its phase (`resolve`, `download`, `open`, ...).
public final class UIJobProgress {
    private let update: (String) -> Void
    init(_ update: @escaping (String) -> Void) { self.update = update }
    public func phase(_ name: String) { update(name) }
}

public final class UIJobStore {
    public enum StartResult {
        case started(UIJobSnapshot)
        /// The app already has a running job; it is returned instead of starting a second one.
        case busy(UIJobSnapshot)
    }

    private let lock = NSLock()
    private var jobs: [String: UIJobSnapshot] = [:]
    private var order: [String] = []
    private let retained: Int
    private let queue: DispatchQueue

    public init(retained: Int = 200, queue: DispatchQueue = .global(qos: .userInitiated)) {
        self.retained = retained
        self.queue = queue
    }

    public func start(kind: UIJobKind, app: String, work: @escaping (UIJobProgress) throws -> Void) -> StartResult {
        lock.lock()
        let key = app.lowercased()
        if let running = order.compactMap({ jobs[$0] }).first(where: { $0.state == .running && $0.app.lowercased() == key }) {
            lock.unlock()
            return .busy(running)
        }
        let job = UIJobSnapshot(id: UUID().uuidString.lowercased(), kind: kind, app: app, state: .running, phase: "queued", startedAt: Date())
        jobs[job.id] = job
        order.append(job.id)
        prune()
        lock.unlock()
        let id = job.id
        queue.async { [self] in
            let progress = UIJobProgress { [weak self] phase in self?.mutate(id) { $0.phase = phase } }
            do {
                try work(progress)
                mutate(id) {
                    $0.state = .done
                    $0.finishedAt = Date()
                }
            } catch {
                let info = ManagementUI.errorInfo(error)
                mutate(id) {
                    $0.state = .failed
                    $0.errorCode = info.code
                    $0.errorMessage = info.message
                    $0.finishedAt = Date()
                }
            }
        }
        return .started(job)
    }

    public func job(_ id: String) -> UIJobSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]
    }

    public func active() -> [UIJobSnapshot] {
        all().filter { $0.state == .running }
    }

    public func all() -> [UIJobSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { jobs[$0] }
    }

    /// Polls until the job leaves `running` or the timeout passes.
    public func wait(_ id: String, timeout: TimeInterval) -> UIJobSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let current = job(id)
            if current == nil || current?.state != .running || Date() >= deadline { return current }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func mutate(_ id: String, _ change: (inout UIJobSnapshot) -> Void) {
        lock.lock()
        if var job = jobs[id] {
            change(&job)
            jobs[id] = job
        }
        lock.unlock()
    }

    /// Caller holds the lock. Finished jobs past the limit are dropped, oldest first.
    private func prune() {
        guard order.count > retained else { return }
        var excess = order.count - retained
        order.removeAll { id in
            guard excess > 0, let job = jobs[id], job.state != .running else { return false }
            excess -= 1
            jobs.removeValue(forKey: id)
            return true
        }
    }
}

/// What each job does. Tests pass their own `run`; `isenough ui` uses `live`.
public struct ManagementActions {
    public var run: (UIJobKind, String, UIJobProgress) throws -> Void

    public init(run: @escaping (UIJobKind, String, UIJobProgress) throws -> Void) {
        self.run = run
    }

    public static func live(_ engine: IsenoughEngine) -> ManagementActions {
        ManagementActions { kind, name, progress in
            progress.phase("resolve")
            guard var manifest = engine.manifest(named: name, in: try engine.list()) else { throw UIJobError.unknownApp(name) }
            switch kind {
            case .prefetch:
                progress.phase("download")
                _ = try engine.prefetch(manifest)
            case .launch, .restore:
                if kind == .restore { manifest.mode = .restore }
                progress.phase("download")
                _ = try engine.prefetch(manifest)
                progress.phase("open")
                try launchSupervised(engine, manifest)
                progress.phase("running")
            case .evict:
                progress.phase("evict")
                // The dashboard has no --force, so say what to do here instead.
                if engine.evictRefusal(manifest, force: false)?.reason == "pinned" {
                    throw IsenoughError.busy("\(manifest.name) is pinned; unpin it first")
                }
                try engine.evict(manifest)
            case .unpack:
                progress.phase("unpack")
                try engine.unpack(manifest, to: nil)
            case .pin:
                progress.phase("download")
                try engine.setPinned(manifest, pinned: true)
            case .unpin:
                progress.phase("pin")
                try engine.setPinned(manifest, pinned: false)
            }
        }
    }

    /// `launch` keeps supervising the session until the app quits, then
    /// detaches. That supervision stays on its own thread; the job finishes
    /// once the app is open (state `running`, or a restore mirror in restore
    /// mode), or when `launch` returns or throws first.
    static func launchSupervised(_ engine: IsenoughEngine, _ manifest: ImageManifest) throws {
        let store = StateStore(engine.config.stateDir)
        let opened: () -> Bool = {
            let state = store.load()
            if manifest.mode == .restore { return state.restored[manifest.bundleId] != nil }
            return state.apps[manifest.bundleId]?.state == "running"
        }
        let alreadyOpen = opened()
        let finished = DispatchSemaphore(value: 0)
        let outcome = LaunchOutcome()
        let worker = Thread {
            do { try engine.launch(manifest) } catch {
                outcome.set(error)
                if outcome.detached { FileHandle.standardError.write(Data("isenough ui: \(manifest.name): \(error)\n".utf8)) }
            }
            finished.signal()
        }
        worker.name = "isenough.ui.launch"
        worker.start()
        while true {
            if finished.wait(timeout: .now() + 0.25) == .success {
                if let error = outcome.error { throw error }
                return
            }
            if !alreadyOpen, opened() {
                outcome.detach()
                return
            }
        }
    }
}

private final class LaunchOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var isDetached = false
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    var detached: Bool { lock.lock(); defer { lock.unlock() }; return isDetached }
    func set(_ error: Error) { lock.lock(); storedError = error; lock.unlock() }
    func detach() { lock.lock(); isDetached = true; lock.unlock() }
}

/// Shared state for one management server: running jobs and the last scan.
public final class ManagementUIContext {
    public let jobs: UIJobStore
    /// Replaces the engine-backed actions, for tests.
    public let actions: ManagementActions?
    private let now: () -> Date
    private let lock = NSLock()
    private let scanLock = NSLock()
    private var recommendCache: [String: (report: [String: Any], scannedAt: Date)] = [:]

    public init(jobs: UIJobStore = UIJobStore(), actions: ManagementActions? = nil, now: @escaping () -> Date = Date.init) {
        self.jobs = jobs
        self.actions = actions
        self.now = now
    }

    /// Returns the cached scan for `key` unless `rescan` is set. One scan runs at a time.
    public func recommendations(key: String, rescan: Bool, compute: () -> [String: Any]) -> (report: [String: Any], scannedAt: Date, fromCache: Bool) {
        if !rescan, let hit = cached(key) { return (hit.report, hit.scannedAt, true) }
        scanLock.lock()
        defer { scanLock.unlock() }
        // Another request may have finished the same scan while this one waited.
        if !rescan, let hit = cached(key) { return (hit.report, hit.scannedAt, true) }
        let report = compute()
        let stamp = now()
        lock.lock()
        recommendCache[key] = (report, stamp)
        lock.unlock()
        return (report, stamp, false)
    }

    private func cached(_ key: String) -> (report: [String: Any], scannedAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        return recommendCache[key]
    }
}
