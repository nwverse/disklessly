import Foundation
#if os(macOS)
import Security
#endif

/// The macOS privacy permissions Disklessly asks for, and how to tell whether this process has them.
public enum MacPermission: String, CaseIterable {
    /// Replacing other developers' apps in /Applications with stubs and back (pack, unpack, restore).
    case appManagement
    /// Reading protected folders: other apps' containers for the usage map, and an iCloud repo
    /// that otherwise can block without a prompt.
    case fullDiskAccess

    public var required: Bool { self == .appManagement }

    /// The System Settings pane for this permission (Privacy & Security).
    public var settingsURLs: [URL] {
        let anchor = self == .appManagement ? "Privacy_AppBundles" : "Privacy_AllFiles"
        return [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ].compactMap(URL.init(string:))
    }
}

public enum PermissionState: String {
    case granted, denied
    /// No way to test it here (for example no third-party app is installed to probe App Management).
    case unknown
}

public enum PermissionProbe {
    /// Full Disk Access: the user's TCC database is readable only with it. Reading it changes nothing
    /// and shows no prompt, so this can run often.
    ///
    /// Several protected files are tried in turn, because a given one may not exist: macOS 27 has
    /// no per-user TCC.db at the old path. The first file that exists decides.
    public static func fullDiskAccess(home: String = NSHomeDirectory()) -> PermissionState {
        fullDiskAccess(candidates: fullDiskAccessCandidates(home: home))
    }

    static func fullDiskAccessCandidates(home: String) -> [String] {
        [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Messages/chat.db",
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ]
    }

    static func fullDiskAccess(candidates: [String]) -> PermissionState {
        for path in candidates {
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            let code = errno
            if fd >= 0 { close(fd); return .granted }
            if code == EPERM || code == EACCES { probeLog("fullDiskAccess denied at \(path)"); return .denied }
        }
        return .unknown
    }

    /// App Management: opening a file inside another developer's app for writing is refused with
    /// EPERM without it. The file is opened for append and closed again; nothing is written.
    /// A refusal can make macOS show a notification, so callers run this on demand, not on a timer.
    public static func appManagement(applications: [String] = ["/Applications"], ownTeamId: String? = ownTeamIdentifier()) -> PermissionState {
        for target in appManagementTargets(applications: applications, ownTeamId: ownTeamId, teamId: teamIdentifier(ofBundle:)) {
            let fd = open(target, O_WRONLY | O_APPEND | O_NONBLOCK)
            let code = errno
            if fd >= 0 { close(fd); probeLog("appManagement granted via \(target)"); return .granted }
            probeLog("appManagement open \(target): errno \(code)")
            if code == EPERM { return .denied }
        }
        probeLog("appManagement unknown: no probe target")
        return .unknown
    }

    /// Files the App Management probe may open: `Contents/Info.plist` of apps we can write to by
    /// POSIX permissions (so only TCC can refuse) that another developer team signed.
    /// Ad-hoc signed apps and our own stubs are not protected by App Management, so they prove nothing.
    static func appManagementTargets(applications: [String], ownTeamId: String?, teamId: (String) -> String?, limit: Int = 3) -> [String] {
        var out: [String] = []
        for folder in applications {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            for name in names where name.hasSuffix(".app") && !name.hasPrefix(".") {
                let bundle = folder + "/" + name
                let plist = bundle + "/Contents/Info.plist"
                guard access(plist, W_OK) == 0, let team = teamId(bundle), team != ownTeamId else { continue }
                out.append(plist)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Probe results go to the unified log (`log show --predicate 'eventMessage CONTAINS "disklessly permission"'`),
    /// so a wrong answer inside the app can be traced to the file it tried.
    static func probeLog(_ message: String) {
        #if os(macOS)
        NSLog("disklessly permission: %@", message)
        #endif
    }

    public static func current() -> [MacPermission: PermissionState] {
        [.appManagement: appManagement(), .fullDiskAccess: fullDiskAccess()]
    }

    #if os(macOS)
    static func teamIdentifier(ofBundle path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func ownTeamIdentifier() -> String? {
        teamIdentifier(ofBundle: Bundle.main.bundlePath)
    }
    #else
    static func teamIdentifier(ofBundle path: String) -> String? { nil }
    public static func ownTeamIdentifier() -> String? { nil }
    #endif
}
