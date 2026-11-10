import Foundation

/// The OS this build targets. Tests pass a value to check the other platform's rules.
public enum HostPlatform: String, Equatable {
    case macOS = "macos"
    case linux

    public static var current: HostPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .linux
        #endif
    }

    /// Offloading apps needs app bundles, disk images, codesign, and LaunchServices.
    public var offloadsApps: Bool { self == .macOS }
}

/// Which CLI commands run where. On Linux only the parts that do not touch app
/// bundles or disk images are available; see docs/linux.md.
public enum PlatformCommands {
    /// Commands a Linux build runs. `hooks` is the hidden placeholder kept for old scripts.
    public static let linux: Set<String> = [
        "help", "--help", "-h", "version", "init", "list", "status",
        "sessions", "ui", "backend", "repo", "devices", "license", "hooks", "remote",
    ]

    /// Commands that exist but only on macOS. Anything else is an unknown command.
    public static let macOSOnly: Set<String> = [
        "pack", "launch", "restore", "unpack", "recommend", "prefetch", "pin", "unpin",
        "evict", "detach", "reap", "evict-local", "cleanup-backups", "gc", "doctor",
        "hook", "resolve", "icons", "install-engine", "stub",
    ]

    /// The refusal for `command` on `platform`, or nil when it may run (or is unknown).
    public static func refusal(_ command: String, on platform: HostPlatform) -> DisklesslyError? {
        guard platform != .macOS, macOSOnly.contains(command) else { return nil }
        return .unsupported("\(command) is macOS only. On Linux disklessly offers sessions, ui, backend, repo, devices, license, init, list, status, and version; see docs/linux.md")
    }
}
