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
    public static func resolveCLI(environment:[String:String], stubInfo:[String:Any], path:String, home:String, isExecutable:(String)->Bool) throws -> URL {
        var candidates:[String]=[]
        if let p=environment["ISENOUGH_CLI"] { candidates.append(p) }
        if let p=stubInfo["isenoughPath"] as? String { candidates.append(p) }
        candidates += path.split(separator:":").map { URL(fileURLWithPath:String($0)).appendingPathComponent("isenough").path }
        candidates += ["\(home)/.local/bin/isenough","/usr/local/bin/isenough","/opt/homebrew/bin/isenough"]
        guard let result=candidates.first(where:isExecutable) else { throw StubArgvError.cliNotFound }
        return URL(fileURLWithPath:result).standardizedFileURL
    }
}
public enum StubArgvError: Error { case missingValue(String), cliNotFound }
