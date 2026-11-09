import Foundation

/// A short, deterministic text digest of an agent transcript. It keeps the user
/// prompts and the last assistant text of each turn, and drops tool calls, tool
/// results, reasoning, images, base64, and injected system text. Nothing leaves
/// the Mac and no model is asked: the same bytes always give the same digest.
///
/// The digest is an extra for search and reading. It never replaces the
/// transcript: the original file is what is archived and restored.
public enum SessionDigest {
    public static let defaultCap = 8 * 1024
    /// One message longer than this is cut before the overall cap is applied, so
    /// a single pasted log cannot fill the whole digest.
    public static let messageCap = 1_500

    public enum Format: String {
        case claude, codex, pi, gemini, generic
    }

    public struct Message: Equatable {
        public var role: String
        public var text: String
        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// Digest body (Markdown) for a transcript, at most `cap` UTF-8 bytes.
    public static func digest(tool: String, path: String, data: Data, cap: Int = defaultCap) -> String {
        let format = detect(tool: tool, path: path, data: data)
        var found = messages(format: format, data: data)
        // A format that drifted, or a tool mapped to the wrong extractor, still
        // gets whatever user/assistant text the generic reader can find.
        if found.isEmpty && format != .generic { found = generic(data) }
        let turns = reduceTurns(found)
        let body = turns.map { message -> String in
            let label = message.role == "user" ? "User" : message.role == "assistant" ? "Assistant" : message.role.capitalized
            return "**\(label):** \(message.text)"
        }.joined(separator: "\n\n")
        return capped(body, maxBytes: cap)
    }

    public static let titleCap = 80

    /// A one-line title for a transcript, so an archived session can be found and restored by
    /// topic: the agent's own title when it wrote one (Claude Code `custom-title`/`ai-title`/
    /// `summary` records, Codex `session_index.jsonl` thread names), else the first user prompt.
    public static func title(tool: String, path: String, data: Data, home: String = NSHomeDirectory()) -> String {
        if let native = nativeTitle(tool: tool, path: path, data: data, home: home) { return oneLine(native) }
        let format = detect(tool: tool, path: path, data: data)
        var found = messages(format: format, data: data)
        if found.isEmpty && format != .generic { found = generic(data) }
        return oneLine(stripLeadingTags(found.first { $0.role == "user" }?.text ?? ""))
    }

    /// The working directory a session ran in, from the first record that names one
    /// (Claude Code `cwd`, Codex `session_meta.payload.cwd`, pi's header `cwd`).
    public static func workingDirectory(_ data: Data) -> String? {
        var found: String?
        var seen = 0
        let bytes = data
        var start = bytes.startIndex
        while found == nil, seen < 64, start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            seen += 1
            if end > start, let object = (try? JSONSerialization.jsonObject(with: bytes[start..<end])) as? [String: Any] {
                let payload = object["payload"] as? [String: Any]
                if let cwd = (object["cwd"] as? String) ?? (payload?["cwd"] as? String), !cwd.isEmpty { found = cwd }
            }
            start = end < bytes.endIndex ? bytes.index(after: end) : end
        }
        return found
    }

