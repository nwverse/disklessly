import Foundation

public enum StubArgv {
    public static func build(appId: String, rawArguments: [String], cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> [String] {
        var out=["launch",appId], i=0, options=true
        while i < rawArguments.count {
            let token=rawArguments[i]; i += 1
            if options && token == "--" { options=false; continue }
            if options && ["--doc","--url","--arg"].contains(token) {
                guard i < rawArguments.count else { throw StubArgvError.missingValue(token) }
                out += [token,rawArguments[i]]; i += 1; continue
            }
            // Launch Services noise is only dropped while option parsing is active.
            // After `--`, a filename such as `-NSnotes.txt` is a document.
            if options && token.hasPrefix("-psn_") { continue }
            if options && (token.hasPrefix("-NS") || token.hasPrefix("-Apple")) { if i < rawArguments.count { i += 1 }; continue }
            if let scheme=token.range(of:"^[A-Za-z][A-Za-z0-9+.-]*:", options:.regularExpression), !token.hasPrefix("/") {
                if token[..<scheme.upperBound].lowercased() == "file:" {
                    // `URL.path` is already percent-decoded once. Decoding again turns
                    // a literal `%20` (`%2520` in the URL) into the wrong path.
                    let path=URL(string:token)?.path ?? token
                    out += ["--doc",standard(path,cwd:cwd)]
                } else { out += ["--url",token] }
            } else { out += ["--doc",standard(token,cwd:cwd)] }
        }
        return out
    }
    private static func standard(_ path:String,cwd:URL)->String { let u=path.hasPrefix("/") ? URL(fileURLWithPath:path) : cwd.appendingPathComponent(path); return u.standardizedFileURL.path }
    /// Installed engine copied by `disklessly init` / `pack` / `install-engine`.
    /// Kept in this target so the stub does not link the engine. The same
    /// relative path is `EngineInstall.binary(stateDir:)`.
    public static func stableEnginePath(environment:[String:String], home:String) -> String {
        let state = environment["DISKLESSLY_STATE_DIR"] ?? "\(home)/Library/Application Support/Disklessly"
        return URL(fileURLWithPath: state).appendingPathComponent("bin/disklessly").path
    }

    public static func resolveCLI(environment:[String:String], stubInfo:[String:Any], path:String, home:String, isExecutable:(String)->Bool) throws -> URL {
        var candidates:[String]=[]
        if let p=environment["DISKLESSLY_CLI"] { candidates.append(p) }
        // The stable copy wins over a path baked into an old stub. A dev-build
        // `disklesslyPath` can still exist and be executable, and it is the binary
        // that was current when the stub was generated, not the one the user runs now.
        candidates.append(stableEnginePath(environment:environment, home:home))
        if let p=stubInfo["disklesslyPath"] as? String { candidates.append(p) }
        candidates += path.split(separator:":").map { URL(fileURLWithPath:String($0)).appendingPathComponent("disklessly").path }
        candidates += ["\(home)/.local/bin/disklessly","/usr/local/bin/disklessly","/opt/homebrew/bin/disklessly"]
        guard let result=candidates.first(where:isExecutable) else { throw StubArgvError.cliNotFound }
        return URL(fileURLWithPath:result).standardizedFileURL
    }
}
public enum StubArgvError: Error { case missingValue(String), cliNotFound }
