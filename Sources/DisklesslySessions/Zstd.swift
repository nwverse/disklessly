import Foundation
import DisklesslyCore
import libzstd

public enum Zstd {
    public static func compress(_ input: Data, level: Int32 = 3) throws -> Data {
        let bound = ZSTD_compressBound(input.count)
        var destination = Data(count: bound)
        let written: Int = destination.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                ZSTD_compress(dst.baseAddress, dst.count, src.baseAddress, src.count, Int32(level))
            }
        }
        guard ZSTD_isError(written) == 0 else {
            throw DisklesslyError.failure("zstd compress failed")
        }
        return destination.prefix(written)
    }

    public static func decompress(_ input: Data, maxBytes: Int) throws -> Data {
        guard let stream = ZSTD_createDStream() else {
            throw DisklesslyError.failure("zstd could not create a decoder")
        }
        defer { ZSTD_freeDStream(stream) }
        let primed = ZSTD_initDStream(stream)
        guard ZSTD_isError(primed) == 0 else {
            throw DisklesslyError.integrity("zstd decompress failed")
        }
        var output = Data()
        var finished = false
        try input.withUnsafeBytes { src in
            var inputBuffer = ZSTD_inBuffer(src: src.baseAddress, size: src.count, pos: 0)
            var block = [UInt8](repeating: 0, count: 64 * 1024)
            while !finished {
                let produced: Int = try block.withUnsafeMutableBytes { raw in
                    var outputBuffer = ZSTD_outBuffer(dst: raw.baseAddress, size: raw.count, pos: 0)
                    let code = ZSTD_decompressStream(stream, &outputBuffer, &inputBuffer)
                    guard ZSTD_isError(code) == 0 else {
                        throw DisklesslyError.integrity("zstd decompress failed")
                    }
                    if code == 0 { finished = true }
                    return outputBuffer.pos
                }
                if output.count + produced > maxBytes {
                    throw DisklesslyError.integrity("decompressed session exceeds \(maxBytes) bytes")
                }
                if produced > 0 {
                    output.append(contentsOf: block.prefix(produced))
                } else if inputBuffer.pos >= inputBuffer.size {
                    break
                }
            }
        }
        return output
    }
}

/// Streaming zstd for archives too large to hold in memory (offloaded folders).
public enum ZstdStream {
    static let block = 1 << 20
    static let parallelBlock = 4 << 20

