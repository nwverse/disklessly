import Foundation

public struct GlobalArguments: Equatable {
    public var json: Bool
    public var configPath: String?
    public var stateDir: String?
    public var rest: [String]
    public init(json: Bool, configPath: String?, stateDir: String?, rest: [String]) {
        self.json = json; self.configPath = configPath; self.stateDir = stateDir; self.rest = rest
    }

    /// `--json` is accepted anywhere in argv. Other global flags still precede the command.
    /// An unknown flag is `EX_USAGE`, not an unknown command.
    public static func parse(_ args: [String]) throws -> GlobalArguments {
        var json = false
        var configPath: String?
        var stateDir: String?
        var rest: [String] = []
        for arg in args {
            if arg == "--json" { json = true }
            else { rest.append(arg) }
        }
        while let first = rest.first, first.hasPrefix("--") {
            if first == "--help" {
                rest = ["help"]
                break
            } else if first == "--config" {
                guard rest.count > 1 else { throw DisklesslyError.usage("Unknown option or missing value: --config") }
                configPath = rest[1]
                rest.removeFirst(2)
            } else if first == "--state-dir" {
                guard rest.count > 1 else { throw DisklesslyError.usage("Unknown option or missing value: --state-dir") }
                stateDir = rest[1]
                rest.removeFirst(2)
            } else {
                throw DisklesslyError.usage("Unknown option: \(first)")
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
    /// `--encrypt` / `--no-encrypt`; nil leaves it to `imageEncryption` in the config.
    public var encrypt: Bool?

    public init(app: String, mode: ImageManifest.Mode?, imageFormat: String?, keepOriginal: Bool, noStub: Bool, stubDir: String?, encrypt: Bool? = nil) {
        self.app = app
        self.mode = mode
        self.imageFormat = imageFormat
        self.keepOriginal = keepOriginal
        self.noStub = noStub
        self.stubDir = stubDir
        self.encrypt = encrypt
    }

    public static func parse(_ args: [String]) throws -> PackArguments {
        guard let app = args.first, !app.hasPrefix("-") else { throw DisklesslyError.usage("pack requires an .app path") }
        var mode: ImageManifest.Mode?
        var imageFormat: String?
        var keepOriginal = false
        var noStub = false
        var stubDir: String?
        var encrypt: Bool?
        var rest = Array(args.dropFirst())
        while let flag = rest.first {
            rest.removeFirst()
            switch flag {
            case "--mode":
                guard let value = rest.first else { throw DisklesslyError.usage("invalid --mode; expected mount or restore") }
                rest.removeFirst()
                guard let parsed = ImageManifest.Mode(rawValue: value) else {
                    throw DisklesslyError.usage("invalid --mode \(value); expected mount or restore")
                }
                mode = parsed
            case "--image-format":
                guard let value = rest.first else { throw DisklesslyError.usage("invalid --image-format; expected ULMO or ULFO") }
                rest.removeFirst()
                let upper = value.uppercased()
                guard upper == "ULMO" || upper == "ULFO" else {
                    throw DisklesslyError.usage("invalid --image-format \(value); expected ULMO or ULFO")
                }
                imageFormat = upper
            case "--keep-original":
                keepOriginal = true
            case "--no-stub":
                noStub = true
            case "--encrypt":
                encrypt = true
            case "--no-encrypt":
                encrypt = false
            case "--stub-dir":
                guard let value = rest.first else { throw DisklesslyError.usage("invalid --stub-dir; expected a directory") }
                rest.removeFirst()
                stubDir = value
            default:
                throw DisklesslyError.usage("unknown pack option \(flag)")
            }
        }
        return PackArguments(app: app, mode: mode, imageFormat: imageFormat, keepOriginal: keepOriginal, noStub: noStub, stubDir: stubDir, encrypt: encrypt)
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
        guard let app = args.first, !app.hasPrefix("-") else { throw DisklesslyError.usage("unpack requires an app") }
        var directory: String?
        var rest = Array(args.dropFirst())
        while let flag = rest.first {
            rest.removeFirst()
            switch flag {
            case "--delete-remote":
                throw DisklesslyError.usage("unpack keeps the repository image; --delete-remote is not a command")
            case "--to":
                guard let value = rest.first, !value.hasPrefix("-") else { throw DisklesslyError.usage("invalid --to; expected a directory") }
                rest.removeFirst()
                directory = value
            default:
                throw DisklesslyError.usage("unknown unpack option \(flag)")
            }
        }
        return UnpackArguments(app: app, directory: directory)
    }
}

public struct SessionsArguments: Equatable {
    public enum Command: Equatable { case tier, search, restore, reindex, migrate, verify, keyInit, keyStatus, list, status }
    public var command: Command
    public var apply: Bool
    public var days: Int?
    public var home: String?
    public var encrypt: Bool
    public var query: String?
    public var limit: Int?
    public var to: String?
    public var legacy: Bool
    /// `sessions --exclude-from FILE|-`: `-` reads standard input.
    public var excludeFrom: String?
    /// `sessions list --state`: a row state or `all`.
    public var state: String
    public var tool: String?
    public var digest: Bool
    public var checkSegments: Bool

    public init(command: Command, apply: Bool = false, days: Int? = nil, home: String? = nil, encrypt: Bool = false, query: String? = nil, limit: Int? = nil, to: String? = nil, legacy: Bool = false, excludeFrom: String? = nil, state: String = "all", tool: String? = nil, digest: Bool = false, checkSegments: Bool = false) {
        self.command = command
        self.apply = apply
        self.days = days
        self.home = home
        self.encrypt = encrypt
        self.query = query
        self.limit = limit
        self.to = to
        self.legacy = legacy
        self.excludeFrom = excludeFrom
        self.state = state
        self.tool = tool
        self.digest = digest
        self.checkSegments = checkSegments
    }

    public static func parse(_ args: [String]) throws -> SessionsArguments {
        var rest = args
        func value(_ flag: String) throws -> String {
            guard let next = rest.first, !next.hasPrefix("-") else { throw DisklesslyError.usage("invalid \(flag)") }
            rest.removeFirst()
            return next
        }
        guard let head = rest.first else { return SessionsArguments(command: .tier) }
        if head.hasPrefix("-") {
            var apply = false
            var days: Int?
            var home: String?
            var encrypt = false
            var excludeFrom: String?
            while let flag = rest.first {
                rest.removeFirst()
                switch flag {
                case "--apply": apply = true
                case "--encrypt": encrypt = true
                case "--exclude-from":
                    guard let next = rest.first, next == "-" || !next.hasPrefix("-") else { throw DisklesslyError.usage("invalid --exclude-from") }
                    rest.removeFirst()
                    excludeFrom = next
                case "--days":
                    let raw = try value("--days")
                    guard let number = Int(raw) else { throw DisklesslyError.usage("invalid --days \(raw)") }
                    days = number
                case "--home": home = try value("--home")
                default: throw DisklesslyError.usage("unknown sessions option \(flag)")
                }
            }
            return SessionsArguments(command: .tier, apply: apply, days: days, home: home, encrypt: encrypt, excludeFrom: excludeFrom)
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
                    guard let number = Int(raw), number > 0 else { throw DisklesslyError.usage("invalid --limit \(raw)") }
                    limit = number
                } else if token.hasPrefix("-") {
                    throw DisklesslyError.usage("unknown sessions option \(token)")
                } else {
                    words.append(token)
                }
            }
            guard !words.isEmpty else { throw DisklesslyError.usage("sessions search requires a query") }
            return SessionsArguments(command: .search, query: words.joined(separator: " "), limit: limit)
        case "restore":
            guard let query = rest.first, !query.hasPrefix("-") else { throw DisklesslyError.usage("sessions restore requires an id or path") }
            rest.removeFirst()
            var to: String?
            while let flag = rest.first {
                rest.removeFirst()
                if flag == "--to" { to = try value("--to") }
                else { throw DisklesslyError.usage("unknown sessions option \(flag)") }
            }
            return SessionsArguments(command: .restore, query: query, to: to)
        case "list":
            var state = "all"
            var tool: String?
            var limit: Int?
            var digest = false
            while let flag = rest.first {
                rest.removeFirst()
                switch flag {
                case "--state":
                    state = try value("--state")
                    guard state == "all" || ["archived", "remote", "restored", "keptLocal", "pendingDelete"].contains(state) else {
                        throw DisklesslyError.usage("invalid --state \(state)")
                    }
                case "--tool": tool = try value("--tool")
                case "--limit":
                    let raw = try value("--limit")
                    guard let number = Int(raw), number > 0 else { throw DisklesslyError.usage("invalid --limit \(raw)") }
                    limit = number
                case "--digest": digest = true
                default: throw DisklesslyError.usage("unknown sessions option \(flag)")
                }
            }
            return SessionsArguments(command: .list, limit: limit, state: state, tool: tool, digest: digest)
        case "status":
            var check = false
            while let flag = rest.first {
                rest.removeFirst()
                if flag == "--check-segments" { check = true }
                else { throw DisklesslyError.usage("unknown sessions option \(flag)") }
            }
            return SessionsArguments(command: .status, checkSegments: check)
        case "reindex":
            guard rest.isEmpty else { throw DisklesslyError.usage("unknown sessions option \(rest[0])") }
            return SessionsArguments(command: .reindex)
        case "migrate":
            guard rest.isEmpty else { throw DisklesslyError.usage("unknown sessions option \(rest[0])") }
            return SessionsArguments(command: .migrate)
        case "verify":
            var legacy = false
            while let flag = rest.first {
                rest.removeFirst()
                if flag == "--legacy" { legacy = true }
                else { throw DisklesslyError.usage("unknown sessions option \(flag)") }
            }
            guard legacy else { throw DisklesslyError.usage("sessions verify requires --legacy") }
            return SessionsArguments(command: .verify, legacy: true)
        case "key":
            guard let action = rest.first else { throw DisklesslyError.usage("sessions key requires init or status") }
            rest.removeFirst()
            guard rest.isEmpty else { throw DisklesslyError.usage("unknown sessions option \(rest[0])") }
            switch action {
            case "init": return SessionsArguments(command: .keyInit)
            case "status": return SessionsArguments(command: .keyStatus)
            default: throw DisklesslyError.usage("unknown sessions key command \(action)")
            }
        default:
            throw DisklesslyError.usage("unknown sessions command \(head)")
        }
    }
}
