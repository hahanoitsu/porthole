import XCTest
@testable import PortholeCore

final class PacingTests: XCTestCase {
    private let settings = FramePacer.Settings()
    /// The longest hold, plus room for frames due together being nudged 0.5 ms apart to stay in order.
    private var holdLimit: Double { settings.maxDelay + settings.decodeTime + 0.01 }

    func testSteadyArrivalsShowAlmostAtOnce() {
        var pacer = FramePacer()
        let run = simulate(&pacer, seconds: 5) { _ in 0 }
        for frame in run {
            XCTAssertEqual(frame.slot.displayTime - frame.arrival, settings.decodeTime, accuracy: 1e-9)
            XCTAssertFalse(frame.slot.isLate)
        }
    }

    func testJitterIsAbsorbedWithLittleDelay() {
        var random = SeededGenerator(seed: 7)
        var pacer = FramePacer()
        let run = simulate(&pacer, seconds: 10) { _ in Double.random(in: 0..<0.030, using: &random) }
        let settled = Array(run.suffix(300))
        XCTAssertLessThanOrEqual(settled.filter(\.slot.isLate).count, 6)
        XCTAssertGreaterThanOrEqual(evenShare(settled), 0.9)
        XCTAssertLessThan(averageHold(settled), 0.035, "about the jitter, not a fixed 100 ms")
    }

    /// The pattern measured on the user's Wi-Fi: the link stalls for 100 ms every half second.
    func testRegularStallsAreSmoothedOver() {
        var pacer = FramePacer()
        let run = simulate(&pacer, seconds: 10) { sent in Self.stall(at: sent, every: 0.5, lasting: 0.1) }
        let settled = Array(run.suffix(300))
        XCTAssertLessThanOrEqual(settled.filter(\.slot.isLate).count, 6)
        XCTAssertGreaterThanOrEqual(evenShare(settled), 0.95)
        XCTAssertLessThanOrEqual(run.map { $0.slot.displayTime - $0.arrival }.max()!, holdLimit)
    }

    func testHoldNeverExceedsTheLimit() {
        var pacer = FramePacer()
        let run = simulate(&pacer, seconds: 10) { sent in Self.stall(at: sent, every: 1, lasting: 0.3) }
        XCTAssertLessThanOrEqual(run.map { $0.slot.displayTime - $0.arrival }.max()!, holdLimit)
        XCTAssertGreaterThan(run.filter(\.slot.isLate).count, 0, "stalls longer than the limit still show")
    }

    /// Once the stalls stop, the delay drains a little at a time instead of jumping.
    func testDelayDrainsSlowlyAfterTheNetworkRecovers() {
        var pacer = FramePacer()
        let run = simulate(&pacer, seconds: 20) { sent in sent < 5 ? Self.stall(at: sent, every: 0.5, lasting: 0.1) : 0 }
        let recovered = run.filter { $0.stamp >= 5.2 }
        for (previous, frame) in zip(recovered, recovered.dropFirst()) {
            let spacing = frame.slot.displayTime - previous.slot.displayTime
            XCTAssertGreaterThanOrEqual(spacing, 1.0 / 60 - settings.fallRate / 60 - 1e-9)
        }
        let end = recovered.suffix(60)
        XCTAssertEqual(averageHold(Array(end)), settings.decodeTime, accuracy: 0.001)
    }

    /// While sound plays, the offset also covers what the sound needs (here more than the
    /// picture does) and holds still; when it stops, the offset drains back without jumping.
    func testSoundHoldsTheOffset() {
        var random = SeededGenerator(seed: 3)
        var pacer = FramePacer()
        let jitter = { (_: Double) in Double.random(in: 0..<0.03, using: &random) }
        let soundNeed = 1000.3  // host minus phone time that sound needs
        var run: [Frame] = []
        for second in 0..<6 {
            run += simulate(&pacer, seconds: 1, from: second * 60, soundNeed: soundNeed, extraDelay: jitter)
        }
        let settled = run.suffix(240)
        XCTAssertTrue(settled.allSatisfy(\.slot.withSound))
        XCTAssertFalse(settled.contains(where: \.slot.isLate))
        for frame in settled {
            XCTAssertEqual(frame.slot.displayTime, frame.stamp + soundNeed + settings.soundMargin, accuracy: 1e-9)
        }

        let after = simulate(&pacer, seconds: 20, from: 360) { _ in 0 }
        XCTAssertFalse(after.contains(where: \.slot.withSound))
        for (previous, frame) in zip(after, after.dropFirst()) {
            XCTAssertGreaterThanOrEqual(frame.slot.displayTime - previous.slot.displayTime, 1.0 / 60 - settings.fallRate / 60 - 1e-9,
                                        "drains without jumping")
        }
        XCTAssertEqual(averageHold(Array(after.suffix(60))), settings.decodeTime, accuracy: 0.001)
    }

    /// Timings like the real phone's: frames arrive 96 ms before the phone wants them shown, and
    /// sound 187 ms before it wants it played.
    private func runSharedClock(outputLatency: Double) -> (clock: PlayoutClock, videoOffset: Double, soundOffset: Double) {
        let clock = PlayoutClock()
        var lastFrame = FramePacer.Slot(displayTime: 0, jitter: 0, isLate: false)
        for index in 0..<120 {
            let stamp = 5000 + Double(index) / 60
            lastFrame = clock.scheduleFrame(stamp: stamp, arrival: stamp + 1000 - 0.096, isKeyFrame: false)
        }
        let videoOffset = lastFrame.displayTime - (5000 + 119.0 / 60)
        var soundOffset = 0.0
        for index in 0..<100 {
            let presentation = 5002 + Double(index) * 480 / 44_100
            soundOffset = clock.noteSound(presentation: presentation, arrival: presentation + 1000 - 0.187,
                                          outputLead: outputLatency + AudioStreamReceiver.renderLead) ?? .nan
        }
        return (clock, videoOffset, soundOffset)
    }

