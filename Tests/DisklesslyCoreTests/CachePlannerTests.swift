import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class CachePlannerTests: XCTestCase {
    private func item(_ id: String, bytes: UInt64, lastUsed: Date?, pinned: Bool = false, mounted: Bool = false, inUse: Bool = false, protectedUntil: Date? = nil, needsResolution: Bool = false, justUsed: Bool = false) -> CacheItem {
        CacheItem(imageId: id, bytes: bytes, lastUsed: lastUsed, pinned: pinned, mounted: mounted, inUse: inUse, protectedUntil: protectedUntil, needsResolution: needsResolution, justUsed: justUsed)
    }

    func testLRUOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            item("c", bytes: 10, lastUsed: now.addingTimeInterval(-10)),
            item("a", bytes: 10, lastUsed: now.addingTimeInterval(-300)),
            item("b", bytes: 10, lastUsed: now.addingTimeInterval(-200)),
        ]
        let plan = CachePlanner.planEviction(items, leftovers: [], quota: 10, now: now)
        XCTAssertEqual(plan.victims, ["a", "b"])
        XCTAssertEqual(plan.freed, 20)
        XCTAssertEqual(plan.shortBy, 0)
    }

    func testNeverEvictsPinnedMountedInUse() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            item("pin", bytes: 10, lastUsed: now, pinned: true),
            item("mnt", bytes: 10, lastUsed: now, mounted: true),
            item("use", bytes: 10, lastUsed: now, inUse: true),
            item("prot", bytes: 10, lastUsed: now, protectedUntil: now.addingTimeInterval(60)),
            item("res", bytes: 10, lastUsed: now, needsResolution: true),
        ]
        let plan = CachePlanner.planEviction(items, leftovers: [], quota: 1, now: now)
        XCTAssertEqual(plan.victims, [])
        XCTAssertGreaterThan(plan.shortBy, 0)
        XCTAssertEqual(plan.skipped["pin"], "pinned")
        XCTAssertEqual(plan.skipped["mnt"], "mounted")
        XCTAssertEqual(plan.skipped["use"], "inUse")
        XCTAssertEqual(plan.skipped["prot"], "protectedUntil")
        XCTAssertEqual(plan.skipped["res"], "needsResolution")
    }

    func testJustUsedKeptUnlessAlone() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let kept = CachePlanner.planEviction([
            item("old", bytes: 30, lastUsed: now.addingTimeInterval(-100)),
            item("fresh", bytes: 10, lastUsed: now, justUsed: true),
        ], leftovers: [], quota: 10, now: now)
        XCTAssertEqual(kept.victims, ["old"])
        XCTAssertFalse(kept.victims.contains("fresh"))
        XCTAssertEqual(kept.shortBy, 0)

        let alone = CachePlanner.planEviction([
            item("fresh", bytes: 100, lastUsed: now, justUsed: true),
        ], leftovers: [], quota: 10, now: now)
        XCTAssertEqual(alone.victims, [])
        XCTAssertEqual(alone.skipped["fresh"], "alone exceeds quota")
        XCTAssertEqual(alone.shortBy, 90)

        let stillTooBig = CachePlanner.planEviction([
            item("old", bytes: 40, lastUsed: now.addingTimeInterval(-50)),
            item("fresh", bytes: 80, lastUsed: now, justUsed: true),
        ], leftovers: [], quota: 50, now: now)
        XCTAssertEqual(stillTooBig.victims, ["old"])
        XCTAssertEqual(stillTooBig.skipped["fresh"], "alone exceeds quota")
        XCTAssertEqual(stillTooBig.shortBy, 30)
    }

    func testLeftoversFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = CachePlanner.planEviction(
            [item("keep", bytes: 10, lastUsed: now.addingTimeInterval(-10))],
            leftovers: [(path: "partial/stale.dmg", bytes: 8), (path: "bad/broken.dmg", bytes: 4)],
            quota: 10,
            now: now
        )
        XCTAssertEqual(plan.victims, ["partial/stale.dmg", "bad/broken.dmg"])
        XCTAssertEqual(plan.freed, 12)
        XCTAssertFalse(plan.victims.contains("keep"))
    }

    func testEnforceSkipsLockedVictim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-lru-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = RuntimeConfig(
            repoPath: root.appendingPathComponent("repo").path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mnt").path,
            stubDir: root.appendingPathComponent("apps").path
        )
        config.quotaBytes = 1
        let engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        let id = "img-locked"
        let images = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let dmg = images.appendingPathComponent("\(id).dmg")
        try Data(repeating: 0x61, count: 8192).write(to: dmg)
        try StateStore(config.stateDir).setAppState(bundleId: "com.example.locked", imageId: id, state: "cached")
        let lockDir = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/app")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        var held = FileLock(path: lockDir.appendingPathComponent("com.example.locked.lock").path)
        XCTAssertTrue(try held.tryLock())
        defer { held.unlock() }
        let result = try engine.enforceCacheQuota(justUsed: nil)
        XCTAssertTrue(result.plan.victims.contains(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dmg.path))
        XCTAssertFalse(result.lines.contains { $0.contains("evicted cache \(id)") })
    }
}
