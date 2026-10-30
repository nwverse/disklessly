import Foundation
import IsenoughCore

public enum TarWriter {
    /// ustar member. `name` is ASCII and at most 100 bytes. Mode is 0644.
    public static func append(name: String, data: Data, mtime: Date) -> Data {
        var archive = Data()
        archive.append(header(name: name, size: data.count, mtime: mtime))
        archive.append(data)
        let padding = (512 - (data.count % 512)) % 512
        if padding > 0 { archive.append(Data(count: padding)) }
        archive.append(Data(count: 1024))
        return archive
    }

    public static func archive(_ files: [(name: String, data: Data, mtime: Date)]) throws -> Data {
        for file in files {
            try validate(name: file.name)
        }
        var archive = Data()
        for file in files {
            archive.append(header(name: file.name, size: file.data.count, mtime: file.mtime))
            archive.append(file.data)
            let padding = (512 - (file.data.count % 512)) % 512
            if padding > 0 { archive.append(Data(count: padding)) }
        }
        archive.append(Data(count: 1024))
        return archive
    }

    public static func validate(name: String) throws {
        guard name.count <= 100, name.utf8.allSatisfy({ $0 < 128 }), !name.isEmpty else {
            throw IsenoughError.integrity("tar name must be ASCII and at most 100 bytes")
        }
    }

    private static func header(name: String, size: Int, mtime: Date) -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        writeString(name, into: &bytes, offset: 0, length: 100)
        writeOctal(0o644, into: &bytes, offset: 100, length: 8)
        writeOctal(0, into: &bytes, offset: 108, length: 8)
        writeOctal(0, into: &bytes, offset: 116, length: 8)
        writeOctal(size, into: &bytes, offset: 124, length: 12)
        writeOctal(Int(mtime.timeIntervalSince1970), into: &bytes, offset: 136, length: 12)
        for index in 148..<156 { bytes[index] = 0x20 }
        bytes[156] = UInt8(ascii: "0")
        writeString("ustar", into: &bytes, offset: 257, length: 6)
        bytes[262] = 0
        bytes[263] = UInt8(ascii: "0")
        bytes[264] = UInt8(ascii: "0")
        let sum = bytes.reduce(0) { $0 + Int($1) }
        writeOctal(sum, into: &bytes, offset: 148, length: 8)
        return Data(bytes)
    }

    private static func writeString(_ text: String, into bytes: inout [UInt8], offset: Int, length: Int) {
        let raw = Array(text.utf8)
        for index in 0..<min(raw.count, length) {
            bytes[offset + index] = raw[index]
        }
    }

    private static func writeOctal(_ value: Int, into bytes: inout [UInt8], offset: Int, length: Int) {
        let digits = String(value, radix: 8)
        let field = digits.count < length ? String(repeating: "0", count: length - 1 - digits.count) + digits : String(digits.suffix(length - 1))
        writeString(field, into: &bytes, offset: offset, length: length - 1)
        bytes[offset + length - 1] = 0
    }
}

public enum TarReader {
    public static func entries(_ data: Data) throws -> [(name: String, data: Data)] {
        var offset = 0
        var found: [(name: String, data: Data)] = []
        let bytes = [UInt8](data)
        while offset + 512 <= bytes.count {
            if bytes[offset..<offset + 512].allSatisfy({ $0 == 0 }) { break }
            let type = bytes[offset + 156]
            if type != 0 && type != UInt8(ascii: "0") {
                throw IsenoughError.integrity("unsupported tar entry")
            }
            let nameRaw = bytes[offset..<offset + 100]
            let name = String(decoding: nameRaw.prefix { $0 != 0 }, as: UTF8.self)
            let size = parseOctal(bytes[offset + 124..<offset + 136])
            offset += 512
            guard offset + size <= bytes.count else { throw IsenoughError.integrity("truncated tar entry \(name)") }
            found.append((name, Data(bytes[offset..<offset + size])))
            offset += ((size + 511) / 512) * 512
        }
        return found
    }

    private static func parseOctal(_ field: ArraySlice<UInt8>) -> Int {
        let text = String(decoding: field.filter { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
        return Int(text, radix: 8) ?? 0
    }
}
