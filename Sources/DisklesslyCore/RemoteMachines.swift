import Foundation

/// Parsed `Host` block from `~/.ssh/config` (wildcards filtered out).
public struct SSHHostEntry: Codable, Equatable, Sendable {
    public var alias: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public init(alias: String, hostname: String? = nil, user: String? = nil, port: Int? = nil, identityFile: String? = nil, proxyJump: String? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }

    public var displayTarget: String {
        let target = hostname ?? alias
        let prefix = user.map { "\($0)@" } ?? ""
        let suffix = port.map { $0 != 22 ? ":\($0)" : "" } ?? ""
        return "\(prefix)\(target)\(suffix)"
    }

    public func jsonObject() -> [String: Any] {
        var obj: [String: Any] = ["alias": alias, "displayTarget": displayTarget]
        if let hostname { obj["hostname"] = hostname }
        if let user { obj["user"] = user }
        if let port { obj["port"] = port }
        if let identityFile { obj["identityFile"] = identityFile }
        if let proxyJump { obj["proxyJump"] = proxyJump }
        return obj
    }
}

/// Pure parser for OpenSSH client config files (`~/.ssh/config`).
public enum SSHConfigParser {
    /// Returns concrete `Host` entries in declaration order, filtering out any pattern containing `*`, `?`, or `!` or leading `-`.
    public static func parse(_ text: String) -> [SSHHostEntry] {
        var results: [SSHHostEntry] = []
        var aliasIndex: [String: Int] = [:]
        var wildcardBlocks: [(patterns: [String], fields: [String: String])] = []
        var currentTokens: [String] = []
        var fields: [String: String] = [:]

        func flush() {
            guard !currentTokens.isEmpty else {
                fields = [:]
                return
            }
            let concretes = currentTokens.filter { isConcreteHost($0) }
            let wildcards = currentTokens.filter { !isConcreteHost($0) && !$0.hasPrefix("!") }
            for alias in concretes {
                if let idx = aliasIndex[alias] {
                    if results[idx].hostname == nil { results[idx].hostname = fields["hostname"] }
                    if results[idx].user == nil { results[idx].user = fields["user"] }
                    if results[idx].port == nil { results[idx].port = fields["port"].flatMap(Int.init) }
                    if results[idx].identityFile == nil { results[idx].identityFile = fields["identityfile"] }
                    if results[idx].proxyJump == nil { results[idx].proxyJump = fields["proxyjump"] }
                } else {
                    aliasIndex[alias] = results.count
                    results.append(SSHHostEntry(
                        alias: alias,
                        hostname: fields["hostname"],
                        user: fields["user"],
                        port: fields["port"].flatMap(Int.init),
                        identityFile: fields["identityfile"],
                        proxyJump: fields["proxyjump"]
                    ))
                }
            }
            if !wildcards.isEmpty && !fields.isEmpty {
                wildcardBlocks.append((patterns: wildcards, fields: fields))
            }
            currentTokens = []
            fields = [:]
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let uncommented = stripComment(String(rawLine))
            let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let (key, value) = splitDirective(trimmed) else { continue }
            let lowerKey = key.lowercased()
            if lowerKey == "host" {
                flush()
                let tokens = splitTokens(value)
                // If any token in the Host line is a negated pattern (!foo), skip the non-concrete tokens
                currentTokens = tokens.filter { !$0.hasPrefix("!") }
            } else if lowerKey == "match" {
                flush()
            } else if !currentTokens.isEmpty {
                if fields[lowerKey] == nil {
                    fields[lowerKey] = unquote(value)
                }
            }
        }
        flush()

        // Apply wildcard blocks (such as `Host *`) as defaults for fields still nil.
        for block in wildcardBlocks {
            for i in results.indices {
                let alias = results[i].alias
                if block.patterns.contains(where: { wildcardMatch(pattern: $0, text: alias) }) {
                    if results[i].hostname == nil { results[i].hostname = block.fields["hostname"] }
                    if results[i].user == nil { results[i].user = block.fields["user"] }
                    if results[i].port == nil { results[i].port = block.fields["port"].flatMap(Int.init) }
                    if results[i].identityFile == nil { results[i].identityFile = block.fields["identityfile"] }
                    if results[i].proxyJump == nil { results[i].proxyJump = block.fields["proxyjump"] }
                }
            }
        }
        return results
    }

    public static func isConcreteHost(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.hasPrefix("-") { return false }
        if token.contains("*") || token.contains("?") || token.contains("!") { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[]")
        for scalar in token.unicodeScalars {
            if !allowed.contains(scalar) {
                return false
            }
        }
        return true
    }

    private static func wildcardMatch(pattern: String, text: String) -> Bool {
        if pattern == "*" { return true }
        let p = Array(pattern)
        let t = Array(text)
        var dp = Array(repeating: Array(repeating: false, count: t.count + 1), count: p.count + 1)
        dp[0][0] = true
        for i in 1...p.count {
            if p[i - 1] == "*" {
                dp[i][0] = dp[i - 1][0]
            }
        }
        if t.isEmpty { return dp[p.count][0] }
        for i in 1...p.count {
            for j in 1...t.count {
                if p[i - 1] == "*" {
                    dp[i][j] = dp[i - 1][j] || dp[i][j - 1]
                } else if p[i - 1] == "?" || p[i - 1] == t[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                }
            }
        }
        return dp[p.count][t.count]
    }

    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var out = ""
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                out.append(ch)
            } else if ch == "#" && !inQuotes {
                break
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func splitDirective(_ line: String) -> (String, String)? {
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == " " || ch == "\t" || ch == "=" { break }
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex, idx < line.endIndex else { return nil }
        let key = String(line[..<idx])
        var rest = line[idx...]
        while let first = rest.first, first == " " || first == "\t" || first == "=" {
            rest = rest.dropFirst()
        }
        let val = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else { return nil }
        return (key, val)
    }

    private static func splitTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
            } else if (ch == " " || ch == "\t") && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquote(_ text: String) -> String {
        if text.count >= 2 && text.first == "\"" && text.last == "\"" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

/// OpenSSH invocation helpers and stderr reason extraction.
public enum SSHCommand {
    public static let defaultFlags: [String] = [
        "-T",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=15",
    ]

    public static func arguments(host: String, remoteCommand: String, extraFlags: [String] = []) -> [String] {
        defaultFlags + extraFlags + ["--", host, remoteCommand]
    }

    /// Extracts the last non-empty line of stderr as the error reason.
    public static func lastErrorLine(_ stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.last ?? "ssh failed"
    }

    public static func lastErrorLine(_ data: Data) -> String {
        lastErrorLine(String(decoding: data, as: UTF8.self))
    }

    /// Single-quote shell escaping for POSIX sh (`'foo'\''bar'`).
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Safe repository path component for a host alias (`[A-Za-z0-9._-]`, max 80 chars).
    public static func sanitizeHost(_ host: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var out = ""
        for scalar in host.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("_")
            }
        }
        while out.hasPrefix(".") { out.removeFirst() }
        if out.isEmpty { out = "host" }
        if out.count > 80 { out = String(out.prefix(80)) }
        return out
    }
}

