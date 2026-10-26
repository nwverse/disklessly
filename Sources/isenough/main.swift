import Foundation
import IsenoughCore
import IsenoughEngine
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func usage() -> Never {
    print("""
    isenough — remote app image manager
    Usage: isenough [--json] [--config PATH] [--state-dir PATH] [--help] <command>
      init [--backend local|icloud] [--root DIR] [--cache-dir DIR]
      pack APP.app [--mode mount|restore] [--image-format ULMO|ULFO] [--no-stub] [--keep-original] [--stub-dir DIR]
      install-engine | stub refresh --app ID | stub rebuild APP
      list | status [APP] | prefetch APP | launch APP [--doc PATH] [--url URL] [--arg ARG] [--no-wait]
      pin APP | unpin APP | evict APP | evict-local | gc [--include-legacy] | cleanup-backups | restore APP | unpack APP
      devices [list] | devices rename NAME | devices forget DEVICEID --yes
      backend add smb|nfs|webdav|openlist ... | backend list | backend use ID
      sessions [--apply] [--days N] [--home DIR] | sessions search QUERY | sessions restore ID|PATH
      recommend [--json] [--min-size SIZE] [--limit N] [--min-idle-days N]
      ui | hooks list|enable|disable APP | doctor | version | help
    help, --help, and -h print this text. --json keeps machine-readable output.
    Environment overrides: ISENOUGH_REPO_PATH, ISENOUGH_CACHE_DIR, ISENOUGH_STATE_DIR,
      ISENOUGH_MOUNT_ROOT, ISENOUGH_STUB_DIR, ISENOUGH_CONFIG, ISENOUGH_DETACH_DELAY,
      ISENOUGH_QUOTA_BYTES, ISENOUGH_MIN_FREE_BYTES, ISENOUGH_SIGN_IDENTITY,
      ISENOUGH_DOCTOR_TIMEOUT
    """)
    exit(0)
}
let invocation: GlobalArguments
do { invocation = try GlobalArguments.parse(Array(CommandLine.arguments.dropFirst())) }
catch let error as IsenoughError {
    fputs("isenough: \(error.errorDescription ?? String(describing: error))\n", stderr)
    exit(Int32(error.exitCode))
}
var args=invocation.rest; var json=invocation.json
let env=ProcessInfo.processInfo.environment
let configPath=env["ISENOUGH_CONFIG"] ?? invocation.configPath
if let stateDir=invocation.stateDir { setenv("ISENOUGH_STATE_DIR", stateDir, 1) }
// `ProcessInfo.environment` can miss a setenv from this process. `--state-dir`
// is applied as an override, and `<stateDir>/config.json` is loaded unless
// `--config` / `ISENOUGH_CONFIG` replaces it. Path env vars win over the file.
var config=RuntimeConfig.resolved(environment:env, home:NSHomeDirectory(), stateDirOverride:invocation.stateDir, explicitConfig:configPath)
if let n=env["ISENOUGH_DETACH_DELAY"].flatMap(UInt64.init) { config.detachDelaySeconds=n }
var engine=IsenoughEngine(config:config)
func emit(_ data:Any) { if json, JSONSerialization.isValidJSONObject(data), let d=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]), let s=String(data:d,encoding:.utf8) { print(s) } else { print(data) } }
func sizeText(_ bytes: UInt64) -> String { RecommendFormatting.byteText(bytes) }
func printVersionLine() { print("isenough \(EngineInstall.version) revision \(EngineInstall.revision) schema image/1") }
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
func printMaintenance(_ report: MaintenanceReport) {
    var count = 0
    for warning in report.warnings { print("warning  \(warning)"); count += 1 }
    for id in report.trashed { print("trashed  \(id)"); count += 1 }
    for id in report.restored { print("restored  \(id)"); count += 1 }
    for id in report.purged { print("purged  \(id)"); count += 1 }
    for path in report.evictedLocal { print("evicted  \(path)"); count += 1 }
    for journal in report.journals { print("recovered  \(journal)"); count += 1 }
    if count == 0 { print("nothing to remove") }
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
func find(_ name:String) throws -> ImageManifest { guard let m=engine.manifest(named: name, in: try engine.list()) else { throw IsenoughError.usage("Unknown app: \(name)") }; return m }
do {
    guard let command=args.first else { usage() }; args.removeFirst()
    // The stub is a session leader. A hangup must not kill `launch` / `hook watch`
    // before the journal reaches a terminal phase. SIGKILL faults still apply.
    if command == "launch" || command == "hook" || command == "restore" {
        signal(SIGHUP, SIG_IGN)
    }
    switch command {
    case "help", "--help", "-h": usage()
    case "version":
        if json { emit(["version":EngineInstall.version,"revision":EngineInstall.revision,"schema":"image/1"]) }
        else { printVersionLine() }
    case "init":
        while !args.isEmpty { let a=args.removeFirst(); if a=="--backend", !args.isEmpty { config.backend=args.removeFirst() } else if a=="--root", !args.isEmpty { config.repoPath=args.removeFirst() } else if a=="--cache-dir", !args.isEmpty { config.cacheDir=args.removeFirst() } }
        try IsenoughEngine(config:config).initialize(); emit(["ok":true,"repo":config.repoPath])
    case "pack":
        let parsed = try PackArguments.parse(args)
        if let stubDir = parsed.stubDir { config.stubDir = stubDir }
        let published=try engine.pack(parsed.app,mode:parsed.mode,keepOriginal:parsed.keepOriginal,noStub:parsed.noStub,imageFormat:parsed.imageFormat); let m=published.manifest
        let path = parsed.app
        for warning in published.warnings { fputs("isenough: \(warning)\n", stderr) }
        for path in published.evicted { fputs("isenough: evicted local iCloud copy \(path)\n", stderr) }
        if let kept = published.originalKept {
            let retained = URL(fileURLWithPath: config.stubDir).appendingPathComponent(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".256orig.app")
            fputs("isenough: kept original at \(retained.path): \(kept)\n", stderr)
        }
        var packed: [String: Any] = ["ok":true,"imageId":m.imageId,"bundleId":m.bundleId,"mode":m.mode.rawValue,"sha256":m.image.sha256,"reused":published.reused,"uploaded":published.uploaded,"warnings":published.warnings,"evicted":published.evicted]
        if let kept = published.originalKept { packed["originalKept"] = kept }
        emit(packed)
    case "list":
        let manifests = try engine.list()
        if json { emit(manifests.map { ["imageId":$0.imageId,"bundleId":$0.bundleId,"name":$0.name,"version":$0.version,"mode":$0.mode.rawValue] }) }
        else { printImageList(manifests) }
    case "status": emit(engine.status())
    case "prefetch": guard let n=args.first else { throw IsenoughError.usage("prefetch requires app") }; let m=try find(n); emit(["ok":true,"path":try engine.prefetch(m).path])
    case "launch":
        let parsed=try LaunchArguments.parse(args)
        try engine.launch(find(parsed.app),documents:parsed.documents,urls:parsed.urls,arguments:parsed.arguments,wait:parsed.wait); emit(["ok":true])
    case "restore":
        let parsed=try LaunchArguments.parse(args)
        var manifest=try find(parsed.app)
        manifest.mode = .restore
        try engine.launch(manifest,documents:parsed.documents,urls:parsed.urls,arguments:parsed.arguments,wait:parsed.wait); emit(["ok":true])
    case "pin", "unpin": guard let n=args.first else { throw IsenoughError.usage("\(command) requires app") }; try engine.setPinned(try find(n), pinned: command=="pin"); emit(["ok":true,"pinned":command=="pin"])
    case "evict": guard let n=args.first else { throw IsenoughError.usage("evict requires app") }; try engine.evict(find(n)); emit(["ok":true])
    case "evict-local":
        let files = engine.materialFiles()
        let eviction = engine.evictLocalCopies()
        if json {
            for path in eviction.evicted { fputs("isenough: evicted local iCloud copy \(path)\n", stderr) }
            for line in eviction.retryLater { fputs("isenough: \(line)\n", stderr) }
            emit(["ok":true,"evicted":eviction.evicted,"retryLater":eviction.retryLater,"skipped":eviction.skipped])
        } else {
            printEvict(eviction, files: files)
        }
    case "cleanup-backups":
        let cleaned = try engine.cleanupBackups()
        for path in cleaned.removed { fputs("isenough: removed \(path)\n", stderr) }
        for line in cleaned.kept { fputs("isenough: kept \(line)\n", stderr) }
        emit(["ok":true,"removed":cleaned.removed,"kept":cleaned.kept])
    case "gc":
        var includeLegacy = false
        while let flag = args.first {
            args.removeFirst()
            if flag == "--include-legacy" { includeLegacy = true }
            else if flag == "--help" || flag == "-h" { usage() }
            else { throw IsenoughError.usage("Unknown option: \(flag)") }
        }
        let report = try engine.maintain(includeLegacy: includeLegacy)
        if json {
            for path in report.evictedLocal { fputs("isenough: evicted local iCloud copy \(path)\n", stderr) }
            emit(["ok":true,"removed":report.purged,"trashed":report.trashed,"restored":report.restored,"warnings":report.warnings,"recovered":report.journals,"evicted":report.evictedLocal])
        } else {
            printMaintenance(report)
        }
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
            guard !name.isEmpty else { throw IsenoughError.usage("devices rename requires a name") }
            let record = try engine.renameDevice(to: name)
            emit(["ok": true, "deviceId": record.deviceId, "displayName": record.displayName])
        case "forget":
            guard let id = args.first else { throw IsenoughError.usage("devices forget requires a device id and --yes") }
            args.removeFirst()
            try engine.forgetDevice(id: id, confirmed: args.contains("--yes"))
            emit(["ok": true, "forgot": id])
        default:
            throw IsenoughError.usage("Unknown devices command: \(sub)")
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
        if json { emit(report) }
        exit((report["ok"] as? Bool) == true ? 0 : 1)
    case "hook":
        guard args.first == "watch" else { throw IsenoughError.usage("hook watch requires --app") }
        args.removeFirst()
        guard args.first == "--app", args.count >= 2 else { throw IsenoughError.usage("hook watch requires --app") }
        try engine.watch(appId: args[1]); emit(["ok":true])
    case "resolve":
        guard let name=args.first else { throw IsenoughError.usage("resolve requires an app") }
        args.removeFirst()
        var discard=false, trust=false, keep=false, export:String?
        while let flag=args.first {
            args.removeFirst()
            if flag == "--discard" { discard=true }
            else if flag == "--keep-updated" { keep=true }
            else if flag == "--trust" { trust=true }
            else if flag == "--export", let dir=args.first { export=dir; args.removeFirst() }
            else { throw IsenoughError.usage("Unknown option or missing value: \(flag)") }
        }
        try engine.resolve(find(name), keepUpdated: keep, trust: trust, export: export, discard: discard); emit(["ok":true])
    case "sessions":
        var apply = false
        var days: Int?
        var home: String?
        var rest = args
        var filtered: [String] = []
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            if flag == "--apply" { apply = true }
            else if flag == "--days", let raw = rest.first, let value = Int(raw) { days = value; rest.removeFirst() }
            else if flag == "--home", let raw = rest.first { home = raw; rest.removeFirst() }
            else { filtered.append(flag) }
        }
        if filtered.first == "search" {
            let query = filtered.dropFirst().joined(separator: " ")
            guard !query.isEmpty else { throw IsenoughError.usage("sessions search requires a query") }
            let hits = try SessionArchive.search(config: config, query: query)
            emit(hits.map { ["id": $0.id, "tool": $0.tool, "path": $0.path, "preview": $0.preview] })
        } else if filtered.first == "restore" {
            guard filtered.count >= 2 else { throw IsenoughError.usage("sessions restore requires an id or path") }
            let path = try SessionArchive.restore(config: config, backend: engine.repo, query: filtered[1])
            emit(["ok": true, "path": path])
        } else if filtered.isEmpty {
            let report = try SessionArchive.tier(config: config, backend: engine.repo, apply: apply, coldDays: days, home: home, isOpen: liveSessionOpen)
            emit(["ok": true, "applied": report.applied, "cold": report.cold, "skipped": report.skipped.map { ["path": $0.0, "reason": $0.1] }])
        } else {
            throw IsenoughError.usage("Unknown sessions command: \(filtered[0])")
        }
    case "backend":
        guard let sub = args.first else { throw IsenoughError.usage("backend requires add, list, or use") }
        args.removeFirst()
        switch sub {
        case "list":
            emit(config.backends.map { endpoint in
                ["id": endpoint.id, "type": endpoint.type, "mountPoint": endpoint.mountPoint ?? "", "url": endpoint.url ?? "", "user": endpoint.user ?? ""]
            })
        case "use":
            guard let id = args.first, config.backends.contains(where: { $0.id == id }) else { throw IsenoughError.usage("backend use requires a known id") }
            guard let endpoint = config.backends.first(where: { $0.id == id }) else { throw IsenoughError.usage("Unknown backend: \(id)") }
            config.remember(endpoint)
            engine.config = config
            try engine.saveConfig()
            emit(["ok": true, "active": id])
        case "add":
            var draft = try BackendCommands.parseAdd(args)
            if draft.readPasswordFromStdin {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let password = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !password.isEmpty else { throw IsenoughError.usage("password from stdin was empty") }
                draft.password = password
            }
            let endpoint = try BackendCatalog.store(draft, secrets: engine.secrets)
            config.remember(endpoint)
            engine.config = config
            try engine.saveConfig()
            emit(["ok": true, "id": endpoint.id, "type": endpoint.type])
        default:
            throw IsenoughError.usage("Unknown backend command: \(sub)")
        }
    case "install-engine":
        let installed=try engine.installEngine()
        emit(["ok":true,"path":installed.path,"version":EngineInstall.version,"revision":EngineInstall.revision])
    case "stub":
        if args.first=="rebuild" { emit(["ok":false,"message":"Stub rebuild requires macOS and a manifest-backed installed app" ]) }
        else if args.first=="refresh" {
            args.removeFirst()
            guard args.first=="--app", args.count>=2 else { throw IsenoughError.usage("stub refresh requires --app ID") }
            emit(["ok":true,"updated":try engine.refreshStubs(appId:args[1])])
        } else { usage() }
    case "hooks": emit(["ok":true,"hooks":[] as [String]])
    case "ui":
        let webRoot = ProcessInfo.processInfo.environment["ISENOUGH_WEB_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Bundle.module.url(forResource: "web", withExtension: nil)
        let ui = LoopbackUIServer { request in ManagementUI.respond(engine: engine, webRoot: webRoot, request: request) }
        try ui.start()
        print("http://127.0.0.1:\(ui.port)/?token=\(ui.token)")
        fflush(stdout)
        serveUntilSignaled(ui)
    case "serve": emit(["ok":false,"message":"HTTP server not yet available; use isenough ui" ])
    case "daemon": emit(["ok":false,"message":"Daemon management is not implemented in MVP build"])
    case "detach", "unpack", "trust": throw IsenoughError.unsupported("\(command) is not available in this MVP build")
    default: throw IsenoughError.usage(command.hasPrefix("--") ? "Unknown option: \(command)" : "Unknown command: \(command)")
    }
} catch let e as IsenoughError { if json { emit(["ok":false,"error":["code":e.exitCode,"message":e.errorDescription ?? String(describing: e)]]) } else { fputs("isenough: \(e.errorDescription ?? String(describing:e))\n",stderr) }; exit(Int32(e.exitCode)) } catch {
    let nsError = error as NSError
    fputs("isenough: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]\n", stderr)
    if !nsError.userInfo.isEmpty { fputs("details: \(nsError.userInfo)\n", stderr) }
    exit(1)
}
