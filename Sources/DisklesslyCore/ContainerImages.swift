import Foundation

/// Container images and volumes kept by the container engines on this Mac: Apple's
/// `container` (com.apple.container), and the Docker-compatible ones (Docker Desktop,
/// OrbStack, Colima, Dory). An image nothing uses can go to the repo as the tar its own
/// CLI saves (`docker save` / `container image save`) and come back with `load`.
///
/// Repo layout, write-once like dev assets: `containers/images/<id>.tar` plus a JSON record
/// next to it. The id is the first 16 hex digits of the tar's sha256 (save output is not
/// byte-reproducible, so naming by image id would collide on a second offload).
public enum ContainerImages {
    public static let root = "containers"
    public static let folder = "containers/images"
    public static func tarPath(id: String) -> String { "\(folder)/\(id).tar" }
    public static func recordPath(id: String) -> String { "\(folder)/\(id).json" }
    public static func recordId(sha256: String) -> String { String(sha256.lowercased().prefix(16)) }

    /// Pulled, tagged or run within this many days counts as recently used.
    public static let recentDays = 30
}

/// Which engine holds an image.
public enum ContainerEngineKind: String, Codable, CaseIterable {
    case apple
    case dockerDesktop = "docker-desktop"
    case orbstack
    case colima
    case dory

    public var title: String {
        switch self {
        case .apple: return "Apple container"
        case .dockerDesktop: return "Docker Desktop"
        case .orbstack: return "OrbStack"
        case .colima: return "Colima"
        case .dory: return "Dory"
        }
    }

    /// Engines that keep images inside one VM disk file: deleting an image inside the VM
    /// gives space back to the Mac only once the VM trims its disk.
    public var usesVMDisk: Bool { self != .apple }
}

/// Why an image counts as in use, or why it is a candidate.
public enum ContainerImageUse: String, Codable {
    /// A running container uses it.
    case running
    /// A stopped container still refers to it; removing the container comes first.
    case stopped
    /// Pulled, tagged or run within `ContainerImages.recentDays`.
    case recent
    /// No tag left; usually an old build layer set.
    case dangling
    /// Nothing refers to it and it has not been used lately.
    case idle

    /// Offload and clean are refused while a container refers to the image.
    public var blocksRemoval: Bool { self == .running || self == .stopped }
}

public struct ContainerImage: Equatable {
    public var engine: ContainerEngineKind
    /// Docker image id (`sha256:...`) or the Apple image index digest.
    public var id: String
    /// `repo:tag` names; empty for a dangling image.
    public var references: [String]
    public var bytes: UInt64
    public var created: Date?
    /// When it was pulled or tagged here.
    public var pulled: Date?
    /// Latest start or stop of a container using it.
    public var lastRun: Date?
    /// Names of containers that refer to it, running first.
    public var containers: [String]
    public var use: ContainerImageUse

    public var title: String { references.first ?? "<none> " + String(Self.shortId(id)) }
    public var lastUsed: Date? { [pulled, lastRun].compactMap { $0 }.max() }

    /// The string the UI passes back: `<engine>/<id>`.
    public var key: String { "\(engine.rawValue)/\(id)" }

    public static func shortId(_ id: String) -> Substring {
        let bare = id.hasPrefix("sha256:") ? id.dropFirst("sha256:".count) : Substring(id)
        return bare.prefix(12)
    }

    public init(engine: ContainerEngineKind, id: String, references: [String], bytes: UInt64, created: Date? = nil, pulled: Date? = nil,
                lastRun: Date? = nil, containers: [String] = [], use: ContainerImageUse = .idle) {
        self.engine = engine
        self.id = id
        self.references = references
        self.bytes = bytes
        self.created = created
        self.pulled = pulled
        self.lastRun = lastRun
        self.containers = containers
        self.use = use
    }

    public func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = [
            "key": key, "engine": engine.rawValue, "id": id, "shortId": String(Self.shortId(id)), "title": title,
            "references": references, "bytes": NSNumber(value: bytes), "use": use.rawValue, "containers": containers,
            "inUse": use.blocksRemoval,
        ]
        if let created { object["created"] = iso.string(from: created) }
        if let pulled { object["pulled"] = iso.string(from: pulled) }
        if let lastRun { object["lastRun"] = iso.string(from: lastRun) }
        if let lastUsed { object["lastUsed"] = iso.string(from: lastUsed) }
        return object
    }
}

