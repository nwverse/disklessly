import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct SessionRoot: Codable, Equatable {
    public var tool: String
    public var directory: String
    /// Primary file suffix. Kept for configs written before `suffixes` existed.
    public var suffix: String
    /// Extra suffixes, e.g. `[".jsonl", ".json"]`. Nil means `[suffix]`.
    public var suffixes: [String]?
    /// A directory name that must appear between `directory` and the file, e.g.
    /// `chats` for `~/.gemini/tmp/<hash>/chats/session-*.json`. Nil accepts any depth.
    public var requireComponent: String?
    public init(tool: String, directory: String, suffix: String = ".jsonl", suffixes: [String]? = nil, requireComponent: String? = nil) {
        self.tool = tool
        self.directory = directory
        self.suffix = suffix
        self.suffixes = suffixes
        self.requireComponent = requireComponent
    }

    /// Every suffix this root accepts.
    public var allSuffixes: [String] {
        var out = [suffix]
        for extra in suffixes ?? [] where !out.contains(extra) { out.append(extra) }
        return out
    }

    /// Whether `path` (canonical, inside `canonicalDirectory`) is a transcript of this root.
    public func accepts(_ path: String, canonicalDirectory: String) -> Bool {
        guard allSuffixes.contains(where: { path.hasSuffix($0) }) else { return false }
        guard let component = requireComponent, !component.isEmpty else { return true }
        let relative = path.hasPrefix(canonicalDirectory + "/") ? String(path.dropFirst(canonicalDirectory.count + 1)) : path
        let parts = relative.split(separator: "/").dropLast()
        return parts.contains { $0 == component }
    }

    /// Built-in roots for the coding agents Disklessly knows. Only append-only,
    /// file-per-session transcripts are listed. Agents that keep sessions only in
    /// SQLite (Crush, Hermes, Devin, Shelley, Goose 1.20+, OpenCode 1.2+), one file
    /// per message (OpenCode `storage/`), or mutable state JSON (Claude desktop's
    /// `claude-code-sessions` and `local-agent-mode-sessions`) are not tiered.
    public static func defaults(home: String, platform: HostPlatform = .current) -> [SessionRoot] {
        var roots: [SessionRoot] = [
            SessionRoot(tool: "pi", directory: "\(home)/.pi/agent/sessions"),
            SessionRoot(tool: "claude", directory: "\(home)/.claude/projects"),
            SessionRoot(tool: "codex", directory: "\(home)/.codex/sessions"),
            SessionRoot(tool: "codex", directory: "\(home)/.codex/archived_sessions"),
            SessionRoot(tool: "omp", directory: "\(home)/.omp/agent/sessions"),
            SessionRoot(tool: "gemini", directory: "\(home)/.gemini/tmp", suffix: ".json", suffixes: [".jsonl"], requireComponent: "chats"),
            SessionRoot(tool: "factory", directory: "\(home)/.factory/sessions"),
            SessionRoot(tool: "qwen", directory: "\(home)/.qwen/projects"),
            SessionRoot(tool: "qwen", directory: "\(home)/.qwen/tmp", suffix: ".json", requireComponent: "chats"),
            SessionRoot(tool: "kimi", directory: "\(home)/.kimi/sessions"),
            SessionRoot(tool: "kimi", directory: "\(home)/.kimi-code/sessions"),
            SessionRoot(tool: "copilot", directory: "\(home)/.copilot/session-state"),
            SessionRoot(tool: "goose", directory: "\(home)/.local/share/goose/sessions"),
            SessionRoot(tool: "goose", directory: "\(home)/.goose/sessions"),
            SessionRoot(tool: "grok", directory: "\(home)/.grok/sessions"),
            SessionRoot(tool: "vibe", directory: "\(home)/.vibe/logs/session"),
            SessionRoot(tool: "kiro", directory: "\(home)/.kiro/sessions/cli"),
            SessionRoot(tool: "openclaw", directory: "\(home)/.openclaw/agents", requireComponent: "sessions"),
            SessionRoot(tool: "prime", directory: "\(home)/.prime/agent/sessions"),
            SessionRoot(tool: "cursor", directory: "\(home)/.cursor/projects", requireComponent: "agent-transcripts"),
        ]
        if platform == .linux {
            // Claude Code honours XDG_CONFIG_HOME; its default spelling is listed too.
            roots.append(SessionRoot(tool: "claude", directory: "\(home)/.config/claude-code/projects"))
        }
        return roots
    }

    /// Human label for a tool id. Unknown ids are returned as they are.
    public static func label(tool: String) -> String {
        let labels = [
            "pi": "pi", "claude": "Claude Code", "codex": "Codex", "omp": "Oh My Pi", "gemini": "Gemini CLI",
            "factory": "Factory Droid", "qwen": "Qwen Code", "kimi": "Kimi Code", "copilot": "Copilot CLI",
            "goose": "Goose", "grok": "Grok", "vibe": "Mistral Vibe", "kiro": "Kiro CLI", "openclaw": "OpenClaw",
            "prime": "Prime", "cursor": "Cursor agent",
        ]
        return labels[tool] ?? tool
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

public enum SessionPaths {
    /// Realpath of `path`, including a missing leaf's existing ancestor.
    /// On macOS `/var`, `/tmp`, and `/etc` are symlinks, so the stored spelling is
    /// `/private/var`, `/private/tmp`, or `/private/etc`. The result is not passed
    /// back through `URL.path`, which strips that `/private` prefix.
    public static func canonical(_ path: String) -> String {
        let absolute = absoluteForm(path)
        if let existing = posixRealpath(absolute) {
            return privateSystemPrefix(existing)
        }
        let parts = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var resolved = "/"
        for part in parts {
            if part == "." { continue }
            if part == ".." {
                resolved = parentPath(resolved)
                continue
            }
            let next = join(resolved, part)
            if let existing = posixRealpath(next) {
                resolved = existing
            } else {
                resolved = next
            }
        }
        return privateSystemPrefix(resolved)
    }

    /// `$HOME` when the variable is set. `NSHomeDirectory()` is the passwd home and is
    /// used only when HOME is missing or empty. On macOS `NSHomeDirectory()` ignores `$HOME`.
    public static func homeDirectory(environment: [String: String]) -> String {
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return canonical(home)
        }
        return canonical(NSHomeDirectory())
    }

    public static func contains(_ root: String, path: String) -> Bool {
        let base = canonical(root)
        let file = canonical(path)
        return file == base || file.hasPrefix(base + "/")
    }

    private static func absoluteForm(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        let cwd = FileManager.default.currentDirectoryPath
        if path.isEmpty { return cwd }
        return join(cwd, path)
    }

    private static func parentPath(_ path: String) -> String {
        if path == "/" { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private static func join(_ base: String, _ part: String) -> String {
        if base == "/" { return "/" + part }
        return base + "/" + part
    }

    /// POSIX `realpath(3)`. A nil buffer lets libc allocate, so the result can
    /// exceed `PATH_MAX` and is not rewritten by Foundation.
    private static func posixRealpath(_ path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// `/var` → `/private/var` (also `/tmp` and `/etc`) only when that short prefix
    /// realpaths to the `/private` form. A Linux `/var` that is not a symlink stays `/var`.
    private static func privateSystemPrefix(_ path: String) -> String {
        let pairs = [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")]
        for (short, long) in pairs {
            guard path == short || path.hasPrefix(short + "/") else { continue }
            guard posixRealpath(short) == long else { continue }
            return long + String(path.dropFirst(short.count))
        }
        return path
    }
}

public enum OpenFileProbe {
    /// `lsof -Fn` prints a machine record `n` + path. That line is the classifier.
    /// Exit status other than 0 means the file is not open. The sentence lsof prints
    /// on failure is ignored. Both the record and the queried path are canonicalized,
    /// so `/var/...` and `/private/var/...` name the same open file.
    public static func isOpen(lsofStatus: Int32, lsofStdout: String, path: String) -> Bool {
        guard lsofStatus == 0 else { return false }
        let needle = SessionPaths.canonical(path)
        return lsofStdout.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            guard line.hasPrefix("n"), line.count > 1 else { return false }
            return SessionPaths.canonical(String(line.dropFirst())) == needle
        }
    }

    /// Linux without lsof: every path some process holds open, read from the
    /// `/proc/<pid>/fd` links. Only processes this user may inspect are listed,
    /// which covers the coding agents the user runs. Nil when `/proc` is unreadable.
    public static func procOpenPaths(procRoot: String = "/proc", fileManager: FileManager = .default) -> Set<String>? {
        guard let pids = try? fileManager.contentsOfDirectory(atPath: procRoot) else { return nil }
        var open: Set<String> = []
        for pid in pids where !pid.isEmpty && pid.allSatisfy(\.isNumber) {
            let fdDir = "\(procRoot)/\(pid)/fd"
            guard let fds = try? fileManager.contentsOfDirectory(atPath: fdDir) else { continue }
            for fd in fds {
                guard let target = try? fileManager.destinationOfSymbolicLink(atPath: "\(fdDir)/\(fd)"), target.hasPrefix("/") else { continue }
                // The kernel already prints the resolved path.
                open.insert(target)
            }
        }
        return open
    }
}

public enum SessionTiering {
    public static let protectSeconds: TimeInterval = 24 * 60 * 60

    /// True for anything that is not a session transcript: names other than
    /// `.jsonl`/`.json`, credentials and tokens, sidecar settings, temp files,
    /// and SQLite files. Such a file is never tiered, whatever the root says.
    public static func forbidden(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if !name.hasSuffix(".jsonl") && !name.hasSuffix(".json") { return true }
        let blocked = [".credentials.json", "auth.json", "config.toml", ".claude.json", "settings.json", "config.json", "state.json", "manifest.json", "sessions.json", "models.json"]
        if blocked.contains(name) { return true }
        let lowerName = name.lowercased()
        for word in ["auth", "token", "credential", "secret", "password", "apikey", "api_key", "api-key"] where lowerName.contains(word) {
            return true
        }
        if lowerName.hasSuffix(".settings.json") || lowerName.hasSuffix(".meta.json") { return true }
        if lowerName.hasPrefix(".") { return true }
        let lower = path.lowercased()
        if lower.contains(".sqlite") || lower.hasSuffix(".db") || lower.contains("state.vscdb") || lower.hasSuffix("-wal") || lower.hasSuffix("-shm") {
            return true
        }
        return false
    }

    /// Cold when the file is a session transcript, closed, unmodified for 24 hours, and
    /// unmodified for `coldDays` (default 14). An open file or a secret path is never cold.
    public static func decide(_ candidate: SessionCandidate, now: Date, coldDays: Int) -> SessionDecision {
        if forbidden(candidate.path) {
            return SessionDecision(candidate: candidate, cold: false, reason: "not a session transcript")
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

    @available(*, deprecated, message: "Legacy monthly archive path. v2 segments are write-once and are not addressed by month.")
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
    /// Short text digest (schema 3 index rows only).
    public var digest: String?
    public init(id: String, tool: String, path: String, sha256: String, size: UInt64, modified: Date, archive: String, member: String, preview: String, digest: String? = nil) {
        self.id = id
        self.tool = tool
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.modified = modified
        self.archive = archive
        self.member = member
        self.preview = preview
        self.digest = digest
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
        let canonicalQuery = query.hasPrefix("/") ? SessionPaths.canonical(query) : nil
        return entries.filter { entry in
            if entry.id.lowercased().contains(needle) || entry.preview.lowercased().contains(needle) || entry.tool.lowercased().contains(needle) || (entry.digest?.lowercased().contains(needle) ?? false) {
                return true
            }
            if entry.path.lowercased().contains(needle) { return true }
            guard let canonicalQuery else { return false }
            let stored = SessionPaths.canonical(entry.path)
            return stored == canonicalQuery || stored.lowercased().contains(canonicalQuery.lowercased())
        }
    }

    public func matches(_ query: String) -> [SessionIndexEntry] {
        if query.hasPrefix("/") {
            let canonicalQuery = SessionPaths.canonical(query)
            return entries.filter { SessionPaths.canonical($0.path) == canonicalQuery }
        }
        return entries.filter { $0.id == query || $0.path == query || $0.path.hasSuffix("/" + query) }
    }
}
