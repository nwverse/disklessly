import Foundation
import DisklesslyCore
#if os(macOS)
import Darwin
#endif

/// Processes whose executable lives inside an app bundle: the app itself and its
/// helpers (login items, menu bar agents, updaters). Used to stop them before pack
/// when the user asked for "Stop and offload".
public enum BundleProcesses {
    /// pids whose executable is under `bundlePath` (or its resolved path). Never this process or
    /// its ancestors: a stub that started `disklessly launch` lives in the bundle and waits for it.
    public static func pids(inBundle bundlePath: String) -> [Int32] {
        #if os(macOS)
        // proc_pidpath reports the real path (/private/var/...), which Foundation's
        // resolvingSymlinksInPath would strip again, so realpath(3) is used as well.
        var roots = Set([bundlePath, URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if let real = realpath(bundlePath, nil) { roots.insert(String(cString: real)); free(real) }
        let prefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let skip = ancestors()
        return allProcesses().filter { pid, path in
            !skip.contains(pid) && prefixes.contains { path.hasPrefix($0) }
        }.map(\.0)
        #else
        return []
        #endif
    }

    /// Ask every process inside the bundle to quit (SIGTERM), wait up to `grace`
    /// seconds, then SIGKILL the ones still there. Returns how many were signalled.
    /// Throws `.busy` when some are still alive afterwards.
    @discardableResult
    public static func stop(bundlePath: String, grace: TimeInterval = 8) throws -> Int {
        #if os(macOS)
        let first = pids(inBundle: bundlePath)
        guard !first.isEmpty else { return 0 }
        for pid in first { kill(pid, SIGTERM) }
        if waitGone(bundlePath, seconds: grace) { return first.count }
        for pid in pids(inBundle: bundlePath) { kill(pid, SIGKILL) }
        if waitGone(bundlePath, seconds: 3) { return first.count }
        let name = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        throw DisklesslyError.busy("\(name) is still running after it was asked to quit; nothing was changed")
        #else
        return 0
        #endif
    }

    #if os(macOS)
    /// This process and every parent up to launchd.
    static func ancestors() -> Set<Int32> {
        var out: Set<Int32> = []
        var pid = getpid()
        while pid > 1, out.insert(pid).inserted {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            pid = Int32(info.pbi_ppid)
        }
        return out
    }

    private static func waitGone(_ bundlePath: String, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if pids(inBundle: bundlePath).isEmpty { return true }
            usleep(200_000)
        }
        return pids(inBundle: bundlePath).isEmpty
    }

    static func allProcesses() -> [(Int32, String)] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        var list = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let written = list.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_listpids(UInt32(PROC_ALL_PIDS), 0, base, Int32(buffer.count))
        }
        guard written > 0 else { return [] }
        var result: [(Int32, String)] = []
        for pid in list.prefix(min(list.count, Int(written) / MemoryLayout<pid_t>.size)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return 0 }
                return proc_pidpath(pid, base, UInt32(raw.count))
            }
            if length > 0 { result.append((pid, String(cString: buffer))) }
        }
        return result
    }
    #endif
}
