import Foundation
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
        let start = ticks(for: owner.pid)
        if owner.start == 0 || start == 0 { return true }
        return start == owner.start
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
    public static func hex(_ data: Data) -> String {
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var bytes = [UInt8](data)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        func rotr(_ value: UInt32, _ bits: UInt32) -> UInt32 {
            (value >> bits) | (value << (32 - bits))
        }
        var offset = 0
        while offset < bytes.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = offset + i * 4
                w[i] = (UInt32(bytes[o]) << 24) | (UInt32(bytes[o + 1]) << 16) | (UInt32(bytes[o + 2]) << 8) | UInt32(bytes[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            hash[0] = hash[0] &+ a; hash[1] = hash[1] &+ b; hash[2] = hash[2] &+ c; hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e; hash[5] = hash[5] &+ f; hash[6] = hash[6] &+ g; hash[7] = hash[7] &+ h
            offset += 64
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    public static func hexFile(_ url: URL) throws -> String {
        hex(try Data(contentsOf: url))
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

    public static func identity(_ url: URL, cdhash: (URL) throws -> String, treeHash: (URL) throws -> String) -> BundleIdentity? {
        guard let info = readInfo(url), let bundleId = info["CFBundleIdentifier"] as? String else { return nil }
        let executable = info["CFBundleExecutable"] as? String ?? ""
        let cd = (try? cdhash(url)) ?? ""
        let tree = (try? treeHash(url)) ?? ""
        let stub = bundleId.hasSuffix(".256stub") || executable == "isenough-stub"
        return BundleIdentity(bundleId: bundleId, executable: executable, cdhash: cd, treeHash: tree, inode: DurableIO.inode(url), isStub: stub)
    }
}

/// Tree hash: sha256 over sorted relative paths, type, mode, symlink target, and file bytes.
public enum BundleHasher {
    public static func treeHash(of root: URL) throws -> String {
        let start = root.resolvingSymlinksInPath()
        var files: [URL] = []
        try collect(start, &files)
        var entries: [(relative: String, url: URL)] = []
        entries.reserveCapacity(files.count)
        for url in files {
            guard let relative = relativePath(url.path, root: start.path) else {
                throw IsenoughError.failure("cannot relativize \(url.path) under \(start.path)")
            }
            guard !relative.isEmpty, !relative.split(separator: "/").contains(".."), !relative.hasPrefix("/") else { continue }
            entries.append((relative, url))
        }
        entries.sort { $0.relative < $1.relative }
        var blob = Data()
        func append(_ string: String) { blob.append(Data(string.utf8)) }
        let fm = FileManager.default
        for entry in entries {
            let url = entry.url
            let relative = entry.relative
            let isLink = DurableIO.isSymlink(url)
            var isDir: ObjCBool = false
            if !isLink { _ = fm.fileExists(atPath: url.path, isDirectory: &isDir) }
            let mode = fileMode(url)
            if isLink {
                let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                append("l \(mode) \(relative)\n")
                append("target \(target)\n")
            } else if isDir.boolValue {
                append("d \(mode) \(relative)\n")
            } else {
                let bytes = (try? Data(contentsOf: url)) ?? Data()
                append("f \(mode) \(relative)\n")
                append("bytes \(bytes.count)\n")
                blob.append(bytes)
                append("\n")
            }
        }
        return SHA256Digest.hex(blob)
    }

    /// Drop AppleDouble sidecars and `__MACOSX` directories left by a disk-image round trip.
    /// Their bytes can include a per-copy `com.apple.provenance` value, so they must not
    /// be part of the tree that is hashed or installed. Real bundle files stay.
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
    private static func collect(_ directory: URL, _ files: inout [URL]) throws {
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

    private static func fileMode(_ url: URL) -> String {
        var st = stat()
        if lstat(url.path, &st) != 0 { return "000" }
        return String(st.st_mode & 0o777, radix: 8)
    }
}
