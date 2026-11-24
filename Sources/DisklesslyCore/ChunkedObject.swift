import Foundation

/// Manifest describing a large offloaded file or folder archive split into content-addressed
/// chunks (`files/chunks/<sha256>.bin`) so remote uploads, verification, and downloads can run
/// in parallel across multiple streams.
public struct ChunkedObjectManifest: Codable, Equatable {
    public static let schemaV1 = "chunks/1"

    public struct Chunk: Codable, Equatable {
        public var index: Int
        public var path: String
        public var sha256: String
        public var size: UInt64

        public init(index: Int, path: String, sha256: String, size: UInt64) {
            self.index = index
            self.path = path
            self.sha256 = sha256
            self.size = size
        }
    }

    public var schema: String
    /// Payload codec before chunking: `"none"` for files or `"tar+zstd"` for folders.
    public var codec: String
    /// SHA-256 of the concatenated chunk stream (exact match with single-object digest).
    public var sha256: String
    public var totalSize: UInt64
    public var chunkSize: UInt64
    public var chunks: [Chunk]

    public init(codec: String, sha256: String, totalSize: UInt64, chunkSize: UInt64, chunks: [Chunk]) {
        self.schema = Self.schemaV1
        self.codec = codec
        self.sha256 = sha256.lowercased()
        self.totalSize = totalSize
        self.chunkSize = chunkSize
        self.chunks = chunks
    }

    /// Permanent content-addressed path for one chunk. Uses `.bin` so RepoCopier never treats it as transient.
    public static func chunkPath(sha256: String) -> String {
        "files/chunks/\(sha256.lowercased()).bin"
    }

    /// Manifest path under `files/objects/`.
    public static func manifestPath(sha256: String) -> String {
        "files/objects/\(sha256.lowercased()).chunks.json"
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ChunkedObjectManifest {
        let manifest: ChunkedObjectManifest
        do {
            manifest = try JSONDecoder().decode(ChunkedObjectManifest.self, from: data)
        } catch {
            throw DisklesslyError.integrity("malformed chunk manifest (\(error.localizedDescription))")
        }
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard schema == Self.schemaV1 else {
            throw DisklesslyError.unsupported("chunk manifest schema \(schema) is newer than this Disklessly; update it")
        }
        guard codec == "none" || codec == "tar+zstd" else {
            throw DisklesslyError.unsupported("chunk manifest codec \(codec) is not supported")
        }
        guard Self.isHex64(sha256), sha256 == sha256.lowercased() else {
            throw DisklesslyError.integrity("chunk manifest has a malformed sha256")
        }
        guard chunkSize > 0, !chunks.isEmpty else {
            throw DisklesslyError.integrity("chunk manifest has no chunks")
        }
        var sum: UInt64 = 0
        for (expectedIndex, chunk) in chunks.enumerated() {
            guard chunk.index == expectedIndex else {
                throw DisklesslyError.integrity("chunk manifest has non-sequential index \(chunk.index) (expected \(expectedIndex))")
            }
            guard Self.isHex64(chunk.sha256), chunk.sha256 == chunk.sha256.lowercased() else {
                throw DisklesslyError.integrity("chunk \(chunk.index) has a malformed sha256")
            }
            guard chunk.path == Self.chunkPath(sha256: chunk.sha256) else {
                throw DisklesslyError.integrity("chunk \(chunk.index) names an unexpected path: \(chunk.path)")
            }
            guard chunk.size > 0 else {
                throw DisklesslyError.integrity("chunk \(chunk.index) has zero size")
            }
            sum += chunk.size
        }
        guard sum == totalSize else {
            throw DisklesslyError.integrity("chunk sizes sum to \(sum), expected \(totalSize)")
        }
    }

    static func isHex64(_ value: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64 && value.unicodeScalars.allSatisfy(hex.contains)
    }
}

/// Tuning parameters for multi-stream chunked file/folder offload and restore.
public struct ChunkedTransferConfig: Equatable {
    public var streams: Int
    public var chunkSize: UInt64
    public var thresholdBytes: UInt64
    public var forceChunks: Bool

    public init(streams: Int = 4, chunkSize: UInt64 = 64 * 1024 * 1024, thresholdBytes: UInt64 = 128 * 1024 * 1024, forceChunks: Bool = false) {
        self.streams = min(8, max(1, streams))
        self.chunkSize = min(256 * 1024 * 1024, max(64 * 1024, chunkSize))
        self.thresholdBytes = max(64 * 1024, thresholdBytes)
        self.forceChunks = forceChunks
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> ChunkedTransferConfig {
        let streams = environment["DISKLESSLY_UPLOAD_STREAMS"].flatMap(Int.init) ?? 4
        let chunkSize = environment["DISKLESSLY_CHUNK_SIZE_BYTES"].flatMap(UInt64.init) ?? (64 * 1024 * 1024)
        let threshold = environment["DISKLESSLY_CHUNK_THRESHOLD_BYTES"].flatMap(UInt64.init) ?? (128 * 1024 * 1024)
        let force = environment["DISKLESSLY_FORCE_CHUNKS"] == "1"
        return ChunkedTransferConfig(streams: streams, chunkSize: chunkSize, thresholdBytes: threshold, forceChunks: force)
    }

    public func shouldChunk(logicalBytes: UInt64, isRemote: Bool) -> Bool {
        logicalBytes > 0 && (forceChunks || (isRemote && logicalBytes >= thresholdBytes))
    }
}
