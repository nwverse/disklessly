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

public struct SessionsArguments: Equatable {
    public enum Command: Equatable { case tier, search, restore, reindex, migrate, verify, keyInit, keyStatus }
    public var command: Command
    public var apply: Bool
    public var days: Int?
    public var home: String?
    public var encrypt: Bool
    public var query: String?
    public var limit: Int?
    public var to: String?
    public var legacy: Bool

    public init(command: Command, apply: Bool = false, days: Int? = nil, home: String? = nil, encrypt: Bool = false, query: String? = nil, limit: Int? = nil, to: String? = nil, legacy: Bool = false) {
        self.command = command
        self.apply = apply
        self.days = days
        self.home = home
        self.encrypt = encrypt
        self.query = query
        self.limit = limit
        self.to = to
        self.legacy = legacy
    }

    public static func parse(_ args: [String]) throws -> SessionsArguments {
        var rest = args
        func value(_ flag: String) throws -> String {
            guard let next = rest.first, !next.hasPrefix("-") else { throw IsenoughError.usage("invalid \(flag)") }
            rest.removeFirst()
            return next
        }
        guard let head = rest.first else { return SessionsArguments(command: .tier) }
        if head.hasPrefix("-") {
            var apply = false
            var days: Int?
            var home: String?
            var encrypt = false
            while let flag = rest.first {
                rest.removeFirst()
                switch flag {
                case "--apply": apply = true
                case "--encrypt": encrypt = true
                case "--days":
                    let raw = try value("--days")
                    guard let number = Int(raw) else { throw IsenoughError.usage("invalid --days \(raw)") }
                    days = number
                case "--home": home = try value("--home")
                default: throw IsenoughError.usage("unknown sessions option \(flag)")
                }
            }
            return SessionsArguments(command: .tier, apply: apply, days: days, home: home, encrypt: encrypt)
        }
        rest.removeFirst()
        switch head {
        case "search":
            var limit: Int?
            var words: [String] = []
            while let token = rest.first {
                rest.removeFirst()
                if token == "--limit" {
                    let raw = try value("--limit")
                    guard let number = Int(raw), number > 0 else { throw IsenoughError.usage("invalid --limit \(raw)") }
                    limit = number
                } else if token.hasPrefix("-") {
                    throw IsenoughError.usage("unknown sessions option \(token)")
                } else {
                    words.append(token)
                }
            }
            guard !words.isEmpty else { throw IsenoughError.usage("sessions search requires a query") }
            return SessionsArguments(command: .search, query: words.joined(separator: " "), limit: limit)
        case "restore":
            guard let query = rest.first, !query.hasPrefix("-") else { throw IsenoughError.usage("sessions restore requires an id or path") }
            rest.removeFirst()
            var to: String?
            while let flag = rest.first {
                rest.removeFirst()
                if flag == "--to" { to = try value("--to") }
                else { throw IsenoughError.usage("unknown sessions option \(flag)") }
            }
            return SessionsArguments(command: .restore, query: query, to: to)
        case "reindex":
            guard rest.isEmpty else { throw IsenoughError.usage("unknown sessions option \(rest[0])") }
            return SessionsArguments(command: .reindex)
        case "migrate":
            guard rest.isEmpty else { throw IsenoughError.usage("unknown sessions option \(rest[0])") }
            return SessionsArguments(command: .migrate)
        case "verify":
            var legacy = false
            while let flag = rest.first {
                rest.removeFirst()
                if flag == "--legacy" { legacy = true }
                else { throw IsenoughError.usage("unknown sessions option \(flag)") }
            }
            guard legacy else { throw IsenoughError.usage("sessions verify requires --legacy") }
            return SessionsArguments(command: .verify, legacy: true)
        case "key":
            guard let action = rest.first else { throw IsenoughError.usage("sessions key requires init or status") }
            rest.removeFirst()
            guard rest.isEmpty else { throw IsenoughError.usage("unknown sessions option \(rest[0])") }
            switch action {
            case "init": return SessionsArguments(command: .keyInit)
            case "status": return SessionsArguments(command: .keyStatus)
            default: throw IsenoughError.usage("unknown sessions key command \(action)")
            }
        default:
            throw IsenoughError.usage("unknown sessions command \(head)")
        }
    }
}
