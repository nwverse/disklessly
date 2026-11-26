#if canImport(Darwin)
import XCTest
import Darwin
import DisklesslyCore
@testable import DisklesslyEngine

/// Streaming reads return autoreleased buffers. In a long loop on a background thread with no
/// autorelease pool they are never freed, so a 32 GB folder offload held ~19 GB of memory.
final class StreamingMemoryTests: XCTestCase {
    private func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return Int(info.resident_size >> 20)
    }

    func testChunkedFolderUploadDoesNotHoldTheStreamInMemory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("stream-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("src"), repo = base.appendingPathComponent("repo"), cache = base.appendingPathComponent("cache")
        for d in [folder, repo, cache] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        // Random bytes so zstd cannot shrink them: 600 MB goes through every read loop.
        let dd = Process()
        dd.executableURL = URL(fileURLWithPath: "/bin/dd")
        dd.arguments = ["if=/dev/urandom", "of=\(folder.appendingPathComponent("blob").path)", "bs=1m", "count=600"]
        dd.standardError = FileHandle.nullDevice
        try dd.run(); dd.waitUntilExit()

        let backend = try LocalFolderBackend(root: repo)
        let before = residentMB()
        var peak = before
        let config = ChunkedTransferConfig(streams: 2, chunkSize: 16 * 1024 * 1024, thresholdBytes: 1, forceChunks: true)
        _ = try ChunkedTransfer.uploadFolder(folder, expectedLogicalBytes: 600 << 20, backend: backend, cacheDir: cache.path, minFreeBytes: 0, config: config) { _, _ in
            peak = max(peak, self.residentMB())
        }
        peak = max(peak, residentMB())
        XCTAssertLessThan(peak - before, 250, "resident grew from \(before) MB to \(peak) MB")
    }
}
#endif
