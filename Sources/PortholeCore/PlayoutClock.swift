import Foundation

/// The schedule picture and sound share. The phone gives both their presentation times on one
/// clock: frames carry theirs in the header, and sound gets them from the sync packets on its
/// control port (sample R plays at N + (R - R_sync) / 44100). Presenting everything at
/// "phone time + offset" keeps the two together, as Apple's receivers do. The offset is the
/// smallest that nearly all recent frames and sound packets arrive in time for. For sound that
/// includes the output device's delay; AirPods add about 0.16 s. See FramePacer.
///
/// One per session. Frames are scheduled on the video thread, sound packets reported on the
/// audio thread.
final class PlayoutClock: @unchecked Sendable {
    /// Moves the picture against the sound while it plays, in seconds: positive shows it later.
    let pictureOffset: Double

    private let lock = NSLock()
    private var pacer = FramePacer()
    private var soundLateness: [(arrival: Double, value: Double)] = []  // arrival minus presentation
    private var soundLead = 0.0
    private var soundUntil = -Double.infinity

    init(pictureOffset: Double = 0) {
        self.pictureOffset = pictureOffset
    }

    /// Schedules a frame stamped `stamp` (phone clock) that arrived at `arrival` (host clock).
    func scheduleFrame(stamp: Double, arrival: Double, isKeyFrame: Bool) -> FramePacer.Slot {
        lock.lock()
        defer { lock.unlock() }
        let need = arrival < soundUntil ? soundNeed : nil
        var slot = pacer.schedule(stamp: stamp, arrival: arrival, isKeyFrame: isKeyFrame, soundNeed: need)
        if need != nil { slot.displayTime += pictureOffset }
        return slot
    }

    /// A sound packet due at `presentation` (phone clock) arrived at `arrival` (host clock), and
    /// needs `outputLead` more before it's heard (render cycle and output device). Returns the
    /// offset to play it at: heard at `presentation + offset`. Returns nil if its time doesn't fit
    /// the picture's clock, in which case the sound should play as it comes.
    func noteSound(presentation: Double, arrival: Double, outputLead: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let lateness = arrival - presentation
        if let offset = pacer.offset, abs(lateness - offset) > 2 { return nil }
        soundLateness.append((arrival, lateness))
        var expired = 0
        while soundLateness.count - expired > 20, soundLateness[expired].arrival < arrival - 3 { expired += 1 }
        soundLateness.removeFirst(expired)
        soundLead = outputLead
        soundUntil = arrival + 0.5  // sound packets come every 11 ms; longer gaps are Wi-Fi stalls
        pacer.raise(toCover: soundNeed!)
        return pacer.offset
    }

    /// The offset sound needs: all but the latest 1% of the last 3 seconds' packets in time, plus
    /// the output lead.
    private var soundNeed: Double? {
        guard !soundLateness.isEmpty else { return nil }
        let sorted = soundLateness.map(\.value).sorted()
        return sorted[Int((Double(sorted.count - 1) * 0.99).rounded())] + soundLead
    }
}
