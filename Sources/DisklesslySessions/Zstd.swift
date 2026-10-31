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
