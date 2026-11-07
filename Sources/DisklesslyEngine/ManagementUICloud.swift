import Foundation
import DisklesslyCore

/// `/api/cloud*` and `/api/openlist*`: cloud drives through the bundled rclone, the one-click
/// OpenList server, and switching which repo is active.
extension ManagementUI {
    static func cloudAPI(engine: DisklesslyEngine, request: UIRequest, context: ManagementUIContext) -> UIResponse {
        let body = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]) ?? [:]
        let drives = CloudDrives(stateDir: engine.config.stateDir)
        let openlist = OpenListService(stateDir: engine.config.stateDir, secrets: engine.secrets)
        switch (request.method, request.path) {
        case ("GET", "/api/cloud"):
            return .json(cloudObject(engine, drives: drives, openlist: openlist, context: context))
        case ("POST", "/api/cloud/connect"):
            let provider = body["provider"] as? String ?? ""
            guard CloudDrives.provider(provider) != nil else { return failure(code: "usage", message: "unknown cloud drive: \(provider)", status: 400) }
            guard drives.binary != nil else { return failure(code: "unsupported", message: "rclone is not available", status: 400) }
            let started = context.cloud.start("connect") { progress in
                progress("signin")
                let endpoint = try drives.connect(provider: provider)
                try store(endpoint, engine: engine, context: context)
                return ["backendId": endpoint.id, "remote": endpoint.remote ?? ""]
            }
            return started ? .json(["ok": true, "cloud": cloudObject(engine, drives: drives, openlist: openlist, context: context)], status: 202)
                : failure(code: "busy", message: "another cloud task is running", status: 409)
        case ("POST", "/api/cloud/disconnect"):
            let remote = body["remote"] as? String ?? ""
            let ids = engine.config.backends.filter { $0.type == "rclone" && $0.remote == remote }.map(\.id)
            if let active = engine.config.activeBackendId, ids.contains(active) {
                return failure(code: "usage", message: "\(remote) is the active repo; switch back first", status: 409)
            }
            do {
                try drives.disconnect(remote)
                var updated = engine
                updated.config.backends.removeAll { ids.contains($0.id) }
                try updated.saveConfig()
                context.configChanged(updated.config)
                return .json(["ok": true, "cloud": cloudObject(updated, drives: drives, openlist: openlist, context: context)])
            } catch {
                return failure(error, status: 400)
            }
        case ("POST", "/api/cloud/use"):
            let id = body["id"] as? String ?? ""
            var updated = engine
            if let remote = body["remote"] as? String {
                // A remote made with `disklessly rclone config` that is not a backend yet.
                guard (try? drives.remotes())?.contains(remote) == true else { return failure(code: "usage", message: "unknown remote: \(remote)", status: 400) }
                do { updated.config.remember(try drives.endpoint(remote: remote)) } catch { return failure(error, status: 400) }
            } else if id == "default" {
                updated.config.useDefaultRepo()
            } else if let endpoint = engine.config.backends.first(where: { $0.id == id }) {
                updated.config.remember(endpoint)
            } else {
                return failure(code: "usage", message: "unknown backend: \(id)", status: 400)
            }
            do {
                try updated.prepareRepo()
                try updated.saveConfig()
            } catch {
                return failure(error, status: 400)
            }
            context.configChanged(updated.config)
            _ = context.health.current(updated, fresh: true)
            return .json(["ok": true, "cloud": cloudObject(updated, drives: drives, openlist: openlist, context: context)])
        case ("POST", "/api/openlist/install"):
            let started = context.cloud.start("openlist") { progress in
                let endpoint = try openlist.install(progress: progress)
                try store(endpoint, engine: engine, context: context)
                return ["backendId": endpoint.id, "url": openlist.url]
            }
            return started ? .json(["ok": true, "cloud": cloudObject(engine, drives: drives, openlist: openlist, context: context)], status: 202)
                : failure(code: "busy", message: "another cloud task is running", status: 409)
        case ("POST", "/api/openlist/start"), ("POST", "/api/openlist/stop"):
            do {
                if request.path.hasSuffix("start") { try openlist.start() } else { try openlist.stop() }
                return .json(["ok": true, "cloud": cloudObject(engine, drives: drives, openlist: openlist, context: context)])
            } catch {
                return failure(error, status: 500)
            }
        case ("GET", "/api/openlist/password"):
            guard let password = openlist.password() else { return failure(code: "usage", message: "OpenList is not installed", status: 404) }
            return .json(["ok": true, "user": "admin", "password": password])
        default:
            return .text(404, "not found")
        }
    }

    /// Adds `endpoint` to the latest saved config without making it the repo.
    static func store(_ endpoint: BackendEndpoint, engine: DisklesslyEngine, context: ManagementUIContext) throws {
        var updated = engine
        if let latest = context.updatedConfig() { updated.config = latest }
        updated.config.store(endpoint)
        try updated.saveConfig()
        context.configChanged(updated.config)
    }

    static func cloudObject(_ engine: DisklesslyEngine, drives: CloudDrives, openlist: OpenListService, context: ManagementUIContext) -> [String: Any] {
        var object = drives.listing(config: engine.config)
        object["ok"] = true
        object["openlist"] = openlist.status()
        object["task"] = context.cloud.snapshot()
        object["repoPath"] = engine.config.repoPath
        object["defaultKind"] = ICloudFolderBackend.looksLikeICloud(URL(fileURLWithPath: engine.config.repoPath)) ? "icloud" : "local"
        object["backends"] = engine.config.backends.map { ["id": $0.id, "type": $0.type, "url": $0.url ?? ""] }
        object["appsHere"] = engine.appsOnActiveRepo().count
        return object
    }
}
