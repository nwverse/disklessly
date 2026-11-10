import Foundation
import DisklesslyCore
import DisklesslyEngine

enum RemoteCLI {
    static func run(args: [String], engine: DisklesslyEngine, json: Bool, emit: (Any) -> Void) throws {
        var rest = args
        let sub = rest.first ?? "list"
        if !rest.isEmpty { rest.removeFirst() }

        switch sub {
        case "list":
            let cards = engine.machinesSummary()
            let sshHosts = engine.sshConfigHosts()
            if json {
                emit([
                    "ok": true,
                    "machines": cards.map { $0.jsonObject() },
                    "sshConfigHosts": sshHosts.map { $0.jsonObject() },
                ])
                return
            }
            for card in cards {
                let kind = card.isLocal ? "local" : "ssh"
                let used = RecommendFormatting.byteText(card.usedBytes)
                let total = RecommendFormatting.byteText(card.totalBytes)
                let reclaim = RecommendFormatting.byteText(card.reclaimableBytes + card.offloadableBytes)
                print("\(card.displayName) (\(kind))  [\(card.level.rawValue)]  used \(used) / \(total)  reclaimable \(reclaim)")
            }

        case "add":
            guard let host = rest.first else {
                throw DisklesslyError.usage("remote add requires a host alias")
            }
            rest.removeFirst()
            var displayName: String?
            var rcloneRemote: String?
            while !rest.isEmpty {
                let flag = rest.removeFirst()
                switch flag {
                case "--name":
                    guard let val = rest.first else { throw DisklesslyError.usage("missing value for --name") }
                    rest.removeFirst()
                    displayName = val
                case "--rclone-remote":
                    guard let val = rest.first else { throw DisklesslyError.usage("missing value for --rclone-remote") }
                    rest.removeFirst()
                    rcloneRemote = val
                default:
                    throw DisklesslyError.usage("Unknown option: \(flag)")
                }
            }
            let added = try engine.addRemoteMachine(host: host, displayName: displayName, rcloneRemote: rcloneRemote)
            if json {
                emit(["ok": true, "host": added.host, "displayName": added.displayName ?? added.host])
            } else {
                print("Added remote machine \(added.host)")
            }

        case "remove":
            guard let host = rest.first else {
                throw DisklesslyError.usage("remote remove requires a host alias")
            }
            try engine.removeRemoteMachine(host: host)
            if json {
                emit(["ok": true, "host": host])
            } else {
                print("Removed remote machine \(host)")
            }

        case "scan":
            guard let host = rest.first else {
                throw DisklesslyError.usage("remote scan requires a host alias")
            }
            let report = try engine.scanRemoteMachine(host: host)
            let offloaded = (try? engine.listRemoteOffloaded(host: host)) ?? []
            if json {
                emit(report.jsonObject(offloaded: offloaded))
                return
            }
            print("Host: \(report.host) (\(report.hostname))  mode: \(report.scanMode)")
            for m in report.mounts {
                print("  mount \(m.mountPoint) (\(m.device), \(m.fsType)): \(RecommendFormatting.byteText(m.usedBytes)) / \(RecommendFormatting.byteText(m.totalBytes)) used, \(RecommendFormatting.byteText(m.availableBytes)) free")
            }
            if report.items.isEmpty {
                print("  no large cleanable or offloadable items found")
            } else {
                for item in report.items {
                    print("  [\(item.action.rawValue)] \(item.id)  \(RecommendFormatting.byteText(item.bytes))  \(item.title)  (\(item.path))")
                }
            }

        case "plan":
            guard rest.count >= 2 else {
                throw DisklesslyError.usage("remote plan requires <host> <clean|offload|restore> <target...>")
            }
            let host = rest.removeFirst()
            let action = rest.removeFirst()
            var mode = "relay"
            var targets: [String] = []
            while !rest.isEmpty {
                let arg = rest.removeFirst()
                if arg == "--mode" {
                    guard let val = rest.first else { throw DisklesslyError.usage("missing value for --mode") }
                    rest.removeFirst()
                    mode = val
                } else {
                    targets.append(arg)
                }
            }
            let plan = try engine.planRemoteAction(host: host, action: action, targets: targets, mode: mode)
            if json {
                emit(plan.jsonObject())
            } else {
                printPlan(plan)
            }

        case "clean":
            guard let host = rest.first else {
                throw DisklesslyError.usage("remote clean requires <host> <target...> [--dry-run] [--yes]")
            }
            rest.removeFirst()
            var dryRun = false
            var confirmed = false
            var targets: [String] = []
            for arg in rest {
                if arg == "--dry-run" { dryRun = true }
                else if arg == "--yes" { confirmed = true }
                else if arg.hasPrefix("--") { throw DisklesslyError.usage("Unknown option: \(arg)") }
                else { targets.append(arg) }
            }
            if !dryRun && !confirmed {
                let plan = try engine.planRemoteAction(host: host, action: "clean", targets: targets, mode: "clean")
                if !json { printPlan(plan) }
                throw DisklesslyError.usage("plan shown above; re-run with --yes to execute remote clean on \(host)")
            }
            let result = try engine.cleanRemoteMachine(host: host, targets: targets, dryRun: dryRun)
            if json {
                emit(result)
            } else if dryRun {
                let plan = try engine.planRemoteAction(host: host, action: "clean", targets: targets, mode: "clean")
                printPlan(plan)
            } else {
                let freed = (result["freedBytes"] as? NSNumber)?.uint64Value ?? 0
                for item in result["items"] as? [[String: Any]] ?? [] {
                    let id = item["id"] as? String ?? "?"
                    let scanned = (item["scannedBytes"] as? NSNumber)?.uint64Value ?? 0
                    let got = (item["freedBytes"] as? NSNumber)?.uint64Value ?? 0
                    let busy = item["skippedInUse"] as? [String] ?? []
                    let rc = item["exitCode"] as? Int ?? 0
                    var line = "  \(id)  scanned \(RecommendFormatting.byteText(scanned))  freed \(RecommendFormatting.byteText(got))"
                    if !busy.isEmpty { line += "  kept in use: \(busy.joined(separator: ", "))" }
                    if rc != 0 { line += "  (exit \(rc))" }
                    print(line)
                }
                print("Cleaned \(targets.count) item(s) on \(host), freed \(RecommendFormatting.byteText(freed)) (measured with df)")
            }

        case "offload":
            guard let host = rest.first else {
                throw DisklesslyError.usage("remote offload requires <host> <target> [--dry-run] [--yes] [--mode relay|direct]")
            }
            rest.removeFirst()
            var dryRun = false
            var confirmed = false
            var mode = "relay"
            var rcloneRemote: String?
            var target: String?
            while !rest.isEmpty {
                let arg = rest.removeFirst()
                switch arg {
                case "--dry-run": dryRun = true
                case "--yes": confirmed = true
                case "--mode":
                    guard let val = rest.first else { throw DisklesslyError.usage("missing value for --mode") }
                    rest.removeFirst()
                    mode = val
                case "--rclone-remote":
                    guard let val = rest.first else { throw DisklesslyError.usage("missing value for --rclone-remote") }
                    rest.removeFirst()
                    rcloneRemote = val
                default:
                    if arg.hasPrefix("--") { throw DisklesslyError.usage("Unknown option: \(arg)") }
                    target = arg
                }
            }
            guard let itemTarget = target else {
                throw DisklesslyError.usage("remote offload requires a target item id or path")
            }
            if !dryRun && !confirmed {
                let plan = try engine.planRemoteAction(host: host, action: "offload", targets: [itemTarget], mode: mode)
                if !json { printPlan(plan) }
                throw DisklesslyError.usage("plan shown above; re-run with --yes to execute remote offload on \(host)")
            }
            let result = try engine.offloadRemoteItem(host: host, target: itemTarget, mode: mode, rcloneRemote: rcloneRemote, dryRun: dryRun)
            if json {
                emit(result)
            } else if dryRun {
                let plan = try engine.planRemoteAction(host: host, action: "offload", targets: [itemTarget], mode: mode)
                printPlan(plan)
            } else if let rec = result["record"] as? [String: Any], let id = rec["id"] as? String {
                print("Offloaded \(itemTarget) from \(host) to repo (record \(id))")
            }

        case "restore":
            guard rest.count >= 2 else {
                throw DisklesslyError.usage("remote restore requires <host> <record-id-or-path> [--dry-run] [--yes]")
            }
            let host = rest.removeFirst()
            let target = rest.removeFirst()
            var dryRun = false
            for arg in rest {
                if arg == "--dry-run" { dryRun = true }
                else if arg == "--yes" { continue }
                else if arg.hasPrefix("--") { throw DisklesslyError.usage("Unknown option: \(arg)") }
            }
            let result = try engine.restoreRemoteItem(host: host, recordIdOrPath: target, dryRun: dryRun)
            if json {
                emit(result)
            } else if dryRun {
                let plan = try engine.planRemoteAction(host: host, action: "restore", targets: [target], mode: "relay")
                printPlan(plan)
            } else {
                print("Restored \(result["restoredPath"] as? String ?? target) on \(host)")
            }

        case "deploy":
            guard let host = rest.first else {
                throw DisklesslyError.usage("remote deploy requires <host>")
            }
            let force = rest.contains("--force")
            let result = try engine.deployRemoteBinary(host: host, force: force)
            if json {
                emit(result)
            } else {
                print("Deployed disklessly to \(host): \(result["version"] as? String ?? "")")
            }

        case "recover":
            guard let host = rest.first else {
                throw DisklesslyError.usage("remote recover requires <host>")
            }
            let actions = try engine.recoverRemoteJournals(host: host)
            if json {
                emit(["ok": true, "host": host, "recovered": actions])
            } else {
                print("Recovered \(actions.count) journal(s) for \(host)")
            }

        default:
            throw DisklesslyError.usage("Unknown remote command: \(sub). Expected list, add, remove, scan, plan, clean, offload, restore, deploy, or recover")
        }
    }

    private static func printPlan(_ plan: RemoteActionPlan) {
        print("Plan (\(plan.action), mode=\(plan.mode), dryRun=\(plan.dryRun)) for \(plan.host): total \(RecommendFormatting.byteText(plan.totalBytes))")
        for item in plan.items {
            print("  \(item.id)  \(item.path)  \(RecommendFormatting.byteText(item.bytes))  recoverable=\(item.recoverable)")
        }
    }
}
