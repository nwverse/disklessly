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

    /// Reads `input` to its end and writes one zstd frame to `output`.
    public static func compress(from input: FileHandle, to output: FileHandle, level: Int32 = 3) throws {
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
            let chunk = try input.read(upToCount: block) ?? Data()
            if chunk.isEmpty { break }
            try drain(ZSTD_e_continue, chunk)
        }
        try drain(ZSTD_e_end, Data())
    }

    /// Decodes the zstd frames in `input` onto `output`.
    public static func decompress(from input: FileHandle, to output: FileHandle) throws {
        guard let stream = ZSTD_createDStream() else { throw DisklesslyError.failure("zstd could not create a decoder") }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { throw DisklesslyError.integrity("zstd decompress failed") }
        var out = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var last = 0
        while true {
            let chunk = try input.read(upToCount: block) ?? Data()
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
                    if inBuffer.pos >= inBuffer.size && produced < out.count { break }
                }
            }
        }
        guard last == 0 else { throw DisklesslyError.integrity("zstd archive is truncated") }
    }
}
