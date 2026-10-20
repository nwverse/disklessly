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
    public static func forwardArguments(_ arguments: [String]) -> [String] { arguments }
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
        let id="\(bid)-\(version)-\(UUID().uuidString.prefix(8).lowercased())", filename="\(id).dmg", staging=URL(fileURLWithPath:config.cacheDir).appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:staging) }
        let dmg=staging.appendingPathComponent(filename)
        try run("/usr/bin/hdiutil",["create","-quiet","-srcfolder",app.path,"-format","ULMO","-volname",name,"-o",dmg.deletingPathExtension().path])
        let sha=try Hashing.sha256(dmg), attrs=try FileManager.default.attributesOfItem(atPath:dmg.path), size=(attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let image=ImageManifest.Image(file:"images/\(filename)",format:"ULMO",sha256:sha,size:size,volumeName:name,appPathInVolume:app.lastPathComponent)
        let facts=ImageManifest.App(originalPath:app.path,executable:info["CFBundleExecutable"] as? String ?? "",documentTypes:(info["CFBundleDocumentTypes"] as? [[String:Any]] ?? []).map { $0.mapValues(AnyCodable.init) },urlTypes:(info["CFBundleURLTypes"] as? [[String:Any]] ?? []).map { $0.mapValues(AnyCodable.init) })
        let manifest=ImageManifest(bundleId:bid,name:name,version:version,image:image,app:facts,mode:selected); try manifest.validate()
        let backend=try repo; try backend.put(image.file,data:Data(contentsOf:dmg)); try backend.put("manifests/\(id).json",data:manifest.encode())
        if !noStub { try installStub(info:info, manifest:manifest, path:app.path, keepOriginal:keepOriginal) }
        return manifest
        #endif
    }
    #if os(macOS)
    private func installStub(info:[String:Any],manifest:ImageManifest,path:String,keepOriginal:Bool) throws {
        let source=URL(fileURLWithPath:path).standardizedFileURL
        let dest=URL(fileURLWithPath:config.stubDir).appendingPathComponent(source.lastPathComponent)
        let temp=dest.deletingLastPathComponent().appendingPathComponent(".isenough-\(UUID().uuidString).app")
        let backup=dest.deletingLastPathComponent().appendingPathComponent(".isenough-original-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        let p=StubGenerator.infoPlist(source:info,appId:manifest.bundleId); (p as NSDictionary).write(to:temp.appendingPathComponent("Contents/Info.plist"),atomically:true)
        let executable=Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0]); try FileManager.default.copyItem(at:executable,to:temp.appendingPathComponent("Contents/MacOS/isenough-stub"))
        try manifest.encode().write(to:temp.appendingPathComponent("Contents/Resources/manifest.json"))
        try run("/usr/bin/codesign",["--force","--sign","-",temp.path]); try run("/usr/bin/codesign",["--verify","--strict",temp.path])
        guard source == dest else { throw IsenoughError.unsupported("Stub must replace the app at its original path") }
        try FileManager.default.moveItem(at:source,to:backup)
        do { try FileManager.default.moveItem(at:temp,to:dest) }
        catch { try? FileManager.default.moveItem(at:backup,to:source); throw error }
        if keepOriginal { try? FileManager.default.moveItem(at:backup,to:dest.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent+".256orig.app")) }
        else { try FileManager.default.removeItem(at:backup) }
    }
    #endif
    public func list() throws -> [ImageManifest] { let b=try repo; return try b.list("manifests").filter{$0.hasSuffix(".json")}.compactMap { try? ImageManifest.decode(b.get("manifests/\($0)",range:nil)) } }
    public func status() -> [String:Any] { let state=StateStore(config.stateDir).read(); return ["backend":config.backend,"repoPath":config.repoPath,"cacheDir":config.cacheDir,"apps":state["apps"] ?? [:],"cache":state["cache"] ?? [:]] }
    public func prefetch(_ manifest:ImageManifest) throws -> URL {
        let backend=try repo, cache=URL(fileURLWithPath:config.cacheDir).appendingPathComponent("images/\(manifest.imageId).dmg"); try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path), try Hashing.sha256(cache)==manifest.image.sha256 { return cache }
        let data=try backend.get(manifest.image.file,range:nil); guard UInt64(data.count)==manifest.image.size, digest(data)==manifest.image.sha256 else { throw IsenoughError.integrity("Remote image hash or size mismatch") }
        let tmp=cache.appendingPathExtension("tmp"); try data.write(to:tmp,options:.atomic)
        #if os(macOS)
        let converted=cache.deletingPathExtension().appendingPathExtension("ulfo.dmg"); try run("/usr/bin/hdiutil",["convert",tmp.path,"-format","ULFO","-o",converted.deletingPathExtension().path]); try? FileManager.default.removeItem(at:tmp); try? FileManager.default.removeItem(at:cache); try FileManager.default.moveItem(at:converted,to:cache)
        #else
        try FileManager.default.moveItem(at:tmp,to:cache)
        #endif
        return cache
    }
    private func digest(_ data:Data)->String { let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try? data.write(to:u); defer{try? FileManager.default.removeItem(at:u)}; return (try? Hashing.sha256(u)) ?? "" }
    public func launch(_ manifest:ImageManifest, documents:[String]=[], urls:[String]=[], wait:Bool=true) throws {
        let image=try prefetch(manifest)
        #if !os(macOS)
        throw IsenoughError.unsupported("launch requires macOS hdiutil and Launch Services")
        #else
        let mount=URL(fileURLWithPath:config.mountRoot).appendingPathComponent(manifest.imageId); try FileManager.default.createDirectory(at:mount.deletingLastPathComponent(),withIntermediateDirectories:true)
        try run("/usr/bin/hdiutil",["attach","-readonly","-nobrowse","-noautoopen","-mountpoint",mount.path,image.path])
        let app=mount.appendingPathComponent(manifest.image.appPathInVolume)
        var args=["-a",app.path]; args += documents; args += urls
        try run("/usr/bin/open",args)
        if wait { while true { Thread.sleep(forTimeInterval:2); let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/pgrep"); p.arguments=["-f",app.appendingPathComponent("Contents/MacOS/"+manifest.app.executable).path]; try? p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { break } }; Thread.sleep(forTimeInterval:Double(config.detachDelaySeconds)); try? run("/usr/bin/hdiutil",["detach",mount.path]) }
        #endif
    }
    #if os(macOS)
    private func run(_ path:String,_ args:[String]) throws { let p=Process(); p.executableURL=URL(fileURLWithPath:path); p.arguments=args; try p.run(); p.waitUntilExit(); guard p.terminationStatus==0 else { throw IsenoughError.diskImage("\(path) exited \(p.terminationStatus)") } }
    #endif
}
