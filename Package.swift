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
    name: "Disklessly",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DisklesslyCore", targets: ["DisklesslyCore"]),
        .library(name: "DisklesslyEngine", targets: ["DisklesslyEngine"]),
        .executable(name: "disklessly", targets: ["disklessly"]),
        .executable(name: "disklessly-stub", targets: ["disklessly-stub"]),
        // Menu-bar app. Its sources compile to a stub on platforms without AppKit.
        .executable(name: "DisklesslyMac", targets: ["DisklesslyMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.6"),
    ],
    targets: [
        .target(name: "DisklesslyCore"),
        .target(name: "DisklesslyStubSupport"),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: sqlitePkgConfig, providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]),
        .target(name: "DisklesslySessions", dependencies: [
            "DisklesslyCore",
            "CSQLite",
            .product(name: "libzstd", package: "zstd"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "DisklesslyEngine", dependencies: ["DisklesslyCore", "DisklesslyStubSupport", "DisklesslySessions"]),
        .executableTarget(name: "disklessly", dependencies: ["DisklesslyCore", "DisklesslyEngine"], resources: [.copy("web")]),
        .executableTarget(name: "disklessly-stub", dependencies: ["DisklesslyStubSupport"]),
        .executableTarget(name: "DisklesslyMac", dependencies: ["DisklesslyCore", "DisklesslyEngine"]),
        .testTarget(name: "DisklesslyCoreTests", dependencies: ["DisklesslyCore", "DisklesslyEngine", "DisklesslyStubSupport", "DisklesslySessions"]),
    ]
)
