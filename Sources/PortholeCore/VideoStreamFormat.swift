import Foundation

public enum VideoCodec: String, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"
}

/// The stream's codec and parameter sets, from the unencrypted "codec" packet the phone sends at
/// the start and whenever the picture changes shape (for example on rotation).
public struct VideoStreamFormat: Equatable, Sendable {
    public let codec: VideoCodec
    /// H.264: SPS then PPS. HEVC: VPS, SPS, then PPS. Raw NAL units without length prefixes.
    public let parameterSets: [Data]
    /// Picture size the phone reports in the packet header.
    public let width: Int
    public let height: Int
    public let sourceWidth: Int
    public let sourceHeight: Int

    public init(codec: VideoCodec, parameterSets: [Data], width: Int, height: Int, sourceWidth: Int, sourceHeight: Int) {
        self.codec = codec
        self.parameterSets = parameterSets
        self.width = width
        self.height = height
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }

    /// Parses a codec packet: its 128-byte header and unencrypted payload.
    ///
    /// H.264 payloads are an AVCDecoderConfigurationRecord ("avcC"). HEVC payloads are an 'hvc1'
    /// sample entry containing an 'hvcC' box.
    static func parse(header: Data, payload: Data) throws -> VideoStreamFormat {
        guard header.count >= 64 else { throw AirPlayError.badRequest("codec packet header too short") }
        guard !payload.isEmpty else {
            throw AirPlayError.unsupported("empty codec packet: the phone wants a codec we didn't advertise (feature bit 42)")
        }
        let width = Int(header.floatLE(at: 56))
        let height = Int(header.floatLE(at: 60))
        let sourceWidth = Int(header.floatLE(at: 40))
        let sourceHeight = Int(header.floatLE(at: 44))

        if payload.count >= 8 && payload.bytes(at: 4, count: 4) == Data("hvc1".utf8) {
            let sets = try CodecConfiguration.hevcParameterSets(fromSampleEntry: payload)
            return VideoStreamFormat(codec: .hevc, parameterSets: sets, width: width, height: height,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        }
        let sets = try CodecConfiguration.h264ParameterSets(fromAVCC: payload)
        return VideoStreamFormat(codec: .h264, parameterSets: sets, width: width, height: height,
                                 sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
}

enum CodecConfiguration {
    /// SPS(s) followed by PPS(s) from an AVCDecoderConfigurationRecord.
    static func h264ParameterSets(fromAVCC record: Data) throws -> [Data] {
        var reader = Reader(record)
        guard try reader.uint8() == 1 else { throw AirPlayError.badRequest("avcC version is not 1") }
        try reader.skip(3)  // profile, compatibility, level
        let lengthSize = Int(try reader.uint8() & 0x03) + 1
        guard lengthSize == 4 else { throw AirPlayError.unsupported("H.264 NAL length size \(lengthSize)") }

        var sequenceSets: [Data] = []
        for _ in 0..<Int(try reader.uint8() & 0x1f) { sequenceSets.append(try reader.lengthPrefixed()) }
        var pictureSets: [Data] = []
        for _ in 0..<Int(try reader.uint8()) { pictureSets.append(try reader.lengthPrefixed()) }
        guard !sequenceSets.isEmpty, !pictureSets.isEmpty else {
            throw AirPlayError.badRequest("avcC has \(sequenceSets.count) SPS and \(pictureSets.count) PPS")
        }
        return sequenceSets + pictureSets
    }

    /// VPS, SPS and PPS from the 'hvcC' box inside an 'hvc1' sample entry.
    static func hevcParameterSets(fromSampleEntry entry: Data) throws -> [Data] {
        guard let box = entry.range(of: Data("hvcC".utf8)) else { throw AirPlayError.badRequest("no hvcC box in HEVC codec packet") }
        var reader = Reader(entry[box.upperBound...])
        try reader.skip(21)  // version, profile/tier/level, chroma, bit depths, frame rate…
        let lengthSize = Int(try reader.uint8() & 0x03) + 1
        guard lengthSize == 4 else { throw AirPlayError.unsupported("HEVC NAL length size \(lengthSize)") }

        var byType: [UInt8: [Data]] = [:]
        for _ in 0..<Int(try reader.uint8()) {
            let type = try reader.uint8() & 0x3f
            let count = Int(try reader.uint16())
            for _ in 0..<count { byType[type, default: []].append(try reader.lengthPrefixed()) }
        }
        let vps = byType[32] ?? [], sps = byType[33] ?? [], pps = byType[34] ?? []
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else {
            throw AirPlayError.badRequest("hvcC has \(vps.count) VPS, \(sps.count) SPS, \(pps.count) PPS")
        }
        return vps + sps + pps
    }

    private struct Reader {
        private let data: Data
        private var offset = 0

        init(_ data: Data) { self.data = Data(data) }

        mutating func skip(_ count: Int) throws {
            guard offset + count <= data.count else { throw AirPlayError.badRequest("codec record truncated") }
            offset += count
        }

        mutating func uint8() throws -> UInt8 {
            guard offset < data.count else { throw AirPlayError.badRequest("codec record truncated") }
            defer { offset += 1 }
            return data.byte(offset)
        }

        mutating func uint16() throws -> UInt16 {
            guard offset + 2 <= data.count else { throw AirPlayError.badRequest("codec record truncated") }
            defer { offset += 2 }
            return data.uint16BE(at: offset)
        }

        mutating func lengthPrefixed() throws -> Data {
            let length = Int(try uint16())
            guard offset + length <= data.count else { throw AirPlayError.badRequest("codec record truncated") }
            defer { offset += length }
            return data.bytes(at: offset, count: length)
        }
    }
}

/// Helpers for frames in "AVCC" layout: NAL units each prefixed by a 4-byte big-endian length.
public enum NALUnits {
    /// Whether the length prefixes tile the buffer exactly. A failed decryption almost never passes.
    public static func isWellFormed(_ frame: Data) -> Bool {
        guard !frame.isEmpty else { return false }
        var offset = 0
        while offset < frame.count {
            guard offset + 4 <= frame.count else { return false }
            let length = Int(frame.uint32BE(at: offset))
            offset += 4
            guard length > 0, length <= frame.count - offset else { return false }
            if frame.byte(offset) & 0x80 != 0 { return false }  // forbidden_zero_bit
            offset += length
        }
        return offset == frame.count
    }

    /// Whether the frame holds a picture that decodes on its own (H.264 IDR, HEVC IRAP).
    public static func containsKeyFrame(_ frame: Data, codec: VideoCodec) -> Bool {
        var found = false
        forEachType(frame, codec: codec) { type in
            switch codec {
            case .h264: if type == 5 { found = true }
            case .hevc: if (16...21).contains(type) { found = true }
            }
        }
        return found
    }

    public static func types(_ frame: Data, codec: VideoCodec) -> [Int] {
        var types: [Int] = []
        forEachType(frame, codec: codec) { types.append($0) }
        return types
    }

    private static func forEachType(_ frame: Data, codec: VideoCodec, _ body: (Int) -> Void) {
        var offset = 0
        while offset + 5 <= frame.count {
            let length = Int(frame.uint32BE(at: offset))
            let header = frame.byte(offset + 4)
            body(codec == .h264 ? Int(header & 0x1f) : Int((header >> 1) & 0x3f))
            offset += 4 + length
        }
    }
}
