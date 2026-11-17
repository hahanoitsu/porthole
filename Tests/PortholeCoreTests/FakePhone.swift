import CommonCrypto
import CryptoKit
import XCTest
@testable import PortholeCore

/// Plays the iPhone's side of a mirroring session against a real receiver on localhost.
final class FakePhone {
    let client: TestRTSPClient
    let receiver: AirPlayReceiver
    let eiv = randomData(16)
    private(set) var sessionKey = Data()
    private(set) var clock: UDPSocket?
    /// The receiver's own timing port, from its SETUP reply.
    private(set) var receiverTimingPort: UInt16 = 0
    private let plistType = "application/x-apple-binary-plist"
    private let octets = "application/octet-stream"

    init(receiver: AirPlayReceiver) throws {
        self.receiver = receiver
        client = try TestRTSPClient(port: receiver.port)
    }

    func request(_ method: String, _ uri: String = "rtsp://127.0.0.1/4242", plist: [String: Any]? = nil) throws -> TestRTSPClient.Response {
        if let plist {
            return try client.request(method, uri, body: try binaryPlist(plist), contentType: plistType)
        }
        return try client.request(method, uri)
    }

    /// /info, pairing, FairPlay and the session SETUP, checking each answer along the way.
    /// With `pairSetup` false it skips /pair-setup, as a reconnecting iPhone does.
    func startSession(name: String = "Test iPhone", pairSetup: Bool = true) throws {
        let info = try plistDictionary(try client.request("GET", "/info").body)
        XCTAssertEqual((info["features"] as? NSNumber)?.uint64Value, receiver.config.features)

        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        if pairSetup {
            XCTAssertEqual(try client.request("POST", "/pair-setup", body: signing.publicKey.rawRepresentation, contentType: octets).body,
                           receiver.identity.publicKey)
        }
        let verify = try client.request("POST", "/pair-verify", body: Data([1, 0, 0, 0]) + agreement.publicKey.rawRepresentation
                                        + signing.publicKey.rawRepresentation, contentType: octets)
        XCTAssertEqual(verify.body.count, 96)
        let serverAgreement = verify.body.prefix(32)
        let secret = try agreement.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: serverAgreement)).withUnsafeBytes { Data($0) }
        let cipher = AESCTR(key: Data(sha512(Data("Pair-Verify-AES-Key".utf8), secret).prefix(16)),
                            iv: Data(sha512(Data("Pair-Verify-AES-IV".utf8), secret).prefix(16)))
        XCTAssertTrue(receiver.identity.signingKey.publicKey.isValidSignature(
            cipher.processed(verify.body.suffix(64)), for: serverAgreement + agreement.publicKey.rawRepresentation))
        let signature = try signing.signature(for: agreement.publicKey.rawRepresentation + serverAgreement)
        XCTAssertEqual(try client.request("POST", "/pair-verify", body: Data([0, 0, 0, 0]) + cipher.processed(signature),
                                          contentType: octets).status, 200)

        let setupRequest = Data([0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x02, 0x00, 0x02, 0xbb])
        XCTAssertEqual(try client.request("POST", "/fp-setup", body: setupRequest, contentType: octets).body.count, 142)
        var keyMessage = randomData(164)
        keyMessage[4] = 0x03
        keyMessage[12] = 0x02  // mode
        XCTAssertEqual(try client.request("POST", "/fp-setup", body: keyMessage, contentType: octets).body.suffix(20), keyMessage.suffix(20))

        let ekey = randomData(72)
        let clock = try UDPSocket()
        self.clock = clock
        let setup = try request("SETUP", plist: [
            "ekey": ekey, "eiv": eiv, "timingProtocol": "NTP", "timingPort": Int(clock.port),
            "name": name, "model": "iPhone18,1", "osVersion": "27.0", "isScreenMirroringSession": true,
        ])
        XCTAssertEqual(setup.status, 200)
        receiverTimingPort = try XCTUnwrap((try plistDictionary(setup.body)["timingPort"] as? NSNumber)?.uint16Value)

        var fairPlay = FairPlaySession()
        _ = try fairPlay.handleSetup(keyMessage)
        sessionKey = Data(sha512(try fairPlay.decryptKey(ekey), secret).prefix(16))
    }

    /// Answers one clock-sync request from the receiver, as the phone does.
    func answerTimingRequest() throws {
        let timing = try XCTUnwrap(clock?.receive(timeoutMs: 2000), "the receiver should ask for the phone's time")
        XCTAssertEqual(timing.data.count, 32)
        XCTAssertEqual(timing.data[1], 0xd2)
        var reply = timing.data
        reply[1] = 0xd3
        reply.replaceSubrange(8..<16, with: timing.data[24..<32])
        clock?.send(reply, to: timing.from)
    }

    func setUpVideo(streamConnectionID: UInt64) throws -> UInt16 {
        let response = try request("SETUP", plist: ["streams": [["type": 110, "streamConnectionID": NSNumber(value: streamConnectionID)]]])
        let stream = try XCTUnwrap((try plistDictionary(response.body)["streams"] as? [[String: Any]])?.first)
        return try XCTUnwrap((stream["dataPort"] as? NSNumber)?.uint16Value)
    }

    func videoCipher(streamConnectionID: UInt64) -> AESCTR {
        AESCTR(key: Data(sha512(Data("AirPlayStreamKey\(streamConnectionID)".utf8), sessionKey).prefix(16)),
               iv: Data(sha512(Data("AirPlayStreamIV\(streamConnectionID)".utf8), sessionKey).prefix(16)))
    }

    func setUpAudio() throws -> UInt16 {
        try setUpAudioPorts().data
    }

    func setUpAudioPorts() throws -> (data: UInt16, control: UInt16) {
        let response = try request("SETUP", plist: ["streams": [[
            "type": 96, "ct": 8, "spf": 480, "audioFormat": 0x100_0000, "controlPort": 50_000,
            "usingScreen": true, "isMedia": false,
        ]]])
        XCTAssertEqual(response.status, 200)
        let stream = try XCTUnwrap((try plistDictionary(response.body)["streams"] as? [[String: Any]])?.first)
        return (try XCTUnwrap((stream["dataPort"] as? NSNumber)?.uint16Value),
                try XCTUnwrap((stream["controlPort"] as? NSNumber)?.uint16Value))
    }

    /// A sync packet: RTP time `rtpTime` should play at `seconds` on the phone's clock, and
    /// 7497 samples later is being sent now, as an iPhone does.
    func syncPacket(rtpTime: UInt32, playsAt seconds: Double) -> Data {
        var packet = Data([0x90, 0xd4, 0x00, 0x04])
        packet.appendUInt32BE(rtpTime)
        let ntp = seconds + 2_208_988_800
        packet.appendUInt64BE(UInt64(ntp) << 32 | UInt64((ntp - ntp.rounded(.down)) * 4_294_967_296))
        packet.appendUInt32BE(rtpTime &+ 7497)
        return packet
    }

    /// One RTP audio packet: the AAC-ELD frame AES-CBC encrypted with the session key, or the
    /// placeholder the phone sends before there is sound.
    func audioPacket(sequence: UInt16, rtpTime: UInt32, frame: Data?) -> Data {
        var packet = Data([0x80, 0x60])
        packet.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xff)])
        packet.appendUInt32BE(rtpTime)
        packet.appendUInt32BE(0)
        if let frame {
            packet.append(aesCBC(CCOperation(kCCEncrypt), blocksOf: frame, key: sessionKey, iv: eiv))
        } else {
            packet.append(AudioStreamReceiver.noDataMarker)
        }
        return packet
    }
}

