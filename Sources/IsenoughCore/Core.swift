import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum IsenoughError: Error, LocalizedError, Equatable {
    case usage(String), unsupported(String), backend(String), integrity(String), busy(String), diskImage(String), noSpace(String), failure(String), hook(String), resolution(String)
    public var exitCode: Int {
        switch self {
        case .usage: 2
        case .unsupported: 3
        case .backend: 4
        case .integrity: 5
        case .diskImage: 6
        case .noSpace: 8
        case .hook: 10
        case .busy: 9
        case .resolution: 14
        case .failure: 1
        }
    }
    public var errorDescription: String? {
        switch self {
        case .usage(let s), .unsupported(let s), .backend(let s), .integrity(let s), .busy(let s), .diskImage(let s), .noSpace(let s), .failure(let s), .hook(let s), .resolution(let s): s
        }
    }
}

public struct ImageManifest: Equatable {
    public let schema: String
    public var imageId: String
    public var bundleId: String
    public var name: String
    public var version: String
    /// `CFBundleVersion`. Empty on manifests written before multi-machine identity.
    public var build: String
    /// Mach-O slices the packed app contains, sorted. Empty on older manifests.
    public var architectures: [String]
    /// Tree hash that identifies the app across machines. Receipt bytes are not part of it.
    /// When nil, `app.treeHash` is the only recorded digest.
    public var contentTreeHash: String?
    public var image: Image
    public var app: App
    public var mode: Mode
    public var createdAt: Date
    public enum Mode: String, Codable { case mount, restore }
    public struct Image: Codable, Equatable {
        public var file: String; public var format: String; public var sha256: String; public var size: UInt64; public var volumeName: String; public var appPathInVolume: String
        public init(file: String, format: String, sha256: String, size: UInt64, volumeName: String, appPathInVolume: String) { self.file=file; self.format=format; self.sha256=sha256; self.size=size; self.volumeName=volumeName; self.appPathInVolume=appPathInVolume }
    }
    public struct App: Codable, Equatable {
        public var originalPath: String
        public var executable: String
        public var documentTypes: [[String: AnyCodable]]
        public var urlTypes: [[String: AnyCodable]]
        /// Code-directory hash recorded at pack. On macOS this is `codesign`'s CDHash when the bundle is signed; otherwise it is the sha256 of the main executable.
        public var cdhash: String?
        /// Canonical tree hash from `BundleHasher`, recorded at pack. This is the post-image tree
        /// restore verifies. It uses the same digest format as `contentTreeHash`.
        public var treeHash: String?
        public init(originalPath: String, executable: String, documentTypes: [[String: AnyCodable]], urlTypes: [[String: AnyCodable]], cdhash: String? = nil, treeHash: String? = nil) {
            self.originalPath=originalPath; self.executable=executable; self.documentTypes=documentTypes; self.urlTypes=urlTypes; self.cdhash=cdhash; self.treeHash=treeHash
        }
    }
    public init(bundleId: String, name: String, version: String, image: Image, app: App, mode: Mode = .mount, createdAt: Date = Date(), build: String = "", architectures: [String] = [], contentTreeHash: String? = nil, imageId explicitImageId: String? = nil) {
        self.schema = "image/1"; self.bundleId = bundleId; self.name = name; self.version = version; self.image = image; self.app = app; self.mode = mode; self.createdAt = createdAt
        self.build = build
        self.architectures = ImageIdentity.normalize(architectures)
        self.contentTreeHash = contentTreeHash
        if let explicitImageId {
            self.imageId = explicitImageId
        } else if let contentTreeHash, !contentTreeHash.isEmpty {
            self.imageId = ImageIdentity(bundleId: bundleId, version: version, build: build, architectures: architectures, treeHash: contentTreeHash).imageId()
        } else {
            self.imageId = "\(bundleId)-\(version)-\(String(image.sha256.prefix(8)))"
        }
        if self.image.file.isEmpty { self.image.file = "images/\(self.imageId).dmg" }
    }
    /// Identity used to recognize the same app on another Mac. Prefers the content hash.
    public var resolvedIdentity: ImageIdentity? {
        let hash = contentTreeHash ?? app.treeHash
        guard let hash, !hash.isEmpty else { return nil }
        return ImageIdentity(bundleId: bundleId, version: version, build: build, architectures: architectures, treeHash: hash)
    }
    public func validate() throws {
        guard schema == "image/1" else { throw IsenoughError.failure("Unsupported manifest schema: \(schema)") }
        guard image.format == "ULMO", image.sha256.count == 64, image.size > 0 else { throw IsenoughError.integrity("Invalid image metadata") }
    }
    public func encode() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; e.dateEncodingStrategy = .iso8601; return try e.encode(self) }
    public static func decode(_ data: Data) throws -> Self { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; let m = try d.decode(Self.self, from: data); try m.validate(); return m }
}

