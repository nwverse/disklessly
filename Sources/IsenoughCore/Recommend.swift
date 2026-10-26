import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Bounds for `isenough recommend`. Size is allocated 512-byte blocks, the same
/// basis as `du`, walked in-process so a stuck or localized `du` cannot be parsed.
public enum RecommendLimits {
    /// 100 MiB. `--min-size 100MB` is the decimal 100,000,000 bytes; the default is binary.
    public static let defaultMinSizeBytes: UInt64 = 100 * 1024 * 1024
    /// One app's walk stops after this, even if the tree is still descending.
    public static let sizeTimeout: TimeInterval = 20
    /// The whole scan stops starting new full walks after this.
    public static let scanTimeout: TimeInterval = 120
}

public enum RecommendScore {
    public static let mebibyte: Double = 1_048_576
    /// Days assumed for an app Spotlight has never recorded as used.
    public static let neverUsedIdleDays = 365
    /// Extra days added on top of `neverUsedIdleDays` so a never-used app outranks
    /// an app of the same size that was used exactly `neverUsedIdleDays` ago.
    public static let neverUsedBonusDays = 90

    /// Whole UTC-agnostic days of `86_400` seconds. A future date is zero days, not negative.
    public static func daysIdle(lastUsed: Date?, now: Date) -> Int? {
        guard let lastUsed else { return nil }
        let seconds = now.timeIntervalSince(lastUsed)
        if seconds <= 0 { return 0 }
        return Int(seconds / 86_400)
    }

    /// `(size in MiB) × idle weight`. Never-used weight is `neverUsedIdleDays + neverUsedBonusDays`.
    public static func value(sizeBytes: UInt64, daysIdle: Int?, neverUsed: Bool, neverUsedIdleDays: Int = RecommendScore.neverUsedIdleDays, neverUsedBonusDays: Int = RecommendScore.neverUsedBonusDays) -> Double {
        let weight: Double
        if neverUsed {
            weight = Double(neverUsedIdleDays + neverUsedBonusDays)
        } else {
            weight = Double(max(0, daysIdle ?? 0))
        }
        return (Double(sizeBytes) / mebibyte) * weight
    }
}

public struct RecommendOptions: Equatable {
    public var minSizeBytes: UInt64
    public var limit: Int?
    public var minIdleDays: Int?
    public var now: Date
    public var neverUsedIdleDays: Int
    public var neverUsedBonusDays: Int

    public init(minSizeBytes: UInt64 = RecommendLimits.defaultMinSizeBytes, limit: Int? = nil, minIdleDays: Int? = nil, now: Date = Date(), neverUsedIdleDays: Int = RecommendScore.neverUsedIdleDays, neverUsedBonusDays: Int = RecommendScore.neverUsedBonusDays) {
        self.minSizeBytes = minSizeBytes
        self.limit = limit
        self.minIdleDays = minIdleDays
        self.now = now
        self.neverUsedIdleDays = neverUsedIdleDays
        self.neverUsedBonusDays = neverUsedBonusDays
    }
}

/// One installed app after a scan. Callers on Linux construct this directly.
/// `lastUsed == nil` means Spotlight's `kMDItemLastUsedDate` was null (never used).
public struct RecommendApp: Equatable {
    public var path: String
    public var name: String
    public var bundleId: String
    public var sizeBytes: UInt64
    public var sizeIncomplete: Bool
    public var lastUsed: Date?
    public var macAppStore: Bool
    public var pinned: Bool
    public var packed: Bool
    public var running: Bool
    public var stub: Bool
    public var isenoughProduct: Bool
    public var systemLocation: Bool
    public var appleSystemSigned: Bool
    public var loginItem: Bool
    public var menuBarAgent: Bool
    public var backgroundHelperRunning: Bool
    public var systemExtension: Bool
    public var kernelExtension: Bool
    public var toolchain: Bool