/// A container as far as image use goes.
public struct ContainerRef: Equatable {
    public var name: String
    /// Image id or digest the container was created from (may be empty when the CLI gives only a name).
    public var imageId: String
    /// The image name the container was created with.
    public var imageReference: String
    public var running: Bool
    public var lastActive: Date?

    public init(name: String, imageId: String, imageReference: String, running: Bool, lastActive: Date? = nil) {
        self.name = name
        self.imageId = imageId
        self.imageReference = imageReference
        self.running = running
        self.lastActive = lastActive
    }
}

public struct ContainerVolume: Equatable {
    public var engine: ContainerEngineKind
    public var name: String
    public var bytes: UInt64?
    /// Containers using it (Docker's `Links`); nil when the engine does not say.
    public var links: Int?

    public init(engine: ContainerEngineKind, name: String, bytes: UInt64?, links: Int?) {
        self.engine = engine
        self.name = name
        self.bytes = bytes
        self.links = links
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["engine": engine.rawValue, "name": name]
        if let bytes { object["bytes"] = NSNumber(value: bytes) }
        if let links { object["links"] = links; object["inUse"] = links > 0 }
        return object
    }
}

/// Parsing of each CLI's output, and the in-use decision. Pure: tests feed it captured output.
public enum ContainerParse {
    // MARK: in use

