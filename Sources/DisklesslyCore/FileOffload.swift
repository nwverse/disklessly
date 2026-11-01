import Foundation

/// The small file left where an offloaded file or folder was: `Name.ext.disklessly`.
/// It holds everything `disklessly fetch` needs, so it still works after the local registry is gone.
public struct FilePlaceholder: Codable, Equatable {
    public enum Kind: String, Codable { case file, folder }

    public static let schemaV1 = "file/1"
    public static let fileExtension = "disklessly"
    /// Uniform type exported by Disklessly.app for the placeholder.
    public static let typeIdentifier = "io.github.s546126.disklessly.placeholder"
    /// Finder tag added to the placeholder.
    public static let finderTag = "Disklessly"

    public var schema: String
    public var id: String
    public var kind: Kind
    /// The original name (`Movie.mov`, `Old Project`), restored next to the placeholder.
    public var name: String
    /// Logical bytes of the original (a folder: sum of its files).
    public var size: UInt64
    /// Object in the repo: `files/objects/<sha256>.bin` or `.tar.zst`.
    public var object: String
    /// `none` for a file stored as is, `tar+zstd` for a folder.
    public var codec: String
    /// SHA-256 and size of the repo object.
    public var sha256: String
    public var storedSize: UInt64
    public var repoId: String?
    public var originalPath: String
    public var createdAt: Date
    public var modifiedAt: Date?
    public var posixPermissions: Int?
    public var device: String?

    public init(id: String, kind: Kind, name: String, size: UInt64, object: String, codec: String, sha256: String, storedSize: UInt64, repoId: String?, originalPath: String, createdAt: Date, modifiedAt: Date? = nil, posixPermissions: Int? = nil, device: String? = nil) {
        self.schema = Self.schemaV1
        self.id = id; self.kind = kind; self.name = name; self.size = size; self.object = object; self.codec = codec
        self.sha256 = sha256; self.storedSize = storedSize; self.repoId = repoId; self.originalPath = originalPath
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.posixPermissions = posixPermissions; self.device = device
    }

    public static func objectPath(sha256: String, kind: Kind) -> String {
        "files/objects/\(sha256.lowercased()).\(kind == .folder ? "tar.zst" : "bin")"
    }

    /// `/a/Movie.mov` -> `/a/Movie.mov.disklessly`.
    public static func placeholderURL(for original: URL) -> URL {
        original.deletingLastPathComponent().appendingPathComponent(original.lastPathComponent + "." + fileExtension)
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FilePlaceholder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let placeholder: FilePlaceholder
        do { placeholder = try decoder.decode(FilePlaceholder.self, from: data) }
        catch { throw DisklesslyError.usage("not a Disklessly placeholder (\(error.localizedDescription))") }
        try placeholder.validate()
        return placeholder
    }

    public static func read(_ url: URL) throws -> FilePlaceholder {
        guard url.pathExtension == fileExtension else { throw DisklesslyError.usage("\(url.path) is not a .\(fileExtension) placeholder") }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 1 << 20 else { throw DisklesslyError.usage("\(url.path) is not a Disklessly placeholder") }
        return try decode(Data(contentsOf: url))
    }

    public func validate() throws {
        guard schema == Self.schemaV1 else { throw DisklesslyError.unsupported("placeholder schema \(schema) is newer than this Disklessly; update it") }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard sha256.count == 64, sha256.unicodeScalars.allSatisfy(hex.contains) else { throw DisklesslyError.integrity("placeholder has a malformed sha256") }
        guard object == Self.objectPath(sha256: sha256, kind: kind) else { throw DisklesslyError.integrity("placeholder names an unexpected repo object: \(object)") }
        guard FileOffloadPolicy.isPlainName(name) else { throw DisklesslyError.integrity("placeholder has an unsafe name: \(name)") }
        guard codec == (kind == .folder ? "tar+zstd" : "none") else { throw DisklesslyError.unsupported("placeholder codec \(codec) is not supported") }
    }
}

