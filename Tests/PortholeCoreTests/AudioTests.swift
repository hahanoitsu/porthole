import AudioToolbox
import CommonCrypto
import XCTest
@testable import PortholeCore

final class AudioTests: XCTestCase {
    func testDecodesAppleAACELDWithThePhonesCodecConfig() throws {
        let input = TestAudio.tone(frames: 44_100)
        let (packets, cookie) = try TestAudio.encodeAACELD(input)
        XCTAssertGreaterThan(packets.count, 80)
        print("encoder magic cookie: \(cookie.map { String(format: "%02x", $0) }.joined()); first packet starts \(hexPreview(packets[0], limit: 4))")

        XCTAssertEqual(AACELDDecoder.esdsCookie(audioSpecificConfig: AACELDDecoder.audioSpecificConfig), cookie,
                       "our cookie is byte-for-byte what Apple's encoder writes for the phone's format")
        let decoder = try AACELDDecoder()
        XCTAssertTrue(decoder.acceptedCodecConfig)
        var output: [Float] = []
        for packet in packets {
            output += try XCTUnwrap(decoder.decode(packet), "packet failed to decode")
        }
        XCTAssertGreaterThan(output.count / 2, 40_000)

        // Skip the codec's start-up delay, then compare with what went in.
        let steady = Array(output.dropFirst(4096 * 2))
        XCTAssertEqual(TestAudio.rms(steady, channel: 0), TestAudio.rms(input, channel: 0), accuracy: 0.05)
        XCTAssertEqual(TestAudio.rms(steady, channel: 1), TestAudio.rms(input, channel: 1), accuracy: 0.05)
        XCTAssertEqual(TestAudio.frequency(steady, channel: 0), 440, accuracy: 15)
        XCTAssertEqual(TestAudio.frequency(steady, channel: 1), 660, accuracy: 15)
    }

    func testRedundantPacketsPlayOnceAndLossBecomesSilence() throws {
        let (frames, _) = try TestAudio.encodeAACELD(TestAudio.tone(frames: 480 * 30))
        let recorder = RecordingSink()
        let key = randomData(16), iv = randomData(16)
        let stream = try AudioStreamReceiver(key: key, iv: iv, compressionType: 8, framesPerPacket: 480, sink: recorder)
        defer { stream.stop() }

        func packet(_ index: Int) -> Data {
            var packet = Data([0x80, 0x60, UInt8(index >> 8 & 0xff), UInt8(index & 0xff)])
            packet.append(Data(count: 8))
            packet.append(aesCBC(CCOperation(kCCEncrypt), blocksOf: frames[index], key: key, iv: iv))
            return packet
        }

        let lostFrame = 10
        for index in 0..<frames.count {
            for resend in max(0, index - 2)...index where resend != lostFrame {
                stream.handle(packet(resend))
            }
        }
        // Every frame plays exactly once, despite arriving three times; the lost one as silence.
        XCTAssertEqual(recorder.samples.count / 2, frames.count * 480)
        let silent = recorder.samples[(lostFrame * 480 * 2)..<((lostFrame + 1) * 480 * 2)]
        XCTAssertTrue(silent.allSatisfy { $0 == 0 }, "the lost frame is replaced by silence")
    }

    func testRingWaitsForBufferThenPlaysInOrder() {
        let ring = SampleRing(sampleRate: 1000, targetLatency: 0.010, maxLatency: 0.100)  // 10 and 100 frames
        let output = OutputBuffers(frames: 4)

        ring.write((0..<8).flatMap { [Float($0), -Float($0)] })  // 8 frames: below the 10-frame target
        ring.render(frames: 4, into: output.list)
        XCTAssertEqual(output.left, [0, 0, 0, 0], "still priming")

        ring.write((8..<12).flatMap { [Float($0), -Float($0)] })
        ring.render(frames: 4, into: output.list)
        XCTAssertEqual(output.left, [0, 1, 2, 3])
        XCTAssertEqual(output.right, [0, -1, -2, -3])

        ring.gain = 0.5
        ring.render(frames: 4, into: output.list)
        XCTAssertEqual(output.left, [2, 2.5, 3, 3.5])

        ring.isMuted = true
        ring.render(frames: 4, into: output.list)
        XCTAssertEqual(output.left, [0, 0, 0, 0], "muted still uses up the audio")
        XCTAssertEqual(ring.bufferedFrameCount, 0)

        ring.isMuted = false
        ring.render(frames: 4, into: output.list)
        XCTAssertEqual(ring.statistics.underruns, 1)
    }