extension ImageManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case schema, imageId, bundleId, name, version, build, architectures, contentTreeHash, image, app, mode, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? "image/1"
        imageId = try container.decode(String.self, forKey: .imageId)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        build = try container.decodeIfPresent(String.self, forKey: .build) ?? ""
        architectures = try container.decodeIfPresent([String].self, forKey: .architectures) ?? []
        contentTreeHash = try container.decodeIfPresent(String.self, forKey: .contentTreeHash)
        image = try container.decode(Image.self, forKey: .image)
        app = try container.decode(App.self, forKey: .app)
        mode = try container.decode(Mode.self, forKey: .mode)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(imageId, forKey: .imageId)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(build, forKey: .build)
        try container.encode(architectures, forKey: .architectures)
        try container.encodeIfPresent(contentTreeHash, forKey: .contentTreeHash)
        try container.encode(image, forKey: .image)
        try container.encode(app, forKey: .app)
        try container.encode(mode, forKey: .mode)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct AnyCodable: Codable, Equatable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if c.decodeNil() { value = NSNull() } else if let b = try? c.decode(Bool.self) { value = b } else if let i = try? c.decode(Int64.self) { value = i } else if let d = try? c.decode(Double.self) { value = d } else if let s = try? c.decode(String.self) { value = s } else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) } else { value = try c.decode([String: AnyCodable].self).mapValues(\.value) } }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch value { case is NSNull: try c.encodeNil(); case let x as Bool: try c.encode(x); case let x as Int: try c.encode(x); case let x as Int64: try c.encode(x); case let x as Double: try c.encode(x); case let x as String: try c.encode(x); case let x as [Any]: try c.encode(x.map(AnyCodable.init)); case let x as [String: Any]: try c.encode(x.mapValues(AnyCodable.init)); default: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported plist value")) } }
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool { String(describing: lhs.value) == String(describing: rhs.value) }
}

public enum SessionState: String, Codable, CaseIterable { case remote, downloading, verifying, cached, mounted, running, idle, detaching, backoff, stuck }
public enum SessionEvent { case fetch, downloaded, verified, attach, open, quit, detach, detachFailed, revive, evicted }
public struct StateMachine {
    public static func transition(_ state: SessionState, _ event: SessionEvent) throws -> SessionState {
        switch (state, event) {
        case (.remote, .fetch): .downloading
        case (.downloading, .downloaded): .verifying
        case (.verifying, .verified): .cached
        case (.cached, .attach): .mounted
        case (.mounted, .open): .running
        case (.running, .quit): .idle
        case (.idle, .detach): .detaching
        case (.detaching, .detach): .cached
        case (.detaching, .detachFailed): .backoff
        case (.backoff, .revive), (.stuck, .revive): .running
        case (.cached, .evicted): .remote
        default: throw IsenoughError.failure("Illegal lifecycle transition \(state) + \(event)")
        }
    }
}

/// Input to the original quota planner. The state file uses `CacheEntry` (`state/2`).
public struct PolicyCacheEntry: Codable, Equatable { public var id: String; public var size: UInt64; public var lastUsed: Date; public var pinned: Bool; public var mounted: Bool; public init(id: String, size: UInt64, lastUsed: Date, pinned: Bool = false, mounted: Bool = false) { self.id=id; self.size=size; self.lastUsed=lastUsed; self.pinned=pinned; self.mounted=mounted } }
public enum CachePolicy {
    public static func evictionPlan(_ entries: [PolicyCacheEntry], quota: UInt64) -> [String] {
        var total = entries.reduce(UInt64(0)) { $0 + $1.size }; guard total > quota else { return [] }
        var victims: [String] = []
        for entry in entries.filter({ !$0.pinned && !$0.mounted }).sorted(by: { $0.lastUsed < $1.lastUsed }) { victims.append(entry.id); total = total >= entry.size ? total - entry.size : 0; if total <= quota { break } }
        return victims
    }
}

public struct ResumableBody: Equatable {
    public var data: Data
    /// The server ignored `Range` and returned the object from byte 0.
    public var restart: Bool
    public init(data: Data, restart: Bool) {
        self.data = data
        self.restart = restart
    }
}

/// Result of streaming a remote object onto disk. `bytesWritten` is the size of this
/// response, not the total size of a resumed file.
public struct ResumableFile: Equatable {
    public var restart: Bool
    public var bytesWritten: UInt64
    public init(restart: Bool, bytesWritten: UInt64) {
        self.restart = restart
        self.bytesWritten = bytesWritten
    }
}

