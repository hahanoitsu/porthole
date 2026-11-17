import CoreMedia
import Darwin

/// Seconds on the host clock (mach_absolute_time), which AVSampleBufferDisplayLayer can schedule
/// frames against and audio time stamps are given in.
public enum HostClock {
    public static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Seconds per mach_absolute_time tick, the unit of an AudioTimeStamp's mHostTime.
    public static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}

/// Decides when each mirrored frame appears.
///
/// The phone stamps every frame with the time it should be shown, on its own clock. Showing each
/// frame the moment it arrives turns every Wi-Fi delay into a stutter. The pacer instead shows
/// each frame at its stamp plus an offset, so frames keep the phone's spacing. The offset is as
/// small as recent arrivals allow:
/// - it covers all but the latest 1% of the last few seconds' frames;
/// - it rises at once when frames start arriving later;
/// - it falls slowly when they speed up again, so the picture never visibly jumps;
/// - no frame is ever held longer than `maxDelay`.
///
/// On a clean network that's a few milliseconds. When Wi-Fi stalls regularly, it grows to the
/// length of the stalls.
///
/// While sound plays (see PlayoutClock), the offset also covers what the sound needs, and stops
/// falling: sound shares the offset, so moving it would make the sound skip.
public struct FramePacer {
    public struct Settings: Sendable {
        /// Seconds of arrivals that decide the offset (at least `minimumSamples` frames).
        public var window = 3.0
        public var minimumSamples = 20
        /// Share of recent frames that should arrive in time for their slot.
        public var coverage = 0.99
        /// Time to decode a frame before its slot.
        public var decodeTime = 0.006
        /// The longest a frame is held back.
        public var maxDelay = 0.15
        /// How fast the offset falls once frames speed up, in seconds per second. 0.02 plays
        /// the picture 2% fast until it has caught up.
        public var fallRate = 0.02
        /// The longest a frame is held while sound plays (AirPods alone add about 0.16 s).
        public var maxSoundDelay = 1.0
        /// Head room added when sound pushes the offset up, so it doesn't creep up a few
        /// milliseconds at a time (each step pauses the sound for that long).
        public var soundMargin = 0.02

        public init() {}
    }

    public struct Slot: Equatable {
        /// When to show the frame, in host-clock seconds.
        public var displayTime: Double
        /// How much later than the quickest recent frame this one arrived.
        public var jitter: Double
        /// Arrived too late to be decoded by its slot; it appears as soon as it's ready.
        public var isLate: Bool
        /// Scheduled while sound plays, so the offset covers the sound too.
        public var withSound = false
    }

    public var settings: Settings
    /// Host-clock time minus phone-clock time for showing a frame; nil until the first frame
    /// that isn't a key frame.
    public private(set) var offset: Double?

    private var recent: [(arrival: Double, transit: Double)] = []
    private var lastArrival = 0.0
    private var lastDisplayTime = -Double.infinity
    private var drainingLongHold = false

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Schedules a frame stamped `stamp` (phone-clock seconds) whose last byte arrived at
    /// `arrival` (host-clock seconds). While sound plays, `soundNeed` is the offset the sound
    /// itself needs.
    public mutating func schedule(stamp: Double, arrival: Double, isKeyFrame: Bool = false,
                                  soundNeed: Double? = nil) -> Slot {
        let transit = arrival - stamp
        if let offset, transit < offset - 2 {
            // The phone's clock jumped ahead; going on would hold frames for seconds.
            reset()
        }

        // Key frames are many times larger than the rest and always arrive late. Counting them
        // would hold every frame back for the whole window, so they just show when they can.
        if !isKeyFrame {
            recent.append((arrival, transit))
            var expired = 0
            while recent.count - expired > settings.minimumSamples,
                  recent[expired].arrival < arrival - settings.window {
                expired += 1
            }
            recent.removeFirst(expired)
        }

        let transits = recent.map(\.transit).sorted()
        let quickest = transits.first ?? transit
        if !isKeyFrame {
            let index = Int((Double(transits.count - 1) * settings.coverage).rounded())
            let target = min(transits[index], quickest + settings.maxDelay) + settings.decodeTime
            var limit = settings.maxDelay + settings.decodeTime
            if let soundNeed {
                raise(toCover: max(target, soundNeed))
                limit = settings.maxSoundDelay
            } else {
                if let current = offset, target < current {
                    offset = max(target, current - settings.fallRate * max(0, arrival - lastArrival))
                } else {
                    offset = target
                }
                // Once the sound stops, a longer hold it needed drains slowly instead of jumping.
                if drainingLongHold {
                    if offset! - transit > limit { limit = settings.maxSoundDelay } else { drainingLongHold = false }
                }
            }
            // Never hold this frame longer than the limit, even while the offset is still falling.
            offset = min(offset!, transit + limit)
            lastArrival = arrival
        }

        let ready = arrival + settings.decodeTime
        var displayTime = offset.map { stamp + $0 } ?? ready
        displayTime = max(displayTime, lastDisplayTime + 0.0005)  // keep frames in order
        lastDisplayTime = displayTime
        return Slot(displayTime: displayTime, jitter: max(0, transit - quickest), isLate: ready > displayTime + 0.0005,
                    withSound: soundNeed != nil)
    }

    /// Raises the offset to `need` plus a margin, if it's lower. Never lowers it.
    public mutating func raise(toCover need: Double) {
        if let offset, offset >= need { return }
        offset = need + settings.soundMargin
        drainingLongHold = true
    }

    public mutating func reset() {
        recent.removeAll()
        offset = nil
        lastDisplayTime = -.infinity
        drainingLongHold = false
    }
}
