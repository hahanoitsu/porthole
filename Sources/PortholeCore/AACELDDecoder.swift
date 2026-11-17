import AudioToolbox
import Foundation

/// Decodes AirPlay mirror audio: AAC-ELD, 44.1 kHz, stereo, 480 samples per packet, into
/// interleaved Float32 samples.
final class AACELDDecoder {
    static let sampleRate = 44_100.0
    static let channels = 2
    static let framesPerPacket = 480
    /// AudioSpecificConfig for that format (object type 39, 44.1 kHz, 2 channels, 480-sample
    /// frames). UxPlay hands GStreamer the same four bytes.
    static let audioSpecificConfig: [UInt8] = [0xf8, 0xe8, 0x50, 0x00]

    private static let endOfInput: OSStatus = 0x656F_6621  // 'eof!'

    private let converter: AudioConverterRef
    private let input = InputState()
    /// Whether the decoder took the codec config. It decodes without it, going by the format alone.
    let acceptedCodecConfig: Bool

    /// The config wrapped in an MPEG-4 ES descriptor ("esds"), the cookie form AudioToolbox
    /// takes, built exactly as Apple's own AAC-ELD encoder writes it.
    static func esdsCookie(audioSpecificConfig config: [UInt8], bitRate: UInt32 = 128_000) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, 0x80, 0x80, 0x80, UInt8(body.count)] + body }
        func bigEndian(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
        let decoderConfig: [UInt8] = [0x40, 0x14, 0x00, 0x18, 0x00]  // MPEG-4 audio, audio stream, buffer size
            + bigEndian(bitRate) + bigEndian(bitRate) + descriptor(0x05, config)
        return descriptor(0x03, [0x00, 0x00, 0x00] + descriptor(0x04, decoderConfig) + descriptor(0x06, [0x02]))
    }

    init(magicCookie: [UInt8] = AACELDDecoder.esdsCookie(audioSpecificConfig: AACELDDecoder.audioSpecificConfig)) throws {
        var compressed = AudioStreamBasicDescription()
        compressed.mSampleRate = Self.sampleRate
        compressed.mFormatID = kAudioFormatMPEG4AAC_ELD
        compressed.mChannelsPerFrame = UInt32(Self.channels)
        compressed.mFramesPerPacket = UInt32(Self.framesPerPacket)
        var pcm = Self.pcmFormat

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&compressed, &pcm, &converter)
        guard status == noErr, let converter else {
            throw AirPlayError.unsupported("no AAC-ELD decoder (OSStatus \(status))")
        }
        self.converter = converter

        var cookie = magicCookie
        let cookieStatus = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), &cookie)
        acceptedCodecConfig = cookieStatus == noErr
        if !acceptedCodecConfig { logWarning("AAC-ELD decoder did not take the codec config (OSStatus \(cookieStatus))") }
    }

    deinit {
        AudioConverterDispose(converter)
    }

    static var pcmFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    /// Decodes one packet. Returns interleaved stereo samples (normally 480 frames), or nil on error.
    func decode(_ packet: Data) -> [Float]? {
        guard !packet.isEmpty else { return nil }
        input.load(packet)

        var frames = UInt32(Self.framesPerPacket)
        var samples = [Float](repeating: 0, count: Self.framesPerPacket * Self.channels)
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var buffers = AudioBufferList(mNumberBuffers: 1,
                                          mBuffers: AudioBuffer(mNumberChannels: UInt32(Self.channels),
                                                                mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, Self.supplyPacket, Unmanaged.passUnretained(input).toOpaque(),
                                                   &frames, &buffers, nil)
        }
        guard status == noErr || status == Self.endOfInput else { return nil }
        return Array(samples.prefix(Int(frames) * Self.channels))
    }

    /// Hands the converter the one packet we have, then reports there is no more.
    private static let supplyPacket: AudioConverterComplexInputDataProc = { _, packetCount, data, descriptions, context in
        let input = Unmanaged<InputState>.fromOpaque(context!).takeUnretainedValue()
        guard !input.consumed else {
            packetCount.pointee = 0
            return AACELDDecoder.endOfInput
        }
        input.consumed = true
        packetCount.pointee = 1
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mData = input.bytes
        data.pointee.mBuffers.mDataByteSize = input.size
        data.pointee.mBuffers.mNumberChannels = UInt32(AACELDDecoder.channels)
        input.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: input.size)
        descriptions?.pointee = input.description
        return noErr
    }

    /// Stable memory for the packet being decoded, alive across the converter's callbacks.
    private final class InputState {
        private(set) var bytes: UnsafeMutableRawPointer
        private var capacity = 2048
        private(set) var size: UInt32 = 0
        var consumed = true
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

        init() {
            bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        }

        deinit {
            bytes.deallocate()
            description.deallocate()
        }

        func load(_ packet: Data) {
            if packet.count > capacity {
                bytes.deallocate()
                capacity = packet.count
                bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            }
            packet.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: packet.count)
            size = UInt32(packet.count)
            consumed = false
        }
    }
}
