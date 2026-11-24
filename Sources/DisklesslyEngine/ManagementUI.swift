import Foundation
import DisklesslyCore

/// Local management page and JSON API. The loopback server checks the token
/// before this runs, so every page and `/api` call already presented it.
public enum ManagementUI {
    /// Process-wide jobs and scan cache used by `disklessly ui`.
    public static let shared = ManagementUIContext()

    public static func respond(engine: DisklesslyEngine, webRoot: URL?, request: UIRequest) -> UIResponse {
        respond(engine: engine, webRoot: webRoot, request: request, context: shared)
    }

    public static func respond(engine: DisklesslyEngine, webRoot: URL?, request: UIRequest, context: ManagementUIContext) -> UIResponse {
        var engine = engine
        // The page can switch the repo; later requests use the saved config.
        if let config = context.updatedConfig() { engine.config = config }
        if request.path.hasPrefix("/api/cloud") || request.path.hasPrefix("/api/openlist") {
            return cloudAPI(engine: engine, request: request, context: context)
        }
        if request.path.hasPrefix("/api/machines") {
            return machinesAPI(engine: engine, request: request, context: context)
        }
        if request.path.hasPrefix("/api/") { return api(engine: engine, request: request, context: context) }
        return staticFile(webRoot: webRoot, request: request)
    }

    public static func dashboard(_ engine: DisklesslyEngine) -> [String: Any] {
        dashboard(engine, context: shared)
    }

