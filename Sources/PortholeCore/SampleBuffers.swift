import CoreMedia
import Foundation

/// Turns the stream's parameter sets and frames into what Apple's decoders take.
public enum SampleBuffers {
    public static func formatDescription(for format: VideoStreamFormat) -> CMVideoFormatDescription? {
        let sets = format.parameterSets
        let copies: [UnsafeMutablePointer<UInt8>] = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var description: CMFormatDescription?
        let status: OSStatus
        switch format.codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr else {
            logError("Could not build a \(format.codec.rawValue) format description (OSStatus \(status))")
            return nil
        }
        return description
    }

    /// The picture size in pixels, after cropping.
    public static func presentationSize(of description: CMVideoFormatDescription) -> CGSize {
        CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true)
    }

    /// Wraps one AVCC frame in a sample buffer that a display layer running on the host clock
    /// shows at `displayTime` (`HostClock` seconds), or as soon as it's decoded if that has passed.
    public static func sampleBuffer(frame: Data, description: CMVideoFormatDescription, isKeyFrame: Bool,
                                    displayTime: Double) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: frame.count, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = frame.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var size = frame.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: displayTime, preferredTimescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            set(dictionary, kCMSampleAttachmentKey_NotSync, !isKeyFrame)
            set(dictionary, kCMSampleAttachmentKey_DependsOnOthers, !isKeyFrame)
        }
        return sample
    }

    private static func set(_ dictionary: CFMutableDictionary, _ key: CFString, _ value: Bool) {
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
    }
}
