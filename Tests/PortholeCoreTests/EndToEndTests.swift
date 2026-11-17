import CommonCrypto
import XCTest
@testable import PortholeCore

/// A fake iPhone runs whole mirroring sessions against a real receiver on localhost.
final class EndToEndTests: XCTestCase {
    func testFakePhoneMirrorsH264() throws {
        try runVideoSession(.h264, smooth: false)
    }

    func testFakePhoneMirrorsHEVC() throws {
        try runVideoSession(.hevc, smooth: true)
    }

    /// The phone's sync packet puts sound on its clock; picture and sound then share one offset,
    /// here set by sound through slow headphones.
    func testSoundAndPictureShareTheSchedule() throws {
        let video = try EncodedVideo.make(.h264)
        let receiver = AirPlayReceiver(config: ReceiverConfig(), identity: .generate())
        let recorder = RecordingSink()
        recorder.latency = 0.2
        receiver.makeAudioSink = { recorder }
        let events = EventCollector(expectedFrames: video.frames.count)
        receiver.delegate = events
        try receiver.start(advertise: false)
        defer { receiver.stop() }

        let phone = try FakePhone(receiver: receiver)
        try phone.startSession()
        try phone.answerTimingRequest()
        let ports = try phone.setUpAudioPorts()
        let videoPort = try phone.setUpVideo(streamConnectionID: 77)
        wait(for: [events.started], timeout: 2)

        // The phone's clock runs in step with ours from 50,000 s. Its sync packet says sample
        // 1,000,000 plays at 50,000 s; it sends sound 170 ms ahead of play and video 100 ms ahead.
        let syncTime: UInt32 = 1_000_000
        let syncSeconds = 50_000.0
        let start = HostClock.now
        func phoneNow() -> Double { syncSeconds + HostClock.now - start }
        let socket = try UDPSocket()
        socket.send(phone.syncPacket(rtpTime: syncTime, playsAt: syncSeconds), to: try XCTUnwrap(SocketAddress(host: "::1", port: ports.control)))
        let audio = try XCTUnwrap(SocketAddress(host: "::1", port: ports.data))
        var sequence: UInt16 = 0
        func sendSound(_ count: Int) {
            for _ in 0..<count {  // placeholders carry the timing too
                let rtpTime = syncTime &+ 7497 &+ UInt32((phoneNow() - syncSeconds) * 44_100)
                socket.send(phone.audioPacket(sequence: sequence, rtpTime: rtpTime, frame: nil), to: audio)
                sequence &+= 1
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        sendSound(20)
        let deadline = Date().addingTimeInterval(2)
        while recorder.scheduleBase == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertNotNil(recorder.scheduleBase, "sound goes on the schedule once the phone has synced")

        let cipher = phone.videoCipher(streamConnectionID: 77)
        let stream = try connectTCP(port: videoPort)
        defer { close(stream) }
        let firstStamp = phoneNow() + 0.1
        var bytes = mirrorPacket(type: 1, option: 0x16, payload: video.codecPacketPayload, width: Float(video.width), height: Float(video.height))
        var stamps: [Double] = []
        for (index, frame) in video.frames.enumerated() {
            let stamp = UInt64((firstStamp + Double(index) / 60) * 4_294_967_296)
            stamps.append(Double(stamp) / 4_294_967_296)
            bytes += mirrorPacket(type: 0, payload: cipher.processed(frame.data), timestamp: stamp)
        }
        XCTAssertTrue(Sockets.writeAll(stream, bytes))
        wait(for: [events.framesArrived], timeout: 5)
        sendSound(5)
        Thread.sleep(forTimeInterval: 0.05)

        // Sound: sample R plays at syncSeconds + (R - syncTime) / 44100 on the phone and is heard at
        // base + R / 44100 on the Mac. Picture: stamp s shows at s + offset. Same offset for both,
        // set by the sound: through slow headphones it needs more than the picture.
        let base = try XCTUnwrap(recorder.scheduleBase)
        let soundOffset = base + Double(syncTime) / 44_100 - syncSeconds
        let frames = events.frames
        for index in 1..<frames.count {
            XCTAssertEqual(frames[index].frame.displayTime - stamps[index], soundOffset, accuracy: 0.002, "frame \(index)")
        }
        // Alone the picture would be held ~6 ms. The headphones' 0.2 s plus 15 ms render lead, less
        // the 70 ms more lead the phone gives sound than picture, plus 20 ms margin: ~0.18 s.
        XCTAssertEqual(frames[1].frame.displayTime - frames[1].receivedAt, 0.18, accuracy: 0.04, "the picture waits for the headphones")
    }

    /// A square display as tall as the phone's screen gets its exact pixels both ways up; the
    /// frame rate limit can change between sessions.
    func testInfoOffersSquareDisplayAndFrameRate() throws {
        let receiver = AirPlayReceiver(config: ReceiverConfig(), identity: .generate())
        try receiver.start(advertise: false)
        defer { receiver.stop() }
        func info() throws -> (info: [String: Any], display: [String: Any]) {
            let info = try plistDictionary(try TestRTSPClient(port: receiver.port).request("GET", "/info").body)
            return (info, try XCTUnwrap((info["displays"] as? [[String: Any]])?.first))
        }

        var (full, display) = try info()
        XCTAssertEqual(display["width"] as? Int, 2868)
        XCTAssertEqual(display["height"] as? Int, 2868)
        XCTAssertEqual(display["maxFPS"] as? Int, 60)
        XCTAssertNotNil(full["audioFormats"], "sound plays on the Mac")
        XCTAssertNotEqual((full["features"] as? NSNumber).map { $0.uint64Value & (1 << 9) }, 0)

        receiver.maxFPS = 30
        (full, display) = try info()
        XCTAssertEqual(display["maxFPS"] as? Int, 30)
        XCTAssertEqual(display["refreshRate"] as? Double ?? 0, 1.0 / 30, accuracy: 1e-9)
    }

    func testInfoAnswersTXTQualifier() throws {
        let receiver = AirPlayReceiver(config: ReceiverConfig(), identity: .generate())
        try receiver.start(advertise: false)
        defer { receiver.stop() }
        let client = try TestRTSPClient(port: receiver.port)

        let response = try client.request("GET", "/info", body: try binaryPlist(["qualifier": ["txtAirPlay"]]),
                                          contentType: "application/x-apple-binary-plist")
        let info = try plistDictionary(response.body)
        XCTAssertEqual(info["txtAirPlay"] as? Data, receiver.airplayTXT)
        XCTAssertNil(info["displays"], "the qualifier request only wants the TXT record")
    }

    func testLogKeepsEarlierRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("porthole.log")
        let log = Log()
        for run in 0..<3 {
            log.openFile(url, keeping: 10)
            log.write(.info, "run \(run)")
            Thread.sleep(forTimeInterval: 1.1)  // archive names are per second
        }
        log.openFile(url, keeping: 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names.count, 2, "\(names)")
        XCTAssertTrue(names.contains("porthole.log"))
    }

    /// If the phone ever asks the receiver for its clock, it gets an answer.
    func testReceiverAnswersThePhonesClockRequests() throws {
        let receiver = AirPlayReceiver(config: ReceiverConfig(), identity: .generate())
        try receiver.start(advertise: false)
        defer { receiver.stop() }
        let phone = try FakePhone(receiver: receiver)
        try phone.startSession()
        try phone.answerTimingRequest()

        let receiverClock = try XCTUnwrap(SocketAddress(host: "::1", port: phone.receiverTimingPort))
        var question = Data(count: 32)
        question[0] = 0x80
        question[1] = 0xd2
        question.replaceSubrange(24..<32, with: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let clock = try XCTUnwrap(phone.clock)
        clock.send(question, to: receiverClock)
        var answer: Data?
        for _ in 0..<10 where answer == nil {  // skip the receiver's own periodic requests
            if let (packet, _) = clock.receive(timeoutMs: 1000), packet[1] == 0xd3 { answer = packet }
        }
        let reply = try XCTUnwrap(answer)
        XCTAssertEqual(reply.bytes(at: 8, count: 8), Data([1, 2, 3, 4, 5, 6, 7, 8]), "echoes our transmit time")
    }

    func testFakePhonePlaysSound() throws {
        let tone = TestAudio.tone(frames: 44_100 / 2)
        let (frames, _) = try TestAudio.encodeAACELD(tone)
        let recorder = RecordingSink(expectedFrames: frames.count * 480)
        let receiver = AirPlayReceiver(config: ReceiverConfig(), identity: .generate())
        receiver.makeAudioSink = { recorder }
        try receiver.start(advertise: false)
        defer { receiver.stop() }

        // Reconnect-style pairing (no /pair-setup): the stream keys must still line up.
        let phone = try FakePhone(receiver: receiver)
        try phone.startSession(pairSetup: false)
        let dataPort = try phone.setUpAudio()
        XCTAssertTrue(recorder.started)

        // Placeholders first, then each frame three times (n; n-1 n; n-2 n-1 n…), with the
        // sequence number wrapping past 65535 and the 32-bit RTP time wrapping partway through.
        let first: UInt16 = 65_530
        let firstTime = UInt32.max - 480 * 20
        func rtpTime(_ index: Int) -> UInt32 { firstTime &+ UInt32(index * 480) }
        let socket = try UDPSocket()
        let destination = try XCTUnwrap(SocketAddress(host: "::1", port: dataPort))
        for index in 0..<4 {
            socket.send(phone.audioPacket(sequence: first &+ UInt16(index), rtpTime: rtpTime(index), frame: nil), to: destination)
        }
        let start = first &+ 4
        for index in 0..<frames.count {
            for resend in max(0, index - 2)...index {
                socket.send(phone.audioPacket(sequence: start &+ UInt16(resend), rtpTime: rtpTime(4 + resend), frame: frames[resend]),
                            to: destination)
            }
            if index % 16 == 15 { Thread.sleep(forTimeInterval: 0.005) }
        }

        wait(for: [recorder.enoughAudio], timeout: 5)
        let times = recorder.rtpTimes
        XCTAssertEqual(times.first, Int64(rtpTime(4)))
        XCTAssertEqual(zip(times, times.dropFirst()).map { $1 - $0 }, Array(repeating: 480, count: times.count - 1),
                       "RTP times run on smoothly across the 32-bit wrap")
        let decoded = Array(recorder.samples.dropFirst(4096 * 2))
        XCTAssertEqual(TestAudio.rms(decoded, channel: 0), TestAudio.rms(tone, channel: 0), accuracy: 0.05)
        XCTAssertEqual(TestAudio.frequency(decoded, channel: 0), 440, accuracy: 20)
        XCTAssertEqual(TestAudio.frequency(decoded, channel: 1), 660, accuracy: 20)

        receiver.isAudioMuted = true
        XCTAssertTrue(recorder.isMuted)
        receiver.isAudioMuted = false
        XCTAssertFalse(recorder.isMuted)

        let volume = try phone.client.request("SET_PARAMETER", "rtsp://127.0.0.1/4242", body: Data("volume: -15.000000\r\n".utf8),
                                              contentType: "text/parameters")
        XCTAssertEqual(volume.status, 200)
        XCTAssertEqual(recorder.gain, powf(10, -15.0 / 20), accuracy: 0.001)

        XCTAssertEqual(try phone.request("TEARDOWN", plist: ["streams": [["type": 96]]]).status, 200)
        XCTAssertTrue(recorder.stopped)
    }

    /// The fake phone stamps frames 1/60 s apart but sends them all at once. Smooth playback
    /// spreads them back out to the phone's spacing; without it they show on arrival.
    private func runVideoSession(_ codec: VideoCodec, smooth: Bool) throws {
        let video = try EncodedVideo.make(codec)
        let receiver = AirPlayReceiver(config: ReceiverConfig(), identity: .generate())
        receiver.smoothPlayback = smooth
        let events = EventCollector(expectedFrames: video.frames.count)
        receiver.delegate = events
        try receiver.start(advertise: false)
        defer { receiver.stop() }

        let phone = try FakePhone(receiver: receiver)
        try phone.startSession()
        try phone.answerTimingRequest()

        // A connection ID above Int64.max checks the unsigned handling.
        let streamConnectionID: UInt64 = 0xF00D_CAFE_1234_5678
        let dataPort = try phone.setUpVideo(streamConnectionID: streamConnectionID)
        wait(for: [events.started], timeout: 2)

        let cipher = phone.videoCipher(streamConnectionID: streamConnectionID)
        let stream = try connectTCP(port: dataPort)
        defer { close(stream) }
        var bytes = mirrorPacket(type: 1, option: codec == .h264 ? 0x16 : 0x1e, payload: video.codecPacketPayload,
                                 width: Float(video.width), height: Float(video.height))
        bytes += mirrorPacket(type: 5, payload: randomData(40))  // stats packets are not encrypted
        let firstStamp = 57_440.675  // NTP-style seconds, as in the spec's example packet
        for (index, frame) in video.frames.enumerated() {
            let stamp = UInt64((firstStamp + Double(index) / 60) * 4_294_967_296)
            bytes += mirrorPacket(type: 0, payload: cipher.processed(frame.data), timestamp: stamp)
        }
        // Send in awkward pieces to exercise reassembly.
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 777, bytes.count)
            XCTAssertTrue(Sockets.writeAll(stream, bytes[offset..<end]))
            offset = end
        }

        wait(for: [events.framesArrived], timeout: 5)
        let format = try XCTUnwrap(events.formats.first)
        XCTAssertEqual(format.codec, codec)
        XCTAssertEqual(format.width, video.width)
        let frames = events.frames
        XCTAssertEqual(frames.map(\.frame.data), video.frames.map(\.data))
        XCTAssertEqual(frames.map(\.frame.isKeyFrame), video.frames.map(\.isKeyFrame))
        XCTAssertEqual(try decodedFrameCount(frames.map(\.frame), format: format), video.frames.count)
        let times = frames.map(\.frame.displayTime)
        XCTAssertEqual(times, times.sorted(), "frames stay in order")
        if smooth {
            // Frame 0 is the key frame and shows when ready; the next few keep the phone's spacing
            // (later ones would be held past the 150 ms limit, since they all arrived together).
            for index in 2...6 {
                XCTAssertEqual(times[index] - times[index - 1], 1.0 / 60, accuracy: 0.0005, "frame \(index)")
            }
            XCTAssertLessThanOrEqual(times.last! - frames.last!.receivedAt, FramePacer.Settings().maxDelay + 0.01)
        } else {
            for (time, received) in zip(times, frames.map(\.receivedAt)) {
                XCTAssertLessThanOrEqual(time, received, "shown on arrival")
            }
        }

        XCTAssertEqual(try phone.request("TEARDOWN", plist: ["streams": [["type": 110]]]).status, 200)
        wait(for: [events.stopped], timeout: 3)
    }
}

