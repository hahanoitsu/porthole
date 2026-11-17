import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox
import XCTest
@testable import PortholeCore

enum TestError: Error {
    case failed(String)
}

func randomData(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

func binaryPlist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}

func plistDictionary(_ data: Data) throws -> [String: Any] {
    guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw TestError.failed("not a plist dictionary")
    }
    return dictionary
}

/// Frames from VideoToolbox's encoder, in the same layout an iPhone sends.
struct EncodedVideo {
    let codec: VideoCodec
    let width: Int
    let height: Int
    /// The avcC or hvcC record.
    let configurationRecord: Data
    let frames: [(data: Data, isKeyFrame: Bool)]

    /// The unencrypted payload of a codec packet: avcC as is, or hvcC inside an 'hvc1' sample entry.
    var codecPacketPayload: Data {
        switch codec {
        case .h264:
            return configurationRecord
        case .hevc:
            var box = Data()
            box.appendUInt32BE(UInt32(8 + configurationRecord.count))
            box.append(Data("hvcC".utf8))
            box.append(configurationRecord)
            var entry = Data()
            entry.appendUInt32BE(UInt32(8 + 78 + box.count))
            entry.append(Data("hvc1".utf8))
            entry.append(Data(count: 78))  // visual sample entry fields
            entry.append(box)
            return entry
        }
    }

    static func make(_ codec: VideoCodec, width: Int = 240, height: Int = 432, frameCount: Int = 12) throws -> EncodedVideo {
        var session: VTCompressionSession?
        let codecType = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw TestError.failed("VTCompressionSessionCreate: \(status)") }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 6 as CFNumber)

        let lock = NSLock()
        var samples: [CMSampleBuffer] = []
        for index in 0..<frameCount {
            let image = try pixelBuffer(width: width, height: height, frame: index)
            status = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                                                     presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                guard let sample else { return }
                lock.lock()
                samples.append(sample)
                lock.unlock()
            }
            guard status == noErr else { throw TestError.failed("encode: \(status)") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)

        guard let first = samples.first, let description = CMSampleBufferGetFormatDescription(first) else {
            throw TestError.failed("encoder produced no frames")
        }
        let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        guard let record = atoms?[codec == .h264 ? "avcC" : "hvcC"] as? Data else {
            throw TestError.failed("no configuration record in the encoder's format description")
        }

        let frames: [(Data, Bool)] = try samples.map { sample in
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw TestError.failed("sample without data") }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            return (data, !notSync)
        }
        return EncodedVideo(codec: codec, width: width, height: height, configurationRecord: record, frames: frames)
    }

    private static func pixelBuffer(width: Int, height: Int, frame: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw TestError.failed("CVPixelBufferCreate") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = UInt8((x + frame * 9) & 0xff)
                pixel[1] = UInt8((y + frame * 5) & 0xff)
                pixel[2] = UInt8((x ^ y) & 0xff)
                pixel[3] = 0xff
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

func decodedFrameCount(_ frames: [(data: Data, isKeyFrame: Bool)], format: VideoStreamFormat) throws -> Int {
    let timed = frames.enumerated().map { VideoFrame(data: $1.data, isKeyFrame: $1.isKeyFrame, displayTime: Double($0) / 60) }
    return try decodedFrameCount(timed, format: format)
}

/// Decodes frames the way the app will (same format description and sample buffers) and
/// returns how many produced a picture.
func decodedFrameCount(_ frames: [VideoFrame], format: VideoStreamFormat) throws -> Int {
    guard let description = SampleBuffers.formatDescription(for: format) else { throw TestError.failed("no format description") }
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                              imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
    guard status == noErr, let session else { throw TestError.failed("VTDecompressionSessionCreate: \(status)") }
    let lock = NSLock()
    var decoded = 0
    for frame in frames {
        guard let sample = SampleBuffers.sampleBuffer(frame: frame.data, description: description,
                                                      isKeyFrame: frame.isKeyFrame, displayTime: frame.displayTime) else {
            throw TestError.failed("could not build a sample buffer")
        }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr && image != nil {
                lock.lock()
                decoded += 1
                lock.unlock()
            }
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    VTDecompressionSessionInvalidate(session)
    return decoded
}

/// A 128-byte mirror-stream packet header followed by its payload.
func mirrorPacket(type: UInt8, option: UInt8 = 0, payload: Data, width: Float = 0, height: Float = 0, timestamp: UInt64 = 0) -> Data {
    var header = Data()
    header.appendUInt32LE(UInt32(payload.count))
    header.append(contentsOf: [type, 0, option, type == 1 ? 1 : 0])
    header.appendUInt64LE(timestamp)
    header.appendFloatLE(width)
    header.appendFloatLE(height)
    header.append(Data(count: 16))   // 24-39
    header.appendFloatLE(width)      // 40: source width
    header.appendFloatLE(height)     // 44: source height
    header.append(Data(count: 8))    // 48-55: offsets
    header.appendFloatLE(width)      // 56
    header.appendFloatLE(height)     // 60
    header.append(Data(count: 128 - header.count))
    return header + payload
}

func connectTCP(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestError.failed("socket") }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    Sockets.setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else {
        close(fd)
        throw TestError.failed("connect to port \(port): \(String(cString: strerror(errno)))")
    }
    return fd
}

/// Plays the phone's side of the RTSP conversation.
final class TestRTSPClient {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private let fd: Int32
    private var sequence = 0

    init(port: UInt16) throws {
        fd = try connectTCP(port: port)
    }

    deinit { close(fd) }

    func request(_ method: String, _ uri: String, body: Data = Data(), contentType: String? = nil) throws -> Response {
        sequence += 1
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(sequence)\r\nUser-Agent: AirPlay/999.1\r\n"
        if let contentType { text += "Content-Type: \(contentType)\r\n" }
        if !body.isEmpty { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        guard Sockets.writeAll(fd, Data(text.utf8) + body) else { throw TestError.failed("send \(method)") }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let status = Int(head[0].split(separator: " ")[1]) ?? 0
                var headers: [String: String] = [:]
                for line in head.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if buffer.endIndex - end.upperBound >= length {
                    return Response(status: status, headers: headers, body: Data(buffer[end.upperBound..<(end.upperBound + length)]))
                }
            }
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { throw TestError.failed("no response to \(method) \(uri)") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
