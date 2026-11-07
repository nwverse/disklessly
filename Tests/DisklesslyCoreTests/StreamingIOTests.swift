import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import DisklesslyCore
import DisklesslyEngine

final class StreamingIOTests: XCTestCase {
    func testNeedsDownloadOnlyForEvictedUbiquitousItems() {
        XCTAssertFalse(UbiquitousMaterializer.needsDownload(isUbiquitous: false, status: nil))
        XCTAssertFalse(UbiquitousMaterializer.needsDownload(isUbiquitous: true, status: "current"))
        XCTAssertFalse(UbiquitousMaterializer.needsDownload(isUbiquitous: true, status: "downloaded"))
        XCTAssertTrue(UbiquitousMaterializer.needsDownload(isUbiquitous: true, status: "notDownloaded"))
        XCTAssertTrue(UbiquitousMaterializer.needsDownload(isUbiquitous: true, status: nil))
    }

    func testICloudPathsAndBoundedListing() throws {
        let cloud = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Disklessly")
        XCTAssertTrue(ICloudFolderBackend.looksLikeICloud(cloud))
        XCTAssertFalse(ICloudFolderBackend.looksLikeICloud(URL(fileURLWithPath: "/tmp/repo")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = BackendEndpoint(id: "cloud", type: "icloud", mountPoint: root.path)
        let backend = try BackendFactory.open(endpoint, secrets: MemorySecretStore(), opener: ShareOpener.system)
        try backend.put("repo.json", data: Data("{}".utf8))
        XCTAssertEqual(try backend.list(""), ["repo.json"])
        XCTAssertThrowsError(try BlockingCall.run(seconds: 0.2, what: "listing \(cloud.path)") {
            Thread.sleep(forTimeInterval: 0.8)
            return [String]()
        }) { error in
            let text = (error as? DisklesslyError)?.errorDescription ?? ""
            XCTAssertEqual((error as? DisklesslyError)?.exitCode, 4)
            XCTAssertTrue(text.contains("timed out"))
            XCTAssertTrue(text.contains("Files and Folders"))
            XCTAssertTrue(text.contains("iCloud"))
        }
    }

    func testPutFileCopiesAndRangeDoesNotReadTheWholeObject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sparse.bin")
        let bytes: Int64 = 300 * 1024 * 1024
        let fd = open(source.path, O_CREAT | O_RDWR | O_TRUNC, mode_t(0o644))
        XCTAssertGreaterThanOrEqual(fd, 0, "errno \(errno)")
        XCTAssertEqual(ftruncate(fd, off_t(bytes)), 0)
        let header = Array("disklessly".utf8)
        _ = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        close(fd)
        let backend = try LocalFolderBackend(root: root.appendingPathComponent("repo"))
        let baseline = ResidentMemory.bytes()
        let sampler = PeakResident()
        sampler.start()
        try backend.put("images/sparse.bin", file: source)
        let ranged = try backend.get("images/sparse.bin", range: 0..<10)
        let digest = try SHA256Digest.hexFile(source)
        let copied = try SHA256Digest.hexFile(root.appendingPathComponent("repo/images/sparse.bin"))
        let peak = sampler.stop()
        XCTAssertEqual(ranged, Data("disklessly".utf8))
        XCTAssertEqual(copied, digest)
        XCTAssertEqual(try backend.stat("images/sparse.bin")?.size, UInt64(bytes))
        let allowance: UInt64 = 96 * 1024 * 1024
        XCTAssertLessThan(peak, baseline &+ allowance, "peak RSS \(peak) baseline \(baseline)")
    }

    func testWebAssetsStayLocalAndChineseFirst() throws {
        let web = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/disklessly/web")
        let names = ["index.html", "app.js", "style.css"]
        var combined = ""
        for name in names {
            let text = try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)
            combined += text
            // The one link out: a usage tip the user opens in their own browser.
            let local = text.replacingOccurrences(of: "https://github.com/omlahore/RemoveMacAI", with: "")
            XCTAssertFalse(local.contains("http://"))
            XCTAssertFalse(local.contains("https://"))
        }
        XCTAssertTrue(combined.contains("已缓存"))
        XCTAssertTrue(combined.contains("仅远端"))
        XCTAssertTrue(combined.contains("已固定"))
        XCTAssertTrue(combined.contains("已还原"))
        XCTAssertTrue(combined.contains("会话分层"))
        XCTAssertFalse(combined.lowercased().contains("wupan"))
    }
}

enum ResidentMemory {
    static func bytes() -> UInt64 {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, let kb = UInt64(fields[1]) { return kb * 1024 }
        }
        return 0
        #elseif os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        #else
        return 0
        #endif
    }
}

final class PeakResident: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = true

    func start() {
        peak = ResidentMemory.bytes()
        let thread = Thread { [weak self] in
            while let self, self.keepGoing() {
                let sample = ResidentMemory.bytes()
                self.lock.lock()
                if sample > self.peak { self.peak = sample }
                self.lock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        thread.stackSize = 64 * 1024
        thread.start()
    }

    func stop() -> UInt64 {
        lock.lock()
        running = false
        let value = peak
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.02)
        return max(value, ResidentMemory.bytes())
    }

    private func keepGoing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}