    public init(path: String, name: String, bundleId: String, sizeBytes: UInt64, sizeIncomplete: Bool = false, lastUsed: Date? = nil, macAppStore: Bool = false, pinned: Bool = false, packed: Bool = false, running: Bool = false, stub: Bool = false, isenoughProduct: Bool = false, systemLocation: Bool = false, appleSystemSigned: Bool = false, loginItem: Bool = false, menuBarAgent: Bool = false, backgroundHelperRunning: Bool = false, systemExtension: Bool = false, kernelExtension: Bool = false, toolchain: Bool = false) {
        self.path = path
        self.name = name
        self.bundleId = bundleId
        self.sizeBytes = sizeBytes
        self.sizeIncomplete = sizeIncomplete
        self.lastUsed = lastUsed
        self.macAppStore = macAppStore
        self.pinned = pinned
        self.packed = packed
        self.running = running
        self.stub = stub
        self.isenoughProduct = isenoughProduct
        self.systemLocation = systemLocation
        self.appleSystemSigned = appleSystemSigned
        self.loginItem = loginItem
        self.menuBarAgent = menuBarAgent
        self.backgroundHelperRunning = backgroundHelperRunning
        self.systemExtension = systemExtension
        self.kernelExtension = kernelExtension
        self.toolchain = toolchain
    }
}

public struct RecommendItem: Equatable {
    public var path: String
    public var name: String
    public var bundleId: String
    public var sizeBytes: UInt64
    public var sizeIncomplete: Bool
    public var lastUsed: Date?
    public var neverUsed: Bool
    public var daysIdle: Int?
    public var macAppStore: Bool
    public var suggestedMode: String
    public var pinned: Bool
    public var packed: Bool
    public var score: Double
    public var reason: String
    public var warnings: [String]
    public var estimatedFreedBytes: UInt64

    public func jsonObject() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return [
            "name": name,
            "path": path,
            "bundleId": bundleId,
            "sizeBytes": NSNumber(value: sizeBytes),
            "sizeIncomplete": sizeIncomplete,
            "lastUsed": lastUsed.map { formatter.string(from: $0) } ?? NSNull(),
            "neverUsed": neverUsed,
            "daysIdle": daysIdle.map { NSNumber(value: $0) } ?? NSNull(),
            "macAppStore": macAppStore,
            "suggestedMode": suggestedMode,
            "pinned": pinned,
            "packed": packed,
            "score": NSNumber(value: score),
            "reason": reason,
            "warnings": warnings,
            "estimatedFreedBytes": NSNumber(value: estimatedFreedBytes),
        ]
    }
}

public struct RecommendReport: Equatable {
    public var scanAvailable: Bool
    public var minSizeBytes: UInt64
    public var limit: Int?
    public var minIdleDays: Int?
    public var recommendations: [RecommendItem]
    public var warnings: [RecommendItem]
    public var leftovers: [RecommendLeftover]
    public var estimatedFreedBytes: UInt64

    public var leftoverBytes: UInt64 {
        leftovers.reduce(0) { $0 + $1.sizeBytes }
    }

    public func jsonObject() -> [String: Any] {
        [
            "ok": true,
            "scan": scanAvailable ? "ok" : "unavailable",
            "detail": scanAvailable ? "" : "Scanning installed apps requires macOS",
            "minSizeBytes": NSNumber(value: minSizeBytes),
            "minIdleDays": minIdleDays.map { NSNumber(value: $0) } ?? NSNull(),
            "limit": limit.map { NSNumber(value: $0) } ?? NSNull(),
            "estimatedFreedBytes": NSNumber(value: estimatedFreedBytes),
            "recommendations": recommendations.map { $0.jsonObject() },
            "warnings": warnings.map { $0.jsonObject() },
            "leftoverBackups": leftovers.map { $0.jsonObject() },
            "leftoverBackupBytes": NSNumber(value: leftoverBytes),
        ]
    }

