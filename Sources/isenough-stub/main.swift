import Foundation
import IsenoughStubSupport
#if os(macOS)
import AppKit
import Darwin
@main struct StubLauncher {
    static func main() {
        let root=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        do {
            let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("manifest.json"))) as! [String:Any]
            let info=(try? JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("stub.json")))) as? [String:Any] ?? [:]
            guard let appId=manifest["bundleId"] as? String else { throw StubArgvError.cliNotFound }
            let env=ProcessInfo.processInfo.environment
            let cli=try StubArgv.resolveCLI(environment:env,stubInfo:info,path:env["PATH"] ?? "",home:NSHomeDirectory(),isExecutable:{ FileManager.default.isExecutableFile(atPath:$0) })
            let argv=try StubArgv.build(appId:appId,rawArguments:Array(CommandLine.arguments.dropFirst()))
            let p=Process(); p.executableURL=cli; p.arguments=argv
            try p.run(); p.waitUntilExit(); exit(p.terminationStatus)
        } catch {
            fputs("isenough-stub: \(error); argv=\(CommandLine.arguments)\n",stderr); exit(2)
        }
    }
}
#else
@main struct StubLauncher { static func main() {} }
#endif
