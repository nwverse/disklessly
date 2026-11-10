import Foundation
import DisklesslyCore

/// Tracks background SSH scan and action states per remote machine for the Dashboard UI.
public final class RemoteMachinesState: @unchecked Sendable {
    private let lock = NSLock()
    private var scanningHosts = Set<String>()
    private var busyHosts = Set<String>()
    private var lastErrors: [String: String] = [:]

    public init() {}

    public func beginScan(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if scanningHosts.contains(host) { return false }
        scanningHosts.insert(host)
        lastErrors[host] = nil
        return true
    }

    public func endScan(_ host: String, error: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        scanningHosts.remove(host)
        lastErrors[host] = error
    }

    public func isScanning(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return scanningHosts.contains(host)
    }

    public func beginAction(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busyHosts.contains(host) { return false }
        busyHosts.insert(host)
        return true
    }

    public func endAction(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        busyHosts.remove(host)
    }

    public func error(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastErrors[host]
    }
}

/// `/api/machines*` endpoints for the Dashboard Machines page (#46 §4).
extension ManagementUI {
    static func machinesAPI(engine: DisklesslyEngine, request: UIRequest, context: ManagementUIContext) -> UIResponse {
        let body = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]) ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/api/machines"):
            return .json(machinesOverviewObject(engine: engine, context: context))

        case ("GET", "/api/machines/detail"):
            let host = (request.query["host"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                return failure(code: "bad_request", message: "missing host parameter", status: 400)
            }
            guard SSHConfigParser.isConcreteHost(host) else {
                return failure(code: "bad_request", message: "invalid host parameter", status: 400)
            }
            return .json(machineDetailObject(engine: engine, host: host, context: context))

        case ("POST", "/api/machines/add"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (body["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rcloneRemote = (body["rcloneRemote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try engine.addRemoteMachine(host: host, displayName: displayName, rcloneRemote: rcloneRemote)
                return .json(machinesOverviewObject(engine: engine, context: context))
            } catch {
                return failure(error, status: 400)
            }

        case ("POST", "/api/machines/remove"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try engine.removeRemoteMachine(host: host)
                return .json(machinesOverviewObject(engine: engine, context: context))
            } catch {
                return failure(error, status: 400)
            }

        case ("POST", "/api/machines/scan"):
            let host = (body["host"] as? String ?? request.query["host"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                return failure(code: "bad_request", message: "missing host", status: 400)
            }
            guard SSHConfigParser.isConcreteHost(host) else {
                return failure(code: "bad_request", message: "invalid host", status: 400)
            }
            let sync = (body["sync"] as? Bool == true) || (request.query["sync"] == "1")
            if sync {
                guard context.machines.beginScan(host) else {
                    return failure(code: "busy", message: "scan already running for \(host)", status: 409)
                }
                do {
                    let report = try engine.scanRemoteMachine(host: host)
                    context.machines.endScan(host, error: nil)
                    let offloaded = (try? engine.listRemoteOffloaded(host: host)) ?? []
                    return .json(report.jsonObject(offloaded: offloaded))
                } catch {
                    let info = errorInfo(error)
                    context.machines.endScan(host, error: info.message)
                    return failure(error, status: 500)
                }
            }
            guard context.machines.beginScan(host) else {
                return .json(["ok": true, "host": host, "state": "scanning"], status: 202)
            }
            let eng = engine
            let machinesState = context.machines
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try eng.scanRemoteMachine(host: host)
                    machinesState.endScan(host, error: nil)
                } catch {
                    let info = ManagementUI.errorInfo(error)
                    machinesState.endScan(host, error: info.message)
                }
            }
            return .json(["ok": true, "host": host, "state": "scanning"], status: 202)

        case ("POST", "/api/machines/plan"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let action = (body["action"] as? String ?? "offload").trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = (body["mode"] as? String ?? "relay").trimmingCharacters(in: .whitespacesAndNewlines)
            let targets: [String]
            if let arr = body["targets"] as? [String] {
                targets = arr
            } else if let single = body["target"] as? String, !single.isEmpty {
                targets = [single]
            } else {
                targets = []
            }
            do {
                let plan = try engine.planRemoteAction(host: host, action: action, targets: targets, mode: mode)
                return .json(plan.jsonObject())
            } catch {
                return failure(error, status: 400)
            }

        case ("POST", "/api/machines/clean"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let dryRun = body["dryRun"] as? Bool ?? false
            let targets: [String]
            if let arr = body["targets"] as? [String] {
                targets = arr
            } else if let single = body["target"] as? String, !single.isEmpty {
                targets = [single]
            } else {
                targets = []
            }
            if !dryRun {
                guard context.machines.beginAction(host) else {
                    return failure(code: "busy", message: "another operation is running on \(host)", status: 409)
                }
            }
            defer { if !dryRun { context.machines.endAction(host) } }
            do {
                let result = try engine.cleanRemoteMachine(host: host, targets: targets, dryRun: dryRun)
                return .json(result)
            } catch {
                return failure(error, status: 400)
            }

        case ("POST", "/api/machines/offload"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let target = (body["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = (body["mode"] as? String ?? "relay").trimmingCharacters(in: .whitespacesAndNewlines)
            let dryRun = body["dryRun"] as? Bool ?? false
            if !dryRun {
                guard context.machines.beginAction(host) else {
                    return failure(code: "busy", message: "another operation is running on \(host)", status: 409)
                }
            }
            defer { if !dryRun { context.machines.endAction(host) } }
            do {
                let result = try engine.offloadRemoteItem(host: host, target: target, mode: mode, dryRun: dryRun)
                return .json(result)
            } catch {
                return failure(error, status: 400)
            }

        case ("POST", "/api/machines/restore"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let target = (body["target"] as? String ?? body["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let dryRun = body["dryRun"] as? Bool ?? false
            if !dryRun {
                guard context.machines.beginAction(host) else {
                    return failure(code: "busy", message: "another operation is running on \(host)", status: 409)
                }
            }
            defer { if !dryRun { context.machines.endAction(host) } }
            do {
                let result = try engine.restoreRemoteItem(host: host, recordIdOrPath: target, dryRun: dryRun)
                return .json(result)
            } catch {
                return failure(error, status: 400)
            }

        case ("POST", "/api/machines/deploy"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard context.machines.beginAction(host) else {
                return failure(code: "busy", message: "another operation is running on \(host)", status: 409)
            }
            defer { context.machines.endAction(host) }
            do {
                let result = try engine.deployRemoteBinary(host: host)
                return .json(result)
            } catch {
                return failure(error, status: 400)
            }

        case ("POST", "/api/machines/recover"):
            let host = (body["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard context.machines.beginAction(host) else {
                return failure(code: "busy", message: "another operation is running on \(host)", status: 409)
            }
            defer { context.machines.endAction(host) }
            do {
                let actions = try engine.recoverRemoteJournals(host: host)
                return .json(["ok": true, "host": host, "recovered": actions])
            } catch {
                return failure(error, status: 400)
            }

        default:
            return .text(404, "not found")
        }
    }

    private static func machinesOverviewObject(engine: DisklesslyEngine, context: ManagementUIContext) -> [String: Any] {
        var cards = engine.machinesSummary()
        cards = cards.map { card in
            guard !card.isLocal else { return card }
            var copy = card
            if let err = context.machines.error(for: card.host) {
                copy.reachable = false
                copy.level = .offline
                copy.lastError = err
            }
            return copy
        }
        let sorted = MachineOrdering.sort(cards)
        let sshDiscovered = engine.sshConfigHosts().map { $0.jsonObject() }
        let scanningHosts = sorted.filter { !$0.isLocal && context.machines.isScanning($0.host) }.map(\.host)
        return [
            "ok": true,
            "machines": sorted.map { card -> [String: Any] in
                var obj = card.jsonObject()
                obj["scanning"] = !card.isLocal && context.machines.isScanning(card.host)
                return obj
            },
            "sshConfigHosts": sshDiscovered,
            "scanning": !scanningHosts.isEmpty,
            "scanningHosts": scanningHosts,
        ]
    }

    private static func machineDetailObject(engine: DisklesslyEngine, host: String, context: ManagementUIContext) -> [String: Any] {
        let cached = RemoteMachineStore.loadCachedScan(stateDir: engine.config.stateDir, host: host)
        let offloaded = (try? engine.listRemoteOffloaded(host: host)) ?? []
        let journals = RemoteMachineStore.loadJournals(stateDir: engine.config.stateDir, host: host)
        let scanning = context.machines.isScanning(host)
        let lastError = context.machines.error(for: host) ?? RemoteMachineStore.loadAttemptStatus(stateDir: engine.config.stateDir, host: host)?.lastError

        if let cached {
            var obj = cached.jsonObject(offloaded: offloaded)
            obj["state"] = scanning ? "scanning" : "ready"
            obj["journals"] = journals.map { $0.jsonObject() }
            if let lastError { obj["lastError"] = lastError }
            return obj
        }
        var empty: [String: Any] = [
            "ok": true,
            "host": host,
            "state": scanning ? "scanning" : "idle",
            "mounts": [] as [[String: Any]],
            "items": [] as [[String: Any]],
            "recommendations": [] as [[String: Any]],
            "offloaded": offloaded.map { $0.jsonObject() },
            "journals": journals.map { $0.jsonObject() },
        ]
        if let lastError { empty["lastError"] = lastError }
        return empty
    }
}
