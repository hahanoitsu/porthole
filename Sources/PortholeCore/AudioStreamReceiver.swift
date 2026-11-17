import CommonCrypto
import Foundation

/// The mirror-mode audio stream: RTP over UDP, one AES-CBC encrypted AAC-ELD frame per packet.
///
/// Packet bytes 0-11: RTP header (byte 1 = 0x60, bytes 2-3 sequence, bytes 4-7 timestamp: the
/// first sample's number, 480 more each packet).
/// The phone sends every frame three times (n, then n-1 n, then n-2 n-1 n…) so a lost packet
/// costs nothing; duplicates are dropped by sequence number here.
///
/// About once a second a sync packet on the control port says when the phone wants its sound
/// played: bytes 4-7 an RTP time, 8-15 the NTP time (phone clock) it should play at, 16-19 the
/// RTP time being sent now (7497 samples, 170 ms, later). With it, sound goes on the schedule
/// it shares with the picture (PlayoutClock).
final class AudioStreamReceiver {
    /// The render cycle runs this far ahead of its output time, and a sample has to be queued by then.
    static let renderLead = 0.015

    static let noDataMarker = Data([0x00, 0x68, 0x34, 0x00])

    let dataPort: UInt16
    let controlPort: UInt16
    private let dataSocket: UDPSocket
    private let controlSocket: UDPSocket
    private let key: Data
    private let iv: Data
    private let decoder: AACELDDecoder?
    private let framesPerPacket: Int
    private let sink: AudioSink
    private let clock: PlayoutClock?
    private let silence: [Float]

    private let lock = NSLock()
    private var stopped = false
    private var flushRequested = false
    private var phoneSync: (ntp: Double, rtp: UInt32)?  // the latest sync packet: play `rtp` at `ntp`

    // Data thread only.
    private var expected: UInt16?
    private var pending: [UInt16: (payload: Data, rtpTime: Int64)] = [:]
    private var lastRTP: Int64?   // highest RTP time seen, counted past 32-bit wraps
    private var nextRTP: Int64?   // RTP time of the next frame to play
    private var played = 0
    private var duplicates = 0
    private var lost = 0
    private var undecodable = 0
    private var suspicious = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var lastArrival: UInt64 = 0
    private var windowPackets = 0
    private var longestWait: UInt64 = 0
    private var warnedAboutClock = false

    init(key: Data, iv: Data, compressionType: Int, framesPerPacket: Int, sink: AudioSink, clock: PlayoutClock? = nil) throws {
        dataSocket = try UDPSocket()
        controlSocket = try UDPSocket()
        dataPort = dataSocket.port
        controlPort = controlSocket.port
        self.key = key
        self.iv = iv
        self.sink = sink
        self.clock = clock
        self.framesPerPacket = framesPerPacket > 0 ? framesPerPacket : AACELDDecoder.framesPerPacket
        silence = [Float](repeating: 0, count: self.framesPerPacket * 2)
        if compressionType == 8 {
            decoder = try AACELDDecoder()
        } else {
            decoder = nil
            logWarning("Audio format ct=\(compressionType) isn't supported (only AAC-ELD, ct=8); this stream won't play")
        }
    }

    func start() {
        sink.start()
        let data = Thread { [self] in receiveAudio() }
        data.name = "porthole.audio.data"
        data.qualityOfService = .userInteractive
        data.start()
        let control = Thread { [self] in receiveControl() }
        control.name = "porthole.audio.control"
        control.start()
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        dataSocket.close()
        controlSocket.close()
        sink.stop()
        if !wasStopped {
            logInfo("Audio stream closed: \(played) frames played, \(duplicates) duplicates dropped, \(lost) lost, \(undecodable) undecodable")
        }
    }

    /// The phone restarted its audio (FLUSH): forget queued audio and resync on the next packet.
    func flush() {
        lock.lock()
        flushRequested = true
        lock.unlock()
        sink.flush()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func takeFlushRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let requested = flushRequested
        flushRequested = false
        return requested
    }

