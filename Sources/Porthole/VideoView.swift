import AppKit
import AVFoundation
import CoreImage
import PortholeCore

/// Shows the mirrored screen. AVSampleBufferDisplayLayer decodes H.264/HEVC on the GPU's video
/// hardware and scales the picture to the view, keeping its aspect ratio. The layer runs on the
/// host clock, so each frame appears at its `displayTime` (see FramePacer).
///
/// `setFormat`, `enqueue` and `reset` must all be called on the same serial queue.
final class VideoView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyFrame = true
    private var showingFrames = false
    /// Set when a decoder failure left us waiting for a key frame. The phone only sends one when
    /// the stream starts or changes shape, so this wait can be long.
    private var recovering = false
    private let metrics = DisplayMetrics()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        var timebase: CMTimebase?
        let hostClock = CMClockGetHostTimeClock()
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: hostClock, timebaseOut: &timebase) == noErr,
           let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(hostClock))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        } else {
            logError("Could not make a host-clock timebase; frames may not appear")
        }
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func makeBackingLayer() -> CALayer { displayLayer }

    /// Sets up decoding for a new stream format. Returns the picture size in pixels.
    func setFormat(_ format: VideoStreamFormat) -> CGSize? {
        guard let description = SampleBuffers.formatDescription(for: format) else { return nil }
        formatDescription = description
        waitingForKeyFrame = true
        let size = SampleBuffers.presentationSize(of: description)
        logInfo("Decoding \(format.codec.rawValue) at \(Int(size.width))x\(Int(size.height))")
        return size
    }

    /// Queues one frame for display. Returns true for the first frame shown since the last reset.
    @discardableResult
    func enqueue(_ frame: VideoFrame) -> Bool {
        guard let description = formatDescription else { return false }
        if waitingForKeyFrame && !frame.isKeyFrame { return false }
        if recovering && frame.isKeyFrame {
            logInfo("Got a key frame; the picture is back")
            recovering = false
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            let reason = renderer.status == .failed ? "decoder error: \(renderer.error.map { "\($0)" } ?? "unknown")" : "decoder needs a restart"
            renderer.flush()
            if !frame.isKeyFrame {
                logWarning("Video \(reason). Waiting for a key frame; the phone sends one when it rotates or mirroring restarts")
                waitingForKeyFrame = true
                recovering = true
                return false
            }
            logWarning("Video \(reason); restarted on a key frame")
        }

        guard let sample = SampleBuffers.sampleBuffer(frame: frame.data, description: description,
                                                      isKeyFrame: frame.isKeyFrame, displayTime: frame.displayTime) else {
            logWarning("Could not wrap a \(frame.data.count)-byte frame for decoding")
            return false
        }
        renderer.enqueue(sample)
        waitingForKeyFrame = false
        metrics.frameEnqueued(renderer)

        let first = !showingFrames
        showingFrames = true
        return first
    }

    /// Clears the picture and forgets the stream format.
    func reset() {
        formatDescription = nil
        waitingForKeyFrame = true
        showingFrames = false
        recovering = false
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        metrics.reset()
    }

    /// The frame on screen right now as PNG data, or nil if nothing is showing.
    func snapshotPNG() -> Data? {
        guard #available(macOS 14.4, *),
              let pixelBuffer = displayLayer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

/// Every 10 seconds, logs the display layer's own count of frames and of frames it dropped: ones
/// that came due together, where only the newest is shown (the rest are still decoded). Steady
/// pacing shows up as few drops. (The layer's accumulated-delay metric stays at zero even for
/// overdue frames, so it isn't logged.)
private final class DisplayMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = 0.0  // video queue only
    private var previous: (frames: Int, dropped: Int)?  // under lock

    func frameEnqueued(_ renderer: AVSampleBufferVideoRenderer) {
        let now = HostClock.now
        guard now - lastReport >= 10 else { return }
        let first = lastReport == 0
        lastReport = now
        guard #available(macOS 14.4, *) else { return }
        renderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics else { return }
            self.report(frames: metrics.totalNumberOfFrames, dropped: metrics.numberOfDroppedFrames, log: !first)
        }
    }

    func reset() {
        lastReport = 0
        lock.lock()
        previous = nil
        lock.unlock()
    }

    private func report(frames: Int, dropped: Int, log: Bool) {
        lock.lock()
        let before = previous.flatMap { $0.frames <= frames ? $0 : nil } ?? (frames: 0, dropped: 0)
        previous = (frames, dropped)
        lock.unlock()
        guard log else { return }
        logInfo("Display: \(frames - before.frames) frames, \(dropped - before.dropped) dropped")
    }
}