    /// On a schedule, each buffer plays the sample that's due when it's heard: silence until the
    /// first is due, then continuous sound, a dropout when it runs out, and a skip when the queued
    /// sound is overdue.
    func testScheduledRingPlaysEachSampleOnTime() {
        let ring = SampleRing(sampleRate: 1000, targetLatency: 0.010, maxLatency: 0.100)  // 8-sample tolerance
        let output = OutputBuffers(frames: 16)
        ring.outputLatency = 0.05
        ring.scheduleBase = 10.0  // sample R is heard at 10 + R / 1000
        ring.write((100..<120).flatMap { [Float($0), -Float($0)] }, rtpTime: 100)

        // Heard at 10.091: sample 91 is due, so 9 samples of silence, then 100 onwards.
        ring.render(frames: 16, into: output.list, outputTime: 10.041)
        XCTAssertEqual(output.left, [Float](repeating: 0, count: 9) + (100..<107).map(Float.init))
        // Heard at 10.107: sample 107 is next, right on time; it runs out after 119.
        ring.render(frames: 16, into: output.list, outputTime: 10.057)
        XCTAssertEqual(output.left, (107..<120).map(Float.init) + [0, 0, 0])
        XCTAssertEqual(ring.statistics.underruns, 1)

        // Samples 200-219 arrive when 250 is already due: they're overdue, so they're skipped.
        ring.write((200..<220).flatMap { [Float($0), -Float($0)] }, rtpTime: 200)
        ring.render(frames: 16, into: output.list, outputTime: 10.2)
        XCTAssertEqual(output.left, [Float](repeating: 0, count: 16))
        XCTAssertEqual(ring.statistics.skippedFrames, 20)
        XCTAssertEqual(ring.statistics.underruns, 1, "still the same dropout")

        // Without a schedule it falls back to buffering 10 samples first.
        ring.scheduleBase = nil
        ring.write((300..<305).flatMap { [Float($0), -Float($0)] }, rtpTime: 300)
        ring.render(frames: 16, into: output.list, outputTime: 10.3)
        XCTAssertEqual(output.left.prefix(5), [300, 301, 302, 303, 304], "already playing, so it carries on")
    }

    /// A sample that arrived at 100.0 s and goes out at 100.2 s through a device with 50 ms of its
    /// own delay is heard 250 ms after arriving; later samples follow on from it.
    func testRingWorksOutWhenSoundIsHeard() {
        let ring = SampleRing(sampleRate: 1000, targetLatency: 0.010, maxLatency: 0.100)
        let output = OutputBuffers(frames: 4)
        ring.outputLatency = 0.05
        XCTAssertNil(ring.soundDelay, "nothing played yet")

        ring.write([Float](repeating: 0.5, count: 2 * 20), rtpTime: 5000, arrival: 100.0)
        ring.render(frames: 4, into: output.list, outputTime: 100.2)
        XCTAssertEqual(ring.soundDelay ?? 0, 0.25, accuracy: 1e-9)
        ring.render(frames: 4, into: output.list, outputTime: 100.204)
        XCTAssertEqual(ring.soundDelay ?? 0, 0.25, accuracy: 1e-9, "the next buffer starts 4 samples later")

        // Sample 5020 arrived at 100.01 s, 10 ms sooner relative to its time than sample 5000, and
        // will be heard at 100.27 s. It sets the pace for the next 3 seconds.
        ring.write([Float](repeating: 0.5, count: 2 * 4), rtpTime: 5020, arrival: 100.01)
        ring.render(frames: 4, into: output.list, outputTime: 100.208)
        XCTAssertEqual(ring.soundDelay ?? 0, 0.26, accuracy: 1e-9)

        // Trimmed samples still count: the next one heard is the right one.
        ring.write([Float](repeating: 0.5, count: 2 * 200), rtpTime: 5024, arrival: 100.02)
        ring.render(frames: 4, into: output.list, outputTime: 100.3)
        XCTAssertGreaterThan(ring.statistics.droppedFrames, 0)
        XCTAssertNotNil(ring.soundDelay)

        ring.reset()
        XCTAssertNil(ring.soundDelay)
    }

