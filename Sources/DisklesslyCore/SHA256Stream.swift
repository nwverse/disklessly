import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension SHA256Digest {
    /// Incremental SHA-256 for callers outside this module that see the bytes in pieces, such as a streamed upload.
    public struct Stream {
        private var hasher = Hasher()
        public init() {}
        public mutating func update(_ data: Data) { hasher.update(data) }
        public mutating func finalize() -> String { hasher.finalize() }
    }

    /// Incremental SHA-256. The digest matches `hex(_:)`, which is defined as one update of the whole buffer.
    /// On Apple platforms this is CommonCrypto. On Linux it uses libcrypto when that library exports SHA-256,
    /// and otherwise a pure Swift compression function. A backend is kept only after it reproduces the
    /// known digest of "abc".
    struct Hasher {
        private var swift = SwiftCore()
        #if canImport(CommonCrypto)
        private var apple = CC_SHA256_CTX()
        #else
        private var openssl: OpenSSLState?
        #endif
        private var kind: Kind

        fileprivate enum Kind {
            case apple
            case openssl
            case swift
        }

        struct Checkpoint {
            fileprivate var swift: SwiftCore
            fileprivate var opensslBytes: Data?
            #if canImport(CommonCrypto)
            fileprivate var apple: CC_SHA256_CTX
            #endif
            fileprivate var kind: Kind
        }

        init() {
            #if canImport(CommonCrypto)
            CC_SHA256_Init(&apple)
            kind = .apple
            #else
            if let api = OpenSSLAPI.shared {
                openssl = OpenSSLState(api: api)
                kind = .openssl
            } else {
                kind = .swift
            }
            #endif
        }

        mutating func update(_ data: Data) {
            data.withUnsafeBytes { update($0) }
        }

        mutating func update(_ string: String) {
            update(Data(string.utf8))
        }

        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            guard bytes.count > 0, let base = bytes.baseAddress else { return }
            var offset = 0
            let chunk = 1024 * 1024
            while offset < bytes.count {
                let count = min(chunk, bytes.count - offset)
                updateChunk(UnsafeRawBufferPointer(start: base.advanced(by: offset), count: count))
                offset += count
            }
        }

        mutating func checkpoint() -> Checkpoint {
            #if canImport(CommonCrypto)
            Checkpoint(swift: swift, opensslBytes: nil, apple: apple, kind: kind)
            #else
            Checkpoint(swift: swift, opensslBytes: openssl?.snapshot(), kind: kind)
            #endif
        }

        mutating func restore(_ saved: Checkpoint) {
            swift = saved.swift
            kind = saved.kind
            #if canImport(CommonCrypto)
            apple = saved.apple
            #else
            if let bytes = saved.opensslBytes {
                openssl?.restore(bytes)
            }
            #endif
        }

        mutating func finalize() -> String {
            switch kind {
            case .apple:
                #if canImport(CommonCrypto)
                var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                digest.withUnsafeMutableBytes { raw in
                    _ = CC_SHA256_Final(raw.bindMemory(to: UInt8.self).baseAddress, &apple)
                }
                return Self.hex(digest)
                #else
                return swift.finalizeHex()
                #endif
            case .openssl:
                #if canImport(CommonCrypto)
                return swift.finalizeHex()
                #else
                return openssl?.finalizeHex() ?? swift.finalizeHex()
                #endif
            case .swift:
                return swift.finalizeHex()
            }
        }

        private mutating func updateChunk(_ bytes: UnsafeRawBufferPointer) {
            switch kind {
            case .apple:
                #if canImport(CommonCrypto)
                if bytes.count > 0 {
                    _ = CC_SHA256_Update(&apple, bytes.baseAddress, CC_LONG(bytes.count))
                }
                #endif
            case .openssl:
                #if !canImport(CommonCrypto)
                openssl?.update(bytes)
                #endif
            case .swift:
                swift.update(bytes)
            }
        }

        /// The pure Swift compression function, for comparison with the system hasher. Not used for tree hashes.
        static func portableHex(_ data: Data) -> String {
            var core = SwiftCore()
            data.withUnsafeBytes { core.update($0) }
            return core.finalizeHex()
        }

        fileprivate static func hex(_ bytes: [UInt8]) -> String {
            var out = ""
            out.reserveCapacity(bytes.count * 2)
            for byte in bytes {
                out.append(String(format: "%02x", byte))
            }
            return out
        }
    }
}

