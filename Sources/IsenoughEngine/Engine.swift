import Foundation
import IsenoughCore

public struct RuntimeConfig: Codable {
    public var schema = "config/1"
    public var backend = "local"
    public var repoPath: String
    public var cacheDir: String
    public var stateDir: String
    public var mountRoot: String
    public var stubDir: String
    public var quotaBytes: UInt64 = 20 * 1024 * 1024 * 1024
    public var detachDelaySeconds: UInt64 = 120
    public init(repoPath: String, cacheDir: String, stateDir: String, mountRoot: String, stubDir: String) { self.repoPath=repoPath; self.cacheDir=cacheDir; self.stateDir=stateDir; self.mountRoot=mountRoot; self.stubDir=stubDir }
    public static func environment() -> RuntimeConfig {
        let home = NSHomeDirectory(), env = ProcessInfo.processInfo.environment
        func v(_ key: String, _ fallback: String) -> String { env["ISENOUGH_\(key)"] ?? fallback }
        return RuntimeConfig(repoPath: v("REPO_PATH", "\(home)/Library/Mobile Documents/com~apple~CloudDocs/256isenough"), cacheDir: v("CACHE_DIR", "\(home)/Library/Caches/256isenough"), stateDir: v("STATE_DIR", "\(home)/Library/Application Support/256isenough"), mountRoot: v("MOUNT_ROOT", "\(home)/Library/Caches/256isenough/mnt"), stubDir: v("STUB_DIR", "/Applications"))
    }
}

public enum Hashing {
    public static func sha256(_ url: URL) throws -> String {
        #if canImport(CryptoKit)
        importCryptoKitPlaceholder()
        #endif
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["sh", "-c", "command -v sha256sum >/dev/null && sha256sum \"$1\" || shasum -a 256 \"$1\"", "isenough", url.path]
        let out = Pipe(); p.standardOutput = out; try p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); guard p.terminationStatus == 0, let line = String(data:d, encoding:.utf8) else { throw IsenoughError.failure("sha256 failed") }; return String(line.split(separator:" ").first ?? "")
    }
    #if canImport(CryptoKit)
    private static func importCryptoKitPlaceholder() {}
    #endif
}

public struct StateStore {
    public let dir: URL
    public init(_ path: String) { dir=URL(fileURLWithPath:path); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories:true) }
    public func read() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.json")))) as? [String:Any] ?? ["schema":"state/1", "apps":[:], "cache":[:]] }
    public func write(_ object: [String:Any]) throws { let d=try JSONSerialization.data(withJSONObject:object, options:[.prettyPrinted,.sortedKeys]); try d.write(to:dir.appendingPathComponent("state.json"),options:.atomic) }
}

public enum StubGenerator {
    public static func infoPlist(source: [String:Any], appId: String, executable: String = "isenough-stub") -> [String:Any] {
        var p=source; p["CFBundleIdentifier"]="\(appId).256stub"; p["CFBundleExecutable"]=executable; p["LSUIElement"]=true
        for key in ["SUFeedURL","SUPublicEDKey","ElectronDefaultApp"] { p.removeValue(forKey:key) }
        return p
    }
    public static func stubInfo(manifest: ImageManifest, cliPath: String) -> [String:Any] { ["schema":"stub/1", "appId":manifest.bundleId, "imageId":manifest.imageId, "isenoughPath":cliPath, "stubVersion":1] }

    public static func locateLauncher(cliExecutable: URL, environment: [String:String], isExecutable: (String)->Bool) throws -> URL {
        let cli=cliExecutable.resolvingSymlinksInPath().standardizedFileURL
        let candidates=[environment["ISENOUGH_STUB_BINARY"], cli.deletingLastPathComponent().appendingPathComponent("isenough-stub").path].compactMap{$0}
        guard let path=candidates.first(where:isExecutable) else { throw IsenoughError.failure("isenough-stub launcher binary not found next to \(cli.path)") }
        let found=URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL
        guard found.path != cli.path else { throw IsenoughError.failure("Refusing to use CLI as isenough-stub launcher") }
        return found
    }

