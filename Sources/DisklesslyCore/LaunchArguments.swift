import Foundation

public struct LaunchArguments: Equatable {
    public var app: String
    public var documents: [String] = []
    public var urls: [String] = []
    public var arguments: [String] = []
    public var wait = true
    public init(app: String, documents: [String] = [], urls: [String] = [], arguments: [String] = [], wait: Bool = true) {
        self.app=app; self.documents=documents; self.urls=urls; self.arguments=arguments; self.wait=wait
    }
    public static func parse(_ args: [String]) throws -> LaunchArguments {
        guard let app=args.first, !app.hasPrefix("--") else { throw DisklesslyError.usage("launch requires app") }
        var result=LaunchArguments(app:app), i=1
        while i < args.count {
            let key=args[i]; i += 1
            if key == "--no-wait" { result.wait=false; continue }
            guard ["--doc","--url","--arg"].contains(key), i < args.count else { throw DisklesslyError.usage("Unknown option or missing value: \(key)") }
            let value=args[i]; i += 1
            switch key { case "--doc": result.documents.append(value); case "--url": result.urls.append(value); default: result.arguments.append(value) }
        }
        return result
    }
    public var argv: [String] {
        var out=["launch",app]
        for v in documents { out += ["--doc",v] }; for v in urls { out += ["--url",v] }; for v in arguments { out += ["--arg",v] }
        if !wait { out.append("--no-wait") }; return out
    }
}

public enum OpenInvocation {
    /// `open` argv for an app. Never includes `-n`. Arguments are dropped when the app is already running.
    public static func arguments(app: String, documents: [String], urls: [String], arguments: [String], alreadyRunning: Bool) -> (argv: [String], warnings: [String]) {
        var argv = ["/usr/bin/open", "-a", app]
        argv += documents
        argv += urls
        var warnings: [String] = []
        if !arguments.isEmpty {
            if alreadyRunning {
                warnings.append("\(app) is already running; launch arguments were not passed")
            } else {
                argv.append(contentsOf: ["--args"] + arguments)
            }
        }
        return (argv, warnings)
    }
}

public struct CachePaths {
    public let cache: URL; public let mountRoot: URL
    public init(cacheDir: String, mountRoot: String) { cache=URL(fileURLWithPath:cacheDir); self.mountRoot=URL(fileURLWithPath:mountRoot) }
    public func image(_ id:String)->URL { cache.appendingPathComponent("images/\(id).dmg") }
    public func partial(_ id:String)->URL { cache.appendingPathComponent("partial/\(id).dmg.part") }
    public func mount(_ id:String)->URL { mountRoot.appendingPathComponent(id) }
}
