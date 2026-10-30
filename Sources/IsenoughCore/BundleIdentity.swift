import Foundation
import Dispatch
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct InodeId: Codable, Equatable, Hashable {
    public var dev: UInt64
    public var ino: UInt64
    public init(dev: UInt64, ino: UInt64) { self.dev = dev; self.ino = ino }
}

public struct ProcessOwner: Codable, Equatable, Hashable {
    public var pid: Int32
    public var start: UInt64
    public init(pid: Int32, start: UInt64) { self.pid = pid; self.start = start }
    public static func current() -> ProcessOwner {
        ProcessOwner(pid: Int32(getpid()), start: ProcessStart.ticks(for: Int32(getpid())))
    }
}

public enum ProcessStart {
    public static func ticks(for pid: Int32) -> UInt64 {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let paren = text.lastIndex(of: ")") else { return 0 }
        let fields = text[text.index(after: paren)...].split(separator: " ")
        // Field 22 (starttime) is index 19 of the post-comm fields.
        if fields.count > 19, let value = UInt64(fields[19]) { return value }
        return 0
        #elseif os(macOS)
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return 0 }
        return UInt64(info.pbi_start_tvsec)
        #else
        return 0
        #endif
    }

    public static func isAlive(_ owner: ProcessOwner) -> Bool {
        guard owner.pid > 0, kill(owner.pid, 0) == 0 else { return false }
        // kill(pid, 0) succeeds for a zombie. A killed `hook watch` child that its
        // parent has not reaped yet must not look like a live journal owner.
        if isZombie(owner.pid) { return false }
        let start = ticks(for: owner.pid)
        if owner.start == 0 { return true }
        // Process info that can no longer be read for a recorded owner means it is gone.
        if start == 0 { return false }
        return start == owner.start
    }

    static func isZombie(_ pid: Int32) -> Bool {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let paren = text.lastIndex(of: ")") else { return false }
        return text[text.index(after: paren)...].split(separator: " ").first == "Z"
        #elseif os(macOS)
        // proc_pidinfo fails for zombies; the kinfo_proc state still says SZOMB.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == CChar(SZOMB)
        #else
        return false
        #endif
    }
}

public enum DurableIO {
    public static func inode(_ url: URL) -> InodeId? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return InodeId(dev: UInt64(st.st_dev), ino: UInt64(st.st_ino))
    }

    public static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    public static func syncItem(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { _ = close(fd) }
        if systemFsync(fd) != 0 {
            throw IsenoughError.failure("fsync failed for \(url.path)")
        }
    }

    private static func systemFsync(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.fsync(fd)
        #elseif canImport(Darwin)
        Darwin.fsync(fd)
        #else
        0
        #endif
    }

    /// Write `data` via a temp file in the destination directory, fsync the file, then rename over the destination and fsync the directory.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        let fd = open(tmp.path, O_RDONLY)
        if fd >= 0 {
            _ = systemFsync(fd)
            _ = close(fd)
        }
        // `rename` replaces an existing file atomically. Unlinking first would
        // leave a window where a crash drops the previous journal.
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw IsenoughError.failure("atomic rename failed for \(url.path) (errno \(errno))")
        }
        try syncItem(dir)
    }
}

public enum SHA256Digest {
    /// SHA-256 of `data`. Streaming and one-shot callers share one implementation.
    public static func hex(_ data: Data) -> String {
        var hasher = Hasher()
        hasher.update(data)
        return hasher.finalize()
    }

    /// SHA-256 of a file, read in fixed-size chunks.
    public static func hexFile(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw IsenoughError.failure("cannot read \(url.path)") }
        defer { _ = close(fd) }
        var hasher = Hasher()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let n: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                while true {
                    let count = read(fd, base, raw.count)
                    if count < 0 && errno == EINTR { continue }
                    return count
                }
            }
            if n < 0 { throw IsenoughError.failure("cannot read \(url.path)") }
            if n == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
            }
        }
        return hasher.finalize()
    }
}

public struct BundleIdentity: Equatable {
    public var bundleId: String
    public var executable: String
    public var cdhash: String
    public var treeHash: String
    public var inode: InodeId?
    public var isStub: Bool
}

public enum BundleFacts {
    public static func readInfo(_ url: URL) -> [String: Any]? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// `verifyContent` false skips cdhash and tree hash. Callers that only need the
    /// bundle id (a live restore probe) use that so a multi-gigabyte tree is not hashed
    /// on every poll. The strings are empty, not a partial digest.
    public static func identity(_ url: URL, cdhash: (URL) throws -> String, treeHash: (URL) throws -> String, verifyContent: Bool = true) -> BundleIdentity? {
        guard let info = readInfo(url), let bundleId = info["CFBundleIdentifier"] as? String else { return nil }
        let executable = info["CFBundleExecutable"] as? String ?? ""
        let stub = bundleId.hasSuffix(".256stub") || executable == "isenough-stub"
        let cd: String
        let tree: String
        if verifyContent {
            cd = (try? cdhash(url)) ?? ""
            tree = (try? treeHash(url)) ?? ""
        } else {
            cd = ""
            tree = ""
        }
        return BundleIdentity(bundleId: bundleId, executable: executable, cdhash: cd, treeHash: tree, inode: DurableIO.inode(url), isStub: stub)
    }
}

/// Tree hash: sha256 over sorted relative paths, type, mode, symlink target, and file bytes.
public enum BundleHasher {

