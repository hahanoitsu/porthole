import AudioToolbox
import Foundation
@testable import PortholeCore

enum TestAudio {
    /// Interleaved stereo: a `left` Hz tone on the left channel and a `right` Hz tone on the right.
    static func tone(frames: Int, left: Double = 440, right: Double = 660, amplitude: Float = 0.5) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let time = Double(frame) / AACELDDecoder.sampleRate
            samples[frame * 2] = amplitude * Float(sin(2 * .pi * left * time))
            samples[frame * 2 + 1] = amplitude * Float(sin(2 * .pi * right * time))
        }
        return samples
    }

    /// Encodes with Apple's AAC-ELD encoder into 480-frame packets, like the phone's.
    static func encodeAACELD(_ samples: [Float]) throws -> (packets: [Data], cookie: [UInt8]) {
        var pcm = AACELDDecoder.pcmFormat
        var eld = AudioStreamBasicDescription()
        eld.mSampleRate = AACELDDecoder.sampleRate
        eld.mFormatID = kAudioFormatMPEG4AAC_ELD
        eld.mChannelsPerFrame = 2
        eld.mFramesPerPacket = UInt32(AACELDDecoder.framesPerPacket)

        var converterRef: AudioConverterRef?
        var status = AudioConverterNew(&pcm, &eld, &converterRef)
        guard status == noErr, let converter = converterRef else { throw TestError.failed("AAC-ELD encoder: \(status)") }
        defer { AudioConverterDispose(converter) }
        var bitRate: UInt32 = 128_000
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate)

        var cookieSize: UInt32 = 0
        var cookie: [UInt8] = []
        if AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &cookieSize, nil) == noErr, cookieSize > 0 {
            cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie)
        }

        var maxPacket: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &propertySize, &maxPacket)

        let source = PCMSource(samples)
        var packets: [Data] = []
        var output = [UInt8](repeating: 0, count: Int(max(maxPacket, 1536)))
        while true {
            var packetCount: UInt32 = 1
            var description = AudioStreamPacketDescription()
            status = output.withUnsafeMutableBytes { raw -> OSStatus in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, PCMSource.supply, Unmanaged.passUnretained(source).toOpaque(),
                                                       &packetCount, &buffers, &description)
            }
            guard packetCount > 0, status == noErr || status == PCMSource.endOfInput else { break }
            packets.append(Data(output[Int(description.mStartOffset)..<Int(description.mStartOffset + Int64(description.mDataByteSize))]))
        }
        return (packets, cookie)
    }

    private final class PCMSource {
        static let endOfInput: OSStatus = 0x656F_6621
        let samples: UnsafeMutablePointer<Float>
        let frames: Int
        var position = 0

        init(_ values: [Float]) {
            frames = values.count / 2
            samples = UnsafeMutablePointer<Float>.allocate(capacity: max(values.count, 1))
            samples.initialize(from: values, count: values.count)
        }

        deinit { samples.deallocate() }

        static let supply: AudioConverterComplexInputDataProc = { _, packetCount, data, _, context in
            let source = Unmanaged<PCMSource>.fromOpaque(context!).takeUnretainedValue()
            let remaining = source.frames - source.position
            guard remaining > 0 else {
                packetCount.pointee = 0
                return PCMSource.endOfInput
            }
            let count = min(remaining, Int(packetCount.pointee))
            data.pointee.mNumberBuffers = 1
            data.pointee.mBuffers.mNumberChannels = 2
            data.pointee.mBuffers.mData = UnsafeMutableRawPointer(source.samples + source.position * 2)
            data.pointee.mBuffers.mDataByteSize = UInt32(count * 8)
            packetCount.pointee = UInt32(count)
            source.position += count
            return noErr
        }
    }

    /// Root mean square of one channel of interleaved stereo.
    static func rms(_ samples: [Float], channel: Int) -> Float {
        var sum: Float = 0
        var count = 0
        var index = channel
        while index < samples.count {
            sum += samples[index] * samples[index]
            count += 1
            index += 2
        }
        return count == 0 ? 0 : (sum / Float(count)).squareRoot()
    }

    /// Rough frequency of one channel, from rising zero crossings.
    static func frequency(_ samples: [Float], channel: Int) -> Double {
        var crossings = 0
        var previous: Float = 0
        var index = channel
        while index < samples.count {
            if previous < 0 && samples[index] >= 0 { crossings += 1 }
            previous = samples[index]
            index += 2
        }
        return Double(crossings) / (Double(samples.count / 2) / AACELDDecoder.sampleRate)
    }
}