    public static func dashboard(_ engine: DisklesslyEngine, context: ManagementUIContext) -> [String: Any] {
        var apps: [[String: Any]] = []
        var appsError = ""
        var appsErrorCode = ""
        let isoFormatter = ISO8601DateFormatter()
        let loaded = StateStore(engine.config.stateDir).load()
        let state = loaded.dictionary()
        let stored = state["apps"] as? [String: [String: Any]] ?? [:]
        // Probe first (bounded by its timeout). An offline backend would make the
        // listing below block for the transport's own timeout, so skip it and show
        // the Error state at once instead of a page stuck on Loading.
        let health = context.health.current(engine)
        let loadedApps = health.status == "offline"
            ? (nil, [], (code: "offline", message: health.detail.isEmpty ? "The backend is unreachable." : health.detail))
            : UbiquitousMaterializer.withBudget(ICloudLimits.metadataTimeout()) { () -> (DeviceListing?, [ImageManifest], (code: String, message: String)) in
            let listing = try? engine.deviceListing(createLocal: false)
            do {
                return (listing, try engine.list(), ("", ""))
            } catch {
                // Same codes as API failures: only `offline` means the backend is unreachable.
                return (listing, [], errorInfo(error))
            }
        }
        let listing = loadedApps.0
        let deviceRows = listing?.devices ?? []
        let manifests = loadedApps.1
        appsError = loadedApps.2.message
        appsErrorCode = loadedApps.2.code
        // The repo is shared by every Mac, so say per row what this Mac actually has.
        let home = NSHomeDirectory()
        let localApps = LocalAppIndex(folders: Array(Set([engine.config.stubDir, "/Applications", home + "/Applications"])))
        let ownImageIds = Set(deviceRows.first { $0.deviceId == listing?.localDeviceId }?.images.map(\.imageId) ?? [])
        let dataRecords = engine.appDataStore.load()
        var cloudApps: [CloudUsageInputs.App] = []
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
                    // Where the stub lives and where a permanent restore puts the app.
                    "installPath": manifest.app.originalPath,
                    "local": localApps.presence(bundleId: manifest.bundleId, imageId: manifest.imageId, ownImageIds: ownImageIds).jsonObject,
                ]
                if let data = dataRecords[manifest.bundleId], data.enabled || data.state == .offloaded {
                    var object: [String: Any] = ["enabled": data.enabled, "state": data.state.rawValue, "bytes": NSNumber(value: data.bytes)]
                    if let error = data.lastError { object["lastError"] = error }
                    row["data"] = object
                }
                if let used = record?.lastUsed { row["lastUsed"] = isoFormatter.string(from: used) }
                apps.append(row)
                let presence = localApps.presence(bundleId: manifest.bundleId, imageId: manifest.imageId, ownImageIds: ownImageIds)
                if let cloudApp = CloudUsage.appItem(manifest, presence: presence, cachedBytes: size, lastUsed: record?.lastUsed, holders: holders) {
                    cloudApps.append(cloudApp)
                }
        }
        // Only a listing that worked replaces the catalog the cloud side of the usage map reads.
        if appsErrorCode.isEmpty, health.status != "offline" {
            context.setCloudCatalog(CloudAppCatalog(apps: cloudApps, listedAt: Date()))
        }
        let archived = ((try? SessionArchive.archivedEntries(config: engine.config)) ?? []).sorted { $0.modified > $1.modified }
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let sessions: [[String: Any]] = archived.map { entry in
            // Only cold files are ever archived, so every indexed entry is cold.
            return [
                "id": entry.id,
                "tool": entry.tool,
                "path": entry.path,
                "displayPath": homeRelative(entry.path),
                "preview": entry.preview,
                "title": sessionTitle(entry),
                "archive": entry.archive,
                "hasDigest": FileManager.default.fileExists(atPath: SessionArchive.digestURL(config: engine.config, id: entry.id).path),
                "tier": "cold",
                "ageDays": NSNumber(value: sessionAgeDays(modified: entry.modified, now: now)),
                "modified": formatter.string(from: entry.modified),
            ]
        }
        let used = directoryBytes(engine.config.cacheDir)
        let quota = engine.config.quotaBytes
        var cache: [String: Any] = [
            "usedBytes": NSNumber(value: used),
            "quotaBytes": NSNumber(value: quota),
            "minFreeBytes": NSNumber(value: engine.config.minFreeBytes),
            "detachDelaySeconds": NSNumber(value: engine.config.detachDelaySeconds),
            "quotaLeftBytes": NSNumber(value: quota > used ? quota - used : 0),
            "level": cacheLevel(used: used, quota: quota),
        ]
        if let diskFree = diskFreeBytes(engine.config.cacheDir) {
            cache["diskFreeBytes"] = NSNumber(value: diskFree)
            // The floor is free disk space, not a cache size. On the 0...quota axis it sits
            // where cache growth would push free disk space below the floor.
            if let marker = floorMarker(used: used, diskFree: diskFree, floor: engine.config.minFreeBytes, quota: quota) {
                cache["floorMarkerBytes"] = NSNumber(value: marker)
            }
        }
        return [
            "ok": true,
            "platform": context.platform.rawValue,
            "backend": backendInfo(engine, health: health),
            "cache": cache,
            "apps": apps,
            "linkedBundles": engine.linkedBundleStore.load().map { $0.jsonObject() },
            "appsError": appsError,
            "appsErrorCode": appsErrorCode,
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
            "generatedAt": formatter.string(from: now),
        ]
    }

    /// The cloud side of the usage map: what the repo holds for this Mac, from the local catalog and
    /// state only. `reachable` is the last health result; nothing here waits on the backend.
    static func cloudUsageObject(_ engine: DisklesslyEngine, context: ManagementUIContext) -> [String: Any] {
        let catalog = context.cloudCatalog()
        let tree = CloudUsage.assemble(CloudUsage.inputs(engine: engine, apps: catalog?.apps ?? []))
        let health = context.health.last(engine)
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "ok": true,
            "generatedAt": formatter.string(from: Date()),
            "reachable": health.map { $0.status != "offline" } ?? true,
            "health": health?.status ?? "unknown",
            "totalBytes": NSNumber(value: tree.bytes),
            "storedBytes": NSNumber(value: CloudUsage.storedBytes(tree)),
            "tree": tree.jsonObject(),
        ]
        if let catalog { object["appsListedAt"] = formatter.string(from: catalog.listedAt) }
        return object
    }

    /// Backend card data: kind, where it lives, health with latency, and every endpoint with its state.
    static func backendInfo(_ engine: DisklesslyEngine, health: BackendHealthProbe.Result) -> [String: Any] {
        let config = engine.config
        let activeId = config.activeBackendId ?? ""
        let active = config.backends.first { $0.id == activeId }
        let kind = active?.type ?? config.backend
        var endpoints: [[String: Any]] = config.backends.map { endpoint in
            let state: String
            if endpoint.id == activeId { state = "active" }
            else if endpoint.type == "local" { state = "local" }
            else { state = "standby" }
            return [
                "id": endpoint.id,
                "type": endpoint.type,
                "host": endpoint.host ?? "",
                "mountPoint": endpoint.mountPoint ?? "",
                "url": endpoint.url ?? "",
                "place": endpointPlace(endpoint),
                "state": state,
            ]
        }
        if active == nil {
            // A plain folder repo has no saved endpoint; it is the active one.
            endpoints.insert([
                "id": "local",
                "type": config.backend,
                "host": "",
                "mountPoint": "",
                "url": "",
                "place": config.repoPath,
                "state": "active",
            ], at: 0)
        }
        var object: [String: Any] = [
            "kind": kind,
            "location": kind == "local" ? "local" : "remote",
            "activeId": activeId,
            "activePlace": active.map(endpointPlace) ?? config.repoPath,
            "repoPath": config.repoPath,
            "health": health.status,
            "healthDetail": health.detail,
            "timedOut": health.timedOut,
            "timeoutMs": NSNumber(value: Int(health.timeout * 1000)),
            "checkedAt": ISO8601DateFormatter().string(from: health.checkedAt),
            "endpoints": endpoints,
        ]
        if let latency = health.latencyMs { object["latencyMs"] = NSNumber(value: latency) }
        return object
    }

    private static func endpointPlace(_ endpoint: BackendEndpoint) -> String {
        if let url = endpoint.url, !url.isEmpty { return url }
        if let host = endpoint.host, !host.isEmpty {
            let share = endpoint.share ?? endpoint.exportPath ?? ""
            if share.isEmpty { return host }
            return host + "/" + (share.hasPrefix("/") ? String(share.dropFirst()) : share)
        }
        if let mount = endpoint.mountPoint, !mount.isEmpty { return mount }
        return endpoint.root
    }

    /// `ok` below 80 % of the quota, `near` from 80 %, `critical` from 95 %.
    public static func cacheLevel(used: UInt64, quota: UInt64) -> String {
        guard quota > 0 else { return "ok" }
        let ratio = Double(used) / Double(quota)
        if ratio >= 0.95 { return "critical" }
        if ratio >= 0.8 { return "near" }
        return "ok"
    }

    /// Cache size at which free disk space would fall to `floor` (`used + diskFree - floor`,
    /// clamped at 0), or nil when that point lies at or past the quota and the floor never binds.
    public static func floorMarker(used: UInt64, diskFree: UInt64, floor: UInt64, quota: UInt64) -> UInt64? {
        guard quota > 0, floor > 0 else { return nil }
        let reach = Double(used) + Double(diskFree) - Double(floor)
        if reach >= Double(quota) { return nil }
        return UInt64(max(0, reach))
    }

    /// Whole days since the archived file was last modified.
    /// `~/…` for paths under the home folder (either `/private` spelling).
    public static func homeRelative(_ path: String, home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) -> String {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmed.isEmpty else { return path }
        var homes = [trimmed]
        if trimmed.hasPrefix("/private/") { homes.append(String(trimmed.dropFirst("/private".count))) }
        else if trimmed.hasPrefix("/tmp/") || trimmed.hasPrefix("/var/") { homes.append("/private" + trimmed) }
        for candidate in homes where path == candidate || path.hasPrefix(candidate + "/") {
            return "~" + path.dropFirst(candidate.count)
        }
        return path
    }

    /// What an archived session was about. Newer rows store the title as their preview; older
    /// rows kept the first raw bytes of the file there, so fall back to the digest's first prompt.
    public static func sessionTitle(_ entry: SessionIndexEntry) -> String {
        let preview = entry.preview.trimmingCharacters(in: .whitespaces)
        if !preview.isEmpty, !preview.hasPrefix("{"), !preview.hasPrefix("[") { return preview }
        return SessionDigest.title(fromDigest: entry.digest ?? "")
    }

    public static func sessionAgeDays(modified: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(modified) / 86_400))
    }

    private static func api(engine: DisklesslyEngine, request: UIRequest, context: ManagementUIContext) -> UIResponse {
        if request.method == "GET", request.path.hasPrefix("/api/icon/") {
            guard let imageId = AppIcon.imageId(apiPath: request.path) else { return .text(404, "not found") }
            let body = AppIcon.png(stateDir: engine.config.stateDir, repoPath: engine.config.repoPath, imageId: imageId)
            return UIResponse(status: 200, contentType: "image/png", body: body)
        }
        if request.method == "GET", request.path == "/api/app-icon" {
            #if os(macOS)
            guard let raw = request.query["path"], let valid = validPackPath(raw),
                  FileManager.default.fileExists(atPath: valid) else {
                return .text(404, "not found")
            }
            let body = StubIcon.bundleIconPNG(appPath: valid, stateDir: engine.config.stateDir)
            return UIResponse(status: 200, contentType: "image/png", body: body)
            #else
            return UIResponse(status: 200, contentType: "image/png", body: AppIcon.genericPNG)
            #endif
        }
        if request.method == "GET", request.path == "/api/usage/dir" {
            guard let raw = request.query["path"], !raw.isEmpty else {
                return failure(code: "bad_request", message: "path is required", status: 400)
            }
            let dir = URL(fileURLWithPath: raw).standardizedFileURL.path
            let home = URL(fileURLWithPath: engine.homeDirectory).standardizedFileURL.path
            let allowed = dir == home || dir.hasPrefix(home + "/") || dir == "/Applications" || dir.hasPrefix("/Applications/") || dir == "/Library" || dir.hasPrefix("/Library/")
            guard allowed else {
                return failure(code: "forbidden", message: "path outside allowed roots", status: 403)
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                return .json(["ok": true, "path": dir, "partial": false, "children": []])
            }
            let kind = UsageNode.Kind(rawValue: request.query["kind"] ?? "") ?? .personal
            let rescan = ["1", "true", "yes"].contains((request.query["rescan"] ?? "").lowercased())
            let origins = CloudUsage.inputs(engine: engine, apps: context.cloudCatalog()?.apps ?? [], readPlaceholders: false).originPaths
            let scan = context.scanDirectory(path: dir, kind: kind, rescan: rescan) {
                UsageMap.scanDirectoryDetailed(dir, kind: kind, timeout: 20, refusal: engine.fileOffloadRefusal, trashRefusal: engine.trashPathRefusal)
            }
            return .json([
                "ok": true,
                "path": dir,
                "partial": scan.partial,
                "cached": scan.cached,
                "children": scan.children.map { UsageMap.countOffloaded($0, originPaths: origins).jsonObject() },
            ])
        }
        if request.method == "GET", request.path == "/api/links/apps" {
            #if os(macOS)
            let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
            let bundles = engine.linkedBundleStore.load()
            let fm = FileManager.default
            var byPath: [String: [String: Any]] = [:]
            for root in roots where fm.fileExists(atPath: root) {
                let items = (try? fm.contentsOfDirectory(atPath: root)) ?? []
                for name in items where name.hasSuffix(".app") {
                    let candidate = URL(fileURLWithPath: root).appendingPathComponent(name).standardizedFileURL
                    guard let valid = validPackPath(candidate.path) else { continue }
                    let plistURL = candidate.appendingPathComponent("Contents/Info.plist")
                    let info = NSDictionary(contentsOf: plistURL) as? [String: Any]
                    let stubPath = candidate.appendingPathComponent("Contents/Resources/stub.json").path
                    let isOffloaded = fm.fileExists(atPath: stubPath)
                    let displayRaw = (info?["CFBundleDisplayName"] as? String)
                        ?? (info?["CFBundleName"] as? String)
                        ?? String(name.dropLast(4))
                    let display = displayRaw.isEmpty ? String(name.dropLast(4)) : displayRaw
                    var bundleId = info?["CFBundleIdentifier"] as? String ?? ""
                    if isOffloaded,
                       let stubData = fm.contents(atPath: stubPath),
                       let stubObj = (try? JSONSerialization.jsonObject(with: stubData)) as? [String: Any],
                       let realId = stubObj["appId"] as? String, !realId.isEmpty {
                        bundleId = realId
                    }
                    let linkedCount = bundles.first(where: { $0.appPath == valid })?.paths.count ?? 0
                    byPath[valid] = [
                        "name": display,
                        "path": valid,
                        "bundleId": bundleId,
                        "offloaded": isOffloaded,
                        "linkedCount": linkedCount,
                    ]
                }
            }
            let apps = byPath.values.sorted {
                ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare($1["name"] as? String ?? "") == .orderedAscending
            }
            return .json(["ok": true, "apps": apps])
            #else
            return .json(["ok": true, "apps": []])
            #endif
        }
        if request.method == "POST", request.path == "/api/links/add" {
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let rawApp = body["appPath"] as? String,
                  let validApp = validPackPath(rawApp),
                  let rawPath = body["path"] as? String, !rawPath.isEmpty else {
                return failure(code: "bad_request", message: "appPath (in /Applications or ~/Applications) and path are required", status: 400)
            }
            let normPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            if let why = engine.fileOffloadRefusal(normPath) {
                return failure(code: "bad_request", message: "\(normPath) \(why)", status: 400)
            }
            let appName = (body["appName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do {
                let bundle = try engine.linkedBundleStore.link(appPath: validApp, appName: appName, extraPath: normPath)
                return .json(["ok": true, "bundle": bundle.jsonObject(), "linkedBundles": engine.linkedBundleStore.load().map { $0.jsonObject() }])
            } catch {
                return failure(error, status: 500)
            }
        }
        if request.method == "POST", request.path == "/api/links/remove" {
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let rawApp = body["appPath"] as? String, !rawApp.isEmpty,
                  let rawPath = body["path"] as? String, !rawPath.isEmpty else {
                return failure(code: "bad_request", message: "appPath and path are required", status: 400)
            }
            do {
                try engine.linkedBundleStore.unlink(appPath: rawApp, extraPath: rawPath)
                return .json(["ok": true, "linkedBundles": engine.linkedBundleStore.load().map { $0.jsonObject() }])
            } catch {
                return failure(error, status: 500)
            }
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
        if !context.platform.offloadsApps, isAppRoute(request) {
            return failure(code: "unsupported", message: "Offloading apps is macOS only; this \(context.platform.rawValue) build serves sessions, disk usage, devices, and license.", status: 501)
        }
        if request.method == "POST", let kind = UIJobKind(path: request.path) {
            guard let name = appName(request) else { return failure(code: "bad_request", message: "app is required", status: 400) }
            let actions = context.actions ?? .live(engine)
            // Evicting a pinned app needs an explicit force; the page sends force=false.
            var options = UIJobOptions(force: flag(request, "force"))
            if kind == .pack {
                guard let path = packPath(request), let valid = validPackPath(path) else {
                    return failure(code: "bad_request", message: "path must be an .app in /Applications or ~/Applications", status: 400)
                }
                options.path = valid
                options.stopFirst = flag(request, "stopFirst")
            }
            if kind == .offloadfile || kind == .trashpath {
                guard let path = packPath(request) else { return failure(code: "bad_request", message: "path is required", status: 400) }
                let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                let why = kind == .trashpath ? engine.trashPathRefusal(standardized) : engine.fileOffloadRefusal(standardized)
                if let why {
                    return failure(code: "bad_request", message: "\(standardized) \(why)", status: 400)
                }
                options.path = standardized
            }
            switch context.jobs.start(kind: kind, app: name, work: { progress in
                try actions.perform(kind, name, options, progress)
                if kind == .offloadfile || kind == .trashpath, let path = options.path {
                    context.files.forget(path: path)
                    context.invalidateDirectoryCache(forPath: path)
                }
                if kind == .offloadfile || kind == .trashpath { _ = context.bigItems.start(engine: engine) }
                // Any job that moves or deletes apps/containers changes the whole usage tree;
                // file/folder offload & trash refresh in-place on the frontend via /api/usage/dir.
                if kind != .pin, kind != .unpin, kind != .trashpath, kind != .offloadfile { _ = context.usage.start(engine: engine) }
            }) {
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
        case ("GET", "/api/health"):
            let fresh = ["1", "true", "yes"].contains((request.query["fresh"] ?? "").lowercased())
            var object = backendInfo(engine, health: context.health.current(engine, fresh: fresh))
            object["ok"] = true
            return .json(object)
        case ("GET", "/api/jobs"):
            return .json(["ok": true, "jobs": context.jobs.all().map { $0.jsonObject() }])
        case ("GET", "/api/recommend"):
            do {
                let arguments = try RecommendArguments.parse(query: request.query)
                let rescan = ["1", "true", "yes"].contains((request.query["rescan"] ?? "").lowercased())
                let cached = context.recommendations(key: recommendKey(engine, request.query), rescan: rescan) {
                    let reachable = context.health.current(engine).status != "offline"
                    return engine.recommend(options: arguments.options(), repoReachable: reachable).jsonObject()
                }
                var object = cached.report
                object["scannedAt"] = ISO8601DateFormatter().string(from: cached.scannedAt)
                object["cached"] = cached.fromCache
                return .json(object)
            } catch {
                return failure(error, status: 400)
            }
        case ("GET", "/api/files"):
            return .json(context.files.snapshot())
        case ("POST", "/api/files/scan"):
            let started = context.files.start(engine: engine)
            var object = context.files.snapshot()
            object["started"] = started
            return .json(object, status: 202)
        case ("GET", "/api/dev"):
            var object = engine.devAssets().jsonObject()
            object["ok"] = true
            return .json(object)
        case ("GET", "/api/usage"):
            var object = context.usage.snapshot()
            object["cleanup"] = context.cleaner.snapshot()
            if let tree = context.usage.tree {
                // Cloud badges: how many offloaded items came from each box (local catalog only).
                let origins = CloudUsage.inputs(engine: engine, apps: context.cloudCatalog()?.apps ?? [], readPlaceholders: false).originPaths
                object["tree"] = UsageMap.countOffloaded(tree, originPaths: origins).jsonObject()
            }
            return .json(object)
        case ("GET", "/api/usage/cloud"):
            return .json(cloudUsageObject(engine, context: context))
        case ("GET", "/api/permissions"):
            // Full Disk Access can be probed by reading the TCC database, which only an allowed app can open.
            // App Management has no public probe; the page asks the user to confirm it.
            let fullDisk = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") != nil
            return .json(["fullDiskAccess": fullDisk ? "granted" : "missing", "appManagement": "unconfirmed"])
        case ("POST", "/api/permissions/open"):
            let which = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["which"] as? String ?? ""
            let pane: String
            switch which {
            case "fullDisk": pane = "Privacy_AllFiles"
            case "appManagement": pane = "Privacy_AppBundles"
            default: return failure(code: "bad_request", message: "unknown permission", status: 400)
            }
            #if os(macOS)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["x-apple.systempreferences:com.apple.preference.security?\(pane)"]
            do { try open.run() } catch { return failure(code: "failed", message: "could not open System Settings", status: 500) }
            return .json(["ok": true])
            #else
            return failure(code: "unsupported", message: "permissions are a macOS setting", status: 501)
            #endif
        case ("POST", "/api/reveal"):
            // Shows a file or folder in Finder (selected in its parent). Reads nothing, changes nothing.
            let raw = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["path"] as? String ?? ""
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard raw.hasPrefix("/"), !raw.contains("\u{0}"), FileManager.default.fileExists(atPath: path) else {
                return failure(code: "bad_request", message: "path must be an existing absolute path", status: 400)
            }
            #if os(macOS)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-R", path]
            do { try open.run() } catch { return failure(code: "failed", message: "could not open Finder", status: 500) }
            return .json(["ok": true])
            #else
            return failure(code: "unsupported", message: "Finder is macOS only", status: 501)
            #endif
        case ("POST", "/api/loginitems/open"):
            // Login items are turned off by the user in System Settings; this only opens that pane.
            #if os(macOS)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]
            do { try open.run() } catch { return failure(code: "failed", message: "could not open System Settings", status: 500) }
            return .json(["ok": true])
            #else
            return failure(code: "unsupported", message: "login items are a macOS setting", status: 501)
            #endif
        case ("POST", "/api/usage/clean"):
            let id = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["action"] as? String ?? ""
            guard UsageCleanup.known(id) else { return failure(code: "bad_request", message: "unknown cleanup", status: 400) }
            // Rescan when it finishes, so the map shows the new sizes.
            let usage = context.usage
            let big = context.bigItems
            let started = context.cleaner.start(id) { _ = usage.start(engine: engine); _ = big.start(engine: engine) }
            guard started else { return failure(code: "busy", message: "a cleanup is already running", status: 409) }
            return .json(["ok": true, "cleanup": context.cleaner.snapshot()], status: 202)
        case ("GET", "/api/sessions/plan"):
            // Reads the agents' folders only; nothing is opened in the repo or written.
            do {
                var object = try engine.sessionPlan().jsonObject()
                object["ok"] = true
                object["task"] = context.sessionTask.snapshot()
                return .json(object)
            } catch {
                return failure(error, status: 500)
            }
        case ("POST", "/api/sessions/apply"):
            // The user picked the agents on the page and confirmed: archive their cold sessions
            // (full snapshot to the repo, short digest kept here), then delete the local files.
            let body = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]) ?? [:]
            let tools = Set((body["tools"] as? [String]) ?? [])
            let paths = (body["paths"] as? [String]).map(Set.init)
            guard !tools.isEmpty else { return failure(code: "usage", message: "pick at least one agent", status: 400) }
            if let paths, paths.isEmpty { return failure(code: "usage", message: "pick at least one session", status: 400) }
            let started = context.sessionTask.start("sessions-apply") { progress in
                progress("archive")
                return try engine.sessionApply(tools: tools, paths: paths).jsonObject()
            }
            guard started else { return failure(code: "busy", message: "sessions are already being archived", status: 409) }
            return .json(["ok": true, "task": context.sessionTask.snapshot()], status: 202)
        case ("GET", "/api/sessions/digest"):
            let id = request.query["id"] ?? ""
            guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit }) else { return failure(code: "usage", message: "bad id", status: 400) }
            guard let text = try? String(contentsOf: SessionArchive.digestURL(config: engine.config, id: id), encoding: .utf8) else {
                return failure(code: "not_found", message: "no digest for \(id)", status: 404)
            }
            return .json(["ok": true, "id": id, "digest": text])
        case ("POST", "/api/sessions/restore"):
            let body = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]) ?? [:]
            let id = body["id"] as? String ?? ""
            guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit }) else { return failure(code: "usage", message: "bad id", status: 400) }
            let started = context.sessionTask.start("sessions-restore") { progress in
                progress("restore")
                return ["path": try SessionArchive.restoreSession(config: engine.config, open: { try engine.openSessionRepo() }, query: id, secrets: engine.secrets).path]
            }
            guard started else { return failure(code: "busy", message: "a session task is already running", status: 409) }
            return .json(["ok": true, "task": context.sessionTask.snapshot()], status: 202)
        case ("GET", "/api/sessions/task"):
            return .json(["ok": true, "task": context.sessionTask.snapshot()])
        case ("GET", "/api/bigitems"):
            var object = context.bigItems.snapshot()
            if object["state"] as? String == "idle" { context.bigItems.start(engine: engine); object["state"] = "scanning" }
            object["cleanup"] = context.cleaner.snapshot()
            return .json(object)
        case ("POST", "/api/bigitems/scan"):
            let started = context.bigItems.start(engine: engine)
            var object = context.bigItems.snapshot()
            object["started"] = started
            return .json(object, status: 202)
        case ("GET", "/api/containers"):
            // Images and volumes of Apple container, Docker Desktop, OrbStack, Colima, Dory.
            var object = context.containers.snapshot()
            if object["state"] as? String == "idle" { context.containers.start(engine: engine); object["state"] = "scanning" }
            return .json(object)
        case ("POST", "/api/containers/scan"):
            let started = context.containers.start(engine: engine)
            var object = context.containers.snapshot()
            object["started"] = started
            return .json(object, status: 202)
        case ("GET", "/api/reconcile"):
            // "Not measured" broken down (from the last usage scan) plus the AI model folders. Reads only.
            var object: [String: Any]
            if let tree = context.usage.tree, let facts = ReconcileReport.facts(in: tree) {
                let models = HiddenUsage.models(home: context.home, runner: context.reconcileRunner, processes: context.reconcileProcesses(), sizeTimeout: 20)
                object = ReconcileReport(facts: facts, models: models).jsonObject(now: context.currentDate())
            } else {
                object = ["ok": true, "state": context.usage.tree == nil ? "noscan" : "nogap",
                          "models": HiddenUsage.models(home: context.home, runner: context.reconcileRunner, processes: context.reconcileProcesses(), sizeTimeout: 20).map { $0.jsonObject() }]
            }
            object["cleanup"] = context.cleaner.snapshot()
            return .json(object)
        case ("POST", "/api/reconcile/action"):
            // One action at a time, each confirmed on its own by the page (`confirm: true`). These are never
            // UsageCleanup ids, so no bulk cleanup can reach them.
            let body = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]) ?? [:]
            let action = body["action"] as? String ?? ""
            guard HiddenUsage.isAction(action) else { return failure(code: "bad_request", message: "unknown reconcile action", status: 400) }
            guard body["confirm"] as? Bool == true else { return failure(code: "confirm_required", message: "this action needs its own confirmation", status: 400) }
            let runner = context.reconcileRunner, processes = context.reconcileProcesses, home = context.home
            let usage = context.usage
            let started = context.cleaner.start(action, work: {
                switch try HiddenUsage.perform(action, engine: engine, runner: runner, processes: processes, home: home) {
                case .done(let output): return output
                case .cancelled: throw DisklesslyError.usage("cancelled at the administrator prompt; nothing was changed")
                }
            }, then: { _ = usage.start(engine: engine) })
            guard started else { return failure(code: "busy", message: "a cleanup is already running", status: 409) }
            return .json(["ok": true, "cleanup": context.cleaner.snapshot()], status: 202)
        case ("POST", "/api/usage/scan"):
            let started = context.usage.start(engine: engine)
            var object = context.usage.snapshot()
            object["started"] = started
            return .json(object, status: 202)
        case ("GET", "/api/caches"), ("POST", "/api/caches/clear"):
            // Caches of offloaded apps. GET only measures; POST empties those of apps not running.
            // Listing an offline backend blocks for the transport timeout, so answer at once.
            if context.health.current(engine).status == "offline" {
                return failure(code: "offline", message: "The backend is unreachable.", status: 503)
            }
            do {
                let report = try engine.clearAppCaches(apply: request.method == "POST", home: context.home)
                // Emptying caches changes the disk map, so measure it again.
                if request.method == "POST" { _ = context.usage.start(engine: engine) }
                return .json(report.jsonObject())
            } catch {
                return failure(error, status: 500)
            }
        case ("GET", "/api/license"):
            return .json(licenseObject(engine))
        case ("POST", "/api/license/activate"):
            let code = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["code"] as? String ?? ""
            do {
                try License.activate(code, stateDir: engine.config.stateDir)
                return .json(licenseObject(engine))
            } catch {
                return failure(error, status: 400)
            }
        case ("POST", "/api/license/deactivate"):
            do {
                try License.deactivate(stateDir: engine.config.stateDir)
                return .json(licenseObject(engine))
            } catch {
                return failure(error, status: 500)
            }
        case ("POST", "/api/icons/backfill"):
            do {
                let report = try engine.backfillIcons(appId: request.query["app"])
                return .json(["ok": true, "updated": report.updated, "skipped": report.skipped, "warnings": report.warnings])
            } catch {
                return failure(error, status: error is DisklesslyError ? 400 : 500)
            }
        default:
            return .text(404, "not found")
        }
    }

    /// License state for the page. `offloaded` is how many apps and files count against the free limit.
    static func licenseObject(_ engine: DisklesslyEngine) -> [String: Any] {
        var object: [String: Any] = ["ok": true, "freeLimit": License.freeAppLimit, "limitEnabled": License.limitEnabled, "purchaseURL": License.purchaseURL]
        object["offloaded"] = ((try? engine.offloadedBundleIdCount()) ?? 0) + engine.offloadedFileCount()
        switch License.load(stateDir: engine.config.stateDir) {
        case .free: object["state"] = "free"
        case .licensed(let p):
            object["state"] = "licensed"; object["edition"] = p.edition
            if let e = p.expires { object["expires"] = e }
            if let u = p.updatesUntil { object["updatesUntil"] = u }
        case .expired(let p): object["state"] = "expired"; object["expires"] = p.expires ?? ""
        case .invalid(let reason): object["state"] = "invalid"; object["reason"] = reason
        }
        return object
    }

    /// Stable error code and readable message. The page maps the code to localized text.
    public static func errorInfo(_ error: Error) -> (code: String, message: String) {
        if let error = error as? UIJobError {
            switch error {
            case .unknownApp(let name): return ("unknown_app", "Unknown app: \(name)")
            case .pinned(let name): return ("pinned", "\(name) is pinned; unpin it first")
            }
        }
        if let error = error as? DisklesslyError {
            let message = error.errorDescription ?? String(describing: error)
            switch error {
            case .backend: return ("offline", message)
            case .integrity: return ("integrity", message)
            case .noSpace: return ("no_space", message)
            case .busy: return ("busy", message)
            case .usage: return ("bad_request", message)
            case .unsupported: return ("unsupported", message)
            case .resolution: return ("needs_resolution", message)
            case .licenseRequired: return ("license_required", message)
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

    /// Routes that pack, launch, or scan app bundles.
    static func isAppRoute(_ request: UIRequest) -> Bool {
        // Container engines and large file/folder offload run on Linux too; their jobs are not app routes.
        if request.method == "POST", let kind = UIJobKind(path: request.path) {
            return !kind.isContainers && kind != .offloadfile && kind != .trashpath
        }
        return request.path == "/api/recommend" || request.path == "/api/icons/backfill"
    }

    static func failure(_ error: Error, status: Int) -> UIResponse {
        let info = errorInfo(error)
        return failure(code: info.code, message: info.message, status: status)
    }

    static func failure(code: String, message: String, status: Int) -> UIResponse {
        .json(failureObject(code: code, message: message), status: status)
    }

    static func failureObject(code: String, message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }

    private static func recommendKey(_ engine: DisklesslyEngine, _ query: [String: String]) -> String {
        let relevant = query.filter { !["token", "rescan", "_"].contains($0.key) }
        let options = relevant.keys.sorted().map { "\($0)=\(relevant[$0] ?? "")" }.joined(separator: "&")
        return engine.config.stateDir + "?" + options
    }

    private static func flag(_ request: UIRequest, _ key: String) -> Bool {
        if let query = request.query[key] { return ["1", "true", "yes"].contains(query.lowercased()) }
        if let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
            return object[key] as? Bool ?? false
        }
        return false
    }

    private static func packPath(_ request: UIRequest) -> String? {
        if let query = request.query["path"], !query.isEmpty { return query }
        if let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
           let path = object["path"] as? String, !path.isEmpty {
            return path
        }
        return nil
    }

    /// Only a top-level `.app` folder directly inside /Applications or ~/Applications may be packed from the page.
    static func validPackPath(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "app" else { return nil }
        let parent = url.deletingLastPathComponent().path
        let allowed = ["/Applications", NSHomeDirectory() + "/Applications"]
        guard allowed.contains(parent) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url.path
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

    /// Free space on the cache volume (the nearest existing folder up the path).
    private static func diskFreeBytes(_ path: String) -> UInt64? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        return try? VolumeSpace.availableBytes(at: url.path)
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
    /// Ejects a mount-mode app's disk image now (`disklessly detach`). Refused while it runs.
    case detach
    /// Offloads an installed app (`disklessly pack`). The request carries the app's `path`.
    case pack
    /// Offloads a large file or folder (`disklessly offload`). The request carries its `path`.
    case offloadfile
    /// Moves a file or folder to the Trash. The request carries its `path`; the same safety rules as offload apply.
    case trashpath

    /// Xcode simulators (`disklessly dev`). `app` is the runtime id, the simulator
    /// udid or the repo record id; clean-derived-data ignores it.
    case devOffloadRuntime = "dev/offload-runtime", devRestoreRuntime = "dev/restore-runtime"
    case devOffloadSimulator = "dev/offload-simulator", devRestoreSimulator = "dev/restore-simulator"
    case devForget = "dev/forget", devCleanDerivedData = "dev/clean-derived-data"
    case devShutdownSimulator = "dev/shutdown-simulator"

    /// Container images (`disklessly containers`). `app` is `<engine>/<image id>` for
    /// offload and clean, the repo record id for restore and forget.
    case containersOffload = "containers/offload", containersClean = "containers/clean"
    case containersRestore = "containers/restore", containersForget = "containers/forget"

    /// Data follows the app (`disklessly data enable|disable`). `app` is the app name.
    case dataEnable = "data/enable", dataDisable = "data/disable"

    /// Removes verified leftover backups with one administrator prompt (`disklessly cleanup-backups`).
    /// `app` is a label only ("backups"); the job covers every leftover backup.
    case backupsCleanup = "backups/cleanup"

    /// Linked app + extra paths group (`vphone.app` + `~/.vphone`). `app` is the linked bundle id.
    case linksOffload = "links/offload", linksRestore = "links/restore"

    public var isDev: Bool { rawValue.hasPrefix("dev/") }
    public var isContainers: Bool { rawValue.hasPrefix("containers/") }

    public init?(path: String) {
        guard path.hasPrefix("/api/") else { return nil }
        self.init(rawValue: String(path.dropFirst("/api/".count)))
    }
}

public enum UIJobError: Error, Equatable {
    case unknownApp(String)
    /// Evict on a pinned app without `force`.
    case pinned(String)
}

/// Request options for a job. `force` lets evict drop a pinned app's cache.
public struct UIJobOptions: Equatable {
    public var force: Bool
    /// Bundle path for `pack`.
    public var path: String?
    /// For `pack`: quit the app's own processes (helpers, menu bar agents) first.
    public var stopFirst: Bool
    public init(force: Bool = false, path: String? = nil, stopFirst: Bool = false) { self.force = force; self.path = path; self.stopFirst = stopFirst }
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
    public var doneBytes: UInt64?
    public var totalBytes: UInt64?
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
        if let doneBytes { object["doneBytes"] = NSNumber(value: doneBytes) }
        if let totalBytes { object["totalBytes"] = NSNumber(value: totalBytes) }
        if let finishedAt { object["finishedAt"] = formatter.string(from: finishedAt) }
        if let errorCode { object["error"] = ["code": errorCode, "message": errorMessage ?? ""] }
        return object
    }
}

/// Lets a running action report its phase (`resolve`, `download`, `open`, ...) and byte progress.
public final class UIJobProgress {
    private let updatePhase: (String) -> Void
    private let updateBytes: (UInt64, UInt64) -> Void
    init(_ updatePhase: @escaping (String) -> Void, bytes updateBytes: @escaping (UInt64, UInt64) -> Void = { _, _ in }) {
        self.updatePhase = updatePhase
        self.updateBytes = updateBytes
    }
    public func phase(_ name: String) { updatePhase(name) }
    public func bytes(_ done: UInt64, total: UInt64) { updateBytes(done, total) }
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
            let progress = UIJobProgress(
                { [weak self] phase in
                    self?.mutate(id) {
                        if $0.phase != phase {
                            $0.doneBytes = nil
                            $0.totalBytes = nil
                        }
                        $0.phase = phase
                    }
                },
                bytes: { [weak self] done, total in
                    self?.mutate(id) {
                        $0.doneBytes = done
                        $0.totalBytes = total
                    }
                }
            )
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

/// What each job does. Tests pass their own `run`; `disklessly ui` uses `live`.
public struct ManagementActions {
    public var perform: (UIJobKind, String, UIJobOptions, UIJobProgress) throws -> Void

    public init(run: @escaping (UIJobKind, String, UIJobProgress) throws -> Void) {
        self.perform = { kind, name, _, progress in try run(kind, name, progress) }
    }

    public init(perform: @escaping (UIJobKind, String, UIJobOptions, UIJobProgress) throws -> Void) {
        self.perform = perform
    }

    public static func live(_ engine: DisklesslyEngine) -> ManagementActions {
        ManagementActions(perform: { kind, name, options, progress in
            if kind == .pack {
                guard let path = options.path else { throw DisklesslyError.usage("pack needs the app path") }
                if options.stopFirst {
                    progress.phase("stop")
                    try BundleProcesses.stop(bundlePath: path)
                    progress.phase("pack")
                    do {
                        _ = try engine.pack(path, progress: { progress.phase($0) }, onBytes: { done, total in progress.bytes(done, total: total) })
                    } catch DisklesslyError.busy {
                        // launchd may have started a helper again before the pack looked; once more.
                        progress.phase("stop")
                        try BundleProcesses.stop(bundlePath: path)
                        progress.phase("pack")
                        _ = try engine.pack(path, progress: { progress.phase($0) }, onBytes: { done, total in progress.bytes(done, total: total) })
                    }
                    MirrorAutoSync.kick(engine)
                    return
                }
                progress.phase("pack")
                _ = try engine.pack(path, progress: { progress.phase($0) }, onBytes: { done, total in progress.bytes(done, total: total) })
                MirrorAutoSync.kick(engine)
                return
            }
            if kind == .trashpath {
                guard let path = options.path else { throw DisklesslyError.usage("delete needs the path") }
                progress.phase("remove")
                try engine.trashPath(path)
                return
            }
            if kind == .linksOffload {
                try engine.offloadLinkedBundle(id: name, progress: { progress.phase($0) }, onBytes: { done, total in progress.bytes(done, total: total) })
                MirrorAutoSync.kick(engine)
                return
            }
            if kind == .linksRestore {
                try engine.restoreLinkedBundle(id: name, progress: { progress.phase($0) })
                return
            }
            if kind == .offloadfile {
                guard let path = options.path else { throw DisklesslyError.usage("offload needs the file path") }
                _ = try engine.offloadFile(path, progress: { progress.phase($0) }, onBytes: { done, total in progress.bytes(done, total: total) })
                MirrorAutoSync.kick(engine)
                return
            }
            if kind.isContainers {
                switch kind {
                case .containersOffload: _ = try engine.offloadContainerImage(name) { progress.phase($0) }
                case .containersClean: progress.phase("remove"); _ = try engine.cleanContainerImage(name)
                case .containersRestore: _ = try engine.restoreContainerImage(name) { progress.phase($0) }
                case .containersForget: progress.phase("forget"); _ = try engine.forgetContainerImage(name)
                default: break
                }
                return
            }
            if kind.isDev {
                progress.phase(String(kind.rawValue.dropFirst("dev/".count)))
                switch kind {
                case .devOffloadRuntime: _ = try engine.offloadRuntime(name)
                case .devRestoreRuntime: _ = try engine.restoreRuntime(name)
                case .devOffloadSimulator: _ = try engine.offloadSimulator(name)
                case .devRestoreSimulator: _ = try engine.restoreSimulator(name)
                case .devForget: _ = try engine.forgetDevAsset(name)
                case .devCleanDerivedData: _ = try engine.trashDerivedData()
                case .devShutdownSimulator: try engine.shutdownSimulator(name)
                default: break
                }
                return
            }
            if kind == .backupsCleanup {
                progress.phase("remove")
                _ = try engine.cleanupBackups()
                return
            }
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
                // design §4: a pinned app is refused unless forced; the page
                // always sends force=false and disables Evict while pinned.
                if engine.evictRefusal(manifest, force: options.force)?.reason == "pinned" {
                    throw UIJobError.pinned(manifest.name)
                }
                progress.phase("evict")
                try engine.evict(manifest, force: options.force)
            case .detach:
                if let refusal = engine.detachRefusal(manifest) { throw refusal.error }
                progress.phase("detach")
                _ = try engine.detach(manifest, force: false)
            case .unpack:
                progress.phase("unpack")
                try engine.unpack(manifest, to: nil)
            case .pin:
                progress.phase("download")
                try engine.setPinned(manifest, pinned: true)
            case .unpin:
                progress.phase("pin")
                try engine.setPinned(manifest, pinned: false)
            case .dataEnable:
                _ = try engine.appDataEnable(manifest) { progress.phase($0) }
            case .dataDisable:
                try engine.appDataDisable(manifest) { progress.phase($0) }
            case .backupsCleanup, .pack, .offloadfile, .trashpath, .devOffloadRuntime, .devRestoreRuntime, .devOffloadSimulator, .devRestoreSimulator, .devForget, .devCleanDerivedData, .devShutdownSimulator,
                 .containersOffload, .containersClean, .containersRestore, .containersForget, .linksOffload, .linksRestore:
                break
            }
        })
    }

    /// `launch` keeps supervising the session until the app quits, then
    /// detaches. That supervision stays on its own thread; the job finishes
    /// once the app is open (state `running`, or a restore mirror in restore
    /// mode), or when `launch` returns or throws first.
    static func launchSupervised(_ engine: DisklesslyEngine, _ manifest: ImageManifest) throws {
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
                if outcome.detached { FileHandle.standardError.write(Data("disklessly ui: \(manifest.name): \(error)\n".utf8)) }
            }
            finished.signal()
        }
        worker.name = "disklessly.ui.launch"
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
    /// The disk usage map scan (`/api/usage`).
    public let usage: UsageScanner
    public let cleaner = UsageCleaner()
    /// Simulators, DerivedData, rebuildable caches, big app data (`/api/bigitems`).
    public let bigItems = BigItemsScanner()
    /// Container images and volumes (`/api/containers`).
    public let containers = ContainerScanner()
    /// Large idle files and folders (`/api/files`).
    public let files: LargeFileScanner
    /// Home folder whose `Library/Caches` `/api/caches` looks in. Tests point it at a temp folder.
    public var home: String = NSHomeDirectory()
    /// Runs `tmutil`, `mdutil`, administrator `osascript` and `lsof` for `/api/reconcile`. Tests inject a fake.
    public var reconcileRunner: SystemCommandRunner = LiveSystemCommandRunner.shared
    /// Running processes for the AI-model in-use check. Tests inject a list.
    public var reconcileProcesses: () -> [(Int32, String)] = HiddenUsage.runningProcesses
    /// Backend reachability with latency; bounded by its timeout and shared across requests.
    public let health: BackendHealthProbe
    /// Replaces the engine-backed actions, for tests.
    public let actions: ManagementActions?
    /// Connecting a cloud drive or installing OpenList (`/api/cloud`).
    public let cloud = CloudTaskRunner()
    /// Archiving or restoring agent sessions (`/api/sessions/apply`, `/api/sessions/restore`).
    public let sessionTask = CloudTaskRunner()
    /// SSH remote machines scan and error state (`/api/machines`).
    public let machines = RemoteMachinesState()
    private struct DirScanEntry {
        let children: [UsageNode]
        let partial: Bool
        let usageScannedAt: Date?
        let scannedAt: Date
    }

    private var savedConfig: RuntimeConfig?
    private let now: () -> Date
    private let lock = NSLock()
    private let scanLock = NSLock()
    private var recommendCache: [String: (report: [String: Any], scannedAt: Date)] = [:]
    private let dirLock = NSLock()
    private var dirCache: [String: DirScanEntry] = [:]
    private var dirInflight: [String: DispatchGroup] = [:]

    /// Linux serves sessions, usage, devices, and license; the app routes answer 501.
    public let platform: HostPlatform

    public init(platform: HostPlatform = .current, jobs: UIJobStore = UIJobStore(), actions: ManagementActions? = nil, health: BackendHealthProbe = BackendHealthProbe(), usage: UsageScanner = UsageScanner(), files: LargeFileScanner = LargeFileScanner(), now: @escaping () -> Date = Date.init) {
        self.jobs = jobs
        self.platform = platform
        self.usage = usage
        self.files = files
        self.health = health
        self.actions = actions
        self.now = now
    }

    private var cloudApps: CloudAppCatalog?

    /// The context's clock (tests inject one).
    public func currentDate() -> Date { now() }

    /// Packed apps from the last successful `/api/status` listing (the cloud side of the usage map).
    public func cloudCatalog() -> CloudAppCatalog? {
        lock.lock(); defer { lock.unlock() }
        return cloudApps
    }

    public func setCloudCatalog(_ catalog: CloudAppCatalog) {
        lock.lock(); cloudApps = catalog; lock.unlock()
    }

    /// The config the page saved last (after a repo switch or a new backend), if any.
    public func updatedConfig() -> RuntimeConfig? {
        lock.lock(); defer { lock.unlock() }
        return savedConfig
    }

    public func configChanged(_ config: RuntimeConfig) {
        lock.lock(); savedConfig = config; lock.unlock()
    }

    /// Invalidates cached directory drill-down scans affected by a mutation at `changedPath`.
    public func invalidateDirectoryCache(forPath changedPath: String) {
        let norm = URL(fileURLWithPath: changedPath).standardizedFileURL.path
        let normPrefix = norm.hasSuffix("/") ? norm : norm + "/"
        dirLock.lock()
        dirCache = dirCache.filter { key, _ in
            guard let pipe = key.lastIndex(of: "|") else { return true }
            let cachedDir = URL(fileURLWithPath: String(key[..<pipe])).standardizedFileURL.path
            let cachedPrefix = cachedDir.hasSuffix("/") ? cachedDir : cachedDir + "/"
            if cachedDir == norm || norm.hasPrefix(cachedPrefix) || cachedDir.hasPrefix(normPrefix) {
                return false
            }
            return true
        }
        dirLock.unlock()
    }

    /// Cached directory drill-down scan, deduplicating concurrent requests and invalidating when a new usage scan completes.
    public func scanDirectory(path: String, kind: UsageNode.Kind, rescan: Bool = false, compute: () -> (children: [UsageNode], partial: Bool)) -> (children: [UsageNode], partial: Bool, cached: Bool) {
        let key = "\(path)|\(kind.rawValue)"
        let usageStamp = usage.scannedAt
        let isValid: (DirScanEntry) -> Bool = { entry in
            !entry.partial && entry.usageScannedAt == usageStamp && self.now().timeIntervalSince(entry.scannedAt) < 120
        }
        dirLock.lock()
        if !rescan, let hit = dirCache[key], isValid(hit) {
            dirLock.unlock()
            return (hit.children, hit.partial, true)
        }
        if !rescan, let running = dirInflight[key] {
            dirLock.unlock()
            running.wait()
            dirLock.lock()
            let hit = dirCache[key]
            dirLock.unlock()
            if let hit, isValid(hit) {
                return (hit.children, hit.partial, true)
            }
            return (hit?.children ?? [], hit?.partial ?? false, false)
        }
        let group = DispatchGroup()
        group.enter()
        dirInflight[key] = group
        dirLock.unlock()

        let result = compute()
        let stamp = now()
        dirLock.lock()
        if !result.partial || !result.children.isEmpty {
            dirCache[key] = DirScanEntry(children: result.children, partial: result.partial, usageScannedAt: usageStamp, scannedAt: stamp)
        }
        dirInflight.removeValue(forKey: key)
        dirLock.unlock()
        group.leave()
        return (result.children, result.partial, false)
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

// MARK: - Backend health

/// Probes the backend off the request thread. A probe that runs past `timeout`
/// reports `offline` (timed out); it keeps running, and its real answer replaces
/// the timeout when it lands. Callers share one probe per backend, and a result
/// stays fresh for `maxAge` seconds. A caller waits on a probe only when it
/// started one itself; while a probe is still running, everyone else gets the
/// last result at once (stale-while-revalidate), so a hung backend costs one
/// `timeout`, not one per refresh.
public final class BackendHealthProbe: @unchecked Sendable {
    public struct Result: Equatable {
        /// `ok`, `degraded` (answers slowly), `missing` (no repo.json), or `offline`.
        public var status: String
        public var detail: String
        public var latencyMs: Int?
        public var timedOut: Bool
        public var timeout: TimeInterval
        public var checkedAt: Date
    }

    /// Returns nil when the repo answers, or a reason when it answers but is incomplete. Throws when unreachable.
    public typealias Check = (DisklesslyEngine) throws -> String?

    private struct Inflight {
        let group: DispatchGroup
        let generation: Int
        let started: Date
    }

    public let timeout: TimeInterval
    public let maxAge: TimeInterval
    public let slowMs: Int
    private let check: Check
    private let lock = NSLock()
    private var results: [String: Result] = [:]
    private var inflight: [String: Inflight] = [:]
    private var generation = 0

    public init(timeout: TimeInterval = 5, maxAge: TimeInterval = 10, slowMs: Int = 500, check: Check? = nil) {
        self.timeout = timeout
        self.maxAge = maxAge
        self.slowMs = slowMs
        self.check = check ?? BackendHealthProbe.repoCheck
    }

    public static func repoCheck(_ engine: DisklesslyEngine) throws -> String? {
        let backend = try engine.openBackend()
        return try backend.stat("repo.json") != nil ? nil : "repo.json is not in the backend"
    }

    /// The last result for this repo, however old, without starting or waiting for a probe.
    public func last(_ engine: DisklesslyEngine) -> Result? {
        let key = [engine.config.backend, engine.config.activeBackendId ?? "", engine.config.repoPath].joined(separator: "|")
        lock.lock(); defer { lock.unlock() }
        return results[key]
    }

    /// `fresh` skips the cache. With a probe already hung past `timeout`, it
    /// starts a new probe instead of joining the stuck one, so Retry can see a
    /// backend that has recovered.
    public func current(_ engine: DisklesslyEngine, fresh: Bool = false) -> Result {
        let key = [engine.config.backend, engine.config.activeBackendId ?? "", engine.config.repoPath].joined(separator: "|")
        lock.lock()
        let last = results[key]
        if !fresh, let last, Date().timeIntervalSince(last.checkedAt) < maxAge {
            lock.unlock()
            return last
        }
        let probe: Inflight
        if let running = inflight[key] {
            let hung = Date().timeIntervalSince(running.started) >= timeout
            if fresh {
                // Retry: join a probe that is still within its timeout, replace a hung one.
                probe = hung ? start(engine, key: key) : running
            } else if let last {
                // A probe is already on it: answer from the last result, do not wait.
                lock.unlock()
                return last
            } else {
                probe = running
            }
        } else {
            probe = start(engine, key: key)
        }
        lock.unlock()
        if probe.group.wait(timeout: .now() + timeout) == .timedOut {
            let timedOut = Result(status: "offline", detail: "timeout", latencyMs: nil, timedOut: true, timeout: timeout, checkedAt: Date())
            lock.lock()
            defer { lock.unlock() }
            // Still running: remember the timeout so the next refresh does not wait again.
            if inflight[key]?.generation == probe.generation {
                results[key] = timedOut
                return timedOut
            }
            return results[key] ?? timedOut
        }
        lock.lock()
        defer { lock.unlock() }
        return results[key] ?? Result(status: "offline", detail: "", latencyMs: nil, timedOut: false, timeout: timeout, checkedAt: Date())
    }

    /// Call with `lock` held. A probe superseded by a newer generation drops its answer.
    private func start(_ engine: DisklesslyEngine, key: String) -> Inflight {
        generation += 1
        let probe = Inflight(group: DispatchGroup(), generation: generation, started: Date())
        probe.group.enter()
        inflight[key] = probe
        let check = self.check
        let timeout = self.timeout
        let slowMs = self.slowMs
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let started = Date()
            var result: Result
            do {
                let problem = try check(engine)
                let latency = Int((Date().timeIntervalSince(started) * 1000).rounded())
                let status = problem != nil ? "missing" : (latency >= slowMs ? "degraded" : "ok")
                result = Result(status: status, detail: problem ?? "", latencyMs: latency, timedOut: false, timeout: timeout, checkedAt: Date())
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result = Result(status: "offline", detail: detail, latencyMs: nil, timedOut: false, timeout: timeout, checkedAt: Date())
            }
            lock.lock()
            if inflight[key]?.generation == probe.generation {
                results[key] = result
                inflight[key] = nil
            }
            lock.unlock()
            probe.group.leave()
        }
        return probe
    }
}
