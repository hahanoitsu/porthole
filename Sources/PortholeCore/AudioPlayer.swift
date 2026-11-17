import AVFoundation
import Foundation
import os

/// Where decoded audio goes. The receiver makes one per audio stream.
protocol AudioSink: AnyObject {
    func start()
    func stop()
    /// Interleaved stereo Float32 samples at 44.1 kHz; the first is RTP sample `rtpTime`.
    func enqueue(_ samples: [Float], rtpTime: Int64)
    /// From now on, plays RTP sample R so it's heard at host time `base + R / 44100`; nil plays
    /// sound as it comes.
    func schedule(heardTimeOfSampleZero base: Double?)
    /// The output device's own delay in seconds (AirPods add about 0.16 s).
    var outputLatency: Double { get }
    /// Drops queued audio, for when the phone restarts its stream.
    func flush()
    var isMuted: Bool { get set }
    /// Linear gain from the phone's volume buttons.
    var gain: Float { get set }
    /// How playback went since the last call, for the periodic log line.
    func takeWindowSummary() -> String?
}

extension AudioSink {
    func takeWindowSummary() -> String? { nil }
    func schedule(heardTimeOfSampleZero base: Double?) {}
    var outputLatency: Double { 0 }
}

/// Plays decoded audio through the Mac's current output device.
final class AudioPlayer: AudioSink {
    private let engine = AVAudioEngine()
    /// Sound follows the phone's schedule once it's known. Until then it starts once 100 ms is
    /// queued, and past 400 ms the oldest is dropped.
    private let ring = SampleRing(sampleRate: AACELDDecoder.sampleRate, targetLatency: 0.10, maxLatency: 0.40)
    private let queue = DispatchQueue(label: "porthole.audio.output")
    private var source: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?
    private var running = false

    var isMuted: Bool {
        get { ring.isMuted }
        set { ring.isMuted = newValue }
    }

    var gain: Float {
        get { ring.gain }
        set { ring.gain = newValue }
    }

    func start() {
        queue.async { [self] in
            guard !running, let format = AVAudioFormat(standardFormatWithSampleRate: AACELDDecoder.sampleRate, channels: 2) else { return }
            let ring = self.ring
            let secondsPerTick = HostClock.secondsPerTick
            let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList in
                // When this buffer goes out to the device, in host-clock seconds.
                let stamp = timestamp.pointee
                let outputTime = stamp.mFlags.contains(.hostTimeValid) ? Double(stamp.mHostTime) * secondsPerTick : HostClock.now
                ring.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList), outputTime: outputTime)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.restartAfterDeviceChange()
            }
            do {
                try engine.start()
                running = true
                logInfo("Audio output started\(isMuted ? " (muted)" : ""); the output device adds \(updateOutputLatency()) ms")
            } catch {
                logError("Could not start audio output: \(error)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
            engine.stop()
            if let source { engine.detach(source) }
            source = nil
            if running {
                let stats = ring.statistics
                logInfo("Audio output stopped (\(stats.underruns) underrun(s), \(stats.droppedFrames) frames dropped to limit delay)")
            }
            running = false
            ring.reset()
        }
    }

    func enqueue(_ samples: [Float], rtpTime: Int64) {
        ring.write(samples, rtpTime: rtpTime, arrival: HostClock.now)
    }

    func schedule(heardTimeOfSampleZero base: Double?) {
        ring.scheduleBase = base
    }

    var outputLatency: Double { ring.outputLatency }

    func flush() {
        ring.reset()
    }

    func takeWindowSummary() -> String? {
        let window = ring.takeWindowStatistics()
        let milliseconds = { (frames: Int) in Int(Double(frames) / AACELDDecoder.sampleRate * 1000) }
        var text = ring.scheduleBase != nil ? "on the phone's schedule"
            : "buffer \(Int(ring.targetLatency * 1000)) ms (peak \(milliseconds(window.peakFrames)) ms)"
        text += ", \(window.underruns) dropout(s)"
        if window.skippedFrames > 0 { text += ", \(milliseconds(window.skippedFrames)) ms skipped to keep time" }
        if window.droppedFrames > 0 { text += ", \(milliseconds(window.droppedFrames)) ms trimmed" }
        if let delay = ring.soundDelay { text += "; heard \(Int(delay * 1000)) ms after arriving" }
        if isMuted { text += ", muted" }
        if let timing = ring.timing {
            logDebug("Audio timing: the quickest packets arrive \(timing.quickest) s after their RTP time and are heard \(timing.heard) s after it")
        }
        return text
    }

    /// The output device's own delay (AirPods add a lot), which the ring counts when it works out
    /// when each sample is heard. Returns it in milliseconds.
    private func updateOutputLatency() -> Int {
        let latency = engine.outputNode.presentationLatency
        ring.outputLatency = latency
        return Int((latency * 1000).rounded())
    }

    /// The engine stops when the output device changes (headphones, AirPods, display audio).
    private func restartAfterDeviceChange() {
        queue.async { [self] in
            guard running else { return }
            do {
                try engine.start()
                logInfo("Audio output device changed; restarted (the device adds \(updateOutputLatency()) ms)")
            } catch {
                logError("Could not restart audio after a device change: \(error)")
            }
        }
    }
}

