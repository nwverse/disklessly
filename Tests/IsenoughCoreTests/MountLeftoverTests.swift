import XCTest
@testable import IsenoughCore
@testable import IsenoughEngine

/// Detach (notably `diskutil image detach`) can leave an empty mount folder
/// behind. That folder must not count as "mounted" or "in use".
final class MountLeftoverTests: XCTestCase {
    func testEmptyMountFolderIsNotAnActiveMount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isenough-mount-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mountRoot = root.appendingPathComponent("mnt")
        let leftover = mountRoot.appendingPathComponent("app-1.0-abc")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        XCTAssertFalse(IsenoughEngine.isActiveMountPoint(leftover.path))
        XCTAssertFalse(IsenoughEngine.isActiveMountPoint(mountRoot.appendingPathComponent("missing").path))
        // A real mount point sits on another device than its parent.
        XCTAssertTrue(IsenoughEngine.isActiveMountPoint("/dev"))

        let config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: mountRoot.path, stubDir: root.appendingPathComponent("stubs").path)
        let usage = LiveMaterialProbe.usageMap(config: config, now: Date())
        XCTAssertFalse(usage.inUse.contains("app-1.0-abc"))
    }
}
