import Foundation
import IsenoughCore

/// Live scan inputs. Directory walking and scoring stay in IsenoughCore.
/// Spotlight, process listing, and the Apple system signature check exist only
/// on macOS and are not text scraped from tools. Login items are read from
/// bundled LoginItems and launchd directories, plus LaunchAgent and
/// LaunchDaemon plists, in IsenoughCore. `SMAppService` is not imported:
/// `statusForLegacyURL` and `statusForLegacyPlist(at:)` are not both present
/// in one SDK, so neither name is called.
enum LiveRecommendScan {
    static func environment(home: String, now: Date = Date()) -> RecommendEnvironment {
        #if os(macOS)
        return macOSEnvironment(home: home, now: now)
        #else
        _ = home
        _ = now
        return .unavailable
        #endif
    }

    #if os(macOS)
    private static func macOSEnvironment(home: String, now: Date) -> RecommendEnvironment {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        return RecommendEnvironment(
            available: true,
            roots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                homeURL.appendingPathComponent("Applications", isDirectory: true),
            ],
            launchAgentDirectories: [
                homeURL.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
            ],
            developerDirectories: MacRecommendProbes.developerDirectories(),
            runningPaths: MacRecommendProbes.runningPaths(),
            lastUsed: { MacRecommendProbes.lastUsedDate(path: $0) },
            appleSystemSigned: { MacRecommendProbes.isAppleSystemSigned($0) },
            sizeTimeout: RecommendLimits.sizeTimeout,
            scanDeadline: now.addingTimeInterval(RecommendLimits.scanTimeout),
            now: now
        )
    }
    #endif
}

#if os(macOS)
import Darwin
import Security

enum MacRecommendProbes {
    /// `kMDItemLastUsedDate` through `NSMetadataItem`, which reads the same Spotlight
    /// attribute as `MDItemCopyAttribute`. A missing item or a null attribute is never used.
    /// `mdls` text is locale-dependent and is not read.
    static func lastUsedDate(path: String) -> Date? {
        guard let item = NSMetadataItem(url: URL(fileURLWithPath: path)) else { return nil }
        return item.value(forAttribute: "kMDItemLastUsedDate") as? Date
    }

    /// `anchor apple` is "signed by Apple as Apple code" (macOS system apps).
    /// `anchor apple generic` is any Apple-issued identity, including Developer ID
    /// and the Mac App Store, and those apps stay eligible. The designated
    /// requirement is read as a requirement string; `codesign` output is not parsed.
    static func isAppleSystemSigned(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return false }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return false }
        let value = text as String
        if value.contains("anchor apple generic") { return false }
        return value.contains("anchor apple")
    }

    static func runningPaths() -> [String] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let count = Int(needed) / MemoryLayout<pid_t>.size + 16
        var pids = [pid_t](repeating: 0, count: count)
        let written = pids.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_listpids(UInt32(PROC_ALL_PIDS), 0, base, Int32(buffer.count))
        }
        guard written > 0 else { return [] }
        let used = min(pids.count, Int(written) / MemoryLayout<pid_t>.size)
        var paths: [String] = []
        paths.reserveCapacity(used)
        for pid in pids.prefix(used) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return 0 }
                return proc_pidpath(pid, base, UInt32(raw.count))
            }
            if length > 0 {
                paths.append(String(cString: buffer))
            }
        }
        return paths
    }

    /// Paths that mean "this app is the toolchain", without reading tool prose.
    /// The developer directory is the `xcode-select` symlink target plus `DEVELOPER_DIR`.
    static func developerDirectories() -> [String] {
        var paths: [String] = []
        let link = URL(fileURLWithPath: "/var/db/xcode_select_link")
        if FileManager.default.fileExists(atPath: link.path) {
            paths.append(link.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !developer.isEmpty {
            paths.append(URL(fileURLWithPath: developer).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        if let executable = CommandLine.arguments.first, !executable.isEmpty {
            paths.append(URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        if let bundled = Bundle.main.executableURL {
            paths.append(bundled.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        return paths
    }
}
#endif