public protocol StorageBackend {
    func list(_ path: String) throws -> [String]
    func stat(_ path: String) throws -> BackendStat?
    /// Small objects (manifests, JSON). Large images and archives use `download`.
    func get(_ path: String, range: Range<UInt64>?) throws -> Data
    func put(_ path: String, data: Data) throws
    /// Upload a local file without reading it into one `Data`.
    func put(_ path: String, file: URL) throws
    func delete(_ path: String) throws
    func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody
    /// Stream `path` onto `destination`, appending when `offset` is past zero and the server honored `Range`.
    func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile
    /// Local directory for file-backed backends. Nil for HTTP backends.
    func localRoot() -> URL?
    func ensureCollection(_ path: String) throws
}

extension StorageBackend {
    public func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody {
        guard let info = try stat(path) else { throw IsenoughError.backend("remote object is missing: \(path)") }
        if offset > info.size { throw IsenoughError.integrity("cached partial is larger than the remote object") }
        if offset == info.size { return ResumableBody(data: Data(), restart: false) }
        return ResumableBody(data: try get(path, range: offset..<info.size), restart: false)
    }
    public func put(_ path: String, file: URL) throws {
        let size = try ChunkedIO.byteCount(file)
        if size > 32 * 1024 * 1024 {
            throw IsenoughError.unsupported("this backend cannot stream an upload of \(size) bytes")
        }
        try put(path, data: ChunkedIO.readAll(file))
    }
    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        let body = try getResumable(path, offset: offset)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if body.restart || offset == 0 {
            try ChunkedIO.writeAtomically(body.data, to: destination)
        } else if !body.data.isEmpty {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-append-\(UUID().uuidString)")
            try body.data.write(to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            try ChunkedIO.appendFile(staging, to: destination)
        }
        return ResumableFile(restart: body.restart, bytesWritten: UInt64(body.data.count))
    }
    public func localRoot() -> URL? { nil }
    public func ensureCollection(_ path: String) throws {
        throw IsenoughError.unsupported("this backend has no local directory")
    }
}
public struct FileLock {
    public let path: String
    private var descriptor: Int32 = -1
    public init(path: String) { self.path=path }
    public var isLocked: Bool { descriptor >= 0 }
    public mutating func lock() throws { try acquire(LOCK_EX) }
    /// Non-blocking exclusive lock. `false` means another process holds it.
    public mutating func tryLock() throws -> Bool {
        if descriptor >= 0 { return true }
        // CLOEXEC so a posix_spawn'd watcher does not inherit the lock.
        // flock is tied to the open file description; an inherited fd keeps the
        // exclusive lock after the parent unlocks and the child then blocks forever.
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw IsenoughError.failure("Cannot open lock file") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }
    public mutating func unlock() { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); _ = close(descriptor); descriptor = -1 } }
    private mutating func acquire(_ operation: Int32) throws {
        #if canImport(Darwin)
        importDarwinLockUnavailable()
        #endif
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600)); guard fd >= 0 else { throw IsenoughError.failure("Cannot open lock file") }
        guard flock(fd, operation) == 0 else { close(fd); throw IsenoughError.failure("Cannot acquire lock") }; descriptor=fd
    }
    #if canImport(Darwin)
    private func importDarwinLockUnavailable() {}
    #endif
}

/// `hdiutil`, `diskutil`, and `codesign` are spawned with `LC_ALL=C` and `LANG=en_US.UTF-8`.
/// That does not select hdiutil's language: macOS follows the user's AppleLanguages.
/// Failures are classified by exit status. `codesign -dvvv`'s `CDHash=` field is a stable
/// machine key, not a translated sentence. `open` is not included: its environment is
/// inherited by the launched app.
public enum ParsedCommand {
    /// These basenames get the pinned locale variables. The name is not a claim that
    /// the tool then speaks English; hdiutil still follows AppleLanguages.
    public static func pinsLocale(_ path: String) -> Bool {
        switch (path as NSString).lastPathComponent {
        case "hdiutil", "diskutil", "codesign": return true
        default: return false
        }
    }

    public static func environment(inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["LC_ALL"] = "C"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    public static func process(path: String, arguments: [String], inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if pinsLocale(path) {
            process.environment = environment(inheriting: base)
        }
        return process
    }
}

public struct BackendStat: Equatable { public var size: UInt64; public var modified: Date; public init(size: UInt64, modified: Date) { self.size=size; self.modified=modified } }
public struct LocalFolderBackend: StorageBackend {
    public let root: URL
    /// When set, directory listings and stats run on a background thread and fail
    /// instead of blocking the caller. iCloud Drive uses this.
    public var boundsListing: Bool
    public var listTimeout: TimeInterval
    /// Download evicted ubiquitous items before reading them.
    public var materializeReads: Bool
    public var materializeTimeout: TimeInterval

