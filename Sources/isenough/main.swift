import Foundation
import IsenoughCore
import IsenoughEngine

func usage() -> Never {
    print("""
    isenough — remote app image manager
    Usage: isenough [--json] [--config PATH] [--state-dir PATH] <command>
      init [--backend local|icloud] [--root DIR] [--cache-dir DIR]
      pack APP.app [--mode mount|restore] [--no-stub] [--keep-original] [--stub-dir DIR]
      list [--json] | status [APP] [--json] | prefetch APP | launch APP [--doc PATH] [--url URL] [--arg ARG] [--no-wait]
      pin APP | unpin APP | evict APP | gc | restore APP | unpack APP | stub rebuild APP
      backend add smb|nfs|webdav ... | backend list | backend use ID
      hooks list|enable|disable APP | doctor | version | serve [--port PORT]
    Environment overrides: ISENOUGH_REPO_PATH, ISENOUGH_CACHE_DIR, ISENOUGH_STATE_DIR,
      ISENOUGH_MOUNT_ROOT, ISENOUGH_STUB_DIR, ISENOUGH_CONFIG, ISENOUGH_DETACH_DELAY,
      ISENOUGH_QUOTA_BYTES, ISENOUGH_MIN_FREE_BYTES, ISENOUGH_SIGN_IDENTITY
    """)
    exit(0)
}
let invocation: GlobalArguments
do { invocation = try GlobalArguments.parse(Array(CommandLine.arguments.dropFirst())) }
catch let error as IsenoughError {
    fputs("isenough: \(error.errorDescription ?? String(describing: error))\n", stderr)
    exit(Int32(error.exitCode))
}
var args=invocation.rest; let json=invocation.json; var configPath=ProcessInfo.processInfo.environment["ISENOUGH_CONFIG"] ?? invocation.configPath
if let stateDir=invocation.stateDir { setenv("ISENOUGH_STATE_DIR", stateDir, 1) }
let env=ProcessInfo.processInfo.environment
var config=RuntimeConfig.environment()
if let path=configPath, let d=try? Data(contentsOf:URL(fileURLWithPath:path)), let c=try? JSONDecoder().decode(RuntimeConfig.self,from:d) { config=c }
if let n=env["ISENOUGH_DETACH_DELAY"].flatMap(UInt64.init) { config.detachDelaySeconds=n }
var engine=IsenoughEngine(config:config)
func emit(_ data:Any) { if json, JSONSerialization.isValidJSONObject(data), let d=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]), let s=String(data:d,encoding:.utf8) { print(s) } else { print(data) } }
func find(_ name:String) throws -> ImageManifest { guard let m=engine.manifest(named: name, in: try engine.list()) else { throw IsenoughError.usage("Unknown app: \(name)") }; return m }
do {
    guard let command=args.first else { usage() }; args.removeFirst()
    switch command {
    case "help", "--help", "-h": usage()
    case "version": emit(["version":"0.1.0","schema":"image/1"])
    case "init":
        while !args.isEmpty { let a=args.removeFirst(); if a=="--backend", !args.isEmpty { config.backend=args.removeFirst() } else if a=="--root", !args.isEmpty { config.repoPath=args.removeFirst() } else if a=="--cache-dir", !args.isEmpty { config.cacheDir=args.removeFirst() } }
        try IsenoughEngine(config:config).initialize(); emit(["ok":true,"repo":config.repoPath])
    case "pack":
        guard let path=args.first else { throw IsenoughError.usage("pack requires an .app path") }; args.removeFirst(); var mode:ImageManifest.Mode?; var keep=false; var noStub=false
        while !args.isEmpty { let a=args.removeFirst(); if a=="--mode", !args.isEmpty { mode=ImageManifest.Mode(rawValue:args.removeFirst()) } else if a=="--keep-original" { keep=true } else if a=="--no-stub" { noStub=true } else if a=="--stub-dir", !args.isEmpty { config.stubDir=args.removeFirst() } }
        let m=try engine.pack(path,mode:mode,keepOriginal:keep,noStub:noStub); emit(["ok":true,"imageId":m.imageId,"bundleId":m.bundleId,"mode":m.mode.rawValue,"sha256":m.image.sha256])
    case "list": emit(try engine.list().map { ["imageId":$0.imageId,"bundleId":$0.bundleId,"name":$0.name,"version":$0.version,"mode":$0.mode.rawValue] })
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
    case "pin", "unpin": guard let n=args.first else { throw IsenoughError.usage("\(command) requires app") }; let m=try find(n); var s=StateStore(config.stateDir).read(); var apps=s["apps"] as? [String:[String:Any]] ?? [:]; var item=apps[m.bundleId] ?? [:]; item["imageId"]=m.imageId; item["pinned"]=command=="pin"; apps[m.bundleId]=item; s["apps"]=apps; try StateStore(config.stateDir).write(s); if command=="pin" { _=try engine.prefetch(m) }; emit(["ok":true,"pinned":command=="pin"])
    case "evict": guard let n=args.first else { throw IsenoughError.usage("evict requires app") }; try engine.evict(find(n)); emit(["ok":true])
    case "gc": emit(["ok":true,"removed":[] as [String],"recovered":try engine.gc()])
    case "doctor":
        if args.first == "--fix" { _ = try engine.gc() }
        emit(engine.doctor())
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
    case "stub": if args.first=="rebuild" { emit(["ok":false,"message":"Stub rebuild requires macOS and a manifest-backed installed app" ]) } else { usage() }
    case "hooks": emit(["ok":true,"hooks":[] as [String]])
    case "serve": emit(["ok":false,"message":"HTTP server not yet available; use the static management UI" ])
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