/// Pure Swift SHA-256, used when no system implementation is available. Padding matches the original
/// one-shot hasher: a 1 bit, zeros to a 56-mod-64 boundary, then the bit length as a big-endian 64-bit integer.
fileprivate struct SwiftCore {
    private var h0: UInt32 = 0x6a09e667
    private var h1: UInt32 = 0xbb67ae85
    private var h2: UInt32 = 0x3c6ef372
    private var h3: UInt32 = 0xa54ff53a
    private var h4: UInt32 = 0x510e527f
    private var h5: UInt32 = 0x9b05688c
    private var h6: UInt32 = 0x1f83d9ab
    private var h7: UInt32 = 0x5be0cd19
    /// Bytes already fed to the compression function. The partial block is extra.
    private var compressed: UInt64 = 0
    private var block = [UInt8](repeating: 0, count: 64)
    private var blockCount = 0

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0, let base = bytes.baseAddress else { return }
        var offset = 0
        if blockCount > 0 {
            let need = 64 - blockCount
            let take = min(need, bytes.count)
            for i in 0..<take {
                block[blockCount + i] = base.advanced(by: offset + i).load(as: UInt8.self)
            }
            blockCount += take
            offset += take
            if blockCount == 64 {
                block.withUnsafeBytes { raw in compress(raw.baseAddress!) }
                blockCount = 0
                compressed &+= 64
            }
        }
        while offset + 64 <= bytes.count {
            compress(base.advanced(by: offset))
            offset += 64
            compressed &+= 64
        }
        if offset < bytes.count {
            let rest = bytes.count - offset
            for i in 0..<rest {
                block[i] = base.advanced(by: offset + i).load(as: UInt8.self)
            }
            blockCount = rest
        }
    }

    mutating func finalizeHex() -> String {
        let total = compressed &+ UInt64(blockCount)
        let bitCount = total &* 8
        block[blockCount] = 0x80
        blockCount += 1
        if blockCount > 56 {
            while blockCount < 64 {
                block[blockCount] = 0
                blockCount += 1
            }
            block.withUnsafeBytes { raw in compress(raw.baseAddress!) }
            blockCount = 0
        }
        while blockCount < 56 {
            block[blockCount] = 0
            blockCount += 1
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            block[blockCount] = UInt8((bitCount >> UInt64(shift)) & 0xff)
            blockCount += 1
        }
        block.withUnsafeBytes { raw in
            compress(raw.baseAddress!)
        }
        let words = [h0, h1, h2, h3, h4, h5, h6, h7]
        return words.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func compress(_ bytes: UnsafeRawPointer) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            for i in 0..<16 {
                let o = i * 4
                w[i] = (UInt32(bytes.load(fromByteOffset: o, as: UInt8.self)) << 24)
                    | (UInt32(bytes.load(fromByteOffset: o + 1, as: UInt8.self)) << 16)
                    | (UInt32(bytes.load(fromByteOffset: o + 2, as: UInt8.self)) << 8)
                    | UInt32(bytes.load(fromByteOffset: o + 3, as: UInt8.self))
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d
            h4 = h4 &+ e; h5 = h5 &+ f; h6 = h6 &+ g; h7 = h7 &+ h
        }
    }

    private func rotr(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}

#if !canImport(CommonCrypto)
private final class OpenSSLAPI {
    typealias InitFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias UpdateFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?, UInt) -> Int32
    typealias FinalFn = @convention(c) (UnsafeMutablePointer<UInt8>?, UnsafeMutableRawPointer) -> Int32

    let handle: UnsafeMutableRawPointer
    let initFn: InitFn
    let updateFn: UpdateFn
    let finalFn: FinalFn

    static let shared: OpenSSLAPI? = OpenSSLAPI.load()

    private init(handle: UnsafeMutableRawPointer, initFn: InitFn, updateFn: UpdateFn, finalFn: FinalFn) {
        self.handle = handle
        self.initFn = initFn
        self.updateFn = updateFn
        self.finalFn = finalFn
    }

    /// SHA256_CTX in OpenSSL 1.1/3 is a 112-byte value type with no pointers, so a byte copy is a valid checkpoint.
    static let contextBytes = 112

    private static func load() -> OpenSSLAPI? {
        let candidates = ["libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so"]
        var opened: UnsafeMutableRawPointer?
        for name in candidates {
            if let handle = dlopen(name, RTLD_NOW) {
                opened = handle
                break
            }
        }
        guard let handle = opened,
              let initRaw = dlsym(handle, "SHA256_Init"),
              let updateRaw = dlsym(handle, "SHA256_Update"),
              let finalRaw = dlsym(handle, "SHA256_Final") else { return nil }
        let api = OpenSSLAPI(
            handle: handle,
            initFn: unsafeBitCast(initRaw, to: InitFn.self),
            updateFn: unsafeBitCast(updateRaw, to: UpdateFn.self),
            finalFn: unsafeBitCast(finalRaw, to: FinalFn.self)
        )
        guard api.acceptsKnownAnswer() else { return nil }
        return api
    }

    private func acceptsKnownAnswer() -> Bool {
        let ctx = UnsafeMutableRawPointer.allocate(byteCount: Self.contextBytes, alignment: 16)
        defer { ctx.deallocate() }
        memset(ctx, 0, Self.contextBytes)
        guard initFn(ctx) == 1 else { return false }
        let abc = Array("abc".utf8)
        let updated = abc.withUnsafeBytes { raw in
            updateFn(ctx, raw.baseAddress, UInt(raw.count))
        }
        guard updated == 1 else { return false }
        var digest = [UInt8](repeating: 0, count: 32)
        let wrote = digest.withUnsafeMutableBufferPointer { buffer in
            finalFn(buffer.baseAddress, ctx)
        }
        return wrote == 1 && SHA256Digest.Hasher.hex(digest) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    }
}

private final class OpenSSLState {
    let api: OpenSSLAPI
    let ptr: UnsafeMutableRawPointer

    init(api: OpenSSLAPI) {
        self.api = api
        ptr = UnsafeMutableRawPointer.allocate(byteCount: OpenSSLAPI.contextBytes, alignment: 16)
        memset(ptr, 0, OpenSSLAPI.contextBytes)
        _ = api.initFn(ptr)
    }

    deinit { ptr.deallocate() }

    func update(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        _ = api.updateFn(ptr, bytes.baseAddress, UInt(bytes.count))
    }

    func finalizeHex() -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        _ = digest.withUnsafeMutableBufferPointer { buffer in
            api.finalFn(buffer.baseAddress, ptr)
        }
        return SHA256Digest.Hasher.hex(digest)
    }

    func snapshot() -> Data {
        Data(bytes: ptr, count: OpenSSLAPI.contextBytes)
    }

    func restore(_ data: Data) {
        guard data.count == OpenSSLAPI.contextBytes else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(ptr, base, OpenSSLAPI.contextBytes)
        }
    }
}
#endif