/// Decoded audio waiting to play.
///
/// With a schedule (`scheduleBase`), each render plays whichever sample is due when its buffer
/// will be heard. If the next queued sample isn't due yet, it waits in silence; if it's overdue,
/// the ring skips ahead. Within 8 ms either way it just plays on, so clock drift costs a tiny
/// correction every few minutes.
///
/// Without one, playback starts (and restarts after a dropout) once `targetLatency` is buffered,
/// and the oldest audio is dropped when more than `maxLatency` builds up.
///
/// When writes carry RTP and arrival times, the ring also works out how long after arriving its
/// sound is heard (`soundDelay`), for the log.
final class SampleRing: @unchecked Sendable {
    struct Statistics {
        var underruns = 0
        var droppedFrames = 0
        var skippedFrames = 0  // jumped over to catch up with the schedule
        var peakFrames = 0
    }

    private let lock = OSAllocatedUnfairLock()
    private var storage: [Float]  // interleaved stereo
    private let sampleRate: Double
    private let capacity: Int      // frames
    private let targetFrames: Int
    private let maxFrames: Int
    private let tolerance: Int64              // how far off the schedule playback may drift, in frames
    private var base: Double?                 // heard host time of RTP sample 0, when scheduled
    private var starved = false               // scheduled sound was due but hadn't arrived
    private var readTime: Int64?              // RTP time of the next sample to play
    private var latency = 0.0                 // the output device's own delay
    private var heardOffset: Double?          // host time a sample is heard minus its RTP time in seconds
    private var arrivals = SlidingMinimum(window: 3)  // arrival host time minus RTP time in seconds
    private var readFrame = 0
    private var bufferedFrames = 0
    private var priming = true
    private var muted = false
    private var linearGain: Float = 1
    private var stats = Statistics()        // since the start
    private var windowStats = Statistics()  // since takeWindowStatistics()

    init(sampleRate: Double, targetLatency: Double, maxLatency: Double, capacitySeconds: Double = 2) {
        self.sampleRate = sampleRate
        capacity = Int(sampleRate * capacitySeconds)
        targetFrames = Int(sampleRate * targetLatency)
        maxFrames = Int(sampleRate * maxLatency)
        tolerance = Int64(sampleRate * 0.008)
        storage = [Float](repeating: 0, count: capacity * 2)
    }

    /// Plays RTP sample R so it's heard at host time `scheduleBase + R / sampleRate`; nil plays
    /// sound as it comes.
    var scheduleBase: Double? {
        get { lock.withLock { base } }
        set { lock.withLock { base = newValue } }
    }

    var targetLatency: Double { lock.withLock { Double(targetFrames) / sampleRate } }

    /// Seconds from a buffer leaving the output unit until it's heard.
    var outputLatency: Double {
        get { lock.withLock { latency } }
        set { lock.withLock { latency = newValue } }
    }

    /// Host time minus RTP time in seconds, for the quickest recent arrivals and for hearing, once playing.
    var timing: (quickest: Double, heard: Double)? {
        lock.withLock {
            guard let heardOffset, let quickest = arrivals.minimum else { return nil }
            return (quickest, heardOffset)
        }
    }

    /// Seconds from the quickest recent arrivals until they're heard, once playing.
    var soundDelay: Double? {
        lock.withLock {
            guard let heardOffset, let quickest = arrivals.minimum else { return nil }
            return heardOffset - quickest
        }
    }

    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    var gain: Float {
        get { lock.withLock { linearGain } }
        set { lock.withLock { linearGain = max(0, min(1, newValue)) } }
    }

    var statistics: Statistics { lock.withLock { stats } }

    func takeWindowStatistics() -> Statistics {
        lock.withLock {
            let window = windowStats
            windowStats = Statistics()
            return window
        }
    }

    var bufferedFrameCount: Int { lock.withLock { bufferedFrames } }

    func reset() {
        lock.withLock {
            readFrame = 0
            bufferedFrames = 0
            priming = true
            readTime = nil
            heardOffset = nil
            arrivals.reset()
            base = nil
            starved = false
        }
    }

