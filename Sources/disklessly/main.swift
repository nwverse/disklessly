import Foundation
import DisklesslyCore
import DisklesslyEngine
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let helpText = """
disklessly: keep rarely used Mac apps in a repo and open them on demand.
Usage: disklessly [--json] [--config PATH] [--state-dir PATH] <command> [options]

Get started
  init [--backend local|icloud] [--root DIR] [--cache-dir DIR]
  recommend [--all] [--min-size SIZE] [--limit N] [--min-idle-days N]
  pack APP.app [--mode mount|restore] [--image-format ULMO|ULFO] [--no-stub] [--keep-original] [--stub-dir DIR]
  ui [--open]                     dashboard on 127.0.0.1 (prints its URL; --json prints url, port, token)

Use offloaded apps
  list | status [APP]
  launch APP [--doc PATH] [--url URL] [--arg ARG] [--no-wait]
  restore APP                     launch with restore mode forced
  resolve APP --keep-updated|--trust|--export DIR|--discard
  prefetch APP | pin APP | unpin APP | evict APP [--force]
  detach APP [--force]            eject a mount-mode app's image now (refused while it runs)
  license [status]                show the free limit and your license
  license activate CODE | deactivate   enter or remove a license code (offload more than 2 apps)

Bring an app back
  unpack APP [--to DIR]           put the real app back in place of its stub (or copy it to DIR)

Keep things tidy
  gc [--dry-run] [--include-legacy]
  evict-local | cleanup-backups | doctor [--fix] | reap [--dry-run]
  caches [--apply]                list (or with --apply clear) the caches of offloaded apps that are not running
  install-engine | stub refresh --app ID|--all [--adopt] | icons backfill [--app ID]

Repos and Macs
  backend add smb|nfs|webdav|openlist ... | backend list | backend use ID
  devices [list] | devices rename NAME | devices forget DEVICEID --yes

Coding-agent sessions
  sessions [--apply] [--days N] [--home DIR] [--encrypt] | sessions search QUERY [--limit N]
  sessions restore ID|PATH [--to PATH] | sessions reindex | sessions migrate | sessions verify [--legacy]
  sessions key init | sessions key status

Other
  version | help

gc replays local journals, applies the repo garbage rules, and enforces the cache quota.
gc --dry-run prints trash candidates, legacy images, and cache LRU victims and changes nothing.
doctor --fix replays local unpack and restore journals and reaps orphan mounts.
caches only empties ~/Library/Caches/<id or name> and a container's Data/Library/Caches;
  Application Support and other app data are never touched, and a running app is skipped.
reap detaches idle images left attached under the mount root (e.g. after a watcher crash).
evict --force only overrides a pin; a mounted or running image is always refused.
--json is accepted before or after the command. Without it, output is meant for people.
Environment overrides: DISKLESSLY_REPO_PATH, DISKLESSLY_CACHE_DIR, DISKLESSLY_STATE_DIR,
  DISKLESSLY_MOUNT_ROOT, DISKLESSLY_STUB_DIR, DISKLESSLY_CONFIG, DISKLESSLY_DETACH_DELAY,
  DISKLESSLY_QUOTA_BYTES, DISKLESSLY_MIN_FREE_BYTES, DISKLESSLY_SIGN_IDENTITY,
  DISKLESSLY_DOCTOR_TIMEOUT, DISKLESSLY_WEB_ROOT, DISKLESSLY_DEBUG
"""
func usage() -> Never {
    print(helpText)
    exit(0)
}
/// `disklessly` with no command. Exit 64 is EX_USAGE from sysexits(3).
func noCommand() -> Never {
    fputs("disklessly: no command given.\nRun `disklessly help` for the commands, `disklessly recommend` to find apps worth offloading, or `disklessly ui --open` for the dashboard.\n", stderr)
    exit(64)
}
let invocation: GlobalArguments
do { invocation = try GlobalArguments.parse(Array(CommandLine.arguments.dropFirst())) }
catch let error as DisklesslyError {
    fputs("disklessly: \(error.errorDescription ?? String(describing: error))\n", stderr)
    exit(Int32(error.exitCode))
}
var args=invocation.rest; var json=invocation.json
let env=ProcessInfo.processInfo.environment
let configPath=env["DISKLESSLY_CONFIG"] ?? invocation.configPath
if let stateDir=invocation.stateDir { setenv("DISKLESSLY_STATE_DIR", stateDir, 1) }
// `ProcessInfo.environment` can miss a setenv from this process. `--state-dir`
// is applied as an override, and `<stateDir>/config.json` is loaded unless
// `--config` / `DISKLESSLY_CONFIG` replaces it. Path env vars win over the file.
var config=RuntimeConfig.resolved(environment:env, home:NSHomeDirectory(), stateDirOverride:invocation.stateDir, explicitConfig:configPath)
if let n=env["DISKLESSLY_DETACH_DELAY"].flatMap(UInt64.init) { config.detachDelaySeconds=n }
var engine=DisklesslyEngine(config:config)
func emit(_ data:Any) { if json, JSONSerialization.isValidJSONObject(data), let d=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]), let s=String(data:d,encoding:.utf8) { print(s) } else { print(data) } }
func sizeText(_ bytes: UInt64) -> String { RecommendFormatting.byteText(bytes) }
func printVersionLine() { print("disklessly \(EngineInstall.version) (\(EngineInstall.commit), built \(EngineInstall.buildDate), \(EngineInstall.arch)) revision \(EngineInstall.revision) schema image/1") }
/// `--json` prints `object`; otherwise `text` is printed for people.
func say(_ object: @autoclosure () -> Any, _ text: @autoclosure () -> String) { if json { emit(object()) } else { print(text()) } }
func printImageList(_ manifests: [ImageManifest]) {
    if manifests.isEmpty { print("no images"); return }
    for manifest in manifests {
        print("\(manifest.name)  \(manifest.version)  \(sizeText(manifest.image.size))  \(manifest.bundleId)  \(manifest.imageId)  \(manifest.mode.rawValue)")
    }
}
func printDevices(_ listing: DeviceListing, names: [String: String], sizes: [String: UInt64]) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if listing.devices.isEmpty && listing.placeholders.isEmpty && listing.conflicts.isEmpty {
        print("no devices")
        return
    }
    for device in listing.devices {
        let mark = device.deviceId == listing.localDeviceId ? "self" : "other"
        let name = device.displayName.isEmpty ? device.hostname : device.displayName
        print("\(mark)  \(name)  \(device.deviceId)  \(device.arch)  \(device.osVersion)  last seen \(formatter.string(from: device.lastSeen))")
        if device.images.isEmpty { print("  (no images)") }
        for image in device.images {
            let title = names[image.imageId] ?? image.bundleId
            let arch = image.architectures.isEmpty ? "" : "  \(image.architectures.joined(separator: "+"))"
            let size = sizes[image.imageId].map { "  \(sizeText($0))" } ?? ""
            print("  \(title)  \(image.version)  \(image.bundleId)  \(image.imageId)  \(image.mode)\(arch)\(size)")
        }
    }
    for name in listing.placeholders { print("placeholder  \(name)") }
    for name in listing.conflicts { print("conflict  \(name)") }
}
func printEvict(_ report: LocalEvictReport, files: [MaterialFile]) {
    var sizes: [String: UInt64] = [:]
    for file in files { sizes[file.relativePath] = file.logicalBytes }
    func decorated(_ line: String) -> String {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? Substring(line))
        guard let bytes = sizes[path] else { return line }
        let suffix = " (\(sizeText(bytes)))"
        if parts.count == 2 { return "\(path)\(suffix):\(parts[1])" }
        return path + suffix
    }
    var count = 0
    for path in report.evicted { print("evicted  \(decorated(path))"); count += 1 }
    for line in report.retryLater { print("retry later  \(decorated(line))"); count += 1 }
    for line in report.skipped { print("skipped  \(decorated(line))"); count += 1 }
    if count == 0 { print("nothing to evict") }
}
func liveSessionOpen(_ path: String) -> Bool {
    let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let lsof else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lsof)
    process.arguments = ["-Fn", "--", path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return OpenFileProbe.isOpen(lsofStatus: process.terminationStatus, lsofStdout: text, path: path)
}
func serveUntilSignaled(_ server: LoopbackUIServer) -> Never {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let stop = {
        server.stop()
        exit(0)
    }
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler(handler: stop)
    term.resume()
    let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intr.setEventHandler(handler: stop)
    intr.resume()
    dispatchMain()
}
/// A stub bundle path (e.g. `/Applications/Foo.app`) resolves through its `stub.json` image id.
func stubImageId(_ name: String) -> String? {
    guard name.hasSuffix(".app") || name.hasSuffix(".app/") else { return nil }
    let stubJSON = URL(fileURLWithPath: name).appendingPathComponent("Contents/Resources/stub.json")
    guard let data = try? Data(contentsOf: stubJSON),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let imageId = object["imageId"] as? String, !imageId.isEmpty else { return nil }
    return imageId
}
/// Stable machine key for a refusal, printed as `error.reason` with `--json`.
var errorReason: String?
func refuse(_ refusal: LifecycleRefusal) throws -> Never {
    errorReason = refusal.reason
    throw refusal.error
}
/// `APP [--force]`: the app name and whether `--force` was given.
func appAndForce(_ command: String, _ args: [String]) throws -> (String, Bool) {
    var name: String?
    var force = false
    for arg in args {
        if arg == "--force" { force = true }
        else if arg.hasPrefix("--") { throw DisklesslyError.usage("Unknown option: \(arg)") }
        else if name == nil { name = arg }
        else { throw DisklesslyError.usage("\(command) takes one app") }
    }
    guard let name else { throw DisklesslyError.usage("\(command) requires app") }
    return (name, force)
}
func exitName(_ code: Int) -> String {
    switch code {
    case 1: "EX_FAILURE"
    case 2: "EX_USAGE"
    case 3: "EX_UNSUPPORTED"
    case 4: "EX_BACKEND"
    case 5: "EX_INTEGRITY"
    case 6: "EX_DISKIMAGE"
    case 8: "EX_NOSPACE"
    case 9: "EX_BUSY"
    case 10: "EX_HOOK"
    case 14: "EX_RESOLUTION"
    default: "EX_FAILURE"
    }
}
func find(_ name:String) throws -> ImageManifest {
    let manifests = try engine.list()
    if let imageId = stubImageId(name), let m = manifests.first(where: { $0.imageId == imageId }) { return m }
    guard let m=engine.manifest(named: name, in: manifests) else {
        throw DisklesslyError.usage(CLIText.unknownApp(name, suggestions: CLIText.suggestions(for: name, in: manifests)))
    }
    return m
}
func openInBrowser(_ url: String) {
    #if os(macOS)
    let tool = "/usr/bin/open"
    #else
    let tool = "/usr/bin/xdg-open"
    #endif
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = [url]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    if (try? process.run()) == nil { fputs("disklessly: could not open a browser; open the URL yourself\n", stderr) }
}
do {
    guard let command=args.first else { noCommand() }; args.removeFirst()
    // The stub is a session leader. A hangup must not kill `launch` / `hook watch`
    // before the journal reaches a terminal phase. SIGKILL faults still apply.
    if command == "launch" || command == "hook" || command == "restore" {
        signal(SIGHUP, SIG_IGN)
    }
    switch command {
    case "help", "--help", "-h": usage()
    case "version":
        if json { emit(["version":EngineInstall.version,"revision":EngineInstall.revision,"schema":"image/1","commit":EngineInstall.commit,"buildDate":EngineInstall.buildDate,"arch":EngineInstall.arch,"schemas":["stub":"stub/1","state":"state/2","image":"image/1"]] as [String: Any]) }
        else { printVersionLine() }
    case "init":
        while !args.isEmpty { let a=args.removeFirst(); if a=="--backend", !args.isEmpty { config.backend=args.removeFirst() } else if a=="--root", !args.isEmpty { config.repoPath=args.removeFirst() } else if a=="--cache-dir", !args.isEmpty { config.cacheDir=args.removeFirst() } }
        try DisklesslyEngine(config:config).initialize()
        say(["ok":true,"repo":config.repoPath,"cacheDir":config.cacheDir,"quotaBytes":NSNumber(value: config.quotaBytes)], CLIText.initialized(config))
    case "pack":
        let parsed = try PackArguments.parse(args)
        if let stubDir = parsed.stubDir { config.stubDir = stubDir; engine = DisklesslyEngine(config: config) }
        let published=try engine.pack(parsed.app,mode:parsed.mode,keepOriginal:parsed.keepOriginal,noStub:parsed.noStub,imageFormat:parsed.imageFormat); let m=published.manifest
        let path = parsed.app
        if json { for warning in published.warnings { fputs("disklessly: \(warning)\n", stderr) } }
        for path in published.evicted { fputs("disklessly: evicted local iCloud copy \(path)\n", stderr) }
        if let kept = published.originalKept {
            let retained = URL(fileURLWithPath: config.stubDir).appendingPathComponent(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".256orig.app")
            fputs("disklessly: kept original at \(retained.path): \(kept)\n", stderr)
        }
        var packed: [String: Any] = ["ok":true,"imageId":m.imageId,"bundleId":m.bundleId,"mode":m.mode.rawValue,"sha256":m.image.sha256,"reused":published.reused,"uploaded":published.uploaded,"warnings":published.warnings,"evicted":published.evicted]
        if let kept = published.originalKept { packed["originalKept"] = kept }
        say(packed, CLIText.packed(published, appPath: path, stubDir: config.stubDir, noStub: parsed.noStub, keepOriginal: parsed.keepOriginal))
    case "list":
        let manifests = try engine.list()
        if json { emit(manifests.map { ["imageId":$0.imageId,"bundleId":$0.bundleId,"name":$0.name,"version":$0.version,"mode":$0.mode.rawValue,"iconPath": AppIcon.existingPath(stateDir: config.stateDir, repoPath: config.repoPath, imageId: $0.imageId) ?? ""] }) }
        else { printImageList(manifests) }
    case "status":
        if json { emit(engine.status()) }
        else { print(CLIText.status(config, state: StateStore(config.stateDir).load(), app: args.first)) }
    case "prefetch":
        guard let n=args.first else { throw DisklesslyError.usage("prefetch requires app") }
        let m=try find(n); let cached=try engine.prefetch(m).path
        say(["ok":true,"path":cached], CLIText.prefetched(m, path: cached))
    case "launch":
        let parsed=try LaunchArguments.parse(args)
        let manifest=try find(parsed.app)
        try engine.launch(manifest,documents:parsed.documents,urls:parsed.urls,arguments:parsed.arguments,wait:parsed.wait)
        say(["ok":true], CLIText.launched(manifest, wait: parsed.wait, restore: manifest.mode == .restore))
    case "restore":
        let parsed=try LaunchArguments.parse(args)
        var manifest=try find(parsed.app)
        manifest.mode = .restore
        try engine.launch(manifest,documents:parsed.documents,urls:parsed.urls,arguments:parsed.arguments,wait:parsed.wait)
        say(["ok":true], CLIText.launched(manifest, wait: parsed.wait, restore: true))
    case "unpack":
        let parsed = try UnpackArguments.parse(args)
        let manifest = try find(parsed.app)
        try engine.unpack(manifest, to: parsed.directory)
        say(["ok": true], CLIText.unpacked(manifest, to: parsed.directory))
    case "pin", "unpin":
        guard let n=args.first else { throw DisklesslyError.usage("\(command) requires app") }
        let manifest=try find(n)
        try engine.setPinned(manifest, pinned: command=="pin")
        say(["ok":true,"pinned":command=="pin"], CLIText.pinned(manifest, pinned: command=="pin"))
    case "evict":
        let (n, force) = try appAndForce("evict", args)
        let manifest=try find(n)
        if let refusal = engine.evictRefusal(manifest, force: force) { try refuse(refusal) }
        try engine.evict(manifest, force: force)
        say(["ok":true], CLIText.evicted(manifest))
    case "license":
        let sub = args.first ?? "status"
        switch sub {
        case "status":
            let state = License.load(stateDir: config.stateDir)
            let offloaded = (try? engine.offloadedBundleIdCount()) ?? 0
            say(CLIText.licenseDictionary(state, offloaded: offloaded), CLIText.licenseStatus(state, offloaded: offloaded))
        case "activate":
            guard args.count == 2 else { throw DisklesslyError.usage("usage: disklessly license activate CODE") }
            let payload = try License.activate(args[1], stateDir: config.stateDir)
            say(CLIText.licenseDictionary(.licensed(payload), offloaded: 0), CLIText.licenseActivated(payload))
        case "deactivate":
            try License.deactivate(stateDir: config.stateDir)
            say(["ok": true], "License removed. The free limit of \(License.freeAppLimit) offloaded apps applies again; apps already offloaded keep working.")
        default:
            throw DisklesslyError.usage("usage: disklessly license [status | activate CODE | deactivate]")
        }
    case "detach":
        let (n, force) = try appAndForce("detach", args)
        let manifest=try find(n)
        if let refusal = engine.detachRefusal(manifest) { try refuse(refusal) }
        let report = try engine.detach(manifest, force: force)
        let text = report.outcome == .detached ? "Detached \(manifest.name)'s disk image from \(report.mountPoint)." : "\(manifest.name)'s disk image is not mounted."
        say(["ok":true,"outcome":report.outcome.rawValue,"mountPoint":report.mountPoint,"forced":report.forced], text)
    case "reap":
        var dryRun = false
        while let flag = args.first {
            args.removeFirst()
            if flag == "--dry-run" { dryRun = true }
            else if flag == "--help" || flag == "-h" { usage() }
            else { throw DisklesslyError.usage("Unknown option: \(flag)") }
        }
        let report = engine.reapOrphanMounts(dryRun: dryRun)
        if json { emit(report.jsonObject()) }
        else { print(report.lines.isEmpty ? "no orphan mounts" : report.lines.joined(separator: "\n")) }
        if !report.failed.isEmpty { exit(6) }
    case "evict-local":
        let files = engine.materialFiles()
        let eviction = engine.evictLocalCopies()
        if json {
            for path in eviction.evicted { fputs("disklessly: evicted local iCloud copy \(path)\n", stderr) }
            for line in eviction.retryLater { fputs("disklessly: \(line)\n", stderr) }
            emit(["ok":true,"evicted":eviction.evicted,"retryLater":eviction.retryLater,"skipped":eviction.skipped])
        } else {
            printEvict(eviction, files: files)
        }
    case "caches":
        var apply = false
        while let flag = args.first {
            args.removeFirst()
            if flag == "--apply" { apply = true }
            else if flag == "--dry-run" { apply = false }
            else if flag == "--help" || flag == "-h" { usage() }
            else { throw DisklesslyError.usage("Unknown option: \(flag)") }
        }
        let report = try engine.clearAppCaches(apply: apply)
        say(report.jsonObject(), report.text)
        if !report.failed.isEmpty { exit(6) }
    case "cleanup-backups":
        let cleaned = try engine.cleanupBackups()
        for path in cleaned.removed { fputs("disklessly: removed \(path)\n", stderr) }
        for line in cleaned.kept { fputs("disklessly: kept \(line)\n", stderr) }
        emit(["ok":true,"removed":cleaned.removed,"kept":cleaned.kept])
    case "gc":
        var includeLegacy = false
        var dryRun = false
        while let flag = args.first {
            args.removeFirst()
            if flag == "--include-legacy" { includeLegacy = true }
            else if flag == "--dry-run" { dryRun = true }
            else if flag == "--help" || flag == "-h" { usage() }
            else { throw DisklesslyError.usage("Unknown option: \(flag)") }
        }
        if dryRun {
            let plan = try engine.gcDryRun(includeLegacy: includeLegacy)
            if json {
                emit(["ok": true, "dryRun": true, "trash": plan.trash, "restore": plan.restoreFromTrash, "purge": plan.purge, "legacy": plan.legacy, "lru": plan.lru, "warnings": plan.warnings])
            } else {
                print(plan.text(), terminator: "")
            }
            break
        }
        // gc replays journals, runs repo maintenance, and enforces the cache quota.
        let lines = try engine.gc(includeLegacy: includeLegacy)
        say(["ok": true, "lines": lines], CLIText.gc(lines))
    case "devices":
        let sub = args.first ?? "list"
        if !args.isEmpty { args.removeFirst() }
        switch sub {
        case "list":
            let listing = try engine.deviceListing()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let payload: [String: Any] = ["devices": listing.devices.map { device in
                ["deviceId": device.deviceId, "displayName": device.displayName, "hostname": device.hostname, "arch": device.arch, "osVersion": device.osVersion, "lastSeen": formatter.string(from: device.lastSeen), "self": device.deviceId == listing.localDeviceId, "images": device.images.map { ["imageId": $0.imageId, "bundleId": $0.bundleId, "version": $0.version, "build": $0.build, "architectures": $0.architectures, "mode": $0.mode] }]
            }, "placeholders": listing.placeholders, "conflicts": listing.conflicts]
            if json { emit(payload) }
            else {
                var names: [String: String] = [:]
                var sizes: [String: UInt64] = [:]
                if let manifests = try? engine.list() {
                    for manifest in manifests {
                        names[manifest.imageId] = manifest.name
                        sizes[manifest.imageId] = manifest.image.size
                    }
                }
                printDevices(listing, names: names, sizes: sizes)
            }
        case "rename":
            let name = args.joined(separator: " ")
            guard !name.isEmpty else { throw DisklesslyError.usage("devices rename requires a name") }
            let record = try engine.renameDevice(to: name)
            emit(["ok": true, "deviceId": record.deviceId, "displayName": record.displayName])
        case "forget":
            guard let id = args.first else { throw DisklesslyError.usage("devices forget requires a device id and --yes") }
            args.removeFirst()
            try engine.forgetDevice(id: id, confirmed: args.contains("--yes"))
            emit(["ok": true, "forgot": id])
        default:
            throw DisklesslyError.usage("Unknown devices command: \(sub)")
        }
    case "recommend":
        let parsed = try RecommendArguments.parse(args)
        if parsed.json { json = true }
        let report = engine.recommend(options: parsed.options())
        if json { emit(report.jsonObject()) } else { print(report.text(), terminator: "") }
    case "doctor":
        let fixing = args.first == "--fix"
        let report = engine.doctor(fix: fixing) { check in
            guard !json else { return }
            fputs(DoctorFormatting.line(check) + "\n", stdout)
            fflush(stdout)
        }
        if let hint = report["iconHint"] as? String, !json {
            fputs(hint + "\n", stdout)
        }
        if json { emit(report) }
        if (report["needsAttention"] as? Bool) == true { exit(14) }
        exit((report["ok"] as? Bool) == true ? 0 : 1)
    case "hook":
        guard args.first == "watch" else { throw DisklesslyError.usage("hook watch requires --app") }
        args.removeFirst()
        guard args.first == "--app", args.count >= 2 else { throw DisklesslyError.usage("hook watch requires --app") }
        try engine.watch(appId: args[1]); emit(["ok":true])
    case "resolve":
        guard let name=args.first else { throw DisklesslyError.usage("resolve requires an app") }
        args.removeFirst()
        var discard=false, trust=false, keep=false, export:String?
        while let flag=args.first {
            args.removeFirst()
            if flag == "--discard" { discard=true }
            else if flag == "--keep-updated" { keep=true }
            else if flag == "--trust" { trust=true }
            else if flag == "--export", let dir=args.first { export=dir; args.removeFirst() }
            else { throw DisklesslyError.usage("Unknown option or missing value: \(flag)") }
        }
        try engine.resolve(find(name), keepUpdated: keep, trust: trust, export: export, discard: discard); emit(["ok":true])
    case "sessions":
        let parsed = try SessionsArguments.parse(args)
        let secrets = engine.secrets
        switch parsed.command {
        case .tier:
            let report = try SessionArchive.tier(config: config, backend: engine.repo, apply: parsed.apply, coldDays: parsed.days, home: parsed.home, isOpen: liveSessionOpen, secrets: secrets, encrypt: parsed.encrypt)
            emit(["ok": true, "applied": report.applied, "cold": report.cold, "skipped": report.skipped.map { ["path": $0.0, "reason": $0.1] }, "keptLocal": report.keptLocal.map { ["path": $0.0, "reason": $0.1] }, "segments": report.segments])
        case .search:
            let hits = try SessionArchive.search(config: config, query: parsed.query ?? "")
            let limited = parsed.limit.map { Array(hits.prefix($0)) } ?? hits
            emit(limited.map { ["id": $0.id, "tool": $0.tool, "path": $0.path, "preview": $0.preview] })
        case .restore:
            let path = try SessionArchive.restore(config: config, backend: engine.repo, query: parsed.query ?? "", to: parsed.to, secrets: secrets)
            emit(["ok": true, "path": path])
        case .reindex:
            let added = try SessionArchive.reindex(config: config, backend: engine.repo, secrets: secrets)
            emit(["ok": true, "added": added])
        case .migrate:
            _ = try SessionArchive.search(config: config, query: " ")
            emit(["ok": true, "migrated": FileManager.default.fileExists(atPath: URL(fileURLWithPath: config.stateDir).appendingPathComponent("sessions-index.json.migrated-v2").path)])
        case .verify:
            let missing = try SessionArchive.verifyLegacy(config: config, backend: engine.repo)
            emit(["ok": true, "missing": missing])
        case .keyInit:
            let id = try SessionArchive.createSessionKey(secrets: secrets)
            emit(["ok": true, "keyId": id])
        case .keyStatus:
            guard let id = try SessionArchive.sessionKeyId(secrets: secrets) else { throw DisklesslyError.usage("no session key; run disklessly sessions key init") }
            emit(["ok": true, "keyId": id])
        }
    case "backend":
        guard let sub = args.first else { throw DisklesslyError.usage("backend requires add, list, or use") }
        args.removeFirst()
        switch sub {
        case "list":
            emit(config.backends.map { endpoint in
                ["id": endpoint.id, "type": endpoint.type, "mountPoint": endpoint.mountPoint ?? "", "url": endpoint.url ?? "", "user": endpoint.user ?? ""]
            })
        case "use":
            guard let id = args.first, config.backends.contains(where: { $0.id == id }) else { throw DisklesslyError.usage("backend use requires a known id") }
            guard let endpoint = config.backends.first(where: { $0.id == id }) else { throw DisklesslyError.usage("Unknown backend: \(id)") }
            config.remember(endpoint)
            engine.config = config
            try engine.saveConfig()
            emit(["ok": true, "active": id])
        case "add":
            var draft = try BackendCommands.parseAdd(args)
            if draft.readPasswordFromStdin {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let password = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !password.isEmpty else { throw DisklesslyError.usage("password from stdin was empty") }
                draft.password = password
            }
            let endpoint = try BackendCatalog.store(draft, secrets: engine.secrets)
            config.remember(endpoint)
            engine.config = config
            try engine.saveConfig()
            emit(["ok": true, "id": endpoint.id, "type": endpoint.type])
        default:
            throw DisklesslyError.usage("Unknown backend command: \(sub)")
        }
    case "icons":
        if args.contains("--help") || args.contains("-h") { usage() }
        let parsed = try IconsArguments.parse(args)
        let report = try engine.backfillIcons(appId: parsed.app)
        for warning in report.warnings { fputs("disklessly: \(warning)\n", stderr) }
        emit(["ok": true, "updated": report.updated, "skipped": report.skipped, "warnings": report.warnings])
    case "install-engine":
        let installed=try engine.installEngine()
        emit(["ok":true,"path":installed.path,"version":EngineInstall.version,"revision":EngineInstall.revision])
    case "stub":
        if args.first=="rebuild" { throw DisklesslyError.unsupported("stub rebuild is not available in this build; use disklessly stub refresh --app ID") }
        else if args.first=="refresh" {
            args.removeFirst()
            if args.first=="--all" {
                // Also the migration that stamps this repo's repoId on legacy stubs.
                let adopt=args.contains("--adopt")
                let report=try engine.refreshOwnedStubs(appId:nil, adopt:adopt)
                var line="Refreshed \(report.updated.count) stub(s); left \(report.foreign.count) stub(s) of other repos alone"
                if !report.mismatched.isEmpty { line+="; \(report.mismatched.count) stub(s) name another repo id but use this repo's images (run disklessly stub refresh --all --adopt to restamp them)" }
                say(["ok":true,"updated":report.updated,"foreign":report.foreign,"mismatched":report.mismatched], line)
            } else {
                guard args.first=="--app", args.count>=2 else { throw DisklesslyError.usage("stub refresh requires --app ID or --all [--adopt]") }
                let report=try engine.refreshStubs(appId:args[1])
                var line="Refreshed stubs for \(args[1]): \(report.updated)"
                if !report.foreign.isEmpty { line+="; left stubs of other repos alone: \(report.foreign)" }
                if !report.mismatched.isEmpty { line+="; stubs naming another repo id: \(report.mismatched) (run disklessly stub refresh --all --adopt)" }
                say(["ok":true,"updated":report.updated,"foreign":report.foreign,"mismatched":report.mismatched], line)
            }
        } else { throw DisklesslyError.usage("stub requires refresh --app ID") }
    // Placeholder kept for old scripts. Hidden from help.
    case "hooks": emit(["ok":true,"hooks":[] as [String]])
    case "ui":
        var openBrowser = false
        while let flag = args.first {
            args.removeFirst()
            if flag == "--open" { openBrowser = true }
            else if flag == "--help" || flag == "-h" { usage() }
            else { throw DisklesslyError.usage("Unknown option: \(flag)") }
        }
        let webRoot = try WebRoot.resolve(environment: env, executable: EngineInstall.runningExecutable())
        let ui = LoopbackUIServer(token: UUID().uuidString) { request in ManagementUI.respond(engine: engine, webRoot: webRoot, request: request) }
        try ui.start(preferredPort: LoopbackUIServer.defaultPort)
        let url = "http://127.0.0.1:\(ui.port)/?token=\(ui.token)"
        if json {
            let payload: [String: Any] = ["url": url, "port": Int(ui.port), "token": ui.token]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]), let line = String(data: data, encoding: .utf8) { print(line) }
        } else {
            print(url)
            fputs("disklessly: serving the dashboard on 127.0.0.1; press Ctrl-C to stop\n", stderr)
        }
        fflush(stdout)
        if openBrowser { openInBrowser(url) }
        serveUntilSignaled(ui)
    case "serve": throw DisklesslyError.unsupported("serve is not available in this build; use disklessly ui")
    case "daemon": throw DisklesslyError.unsupported("daemon is not available in this build")
    case "trust": throw DisklesslyError.unsupported("\(command) is not available in this build")
    default: throw DisklesslyError.usage(command.hasPrefix("--") ? "Unknown option: \(command)" : "Unknown command: \(command)")
    }
} catch let e as DisklesslyError {
    if json {
        var detail: [String: Any] = ["code":e.exitCode,"name":exitName(e.exitCode),"message":e.errorDescription ?? String(describing: e)]
        if let errorReason { detail["reason"] = errorReason }
        emit(["ok":false,"error":detail])
    }
    else { fputs("disklessly: \(e.errorDescription ?? String(describing:e))\n",stderr) }
    exit(Int32(e.exitCode))
} catch {
    let nsError = error as NSError
    if json { emit(["ok":false,"error":["code":1,"message":error.localizedDescription]]) }
    else { fputs("disklessly: \(error.localizedDescription)\n", stderr) }
    // Foundation userInfo can hold long paths and nested errors. Print it only when asked.
    if let debug = env["DISKLESSLY_DEBUG"], !debug.isEmpty, debug != "0" {
        fputs("disklessly: [\(nsError.domain) \(nsError.code)]\n", stderr)
        if !nsError.userInfo.isEmpty { fputs("details: \(nsError.userInfo)\n", stderr) }
    }
    exit(1)
}
