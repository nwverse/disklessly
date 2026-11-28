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

/// Runs a child with both output pipes drained concurrently. Reading only one
/// side before waiting can deadlock as soon as the other side fills its pipe.
public enum ProcessCapture {
    private final class Buffer {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }

        func read() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }

    public static func run(_ process: Process, timeout: TimeInterval? = nil) throws -> ProcessCaptureResult {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        let out = Buffer()
        let err = Buffer()
        let readers = DispatchGroup()
        for (pipe, buffer) in [(stdout, out), (stderr, err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }

        var timedOut = false
        var exited = true
        if let timeout, timeout > 0 {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if finished.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited = finished.wait(timeout: .now() + 2) == .success
                }
            }
        } else {
            finished.wait()
        }

        if timedOut {
            _ = readers.wait(timeout: .now() + 2)
        } else {
            readers.wait()
        }
        return ProcessCaptureResult(
            status: exited ? process.terminationStatus : -1,
            stdout: out.read(),
            stderr: err.read(),
            timedOut: timedOut
        )
    }
}
