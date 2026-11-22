import Foundation

public struct BackendEndpoint: Codable, Equatable {
    public var id: String
    public var type: String
    public var host: String?
    public var share: String?
    public var exportPath: String?
    public var user: String?
    public var mountPoint: String?
    public var url: String?
    public var root: String
    /// rclone: the remote name in `configPath`.
    public var remote: String?
    /// rclone: Disklessly's own rclone.conf.
    public var configPath: String?
    public init(id: String, type: String, host: String? = nil, share: String? = nil, exportPath: String? = nil, user: String? = nil, mountPoint: String? = nil, url: String? = nil, root: String = "", remote: String? = nil, configPath: String? = nil) {
        self.id = id
        self.type = type
        self.host = host
        self.share = share
        self.exportPath = exportPath
        self.user = user
        self.mountPoint = mountPoint
        self.url = url
        self.root = root
        self.remote = remote
        self.configPath = configPath
    }
}

public struct BackendDraft: Equatable {
    public var type: String
    public var id: String?
    public var host: String?
    public var share: String?
    public var exportPath: String?
    public var user: String?
    public var mountPoint: String?
    public var url: String?
    public var remoteRoot: String?
    /// rclone remote name (`--remote`).
    public var remote: String?
    /// rclone config file; the CLI fills it in from the state dir.
    public var configPath: String?
    public var password: String?
    public var readPasswordFromStdin: Bool
    public init(type: String) {
        self.type = type
        self.readPasswordFromStdin = false
    }
}

public enum SigningIdentity {
    public static func resolve(configured: String, environment: [String: String]) -> String {
        if let override = environment["DISKLESSLY_SIGN_IDENTITY"], !override.isEmpty { return override }
        return configured.isEmpty ? "-" : configured
    }
}

public enum SpaceFloor {
    /// Maximum free-space reserve kept during transient offload staging.
    /// Offload reclaims disk space once finished, so enforcing the full download floor
    /// (default 15 GiB) would block users from freeing space precisely when their disk is low.
    public static let maxOffloadReserveBytes: UInt64 = 256 * 1024 * 1024

    public static func offloadFloor(_ configuredFloor: UInt64) -> UInt64 {
        min(configuredFloor, maxOffloadReserveBytes)
    }

    public static func admits(freeBytes: UInt64, incoming: UInt64, floor: UInt64) -> Bool {
        freeBytes >= incoming && freeBytes &- incoming >= floor
    }
}

public enum BackendCommands {
    public static func parseAdd(_ args: [String]) throws -> BackendDraft {
        guard let type = args.first, ["smb", "nfs", "webdav", "openlist", "rclone"].contains(type) else {
            throw DisklesslyError.usage("backend add requires smb, nfs, webdav, openlist, or rclone")
        }
        var draft = BackendDraft(type: type)
        var index = 1
        while index < args.count {
            let flag = args[index]
            index += 1
            if flag == "--password" {
                throw DisklesslyError.usage("refusing --password; use --password-stdin so the secret is stored in the Keychain and not on the command line")
            }
            if flag == "--password-stdin" {
                draft.readPasswordFromStdin = true
                continue
            }
            guard index < args.count else { throw DisklesslyError.usage("missing value for \(flag)") }
            let value = args[index]
            index += 1
            switch flag {
            case "--id": draft.id = value
            case "--host": draft.host = value
            case "--share": draft.share = value
            case "--export": draft.exportPath = value
            case "--user": draft.user = value
            case "--mount": draft.mountPoint = value
            case "--url": draft.url = value
            case "--root": draft.remoteRoot = value
            case "--remote": draft.remote = value.hasSuffix(":") ? String(value.dropLast()) : value
            default: throw DisklesslyError.usage("Unknown option: \(flag)")
            }
        }
        if draft.id == nil { draft.id = type == "rclone" ? "rclone-\(draft.remote ?? "")" : type }
        switch type {
        case "smb":
            guard draft.host != nil, draft.share != nil, draft.mountPoint != nil else {
                throw DisklesslyError.usage("smb requires --host, --share, and --mount")
            }
        case "nfs":
            guard draft.host != nil, (draft.exportPath != nil || draft.share != nil), draft.mountPoint != nil else {
                throw DisklesslyError.usage("nfs requires --host, --export, and --mount")
            }
        case "webdav":
            guard let url = draft.url, url.hasPrefix("http://") || url.hasPrefix("https://") else {
                throw DisklesslyError.usage("webdav requires --url http(s)://…")
            }
        case "openlist":
            guard let url = draft.url, url.hasPrefix("http://") || url.hasPrefix("https://") else {
                throw DisklesslyError.usage("openlist requires --url http(s)://…")
            }
            guard draft.user != nil else { throw DisklesslyError.usage("openlist requires --user") }
        case "rclone":
            guard let remote = draft.remote, !remote.isEmpty, !remote.contains("/") else {
                throw DisklesslyError.usage("rclone requires --remote NAME (a remote from disklessly cloud list)")
            }
        default: break
        }
        return draft
    }

    public static func secretAccount(type: String, id: String) -> String { "\(type):\(id)" }
}

public enum BackendCatalog {
    public static let keychainService = "io.github.s546126.disklessly"

    /// Stores the secret in `secrets` and returns the endpoint. The caller writes the endpoint
    /// into config. The secret is not part of the endpoint.
    public static func store(_ draft: BackendDraft, secrets: any SecretStore) throws -> BackendEndpoint {
        let endpoint = try endpoint(from: draft)
        if let password = draft.password, !password.isEmpty {
            try secrets.save(service: keychainService, account: BackendCommands.secretAccount(type: endpoint.type, id: endpoint.id), secret: password)
            if endpoint.type == "smb" || endpoint.type == "nfs", let host = endpoint.host {
                try secrets.saveMountCredential(kind: endpoint.type, host: host, account: endpoint.user ?? "", secret: password)
            }
        }
        return endpoint
    }