    /// Worker count for parallel streaming compression. Overridden by `DISKLESSLY_ZSTD_WORKERS`.
    public static func defaultWorkers(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let raw = environment["DISKLESSLY_ZSTD_WORKERS"], let parsed = Int(raw), parsed > 0 {
            return min(16, max(1, parsed))
        }
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6))
    }

    private static func readBlock(from input: FileHandle, maxBytes: Int) throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(min(maxBytes, block))
        while buffer.count < maxBytes {
            let chunk = try autoreleasepool { try input.read(upToCount: maxBytes - buffer.count) } ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return buffer
    }

    /// Reads `input` to its end and writes a standard zstd stream (single-frame or
    /// ordered multi-frame when `workers > 1`) to `output`.
    public static func compress(from input: FileHandle, to output: FileHandle, level: Int32 = 3, workers: Int = defaultWorkers()) throws {
        let activeWorkers = max(1, workers)
        if activeWorkers <= 1 {
            try compressSingle(from: input, to: output, level: level)
            return
        }
        let firstBlock = try readBlock(from: input, maxBytes: parallelBlock)
        if firstBlock.isEmpty {
            try output.write(contentsOf: try Zstd.compress(Data(), level: level))
            return
        }

        let maxInFlight = activeWorkers * 2
        let state = OrderedFrameBuffer(maxInFlight: maxInFlight)
        let workerGroup = DispatchGroup()
        let writerGroup = DispatchGroup()
        let cpuSem = DispatchSemaphore(value: activeWorkers)

        writerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { writerGroup.leave() }
            var expected = 0
            while let frame = state.takeNext(expected: expected) {
                do {
                    try output.write(contentsOf: frame)
                    state.releaseSlot()
                    expected += 1
                } catch {
                    state.abort(error)
                    break
                }
            }
        }

        func schedule(seq: Int, chunk: Data) {
            cpuSem.wait()
            if state.isAborted {
                cpuSem.signal()
                state.releaseSlot()
                return
            }
            workerGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { cpuSem.signal(); workerGroup.leave() }
                if state.isAborted {
                    state.releaseSlot()
                    return
                }
                do {
                    let compressed = try Zstd.compress(chunk, level: level)
                    state.store(seq: seq, frame: compressed)
                } catch {
                    state.abort(error)
                }
            }
        }

        var seq = 0
        if state.reserveSlot() {
            schedule(seq: seq, chunk: firstBlock)
            seq += 1
            while !state.isAborted {
                let nextChunk: Data
                do {
                    nextChunk = try readBlock(from: input, maxBytes: parallelBlock)
                } catch {
                    state.abort(error)
                    break
                }
                if nextChunk.isEmpty { break }
                guard state.reserveSlot() else { break }
                schedule(seq: seq, chunk: nextChunk)
                seq += 1
            }
        }

        workerGroup.wait()
        state.finish(totalFrames: seq)
        writerGroup.wait()
        if let error = state.storedError { throw error }
    }

    private static func compressSingle(from input: FileHandle, to output: FileHandle, level: Int32) throws {
        guard let stream = ZSTD_createCStream() else { throw DisklesslyError.failure("zstd could not create an encoder") }
        defer { ZSTD_freeCStream(stream) }
        guard ZSTD_isError(ZSTD_initCStream(stream, level)) == 0 else { throw DisklesslyError.failure("zstd compress failed") }
        var out = [UInt8](repeating: 0, count: ZSTD_CStreamOutSize())
        func drain(_ mode: ZSTD_EndDirective, _ chunk: Data) throws {
            try chunk.withUnsafeBytes { src in
                var inBuffer = ZSTD_inBuffer(src: src.baseAddress, size: src.count, pos: 0)
                while true {
                    var remaining = 0
                    let produced: Int = try out.withUnsafeMutableBytes { raw in
                        var outBuffer = ZSTD_outBuffer(dst: raw.baseAddress, size: raw.count, pos: 0)
                        remaining = ZSTD_compressStream2(stream, &outBuffer, &inBuffer, mode)
                        guard ZSTD_isError(remaining) == 0 else { throw DisklesslyError.failure("zstd compress failed") }
                        return outBuffer.pos
                    }
                    if produced > 0 { try output.write(contentsOf: Data(out.prefix(produced))) }
                    let done = mode == ZSTD_e_end ? remaining == 0 : inBuffer.pos >= inBuffer.size
                    if done { break }
                }
            }
        }
        while true {
            let chunk = try autoreleasepool { try input.read(upToCount: block) } ?? Data()
            if chunk.isEmpty { break }
            try drain(ZSTD_e_continue, chunk)
        }
        try drain(ZSTD_e_end, Data())
    }

    private final class OrderedFrameBuffer: @unchecked Sendable {
        private let cond = NSCondition()
        private let maxInFlight: Int
        private var inFlight = 0
        private var frames: [Int: Data] = [:]
        private var totalFrames: Int?
        private var aborted = false
        private var error: Error?

        init(maxInFlight: Int) { self.maxInFlight = maxInFlight }

        var isAborted: Bool {
            cond.lock(); defer { cond.unlock() }
            return aborted
        }

        var storedError: Error? {
            cond.lock(); defer { cond.unlock() }
            return error
        }

        func reserveSlot() -> Bool {
            cond.lock(); defer { cond.unlock() }
            while inFlight >= maxInFlight && !aborted { cond.wait() }
            if aborted { return false }
            inFlight += 1
            return true
        }

        func releaseSlot() {
            cond.lock()
            if inFlight > 0 { inFlight -= 1 }
            cond.broadcast()
            cond.unlock()
        }

        func store(seq: Int, frame: Data) {
            cond.lock()
            if !aborted { frames[seq] = frame }
            cond.broadcast()
            cond.unlock()
        }

        func abort(_ err: Error) {
            cond.lock()
            if error == nil { error = err }
            aborted = true
            frames.removeAll()
            cond.broadcast()
            cond.unlock()
        }

        func finish(totalFrames: Int) {
            cond.lock()
            self.totalFrames = totalFrames
            cond.broadcast()
            cond.unlock()
        }

        func takeNext(expected: Int) -> Data? {
            cond.lock(); defer { cond.unlock() }
            while !aborted {
                if let frame = frames.removeValue(forKey: expected) { return frame }
                if let total = totalFrames, expected >= total { return nil }
                cond.wait()
            }
            return nil
        }
    }

    /// Decodes the zstd frames in `input` onto `output`.
    public static func decompress(from input: FileHandle, to output: FileHandle) throws {
        guard let stream = ZSTD_createDStream() else { throw DisklesslyError.failure("zstd could not create a decoder") }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { throw DisklesslyError.integrity("zstd decompress failed") }
        var out = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var last = 0
        while true {
            let chunk = try autoreleasepool { try input.read(upToCount: block) } ?? Data()
            if chunk.isEmpty { break }
            try chunk.withUnsafeBytes { src in
                var inBuffer = ZSTD_inBuffer(src: src.baseAddress, size: src.count, pos: 0)
                while true {
                    let produced: Int = try out.withUnsafeMutableBytes { raw in
                        var outBuffer = ZSTD_outBuffer(dst: raw.baseAddress, size: raw.count, pos: 0)
                        last = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                        guard ZSTD_isError(last) == 0 else { throw DisklesslyError.integrity("zstd decompress failed") }
                        return outBuffer.pos
                    }
                    if produced > 0 { try output.write(contentsOf: Data(out.prefix(produced))) }
                    if inBuffer.pos >= inBuffer.size && (produced < out.count || last == 0) { break }
                }
            }
        }
        guard last == 0 else { throw DisklesslyError.integrity("zstd archive is truncated") }
    }
}