private final class EventCollector: AirPlayReceiverDelegate {
    let started = XCTestExpectation(description: "mirroring started")
    let framesArrived = XCTestExpectation(description: "all frames arrived")
    let stopped = XCTestExpectation(description: "mirroring stopped")
    private let expectedFrames: Int
    private let lock = NSLock()
    private var collectedFormats: [VideoStreamFormat] = []
    private var collectedFrames: [(frame: VideoFrame, receivedAt: Double)] = []

    init(expectedFrames: Int) {
        self.expectedFrames = expectedFrames
        stopped.assertForOverFulfill = false
    }

    var formats: [VideoStreamFormat] {
        lock.lock()
        defer { lock.unlock() }
        return collectedFormats
    }

    var frames: [(frame: VideoFrame, receivedAt: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return collectedFrames
    }

    func receiver(_ receiver: AirPlayReceiver, didStartMirroringFrom clientName: String?) {
        XCTAssertEqual(clientName, "Test iPhone")
        started.fulfill()
    }

    func receiver(_ receiver: AirPlayReceiver, didChangeVideoFormat format: VideoStreamFormat) {
        lock.lock()
        collectedFormats.append(format)
        lock.unlock()
    }

    func receiver(_ receiver: AirPlayReceiver, didReceive frame: VideoFrame) {
        lock.lock()
        collectedFrames.append((frame, HostClock.now))
        let done = collectedFrames.count == expectedFrames
        lock.unlock()
        if done { framesArrived.fulfill() }
    }

    func receiver(_ receiver: AirPlayReceiver, didPauseVideo paused: Bool) {}

    func receiverDidStopMirroring(_ receiver: AirPlayReceiver) {
        stopped.fulfill()
    }
}