    /// Fills `containers`, `lastRun` and `use` from the containers that refer to each image.
    public static func classify(_ images: [ContainerImage], containers: [ContainerRef], now: Date = Date(),
                                recentDays: Int = ContainerImages.recentDays) -> [ContainerImage] {
        let recent = now.addingTimeInterval(-Double(recentDays) * 86_400)
        return images.map { image in
            var image = image
            let users = containers.filter { refers($0, to: image) }.sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }
            image.containers = users.map(\.name)
            image.lastRun = users.compactMap(\.lastActive).max() ?? image.lastRun
            if users.contains(where: \.running) {
                image.use = .running
            } else if !users.isEmpty {
                image.use = .stopped
            } else if image.references.isEmpty {
                image.use = .dangling
            } else if let used = image.lastUsed, used >= recent {
                image.use = .recent
            } else {
                image.use = .idle
            }
            return image
        }
    }

    /// Matches by image id or digest first: a container keeps the id even after its tag
    /// moved to a newer image. The name is a fallback for CLIs that report only names.
    public static func refers(_ container: ContainerRef, to image: ContainerImage) -> Bool {
        if !container.imageId.isEmpty { return sameId(container.imageId, image.id) }
        let wanted = normalizedReference(container.imageReference)
        return image.references.contains { normalizedReference($0) == wanted }
    }

    public static func sameId(_ a: String, _ b: String) -> Bool {
        let strip: (String) -> String = { ($0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : $0).lowercased() }
        let x = strip(a), y = strip(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        // Short ids (12 digits) match their full form.
        return x == y || (min(x.count, y.count) >= 12 && (x.hasPrefix(y) || y.hasPrefix(x)))
    }

    /// `nginx` and `docker.io/library/nginx:latest` name the same image.
    public static func normalizedReference(_ reference: String) -> String {
        var ref = reference
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        let lastSlash = ref.lastIndex(of: "/")
        let lastColon = ref.lastIndex(of: ":")
        if lastColon == nil || (lastSlash != nil && lastColon! < lastSlash!) { ref += ":latest" }
        var parts = ref.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let hasRegistry = parts.count > 1 && (parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost")
        if !hasRegistry { parts.insert("docker.io", at: 0) }
        if parts[0] == "index.docker.io" { parts[0] = "docker.io" }
        if parts[0] == "docker.io", parts.count == 2 { parts.insert("library", at: 1) }
        return parts.joined(separator: "/")
    }

    // MARK: dates and sizes

    public static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty, !text.hasPrefix("0001-01-01") else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Go prints nanoseconds; Foundation takes at most milliseconds.
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = text[text.index(after: dot)..<end]
            if digits.count > 3 { text = String(text[..<text.index(after: dot)]) + digits.prefix(3) + text[end...] }
        }
        if let date = fractional.date(from: text) { return date }
        // `docker ps` style: "2026-10-23 18:56:40 +0000 UTC".
        let go = DateFormatter()
        go.locale = Locale(identifier: "en_US_POSIX")
        go.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let trimmed = text.replacingOccurrences(of: " UTC", with: "").replacingOccurrences(of: #" [A-Z]{3,4}$"#, with: "", options: .regularExpression)
        return go.date(from: trimmed)
    }

    /// Docker's human sizes ("1.23GB", "512kB", "0B"). Docker uses decimal units.
    public static func dockerSize(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let split = trimmed.firstIndex(where: { !$0.isNumber && $0 != "." }) else { return Double(trimmed).map { UInt64($0) } }
        guard let value = Double(trimmed[..<split]) else { return nil }
        let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
                                       "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
        guard let scale = units[trimmed[split...].trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        return UInt64(value * scale)
    }

    // MARK: Docker

    /// `docker image inspect <ids...>` (a JSON array).
    public static func dockerImages(_ data: Data, engine: ContainerEngineKind) throws -> [ContainerImage] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DisklesslyError.failure("docker image inspect returned something other than an array")
        }
        return array.compactMap { item in
            guard let id = item["Id"] as? String else { return nil }
            let tags = ((item["RepoTags"] as? [String]) ?? []).filter { $0 != "<none>:<none>" }
            let metadata = item["Metadata"] as? [String: Any]
            let size = (item["Size"] as? NSNumber)?.uint64Value ?? (item["VirtualSize"] as? NSNumber)?.uint64Value ?? 0
            let created = date(item["Created"] as? String)
            return ContainerImage(engine: engine, id: id, references: tags, bytes: size, created: created,
                                  pulled: date(metadata?["LastTagTime"] as? String) ?? created)
        }
    }

    /// `docker container inspect <ids...>` (a JSON array).
    public static func dockerContainers(_ data: Data) throws -> [ContainerRef] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DisklesslyError.failure("docker container inspect returned something other than an array")
        }
        return array.map { item in
            let state = item["State"] as? [String: Any] ?? [:]
            let config = item["Config"] as? [String: Any] ?? [:]
            let name = ((item["Name"] as? String) ?? (item["Id"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let status = (state["Status"] as? String ?? "").lowercased()
            let running = (state["Running"] as? Bool) ?? (status == "running" || status == "restarting" || status == "paused")
            let active = [date(state["StartedAt"] as? String), date(state["FinishedAt"] as? String)].compactMap { $0 }.max()
            return ContainerRef(name: name, imageId: item["Image"] as? String ?? "", imageReference: config["Image"] as? String ?? "",
                                running: running, lastActive: active)
        }
    }

    /// One id per line (`docker image ls -q --no-trunc`, `docker ps -aq --no-trunc`), duplicates dropped.
    public static func ids(_ data: Data) -> [String] {
        var seen = Set<String>()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `docker system df -v --format '{{json .}}'`: volumes with size and link count.
    public static func dockerVolumes(_ data: Data, engine: ContainerEngineKind) -> [ContainerVolume] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let volumes = object["Volumes"] as? [[String: Any]] else { return [] }
        return volumes.compactMap { item in
            guard let name = item["Name"] as? String else { return nil }
            let size = (item["Size"] as? String).flatMap(dockerSize) ?? (item["UsageData"] as? [String: Any]).flatMap { ($0["Size"] as? NSNumber)?.uint64Value }
            let links: Int? = (item["Links"] as? NSNumber)?.intValue ?? (item["Links"] as? String).flatMap { Int($0) }
            return ContainerVolume(engine: engine, name: name, bytes: size, links: links)
        }
    }

    // MARK: Apple container

    public struct AppleImage: Equatable {
        public var image: ContainerImage
        /// Manifest digests of the variants this Mac has (`snapshots/<hex>` names).
        public var manifestDigests: [String]
    }

    /// `container image list --format json`. Sizes are left at 0: the caller measures the
    /// unpacked snapshots and blobs on disk, which is what the image really takes.
    public static func appleImages(_ data: Data) throws -> [AppleImage] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DisklesslyError.failure("container image list returned something other than an array")
        }
        return array.compactMap { item in
            let configuration = item["configuration"] as? [String: Any] ?? [:]
            let descriptor = configuration["descriptor"] as? [String: Any] ?? [:]
            guard let digest = (descriptor["digest"] as? String) ?? (item["id"] as? String).map({ "sha256:" + $0 }) else { return nil }
            let name = configuration["name"] as? String ?? ""
            let variants = (item["variants"] as? [[String: Any]]) ?? []
            let manifests = variants.compactMap { $0["digest"] as? String }
            let image = ContainerImage(engine: .apple, id: digest, references: name.isEmpty ? [] : [name], bytes: 0,
                                       created: date(configuration["creationDate"] as? String))
            return AppleImage(image: image, manifestDigests: manifests)
        }
    }

    /// `container list --all --format json`.
    public static func appleContainers(_ data: Data) throws -> [ContainerRef] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DisklesslyError.failure("container list returned something other than an array")
        }
        return array.map { item in
            let configuration = item["configuration"] as? [String: Any] ?? [:]
            let image = configuration["image"] as? [String: Any] ?? [:]
            let descriptor = image["descriptor"] as? [String: Any] ?? [:]
            let status = (item["status"] as? String ?? "").lowercased()
            return ContainerRef(name: configuration["id"] as? String ?? "", imageId: descriptor["digest"] as? String ?? "",
                                imageReference: image["reference"] as? String ?? "", running: status == "running",
                                lastActive: date(item["startedDate"] as? String))
        }
    }

    /// `container volume list --format json`: names only; the caller measures the folders.
    public static func appleVolumes(_ data: Data) -> [String] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { ($0["name"] as? String) ?? (($0["configuration"] as? [String: Any])?["name"] as? String) }
    }

    /// Blobs one Apple image owns on disk: the index, each local manifest, its config and layers.
    /// `blob(hex)` returns a blob's bytes when it is stored here.
    public static func appleBlobDigests(index: String, blob: (String) -> Data?) -> Set<String> {
        let hex: (String) -> String = { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : $0 }
        var found: Set<String> = []
        var pending = [hex(index)]
        while let next = pending.popLast() {
            guard !found.contains(next), let data = blob(next) else { continue }
            found.insert(next)
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for manifest in (object["manifests"] as? [[String: Any]]) ?? [] { if let d = manifest["digest"] as? String { pending.append(hex(d)) } }
            if let config = (object["config"] as? [String: Any])?["digest"] as? String { pending.append(hex(config)) }
            for layer in (object["layers"] as? [[String: Any]]) ?? [] { if let d = layer["digest"] as? String { pending.append(hex(d)) } }
        }
        return found
    }
}