    /// Drops wrapper blocks some agents put before the prompt, e.g. Cursor's
    /// `<timestamp>…</timestamp>`, so the title starts at what the user typed.
    static func stripLeadingTags(_ text: String) -> String {
        var rest = Substring(text).drop { $0.isWhitespace }
        while rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            let name = rest[rest.index(after: rest.startIndex)..<close]
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                  let end = rest.range(of: "</\(name)>") else { break }
            let after = rest[end.upperBound...].drop { $0.isWhitespace }
            // A block that is the whole prompt (Cursor's `<user_query>`) is unwrapped instead.
            rest = after.isEmpty ? rest[rest.index(after: close)..<end.lowerBound].drop { $0.isWhitespace } : after
        }
        return String(rest)
    }

    /// The first user prompt in a digest made by `digest(tool:path:data:)`, for index rows
    /// archived before titles were recorded.
    public static func title(fromDigest digest: String) -> String {
        guard let range = digest.range(of: "**User:** ") else { return "" }
        let rest = digest[range.upperBound...]
        let end = rest.range(of: "\n\n**")?.lowerBound ?? rest.endIndex
        return oneLine(String(rest[..<end]))
    }

    static func nativeTitle(tool: String, path: String, data: Data, home: String) -> String? {
        var title: String?
        if detect(tool: tool, path: path, data: data) == .claude {
            // The last title record wins: a rename replaces the generated one.
            forEachLine(data) { object in
                switch object["type"] as? String {
                case "custom-title": if let text = object["customTitle"] as? String, !text.isEmpty { title = text }
                case "ai-title": if let text = object["aiTitle"] as? String, !text.isEmpty { title = text }
                case "summary": if let text = object["summary"] as? String, !text.isEmpty { title = text }
                default: break
                }
            }
        }
        if title == nil, tool == "codex" || path.contains("/.codex/") {
            title = codexThreadName(path: path, home: home)
        }
        return title
    }

    /// Codex keeps thread names in `~/.codex/session_index.jsonl`, keyed by the UUID at the
    /// end of the rollout file name.
    static func codexThreadName(path: String, home: String) -> String? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.count >= 36 else { return nil }
        let id = String(stem.suffix(36)).lowercased()
        guard UUID(uuidString: id) != nil,
              let index = FileManager.default.contents(atPath: (home as NSString).appendingPathComponent(".codex/session_index.jsonl")) else { return nil }
        var name: String?
        forEachLine(index) { object in
            if (object["id"] as? String)?.lowercased() == id, let text = object["thread_name"] as? String, !text.isEmpty { name = text }
        }
        return name
    }

    /// First non-empty line, whitespace collapsed, at most `titleCap` characters.
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        return line.count > titleCap ? String(line.prefix(titleCap - 1)) + "…" : line
    }

    /// The readable `<id>.md` file written next to the index.
    public static func markdown(id: String, tool: String, path: String, sha256: String, modified: Date, digest: String) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [
            "# \(SessionRoot.label(tool: tool)) session \(id)",
            "",
            "- Tool: `\(tool)`",
            "- Path: `\(path)`",
            "- Modified: \(iso.string(from: modified))",
            "- SHA-256: `\(sha256)`",
            "",
            "Digest only. The full transcript is archived and comes back with `disklessly sessions restore \(id)`.",
            "",
            "---",
            "",
        ]
        lines.append(digest.isEmpty ? "_No user or assistant text found._" : digest)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: format

    public static func detect(tool: String, path: String, data: Data) -> Format {
        switch tool {
        case "claude", "claude-desktop": return .claude
        case "codex": return .codex
        case "pi", "omp", "prime", "factory": return .pi
        case "gemini": return .gemini
        default: break
        }
        if path.hasSuffix(".json"), let object = try? JSONSerialization.jsonObject(with: data), (object as? [String: Any])?["messages"] is [Any] {
            return .gemini
        }
        // Only the head is sniffed, so a large transcript is not parsed twice.
        var sniffed: [[String: Any]] = []
        forEachLine(data.prefix(64 * 1024)) { object in
            if sniffed.count < 40 { sniffed.append(object) }
        }
        for object in sniffed {
            if object["payload"] is [String: Any], let type = object["type"] as? String, ["response_item", "event_msg", "session_meta", "turn_context"].contains(type) {
                return .codex
            }
            if let type = object["type"] as? String, let message = object["message"] as? [String: Any] {
                if type == "message", message["role"] != nil { return .pi }
                if type == "user" || type == "assistant" { return .claude }
            }
        }
        return .generic
    }

    public static func messages(format: Format, data: Data) -> [Message] {
        switch format {
        case .claude: return claude(data)
        case .codex: return codex(data)
        case .pi: return pi(data)
        case .gemini: return gemini(data)
        case .generic: return generic(data)
        }
    }

    // MARK: extractors

    /// Claude Code JSONL: `{type: user|assistant, message: {role, content}}`.
    /// User records holding only `tool_result` blocks are not prompts.
    static func claude(_ data: Data) -> [Message] {
        var out: [Message] = []
        forEachLine(data) { object in
            guard let type = object["type"] as? String, type == "user" || type == "assistant" else { return }
            if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return }
            guard let message = object["message"] as? [String: Any] else { return }
            let role = (message["role"] as? String) ?? type
            guard role == "user" || role == "assistant" else { return }
            if let text = clean(texts(message["content"], blockTypes: ["text"])) {
                out.append(Message(role: role, text: text))
            }
        }
        return out
    }

    /// Codex rollout JSONL: `response_item` messages with `input_text`/`output_text`
    /// blocks. Older rollouts write the message object on the line itself. When a
    /// file has no message items, `event_msg` user and agent messages are used.
    static func codex(_ data: Data) -> [Message] {
        var items: [Message] = []
        var events: [Message] = []
        forEachLine(data) { object in
            let payload = (object["payload"] as? [String: Any]) ?? object
            let payloadType = payload["type"] as? String
            if payloadType == "message", let role = payload["role"] as? String, role == "user" || role == "assistant" {
                if let text = clean(texts(payload["content"], blockTypes: ["input_text", "output_text", "text"])) {
                    items.append(Message(role: role, text: text))
                }
            } else if object["type"] as? String == "event_msg" {
                if payloadType == "user_message", let text = clean(payload["message"] as? String) {
                    events.append(Message(role: "user", text: text))
                } else if payloadType == "agent_message", let text = clean(payload["message"] as? String) {
                    events.append(Message(role: "assistant", text: text))
                }
            }
        }
        return items.isEmpty ? events : items
    }

    /// pi / omp JSONL: `{type: message, message: {role, content}}`. System,
    /// `toolResult`, `toolCall`, and `thinking` content is dropped.
    static func pi(_ data: Data) -> [Message] {
        var out: [Message] = []
        forEachLine(data) { object in
            guard object["type"] as? String == "message", let message = object["message"] as? [String: Any] else { return }
            guard let role = message["role"] as? String, role == "user" || role == "assistant" else { return }
            if let text = clean(texts(message["content"], blockTypes: ["text"])) {
                out.append(Message(role: role, text: text))
            }
        }
        return out
    }

    /// Gemini CLI (and Qwen legacy) JSON: `{messages: [{type: user|gemini, content}]}`.
    /// A JSONL file of the same records is read line by line.
    static func gemini(_ data: Data) -> [Message] {
        var out: [Message] = []
        func take(_ record: [String: Any]) {
            let kind = ((record["type"] as? String) ?? (record["role"] as? String) ?? "").lowercased()
            let role: String
            switch kind {
            case "user": role = "user"
            case "gemini", "model", "assistant", "qwen": role = "assistant"
            default: return
            }
            let content = record["content"] ?? record["parts"]
            if let text = clean(texts(content, blockTypes: ["text"])) {
                out.append(Message(role: role, text: text))
            }
        }
        if let object = wholeJSON(data) {
            if let dict = object as? [String: Any], let list = dict["messages"] as? [[String: Any]] {
                list.forEach(take)
            } else if let list = object as? [[String: Any]] {
                list.forEach(take)
            }
        } else {
            forEachLine(data, take)
        }
        return out
    }

    /// Any other JSON or JSONL: strings under `text`/`content`, with a role taken
    /// from `role`, `message.role`, or `type` when it says user or assistant.
    static func generic(_ data: Data) -> [Message] {
        var out: [Message] = []
        func take(_ record: [String: Any]) {
            if skippable(record) { return }
            let message = record["message"] as? [String: Any]
            let rawRole = ((record["role"] as? String) ?? (message?["role"] as? String) ?? (record["type"] as? String) ?? "").lowercased()
            let role: String
            if ["user", "human", "prompt", "user_message", "user.message"].contains(rawRole) { role = "user" }
            else if ["assistant", "model", "ai", "agent", "bot", "gemini", "agent_message", "assistant.message"].contains(rawRole) { role = "assistant" }
            else if rawRole.isEmpty { role = "text" }
            else { return }
            var collected: [String] = []
            walk(record, into: &collected)
            if let text = clean(collected.joined(separator: "\n")) {
                out.append(Message(role: role, text: text))
            }
        }
        if let object = wholeJSON(data) {
            if let dict = object as? [String: Any] {
                let list = ["messages", "history", "conversation", "items", "events"].lazy.compactMap { dict[$0] as? [[String: Any]] }.first
                (list ?? [dict]).forEach(take)
            } else if let list = object as? [[String: Any]] {
                list.forEach(take)
            }
        } else {
            forEachLine(data, take)
        }
        return out
    }

    // MARK: turns and cap

    /// Every user prompt, and only the last assistant text before the next prompt.
    public static func reduceTurns(_ messages: [Message]) -> [Message] {
        var out: [Message] = []
        var pendingAssistant: Message?
        for message in messages {
            if message.role == "assistant" {
                pendingAssistant = message
                continue
            }
            if let assistant = pendingAssistant {
                out.append(assistant)
                pendingAssistant = nil
            }
            if let last = out.last, last == message { continue }
            out.append(message)
        }
        if let assistant = pendingAssistant { out.append(assistant) }
        return out
    }

    /// `text` cut to `maxBytes` UTF-8 bytes: the head, a marker with the number
    /// of bytes left out, and the tail. Cuts land on Unicode scalar boundaries.
    public static func capped(_ text: String, maxBytes: Int) -> String {
        let total = text.utf8.count
        guard total > maxBytes else { return text }
        guard maxBytes > 64 else { return prefix(text, bytes: max(0, maxBytes)) }
        let markerBudget = 48
        let room = maxBytes - markerBudget
        let headBytes = room * 3 / 5
        let tailBytes = room - headBytes
        let head = prefix(text, bytes: headBytes)
        let tail = suffix(text, bytes: tailBytes)
        let omitted = total - head.utf8.count - tail.utf8.count
        return head + "\n\n… [\(omitted) bytes omitted] …\n\n" + tail
    }

    static func prefix(_ text: String, bytes: Int) -> String {
        let utf8 = text.utf8
        guard bytes < utf8.count else { return text }
        var index = utf8.index(utf8.startIndex, offsetBy: bytes)
        while index > utf8.startIndex, index.samePosition(in: text.unicodeScalars) == nil {
            index = utf8.index(before: index)
        }
        return String(text.unicodeScalars[text.unicodeScalars.startIndex..<index])
    }

    static func suffix(_ text: String, bytes: Int) -> String {
        let utf8 = text.utf8
        guard bytes < utf8.count else { return text }
        var index = utf8.index(utf8.endIndex, offsetBy: -bytes)
        while index < utf8.endIndex, index.samePosition(in: text.unicodeScalars) == nil {
            index = utf8.index(after: index)
        }
        return String(text.unicodeScalars[index..<text.unicodeScalars.endIndex])
    }

    // MARK: helpers

    /// Calls `body` with each JSONL line that is an object, one at a time, so a
    /// large transcript is never held as parsed objects all at once.
    static func forEachLine(_ data: Data, _ body: ([String: Any]) -> Void) {
        let bytes = data
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            if end > start {
                autoreleasepoolIfAvailable {
                    if let object = (try? JSONSerialization.jsonObject(with: bytes[start..<end])) as? [String: Any] {
                        body(object)
                    }
                }
            }
            start = end < bytes.endIndex ? bytes.index(after: end) : end
        }
    }

    /// A whole-file JSON document, or nil for JSONL. A file starting with `{`
    /// whose first line is a complete object is JSONL and is not parsed whole.
    static func wholeJSON(_ data: Data) -> Any? {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) else { return nil }
        if first == UInt8(ascii: "{"), let newline = data.firstIndex(of: 0x0A), newline < data.endIndex - 1,
           (try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline])) != nil {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func autoreleasepoolIfAvailable(_ body: () -> Void) {
        #if canImport(ObjectiveC)
        autoreleasepool { body() }
        #else
        body()
        #endif
    }

    /// Text of a `content` value: a string, or the blocks whose `type` is in
    /// `blockTypes` (a block without a type counts when it has `text`).
    static func texts(_ content: Any?, blockTypes: Set<String>) -> String? {
        if let string = content as? String { return string }
        guard let blocks = content as? [Any] else { return nil }
        var parts: [String] = []
        for block in blocks {
            if let string = block as? String { parts.append(string); continue }
            guard let dict = block as? [String: Any] else { continue }
            if let type = dict["type"] as? String, !blockTypes.contains(type) { continue }
            if let text = dict["text"] as? String { parts.append(text) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static let skippedTypeWords = ["tool", "image", "thinking", "reasoning", "function", "file", "attachment"]

    private static func skippable(_ dict: [String: Any]) -> Bool {
        guard let type = (dict["type"] as? String)?.lowercased() else { return false }
        return skippedTypeWords.contains { type.contains($0) }
    }

    private static func walk(_ value: Any, into out: inout [String]) {
        if let dict = value as? [String: Any] {
            if skippable(dict) { return }
            for key in dict.keys.sorted() {
                guard let child = dict[key] else { continue }
                if (key == "text" || key == "content"), let string = child as? String {
                    out.append(string)
                } else if child is [String: Any] || child is [Any] {
                    if key.lowercased().contains("tool") || key == "metadata" || key == "usage" { continue }
                    walk(child, into: &out)
                }
            }
        } else if let list = value as? [Any] {
            for item in list { walk(item, into: &out) }
        }
    }

    /// Prefixes of text the agent injects into the user turn (environment, slash
    /// command echoes, instructions). Such a message is dropped.
    private static let noisePrefixes = [
        "<environment_context>", "<user_instructions>", "<permissions instructions>", "<command-name>", "<command-message>",
        "<command-args>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>", "<user-prompt-submit-hook>",
        "# AGENTS.md instructions", "<INSTRUCTIONS>", "<system-reminder>", "<task-notification>", "Caveat: The messages below",
        "[Request interrupted by user", "<turn_aborted>",
    ]

    private static let blockPatterns: [NSRegularExpression] = [
        "<system-reminder>[\\s\\S]*?</system-reminder>",
        "<environment_context>[\\s\\S]*?</environment_context>",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let wholeTagPattern = try? NSRegularExpression(pattern: "^<([A-Za-z][A-Za-z0-9_-]*)(\\s[^>]*)?>[\\s\\S]*</\\1>$")

    private static let base64Patterns: [(NSRegularExpression, String)] = [
        ("data:[A-Za-z0-9.+/-]+;base64,[A-Za-z0-9+/=]+", "[binary]"),
        ("[A-Za-z0-9+/=]{200,}", "[base64]"),
    ].compactMap { pattern, replacement in (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) } }

    /// Strips injected blocks and base64, trims, cuts to `messageCap`. Nil when
    /// nothing readable is left or the message is agent noise.
    static func clean(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        for pattern in blockPatterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        for (pattern, replacement) in base64Patterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if noisePrefixes.contains(where: { text.hasPrefix($0) }) { return nil }
        // A message that is one injected `<tag>…</tag>` block and nothing else.
        if let wrapped = wholeTagPattern, wrapped.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return nil }
        if text.utf8.count > messageCap {
            text = prefix(text, bytes: messageCap) + " …"
        }
        return text
    }
}