    public func text() -> String {
        var lines: [String] = []
        if !scanAvailable {
            lines.append("Scanning installed apps requires macOS.")
        }
        lines.append("\(recommendations.count) \(recommendations.count == 1 ? "recommendation" : "recommendations"), \(RecommendFormatting.byteText(estimatedFreedBytes)) estimated free")
        for item in recommendations {
            lines.append("- \(item.name) (\(item.path)) \(item.bundleId)")
            lines.append("  \(item.reason)")
            lines.append("  mode \(item.suggestedMode), score \(RecommendFormatting.scoreText(item.score))")
        }
        lines.append("\(warnings.count) \(warnings.count == 1 ? "warning" : "warnings")")
        for item in warnings {
            lines.append("- \(item.name) (\(item.path)) \(item.bundleId)")
            lines.append("  \(RecommendFormatting.byteText(item.sizeBytes))")
            lines.append("  \(item.reason)")
        }
        if !leftovers.isEmpty {
            lines.append(RecommendFormatting.leftoverLine(count: leftovers.count, bytes: leftoverBytes))
            for item in leftovers {
                lines.append("- \(item.path)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A backup the engine left beside an installed app. It is not scored.
public struct RecommendLeftover: Equatable {
    public var path: String
    public var sizeBytes: UInt64
    public var sizeIncomplete: Bool

    public init(path: String, sizeBytes: UInt64, sizeIncomplete: Bool = false) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeIncomplete = sizeIncomplete
    }

    public func jsonObject() -> [String: Any] {
        [
            "path": path,
            "sizeBytes": NSNumber(value: sizeBytes),
            "sizeIncomplete": sizeIncomplete,
        ]
    }
}

public enum RecommendFormatting {
    public static func byteText(_ bytes: UInt64) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        if bytes >= 1_073_741_824 {
            let value = Double(bytes) / 1_073_741_824
            let digits = value >= 10 ? 0 : 1
            return String(format: "%.\(digits)f GiB", locale: locale, value)
        }
        if bytes >= 1_048_576 {
            let value = Double(bytes) / 1_048_576
            let digits = value >= 10 ? 0 : 1
            return String(format: "%.\(digits)f MiB", locale: locale, value)
        }
        return "\(bytes) B"
    }

    public static func scoreText(_ score: Double) -> String {
        String(Int(score.rounded()))
    }

    /// One summary line. Paths are printed under it. The command does not delete these.
    public static func leftoverLine(count: Int, bytes: UInt64) -> String {
        let noun = count == 1 ? "leftover backup" : "leftover backups"
        return "\(count) \(noun) (\(byteText(bytes))) can be removed"
    }

    public static func warningText(_ code: String) -> String {
        switch code {
        case "loginItem": "login item"
        case "menuBarAgent": "menu bar agent"
        case "backgroundHelper": "background helper is running"
        case "systemExtension": "bundles a system extension"
        case "kernelExtension": "bundles a kernel extension"
        case "toolchain": "toolchain used by the engine"
        case "pinned": "pinned"
        case "alreadyPacked": "already packed"
        case "sizeTimedOut": "size scan timed out"
        default: code
        }
    }

    public static func reason(sizeBytes: UInt64, daysIdle: Int?, neverUsed: Bool, macAppStore: Bool, sizeIncomplete: Bool, warnings: [String]) -> String {
        if !warnings.isEmpty {
            return warnings.map(warningText).joined(separator: "; ")
        }
        var text = byteText(sizeBytes)
        if neverUsed {
            text += ", never used"
        } else if let daysIdle {
            text += daysIdle == 1 ? ", last used 1 day ago" : ", last used \(daysIdle) days ago"
        }
        if macAppStore { text += "; Mac App Store receipt, restore mode" }
        if sizeIncomplete { text += "; size is a lower bound because the scan timed out" }
        return text
    }
}

public enum RecommendRanking {
    /// Stable warning codes. The first match also decides `suggestedMode` when several apply.
    public static let warningOrder = ["toolchain", "kernelExtension", "systemExtension", "backgroundHelper", "loginItem", "menuBarAgent", "pinned", "alreadyPacked", "sizeTimedOut"]

    public static func rank(_ apps: [RecommendApp], options: RecommendOptions, scanAvailable: Bool = true) -> RecommendReport {
        var recommendations: [RecommendItem] = []
        var warnings: [RecommendItem] = []
        for app in apps {
            if app.stub || app.isenoughProduct || app.running { continue }
            if (app.systemLocation || app.appleSystemSigned) && !app.toolchain { continue }
            let codes = warningCodes(app)
            let neverUsed = app.lastUsed == nil
            let days = RecommendScore.daysIdle(lastUsed: app.lastUsed, now: options.now)
            let score = RecommendScore.value(sizeBytes: app.sizeBytes, daysIdle: days, neverUsed: neverUsed, neverUsedIdleDays: options.neverUsedIdleDays, neverUsedBonusDays: options.neverUsedBonusDays)
            let poor = !codes.isEmpty
            if poor {
                let largeEnough = app.sizeIncomplete || app.sizeBytes >= options.minSizeBytes
                if !largeEnough { continue }
                warnings.append(item(app, days: days, neverUsed: neverUsed, score: score, warnings: codes, freed: 0))
                continue
            }
            guard app.sizeBytes >= options.minSizeBytes else { continue }
            if let minimum = options.minIdleDays {
                let idleEnough = neverUsed || (days ?? 0) >= minimum
                if !idleEnough { continue }
            }
            recommendations.append(item(app, days: days, neverUsed: neverUsed, score: score, warnings: [], freed: app.sizeBytes))
        }
        recommendations = sort(recommendations)
        warnings = sort(warnings)
        if let limit = options.limit, limit >= 0, recommendations.count > limit {
            recommendations = Array(recommendations.prefix(limit))
        }
        let freed = recommendations.reduce(UInt64(0)) { $0 + $1.estimatedFreedBytes }
        return RecommendReport(scanAvailable: scanAvailable, minSizeBytes: options.minSizeBytes, limit: options.limit, minIdleDays: options.minIdleDays, recommendations: recommendations, warnings: warnings, leftovers: [], estimatedFreedBytes: freed)
    }

    private static func warningCodes(_ app: RecommendApp) -> [String] {
        var codes: [String] = []
        if app.toolchain { codes.append("toolchain") }
        if app.kernelExtension { codes.append("kernelExtension") }
        if app.systemExtension { codes.append("systemExtension") }
        if app.backgroundHelperRunning { codes.append("backgroundHelper") }
        if app.loginItem { codes.append("loginItem") }
        if app.menuBarAgent { codes.append("menuBarAgent") }
        if app.pinned { codes.append("pinned") }
        if app.packed { codes.append("alreadyPacked") }
        if app.sizeIncomplete { codes.append("sizeTimedOut") }
        return warningOrder.filter { codes.contains($0) }
    }

    private static func suggestedMode(_ app: RecommendApp, warnings: [String]) -> String {
        if warnings.contains("toolchain") || warnings.contains("kernelExtension") || warnings.contains("systemExtension") {
            return "unsupported"
        }
        if app.macAppStore || warnings.contains("loginItem") || warnings.contains("menuBarAgent") || warnings.contains("backgroundHelper") {
            return "restore"
        }
        if !warnings.isEmpty { return "skip" }
        return app.macAppStore ? "restore" : "mount"
    }

    private static func item(_ app: RecommendApp, days: Int?, neverUsed: Bool, score: Double, warnings: [String], freed: UInt64) -> RecommendItem {
        RecommendItem(
            path: app.path,
            name: app.name,
            bundleId: app.bundleId,
            sizeBytes: app.sizeBytes,
            sizeIncomplete: app.sizeIncomplete,
            lastUsed: app.lastUsed,
            neverUsed: neverUsed,
            daysIdle: days,
            macAppStore: app.macAppStore,
            suggestedMode: suggestedMode(app, warnings: warnings),
            pinned: app.pinned,
            packed: app.packed,
            score: score,
            reason: RecommendFormatting.reason(sizeBytes: app.sizeBytes, daysIdle: days, neverUsed: neverUsed, macAppStore: app.macAppStore, sizeIncomplete: app.sizeIncomplete, warnings: warnings),
            warnings: warnings,
            estimatedFreedBytes: freed
        )
    }

    private static func sort(_ items: [RecommendItem]) -> [RecommendItem] {
        items.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.path < rhs.path
        }
    }
}

public struct RecommendArguments: Equatable {
    public var minSizeBytes: UInt64
    public var limit: Int?
    public var minIdleDays: Int?
    /// Accepted here as well as before the command, matching `isenough --json recommend`.
    public var json: Bool

    public init(minSizeBytes: UInt64 = RecommendLimits.defaultMinSizeBytes, limit: Int? = nil, minIdleDays: Int? = nil, json: Bool = false) {
        self.minSizeBytes = minSizeBytes
        self.limit = limit
        self.minIdleDays = minIdleDays
        self.json = json
    }

    public func options(now: Date = Date()) -> RecommendOptions {
        RecommendOptions(minSizeBytes: minSizeBytes, limit: limit, minIdleDays: minIdleDays, now: now)
    }

    public static func parse(_ args: [String]) throws -> RecommendArguments {
        var result = RecommendArguments()
        var rest = args
        while let flag = rest.first {
            rest.removeFirst()
            switch flag {
            case "--json":
                result.json = true
            case "--min-size":
                guard let raw = rest.first else { throw IsenoughError.usage("Unknown option or missing value: --min-size") }
                rest.removeFirst()
                result.minSizeBytes = try parseSize(raw)
            case "--limit":
                guard let raw = rest.first else { throw IsenoughError.usage("Unknown option or missing value: --limit") }
                rest.removeFirst()
                result.limit = try parseCount(raw, name: "--limit")
            case "--min-idle-days":
                guard let raw = rest.first else { throw IsenoughError.usage("Unknown option or missing value: --min-idle-days") }
                rest.removeFirst()
                result.minIdleDays = try parseCount(raw, name: "--min-idle-days")
            default:
                throw IsenoughError.usage(flag.hasPrefix("-") ? "Unknown option: \(flag)" : "recommend does not take a positional argument: \(flag)")
            }
        }
        return result
    }

    public static func parse(query: [String: String]) throws -> RecommendArguments {
        var result = RecommendArguments()
        if let raw = query["minSize"] ?? query["min-size"] {
            result.minSizeBytes = try parseSize(raw)
        }
        if let raw = query["limit"] {
            result.limit = try parseCount(raw, name: "limit")
        }
        if let raw = query["minIdleDays"] ?? query["min-idle-days"] {
            result.minIdleDays = try parseCount(raw, name: "minIdleDays")
        }
        return result
    }

    /// Bare digits are bytes. `K`/`M`/`G` and `KiB`/`MiB`/`GiB` are 1024-based.
    /// `KB`/`MB`/`GB` are 1000-based. The unit is an ASCII token, not a localized word.
    public static func parseSize(_ raw: String) throws -> UInt64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IsenoughError.usage("missing size") }
        var index = trimmed.startIndex
        var dots = 0
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.isNumber {
                index = trimmed.index(after: index)
                continue
            }
            if character == "." {
                dots += 1
                guard dots == 1 else { throw IsenoughError.usage("invalid size: \(raw)") }
                index = trimmed.index(after: index)
                continue
            }
            break
        }
        let numberPart = trimmed[..<index]
        let unit = trimmed[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !numberPart.isEmpty, let value = Double(numberPart), value >= 0, value.isFinite else {
            throw IsenoughError.usage("invalid size: \(raw)")
        }
        guard unit.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw IsenoughError.usage("invalid size: \(raw)")
        }
        let scale: Double
        switch unit.lowercased() {
        case "":
            guard dots == 0 else { throw IsenoughError.usage("invalid size: \(raw)") }
            scale = 1
        case "k", "kib": scale = 1024
        case "kb": scale = 1_000
        case "m", "mib": scale = 1024 * 1024
        case "mb": scale = 1_000_000
        case "g", "gib": scale = 1024 * 1024 * 1024
        case "gb": scale = 1_000_000_000
        default:
            throw IsenoughError.usage("invalid size: \(raw)")
        }
        let bytes = value * scale
        guard bytes <= Double(UInt64.max) else { throw IsenoughError.usage("invalid size: \(raw)") }
        return UInt64(bytes)
    }

    private static func parseCount(_ raw: String, name: String) throws -> Int {
        guard let value = Int(raw), value >= 0 else { throw IsenoughError.usage("invalid \(name): \(raw)") }
        return value
    }
}