    /// Compare filesystem paths lexically after collapsing redundant separators and dot components.
    /// URL equality is stricter than filesystem path equivalence (notably for `//`).
    public static func pathsReferToSameLocation(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).standardizingPath == (rhs as NSString).standardizingPath
    }
}

public struct IsenoughEngine {
    public var config: RuntimeConfig
    public init(config: RuntimeConfig) { self.config=config }
    public var repo: LocalFolderBackend { get throws { try LocalFolderBackend(root: URL(fileURLWithPath: config.repoPath)) } }
    public func initialize() throws {
        let fm=FileManager.default
        for p in [config.repoPath, config.cacheDir, config.stateDir, config.mountRoot, config.stubDir] { try fm.createDirectory(atPath:p, withIntermediateDirectories:true) }
        let r=try LocalFolderBackend(root:URL(fileURLWithPath:config.repoPath)); if try r.stat("repo.json") == nil { try r.put("repo.json", data:Data("{\"schema\":\"repo/1\",\"repoId\":\"\(UUID().uuidString)\",\"layoutVersion\":1}".utf8)) }
        for p in ["images","manifests","catalog","devices","trash"] { try fm.createDirectory(atPath:config.repoPath+"/"+p,withIntermediateDirectories:true) }
        let cfg=try JSONEncoder().encode(config); try cfg.write(to:URL(fileURLWithPath:config.stateDir).appendingPathComponent("config.json"),options:.atomic)
    }
    public func pack(_ appPath: String, mode: ImageManifest.Mode? = nil, keepOriginal: Bool = false, noStub: Bool = false) throws -> ImageManifest {
        #if !os(macOS)
        throw IsenoughError.unsupported("pack requires macOS hdiutil and codesign")
        #else
        let app=URL(fileURLWithPath:appPath).standardizedFileURL, plistURL=app.appendingPathComponent("Contents/Info.plist")
        guard let info=NSDictionary(contentsOf:plistURL) as? [String:Any], let bid=info["CFBundleIdentifier"] as? String else { throw IsenoughError.usage("Not a valid .app bundle") }
        let name=info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent, version=info["CFBundleShortVersionString"] as? String ?? "0"
        let selected=mode ?? ((FileManager.default.fileExists(atPath:app.appendingPathComponent("Contents/_MASReceipt/receipt").path) ? .restore : .mount))
        let staging=URL(fileURLWithPath:config.cacheDir).appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:staging.appendingPathComponent("src"),withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:staging) }
        let stagedApp=staging.appendingPathComponent("src").appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto",[app.path,stagedApp.path])
        let dmg=staging.appendingPathComponent("image.dmg")
        try run("/usr/bin/hdiutil",["create","-quiet","-srcfolder",staging.appendingPathComponent("src").path,"-format","ULMO","-volname",name,"-o",dmg.deletingPathExtension().path])
        let sha=try Hashing.sha256(dmg), attrs=try FileManager.default.attributesOfItem(atPath:dmg.path), size=(attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let image=ImageManifest.Image(file:"",format:"ULMO",sha256:sha,size:size,volumeName:name,appPathInVolume:app.lastPathComponent)
        let facts=ImageManifest.App(originalPath:app.path,executable:info["CFBundleExecutable"] as? String ?? "",documentTypes:(info["CFBundleDocumentTypes"] as? [[String:Any]] ?? []).map { $0.mapValues(AnyCodable.init) },urlTypes:(info["CFBundleURLTypes"] as? [[String:Any]] ?? []).map { $0.mapValues(AnyCodable.init) })
        var manifest=ImageManifest(bundleId:bid,name:name,version:version,image:image,app:facts,mode:selected); manifest.image.file="images/\(manifest.imageId).dmg"; try manifest.validate()
        let backend=try repo; try backend.put(manifest.image.file,data:Data(contentsOf:dmg)); try backend.put("manifests/\(manifest.imageId).json",data:manifest.encode())
        if !noStub { try installStub(info:info, manifest:manifest, path:app.path, keepOriginal:keepOriginal) }
        return manifest
        #endif
    }
    #if os(macOS)
    private func installStub(info:[String:Any],manifest:ImageManifest,path:String,keepOriginal:Bool) throws {
        let source=URL(fileURLWithPath:path).standardizedFileURL
        let dest=URL(fileURLWithPath:config.stubDir).standardizedFileURL.appendingPathComponent(source.lastPathComponent)
        let temp=dest.deletingLastPathComponent().appendingPathComponent(".isenough-\(UUID().uuidString).app")
        let backup=dest.deletingLastPathComponent().appendingPathComponent(".isenough-original-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        let plistPath=temp.appendingPathComponent("Contents/Info.plist")
        guard (StubGenerator.infoPlist(source:info,appId:manifest.bundleId) as NSDictionary).write(to:plistPath,atomically:true) else {
            throw IsenoughError.failure("Could not write generated stub Info.plist at \(plistPath.path)")
        }
        let cli=Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0])
        let launcher=try StubGenerator.locateLauncher(cliExecutable:cli,environment:ProcessInfo.processInfo.environment,isExecutable:{ FileManager.default.isExecutableFile(atPath:$0) })
        let stubExecutable=temp.appendingPathComponent("Contents/MacOS/isenough-stub")
        try FileManager.default.copyItem(at:launcher,to:stubExecutable)
        guard try Data(contentsOf:stubExecutable) != Data(contentsOf:cli) else {
            throw IsenoughError.failure("Refusing to install CLI binary as isenough-stub launcher")
        }
        try manifest.encode().write(to:temp.appendingPathComponent("Contents/Resources/manifest.json"))
        try JSONSerialization.data(withJSONObject:StubGenerator.stubInfo(manifest:manifest,cliPath:cli.resolvingSymlinksInPath().path),options:[.prettyPrinted,.sortedKeys]).write(to:temp.appendingPathComponent("Contents/Resources/stub.json"))
        // Signing the bundle re-signs its main executable isenough-stub in place.
        // No --deep is needed because there are no nested code items.
        try run("/usr/bin/codesign",["--force","--sign","-",temp.path])
        try run("/usr/bin/codesign",["--verify","--strict",temp.path])
        guard StubGenerator.pathsReferToSameLocation(source.path, dest.path) else { throw IsenoughError.unsupported("Stub must replace the app at its original path (source: \(source.path), destination: \(dest.path))") }
        do {
            try FileManager.default.moveItem(at:source,to:backup)
        } catch {
            throw IsenoughError.failure("Could not move original app to transaction backup \(backup.path): \(error.localizedDescription)")
        }
        do {
            try FileManager.default.moveItem(at:temp,to:dest)
        } catch {
            try? FileManager.default.moveItem(at:backup,to:source)
            throw IsenoughError.failure("Could not install signed stub at \(dest.path): \(error.localizedDescription)")
        }
        if keepOriginal {
            let retained=dest.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent+".256orig.app")
            do { try FileManager.default.moveItem(at:backup,to:retained) }
            catch {
                try? FileManager.default.removeItem(at:dest)
                try? FileManager.default.moveItem(at:backup,to:source)
                throw IsenoughError.failure("Could not retain original app at \(retained.path): \(error.localizedDescription)")
            }
        } else {
            do { try FileManager.default.removeItem(at:backup) }
            catch { throw IsenoughError.failure("Stub installed, but could not remove backup \(backup.path): \(error.localizedDescription)") }
        }
    }
    #endif
    public func list() throws -> [ImageManifest] { let b=try repo; return try b.list("manifests").filter{$0.hasSuffix(".json")}.compactMap { try? ImageManifest.decode(b.get("manifests/\($0)",range:nil)) } }
    public func status() -> [String:Any] { let state=StateStore(config.stateDir).read(); return ["backend":config.backend,"repoPath":config.repoPath,"cacheDir":config.cacheDir,"apps":state["apps"] ?? [:],"cache":state["cache"] ?? [:]] }
    public func prefetch(_ manifest:ImageManifest) throws -> URL {
        let backend=try repo, paths=CachePaths(cacheDir:config.cacheDir,mountRoot:config.mountRoot), cache=paths.image(manifest.imageId); try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path), try Hashing.sha256(cache)==manifest.image.sha256 { return cache }
        let data=try backend.get(manifest.image.file,range:nil); guard UInt64(data.count)==manifest.image.size, digest(data)==manifest.image.sha256 else { throw IsenoughError.integrity("Remote image hash or size mismatch") }
        // Keep the fetched image byte-for-byte identical to the published artifact.
        // The manifest hashes the remote ULMO image; converting it on download both
        // invalidates that identity and relies on hdiutil's output-name conventions.
        let partial=paths.partial(manifest.imageId); try FileManager.default.createDirectory(at:partial.deletingLastPathComponent(),withIntermediateDirectories:true); try? FileManager.default.removeItem(at:partial); try data.write(to:partial,options:.atomic)
        do {
            if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.removeItem(at:cache) }
            try FileManager.default.moveItem(at:partial,to:cache)
        } catch {
            try? FileManager.default.removeItem(at:partial)
            throw IsenoughError.failure("Could not install verified image at cache path \(cache.path): \(error.localizedDescription)")
        }
        return cache
    }
    private func digest(_ data:Data)->String { let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try? data.write(to:u); defer{try? FileManager.default.removeItem(at:u)}; return (try? Hashing.sha256(u)) ?? "" }
    public func launch(_ manifest:ImageManifest, documents:[String]=[], urls:[String]=[], arguments:[String]=[], wait:Bool=true) throws {
        guard manifest.mode == .mount else { throw IsenoughError.unsupported("restore mode is disabled until durable restore recovery is implemented") }
        let image=try prefetch(manifest)
        #if !os(macOS)
        throw IsenoughError.unsupported("launch requires macOS hdiutil and Launch Services")
        #else
        let mount=URL(fileURLWithPath:config.mountRoot).appendingPathComponent(manifest.imageId); try FileManager.default.createDirectory(at:mount.deletingLastPathComponent(),withIntermediateDirectories:true)
        try run("/usr/bin/hdiutil",["attach","-readonly","-nobrowse","-noautoopen","-mountpoint",mount.path,image.path])
        let app=mount.appendingPathComponent(manifest.image.appPathInVolume)
        var args=["-n","-a",app.path]; args += documents; args += urls
        if !arguments.isEmpty { args.append("--args"); args += arguments }
        try run("/usr/bin/open",args)
        if wait { while true { Thread.sleep(forTimeInterval:2); let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/pgrep"); p.arguments=["-f",app.appendingPathComponent("Contents/MacOS/"+manifest.app.executable).path]; try? p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { break } }; Thread.sleep(forTimeInterval:Double(config.detachDelaySeconds)); try? run("/usr/bin/hdiutil",["detach",mount.path]) }
        #endif
    }
    #if os(macOS)
    private func run(_ path:String,_ args:[String]) throws {
        let p=Process(); p.executableURL=URL(fileURLWithPath:path); p.arguments=args
        let output=Pipe(); p.standardOutput=output; p.standardError=output
        do { try p.run() } catch {
            throw IsenoughError.failure("Could not start \(path) \(args.joined(separator:" ")): \(error.localizedDescription)")
        }
        let data=output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus==0 else {
            let detail=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            throw IsenoughError.diskImage("Command failed: \(path) \(args.joined(separator:" ")) (exit \(p.terminationStatus))\(detail.isEmpty ? "" : "\n\(detail)")")
        }
    }
    #endif
}
