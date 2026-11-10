import Foundation
import DisklesslyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the built-in reference scan found. `failed` means the process listing
/// could not be read, so no local transcript may be deleted.
public struct SessionReferenceScan: Equatable {
    public var exclusions: SessionExclusions
    public var failed: Bool

    public init(exclusions: SessionExclusions = SessionExclusions(), failed: Bool = false) {
        self.exclusions = exclusions
        self.failed = failed
    }
}

/// Sessions that running agents or herdr's saved layout still name. They are
/// treated like `--exclude-from` entries by every archive path.
///
/// - Processes of the current user (Linux `/proc/<pid>/cmdline`, else
///   `ps -axww -o args=`): every UUID on a command line that mentions `claude`
///   or `codex`, and every absolute `.jsonl` path on any command line.
/// - `<home>/.config/herdr/session.json`: every UUID and absolute `.jsonl` path.
public enum SessionReferences {
    /// Test seam: replaces the live process listing (one argv per process).
    nonisolated(unsafe) public static var processListOverride: (() throws -> [[String]])?
    /// Test seam: replaces the herdr layout path.
    nonisolated(unsafe) public static var herdrFileOverride: String?

    public static func scan(home: String) -> SessionReferenceScan {
        var result = SessionReferenceScan()
        do {
            let processes = try (processListOverride ?? processCommandLines)()
            merge(&result.exclusions, commandLines(processes))
        } catch {
            result.failed = true
        }
        merge(&result.exclusions, herdr(path: herdrFileOverride ?? (home as NSString).appendingPathComponent(".config/herdr/session.json")))
        return result
    }

    static func merge(_ into: inout SessionExclusions, _ other: SessionExclusions) {
        into.paths.formUnion(other.paths)
        into.ids.formUnion(other.ids)
    }

    static func commandLines(_ processes: [[String]]) -> SessionExclusions {
        var found = SessionExclusions()
        for argv in processes {
            let joined = argv.joined(separator: " ")
            let lower = joined.lowercased()
            if lower.contains("claude") || lower.contains("codex") {
                found.ids.formUnion(uuids(in: joined))
            }
            for argument in argv {
                if argument.hasPrefix("/") && argument.hasSuffix(".jsonl") { addPath(argument, to: &found) }
                for path in jsonlPaths(in: argument) { addPath(path, to: &found) }
            }
        }
        return found
    }

    static func herdr(path: String) -> SessionExclusions {
        guard let data = FileManager.default.contents(atPath: path) else { return SessionExclusions() }
        var strings = [String(decoding: data, as: UTF8.self)]
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            collectStrings(object, into: &strings)
        }
        var found = SessionExclusions()
        for text in strings {
            found.ids.formUnion(uuids(in: text))
            for path in jsonlPaths(in: text) { addPath(path, to: &found) }
        }
        return found
    }

    private static func collectStrings(_ value: Any, into strings: inout [String]) {
        if let text = value as? String {
            strings.append(text)
        } else if let array = value as? [Any] {
            for item in array { collectStrings(item, into: &strings) }
        } else if let object = value as? [String: Any] {
            for (key, item) in object {
                strings.append(key)
                collectStrings(item, into: &strings)
            }
        }
    }

    private static func addPath(_ path: String, to found: inout SessionExclusions) {
        found.paths.insert(path)
        found.paths.insert(SessionPaths.canonical(path))
    }

    private static let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    /// An absolute path ending in `.jsonl` that starts the text or follows a delimiter.
    private static let jsonlPattern = try! NSRegularExpression(pattern: "(?<![^\\s\"'=:,(\\[{])/[^\\s\"'<>|;,]*?\\.jsonl(?![A-Za-z0-9_.-])")

    static func uuids(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(uuidPattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { text[$0].lowercased() } })
    }

    static func jsonlPaths(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return jsonlPattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// The current user's processes, one argv each. Throws when neither `/proc`
    /// nor `ps` can be read.
    static func processCommandLines() throws -> [[String]] {
        #if os(Linux)
        if let processes = procProcesses() { return processes }
        #endif
        return try psProcesses()
    }

    #if os(Linux)
    private static func procProcesses() -> [[String]]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        let uid = getuid()
        let me = getpid()
        var processes: [[String]] = []
        var sawProcess = false
        for name in names {
            guard let pid = Int32(name) else { continue }
            sawProcess = true
            guard pid != me else { continue }
            var info = stat()
            guard stat("/proc/\(name)", &info) == 0, info.st_uid == uid else { continue }
            guard let handle = FileHandle(forReadingAtPath: "/proc/\(name)/cmdline") else { continue }
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            let argv = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
            if !argv.isEmpty { processes.append(argv) }
        }
        return sawProcess ? processes : nil
    }
    #endif

    private static func psProcesses() throws -> [[String]] {
        let candidates = ["/bin/ps", "/usr/bin/ps"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DisklesslyError.failure("cannot list processes: ps not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-axww", "-o", "args="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DisklesslyError.failure("cannot list processes: ps exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { [String($0)] }
    }
}
