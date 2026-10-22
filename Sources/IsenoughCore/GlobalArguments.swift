import Foundation

public struct GlobalArguments: Equatable {
    public var json: Bool
    public var configPath: String?
    public var stateDir: String?
    public var rest: [String]
    public init(json: Bool, configPath: String?, stateDir: String?, rest: [String]) {
        self.json = json; self.configPath = configPath; self.stateDir = stateDir; self.rest = rest
    }

    /// Global flags must precede the command. An unknown flag is `EX_USAGE`, not an unknown command.
    public static func parse(_ args: [String]) throws -> GlobalArguments {
        var json = false
        var configPath: String?
        var stateDir: String?
        var rest = args
        while let first = rest.first, first.hasPrefix("--") {
            if first == "--json" {
                json = true
                rest.removeFirst()
            } else if first == "--config" {
                guard rest.count > 1 else { throw IsenoughError.usage("Unknown option or missing value: --config") }
                configPath = rest[1]
                rest.removeFirst(2)
            } else if first == "--state-dir" {
                guard rest.count > 1 else { throw IsenoughError.usage("Unknown option or missing value: --state-dir") }
                stateDir = rest[1]
                rest.removeFirst(2)
            } else {
                throw IsenoughError.usage("Unknown option: \(first)")
            }
        }
        return GlobalArguments(json: json, configPath: configPath, stateDir: stateDir, rest: rest)
    }
}
