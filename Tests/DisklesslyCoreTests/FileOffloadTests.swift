import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine
import DisklesslySessions

final class FileOffloadTests: XCTestCase {
    // These tests exercise the free limit, which is switched off by default for now.
    override class func setUp() { super.setUp(); License.limitOverride = true }
    override class func tearDown() { License.limitOverride = nil; super.tearDown() }
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("disklessly-files-\(UUID().uuidString)")
        root = URL(fileURLWithPath: SessionPaths.canonical(root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: SessionPaths.canonical(root.path))
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func engine() throws -> DisklesslyEngine {
        var config = RuntimeConfig(repoPath: root.appendingPathComponent("repo").path, cacheDir: root.appendingPathComponent("cache").path, stateDir: root.appendingPathComponent("state").path, mountRoot: root.appendingPathComponent("mounts").path, stubDir: root.appendingPathComponent("apps").path)
        config.minFreeBytes = 0
        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.homeOverride = home.path
        engine.offloadedOverride = { [] }
        engine.fileOpenOverride = { _, _ in false }
        try FileManager.default.createDirectory(atPath: config.repoPath, withIntermediateDirectories: true)
        _ = try RepoIdentity.ensure(try engine.repo)
        return engine
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int, age days: Double = 0) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        }
        try data.write(to: url)
        if days > 0 { try age(url, days) }
        return url
    }

    /// Sets both atime and mtime `days` back.
    private func age(_ url: URL, _ days: Double) throws {
        let seconds = Int(Date().addingTimeInterval(-days * 86_400).timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        XCTAssertEqual(utimes(url.path, &times), 0)
    }

    /// Relative path, kind, size, content hash and mtime (seconds) of everything under `folder`.
    private func contents(_ folder: URL) throws -> [String] {
        var lines: [String] = []
        let walker = FileManager.default.enumerator(atPath: folder.path)
        while let relative = walker?.nextObject() as? String {
            let path = folder.appendingPathComponent(relative).path
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let isFile = (attrs[.type] as? FileAttributeType) == .typeRegular
            let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            lines.append("\(relative) \(isFile ? try SHA256Digest.hexFile(URL(fileURLWithPath: path)) : "dir") \(isFile ? mtime : 0) \((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)")
        }
        return lines.sorted()
    }

    // MARK: Policy

    func testRefusalPolicy() {
        let h = "/Users/me"
        func why(_ path: String, dir: Bool = false, link: Bool = false) -> String? {
            FileOffloadPolicy.refusal(path: path, home: h, protected: ["/Users/me/Library/Mobile Documents/repo", "/Users/me/Disklessly"], isDirectory: dir, isSymlink: link)
        }
        XCTAssertNil(why("/Users/me/Downloads/movie.mov"))
        XCTAssertNil(why("/Users/me/Documents/Old Project", dir: true))
        XCTAssertNotNil(why("/Users/me/Downloads/Some.app/Contents/Resources/big.bin"), "inside an app bundle")
        XCTAssertNotNil(why("/Users/me/Downloads/Some.app", dir: true))
        XCTAssertNotNil(why("/Users/me/Library/Caches/x.bin"))
        XCTAssertNotNil(why("/Applications/Xcode.app/x"))
        XCTAssertNotNil(why("/tmp/x"))
        XCTAssertNotNil(why("/Users/me/Downloads", dir: true), "a standard folder itself")
        XCTAssertNotNil(why("/Users/me/Downloads/movie.mov.disklessly"))
        XCTAssertNotNil(why("/Users/me/Downloads/link", link: true))
        XCTAssertNotNil(why("/Users/me/Pictures/Photos Library.photoslibrary", dir: true))
        XCTAssertNotNil(why("/Users/me/VMs/ubuntu.utm", dir: true))
        XCTAssertNotNil(why("/Users/me/Disklessly/files/x"), "inside the repo")
        XCTAssertNil(why("/Users/me/Projects", dir: true))
        XCTAssertNotNil(FileOffloadPolicy.refusal(path: "/Users/me/Work", home: h, protected: ["/Users/me/Work/repo"], isDirectory: true, isSymlink: false), "a folder holding the repo")
    }

    // MARK: Scanner

    func testScannerListsIdleLargeItemsAndSkipsManagedOnes() throws {
        let min = 64 * 1024
        try write("Downloads/old.bin", bytes: min * 2, age: 90)
        try write("Downloads/new.bin", bytes: min * 2)
        try write("Downloads/small.bin", bytes: min / 2, age: 90)
        try write("Downloads/opened-lately.bin", bytes: min * 2, age: 90)
        try write("Downloads/running.bin", bytes: min * 2, age: 90)
        try write("Downloads/node_modules/pkg/blob.bin", bytes: min * 2, age: 90)
        try write("Downloads/disk.vmdk", bytes: min * 2, age: 90)
        try write("Downloads/Thing.app/Contents/big.bin", bytes: min * 2, age: 90)
        try write("Library/Application Support/com.apple.container/images/big.bin", bytes: min * 2, age: 90)
        try write(".docker/big.bin", bytes: min * 2, age: 90)
        try write("Downloads/.hidden.bin", bytes: min * 2, age: 90)
        try write("Code/repo/big.bin", bytes: min * 2, age: 90)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Code/repo/.git"), withIntermediateDirectories: true)
        // An idle project folder is listed whole, not file by file.
        try write("Documents/Old Project/a.bin", bytes: min, age: 200)
        try write("Documents/Old Project/sub/b.bin", bytes: min * 2, age: 200)
        for dir in ["Documents/Old Project/sub", "Documents/Old Project", "Code/repo", "Code"] { try age(home.appendingPathComponent(dir), 200) }
        let opened = home.appendingPathComponent("Downloads/opened-lately.bin").path
        let running = home.appendingPathComponent("Downloads/running.bin").path
        let scan = LargeFileScan.scan(root: home, protected: [], options: LargeFileOptions(minBytes: UInt64(min), minIdleDays: 30),
                                      lastUsed: { $0.path == opened ? Date() : nil },
                                      openPaths: { Set($0.filter { $0 == running }) })
        let listed = Set(scan.items.map { String($0.path.dropFirst(home.path.count + 1)) })
        XCTAssertFalse(scan.partial)
        XCTAssertEqual(listed, ["Downloads/old.bin", "Documents/Old Project"], "a git working tree is skipped whole")
        XCTAssertEqual(scan.items.first { $0.name == "Old Project" }?.kind, .folder)
    }

    func testScannerSkipsTheRepoAndDoesNotListItsParentWhole() throws {
        let min = 64 * 1024
        try write("Stuff/Disklessly/files/objects/x.bin", bytes: min * 4, age: 90)
        try write("Stuff/old/a.bin", bytes: min * 2, age: 90)
        for dir in ["Stuff/old", "Stuff/Disklessly/files/objects", "Stuff/Disklessly/files", "Stuff/Disklessly", "Stuff"] { try age(home.appendingPathComponent(dir), 90) }
        let scan = LargeFileScan.scan(root: home, protected: [home.appendingPathComponent("Stuff/Disklessly").path], options: LargeFileOptions(minBytes: UInt64(min), minIdleDays: 30), lastUsed: { _ in nil }, openPaths: { _ in [] })
        XCTAssertEqual(scan.items.map(\.name), ["old"])
    }

    // MARK: Round trip

    func testFileRoundTrip() throws {
        let engine = try engine()
        let original = try write("Downloads/movie.mov", bytes: 300_000, age: 60)
        let sha = try SHA256Digest.hexFile(original)
        let result = try engine.offloadFile(original.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let placeholderURL = URL(fileURLWithPath: result.placeholderPath)
        XCTAssertEqual(placeholderURL.lastPathComponent, "movie.mov.disklessly")
        let placeholder = try FilePlaceholder.read(placeholderURL)
        XCTAssertEqual(placeholder.kind, .file)
        XCTAssertEqual(placeholder.sha256, sha)
        XCTAssertEqual(placeholder.size, 300_000)
        XCTAssertNotNil(placeholder.repoId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("repo/\(placeholder.object)").path))
        #if os(macOS)
        XCTAssertEqual(try placeholderURL.resourceValues(forKeys: [.tagNamesKey]).tagNames, [FilePlaceholder.finderTag])
        #endif
        XCTAssertEqual(engine.offloadedFileCount(), 1)

        let back = try engine.fetchFile(placeholderURL.path)
        XCTAssertEqual(SessionPaths.canonical(back.path), SessionPaths.canonical(original.path))
        XCTAssertEqual(try SHA256Digest.hexFile(back), sha)
        XCTAssertFalse(FileManager.default.fileExists(atPath: placeholderURL.path))
        XCTAssertEqual(engine.offloadedFileCount(), 0)
        let modified = try FileManager.default.attributesOfItem(atPath: back.path)[.modificationDate] as? Date
        XCTAssertEqual(modified?.timeIntervalSince1970 ?? 0, placeholder.modifiedAt?.timeIntervalSince1970 ?? -1, accuracy: 1)
    }

    func testFolderRoundTrip() throws {
        let engine = try engine()
        try write("Documents/Project/a.txt", bytes: 1_000)
        try write("Documents/Project/deep/er/b.bin", bytes: 200_000)
        try write("Documents/Project/name with spaces ü.txt", bytes: 10)
        let folder = home.appendingPathComponent("Documents/Project")
        let before = try contents(folder)
        let result = try engine.offloadFile(folder.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(result.placeholder.kind, .folder)
        XCTAssertEqual(result.placeholder.codec, "tar+zstd")
        XCTAssertTrue(result.placeholder.object.hasSuffix(".tar.zst"))
        XCTAssertEqual(result.placeholder.size, 201_010)
        // The staged archive does not stay in the cache.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasPrefix("offload-") }.isEmpty, "\(leftovers)")

        try engine.fetchFile(result.placeholderPath)
        XCTAssertEqual(try contents(folder), before)
        XCTAssertEqual(before.count, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.placeholderPath))
        let parent = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Documents").path)) ?? []
        XCTAssertEqual(parent, ["Project"], "no staging leftovers")
    }

    func testScannerTreatsARecentAccessAsUse() throws {
        let min = 64 * 1024
        let file = try write("Downloads/watched.mov", bytes: min * 2, age: 90)
        let seconds = Int(Date().timeIntervalSince1970)
        let old = Int(Date().addingTimeInterval(-90 * 86_400).timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: old, tv_usec: 0)]
        XCTAssertEqual(utimes(file.path, &times), 0)
        let scan = LargeFileScan.scan(root: home, protected: [], options: LargeFileOptions(minBytes: UInt64(min), minIdleDays: 30), lastUsed: { _ in Date.distantPast.addingTimeInterval(1) }, openPaths: { _ in [] })
        XCTAssertTrue(scan.items.isEmpty, "\(scan.items)")
    }

    func testAFolderDeleteThatStopsHalfwayKeepsThePlaceholder() throws {
        #if os(macOS)
        let engine = try engine()
        let locked = try write("Documents/Stuck/inner/locked.bin", bytes: 1_000)
        try write("Documents/Stuck/other.bin", bytes: 2_000)
        XCTAssertEqual(chflags(locked.path, UInt32(UF_IMMUTABLE)), 0)
        let result = try engine.offloadFile(home.appendingPathComponent("Documents/Stuck").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.placeholderPath), "the placeholder points at the complete repo copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/Stuck").path))
        XCTAssertTrue(result.warnings.contains { $0.contains("could not delete") }, "\(result.warnings)")
        XCTAssertEqual(engine.offloadedFileCount(), 1)
        // Clean up the leftover so the temp folder can be removed.
        let documents = home.appendingPathComponent("Documents")
        for name in try FileManager.default.contentsOfDirectory(atPath: documents.path) where name.contains("disklessly-removing") {
            _ = chflags(documents.appendingPathComponent(name).appendingPathComponent("inner/locked.bin").path, 0)
        }
        #endif
    }

    func testOpenFileIsRefusedAndKept() throws {
        var engine = try engine()
        engine.fileOpenOverride = nil
        let original = try write("Downloads/busy.bin", bytes: 10_000)
        let handle = try FileHandle(forReadingFrom: original)
        defer { try? handle.close() }
        XCTAssertThrowsError(try engine.offloadFile(original.path)) { error in
            guard case DisklesslyError.busy = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path + ".disklessly"))
        try handle.close()
        XCTAssertNoThrow(try engine.offloadFile(original.path))
    }

    func testOpenFolderIsRefused() throws {
        var engine = try engine()
        var asked: [(String, Bool)] = []
        engine.fileOpenOverride = { path, folder in asked.append((path, folder)); return true }
        try write("Documents/Live/a.bin", bytes: 100)
        XCTAssertThrowsError(try engine.offloadFile(home.appendingPathComponent("Documents/Live").path)) { error in
            guard case DisklesslyError.busy = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(asked.first?.1, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/Live/a.bin").path))
    }

    func testRefusesAppBundlesAndPathsOutsideHome() throws {
        let engine = try engine()
        let inside = try write("Downloads/Tool.app/Contents/Resources/big.bin", bytes: 100)
        XCTAssertThrowsError(try engine.offloadFile(inside.path))
        XCTAssertThrowsError(try engine.offloadFile(root.appendingPathComponent("cache").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    func testTamperedRepoObjectIsRefusedAndPlaceholderSurvives() throws {
        let engine = try engine()
        let original = try write("Downloads/data.bin", bytes: 50_000)
        let result = try engine.offloadFile(original.path)
        let object = root.appendingPathComponent("repo/\(result.placeholder.object)")
        var bytes = try Data(contentsOf: object)
        bytes[100] ^= 0xff
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: object.path)
        try bytes.write(to: object)
        XCTAssertThrowsError(try engine.fetchFile(result.placeholderPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.placeholderPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let entries = try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path)
        XCTAssertEqual(entries, ["data.bin.disklessly"], "no partial download left behind")
    }

    func testFetchWhenTheOriginalIsStillThereKeepsItAndDropsThePlaceholder() throws {
        let engine = try engine()
        let original = try write("Downloads/twice.bin", bytes: 20_000)
        let copy = root.appendingPathComponent("copy.bin")
        try FileManager.default.copyItem(at: original, to: copy)
        let result = try engine.offloadFile(original.path)
        // The crash window: the placeholder was written, the original not yet removed.
        try FileManager.default.copyItem(at: copy, to: original)
        try engine.fetchFile(result.placeholderPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.placeholderPath))
        XCTAssertEqual(try SHA256Digest.hexFile(original), try SHA256Digest.hexFile(copy))
        // A different file of that name is never replaced.
        let again = try engine.offloadFile(original.path)
        try Data("other".utf8).write(to: original)
        XCTAssertThrowsError(try engine.fetchFile(again.placeholderPath))
        XCTAssertEqual(try Data(contentsOf: original), Data("other".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.placeholderPath))
    }

    func testPlaceholderFromAnotherRepoIsRefused() throws {
        let engine = try engine()
        let original = try write("Downloads/x.bin", bytes: 1_000)
        let result = try engine.offloadFile(original.path)
        var placeholder = try FilePlaceholder.read(URL(fileURLWithPath: result.placeholderPath))
        placeholder.repoId = "someone-else"
        try placeholder.encode().write(to: URL(fileURLWithPath: result.placeholderPath))
        XCTAssertThrowsError(try engine.fetchFile(result.placeholderPath)) { error in
            XCTAssertTrue((error as? DisklesslyError)?.errorDescription?.contains("another repo") == true)
        }
    }

    func testPlaceholderValidationRejectsUnsafeNames() throws {
        let p = FilePlaceholder(id: "x", kind: .file, name: "../evil", size: 1, object: FilePlaceholder.objectPath(sha256: String(repeating: "a", count: 64), kind: .file), codec: "none", sha256: String(repeating: "a", count: 64), storedSize: 1, repoId: nil, originalPath: "/x", createdAt: Date())
        XCTAssertThrowsError(try FilePlaceholder.decode(try p.encode()))
        var q = p
        q.name = "ok"
        q.object = "images/other.dmg"
        XCTAssertThrowsError(try FilePlaceholder.decode(try q.encode()))
    }

    func testOffloadedFilesCountTowardTheFreeLimit() throws {
        var engine = try engine()
        engine.offloadedOverride = { ["com.example.app"] }
        let first = try write("Downloads/one.bin", bytes: 1_000)
        let second = try write("Downloads/two.bin", bytes: 1_001)
        _ = try engine.offloadFile(first.path)
        XCTAssertThrowsError(try engine.offloadFile(second.path)) { error in
            guard case DisklesslyError.licenseRequired = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertThrowsError(try License.checkPack(state: .free, offloaded: ["a"], packing: "b", files: 1))
        XCTAssertNoThrow(try License.checkPack(state: .free, offloaded: ["a"], packing: "a", files: 5), "re-pack still allowed")
        // A deleted placeholder no longer counts.
        try FileManager.default.removeItem(atPath: first.path + ".disklessly")
        XCTAssertEqual(engine.offloadedFileCount(), 0)
    }

    func testStreamingZstdRoundTrip() throws {
        let input = root.appendingPathComponent("in.bin")
        var data = Data()
        for i in 0..<300_000 { data.append(UInt8(truncatingIfNeeded: i % 251)) }
        try data.write(to: input)
        let compressed = root.appendingPathComponent("c.zst")
        FileManager.default.createFile(atPath: compressed.path, contents: nil)
        let out = try FileHandle(forWritingTo: compressed)
        try ZstdStream.compress(from: try FileHandle(forReadingFrom: input), to: out)
        try out.close()
        XCTAssertEqual(try Zstd.decompress(try Data(contentsOf: compressed), maxBytes: 1 << 24), data)
    }
}