public struct DirectoryAllocation: Equatable {
    public var bytes: UInt64
    public var incomplete: Bool
    public init(bytes: UInt64, incomplete: Bool) {
        self.bytes = bytes
        self.incomplete = incomplete
    }
}

public enum DirectoryMeasure {
    /// Sum of allocated blocks (`st_blocks * 512`), counting each inode once and not
    /// following symlinks. `now` is injectable so the deadline is testable.
    public static func allocatedBytes(at root: URL, deadline: Date, now: @escaping () -> Date = Date.init) -> DirectoryAllocation {
        var bytes: UInt64 = 0
        var incomplete = false
        var seen = Set<String>()
        func visit(_ url: URL) {
            if incomplete || now() >= deadline {
                incomplete = true
                return
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return }
            let key = "\(info.st_dev):\(info.st_ino)"
            if seen.contains(key) { return }
            seen.insert(key)
            let kind = info.st_mode & S_IFMT
            if info.st_blocks > 0 {
                bytes += UInt64(info.st_blocks) * 512
            }
            guard kind == S_IFDIR else { return }
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) else { return }
            for child in children {
                if incomplete || now() >= deadline {
                    incomplete = true
                    return
                }
                visit(child)
            }
        }
        visit(root)
        return DirectoryAllocation(bytes: bytes, incomplete: incomplete)
    }
}

