import Foundation
import DisklesslyStubSupport
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
            // New session so Launch Services tearing down the stub's process group
            // does not SIGKILL `disklessly launch` (exit 137) before post-quit.
            let pid=try DetachedProcess.spawn(executable:cli.path, arguments:[cli.path]+argv, redirectOutput:nil, newSession:true)
            exit(DetachedProcess.wait(pid:pid, timeout:nil) ?? 1)
        } catch {
            fputs("disklessly-stub: \(error); argv=\(CommandLine.arguments)\n",stderr); exit(2)
        }
    }
}
#else
@main struct StubLauncher { static func main() {} }
#endif