/// Platform detection from `uname -sm` for remote binary deployment.
public struct RemotePlatform: Codable, Equatable, Sendable {
    public var os: String       // "linux" or "darwin"
    public var arch: String     // "x86_64" or "arm64"
    public var raw: String

    public init(os: String, arch: String, raw: String) {
        self.os = os
        self.arch = arch
        self.raw = raw
    }

    /// Binary artifact name: `disklessly-<os>-<arch>` (e.g. `disklessly-linux-x86_64`, `disklessly-darwin-arm64`).
    public var binaryArtifactName: String {
        "disklessly-\(os)-\(arch)"
    }

    public static func parse(unameSM: String) -> RemotePlatform? {
        let parts = unameSM.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 2 else { return nil }
        let sys = parts[0].lowercased()
        let mach = parts[1].lowercased()
        let os: String
        if sys.contains("linux") {
            os = "linux"
        } else if sys.contains("darwin") {
            os = "darwin"
        } else {
            os = sys
        }
        let arch: String
        switch mach {
        case "x86_64", "amd64": arch = "x86_64"
        case "aarch64", "arm64": arch = "arm64"
        default: arch = mach
        }
        return RemotePlatform(os: os, arch: arch, raw: parts.joined(separator: " "))
    }
}

/// Machine status level for the Dashboard "Machines" view.
public enum MachineHealthLevel: String, Codable, Equatable, Sendable {
    case offline
    case critical
    case warning
    case ok

    public var sortRank: Int {
        switch self {
        case .offline: return 0
        case .critical: return 1
        case .warning: return 2
        case .ok: return 3
        }
    }

    /// Computes health level from reachability and root disk usage.
    /// Critical: >= 90% used or free < 10 GiB; Warning: >= 80% used or free < 25 GiB.
    public static func evaluate(reachable: Bool, totalBytes: UInt64, availableBytes: UInt64) -> MachineHealthLevel {
        guard reachable else { return .offline }
        guard totalBytes > 0 else { return .ok }
        let usedBytes = totalBytes >= availableBytes ? totalBytes - availableBytes : 0
        let usedPct = Double(usedBytes) / Double(totalBytes)
        let gib: UInt64 = 1024 * 1024 * 1024
        if usedPct >= 0.90 || (totalBytes >= 20 * gib && availableBytes < 10 * gib) {
            return .critical
        }
        if usedPct >= 0.80 || (totalBytes >= 50 * gib && availableBytes < 25 * gib) {
            return .warning
        }
        return .ok
    }
}

/// Summary card model for a machine (this machine or a remote SSH machine).
public struct MachineCardSummary: Codable, Equatable, Sendable {
    public var id: String
    public var host: String
    public var displayName: String
    public var isLocal: Bool
    public var configuredOrder: Int
    public var reachable: Bool
    public var level: MachineHealthLevel
    public var platform: String?
    public var binaryVersion: String?
    public var scanMode: String? // "binary" or "fallback-sh"
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var availableBytes: UInt64
    public var reclaimableBytes: UInt64
    public var offloadableBytes: UInt64
    public var offloadedCount: Int
    public var lastScannedAt: Date?
    public var lastError: String?

    public init(
        id: String,
        host: String,
        displayName: String,
        isLocal: Bool = false,
        configuredOrder: Int = 0,
        reachable: Bool = true,
        level: MachineHealthLevel = .ok,
        platform: String? = nil,
        binaryVersion: String? = nil,
        scanMode: String? = nil,
        totalBytes: UInt64 = 0,
        usedBytes: UInt64 = 0,
        availableBytes: UInt64 = 0,
        reclaimableBytes: UInt64 = 0,
        offloadableBytes: UInt64 = 0,
        offloadedCount: Int = 0,
        lastScannedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.host = host
        self.displayName = displayName
        self.isLocal = isLocal
        self.configuredOrder = configuredOrder
        self.reachable = reachable
        self.level = level
        self.platform = platform
        self.binaryVersion = binaryVersion
        self.scanMode = scanMode
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.reclaimableBytes = reclaimableBytes
        self.offloadableBytes = offloadableBytes
        self.offloadedCount = offloadedCount
        self.lastScannedAt = lastScannedAt
        self.lastError = lastError
    }

    public func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var obj: [String: Any] = [
            "id": id,
            "host": host,
            "displayName": displayName,
            "isLocal": isLocal,
            "configuredOrder": configuredOrder,
            "reachable": reachable,
            "level": level.rawValue,
            "totalBytes": NSNumber(value: totalBytes),
            "usedBytes": NSNumber(value: usedBytes),
            "availableBytes": NSNumber(value: availableBytes),
            "reclaimableBytes": NSNumber(value: reclaimableBytes),
            "offloadableBytes": NSNumber(value: offloadableBytes),
            "offloadedCount": offloadedCount,
        ]
        if let platform { obj["platform"] = platform }
        if let binaryVersion { obj["binaryVersion"] = binaryVersion }
        if let scanMode { obj["scanMode"] = scanMode }
        if let lastScannedAt { obj["lastScannedAt"] = iso.string(from: lastScannedAt) }
        if let lastError { obj["lastError"] = lastError }
        return obj
    }
}

