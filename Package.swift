// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "256isenough",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IsenoughCore", targets: ["IsenoughCore"]),
        .library(name: "IsenoughEngine", targets: ["IsenoughEngine"]),
        .executable(name: "isenough", targets: ["isenough"]),
        .executable(name: "isenough-stub", targets: ["isenough-stub"]),
    ],
    targets: [
        .target(name: "IsenoughCore"),
        .target(name: "IsenoughStubSupport"),
        .target(name: "IsenoughEngine", dependencies: ["IsenoughCore", "IsenoughStubSupport"]),
        .executableTarget(name: "isenough", dependencies: ["IsenoughCore", "IsenoughEngine"], resources: [.copy("web")]),
        .executableTarget(name: "isenough-stub", dependencies: ["IsenoughStubSupport"]),
        .testTarget(name: "IsenoughCoreTests", dependencies: ["IsenoughCore", "IsenoughEngine", "IsenoughStubSupport"]),
    ]
)