    func testSlidingMinimumForgetsOldValues() {
        var minimum = SlidingMinimum(window: 3)
        XCTAssertNil(minimum.minimum)
        minimum.add(5, at: 0)
        minimum.add(7, at: 1)
        minimum.add(6, at: 2)
        XCTAssertEqual(minimum.minimum, 5)
        minimum.add(9, at: 3.5)
        XCTAssertEqual(minimum.minimum, 6, "5 is older than 3 s")
        minimum.add(4, at: 4)
        XCTAssertEqual(minimum.minimum, 4)
        minimum.add(8, at: 10)
        XCTAssertEqual(minimum.minimum, 8, "everything else expired")
    }

    func testRingDropsOldestAudioToCapDelay() {
        let ring = SampleRing(sampleRate: 1000, targetLatency: 0.010, maxLatency: 0.100)
        ring.write([Float](repeating: 1, count: 2 * 150))
        XCTAssertLessThanOrEqual(ring.bufferedFrameCount, 100)
        XCTAssertGreaterThan(ring.statistics.droppedFrames, 0)
    }

    func testAirPlayVolumeToGain() {
        XCTAssertEqual(gain(forAirPlayVolume: 0), 1)
        XCTAssertEqual(gain(forAirPlayVolume: -144), 0)
        XCTAssertEqual(gain(forAirPlayVolume: -20), 0.1, accuracy: 0.0001)
        XCTAssertEqual(gain(forAirPlayVolume: -60), gain(forAirPlayVolume: -30), "clamped to the slider's range")
    }

    /// Two non-interleaved channels, the layout the audio engine renders into.
    private final class OutputBuffers {
        let list: UnsafeMutableAudioBufferListPointer
        private let frames: Int
        private let leftChannel: UnsafeMutablePointer<Float>
        private let rightChannel: UnsafeMutablePointer<Float>

        init(frames: Int) {
            self.frames = frames
            leftChannel = .allocate(capacity: frames)
            rightChannel = .allocate(capacity: frames)
            list = AudioBufferList.allocate(maximumBuffers: 2)
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: leftChannel)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: rightChannel)
        }

        deinit {
            leftChannel.deallocate()
            rightChannel.deallocate()
            free(list.unsafeMutablePointer)
        }

        var left: [Float] { Array(UnsafeBufferPointer(start: leftChannel, count: frames)) }
        var right: [Float] { Array(UnsafeBufferPointer(start: rightChannel, count: frames)) }
    }

    /// Runs the real output path. It only ever gets silence, and is muted on top of that.
    func testPlayerStartsAndStopsCleanly() {
        let player = AudioPlayer()
        player.isMuted = true
        player.start()
        for index in 0..<20 {
            player.enqueue([Float](repeating: 0, count: 480 * 2), rtpTime: Int64(index * 480))
            Thread.sleep(forTimeInterval: 0.01)
        }
        player.stop()
        Thread.sleep(forTimeInterval: 0.2)
    }

    func testCBCPassesTrailingBytesThrough() {
        let key = randomData(16), iv = randomData(16), plain = randomData(100)
        let encrypted = aesCBC(CCOperation(kCCEncrypt), blocksOf: plain, key: key, iv: iv)
        XCTAssertEqual(encrypted.suffix(4), plain.suffix(4), "the last 100 % 16 bytes stay in the clear")
        XCTAssertNotEqual(encrypted.prefix(96), plain.prefix(96))
        XCTAssertEqual(aesCBC(CCOperation(kCCDecrypt), blocksOf: encrypted, key: key, iv: iv), plain)
    }
}
