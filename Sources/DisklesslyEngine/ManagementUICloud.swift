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
                updated.config.mirrorBackendIds.removeAll { ids.contains($0) }
                try updated.saveConfig()
                context.configChanged(updated.config)
                return .json(["ok": true, "cloud": cloudObject(updated, drives: drives, openlist: openlist, context: context)])
            } catch {
                return failure(error, status: 400)
            }
        case ("POST", "/api/cloud/use") where body["migrate"] as? Bool == true:
            return migrateRepo(engine: engine, body: body, drives: drives, openlist: openlist, context: context)
        case ("POST", "/api/cloud/mirrors"):
            let id = body["id"] as? String ?? ""
            var updated = engine
            do {
                switch body["action"] as? String ?? "add" {
                case "add": try updated.addMirror(id)
                case "remove": try updated.removeMirror(id)
                default: return failure(code: "usage", message: "action must be add or remove", status: 400)
                }
            } catch {
                return failure(error, status: 400)
            }
            context.configChanged(updated.config)
            return .json(["ok": true, "cloud": cloudObject(updated, drives: drives, openlist: openlist, context: context)])
        case ("POST", "/api/cloud/mirrors/sync"):
            guard !engine.config.mirrorBackendIds.isEmpty else { return failure(code: "usage", message: "no mirrors to sync", status: 400) }
            let started = context.cloud.startDetailed("mirror-sync") { report in
                var current = engine
                if let latest = context.updatedConfig() { current.config = latest }
                let results = try current.syncMirrors { report($0.dictionary) }
                let rows: [[String: Any]] = results.keys.sorted().map { id in
                    var row = results[id]!.dictionary
                    row["id"] = id
                    return row
                }
                return ["mirrors": rows, "allOk": results.values.allSatisfy(\.ok)]
            }
            return started ? .json(["ok": true, "cloud": cloudObject(engine, drives: drives, openlist: openlist, context: context)], status: 202)
                : failure(code: "busy", message: "another cloud task is running", status: 409)
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
            let activeId = updated.config.activeRepoId
            updated.config.mirrorBackendIds.removeAll { $0 == activeId }
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
        object["activeId"] = engine.config.activeRepoId
        object["mirrors"] = engine.mirrorListing()
        return object
    }

    /// `POST /api/cloud/use` with `migrate: true`: copy the current repo onto the new one
    /// as a cloud task, then switch. The config stays on the old repo if anything fails.
    static func migrateRepo(engine: DisklesslyEngine, body: [String: Any], drives: CloudDrives, openlist: OpenListService, context: ManagementUIContext) -> UIResponse {
        var target = body["id"] as? String ?? ""
        if let remote = body["remote"] as? String {
            guard (try? drives.remotes())?.contains(remote) == true else { return failure(code: "usage", message: "unknown remote: \(remote)", status: 400) }
            do {
                let endpoint = try drives.endpoint(remote: remote)
                try store(endpoint, engine: engine, context: context)
                target = endpoint.id
            } catch {
                return failure(error, status: 400)
            }
        }
        var current = engine
        if let latest = context.updatedConfig() { current.config = latest }
        guard current.config.knowsRepo(target) else { return failure(code: "usage", message: "unknown backend: \(target)", status: 400) }
        guard target != current.config.activeRepoId else { return failure(code: "usage", message: "\(target) is already the active repo", status: 400) }
        let keep = body["keepOldAsMirror"] as? Bool ?? false
        let started = context.cloud.startDetailed("migrate") { report in
            var engine = current
            let result = try engine.switchRepo(to: target, migrate: true, keepOldAsMirror: keep, latest: { context.updatedConfig() }) { state in
                report(state.dictionary)
            }
            context.configChanged(engine.config)
            _ = context.health.current(engine, fresh: true)
            return result.dictionary
        }
        return started ? .json(["ok": true, "taskId": context.cloud.taskId ?? "", "cloud": cloudObject(current, drives: drives, openlist: openlist, context: context)], status: 202)
            : failure(code: "busy", message: "another cloud task is running", status: 409)
    }
}
