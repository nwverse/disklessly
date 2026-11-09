import Foundation
import DisklesslyCore

/// Every folder on disk that Disklessly knows by name, in one place. Scans, cleanups and the
/// usage map read their paths from here instead of spelling them out. Adding a tool is one row.
///
/// Only well-known tool and system locations belong here: nothing that is specific to one
/// person's Mac (a project folder, a backup someone made).
public enum KnownLocations {
    // MARK: Xcode and simulators

    /// Xcode's build cache. Xcode rebuilds it.
    public static let derivedData = "Library/Developer/Xcode/DerivedData"
    /// Simulator devices of the current user.
    public static let simulatorDevices = "Library/Developer/CoreSimulator/Devices"
    /// Simulator runtimes, system-wide (absolute).
    public static let simulatorRuntimes = "/Library/Developer/CoreSimulator"

    /// The folder directly in ~/Library/Developer that holds `relativePath` ("Xcode", "CoreSimulator").
    static func developerFolder(of relativePath: String) -> String {
        String(relativePath.dropFirst("Library/Developer/".count).split(separator: "/").first ?? "")
    }

    // MARK: Homebrew

    public static let homebrewDownloads = "Library/Caches/Homebrew"
    public static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]
    public static let brewExecutables = homebrewPrefixes.map { $0 + "/bin/brew" }

    // MARK: Folders whose contents their own tool downloads or builds again

    /// Removing the contents is safe whenever the tool is not running; the next build or
    /// install is slower once. `BigItems.clean` empties them; the folder itself stays.
    public static let rebuildableCaches: [RebuildableCache] = [
        RebuildableCache(id: "cache-go-build", title: "Go build cache", relativePath: "Library/Caches/go-build"),
        RebuildableCache(id: "cache-playwright", title: "Playwright browsers", relativePath: "Library/Caches/ms-playwright"),
        RebuildableCache(id: "cache-pip", title: "pip cache", relativePath: "Library/Caches/pip"),
        RebuildableCache(id: "cache-yarn", title: "Yarn cache", relativePath: "Library/Caches/Yarn"),
        RebuildableCache(id: "cache-pnpm", title: "pnpm store", relativePath: "Library/pnpm/store"),
        RebuildableCache(id: "cache-npm", title: "npm cache", relativePath: ".npm/_cacache"),
        RebuildableCache(id: "cache-gradle", title: "Gradle caches", relativePath: ".gradle/caches"),
        RebuildableCache(id: "cache-cocoapods", title: "CocoaPods cache", relativePath: "Library/Caches/CocoaPods"),
        RebuildableCache(id: "cache-swiftpm", title: "SwiftPM cache", relativePath: "Library/Caches/org.swift.swiftpm"),
        RebuildableCache(id: "cache-uv", title: "uv cache", relativePath: ".cache/uv"),
        RebuildableCache(id: "cache-camoufox", title: "Camoufox browser", relativePath: "Library/Caches/camoufox"),
        // Symbols copied from each connected iPhone or iPad; Xcode copies them again on the next connect.
        RebuildableCache(id: "cache-ios-devicesupport", title: "Xcode iOS device support", relativePath: "Library/Developer/Xcode/iOS DeviceSupport"),
    ]

    /// Folders an app downloads again when it needs them, but which it may be using while it
    /// runs, so they are only offered for review (offload or delete after quitting the app).
    public struct Redownloadable: Equatable {
        public var id: String
        /// Page string key for the title and `bigReason_<id>` for the explanation.
        public var titleKey: String
        public var title: String
        public var relativePath: String
    }

    public static let redownloadable: [Redownloadable] = [
        // The Linux VM image Claude desktop downloads for its sandbox.
        Redownloadable(id: "claude-vm-bundles", titleKey: "loc_claudeVmBundles", title: "Claude VM bundles",
                       relativePath: "Library/Application Support/Claude/vm_bundles"),
    ]

    // MARK: Folders not listed as app data

    /// iCloud Drive's own store: it holds the iCloud repo's local copies, and offloading from it
    /// would fight iCloud.
    static let iCloudFolders = ["CloudDocs", "com.apple.bird"]
    /// Names Disklessly used before the rename.
    static let legacyStateFolders = ["256isenough"]

    /// Folder names under ~/Library/{Application Support, Containers, Group Containers} that the
    /// big items do not list as app data: Disklessly's own folders, iCloud's store, and container
    /// engines' data (the containers section lists the images inside).
    static func notAppData(home: String, config: RuntimeConfig) -> Set<String> {
        var names = Set(iCloudFolders + legacyStateFolders + ["Disklessly"])
        for path in [config.stateDir, config.cacheDir] { names.insert(URL(fileURLWithPath: path).lastPathComponent) }
        let library = home + "/Library/"
        for endpoint in ContainerEndpoint.all(home: home) {
            for path in endpoint.dataPaths where path.hasPrefix(library) {
                // ~/Library/<parent>/<name>/...: the folder the big items would list is <name>.
                let parts = path.dropFirst(library.count).split(separator: "/")
                if parts.count >= 2 { names.insert(String(parts[1])) }
            }
        }
        return names
    }
}
