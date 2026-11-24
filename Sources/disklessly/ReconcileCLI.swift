import Foundation
import DisklesslyCore
import DisklesslyEngine

/// `disklessly reconcile`: explains the space no folder accounts for ("Not measured" on the dashboard)
/// and runs one confirmed action at a time. Nothing here is part of a bulk clean.
func runReconcile(engine: DisklesslyEngine, args: [String], json: Bool) throws {
    var rest = args
    let confirmed = rest.contains("--yes")
    rest.removeAll { $0 == "--yes" }
    if let bad = rest.first(where: { $0.hasPrefix("--") }) { throw DisklesslyError.usage("Unknown option: \(bad)") }
    let runner = LiveSystemCommandRunner.shared
    guard let verb = rest.first else {
        if !json { fputs("Measuring the disk (this reads sizes only and can take a few minutes)…\n", stderr) }
        let scan = UsageScan.run(engine: engine, runner: runner)
        let models = HiddenUsage.models(runner: runner, processes: HiddenUsage.runningProcesses())
        guard let facts = ReconcileReport.facts(in: scan.tree) else {
            let note = HostPlatform.current == .linux
                ? "Reconciliation of snapshots and the Spotlight index is macOS only."
                : "The folder scan accounts for all used space; nothing is hidden."
            if json {
                emit(["ok": true, "partial": scan.partial, "note": note, "models": models.map { $0.jsonObject() }] as [String: Any])
            } else {
                print(note)
                for m in models { print("\(sizeText(m.bytes))  \(m.location.title)  \(m.path)\(m.inUse ? "  (in use)" : "")") }
            }
            return
        }
        let report = ReconcileReport(facts: facts, models: models, partial: scan.partial)
        if json { emit(report.jsonObject()) } else { print(report.text(), terminator: "") }
        return
    }
    let action: String
    let plan: String
    switch verb {
    case "thin-snapshots":
        action = HiddenUsage.thinSnapshots
        plan = "Ask macOS to thin local Time Machine snapshots on / (tmutil thinlocalsnapshots / <bytes> 4). Files are not touched; restore points stored on this Mac go away."
    case "measure-spotlight":
        action = HiddenUsage.measureSpotlight
        plan = "Measure \(HiddenUsage.spotlightStore) with one administrator prompt (du -skx). Nothing is changed."
    case "rebuild-spotlight":
        action = HiddenUsage.rebuildSpotlight
        plan = "Erase and rebuild the Spotlight index of \(HiddenUsage.spotlightVolume) (mdutil -E, administrator prompt). Spotlight search and Mail search are incomplete for hours while macOS reindexes."
    case "offload-model", "delete-model":
        guard rest.count >= 2, let location = AIModelLocations.location(id: rest[1]) else {
            throw DisklesslyError.usage("usage: disklessly reconcile \(verb) ID   (IDs: \(AIModelLocations.all.map(\.id).joined(separator: ", ")))")
        }
        let offload = verb == "offload-model"
        action = (offload ? HiddenUsage.modelOffloadPrefix : HiddenUsage.modelTrashPrefix) + location.id
        plan = offload
            ? "Offload \(location.path(home: NSHomeDirectory())) into the repo (leaves a .disklessly placeholder). Refused while \(location.title) is in use."
            : "Move \(location.path(home: NSHomeDirectory())) to the Trash. Refused while \(location.title) is in use."
    default:
        throw DisklesslyError.usage("Unknown reconcile action: \(verb). Use thin-snapshots, measure-spotlight, rebuild-spotlight, offload-model ID or delete-model ID")
    }
    guard confirmed else {
        print(plan)
        throw DisklesslyError.usage("re-run with --yes to do this")
    }
    switch try HiddenUsage.perform(action, engine: engine, runner: runner) {
    case .done(let output):
        if json { emit(["ok": true, "action": action, "output": output] as [String: Any]) } else { print(output.isEmpty ? "Done." : output) }
    case .cancelled:
        if json { emit(["ok": false, "action": action, "cancelled": true] as [String: Any]) } else { print("Cancelled at the administrator prompt; nothing was changed.") }
        exit(1)
    }
}
