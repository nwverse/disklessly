import Foundation

/// Names derived from a transcript path and its working directory: the agent's
/// session id, and the project/month partition a segment is filed under.
public enum SessionIdentity {
    /// Claude Code: the file stem. Codex: the UUID at the end of
    /// `rollout-<time>-<uuid>.jsonl`. Any other agent: the file stem.
    public static func sessionId(tool: String, path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if tool == "codex", let id = trailingUUID(stem) { return id }
        return stem
    }

    /// The UUID that ends `stem`, lowercased, or nil.
    public static func trailingUUID(_ stem: String) -> String? {
        guard stem.count >= 36 else { return nil }
        let tail = String(stem.suffix(36))
        guard UUID(uuidString: tail) != nil else { return nil }
        return tail.lowercased()
    }

    public static let unknownProject = "_unknown"
    public static let projectSlugMax = 48

    /// Partition key for a working directory. A Claude-style slug (every character
    /// outside `[A-Za-z0-9]` becomes `-`, leading dashes trimmed), at most 48
    /// characters plus `-<sha8>` when it was cut. Encrypted segments use
    /// `p-<sha12>` so object names carry no plaintext path. Unknown: `_unknown`.
    public static func projectKey(cwd: String?, encrypted: Bool) -> String {
        guard let cwd, !cwd.isEmpty else { return unknownProject }
        let digest = SHA256Digest.hex(Data(cwd.utf8))
        if encrypted { return "p-" + digest.prefix(12) }
        var slug = ""
        for scalar in cwd.unicodeScalars {
            let ascii = scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar))
            slug.unicodeScalars.append(ascii ? scalar : "-")
        }
        slug = String(slug.drop { $0 == "-" })
        if slug.isEmpty { return "p-" + digest.prefix(12) }
        if slug.count > projectSlugMax {
            slug = String(slug.prefix(projectSlugMax)) + "-" + digest.prefix(8)
        }
        return slug
    }

    /// `yyyy-MM` of `date` in UTC.
    public static func month(_ date: Date) -> String { SessionTiering.monthKey(date) }

    public static func month(mtimeNs: Int64) -> String {
        month(Date(timeIntervalSince1970: Double(mtimeNs) / 1_000_000_000))
    }
}

/// Sessions an outside tool still references (`sessions --exclude-from`). Each
/// line is an absolute transcript path or a session id; `#` comments and blank
/// lines are ignored. A match is never uploaded or deleted.
public struct SessionExclusions: Equatable {
    public var paths: Set<String>
    public var ids: Set<String>

    public init(paths: Set<String> = [], ids: Set<String> = []) {
        self.paths = paths
        self.ids = ids
    }

    public var isEmpty: Bool { paths.isEmpty && ids.isEmpty }

    public static func parse(_ text: String) -> SessionExclusions {
        var result = SessionExclusions()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("/") {
                result.paths.insert(line)
                result.paths.insert(SessionPaths.canonical(line))
            } else {
                result.ids.insert(line.lowercased())
            }
        }
        return result
    }

    /// A file matches its own path or session id, and so does every file in a
    /// folder named for an excluded session (Claude Code keeps a session's
    /// subagent transcripts in `<sessionId>/subagents/`, next to `<sessionId>.jsonl`).
    public func matches(tool: String, path: String) -> Bool {
        if isEmpty { return false }
        let canonical = SessionPaths.canonical(path)
        if paths.contains(path) || paths.contains(canonical) { return true }
        for excluded in paths where excluded.hasSuffix(".jsonl") {
            let folder = String(excluded.dropLast(".jsonl".count)) + "/"
            if path.hasPrefix(folder) || canonical.hasPrefix(folder) { return true }
        }
        guard !ids.isEmpty else { return false }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if ids.contains(SessionIdentity.sessionId(tool: tool, path: path).lowercased()) || ids.contains(stem) { return true }
        let folders = (canonical as NSString).pathComponents.dropLast().map { $0.lowercased() }
        return folders.contains { ids.contains($0) }
    }
}

extension SessionDigest {
    public static let firstPromptCap = 500

    /// The first prompt the user typed, at most 500 characters. Text agents inject
    /// as a user message (environment context, instruction files) is skipped.
    public static func firstPrompt(tool: String, path: String, data: Data) -> String {
        let format = detect(tool: tool, path: path, data: data)
        var found = messages(format: format, data: data)
        if found.isEmpty && format != .generic { found = generic(data) }
        for message in found where message.role == "user" {
            let raw = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if injected(raw) { continue }
            let text = stripLeadingTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            return text.count > firstPromptCap ? String(text.prefix(firstPromptCap)) : text
        }
        return ""
    }

    static func injected(_ text: String) -> Bool {
        let markers = ["<environment_context", "<user_instructions", "<permissions instructions", "# AGENTS.md instructions", "<INSTRUCTIONS>", "<system-reminder", "Caveat: The messages below"]
        return markers.contains { text.hasPrefix($0) }
    }
}