    /// Drop AppleDouble sidecars and `__MACOSX` directories left by a disk-image round trip.
    /// Their bytes can include a per-copy `com.apple.provenance` value, so they must not
    /// be part of the tree that is hashed or installed. Real bundle files stay.
    /// Remove `Contents/_MASReceipt` so a shared image does not carry another Mac's receipt.
    public static func removeMachineReceipt(_ root: URL) {
        let receipt = root.appendingPathComponent(MASReceiptPaths.directory)
        if FileManager.default.fileExists(atPath: receipt.path) {
            try? FileManager.default.removeItem(at: receipt)
        }
    }

    public static func removeMetadataSidecars(_ root: URL) {
        var files: [URL] = []
        guard (try? collect(root.resolvingSymlinksInPath(), &files)) != nil else { return }
        files.sort { $0.path.count > $1.path.count }
        let fm = FileManager.default
        for url in files {
            let name = url.lastPathComponent
            if name.hasPrefix("._") || name == "__MACOSX" {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// `FileManager.enumerator(at:)` can skip the contents of a package root (a `.app`).
    /// A direct listing always includes them, so a staged `Restore.app` and an extracted
    /// copy are hashed as the same tree.
    static func collect(_ directory: URL, _ files: inout [URL]) throws {
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
        } catch {
            throw IsenoughError.failure("cannot enumerate \(directory.path)")
        }
        for child in children {
            files.append(child)
            if DurableIO.isSymlink(child) { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                try collect(child, &files)
            }
        }
    }

    public static func executableDigest(of root: URL) throws -> String {
        guard let info = BundleFacts.readInfo(root) else { throw IsenoughError.integrity("bundle has no Info.plist: \(root.path)") }
        let name = info["CFBundleExecutable"] as? String ?? ""
        let exe = root.appendingPathComponent("Contents/MacOS/\(name)")
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw IsenoughError.integrity("bundle executable missing: \(exe.path)")
        }
        return try SHA256Digest.hexFile(exe)
    }

    /// macOS prefers a real code-directory hash. Unsigned bundles and Linux use the executable sha256.
    public static func cdhash(of root: URL) throws -> String {
        #if os(macOS)
        if let signed = codesignCDHash(root) { return signed.lowercased() }
        #endif
        return try executableDigest(of: root)
    }

    public static func signatureValid(_ root: URL) -> Bool {
        #if os(macOS)
        let process = ParsedCommand.process(path: "/usr/bin/codesign", arguments: ["--verify", "--strict", root.path])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
        #else
        return BundleFacts.readInfo(root) != nil
        #endif
    }

    #if os(macOS)
    /// The bundle cdhash is the code directory stored in the main Mach-O. Reading that
    /// executable, not the bundle directory, keeps pack and extract on the same value:
    /// `codesign` rejects a directory whose name is not a bundle extension, and restore
    /// stages the copy at `app.new`. A printed `CDHash=` is used even when the exit
    /// status is non-zero; `--verify` is what checks the seal. `CDHash=` is the machine
    /// field from `-dvvv`. There is no `-plist` form of that field. Translated sentences
    /// in the same output are ignored.
    private static func codesignCDHash(_ root: URL) -> String? {
        if let info = BundleFacts.readInfo(root) {
            let name = info["CFBundleExecutable"] as? String ?? ""
            if !name.isEmpty {
                let exe = root.appendingPathComponent("Contents/MacOS/\(name)")
                if FileManager.default.fileExists(atPath: exe.path), let hash = codesignDisplay(exe) {
                    return hash
                }
            }
        }
        return codesignDisplay(root)
    }

    private static func codesignDisplay(_ url: URL) -> String? {
        let process = ParsedCommand.process(path: "/usr/bin/codesign", arguments: ["-dvvv", url.path])
        let pipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("CDHash=") {
            let value = line.dropFirst("CDHash=".count).split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }
    #endif

    /// Relative path of `path` under `root`, after `/var` and `/private/var` (also `/tmp` and `/etc`) are treated as the same location.
    static func relativePath(_ path: String, root: String) -> String? {
        let paths = pathForms(path)
        let roots = pathForms(root)
        for rootForm in roots {
            let prefix = rootForm.hasSuffix("/") ? rootForm : rootForm + "/"
            for pathForm in paths {
                if pathForm == rootForm { return "" }
                if pathForm.hasPrefix(prefix) {
                    return String(pathForm.dropFirst(prefix.count))
                }
            }
        }
        return nil
    }

    static func pathForms(_ path: String) -> [String] {
        var forms: [String] = []
        func add(_ value: String) {
            var trimmed = value
            if trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            if !forms.contains(trimmed) { forms.append(trimmed) }
        }
        add(path)
        let url = URL(fileURLWithPath: path)
        add(url.standardizedFileURL.path)
        add(url.resolvingSymlinksInPath().path)
        let pairs = [("/private/var", "/var"), ("/private/tmp", "/tmp"), ("/private/etc", "/etc")]
        let seed = forms
        for form in seed {
            for (long, short) in pairs {
                if form == long || form.hasPrefix(long + "/") {
                    add(short + String(form.dropFirst(long.count)))
                } else if form == short || form.hasPrefix(short + "/") {
                    add(long + String(form.dropFirst(short.count)))
                }
            }
        }
        return forms
    }

    static func fileMode(_ url: URL) -> String {
        var st = stat()
        if lstat(url.path, &st) != 0 { return "000" }
        return String(st.st_mode & 0o777, radix: 8)
    }
}