public enum RecommendPaths {
    /// Hidden entries are not apps to offload. Kept originals (`Foo.256orig.app`)
    /// and `.isenough-original-` backups are not apps either, even when the name
    /// has no leading dot.
    public static func isIgnoredAppName(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return isLeftoverBackupName(name)
    }

    /// Engine leftovers in an Applications directory. Ordinary hidden files
    /// (`.DS_Store`, a user-hidden `.app`) are not leftovers.
    public static func isLeftoverBackupName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".isenough-original-") { return true }
        if lower.hasSuffix(".256orig.app") { return true }
        if lower == ".256isenough-staging" { return true }
        if lower.hasPrefix(".isenough-") && lower.hasSuffix(".app") { return true }
        return false
    }

    public static func isSystemLocation(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let candidates = [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path,
        ]
        return candidates.contains { $0 == "/System" || $0.hasPrefix("/System/") }
    }

    public static func topLevelApps(in root: URL, fileManager: FileManager = .default) -> [URL] {
        children(in: root, fileManager: fileManager).filter { url in
            url.pathExtension.lowercased() == "app" && !isIgnoredAppName(url.lastPathComponent)
        }
    }

    public static func leftoverBackups(in root: URL, fileManager: FileManager = .default) -> [URL] {
        children(in: root, fileManager: fileManager).filter { isLeftoverBackupName($0.lastPathComponent) }
    }

    private static func children(in root: URL, fileManager: FileManager) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else { return [] }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum RecommendToolchain {
    public static let bundleIds: Set<String> = ["com.apple.dt.Xcode"]

    public static func matches(bundleId: String, bundlePath: String, developerDirectories: [String]) -> Bool {
        if bundleIds.contains(bundleId) { return true }
        let root = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for directory in developerDirectories {
            let path = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
            if path == root || path.hasPrefix(prefix) { return true }
        }
        return false
    }
}