/// Collects decoded audio instead of playing it.
final class RecordingSink: AudioSink {
    let enoughAudio = XCTestExpectation(description: "enough audio decoded")
    private let lock = NSLock()
    private let expectedFrames: Int
    private var collected: [Float] = []
    private var muted = false
    private var linearGain: Float = 1
    private(set) var started = false
    private(set) var stopped = false
    private(set) var flushes = 0
    private var enqueuedTimes: [Int64] = []
    private var base: Double?
    /// What the sink reports as its output device's delay.
    var latency = 0.0

    var outputLatency: Double { latency }

    /// The latest schedule: RTP sample R heard at `scheduleBase + R / 44100`.
    var scheduleBase: Double? {
        lock.lock()
        defer { lock.unlock() }
        return base
    }

    func schedule(heardTimeOfSampleZero newBase: Double?) {
        lock.lock()
        base = newBase
        lock.unlock()
    }

    /// The RTP time of each enqueue, in order.
    var rtpTimes: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return enqueuedTimes
    }


    init(expectedFrames: Int = .max) {
        self.expectedFrames = expectedFrames
        enoughAudio.assertForOverFulfill = false
    }

    var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var isMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return muted }
        set { lock.lock(); muted = newValue; lock.unlock() }
    }

    var gain: Float {
        get { lock.lock(); defer { lock.unlock() }; return linearGain }
        set { lock.lock(); linearGain = newValue; lock.unlock() }
    }

    func start() { started = true }
    func stop() { stopped = true }
    func flush() { flushes += 1 }


    func enqueue(_ samples: [Float], rtpTime: Int64) {
        lock.lock()
        collected += samples
        enqueuedTimes.append(rtpTime)
        let frames = collected.count / 2
        lock.unlock()
        if frames >= expectedFrames { enoughAudio.fulfill() }
    }
}
