import Foundation

public struct SessionRoot: Codable, Equatable {
    public var tool: String
    public var directory: String
    public var suffix: String
    public init(tool: String, directory: String, suffix: String = ".jsonl") {
        self.tool = tool
        self.directory = directory
        self.suffix = suffix
    }

    public static func defaults(home: String) -> [SessionRoot] {
        [
            SessionRoot(tool: "pi", directory: "\(home)/.pi/agent/sessions"),
            SessionRoot(tool: "claude", directory: "\(home)/.claude/projects"),
            SessionRoot(tool: "codex", directory: "\(home)/.codex/sessions"),
        ]
    }
}

public struct SessionCandidate: Equatable {
    public var path: String
    public var tool: String
    public var size: UInt64
    public var modified: Date
    public var open: Bool
    public var preview: String
    public init(path: String, tool: String, size: UInt64, modified: Date, open: Bool, preview: String) {
        self.path = path
        self.tool = tool
        self.size = size
        self.modified = modified
        self.open = open
        self.preview = preview
    }
}

public struct SessionDecision: Equatable {
    public var candidate: SessionCandidate
    public var cold: Bool
    public var reason: String
    public init(candidate: SessionCandidate, cold: Bool, reason: String) {
        self.candidate = candidate
        self.cold = cold
        self.reason = reason
    }
}

public enum OpenFileProbe {
    /// `lsof -Fn` prints a machine record `n` + path. That line is the classifier.
    /// Exit status other than 0 means the file is not open. The sentence lsof prints
    /// on failure is ignored.
    public static func isOpen(lsofStatus: Int32, lsofStdout: String, path: String) -> Bool {
        guard lsofStatus == 0 else { return false }
        return lsofStdout.split(separator: "\n", omittingEmptySubsequences: false).contains { $0 == "n\(path)" }
    }
}

public enum SessionTiering {
    public static let protectSeconds: TimeInterval = 24 * 60 * 60

    public static func forbidden(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if !name.hasSuffix(".jsonl") { return true }
        let blocked = [".credentials.json", "auth.json", "config.toml", ".claude.json"]
        if blocked.contains(name) { return true }
        let lower = path.lowercased()
        if lower.contains(".sqlite") || lower.hasSuffix(".db") || lower.contains("state.vscdb") || lower.hasSuffix("-wal") || lower.hasSuffix("-shm") {
            return true
        }
        return false
    }

    /// Cold when the file is a session JSONL, closed, unmodified for 24 hours, and
    /// unmodified for `coldDays` (default 14). An open file or a secret path is never cold.
    public static func decide(_ candidate: SessionCandidate, now: Date, coldDays: Int) -> SessionDecision {
        if forbidden(candidate.path) {
            return SessionDecision(candidate: candidate, cold: false, reason: "not a session jsonl")
        }
        if candidate.open {
            return SessionDecision(candidate: candidate, cold: false, reason: "open")
        }
        let age = now.timeIntervalSince(candidate.modified)
        if age < protectSeconds {
            return SessionDecision(candidate: candidate, cold: false, reason: "modified within 24h")
        }
        if age < TimeInterval(coldDays) * 24 * 60 * 60 {
            return SessionDecision(candidate: candidate, cold: false, reason: "newer than \(coldDays) days")
        }
        return SessionDecision(candidate: candidate, cold: true, reason: "cold")
    }

    public static func monthKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    public static func archivePath(tool: String, month: String) -> String {
        "sessions/\(tool)/\(month).tar.gz"
    }

    public static func preview(of data: Data) -> String {
        let text = String(decoding: data.prefix(400), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 160 { return text }
        return String(text.prefix(160))
    }
}

public struct SessionIndexEntry: Codable, Equatable {
    public var id: String
    public var tool: String
    public var path: String
    public var sha256: String
    public var size: UInt64
    public var modified: Date
    public var archive: String
    public var member: String
    public var preview: String
    public init(id: String, tool: String, path: String, sha256: String, size: UInt64, modified: Date, archive: String, member: String, preview: String) {
        self.id = id
        self.tool = tool
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.modified = modified
        self.archive = archive
        self.member = member
        self.preview = preview
    }
}

public struct SessionIndex: Codable, Equatable {
    public var schema: String
    public var entries: [SessionIndexEntry]
    public init(entries: [SessionIndexEntry] = []) {
        self.schema = "sessions-index/1"
        self.entries = entries
    }

    public func search(_ query: String) -> [SessionIndexEntry] {
        let needle = query.lowercased()
        return entries.filter {
            $0.id.lowercased().contains(needle) || $0.path.lowercased().contains(needle) || $0.preview.lowercased().contains(needle) || $0.tool.lowercased().contains(needle)
        }
    }
}