public struct RecommendCatalog: Equatable {
    public var pinnedBundleIds: Set<String>
    public var packedBundleIds: Set<String>
    public var packedPaths: Set<String>

    public init(pinnedBundleIds: Set<String> = [], packedBundleIds: Set<String> = [], packedPaths: Set<String> = []) {
        self.pinnedBundleIds = pinnedBundleIds
        self.packedBundleIds = packedBundleIds
        self.packedPaths = packedPaths
    }

    public func isPinned(_ bundleId: String) -> Bool { pinnedBundleIds.contains(bundleId) }

    public func isPacked(bundleId: String, path: String) -> Bool {
        if packedBundleIds.contains(bundleId) { return true }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return packedPaths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == standard }
    }
}

/// Facts the directory walk cannot see on its own: Spotlight, processes, and signing.
/// The macOS command fills these in. Tests pass plain values.
/// `legacyLoginItem` is an extra injected signal. The live scan leaves it false.
/// Bundled LoginItems, LaunchAgents, and LaunchDaemons, and external launchd
/// plists whose program is inside the app, are detected without it.
public struct RecommendEnvironment {
    public var available: Bool
    public var roots: [URL]
    public var launchAgentDirectories: [URL]
    public var developerDirectories: [String]
    public var runningPaths: [String]
    public var lastUsed: (String) -> Date?
    public var appleSystemSigned: (URL) -> Bool
    public var legacyLoginItem: (URL) -> Bool
    public var sizeTimeout: TimeInterval
    public var scanDeadline: Date
    public var now: Date