    private func receiveAudio() {
        while !isStopped {
            guard let (packet, _) = dataSocket.receive(maxLength: 2048, timeoutMs: 250) else { continue }
            handle(packet, arrival: HostClock.now)
        }
    }

    private func receiveControl() {
        var logged = 0
        while !isStopped {
            guard let (packet, from) = controlSocket.receive(timeoutMs: 250), packet.count >= 2 else { continue }
            if logged < 5 {
                logged += 1
                logDebug("Audio control packet from \(from): type 0x\(String(packet.byte(1) & 0x7f, radix: 16)), "
                         + "\(packet.count) bytes: \(hexPreview(packet, limit: 32)), received \(HostClock.now)")
            }
            if packet.count >= 20 && packet.byte(1) & 0x7f == 0x54 { noteSync(packet) }
        }
    }

    /// A sync packet: RTP time `rtp` should play at NTP time `ntp` on the phone's clock. Video
    /// stamps count from the same zero as the NTP time minus 1900-1970's 2,208,988,800 seconds.
    func noteSync(_ packet: Data) {
        let rtp = packet.uint32BE(at: 4)
        let ntp = packet.uint64BE(at: 8)
        let seconds = Double(ntp >> 32) - 2_208_988_800 + Double(ntp & 0xffff_ffff) / 4_294_967_296
        lock.lock()
        let first = phoneSync == nil
        phoneSync = (seconds, rtp)
        lock.unlock()
        if first {
            let ahead = Double(packet.uint32BE(at: 16) &- rtp) / AACELDDecoder.sampleRate
            logInfo("Sound timing from the phone: it schedules sound \(Int((ahead * 1000).rounded())) ms after sending it")
        }
    }

    func handle(_ packet: Data, arrival: Double = HostClock.now) {
        guard packet.count >= 12 else { return }
        guard packet.byte(1) & 0x7f == 0x60 else {
            logDebug("Ignoring audio packet of type 0x\(String(packet.byte(1) & 0x7f, radix: 16))")
            return
        }
        if takeFlushRequest() {
            expected = nil
            pending.removeAll()
            lastRTP = nil
            nextRTP = nil
            lastArrival = 0  // the phone paused its sound; that gap isn't the network
        }
        if lastRTP == nil {
            logDebug("First audio packet: sequence \(packet.uint16BE(at: 2)), RTP \(packet.uint32BE(at: 4)), arrived \(HostClock.now) s (host clock)")
        }
        accept(sequence: packet.uint16BE(at: 2), rtpTime: extendRTP(packet.uint32BE(at: 4)),
               payload: packet.bytes(at: 12, count: packet.count - 12), arrival: arrival)
    }

    /// RTP times are 32 bits and wrap every 27 hours at 44.1 kHz; this keeps counting past the wrap.
    private func extendRTP(_ raw: UInt32) -> Int64 {
        guard let last = lastRTP else {
            lastRTP = Int64(raw)
            return Int64(raw)
        }
        let value = last + Int64(Int32(bitPattern: raw &- UInt32(truncatingIfNeeded: last)))
        if value > last { lastRTP = value }
        return value
    }

    private func accept(sequence: UInt16, rtpTime: Int64, payload: Data, arrival: Double) {
        if expected == nil { expected = sequence }
        guard let next = expected else { return }
        let ahead = Int(Int16(bitPattern: sequence &- next))
        if ahead < 0 || pending[sequence] != nil {
            duplicates += 1
            return
        }
        noteArrival()
        scheduleSound(rtpTime: rtpTime, arrival: arrival)
        if ahead > 100 {
            logInfo("Audio jumped ahead \(ahead) packets; resyncing")
            expected = sequence
            pending.removeAll()
        }
        pending[sequence] = (payload, rtpTime)
        playInOrder()

        // Each frame arrives three times, so a gap with frames three or more past it won't fill.
        while let next = expected, pending[next] == nil,
              let furthest = pending.keys.map({ Int(Int16(bitPattern: $0 &- next)) }).max(), furthest >= 3 {
            lost += 1
            let missing = nextRTP ?? pending[next &+ UInt16(furthest)].map { $0.rtpTime - Int64(furthest * framesPerPacket) } ?? 0
            sink.enqueue(silence, rtpTime: missing)
            nextRTP = missing + Int64(framesPerPacket)
            expected = next &+ 1
            playInOrder()
        }
    }

