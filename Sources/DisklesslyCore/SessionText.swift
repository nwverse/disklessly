import Foundation

/// The plain-text session index: a JSONL file per archived transcript with a
/// header line and one line per user or assistant message, in transcript order.
/// It uses the `SessionDigest` extractors, so tool calls, tool results,
/// reasoning, images, base64 and injected blocks are dropped the same way, but
/// keeps every message instead of a short digest. Nothing here is uploaded.
public enum SessionText {
    /// One message longer than this is cut.
    public static let messageCap = 32 * 1024
    /// The message text of a whole file is kept to this many bytes: the head and
    /// the tail, with an `omitted` line between them.
    public static let fileCap = 1024 * 1024
    public static let headerType = "disklessly-archive"
    public static let version = 1

    public struct Header: Codable, Equatable {
        public var type: String = SessionText.headerType
        public var version: Int = SessionText.version
        public var entryId: String
        public var deviceId: String
        public var sessionId: String
        public var tool: String
        public var path: String
        public var cwd: String
        public var title: String
        public var firstPrompt: String
        public var mtime: String
        public var archivedAt: String
        public var bytes: Int64
        public var segment: String

        public init(entryId: String, deviceId: String, sessionId: String, tool: String, path: String, cwd: String, title: String, firstPrompt: String, mtime: String, archivedAt: String, bytes: Int64, segment: String) {
            self.entryId = entryId
            self.deviceId = deviceId
            self.sessionId = sessionId
            self.tool = tool
            self.path = path
            self.cwd = cwd
            self.title = title
            self.firstPrompt = firstPrompt
            self.mtime = mtime
            self.archivedAt = archivedAt
            self.bytes = bytes
            self.segment = segment
        }
    }

    /// User and assistant messages of a transcript, each cut at `messageCap`.
    public static func messages(tool: String, path: String, data: Data, messageCap: Int = messageCap) -> [SessionDigest.Message] {
        let format = SessionDigest.detect(tool: tool, path: path, data: data)
        var found = SessionDigest.messages(format: format, data: data, cap: messageCap)
        if found.isEmpty && format != .generic { found = SessionDigest.generic(data, cap: messageCap) }
        return found.filter { $0.role == "user" || $0.role == "assistant" }
    }

    /// Messages kept under `fileCap` bytes of text: whole messages from the head
    /// and from the tail, and the number of text bytes left out between them.
    public static func capped(_ messages: [SessionDigest.Message], fileCap: Int = fileCap) -> (head: [SessionDigest.Message], omitted: Int, tail: [SessionDigest.Message]) {
        let sizes = messages.map { $0.text.utf8.count }
        let total = sizes.reduce(0, +)
        guard total > fileCap else { return (messages, 0, []) }
        let half = fileCap / 2
        var headEnd = 0
        var used = 0
        while headEnd < messages.count, used + sizes[headEnd] <= half {
            used += sizes[headEnd]
            headEnd += 1
        }
        var tailStart = messages.count
        var tailUsed = 0
        while tailStart > headEnd, tailUsed + sizes[tailStart - 1] <= fileCap - used {
            tailUsed += sizes[tailStart - 1]
            tailStart -= 1
        }
        let omitted = sizes[headEnd..<tailStart].reduce(0, +)
        return (Array(messages[..<headEnd]), omitted, Array(messages[tailStart...]))
    }

    /// The whole file: header, then message lines, each ending in a newline.
    /// Keys are written in a fixed order, `type` first.
    public static func render(header: Header, messages: [SessionDigest.Message], fileCap: Int = fileCap) throws -> Data {
        var out = Data()
        try out.append(object([
            ("type", header.type), ("version", header.version), ("entryId", header.entryId), ("deviceId", header.deviceId),
            ("sessionId", header.sessionId), ("tool", header.tool), ("path", header.path), ("cwd", header.cwd),
            ("title", header.title), ("firstPrompt", header.firstPrompt), ("mtime", header.mtime),
            ("archivedAt", header.archivedAt), ("bytes", header.bytes), ("segment", header.segment),
        ]))
        func line(_ message: SessionDigest.Message) throws -> Data {
            try object([("type", message.role), ("timestamp", message.timestamp), ("text", message.text)])
        }
        let (head, omitted, tail) = capped(messages, fileCap: fileCap)
        for message in head { try out.append(line(message)) }
        if omitted > 0 { try out.append(object([("type", "omitted"), ("bytes", omitted)])) }
        for message in tail { try out.append(line(message)) }
        return out
    }

    /// One JSON object with its keys in the given order, and a newline.
    static func object(_ fields: [(String, Any)]) throws -> Data {
        var out = Data("{".utf8)
        for (index, field) in fields.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(try fragment(field.0))
            out.append(UInt8(ascii: ":"))
            out.append(try fragment(field.1))
        }
        out.append(contentsOf: Array("}\n".utf8))
        return out
    }

    private static func fragment(_ value: Any) throws -> Data {
        switch value {
        case let number as Int: return Data(String(number).utf8)
        case let number as Int64: return Data(String(number).utf8)
        default: return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        }
    }
}
