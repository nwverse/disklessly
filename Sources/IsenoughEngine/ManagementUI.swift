import Foundation
import IsenoughCore

/// Local management page and JSON API. The loopback server checks the token
/// before this runs, so every page and `/api` call already presented it.
public enum ManagementUI {
    public static func respond(engine: IsenoughEngine, webRoot: URL?, request: UIRequest) -> UIResponse {
        if request.path.hasPrefix("/api/") { return api(engine: engine, request: request) }
        return staticFile(webRoot: webRoot, request: request)
    }

    public static func dashboard(_ engine: IsenoughEngine) -> [String: Any] {
        var apps: [[String: Any]] = []
        var appsError = ""
        let state = StateStore(engine.config.stateDir).read()
        let stored = state["apps"] as? [String: [String: Any]] ?? [:]
        do {
            for manifest in try engine.list() {
                let cached = URL(fileURLWithPath: engine.config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg")
                let exists = FileManager.default.fileExists(atPath: cached.path)
                let size = exists ? ((try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0) : 0
                let restoredMap = state["restored"] as? [String: Any] ?? [:]
                let appState = stored[manifest.bundleId]?["state"] as? String ?? ""
                let restored = restoredMap[manifest.bundleId] != nil || appState == "restored" || appState == "needsResolution"
                apps.append([
                    "imageId": manifest.imageId,
                    "bundleId": manifest.bundleId,
                    "name": manifest.name,
                    "version": manifest.version,
                    "mode": manifest.mode.rawValue,
                    "pinned": stored[manifest.bundleId]?["pinned"] as? Bool ?? false,
                    "cached": exists,
                    "remote": !exists,
                    "restored": restored,
                    "state": appState,
                    "cachedBytes": NSNumber(value: size),
                ])
            }
        } catch {
            appsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            "sessions": [
                "coldDays": NSNumber(value: engine.config.sessionColdDays),
                "offloaded": sessions,
            ] as [String: Any],
        ]
    }

    private static func api(engine: IsenoughEngine, request: UIRequest) -> UIResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/status"):
            return .json(dashboard(engine))
        case ("POST", "/api/pin"), ("POST", "/api/unpin"), ("POST", "/api/evict"), ("POST", "/api/restore"):
            guard let name = appName(request) else { return .json(["ok": false, "error": "app is required"], status: 400) }
            do {
                guard var manifest = engine.manifest(named: name, in: try engine.list()) else {
                    return .json(["ok": false, "error": "Unknown app: \(name)"], status: 404)
                }
                if request.path == "/api/evict" {
                    try engine.evict(manifest)
                } else if request.path == "/api/restore" {
                    manifest.mode = .restore
                    try engine.launch(manifest)
                } else {
                    try engine.setPinned(manifest, pinned: request.path == "/api/pin")
                }
                return .json(["ok": true, "app": manifest.name, "pinned": request.path == "/api/pin", "restored": request.path == "/api/restore"])
            } catch let error as IsenoughError {
                return .json(["ok": false, "error": error.errorDescription ?? "request failed"], status: 400)
            } catch {
                return .json(["ok": false, "error": error.localizedDescription], status: 500)
            }
        default:
            return .text(404, "not found")
        }
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
