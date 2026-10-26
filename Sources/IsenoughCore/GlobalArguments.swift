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
            if first == "--help" {
                rest = ["help"]
                break
            } else if first == "--json" {
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

public struct PackArguments: Equatable {
    public var app: String
    public var mode: ImageManifest.Mode?
    public var imageFormat: String?
    public var keepOriginal: Bool
    public var noStub: Bool
    public var stubDir: String?

    public init(app: String, mode: ImageManifest.Mode?, imageFormat: String?, keepOriginal: Bool, noStub: Bool, stubDir: String?) {
        self.app = app
        self.mode = mode
        self.imageFormat = imageFormat
        self.keepOriginal = keepOriginal
        self.noStub = noStub
        self.stubDir = stubDir
    }

    public static func parse(_ args: [String]) throws -> PackArguments {
        guard let app = args.first, !app.hasPrefix("-") else { throw IsenoughError.usage("pack requires an .app path") }
        var mode: ImageManifest.Mode?
        var imageFormat: String?
        var keepOriginal = false
        var noStub = false
        var stubDir: String?
        var rest = Array(args.dropFirst())
        while let flag = rest.first {
            rest.removeFirst()
            switch flag {
            case "--mode":
                guard let value = rest.first else { throw IsenoughError.usage("invalid --mode; expected mount or restore") }
                rest.removeFirst()
                guard let parsed = ImageManifest.Mode(rawValue: value) else {
                    throw IsenoughError.usage("invalid --mode \(value); expected mount or restore")
                }
                mode = parsed
            case "--image-format":
                guard let value = rest.first else { throw IsenoughError.usage("invalid --image-format; expected ULMO or ULFO") }
                rest.removeFirst()
                let upper = value.uppercased()
                guard upper == "ULMO" || upper == "ULFO" else {
                    throw IsenoughError.usage("invalid --image-format \(value); expected ULMO or ULFO")
                }
                imageFormat = upper
            case "--keep-original":
                keepOriginal = true
            case "--no-stub":
                noStub = true
            case "--stub-dir":
                guard let value = rest.first else { throw IsenoughError.usage("invalid --stub-dir; expected a directory") }
                rest.removeFirst()
                stubDir = value
            default:
                throw IsenoughError.usage("unknown pack option \(flag)")
            }
        }
        return PackArguments(app: app, mode: mode, imageFormat: imageFormat, keepOriginal: keepOriginal, noStub: noStub, stubDir: stubDir)
    }
}

public struct UnpackArguments: Equatable {
    public var app: String
    public var directory: String?

    public init(app: String, directory: String?) {
        self.app = app
        self.directory = directory
    }

    public static func parse(_ args: [String]) throws -> UnpackArguments {
        guard let app = args.first, !app.hasPrefix("-") else { throw IsenoughError.usage("unpack requires an app") }
        var directory: String?
        var rest = Array(args.dropFirst())
        while let flag = rest.first {
            rest.removeFirst()
            switch flag {
            case "--delete-remote":
                throw IsenoughError.usage("unpack keeps the repository image; --delete-remote is not a command")
            case "--to":
                guard let value = rest.first, !value.hasPrefix("-") else { throw IsenoughError.usage("invalid --to; expected a directory") }
                rest.removeFirst()
                directory = value
            default:
                throw IsenoughError.usage("unknown unpack option \(flag)")
            }
        }
        return UnpackArguments(app: app, directory: directory)
    }
}