/// Which paths may be offloaded, and which the large-file scan never lists.
public enum FileOffloadPolicy {
    /// Package-manager stores, build output and tool folders. A folder with one of these names is skipped whole.
    public static let skippedFolderNames: Set<String> = [
        "node_modules", "bower_components", ".git", ".hg", ".svn", "Pods", "Carthage", "DerivedData", ".build",
        "__pycache__", ".venv", "venv", ".tox", ".gradle", ".m2", ".cargo", ".rustup", "target", ".npm", ".pnpm-store",
        ".yarn", ".cache", "site-packages", "vendor", ".terraform", ".next", ".nuxt",
    ]
    /// Bundles that belong to an app's live library or are a VM disk. They are never offloaded as a whole.
    public static let skippedExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "photolibrary", "aplibrary", "migratedphotolibrary",
        "vmwarevm", "pvm", "utm", "vbox", "vdi", "vmdk", "qcow2", "hdd", "hds", "sparsebundle", "sparseimage",
        "icloud", "download", "crdownload", "part", "partial", FilePlaceholder.fileExtension,
    ]
    /// Names that are a running VM's disk even without one of the extensions above.
    public static let skippedFileNames: Set<String> = ["Docker.raw", "Docker.qcow2", "data.img", "disk.img", ".DS_Store"]
    /// Folders under the home folder that are never scanned or offloaded. `Library` holds app data
    /// (Apple `container` images, Docker, caches) that only its own app can manage.
    public static let skippedHomeChildren: Set<String> = ["Library", "Applications", ".Trash", "Public"]

    /// A single path component that is safe to recreate next to the placeholder.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Why `path` may not be offloaded, or nil. `path` is absolute and standardized.
    /// `protected` holds Disklessly's own repo, cache and state folders.
    public static func refusal(path: String, home: String, protected: [String], isDirectory: Bool, isSymlink: Bool) -> String? {
        let p = (path as NSString).standardizingPath
        let h = (home as NSString).standardizingPath
        func inside(_ root: String) -> Bool {
            let r = (root as NSString).standardizingPath
            return !r.isEmpty && (p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/"))
        }
        if isSymlink { return "is a symbolic link; offload what it points to instead" }
        if p.hasSuffix("." + FilePlaceholder.fileExtension) { return "is already a Disklessly placeholder" }
        guard p.hasPrefix(h + "/") else { return "is outside your home folder" }
        let rest = p.dropFirst(h.count + 1).split(separator: "/").map(String.init)
        guard let top = rest.first else { return "is your home folder" }
        if skippedHomeChildren.contains(top) { return "is inside ~/\(top), which apps manage themselves" }
        if rest.count == 1, ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].contains(top) {
            return "is a standard folder; offload what is inside it instead"
        }
        for component in rest.dropLast() {
            if (component as NSString).pathExtension.lowercased() == "app" { return "is inside an app bundle" }
        }
        if let last = rest.last {
            let ext = (last as NSString).pathExtension.lowercased()
            if ext == "app" { return "is an app; use `disklessly pack` for apps" }
            if skippedExtensions.contains(ext) { return "is a .\(ext) item that its app or VM manages" }
        }
        if protected.contains(where: { inside($0) || (($0 as NSString).standardizingPath).hasPrefix(p + "/") }) {
            return "holds Disklessly's own repo, cache or state"
        }
        _ = isDirectory
        return nil
    }

    /// The scan skips this folder and everything below it.
    public static func skipsFolder(name: String) -> Bool {
        skippedFolderNames.contains(name) || skippedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The scan never lists this file.
    public static func skipsFile(name: String) -> Bool {
        if skippedFileNames.contains(name) { return true }
        if name.hasPrefix(".") && name.hasSuffix(".icloud") { return true }
        return skippedExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Offloaded files this Mac knows about: `<stateDir>/files/offloaded.json`.
/// The placeholder is the source of truth; this list counts toward the free limit and lists them.
public struct OffloadedFileRecord: Codable, Equatable {
    public var id: String
    public var placeholderPath: String
    public var name: String
    public var kind: FilePlaceholder.Kind
    public var size: UInt64
    public var object: String
    public var createdAt: Date
    public init(id: String, placeholderPath: String, name: String, kind: FilePlaceholder.Kind, size: UInt64, object: String, createdAt: Date) {
        self.id = id; self.placeholderPath = placeholderPath; self.name = name; self.kind = kind; self.size = size; self.object = object; self.createdAt = createdAt
    }
}

public enum OffloadedFileRegistry {
    public static func url(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("files/offloaded.json")
    }

    public static func load(stateDir: String) -> [OffloadedFileRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(stateDir: stateDir)),
              let records = try? decoder.decode([OffloadedFileRecord].self, from: data) else { return [] }
        return records
    }

    /// Records whose placeholder is still on disk. A deleted placeholder no longer counts.
    public static func live(stateDir: String) -> [OffloadedFileRecord] {
        load(stateDir: stateDir).filter { FileManager.default.fileExists(atPath: $0.placeholderPath) }
    }

    public static func update(stateDir: String, _ change: (inout [OffloadedFileRecord]) -> Void) throws {
        var records = load(stateDir: stateDir)
        change(&records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let target = url(stateDir: stateDir)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: target, options: .atomic)
    }
}

extension SHA256Digest {
    /// Hashes a repo object by reading it back in ranges, without keeping a local copy.
    /// This is the check that runs before the original is deleted.
    public static func hexRemote(backend: any StorageBackend, path: String, size: UInt64, chunk: UInt64 = 8 << 20) throws -> String {
        var hasher = Hasher()
        var offset: UInt64 = 0
        while offset < size {
            let end = min(size, offset + chunk)
            let data = try backend.get(path, range: offset..<end)
            guard UInt64(data.count) == end - offset else {
                throw DisklesslyError.integrity("reading back \(path) returned \(data.count) bytes at offset \(offset), expected \(end - offset)")
            }
            hasher.update(data)
            offset = end
        }
        return hasher.finalize()
    }
}