    public init(root: URL, boundsListing: Bool = false, listTimeout: TimeInterval = 20, materializeReads: Bool = false, materializeTimeout: TimeInterval = 900) throws {
        self.root = root.standardizedFileURL
        self.boundsListing = boundsListing
        self.listTimeout = listTimeout
        self.materializeReads = materializeReads
        self.materializeTimeout = materializeTimeout
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    private func url(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw IsenoughError.usage("Invalid backend path") }
        return root.appendingPathComponent(path)
    }

    public func list(_ path: String = "") throws -> [String] {
        let directory = try url(path)
        if boundsListing {
            let coordinated = materializeReads
            return try BlockingCall.run(seconds: listTimeout, what: "listing \(directory.path)") {
                try Self.names(in: directory, coordinated: coordinated)
            }
        }
        return try Self.names(in: directory, coordinated: false)
    }

    public func stat(_ path: String) throws -> BackendStat? {
        let file = try url(path)
        let attrs: [FileAttributeKey: Any]?
        if boundsListing {
            attrs = try BlockingCall.run(seconds: listTimeout, what: "stat \(file.path)") {
                try? FileManager.default.attributesOfItem(atPath: file.path)
            }
        } else {
            attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        }
        guard let attrs, let size = attrs[.size] as? NSNumber else { return nil }
        return BackendStat(size: size.uint64Value, modified: attrs[.modificationDate] as? Date ?? .distantPast)
    }

    public func get(_ path: String, range: Range<UInt64>? = nil) throws -> Data {
        let file = try url(path)
        try UbiquitousMaterializer.beforeRead(file, timeout: materializeTimeout, enabled: materializeReads)
        if let range {
            let length = range.upperBound > range.lowerBound ? range.upperBound - range.lowerBound : 0
            var data = Data()
            _ = try ChunkedIO.read(file, offset: range.lowerBound, count: length) { data.append($0) }
            return data
        }
        return try ChunkedIO.readAll(file)
    }

    public func put(_ path: String, data: Data) throws {
        let destination = try url(path)
        try ChunkedIO.writeAtomically(data, to: destination)
    }

    public func put(_ path: String, file: URL) throws {
        let destination = try url(path)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try ChunkedIO.copyFile(from: file, to: temporary)
            try ChunkedIO.replaceFile(destination, with: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        let file = try url(path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw IsenoughError.backend("remote object is missing: \(path)")
        }
        try UbiquitousMaterializer.beforeRead(file, timeout: materializeTimeout, enabled: materializeReads)
        let size = try ChunkedIO.byteCount(file)
        if offset > size { throw IsenoughError.integrity("cached partial is larger than the remote object") }
        if offset == size { return ResumableFile(restart: false, bytesWritten: 0) }
        if offset == 0 {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).fetch-\(UUID().uuidString)")
            try ChunkedIO.copyFile(from: file, to: temporary)
            try ChunkedIO.replaceFile(destination, with: temporary)
            return ResumableFile(restart: false, bytesWritten: size)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-range-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeTail(of: file, offset: offset, length: size - offset, to: temporary)
        try ChunkedIO.appendFile(temporary, to: destination)
        return ResumableFile(restart: false, bytesWritten: size - offset)
    }

    public func delete(_ path: String) throws {
        let file = try url(path)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    public func localRoot() -> URL? { root }

    public func ensureCollection(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    private static func names(in directory: URL, coordinated: Bool) throws -> [String] {
        #if os(macOS)
        if coordinated { return try coordinatedNames(directory) }
        #else
        _ = coordinated
        #endif
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    #if os(macOS)
    private static func coordinatedNames(_ directory: URL) throws -> [String] {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var names: [String] = []
        var readError: Error?
        coordinator.coordinate(readingItemAt: directory, options: [.immediatelyAvailableMetadataOnly], error: &coordinationError) { url in
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            } catch {
                readError = error
            }
        }
        if let coordinationError {
            throw IsenoughError.backend("could not coordinate a read of \(directory.path): \(coordinationError.localizedDescription). \(ICloudLimits.permissionHint)")
        }
        if let readError { throw readError }
        return names.sorted()
    }
    #endif

    private func writeTail(of source: URL, offset: UInt64, length: UInt64, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw IsenoughError.failure("cannot write \(destination.path)")
        }
        let output = open(destination.path, O_WRONLY | O_TRUNC)
        guard output >= 0 else { throw IsenoughError.failure("cannot write \(destination.path)") }
        defer { _ = close(output) }
        _ = try ChunkedIO.read(source, offset: offset, count: length) { chunk in
            try chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let n: Int
                    #if canImport(Glibc)
                    n = Glibc.write(output, base.advanced(by: sent), raw.count - sent)
                    #else
                    n = Darwin.write(output, base.advanced(by: sent), raw.count - sent)
                    #endif
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { throw IsenoughError.failure("cannot write \(destination.path)") }
                    sent += n
                }
            }
        }
    }
}