    /// Through AirPods (0.16 s) the sound needs a later schedule than the picture, so the picture
    /// waits for it; both then use the same offset.
    func testSoundThroughAirPodsDelaysThePicture() {
        let (clock, videoOffset, soundOffset) = runSharedClock(outputLatency: 0.16)
        XCTAssertEqual(videoOffset, 1000 - 0.096 + settings.decodeTime, accuracy: 1e-6, "the picture alone")
        XCTAssertEqual(soundOffset, 1000 - 0.187 + 0.16 + AudioStreamReceiver.renderLead + settings.soundMargin, accuracy: 1e-6)
        let frame = clock.scheduleFrame(stamp: 5003, arrival: 5003 + 1000 - 0.096, isKeyFrame: false)
        XCTAssertTrue(frame.withSound)
        XCTAssertEqual(frame.displayTime - 5003, soundOffset, accuracy: 1e-9, "picture and sound share the offset")
    }

    /// Through the Mac's speakers the sound fits the picture's schedule, so nothing waits.
    func testSoundThroughSpeakersAddsNoDelay() {
        let (clock, videoOffset, soundOffset) = runSharedClock(outputLatency: 0.001)
        XCTAssertEqual(soundOffset, videoOffset, accuracy: 1e-9)
        let frame = clock.scheduleFrame(stamp: 5003, arrival: 5003 + 1000 - 0.096, isKeyFrame: false)
        XCTAssertEqual(frame.displayTime - 5003, videoOffset, accuracy: 1e-9)
    }

    /// Sound times on some other clock than the picture's are refused rather than followed.
    func testSoundOnAnotherClockIsRefused() {
        let (clock, _, _) = runSharedClock(outputLatency: 0.001)
        XCTAssertNil(clock.noteSound(presentation: 5003 + 2_208_988_800, arrival: 6003, outputLead: 0.02))
    }

    func testHostClockTicksMatchItsSeconds() {
        XCTAssertEqual(Double(mach_absolute_time()) * HostClock.secondsPerTick, HostClock.now, accuracy: 0.001)
    }

    func testPhoneClockJumpStartsOver() {
        var pacer = FramePacer()
        _ = simulate(&pacer, seconds: 2) { _ in 0 }
        let stamp = 2.0 + 10  // the phone's clock jumped 10 s ahead
        let slot = pacer.schedule(stamp: stamp, arrival: 1000 + 2.0 + 0.02)
        XCTAssertEqual(slot.displayTime, 1000 + 2.0 + 0.02 + settings.decodeTime, accuracy: 1e-9)
    }

    func testKeyFramesShowWhenReadyWithoutMovingTheSchedule() {
        var pacer = FramePacer()
        let first = pacer.schedule(stamp: 0, arrival: 1000.05, isKeyFrame: true)
        XCTAssertEqual(first.displayTime, 1000.05 + settings.decodeTime, accuracy: 1e-9)
        XCTAssertNil(pacer.offset)

        _ = simulate(&pacer, seconds: 2, from: 1) { _ in 0 }  // stamps up to 120/60
        let offset = pacer.offset
        let stamp = 121.0 / 60
        let late = pacer.schedule(stamp: stamp, arrival: 1000 + stamp + 0.02 + 0.015, isKeyFrame: true)
        XCTAssertTrue(late.isLate)
        XCTAssertEqual(pacer.offset, offset)
    }

    // MARK: - Helpers

    private typealias Frame = (stamp: Double, arrival: Double, slot: FramePacer.Slot)

    /// Runs 60 fps frames through the pacer. Each frame's network delay is 20 ms plus
    /// `extraDelay(sent)`, frames arrive in order (as over TCP), and the host clock is 1000 s
    /// ahead of the phone's.
    private func simulate(_ pacer: inout FramePacer, seconds: Double, from firstIndex: Int = 0, soundNeed: Double? = nil,
                          extraDelay: (Double) -> Double) -> [Frame] {
        var frames: [Frame] = []
        var lastArrival = 0.0
        for index in firstIndex..<(firstIndex + Int(seconds * 60)) {
            let stamp = Double(index) / 60
            let sent = stamp + 0.020
            let arrival = max(1000 + sent + extraDelay(sent), lastArrival)
            lastArrival = arrival
            frames.append((stamp, arrival, pacer.schedule(stamp: stamp, arrival: arrival, soundNeed: soundNeed)))
        }
        return frames
    }

    /// Extra delay for a packet sent at `time` when the link pauses for `length` every `period`.
    private static func stall(at time: Double, every period: Double, lasting length: Double) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period)
        return phase < length ? length - phase : 0
    }

    /// The share of consecutive frames shown 1/60 s apart (within the drain rate's effect).
    private func evenShare(_ frames: [Frame]) -> Double {
        let gaps = zip(frames, frames.dropFirst()).map { $1.slot.displayTime - $0.slot.displayTime }
        return Double(gaps.filter { abs($0 - 1.0 / 60) <= 0.0005 }.count) / Double(gaps.count)
    }

    private func averageHold(_ frames: [Frame]) -> Double {
        frames.map { $0.slot.displayTime - $0.arrival }.reduce(0, +) / Double(frames.count)
    }
}

/// SplitMix64, so the jitter test sees the same numbers every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
