import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct ProcessCaptureResult: Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { !timedOut && status == 0 }
}

/// Runs a child while draining both output pipes from one non-blocking poll
/// loop. This prevents either full pipe from deadlocking the child.
///
/// A timeout covers both the direct child and EOF on its output pipes. If the
/// child exits but a descendant keeps those pipes open, the capture still
/// times out and returns the bytes seen so far. Cleanup deliberately targets
/// only the direct child: descendants may survive when they escape or ignore
/// its termination, because killing the inherited process group could also
/// kill the caller or unrelated children.
public enum ProcessCapture {
    private struct PipeDrain {
        let pipe: Pipe
        let fd: Int32
        var isOpen = true
        var bytes = Data()
    }

    private static let pollMilliseconds: Int32 = 25
    private static let cleanupGrace: TimeInterval = 0.25
    private static let terminationGrace: TimeInterval = 0.5
    private static let killGrace: TimeInterval = 1
    private static let readBufferSize = 64 * 1024

    public static func run(_ process: Process, timeout: TimeInterval? = nil) throws -> ProcessCaptureResult {
        let started = DispatchTime.now()
        let deadline = timeout.flatMap { $0 > 0 ? started + $0 : nil }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        var drains = [
            PipeDrain(pipe: stdout, fd: stdout.fileHandleForReading.fileDescriptor),
            PipeDrain(pipe: stderr, fd: stderr.fileHandleForReading.fileDescriptor),
        ]
        for index in drains.indices {
            makeNonBlocking(drains[index].fd)
        }

        var processDone = false
        var processReaped = true
        var timedOut = false
        var terminationRequested = false
        var escalationRequested = false
        var terminationDeadline: DispatchTime?
        var killDeadline: DispatchTime?
        var readerDeadline: DispatchTime?

        while true {
            if !processDone, finished.wait(timeout: .now()) == .success {
                processDone = true
                if let deadline, hasReached(deadline) {
                    timedOut = true
                }
                readerDeadline = makeReaderDeadline(after: deadline)
            }

            drainReadyPipes(&drains)

            if !processDone, finished.wait(timeout: .now()) == .success {
                processDone = true
                if let deadline, hasReached(deadline) {
                    timedOut = true
                }
                readerDeadline = makeReaderDeadline(after: deadline)
            }

            if processDone, drains.allSatisfy({ !$0.isOpen }) {
                break
            }

            if let readerDeadline, hasReached(readerDeadline) {
                timedOut = true
                closeOpenPipes(&drains)
                break
            }

            let now = DispatchTime.now()
            if !processDone, let deadline, !terminationRequested, hasReached(deadline, now: now) {
                timedOut = true
                terminationRequested = true
                terminationDeadline = now + terminationGrace
                process.terminate()
                continue
            }

            if !processDone, terminationRequested, !escalationRequested,
               let terminationDeadline, hasReached(terminationDeadline, now: now) {
                escalationRequested = true
                killDeadline = now + killGrace
                kill(process.processIdentifier, SIGKILL)
                continue
            }

            if !processDone, escalationRequested, let killDeadline, hasReached(killDeadline, now: now) {
                processReaped = false
                timedOut = true
                closeOpenPipes(&drains)
                break
            }

            if !processDone || drains.contains(where: { $0.isOpen }) {
                waitForNextPoll(processDone: processDone, hasPipes: drains.contains(where: { $0.isOpen }))
            }
        }

        return ProcessCaptureResult(
            status: processDone && processReaped ? process.terminationStatus : -1,
            stdout: drains[0].bytes,
            stderr: drains[1].bytes,
            timedOut: timedOut
        )
    }

    private static func makeReaderDeadline(after deadline: DispatchTime?) -> DispatchTime? {
        guard let deadline else { return nil }
        let now = DispatchTime.now()
        return (now > deadline ? now : deadline) + cleanupGrace
    }

    private static func hasReached(_ deadline: DispatchTime, now: DispatchTime = .now()) -> Bool {
        now >= deadline
    }

    private static func waitForNextPoll(processDone: Bool, hasPipes: Bool) {
        if !processDone && !hasPipes {
            Thread.sleep(forTimeInterval: Double(pollMilliseconds) / 1_000)
        }
    }

    private static func makeNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private static func drainReadyPipes(_ drains: inout [PipeDrain]) {
        var descriptors: [pollfd] = []
        var indices: [Int] = []
        for (index, drain) in drains.enumerated() where drain.isOpen {
            descriptors.append(pollfd(
                fd: drain.fd,
                events: Int16(POLLIN),
                revents: 0
            ))
            indices.append(index)
        }

        guard !descriptors.isEmpty else { return }
        let ready = descriptors.withUnsafeMutableBufferPointer {
            poll($0.baseAddress, nfds_t($0.count), pollMilliseconds)
        }
        if ready < 0 {
            if errno == EINTR { return }
            closeOpenPipes(&drains)
            return
        }
        guard ready > 0 else { return }

        let events = Int32(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        for slot in descriptors.indices where descriptors[slot].revents != 0 {
            let index = indices[slot]
            guard Int32(descriptors[slot].revents) & events != 0 else { continue }
            readAvailable(from: &drains[index])
        }
    }

    private static func readAvailable(from drain: inout PipeDrain) {
        guard drain.isOpen else { return }
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        let count = buffer.withUnsafeMutableBytes {
            read(drain.fd, $0.baseAddress, $0.count)
        }
        if count > 0 {
            drain.bytes.append(contentsOf: buffer[0..<count])
            return
        }
        if count == 0 {
            close(&drain)
            return
        }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            return
        }
        close(&drain)
    }

    private static func closeOpenPipes(_ drains: inout [PipeDrain]) {
        for index in drains.indices {
            close(&drains[index])
        }
    }

    private static func close(_ drain: inout PipeDrain) {
        guard drain.isOpen else { return }
        drain.isOpen = false
        try? drain.pipe.fileHandleForReading.close()
    }
}