    /// Appends samples. `rtpTime` is the RTP time of the first; `arrival` is when it came in.
    func write(_ samples: [Float], rtpTime: Int64? = nil, arrival: Double? = nil) {
        let total = samples.count / 2
        guard total > 0 else { return }
        let frames = min(total, capacity)  // a write longer than the whole ring keeps its newest part
        let first = total - frames
        lock.withLock {
            if let rtpTime {
                let start = rtpTime + Int64(first)
                // Follow on from the queued samples; a jump (a new stream or a resync) starts the count again.
                let followsOn = readTime.map { abs($0 + Int64(bufferedFrames) - start) <= Int64(frames) } ?? false
                if !followsOn { readTime = start - Int64(bufferedFrames) }
                if let arrival { arrivals.add(arrival - Double(rtpTime) / sampleRate, at: arrival) }
            }
            let overflow = bufferedFrames + frames - capacity
            if overflow > 0 { dropOldest(overflow) }

            var writeFrame = (readFrame + bufferedFrames) % capacity
            samples.withUnsafeBufferPointer { input in
                storage.withUnsafeMutableBufferPointer { output in
                    for frame in first..<(first + frames) {
                        output[writeFrame * 2] = input[frame * 2]
                        output[writeFrame * 2 + 1] = input[frame * 2 + 1]
                        writeFrame = writeFrame + 1 == capacity ? 0 : writeFrame + 1
                    }
                }
            }
            bufferedFrames += frames
            windowStats.peakFrames = max(windowStats.peakFrames, bufferedFrames)
            // On a schedule, queued sound is all still due; only unscheduled playback trims.
            if base == nil && bufferedFrames > maxFrames { dropOldest(bufferedFrames - targetFrames) }
        }
    }

    /// Call with the lock held.
    private func dropOldest(_ frames: Int) {
        let drop = discard(frames)
        stats.droppedFrames += drop
        windowStats.droppedFrames += drop
    }

    /// Call with the lock held. Returns how many frames went.
    private func discard(_ frames: Int) -> Int {
        let drop = min(frames, bufferedFrames)
        readFrame = (readFrame + drop) % capacity
        bufferedFrames -= drop
        readTime? += Int64(drop)
        return drop
    }

    /// Called on the real-time audio thread: fills `frames` frames of the output buffers, which go
    /// out to the device at host time `outputTime`.
    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer, outputTime: Double? = nil) {
        guard let left = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        // Unchecked: the closure runs synchronously, so capturing the output pointers is safe.
        let (start, copied): (Int, Int) = lock.withLockUnchecked {
            var start = 0  // silence before the first sample
            let available: Int
            let scheduled = base != nil && outputTime != nil
            if scheduled, let base, let outputTime {
                priming = false
                if let time = readTime, bufferedFrames > 0 {
                    let due = Int64(((outputTime + latency - base) * sampleRate).rounded())
                    let early = time - due
                    if early > tolerance {
                        start = Int(min(early, Int64(frames)))
                    } else if early < -tolerance {
                        let skipped = discard(Int(min(-early, Int64(bufferedFrames))))
                        stats.skippedFrames += skipped
                        windowStats.skippedFrames += skipped
                    }
                }
                available = min(frames - start, bufferedFrames)
            } else {
                if priming && bufferedFrames >= targetFrames { priming = false }
                available = priming ? 0 : min(frames, bufferedFrames)
            }

            if available > 0, let time = readTime {
                if let outputTime { heardOffset = outputTime + Double(start) / sampleRate + latency - Double(time) / sampleRate }
                readTime = time + Int64(available)
            }
            let scale = muted ? 0 : linearGain
            storage.withUnsafeBufferPointer { input in
                var frame = readFrame
                for index in start..<(start + available) {
                    left[index] = input[frame * 2] * scale
                    right?[index] = input[frame * 2 + 1] * scale
                    frame = frame + 1 == capacity ? 0 : frame + 1
                }
                readFrame = frame
            }
            bufferedFrames -= available

            if scheduled {
                // Due sound that hasn't arrived: count one dropout per stretch of silence.
                let short = readTime != nil && available < frames - start
                if short && !starved {
                    stats.underruns += 1
                    windowStats.underruns += 1
                }
                if short { starved = true } else if available > 0 { starved = false }
            } else if !priming && available < frames {
                stats.underruns += 1
                windowStats.underruns += 1
                priming = true
            }
            return (start, available)
        }
        for index in 0..<start {
            left[index] = 0
            right?[index] = 0
        }
        for index in (start + copied)..<frames {
            left[index] = 0
            right?[index] = 0
        }
    }
}

/// AirPlay volume: 0 dB is full, -30 dB the lowest step, -144 means muted.
func gain(forAirPlayVolume volume: Float) -> Float {
    guard volume > -144 else { return 0 }
    return powf(10, max(-30, min(0, volume)) / 20)
}

/// The smallest value added in the last `window` seconds (a monotonic queue, so adding is cheap).
struct SlidingMinimum {
    let window: Double
    private var entries: [(time: Double, value: Double)] = []  // values increase from `head`
    private var head = 0

    init(window: Double) {
        self.window = window
    }

    var minimum: Double? { head < entries.count ? entries[head].value : nil }

    mutating func add(_ value: Double, at time: Double) {
        while entries.count > head, let last = entries.last, last.value >= value { entries.removeLast() }
        entries.append((time, value))
        while head < entries.count - 1, entries[head].time < time - window { head += 1 }
        if head > 256 {
            entries.removeFirst(head)
            head = 0
        }
    }

    mutating func reset() {
        entries.removeAll()
        head = 0
    }
}