    public init(available: Bool = true, roots: [URL], launchAgentDirectories: [URL] = [], developerDirectories: [String] = [], runningPaths: [String] = [], lastUsed: @escaping (String) -> Date? = { _ in nil }, appleSystemSigned: @escaping (URL) -> Bool = { _ in false }, legacyLoginItem: @escaping (URL) -> Bool = { _ in false }, sizeTimeout: TimeInterval = RecommendLimits.sizeTimeout, scanDeadline: Date = Date().addingTimeInterval(RecommendLimits.scanTimeout), now: Date = Date()) {
        self.available = available
        self.roots = roots
        self.launchAgentDirectories = launchAgentDirectories
        self.developerDirectories = developerDirectories
        self.runningPaths = runningPaths
        self.lastUsed = lastUsed
        self.appleSystemSigned = appleSystemSigned
        self.legacyLoginItem = legacyLoginItem
        self.sizeTimeout = sizeTimeout
        self.scanDeadline = scanDeadline
        self.now = now
    }

    public static var unavailable: RecommendEnvironment {
        RecommendEnvironment(available: false, roots: [], scanDeadline: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 0))
    }
}

public enum RecommendDiscovery {
    public static func collect(environment: RecommendEnvironment, catalog: RecommendCatalog = RecommendCatalog(), fileManager: FileManager = .default) -> [RecommendApp] {
        guard environment.available else { return [] }
        let running = environment.runningPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var apps: [RecommendApp] = []
        for root in environment.roots {
            for url in RecommendPaths.topLevelApps(in: root, fileManager: fileManager) {
                if let app = inspect(url, environment: environment, catalog: catalog, running: running, fileManager: fileManager) {
                    apps.append(app)
                }
            }
        }
        return apps
    }

