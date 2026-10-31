import Crypto
import Foundation
import IsenoughCore

public struct SessionMemberDraft: Equatable {
    public var entryId: String
    public var path: String
    public var sha256: String
    public var size: Int64
    public var mtimeNs: Int64
    public var ino: Int64
    public var preview: String
    public var bytes: Data
    public var tool: String
    public init(entryId: String, path: String, sha256: String, size: Int64, mtimeNs: Int64, ino: Int64, preview: String, bytes: Data, tool: String) {
        self.entryId = entryId
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.mtimeNs = mtimeNs
        self.ino = ino
        self.preview = preview
        self.bytes = bytes
        self.tool = tool
    }
}

public struct BuiltSegment: Equatable {
    public var relativePath: String
    public var sidecarPath: String
    public var stored: Data
    public var sidecar: Data
    public var sha256: String
    public var codec: String
    public var encryption: String
    public var keyId: String?
    public var members: [SessionMemberDraft]
}

public enum SegmentWriter {
    public static func entryId(deviceId: String, path: String, sha256: String) -> String {
        let raw = SHA256Digest.hex(Data("\(deviceId)\n\(path)\n\(sha256)".utf8))
        return String(raw.prefix(12))
    }

    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    public static func createdAt(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Build one write-once segment. The in-tar index omits `sha256`, `bytes`, and `segment`:
    /// the object name contains the sha8 of the stored bytes, so it cannot also live inside them.
    /// Encrypted AAD is the same relative path with the `-sha8` token removed, for the same reason.
    public static func build(deviceId: String, tool: String, now: Date, members: [SessionMemberDraft], key: SymmetricKey?) throws -> BuiltSegment {
        let created = createdAt(now)
        let stamp = stamp(now)
        let encryption = key == nil ? "none" : "aes-256-gcm"
        let keyId = key.map { SegmentCrypto.keyId(for: $0) }
        var listed: [[String: Any]] = []
        var files: [(name: String, data: Data, mtime: Date)] = []
        for member in members {
            listed.append([
                "member": "m/\(member.entryId).jsonl",
                "id": member.entryId,
                "path": member.path,
                "sha256": member.sha256,
                "size": member.size,
                "mtimeNs": member.mtimeNs,
                "preview": member.preview,
            ])
            let when = Date(timeIntervalSince1970: Double(member.mtimeNs) / 1_000_000_000)
            files.append((name: "m/\(member.entryId).jsonl", data: member.bytes, mtime: when))
        }
        var index: [String: Any] = [
            "schema": "session-segment/1",
            "deviceId": deviceId,
            "tool": tool,
            "createdAt": created,
            "codec": "zstd-3",
            "encryption": encryption,
            "members": listed,
        ]
        if let keyId { index["keyId"] = keyId } else { index["keyId"] = NSNull() }
        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        files.insert((name: "index.json", data: indexData, mtime: now), at: 0)
        let tar = try TarWriter.archive(files)
        let compressed = try Zstd.compress(tar, level: 3)
        let plainName = "sessions/\(deviceId)/\(tool)/\(stamp)"
        let stored: Data
        let suffix: String
        if let key {
            let aad = Data("\(plainName).tar.zst.enc".utf8)
            stored = try SegmentCrypto.seal(plain: compressed, key: key, aad: aad)
            suffix = ".tar.zst.enc"
        } else {
            stored = compressed
            suffix = ".tar.zst"
        }
        let sha = SHA256Digest.hex(stored)
        let sha8 = String(sha.prefix(8))
        let relative = "\(plainName)-\(sha8)\(suffix)"
        var sidecarObject = index
        sidecarObject["segment"] = relative
        sidecarObject["sha256"] = sha
        sidecarObject["bytes"] = stored.count
        var sidecar = try JSONSerialization.data(withJSONObject: sidecarObject, options: [.sortedKeys])
        let sidecarPath: String
        if let key {
            let encPath = "\(plainName)-\(sha8).json.enc"
            sidecar = try SegmentCrypto.seal(plain: sidecar, key: key, aad: Data(encPath.utf8))
            sidecarPath = encPath
        } else {
            sidecarPath = "\(plainName)-\(sha8).json"
        }
        return BuiltSegment(relativePath: relative, sidecarPath: sidecarPath, stored: stored, sidecar: sidecar, sha256: sha, codec: "zstd-3", encryption: encryption, keyId: keyId, members: members)
    }

    public static func plaintext(stored: Data, relativePath: String, keyring: [String: SymmetricKey]) throws -> Data {
        if relativePath.hasSuffix(".enc") {
            let aadPath = aadPath(for: relativePath)
            return try SegmentCrypto.open(envelope: stored, keyring: keyring, aad: Data(aadPath.utf8))
        }
        return stored
    }

    /// `sessions/<id>/<tool>/<stamp>-<sha8>.tar.zst.enc` → `sessions/<id>/<tool>/<stamp>.tar.zst.enc`.
    public static func aadPath(for relativePath: String) -> String {
        let url = URL(fileURLWithPath: relativePath)
        let name = url.lastPathComponent
        let dir = (relativePath as NSString).deletingLastPathComponent
        guard let dash = name.lastIndex(of: "-"), let dot = name[dash...].firstIndex(of: ".") else { return relativePath }
        let stamp = name[..<dash]
        let ext = name[dot...]
        return dir + "/" + stamp + ext
    }
}