    public static func endpoint(from draft: BackendDraft) throws -> BackendEndpoint {
        let id = draft.id ?? draft.type
        switch draft.type {
        case "smb":
            let host = draft.host ?? ""
            let share = draft.share ?? ""
            try ShareMount.validate(user: draft.user, host: host, share: share)
            return BackendEndpoint(id: id, type: "smb", host: host, share: share, user: draft.user, mountPoint: draft.mountPoint, url: "smb://\(host)/\(share)")
        case "nfs":
            let host = draft.host ?? ""
            let export = draft.exportPath ?? draft.share ?? ""
            try ShareMount.validate(user: nil, host: host, share: export)
            return BackendEndpoint(id: id, type: "nfs", host: host, exportPath: export, user: draft.user, mountPoint: draft.mountPoint, url: "nfs://\(host)\(export)")
        case "webdav":
            return BackendEndpoint(id: id, type: "webdav", user: draft.user, url: draft.url)
        case "openlist":
            let root = draft.remoteRoot ?? "/"
            return BackendEndpoint(id: id, type: "openlist", user: draft.user, url: draft.url, root: root)
        case "rclone":
            let remote = draft.remote ?? ""
            let root = draft.remoteRoot ?? "Disklessly"
            return BackendEndpoint(id: id, type: "rclone", url: "rclone://\(remote)/\(root.trimmingCharacters(in: CharacterSet(charactersIn: "/")))", root: root, remote: remote, configPath: draft.configPath)
        default:
            throw DisklesslyError.usage("Unknown backend type: \(draft.type)")
        }
    }
}

public enum BackendFactory {
    public static func open(_ endpoint: BackendEndpoint, secrets: any SecretStore, opener: ShareOpener, transport: (any HTTPTransport)? = nil) throws -> any StorageBackend {
        switch endpoint.type {
        case "local", "icloud":
            let path = endpoint.mountPoint ?? endpoint.root
            guard !path.isEmpty else { throw DisklesslyError.backend("local backend has no root") }
            let url = URL(fileURLWithPath: path)
            if endpoint.type == "icloud" || ICloudFolderBackend.looksLikeICloud(url) {
                return try ICloudFolderBackend(root: url)
            }
            return try LocalFolderBackend(root: url)
        case "smb", "nfs":
            guard let mount = endpoint.mountPoint, !mount.isEmpty else {
                throw DisklesslyError.backend("\(endpoint.type) backend has no mount point")
            }
            let share = endpoint.type == "nfs" ? (endpoint.exportPath ?? endpoint.share ?? "") : (endpoint.share ?? "")
            let mounted = opener.isMounted(mount)
            let spec = ShareSpec(kind: endpoint.type, host: endpoint.host ?? "", share: share, user: endpoint.user, mountPoint: mount, alreadyMounted: mounted)
            if let command = ShareMount.command(spec) {
                if let secret = try? secrets.load(service: BackendCatalog.keychainService, account: BackendCommands.secretAccount(type: endpoint.type, id: endpoint.id)),
                   !secret.isEmpty, command.rendered.contains(secret) {
                    throw DisklesslyError.failure("refusing to place a Keychain secret on the mount command line")
                }
                try opener.run(command)
                guard opener.isMounted(mount) else {
                    throw DisklesslyError.backend("share is offline or not mounted at \(mount)")
                }
            }
            return try MountedShareBackend(root: URL(fileURLWithPath: mount), probe: { opener.isMounted(mount) })
        case "webdav":
            guard let raw = endpoint.url, let url = URL(string: raw) else { throw DisklesslyError.backend("webdav backend has no URL") }
            let account = BackendCommands.secretAccount(type: "webdav", id: endpoint.id)
            let password = try secrets.load(service: BackendCatalog.keychainService, account: account)
            if endpoint.user != nil && (password == nil || password?.isEmpty == true) {
                throw DisklesslyError.backend("webdav credential is not in the Keychain")
            }
            let client = transport ?? URLSessionTransport(origin: url.host)
            return WebDAVBackend(baseURL: url, user: endpoint.user, password: password, transport: client)
        case "openlist":
            guard let raw = endpoint.url, let url = URL(string: raw) else { throw DisklesslyError.backend("openlist backend has no URL") }
            let account = BackendCommands.secretAccount(type: "openlist", id: endpoint.id)
            let password = try secrets.load(service: BackendCatalog.keychainService, account: account)
            guard let password, !password.isEmpty else { throw DisklesslyError.backend("openlist credential is not in the Keychain") }
            let client = transport ?? URLSessionTransport(origin: url.host)
            return OpenListBackend(baseURL: url, root: endpoint.root, user: endpoint.user ?? "", password: password, transport: client, secrets: secrets, secretAccount: account)
        case "rclone":
            guard let remote = endpoint.remote, !remote.isEmpty else { throw DisklesslyError.backend("rclone backend has no remote") }
            guard let config = endpoint.configPath, !config.isEmpty else { throw DisklesslyError.backend("rclone backend has no config path") }
            return RcloneBackend(binary: try RcloneTool.require(), config: config, remote: remote, root: endpoint.root)
        default:
            throw DisklesslyError.backend("Unknown backend type: \(endpoint.type)")
        }
    }
}
