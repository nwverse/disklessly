// swift-tools-version: 5.9
import PackageDescription

// On macOS link the SDK's libsqlite3. Through pkg-config SwiftPM would pick up
// Homebrew's dylib, and a release binary would then fail on Macs without it.
#if os(macOS)
let sqlitePkgConfig: String? = nil
#else
let sqlitePkgConfig: String? = "sqlite3"
#endif

let package = Package(
    name: "256isenough",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IsenoughCore", targets: ["IsenoughCore"]),
        .library(name: "IsenoughEngine", targets: ["IsenoughEngine"]),
        .executable(name: "isenough", targets: ["isenough"]),
        .executable(name: "isenough-stub", targets: ["isenough-stub"]),
        // Menu-bar app. Its sources compile to a stub on platforms without AppKit.
        .executable(name: "IsenoughMac", targets: ["IsenoughMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.6"),
    ],
    targets: [
        .target(name: "IsenoughCore"),
        .target(name: "IsenoughStubSupport"),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: sqlitePkgConfig, providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]),
        .target(name: "IsenoughSessions", dependencies: [
            "IsenoughCore",
            "CSQLite",
            .product(name: "libzstd", package: "zstd"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "IsenoughEngine", dependencies: ["IsenoughCore", "IsenoughStubSupport", "IsenoughSessions"]),
        .executableTarget(name: "isenough", dependencies: ["IsenoughCore", "IsenoughEngine"], resources: [.copy("web")]),
        .executableTarget(name: "isenough-stub", dependencies: ["IsenoughStubSupport"]),
        .executableTarget(name: "IsenoughMac", dependencies: ["IsenoughCore", "IsenoughEngine"]),
        .testTarget(name: "IsenoughCoreTests", dependencies: ["IsenoughCore", "IsenoughEngine", "IsenoughStubSupport", "IsenoughSessions"]),
    ]
)
