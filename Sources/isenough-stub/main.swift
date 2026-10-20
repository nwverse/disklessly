import Foundation
#if os(macOS)
import AppKit
@main struct StubLauncher {
    static func main() {
        let bundle=Bundle.main, resource=bundle.bundleURL.appendingPathComponent("Contents/Resources/manifest.json")
        guard let data=try? Data(contentsOf:resource), let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let app=obj["app"] as? [String:Any], let path=app["originalPath"] as? String else { return }
        let args=Array(CommandLine.arguments.dropFirst())
        let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/env"); p.arguments=["isenough","launch",(obj["bundleId"] as? String ?? "")]+args
        try? p.run(); p.waitUntilExit()
        _=path
    }
}
#else
@main struct StubLauncher { static func main() {} }
#endif
