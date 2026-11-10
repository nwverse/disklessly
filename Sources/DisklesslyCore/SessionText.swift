import Foundation

/// The plain-text session index: a JSONL file per archived transcript with a
/// header line and one line per user or assistant message, in transcript order.
/// It uses the `SessionDigest` extractors, so tool calls, tool results,
/// reasoning, images, base64 and injected blocks are dropped the same way, but
/// keeps every message instead of a short digest. Nothing here is uploaded.
public enum SessionText {
    /// One message longer than this is cut.
    public static let messageCap = 32 * 1024
    /// The message lines of a whole file (as written, JSON escaping included)
    /// are kept to this many bytes: the head and the tail, with an `omitted`
    /// line between them.
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

    /// Which of `sizes` (the written size of each message line) to keep so
    /// their sum stays under `fileCap`: whole lines from the head (up to half)
    /// and from the tail. Returns the end of the head and the start of the tail;
    /// the lines between them are left out.
    public static func capped(sizes: [Int], fileCap: Int = fileCap) -> (headEnd: Int, tailStart: Int) {
        let total = sizes.reduce(0, +)
        guard total > fileCap else { return (sizes.count, sizes.count) }
        let half = fileCap / 2
        var headEnd = 0
        var used = 0
        while headEnd < sizes.count, used + sizes[headEnd] <= half {
            used += sizes[headEnd]
            headEnd += 1
        }
        var tailStart = sizes.count
        var tailUsed = 0
        while tailStart > headEnd, tailUsed + sizes[tailStart - 1] <= fileCap - used {
            tailUsed += sizes[tailStart - 1]
            tailStart -= 1
        }
        return (headEnd, tailStart)
    }

    /// The header line, keys in a fixed order with `type` first.
    public static func headerLine(_ header: Header) throws -> Data {
        try object([
            ("type", header.type), ("version", header.version), ("entryId", header.entryId), ("deviceId", header.deviceId),
            ("sessionId", header.sessionId), ("tool", header.tool), ("path", header.path), ("cwd", header.cwd),
            ("title", header.title), ("firstPrompt", header.firstPrompt), ("mtime", header.mtime),
            ("archivedAt", header.archivedAt), ("bytes", header.bytes), ("segment", header.segment),
        ])
    }

    /// The whole file: header, then message lines, each ending in a newline.
    /// `fileCap` bounds the written message lines (JSON escaping included), so
    /// the file stays near `fileCap` plus the header. The `omitted` line counts
    /// the message text bytes left out.
    public static func render(header: Header, messages: [SessionDigest.Message], fileCap: Int = fileCap) throws -> Data {
        var out = try headerLine(header)
        let lines = try messages.map { message in
            try object([("type", message.role), ("timestamp", message.timestamp), ("text", message.text)])
        }
        let (headEnd, tailStart) = capped(sizes: lines.map(\.count), fileCap: fileCap)
        for line in lines[..<headEnd] { out.append(line) }
        let omitted = messages[headEnd..<tailStart].reduce(0) { $0 + $1.text.utf8.count }
        if tailStart > headEnd { try out.append(object([("type", "omitted"), ("bytes", omitted)])) }
        for line in lines[tailStart...] { out.append(line) }
        return out
    }

    /// One JSON object with its keys in the given order, and a newline.
    public static func object(_ fields: [(String, Any)]) throws -> Data {
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
