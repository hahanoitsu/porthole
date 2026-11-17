import Foundation

// Offset-based readers. Offsets are relative to `startIndex`, so they are safe on slices.
extension Data {
    @inline(__always)
    func byte(_ offset: Int) -> UInt8 { self[startIndex + offset] }

    func uint16BE(at offset: Int) -> UInt16 {
        UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1))
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(byte(offset)) | UInt32(byte(offset + 1)) << 8 | UInt32(byte(offset + 2)) << 16 | UInt32(byte(offset + 3)) << 24
    }

    func uint32BE(at offset: Int) -> UInt32 {
        UInt32(byte(offset)) << 24 | UInt32(byte(offset + 1)) << 16 | UInt32(byte(offset + 2)) << 8 | UInt32(byte(offset + 3))
    }

    func uint64BE(at offset: Int) -> UInt64 {
        UInt64(uint32BE(at: offset)) << 32 | UInt64(uint32BE(at: offset + 4))
    }

    func uint64LE(at offset: Int) -> UInt64 {
        UInt64(uint32LE(at: offset)) | UInt64(uint32LE(at: offset + 4)) << 32
    }

    func floatLE(at offset: Int) -> Float { Float(bitPattern: uint32LE(at: offset)) }

    /// A zero-based copy of `length` bytes starting at `offset`.
    func bytes(at offset: Int, count length: Int) -> Data {
        Data(self[(startIndex + offset)..<(startIndex + offset + length)])
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32(value >> 32))
        appendUInt32BE(UInt32(value & 0xffff_ffff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 24 & 0xff)])
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendUInt32LE(UInt32(value & 0xffff_ffff))
        appendUInt32LE(UInt32(value >> 32))
    }

    mutating func appendFloatLE(_ value: Float) { appendUInt32LE(value.bitPattern) }
}

/// A one-line description of a binary plist body, for logs. Data values show only their size.
func describePlist(_ body: Data) -> String {
    guard !body.isEmpty else { return "(empty)" }
    guard let value = try? PropertyListSerialization.propertyList(from: body, format: nil) else {
        return hexPreview(body, limit: 24)
    }
    func describe(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            return "{" + dictionary.keys.sorted().map { "\($0): \(describe(dictionary[$0]!))" }.joined(separator: ", ") + "}"
        case let array as [Any]:
            return "[" + array.map(describe).joined(separator: ", ") + "]"
        case let data as Data:
            return "<\(data.count) bytes>"
        case let string as String:
            return "\"\(string)\""
        default:
            return "\(value)"
        }
    }
    return describe(value)
}

/// "00 11 22 …" for logs, truncated to `limit` bytes.
func hexPreview(_ data: Data, limit: Int = 32) -> String {
    let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    return data.count > limit ? "\(shown) … (\(data.count) bytes)" : shown
}