    /// Sizes use the same deadline as the app walk. An expired deadline still lists the path.
    public static func leftovers(environment: RecommendEnvironment, fileManager: FileManager = .default) -> [RecommendLeftover] {
        guard environment.available else { return [] }
        var found: [RecommendLeftover] = []
        for root in environment.roots {
            for url in RecommendPaths.leftoverBackups(in: root, fileManager: fileManager) {
                let allocation = measure(url, environment: environment)
                found.append(RecommendLeftover(path: url.standardizedFileURL.path, sizeBytes: allocation.bytes, sizeIncomplete: allocation.incomplete))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func inspect(_ url: URL, environment: RecommendEnvironment, catalog: RecommendCatalog, running: [String], fileManager: FileManager) -> RecommendApp? {
        guard let info = BundleFacts.readInfo(url), let bundleId = info["CFBundleIdentifier"] as? String, !bundleId.isEmpty else { return nil }
        let executable = info["CFBundleExecutable"] as? String ?? ""
        let path = url.standardizedFileURL.path
        let name = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let stubJSON = fileManager.fileExists(atPath: url.appendingPathComponent("Contents/Resources/stub.json").path)
        let stub = bundleId.hasSuffix(".256stub") || executable == "isenough-stub" || stubJSON
        let product = bundleId == "io.github.s546126.256isenough" || bundleId.hasPrefix("io.github.s546126.256isenough.")
        let system = RecommendPaths.isSystemLocation(path)
        let measureAt = system ? url : url.resolvingSymlinksInPath()
        let allocation = measure(measureAt, environment: environment)
        let mainPath = executable.isEmpty ? nil : url.appendingPathComponent("Contents/MacOS/\(executable)").standardizedFileURL.path
        var appRunning = false
        var helperRunning = false
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for process in running {
            if let mainPath, process == mainPath {
                appRunning = true
                continue
            }
            if process == path || process.hasPrefix(prefix) {
                helperRunning = true
            }
        }
        let loginBundle = bundledBackground(url, fileManager: fileManager) || launchAgentsReference(path, directories: environment.launchAgentDirectories)
        let login = loginBundle || environment.legacyLoginItem(url)
        return RecommendApp(
            path: path,
            name: name,
            bundleId: bundleId,
            sizeBytes: allocation.bytes,
            sizeIncomplete: allocation.incomplete,
            lastUsed: environment.lastUsed(path),
            macAppStore: fileManager.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            pinned: catalog.isPinned(bundleId),
            packed: catalog.isPacked(bundleId: bundleId, path: path),
            running: appRunning,
            stub: stub,
            isenoughProduct: product,
            systemLocation: system,
            appleSystemSigned: environment.appleSystemSigned(url),
            loginItem: login,
            menuBarAgent: plistFlag(info["LSUIElement"]) || plistFlag(info["LSBackgroundOnly"]),
            backgroundHelperRunning: helperRunning,
            systemExtension: hasChildExtension(url.appendingPathComponent("Contents/Library/SystemExtensions"), suffixes: ["systemextension", "dext"], fileManager: fileManager),
            kernelExtension: hasChildExtension(url.appendingPathComponent("Contents/Library/Extensions"), suffixes: ["kext"], fileManager: fileManager),
            toolchain: RecommendToolchain.matches(bundleId: bundleId, bundlePath: path, developerDirectories: environment.developerDirectories)
        )
    }

    private static func measure(_ url: URL, environment: RecommendEnvironment) -> DirectoryAllocation {
        if Date() >= environment.scanDeadline {
            return DirectoryAllocation(bytes: 0, incomplete: true)
        }
        let deadline = min(Date().addingTimeInterval(environment.sizeTimeout), environment.scanDeadline)
        return DirectoryMeasure.allocatedBytes(at: url, deadline: deadline)
    }

    private static func plistFlag(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as Int: return number != 0
        case let number as NSNumber: return number.boolValue
        case let text as String:
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        default: return false
        }
    }

    private static func bundledBackground(_ app: URL, fileManager: FileManager) -> Bool {
        let relatives = ["Contents/Library/LoginItems", "Contents/Library/LaunchAgents", "Contents/Library/LaunchDaemons"]
        return relatives.contains { relative in
            let directory = app.appendingPathComponent(relative)
            guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
            return !children.isEmpty
        }
    }

    private static func hasChildExtension(_ directory: URL, suffixes: Set<String>, fileManager: FileManager) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        return children.contains { suffixes.contains($0.pathExtension.lowercased()) }
    }

    private static func launchAgentsReference(_ appPath: String, directories: [URL]) -> Bool {
        let root = URL(fileURLWithPath: appPath).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                var candidates: [String] = []
                if let program = plist["Program"] as? String { candidates.append(program) }
                if let args = plist["ProgramArguments"] as? [String] { candidates.append(contentsOf: args) }
                for candidate in candidates {
                    let path = URL(fileURLWithPath: candidate).standardizedFileURL.path
                    if path == root || path.hasPrefix(prefix) { return true }
                }
            }
        }
        return false
    }
}