/// An image saved in the repo.
public struct ContainerImageRecord: Codable, Equatable {
    public var schema = 1
    public var id: String
    public var engine: ContainerEngineKind
    /// The engine's image id when it was saved (Docker id or Apple index digest).
    public var imageId: String
    public var references: [String]
    public var sha256: String
    /// Size of the tar in the repo.
    public var size: UInt64
    /// What the image took on this Mac.
    public var localBytes: UInt64
    public var offloadedAt: Date
    public var host: String

    public init(engine: ContainerEngineKind, imageId: String, references: [String], sha256: String, size: UInt64, localBytes: UInt64,
                host: String, offloadedAt: Date = Date()) {
        self.id = ContainerImages.recordId(sha256: sha256)
        self.engine = engine
        self.imageId = imageId
        self.references = references
        self.sha256 = sha256.lowercased()
        self.size = size
        self.localBytes = localBytes
        // Whole seconds, so the record reads back equal from its ISO 8601 JSON.
        self.offloadedAt = Date(timeIntervalSince1970: offloadedAt.timeIntervalSince1970.rounded(.down))
        self.host = host
    }

    public var title: String { references.first ?? "<none> " + String(ContainerImage.shortId(imageId)) }
    public var tar: String { ContainerImages.tarPath(id: id) }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ContainerImageRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContainerImageRecord.self, from: data)
    }

    /// The image is back in an engine here.
    public func present(in images: [ContainerImage]) -> Bool {
        images.contains { $0.engine == engine && ContainerParse.sameId($0.id, imageId) }
    }

    public func jsonObject(present: Bool) -> [String: Any] {
        ["id": id, "engine": engine.rawValue, "imageId": imageId, "shortId": String(ContainerImage.shortId(imageId)), "title": title,
         "references": references, "bytes": NSNumber(value: size), "localBytes": NSNumber(value: localBytes),
         "offloadedAt": ISO8601DateFormatter().string(from: offloadedAt), "host": host, "present": present]
    }
}