/// Pure ordering function for the Machines page (#46 §4):
/// offline first, then critical, then warning, then configured order.
public enum MachineOrdering {
    public static func sort(_ machines: [MachineCardSummary]) -> [MachineCardSummary] {
        machines.enumerated().sorted { lhs, rhs in
            if lhs.element.level.sortRank != rhs.element.level.sortRank {
                return lhs.element.level.sortRank < rhs.element.level.sortRank
            }
            if lhs.element.configuredOrder != rhs.element.configuredOrder {
                return lhs.element.configuredOrder < rhs.element.configuredOrder
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// Mount point entry on a remote machine.
public struct RemoteMountInfo: Codable, Equatable, Sendable {
    public var device: String
    public var mountPoint: String
    public var fsType: String
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var availableBytes: UInt64

    public init(device: String, mountPoint: String, fsType: String, totalBytes: UInt64, usedBytes: UInt64, availableBytes: UInt64) {
        self.device = device
        self.mountPoint = mountPoint
        self.fsType = fsType
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }

    public func jsonObject() -> [String: Any] {
        [
            "device": device,
            "mountPoint": mountPoint,
            "fsType": fsType,
            "totalBytes": NSNumber(value: totalBytes),
            "usedBytes": NSNumber(value: usedBytes),
            "availableBytes": NSNumber(value: availableBytes),
        ]
    }
}

/// Actionable item discovered during a remote scan (cleanable cache/log or offloadable directory/file/image).
public struct RemoteScanItem: Codable, Equatable, Sendable {
    public enum ActionKind: String, Codable, Equatable, Sendable {
        case clean
        case offload
    }

    public var id: String
    public var category: String     // "package-cache", "logs", "model-cache", "container-image", "container-volume", "large-dir", "large-file", "kernel-snap"
    public var title: String
    public var path: String
    public var bytes: UInt64
    public var action: ActionKind
    public var recoverable: Bool
    public var reason: String
    public var inUse: Bool

    public init(
        id: String,
        category: String,
        title: String,
        path: String,
        bytes: UInt64,
        action: ActionKind,
        recoverable: Bool,
        reason: String,
        inUse: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.path = path
        self.bytes = bytes
        self.action = action
        self.recoverable = recoverable
        self.reason = reason
        self.inUse = inUse
    }

    public func jsonObject() -> [String: Any] {
        [
            "id": id,
            "category": category,
            "title": title,
            "path": path,
            "bytes": NSNumber(value: bytes),
            "action": action.rawValue,
            "recoverable": recoverable,
            "reason": reason,
            "inUse": inUse,
        ]
    }
}

/// Complete scan report for a remote SSH host.
public struct RemoteScanReport: Codable, Equatable, Sendable {
    public var host: String
    public var hostname: String
    public var remoteHome: String?
    public var platform: RemotePlatform?
    public var binaryVersion: String?
    public var scanMode: String // "binary+sh" or "fallback-sh"
    public var mounts: [RemoteMountInfo]
    public var items: [RemoteScanItem]
    public var scannedAt: Date

    public init(
        host: String,
        hostname: String,
        remoteHome: String? = nil,
        platform: RemotePlatform?,
        binaryVersion: String? = nil,
        scanMode: String = "fallback-sh",
        mounts: [RemoteMountInfo],
        items: [RemoteScanItem],
        scannedAt: Date = Date()
    ) {
        self.host = host
        self.hostname = hostname
        self.remoteHome = remoteHome
        self.platform = platform
        self.binaryVersion = binaryVersion
        self.scanMode = scanMode
        self.mounts = mounts
        self.items = items
        self.scannedAt = scannedAt
    }

    public var primaryMount: RemoteMountInfo? {
        if let data = mounts.first(where: { $0.mountPoint == "/System/Volumes/Data" }) { return data }
        if let root = mounts.first(where: { $0.mountPoint == "/" }) { return root }
        return mounts.max(by: { $0.totalBytes < $1.totalBytes })
    }

    public var reclaimableBytes: UInt64 {
        items.filter { $0.action == .clean && !$0.inUse }.reduce(0) { $0 + $1.bytes }
    }

    public var offloadableBytes: UInt64 {
        items.filter { $0.action == .offload && !$0.inUse }.reduce(0) { $0 + $1.bytes }
    }

    /// Top recommended items (not in use, sorted by impact; under critical disk pressure, clean items rank first).
    public var recommendations: [RemoteScanItem] {
        let level = MachineHealthLevel.evaluate(
            reachable: true,
            totalBytes: primaryMount?.totalBytes ?? 0,
            availableBytes: primaryMount?.availableBytes ?? 0
        )
        return items.filter { !$0.inUse && $0.bytes > 0 }.sorted { lhs, rhs in
            if level == .critical && lhs.action != rhs.action {
                return lhs.action == .clean
            }
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.path < rhs.path
        }
    }

    public func jsonObject(offloaded: [RemoteOffloadRecord] = []) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let primary = primaryMount
        var obj: [String: Any] = [
            "ok": true,
            "host": host,
            "hostname": hostname,
            "scanMode": scanMode,
            "scannedAt": iso.string(from: scannedAt),
            "totalBytes": NSNumber(value: primary?.totalBytes ?? 0),
            "usedBytes": NSNumber(value: primary?.usedBytes ?? 0),
            "availableBytes": NSNumber(value: primary?.availableBytes ?? 0),
            "reclaimableBytes": NSNumber(value: reclaimableBytes),
            "offloadableBytes": NSNumber(value: offloadableBytes),
            "mounts": mounts.map { $0.jsonObject() },
            "items": items.map { $0.jsonObject() },
            "recommendations": recommendations.map { $0.jsonObject() },
            "offloaded": offloaded.map { $0.jsonObject() },
        ]
        if let remoteHome { obj["remoteHome"] = remoteHome }
        if let platform {
            obj["platform"] = "\(platform.os)-\(platform.arch)"
        }
        if let binaryVersion {
            obj["binaryVersion"] = binaryVersion
        }
        return obj
    }
}

/// Optimized single-trip POSIX shell scan script and parser.
/// When a remote machine does not have a matching `disklessly` binary installed (or for fast unified probing),
/// this script collects uname, mounts, df, package caches, logs, AI models, container images/volumes, old kernels/snaps,
/// and large home folders in ONE SSH round trip.
public enum RemoteScanProbe {
    public static let combinedScript: String = #"""
export LC_ALL=C
export LANG=C
echo "@@SECTION:UNAME"
uname -sm 2>/dev/null || true
echo "@@SECTION:HOSTNAME"
hostname 2>/dev/null || uname -n 2>/dev/null || echo "remote"
echo "@@SECTION:HOME"
printf '%s\n' "$HOME"
echo "@@SECTION:BIN_VERSION"
if [ -x "$HOME/.disklessly/bin/disklessly" ]; then
  "$HOME/.disklessly/bin/disklessly" version 2>/dev/null || true
fi
echo "@@SECTION:PROC_MOUNTS"
if [ -r /proc/self/mounts ]; then
  cat /proc/self/mounts 2>/dev/null || true
fi
echo "@@SECTION:DF"
df -kP 2>/dev/null || true
echo "@@SECTION:CACHES"
probe_dir() {
  cat_id="$1"; cat_kind="$2"; title="$3"; target="$4"; act="$5"; rec="$6"; reason="$7"
  if [ -e "$target" ]; then
    kb=$(du -xsk "$target" 2>/dev/null | awk '{print $1}' | head -n 1)
    if [ -z "$kb" ] || [ "$kb" -eq 0 ] 2>/dev/null; then
      case "$target" in
        /var/*) kb=$(sudo -n du -xsk "$target" 2>/dev/null | awk '{print $1}' | head -n 1) ;;
      esac
    fi
    if [ -n "$kb" ] && [ "$kb" -gt 0 ] 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cat_id" "$cat_kind" "$title" "$target" "$kb" "$act" "$rec" "$reason"
    fi
  fi
}
probe_dir "cache-apt" "package-cache" "APT package cache" "/var/cache/apt/archives" "clean" "false" "Rebuildable apt archive cache"
probe_dir "cache-dnf" "package-cache" "DNF package cache" "/var/cache/dnf" "clean" "false" "Rebuildable dnf package and metadata cache"
probe_dir "cache-yum" "package-cache" "YUM package cache" "/var/cache/yum" "clean" "false" "Rebuildable yum package cache"
probe_dir "cache-pip" "package-cache" "pip wheel & http cache" "$HOME/.cache/pip" "clean" "false" "Rebuildable Python pip cache"
probe_dir "cache-uv" "package-cache" "uv Python cache" "$HOME/.cache/uv" "clean" "false" "Rebuildable uv cache"
probe_dir "cache-npm" "package-cache" "npm package cache" "$HOME/.npm" "clean" "false" "Rebuildable npm cache"
probe_dir "cache-pnpm" "package-cache" "pnpm content-addressable store" "$HOME/.local/share/pnpm/store" "clean" "false" "Rebuildable pnpm package store"
probe_dir "cache-pnpm-store-legacy" "package-cache" "pnpm store (legacy ~/.pnpm-store)" "$HOME/.pnpm-store" "clean" "false" "Rebuildable pnpm package store"
probe_dir "cache-pnpm-cache" "package-cache" "pnpm download & dlx cache" "$HOME/.cache/pnpm" "clean" "false" "Rebuildable pnpm cache"
probe_dir "cache-yarn" "package-cache" "Yarn package cache" "$HOME/.cache/yarn" "clean" "false" "Rebuildable Yarn package cache"
probe_dir "cache-cargo" "package-cache" "Cargo registry cache" "$HOME/.cargo/registry" "clean" "false" "Rebuildable Rust cargo registry"
probe_dir "cache-cargo-git" "package-cache" "Cargo git cache" "$HOME/.cargo/git" "clean" "false" "Rebuildable Rust cargo git checkouts"
probe_dir "cache-gobuild" "package-cache" "Go build cache" "$HOME/.cache/go-build" "clean" "false" "Rebuildable Go compiler cache"
probe_dir "cache-gomod" "package-cache" "Go module cache" "$HOME/go/pkg/mod" "clean" "false" "Rebuildable Go module cache"
probe_dir "cache-swiftpm" "package-cache" "SwiftPM package cache" "$HOME/.cache/org.swift.swiftpm" "clean" "false" "Rebuildable Swift Package Manager cache"
probe_dir "cache-clang" "package-cache" "Clang module cache" "$HOME/.cache/clang" "clean" "false" "Rebuildable Clang module cache"
probe_dir "cache-gradle" "package-cache" "Gradle build cache" "$HOME/.gradle/caches" "clean" "false" "Rebuildable Gradle caches"
probe_dir "cache-playwright" "package-cache" "Playwright browser cache" "$HOME/.cache/ms-playwright" "clean" "false" "Re-downloadable Playwright headless browsers"
probe_dir "cache-puppeteer" "package-cache" "Puppeteer browser cache" "$HOME/.cache/puppeteer" "clean" "false" "Re-downloadable Puppeteer headless browsers"
probe_dir "cache-node-gyp" "package-cache" "node-gyp headers cache" "$HOME/.cache/node-gyp" "clean" "false" "Rebuildable node-gyp headers cache"
probe_dir "cache-typescript" "package-cache" "TypeScript cache" "$HOME/.cache/typescript" "clean" "false" "Rebuildable TypeScript cache"
probe_dir "cache-brew" "package-cache" "Homebrew cache" "$HOME/Library/Caches/Homebrew" "clean" "false" "Rebuildable Homebrew download cache"
probe_dir "logs-var" "logs" "System logs (/var/log)" "/var/log" "clean" "false" "Rotated and archived system logs"
probe_dir "logs-coredump" "logs" "Systemd core dumps" "/var/lib/systemd/coredump" "clean" "false" "Crash core dump files"
probe_dir "model-hf" "model-cache" "HuggingFace Hub models" "$HOME/.cache/huggingface" "offload" "true" "Large AI model weights; can be offloaded to repo or re-downloaded"
probe_dir "model-ollama" "model-cache" "Ollama models" "$HOME/.ollama/models" "offload" "true" "Ollama LLM blobs; can be offloaded to repo"
probe_dir "snap-cache" "kernel-snap" "Snapd cache" "/var/lib/snapd/cache" "clean" "false" "Old snap package cache"
echo "@@SECTION:KERNELS"
cur_k=$(uname -r 2>/dev/null || true)
if [ -n "$cur_k" ] && [ -d /lib/modules ]; then
  for mod in /lib/modules/*; do
    [ -d "$mod" ] || continue
    ver=$(basename "$mod")
    [ "$ver" = "$cur_k" ] && continue
    kb=$(du -xsk "$mod" 2>/dev/null | awk '{print $1}' | head -n 1)
    if [ -n "$kb" ] && [ "$kb" -gt 0 ] 2>/dev/null; then
      printf 'kernel-%s\tkernel-snap\tOld kernel modules (%s)\t%s\t%s\tclean\tfalse\tInactive kernel module tree (running %s)\n' "$ver" "$ver" "$mod" "$kb" "$cur_k"
    fi
  done
fi
echo "@@SECTION:JOURNAL"
if command -v journalctl >/dev/null 2>&1; then
  journalctl --disk-usage 2>/dev/null || sudo -n journalctl --disk-usage 2>/dev/null || true
fi
echo "@@SECTION:CONTAINERS"
if command -v docker >/dev/null 2>&1; then
  docker images --format 'docker|{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}' 2>/dev/null || true
  docker ps -a --format 'inuse|docker|{{.Image}}|{{.ID}}' 2>/dev/null || true
fi
if command -v podman >/dev/null 2>&1; then
  podman images --format 'podman|{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}' 2>/dev/null || true
  podman ps -a --format 'inuse|podman|{{.Image}}|{{.ID}}' 2>/dev/null || true
fi
if command -v ctr >/dev/null 2>&1; then
  ctr -n k8s.io images ls 2>/dev/null | awk 'NR>1 && NF>=4 {print "containerd|"$1"|"$3"|"$4$5}' | head -n 20 || true
fi
echo "@@SECTION:BUILD_CACHE"
if command -v docker >/dev/null 2>&1; then
  T=""; command -v timeout >/dev/null 2>&1 && T="timeout 30"
  $T docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '$1=="Build Cache"{print "docker|"$2}' || true
fi
echo "@@SECTION:LARGE_HOME"
if [ -d "$HOME" ]; then
  for entry in "$HOME"/*; do
    [ -e "$entry" ] || continue
    [ -L "$entry" ] && continue
    base=$(basename "$entry")
    case "$base" in
      .ssh|.disklessly|.cache|.local|.config|.npm|.cargo|.ollama|Library|Applications) continue ;;
      *.disklessly-remote) continue ;;
    esac
    kb=$(du -xsk "$entry" 2>/dev/null | awk '{print $1}' | head -n 1)
    if [ -n "$kb" ] && [ "$kb" -ge 1024 ] 2>/dev/null; then
      if [ -d "$entry" ]; then kind="large-dir"; else kind="large-file"; fi
      printf '%s\t%s\t%s\n' "$kind" "$kb" "$entry"
    fi
  done
fi
echo "@@SECTION:END"
"""#

    private static let skippedFsTypes: Set<String> = [
        "proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "cgroup", "cgroup2",
        "pstore", "bpf", "tracefs", "debugfs", "securityfs", "hugetlbfs",
        "mqueue", "fusectl", "configfs", "efivarfs", "squashfs", "iso9660",
        "autofs", "overlay", "nsfs", "ramfs", "rpc_pipefs", "binfmt_misc",
    ]

    public static func parse(host: String, output: String, now: Date = Date()) -> RemoteScanReport {
        var sections: [String: [String]] = [:]
        var current = ""
        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("@@SECTION:") {
                current = String(line.dropFirst("@@SECTION:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                sections[current] = []
            } else if !current.isEmpty {
                sections[current, default: []].append(line)
            }
        }

        let unameLine = (sections["UNAME"] ?? []).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let platform = RemotePlatform.parse(unameSM: unameLine)
        let hostname = (sections["HOSTNAME"] ?? []).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? host
        let remoteHome = (sections["HOME"] ?? []).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let binVerLine = (sections["BIN_VERSION"] ?? []).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let binaryVersion: String? = binVerLine.flatMap { line in
            let parts = line.split(separator: " ")
            return parts.count >= 2 ? String(parts[1]) : String(line)
        }

        let mounts = parseMounts(procMounts: sections["PROC_MOUNTS"] ?? [], dfLines: sections["DF"] ?? [], os: platform?.os)
        var items: [RemoteScanItem] = []
        var seenPaths = Set<String>()

        // 1. Caches & known dirs + old kernels
        for line in (sections["CACHES"] ?? []) + (sections["KERNELS"] ?? []) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 8, let kb = UInt64(parts[4]), kb > 0 else { continue }
            let path = parts[3]
            guard seenPaths.insert(path).inserted else { continue }
            let action: RemoteScanItem.ActionKind = parts[5] == "offload" ? .offload : .clean
            let recoverable = parts[6] == "true"
            items.append(RemoteScanItem(
                id: parts[0],
                category: parts[1],
                title: parts[2],
                path: path,
                bytes: kb * 1024,
                action: action,
                recoverable: recoverable,
                reason: parts[7]
            ))
        }

        // 2. Journalctl
        for line in sections["JOURNAL"] ?? [] {
            if let bytes = parseJournalUsage(line), bytes > 0 {
                let path = "/var/log/journal"
                if seenPaths.insert(path).inserted {
                    items.append(RemoteScanItem(
                        id: "journalctl-vacuum",
                        category: "logs",
                        title: "Systemd journal logs",
                        path: path,
                        bytes: bytes,
                        action: .clean,
                        recoverable: false,
                        reason: "Vacuum systemd journal logs older than 7 days"
                    ))
                }
            }
        }

        // 3. Container images & in-use detection
        let containerLines = sections["CONTAINERS"] ?? []
        var inUseImages = Set<String>()
        for line in containerLines where line.hasPrefix("inuse|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3 {
                inUseImages.insert("\(parts[1])|\(parts[2])")
            }
        }
        for line in containerLines where !line.hasPrefix("inuse|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let runtime = parts[0]
            let ref = parts[1]
            let imageId = parts[2]
            let bytes = ContainerParse.dockerSize(parts[3]) ?? 0
            guard bytes > 0 else { continue }
            let id = "image-\(runtime)-\(SSHCommand.sanitizeHost(imageId))"
            let displayRef = ref.isEmpty || ref == "<none>:<none>" ? imageId : ref
            let path = "\(runtime)://\(displayRef)"
            guard seenPaths.insert(path).inserted else { continue }
            let used = inUseImages.contains("\(runtime)|\(displayRef)") || inUseImages.contains("\(runtime)|\(imageId)")
            items.append(RemoteScanItem(
                id: id,
                category: "container-image",
                title: "\(runtime): \(displayRef)",
                path: path,
                bytes: bytes,
                action: .offload,
                recoverable: true,
                reason: used ? "In use by a container on this host" : "Container image can be saved to the repo and removed from remote disk",
                inUse: used
            ))
        }

        // 3b. Unused container build cache (`docker system df` reclaimable)
        for line in sections["BUILD_CACHE"] ?? [] {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let runtime = parts[0].trimmingCharacters(in: .whitespaces)
            let sizeToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard runtime == "docker", let bytes = ContainerParse.dockerSize(sizeToken), bytes > 0 else { continue }
            let path = "\(runtime)://build-cache"
            guard seenPaths.insert(path).inserted else { continue }
            items.append(RemoteScanItem(
                id: "cache-\(runtime)-build",
                category: "build-cache",
                title: "Docker build cache (unused)",
                path: path,
                bytes: bytes,
                action: .clean,
                recoverable: false,
                reason: "BuildKit cache not referenced by any running build; rebuilt on next docker build"
            ))
        }

        // 4. Large home directories / files
        for line in sections["LARGE_HOME"] ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let kb = UInt64(parts[1]), kb > 0 else { continue }
            let kind = parts[0]
            let path = parts[2]
            guard seenPaths.insert(path).inserted else { continue }
            let name = (path as NSString).lastPathComponent
            let shortSha = String(SHA256Digest.hex(Data(path.utf8)).prefix(8))
            items.append(RemoteScanItem(
                id: "offload-\(SSHCommand.sanitizeHost(name))-\(shortSha)",
                category: kind,
                title: name,
                path: path,
                bytes: kb * 1024,
                action: .offload,
                recoverable: true,
                reason: "Large \(kind == "large-dir" ? "folder" : "file") in home directory; can be offloaded to repo"
            ))
        }

        items.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.path < rhs.path
        }

        return RemoteScanReport(
            host: host,
            hostname: hostname,
            remoteHome: remoteHome,
            platform: platform,
            binaryVersion: binaryVersion,
            scanMode: binaryVersion != nil ? "binary+sh" : "fallback-sh",
            mounts: mounts,
            items: items,
            scannedAt: now
        )
    }

    public static func parseMounts(procMounts: [String], dfLines: [String], os: String?) -> [RemoteMountInfo] {
        var procByMount: [String: (device: String, fsType: String)] = [:]
        for line in procMounts {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 3 else { continue }
            let dev = cols[0]
            let mnt = cols[1].replacingOccurrences(of: "\\040", with: " ")
            let fs = cols[2]
            if procByMount[mnt] == nil {
                procByMount[mnt] = (dev, fs)
            }
        }

        func isUnder(_ mountPoint: String, _ prefix: String) -> Bool {
            mountPoint == prefix || mountPoint.hasPrefix(prefix + "/")
        }

        var results: [RemoteMountInfo] = []
        var seenDevices = Set<String>()

        for (index, line) in dfLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if index == 0 && trimmed.lowercased().hasPrefix("filesystem") { continue }
            let cols = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 6 else { continue }
            let dev = cols[0]
            guard let totalKB = UInt64(cols[1]),
                  let usedKB = UInt64(cols[2]),
                  let availKB = UInt64(cols[3]) else { continue }
            let mountPoint = cols[5...].joined(separator: " ")

            if os == "darwin" {
                if mountPoint != "/System/Volumes/Data" && mountPoint != "/" { continue }
            } else {
                if dev.hasPrefix("/dev/loop") || dev.hasPrefix("tmpfs") || dev.hasPrefix("devtmpfs") || dev.hasPrefix("overlay") || dev == "none" || dev == "udev" {
                    continue
                }
                if isUnder(mountPoint, "/snap") || isUnder(mountPoint, "/proc") || isUnder(mountPoint, "/sys") || isUnder(mountPoint, "/dev") || isUnder(mountPoint, "/run") {
                    continue
                }
                if let procInfo = procByMount[mountPoint] {
                    let fs = procInfo.fsType.lowercased()
                    // Network/FUSE mounts (rclone, sshfs, ...) report the remote's capacity, not this disk's.
                    if skippedFsTypes.contains(fs) || fs.hasPrefix("fuse") { continue }
                }
                if dev.hasPrefix("/dev/") {
                    if !seenDevices.insert(dev).inserted { continue }
                }
            }

            let fsType = procByMount[mountPoint]?.fsType ?? (os == "darwin" ? "apfs" : "ext4")
            results.append(RemoteMountInfo(
                device: dev,
                mountPoint: mountPoint,
                fsType: fsType,
                totalBytes: totalKB * 1024,
                usedBytes: usedKB * 1024,
                availableBytes: availKB * 1024
            ))
        }

        if os == "darwin", results.contains(where: { $0.mountPoint == "/System/Volumes/Data" }) {
            results.removeAll { $0.mountPoint == "/" }
        }
        return results
    }

    public static func parseJournalUsage(_ line: String) -> UInt64? {
        guard let range = line.range(of: "take up ") else { return nil }
        let after = line[range.upperBound...]
        guard let rawToken = after.split(separator: " ").first else { return nil }
        var token = String(rawToken)
        if let last = token.last, ["K", "M", "G", "T", "k", "m", "g", "t"].contains(last) {
            token.append("iB")
        }
        return ContainerParse.dockerSize(token)
    }
}

/// Builds the POSIX sh run on the remote for one `clean` item and parses what it reports back.
///
/// Every script prints `@@FREED_KB <n>` (free-space delta of the item's filesystem measured with `df`
/// before and after, so hard links, sudo-only files and partial deletes are reported truthfully) and
/// `@@BUSY <path>` for each child it skipped because a running process maps or executes a file under it.
public enum RemoteCleanCommand {
    public struct Outcome: Equatable, Sendable {
        public var freedBytes: UInt64?
        public var busy: [String]
        public var exitCode: Int32
    }

    /// Rotated logs: `*.gz`, `*.1`, `*.old`, and dateext rotations (`messages-20261025`) used by RHEL/Oracle/Fedora.
    static let rotatedLogFind = #"find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' -o -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' \) -delete"#

    /// Deletes each child of "$P" unless a live process maps/executes something under it; root-owned
    /// trees fall back to `sudo -n`; read-only trees (Go module cache) are made writable first.
    static let guardedChildDelete = #"""
if [ -d "$P" ]; then
  S=""; [ -w "$P" ] || S="sudo -n"
  busy=$( { sudo -n sh -c 'ls -l /proc/[0-9]*/exe; cat /proc/[0-9]*/maps' || sh -c 'ls -l /proc/[0-9]*/exe; cat /proc/[0-9]*/maps'; } 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if (substr($i, 1, 1) == "/") print $i }' | sort -u )
  for c in "$P"/* "$P"/.[!.]* "$P"/..?*; do
    [ -e "$c" ] || [ -L "$c" ] || continue
    r=$(readlink -f "$c" 2>/dev/null || printf '%s' "$c")
    if printf '%s\n' "$busy" | awk -v r="$r" 'index($0, r "/") == 1 || $0 == r { f = 1 } END { exit !f }'; then
      printf '@@BUSY %s\n' "$c"
      continue
    fi
    $S chmod -R u+w "$c" 2>/dev/null
    $S rm -rf "$c"
  done
elif [ -f "$P" ]; then
  rm -f "$P" 2>/dev/null || sudo -n rm -f "$P"
fi
"""#

    /// Toolchains that read a cache through ordinary file opens (not mmap/exec), so the per-child guard
    /// cannot see them: if one is running, the whole cache is left alone and reported busy.
    static func toolchainPattern(for id: String) -> String? {
        switch id {
        case "cache-gomod", "cache-gobuild": return "pgrep -x 'go|gopls'"
        // `[G]` keeps `pgrep -f` from matching this very script's command line.
        case "cache-gradle": return "pgrep -f '[G]radleDaemon|[G]radleWrapperMain'"
        case "cache-pnpm", "cache-pnpm-store-legacy", "cache-pnpm-cache": return "pgrep -x pnpm"
        case "cache-npm", "cache-node-gyp": return "pgrep -x 'npm|npx|node-gyp'"
        case "cache-cargo", "cache-cargo-git": return "pgrep -x 'cargo|rustc'"
        case "cache-swiftpm", "cache-clang": return "pgrep -x 'swift|swift-build|swift-test|swift-package|swiftc|clang'"
        case "cache-pip", "cache-uv": return "pgrep -x 'pip|pip3|uv'"
        default: return nil
        }
    }

    public static func body(id: String, path: String) -> String {
        let core = coreBody(id: id, path: path)
        guard let check = toolchainPattern(for: id) else { return core }
        return "if \(check) >/dev/null 2>&1; then printf '@@BUSY %s\\n' \(SSHCommand.shellQuote(path)); exit 0; fi\n\(core)"
    }

    static func coreBody(id: String, path: String) -> String {
        switch id {
        case "journalctl-vacuum":
            return "sudo -n journalctl --vacuum-time=7d 2>/dev/null || journalctl --vacuum-time=7d"
        case "cache-apt":
            return "sudo -n apt-get clean 2>/dev/null || apt-get clean"
        case "cache-dnf":
            return "sudo -n dnf clean all 2>/dev/null || dnf clean all"
        case "cache-yum":
            return "sudo -n yum clean all 2>/dev/null || yum clean all"
        case "cache-docker-build":
            return "docker builder prune -af"
        case "logs-var":
            return "sudo -n \(rotatedLogFind) 2>/dev/null || \(rotatedLogFind) 2>/dev/null; true"
        default:
            // Well-known cache roots stay (tools expect them); an explicitly chosen sub-path goes entirely once emptied.
            let tidy = id.hasPrefix("custom-") ? "\nrmdir \"$P\" 2>/dev/null || true" : ""
            return "P=\(SSHCommand.shellQuote(path))\n\(guardedChildDelete)\(tidy)"
        }
    }

    /// Full script: `df` before, the item's body in a subshell, `df` after, then the markers.
    public static func script(id: String, path: String) -> String {
        let dfTarget: String
        if path.hasPrefix("docker://") {
            dfTarget = "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /)"
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            dfTarget = SSHCommand.shellQuote(parent.isEmpty ? "/" : parent)
        }
        return """
        __dkl_avail() { df -kP "$1" 2>/dev/null | awk 'NR==2 { print $4 }'; }
        __dkl_fs=\(dfTarget)
        __dkl_b=$(__dkl_avail "$__dkl_fs")
        (
        \(body(id: id, path: path))
        ); __dkl_rc=$?
        __dkl_a=$(__dkl_avail "$__dkl_fs")
        echo "@@RC $__dkl_rc"
        echo "@@FREED_KB $(( ${__dkl_a:-0} - ${__dkl_b:-0} ))"
        """
    }

    public static func parse(_ output: String) -> Outcome {
        var freed: UInt64?
        var busy: [String] = []
        var rc: Int32 = 0
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("@@RC ") {
                rc = Int32(line.dropFirst("@@RC ".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("@@FREED_KB ") {
                let n = Int64(line.dropFirst("@@FREED_KB ".count).trimmingCharacters(in: .whitespaces)) ?? 0
                freed = n > 0 ? UInt64(n) * 1024 : 0
            } else if line.hasPrefix("@@BUSY ") {
                busy.append(String(line.dropFirst("@@BUSY ".count)))
            }
        }
        return Outcome(freedBytes: freed, busy: busy, exitCode: rc)
    }
}

/// Dry-run plan for remote clean, offload, or restore (#46 §3).
public struct RemoteActionPlan: Codable, Equatable, Sendable {
    public struct PlanItem: Codable, Equatable, Sendable {
        public var id: String
        public var path: String
        public var title: String
        public var kind: String        // "folder", "file", "container-image", "cache"
        public var bytes: UInt64
        public var action: String      // "clean", "offload", "restore"
        public var recoverable: Bool
        public var repoObject: String?

        public init(id: String, path: String, title: String, kind: String = "folder", bytes: UInt64, action: String, recoverable: Bool, repoObject: String? = nil) {
            self.id = id
            self.path = path
            self.title = title
            self.kind = kind
            self.bytes = bytes
            self.action = action
            self.recoverable = recoverable
            self.repoObject = repoObject
        }

        public func jsonObject() -> [String: Any] {
            var obj: [String: Any] = [
                "id": id,
                "path": path,
                "title": title,
                "kind": kind,
                "bytes": NSNumber(value: bytes),
                "action": action,
                "recoverable": recoverable,
            ]
            if let repoObject { obj["repoObject"] = repoObject }
            return obj
        }
    }

    public var host: String
    public var action: String
    public var mode: String // "relay" (Mode A) or "direct" (Mode B) or "clean"
    public var dryRun: Bool
    public var items: [PlanItem]

    public init(host: String, action: String, mode: String = "relay", dryRun: Bool = true, items: [PlanItem]) {
        self.host = host
        self.action = action
        self.mode = mode
        self.dryRun = dryRun
        self.items = items
    }

    public var totalBytes: UInt64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public func jsonObject() -> [String: Any] {
        [
            "ok": true,
            "host": host,
            "action": action,
            "mode": mode,
            "dryRun": dryRun,
            "totalBytes": NSNumber(value: totalBytes),
            "items": items.map { $0.jsonObject() },
        ]
    }
}

/// Safety policy for remote destructive/offload paths.
public enum RemotePathPolicy {
    private static let forbiddenExact: Set<String> = [
        "", "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64",
        "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp",
        "/usr", "/var", "/System", "/Applications", "/Library", "/Users",
        "/System/Volumes/Data", "/private", "/private/var", "/private/etc",
    ]

    public static func canonicalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("docker://") || trimmed.hasPrefix("podman://") || trimmed.hasPrefix("containerd://") {
            return trimmed
        }
        return (trimmed as NSString).standardizingPath
    }

    public static func refusal(for path: String, remoteHome: String? = nil) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "path is empty" }
        if trimmed.hasPrefix("docker://") || trimmed.hasPrefix("podman://") {
            return nil
        }
        if trimmed.hasPrefix("containerd://") {
            return "containerd image offload is read-only in this build; use docker or podman"
        }
        guard trimmed.hasPrefix("/") else { return "path must be absolute: \(trimmed)" }
        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if rawComponents.contains("..") || rawComponents.contains(".") {
            return "refusing path with dot traversal: \(trimmed)"
        }
        let std = (trimmed as NSString).standardizingPath
        if forbiddenExact.contains(std) {
            return "refusing system root path: \(std)"
        }
        for prefix in ["/proc/", "/sys/", "/dev/", "/boot/", "/etc/", "/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/"] {
            if std.hasPrefix(prefix) {
                return "refusing protected system path: \(std)"
            }
        }
        // Refuse top-level user home directories like `/home/ubuntu` or `/Users/alice`
        let stdParts = std.split(separator: "/").map(String.init)
        if stdParts.count == 2 && (stdParts[0] == "home" || stdParts[0] == "Users") {
            return "refusing user home root directory: \(std)"
        }
        if let home = remoteHome, !home.isEmpty {
            let stdHome = (home as NSString).standardizingPath
            // Refuse remoteHome itself or any ancestor of remoteHome
            if std == stdHome || stdHome.hasPrefix(std + "/") {
                return "refusing remote home directory or its ancestor: \(std)"
            }
            if std == "\(stdHome)/.ssh" || std.hasPrefix("\(stdHome)/.ssh/") {
                return "refusing SSH configuration directory: \(std)"
            }
            if std == "\(stdHome)/.disklessly" || std.hasPrefix("\(stdHome)/.disklessly/") {
                return "refusing Disklessly internal directory: \(std)"
            }
        }
        if std.hasSuffix("/.ssh") || std.contains("/.ssh/") || std.hasSuffix("/.disklessly") || std.contains("/.disklessly/") {
            return "refusing protected directory: \(std)"
        }
        return nil
    }
}

/// Transaction journal for remote clean/offload/restore operations (#46 §3).
/// Stored in `<stateDir>/remote-journals/<txid>.json` locally and `~/.disklessly/journal/<txid>.json` on the remote.
public struct RemoteJournal: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Equatable, Sendable {
        case planned
        case uploaded
        case verified
        case stubbed
        case movedAside
        case completed
        case rolledBack
        case failed
    }

    public static func isValidTxid(_ txid: String) -> Bool {
        guard !txid.isEmpty && txid.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdef-")
        return txid.unicodeScalars.allSatisfy { allowed.contains($0) } && !txid.hasPrefix("-")
    }

    public var schema: String = "remote-tx/1"
    public var txid: String
    public var host: String
    public var action: String          // "clean", "offload", "restore"
    public var mode: String            // "relay" or "direct"
    public var targetPath: String
    public var asidePath: String?
    public var stubPath: String?
    public var repoObject: String?
    public var recordId: String?
    public var sha256: String?
    public var bytes: UInt64
    public var phase: Phase
    public var createdAt: Date
    public var updatedAt: Date
    public var note: String?

    public init(
        txid: String = UUID().uuidString.lowercased(),
        host: String,
        action: String,
        mode: String = "relay",
        targetPath: String,
        asidePath: String? = nil,
        stubPath: String? = nil,
        repoObject: String? = nil,
        recordId: String? = nil,
        sha256: String? = nil,
        bytes: UInt64 = 0,
        phase: Phase = .planned,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        note: String? = nil
    ) {
        self.txid = txid
        self.host = host
        self.action = action
        self.mode = mode
        self.targetPath = targetPath
        self.asidePath = asidePath
        self.stubPath = stubPath
        self.repoObject = repoObject
        self.recordId = recordId
        self.sha256 = sha256
        self.bytes = bytes
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.note = note
    }

    public func encode() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> RemoteJournal {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(RemoteJournal.self, from: data)
    }

    public func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var obj: [String: Any] = [
            "schema": schema,
            "txid": txid,
            "host": host,
            "action": action,
            "mode": mode,
            "targetPath": targetPath,
            "bytes": NSNumber(value: bytes),
            "phase": phase.rawValue,
            "createdAt": iso.string(from: createdAt),
            "updatedAt": iso.string(from: updatedAt),
        ]
        if let asidePath { obj["asidePath"] = asidePath }
        if let stubPath { obj["stubPath"] = stubPath }
        if let repoObject { obj["repoObject"] = repoObject }
        if let recordId { obj["recordId"] = recordId }
        if let sha256 { obj["sha256"] = sha256 }
        if let note { obj["note"] = note }
        return obj
    }
}

/// Pure recovery decision for an interrupted remote journal.
public enum RemoteJournalRecovery {
    public enum Decision: Equatable, Sendable {
        case none
        case markCompleted
        case rollbackMoveAside(asidePath: String, targetPath: String, stubPath: String?)
        case removeStubOnly(stubPath: String)
        case finishRemoveAside(asidePath: String)
    }

    public static func decide(journal: RemoteJournal, targetExists: Bool, asideExists: Bool, stubExists: Bool) -> Decision {
        switch journal.phase {
        case .completed, .rolledBack, .failed:
            return .none
        case .planned, .uploaded, .verified, .stubbed:
            if let aside = journal.asidePath, asideExists, !targetExists {
                if stubExists && journal.sha256 != nil && journal.recordId != nil {
                    return .finishRemoveAside(asidePath: aside)
                }
                return .rollbackMoveAside(asidePath: aside, targetPath: journal.targetPath, stubPath: journal.stubPath)
            }
            if let stub = journal.stubPath, stubExists, targetExists {
                return .removeStubOnly(stubPath: stub)
            }
            return .none
        case .movedAside:
            if let aside = journal.asidePath, asideExists {
                if stubExists && journal.sha256 != nil {
                    return .finishRemoveAside(asidePath: aside)
                }
                if !targetExists {
                    return .rollbackMoveAside(asidePath: aside, targetPath: journal.targetPath, stubPath: journal.stubPath)
                }
            }
            if !asideExists && stubExists && !targetExists && journal.sha256 != nil {
                return .markCompleted
            }
            return .none
        }
    }
}

/// Record stored in the repository at `machines/<sanitized-host>/records/<id>.json` for an offloaded remote item.
public struct RemoteOffloadRecord: Codable, Equatable, Sendable {
    public var schema: String = "remote-offload/1"
    public var id: String
    public var host: String
    public var kind: String             // "folder", "file", "container-image"
    public var title: String
    public var originalPath: String
    public var stubPath: String?
    public var repoObject: String       // e.g. "machines/gpu-box/objects/<sha>.tar.gz"
    public var sha256: String
    public var storedBytes: UInt64
    public var logicalBytes: UInt64
    public var mode: String             // "relay" or "direct"
    public var rcloneRemote: String?    // populated when mode == "direct"
    public var createdAt: Date

    public init(
        id: String,
        host: String,
        kind: String,
        title: String,
        originalPath: String,
        stubPath: String? = nil,
        repoObject: String,
        sha256: String,
        storedBytes: UInt64,
        logicalBytes: UInt64,
        mode: String = "relay",
        rcloneRemote: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.kind = kind
        self.title = title
        self.originalPath = originalPath
        self.stubPath = stubPath
        self.repoObject = repoObject
        self.sha256 = sha256
        self.storedBytes = storedBytes
        self.logicalBytes = logicalBytes
        self.mode = mode
        self.rcloneRemote = rcloneRemote
        self.createdAt = createdAt
    }

    public static func objectPath(host: String, sha256: String, kind: String) -> String {
        let safeHost = SSHCommand.sanitizeHost(host)
        return "machines/\(safeHost)/objects/\(sha256).tar.gz"
    }

    public static func recordPath(host: String, id: String) -> String {
        let safeHost = SSHCommand.sanitizeHost(host)
        return "machines/\(safeHost)/records/\(id).json"
    }

    public func encode() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> RemoteOffloadRecord {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(RemoteOffloadRecord.self, from: data)
    }

    public func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var obj: [String: Any] = [
            "schema": schema,
            "id": id,
            "host": host,
            "kind": kind,
            "title": title,
            "originalPath": originalPath,
            "repoObject": repoObject,
            "sha256": sha256,
            "storedBytes": NSNumber(value: storedBytes),
            "logicalBytes": NSNumber(value: logicalBytes),
            "mode": mode,
            "createdAt": iso.string(from: createdAt),
        ]
        if let stubPath { obj["stubPath"] = stubPath }
        if let rcloneRemote { obj["rcloneRemote"] = rcloneRemote }
        return obj
    }
}
