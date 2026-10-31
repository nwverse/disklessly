import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Spawn a child outside the caller's session.
///
/// Launch Services puts the stub in its own session and tears that session down
/// with `SIGKILL` (exit 137) when the stub exits. A post-quit watcher started
/// with `Foundation.Process` shares that process group and dies with it, so the
/// journal stays `active`. `POSIX_SPAWN_SETSID` (glibc `0x80`, Darwin `0x0400`)
/// makes the child a session leader and starts its process group. Do not also
/// set `POSIX_SPAWN_SETPGROUP`: glibc then calls `setsid` on a process that is
/// already a group leader, and `setsid` fails with `EPERM`. Darwin's `0x80` is
/// `POSIX_SPAWN_START_SUSPENDED` and must not be used here.
public enum DetachedProcess {
    public static func spawn(executable: String, arguments: [String], redirectOutput: String?, newSession: Bool) throws -> Int32 {
        let cArgs: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for arg in cArgs { free(arg) } }
        var pid: pid_t = 0
        let rc = try cArgs.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { throw DetachedProcessError.spawn(EINVAL) }
            let argv = UnsafeMutablePointer(mutating: base)
            if newSession {
                return try spawnNewSession(executable: executable, argv: argv, redirectOutput: redirectOutput, pid: &pid)
            }
            return posix_spawn(&pid, executable, nil, nil, argv, environ)
        }
        guard rc == 0, pid > 0 else { throw DetachedProcessError.spawn(rc) }
        return pid
    }

    /// `nil` when `timeout` elapses and the process is still running.
    /// A `nil` timeout waits until the process exits.
    public static func wait(pid: Int32, timeout: TimeInterval?) -> Int32? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            var status: Int32 = 0
            let rc = waitpid(pid, &status, WNOHANG)
            if rc == pid { return decoded(status) }
            if rc < 0 && errno != EINTR { return 1 }
            if let deadline, Date() >= deadline { return nil }
            usleep(50_000)
        }
    }

    public static func sessionID(_ pid: Int32) -> Int32 { getsid(pid) }

    public static func processGroup(_ pid: Int32) -> Int32 { getpgid(pid) }

    private static func decoded(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return 1
    }

    private static func spawnNewSession(executable: String, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, redirectOutput: String?, pid: inout pid_t) throws -> Int32 {
        #if os(macOS)
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw DetachedProcessError.spawn(errno) }
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID is 0x0400. setsid() also creates the new process group.
        guard posix_spawnattr_setflags(&attr, 0x0400) == 0 else { throw DetachedProcessError.spawn(errno) }
        var actions: posix_spawn_file_actions_t?
        let useActions = redirectOutput != nil
        if useActions {
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw DetachedProcessError.spawn(errno) }
        }
        defer { if useActions { posix_spawn_file_actions_destroy(&actions) } }
        if let redirectOutput {
            try addRedirects(path: redirectOutput) { fd, path, flags, mode in
                posix_spawn_file_actions_addopen(&actions, fd, path, flags, mode)
            }
        }
        if useActions {
            return posix_spawn(&pid, executable, &actions, &attr, argv, environ)
        }
        return posix_spawn(&pid, executable, nil, &attr, argv, environ)
        #else
        let attr = UnsafeMutablePointer<posix_spawnattr_t>.allocate(capacity: 1)
        defer {
            posix_spawnattr_destroy(attr)
            attr.deallocate()
        }
        guard posix_spawnattr_init(attr) == 0 else { throw DetachedProcessError.spawn(errno) }
        // glibc POSIX_SPAWN_SETSID is 0x80. Do not also set POSIX_SPAWN_SETPGROUP.
        guard posix_spawnattr_setflags(attr, 0x0080) == 0 else { throw DetachedProcessError.spawn(errno) }
        let actions = UnsafeMutablePointer<posix_spawn_file_actions_t>.allocate(capacity: 1)
        defer {
            if redirectOutput != nil {
                posix_spawn_file_actions_destroy(actions)
            }
            actions.deallocate()
        }
        if redirectOutput != nil {
            guard posix_spawn_file_actions_init(actions) == 0 else { throw DetachedProcessError.spawn(errno) }
        }
        if let redirectOutput {
            try addRedirects(path: redirectOutput) { fd, path, flags, mode in
                posix_spawn_file_actions_addopen(actions, fd, path, flags, mode)
            }
        }
        if redirectOutput != nil {
            return posix_spawn(&pid, executable, actions, attr, argv, environ)
        }
        return posix_spawn(&pid, executable, nil, attr, argv, environ)
        #endif
    }

    private static func addRedirects(path: String, _ add: (Int32, UnsafePointer<CChar>, Int32, mode_t) -> Int32) throws {
        if add(0, "/dev/null", O_RDONLY, 0) != 0 { throw DetachedProcessError.spawn(errno) }
        let flags = O_WRONLY | O_CREAT | O_APPEND
        try path.withCString { cPath in
            if add(1, cPath, flags, mode_t(0o644)) != 0 { throw DetachedProcessError.spawn(errno) }
            if add(2, cPath, flags, mode_t(0o644)) != 0 { throw DetachedProcessError.spawn(errno) }
        }
    }
}

public enum DetachedProcessError: Error, Equatable {
    case spawn(Int32)
}