    /// Logs every 10 s how much audio arrived, the longest wait for a new packet, and how
    /// playback coped, so the jitter buffer can be tuned against real Wi-Fi.
    private func noteArrival() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastArrival != 0 { longestWait = max(longestWait, now - lastArrival) }
        lastArrival = now
        windowPackets += 1
        let elapsed = now - windowStart
        guard elapsed >= 10_000_000_000 else { return }
        let streamSeconds = Double(windowPackets * framesPerPacket) / AACELDDecoder.sampleRate
        var line = String(format: "Audio: %.1f s of stream in %.1f s, longest wait %d ms",
                          streamSeconds, Double(elapsed) / 1e9, Int(longestWait / 1_000_000))
        if let playback = sink.takeWindowSummary() { line += "; " + playback }
        logInfo(line)
        windowStart = now
        windowPackets = 0
        longestWait = 0
    }

    /// Puts this packet's sound on the schedule it shares with the picture, once a sync packet has
    /// said when the phone wants it played. Sound muted on the Mac isn't heard, so then it plays
    /// as it comes and the picture doesn't wait for it.
    private func scheduleSound(rtpTime: Int64, arrival: Double) {
        lock.lock()
        let sync = phoneSync
        lock.unlock()
        guard let clock, let sync, !sink.isMuted else {
            sink.schedule(heardTimeOfSampleZero: nil)
            return
        }
        let samplesAfterSync = Int32(bitPattern: UInt32(truncatingIfNeeded: rtpTime) &- sync.rtp)
        let presentation = sync.ntp + Double(samplesAfterSync) / AACELDDecoder.sampleRate
        guard let offset = clock.noteSound(presentation: presentation, arrival: arrival,
                                           outputLead: sink.outputLatency + Self.renderLead) else {
            if !warnedAboutClock {
                warnedAboutClock = true
                logWarning("The phone's sound times don't fit its picture times; playing sound as it comes")
            }
            sink.schedule(heardTimeOfSampleZero: nil)
            return
        }
        sink.schedule(heardTimeOfSampleZero: presentation + offset - Double(rtpTime) / AACELDDecoder.sampleRate)
    }

    private func playInOrder() {
        while let next = expected, let entry = pending.removeValue(forKey: next) {
            play(entry.payload, rtpTime: entry.rtpTime)
            nextRTP = entry.rtpTime + Int64(framesPerPacket)
            expected = next &+ 1
        }
    }

    private func play(_ payload: Data, rtpTime: Int64) {
        // The stream opens with placeholder packets before there is any sound.
        guard !payload.isEmpty, payload != Self.noDataMarker else { return }
        guard let decoder else { return }

        let frame = aesCBC(CCOperation(kCCDecrypt), blocksOf: payload, key: key, iv: iv)
        if frame.byte(0) & 0xf0 != 0x80 {
            suspicious += 1
            if suspicious == 1 || suspicious % 500 == 0 {
                logWarning("Audio frame doesn't look like AAC-ELD after decryption (\(suspicious) so far): \(hexPreview(frame, limit: 8))")
            }
        }
        guard let samples = decoder.decode(frame), !samples.isEmpty else {
            undecodable += 1
            if undecodable == 1 || undecodable % 500 == 0 { logWarning("Could not decode \(undecodable) audio frame(s)") }
            sink.enqueue(silence, rtpTime: rtpTime)
            return
        }
        played += 1
        if played == 1 { logInfo("Audio is playing (\(samples.count / 2) samples per frame)") }
        sink.enqueue(samples, rtpTime: rtpTime)
    }
}
