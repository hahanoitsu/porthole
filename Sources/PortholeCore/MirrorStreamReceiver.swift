import Darwin
import Foundation

protocol MirrorStreamEvents: AnyObject {
    var smoothPlayback: Bool { get }
    func mirrorStream(_ connectionID: Int, didChangeFormat format: VideoStreamFormat)
    func mirrorStream(_ connectionID: Int, didReceive frame: VideoFrame)
    func mirrorStream(_ connectionID: Int, didPause paused: Bool)
    func mirrorStreamDidEnd(_ connectionID: Int)
}

/// Receives the mirrored screen: a TCP stream of packets, each a 128-byte header and a payload.
///
/// Header bytes 0-3: payload size (little-endian). Byte 4: type. 0 = video frame (AES-CTR
/// encrypted, one continuous keystream across frames), 1 = codec parameters (plain), 2 =
/// heartbeat, 5 = stats. Byte 6 on codec packets: 0x16/0x1e (H.264/HEVC) normally, 0x56/0x5e
/// when the phone pauses. Bytes 8-15: when to show the frame, as NTP-style 32.32 fixed-point
/// seconds on the phone's clock (little-endian).
final class MirrorStreamReceiver {
    let port: UInt16
    private let connectionID: Int
    private let listener: TCPListener
    private let decryptor: AESCTR
    private weak var events: MirrorStreamEvents?

    private let lock = NSLock()
    private var stopped = false
    private var streamFD: Int32 = -1

    // Only touched on the stream thread.
    private var codec: VideoCodec?
    private var paused = false
    private var totalFrames = 0
    private var badFrames = 0
    private let clock: PlayoutClock
    private var stats = Stats()

    init(sessionKey: Data, streamConnectionID: UInt64, connectionID: Int, clock: PlayoutClock, events: MirrorStreamEvents) throws {
        let key = sha512(Data("AirPlayStreamKey\(streamConnectionID)".utf8), sessionKey).prefix(16)
        let iv = sha512(Data("AirPlayStreamIV\(streamConnectionID)".utf8), sessionKey).prefix(16)
        decryptor = AESCTR(key: Data(key), iv: Data(iv))
        listener = try TCPListener(backlog: 1)
        port = listener.port
        self.connectionID = connectionID
        self.clock = clock
        self.events = events
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "porthole.mirror"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        if streamFD >= 0 { shutdown(streamFD, SHUT_RDWR) }
        lock.unlock()
        listener.close()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        var accepted: (fd: Int32, peer: SocketAddress)?
        while accepted == nil && !isStopped {
            accepted = listener.accept(timeoutMs: 250)
        }
        listener.close()
        guard let (fd, peer) = accepted else { return }

        lock.lock()
        let stoppedEarly = stopped
        if !stoppedEarly { streamFD = fd }
        lock.unlock()
        guard !stoppedEarly else {
            Darwin.close(fd)
            return
        }

        configure(fd)
        logInfo("Video stream connected from \(peer)")
        stats = Stats()

        while let header = Sockets.readExactly(fd, count: 128) {
            let size = Int(header.uint32LE(at: 0))
            guard size <= 64 << 20 else {
                logError("Video packet claims \(size) bytes; giving up on the stream")
                break
            }
            guard var payload = Sockets.readExactly(fd, count: size) else { break }
            handlePacket(header: header, payload: &payload, arrival: HostClock.now)
        }

        lock.lock()
        streamFD = -1
        Darwin.close(fd)
        lock.unlock()
        logInfo("Video stream ended after \(totalFrames) frames")
        events?.mirrorStreamDidEnd(connectionID)
    }

    private func configure(_ fd: Int32) {
        Sockets.setOption(fd, SOL_SOCKET, SO_RCVBUF, 4 << 20)
        Sockets.setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
        Sockets.setOption(fd, IPPROTO_TCP, TCP_KEEPALIVE, 60)
        Sockets.setOption(fd, IPPROTO_TCP, TCP_KEEPINTVL, 10)
        Sockets.setOption(fd, IPPROTO_TCP, TCP_KEEPCNT, 6)
    }

    private func handlePacket(header: Data, payload: inout Data, arrival: Double) {
        switch header.byte(4) {
        case 0x00:
            // Decrypt even before the first codec packet so the keystream stays aligned.
            decryptor.process(&payload)
            guard let codec else { return }
            guard NALUnits.isWellFormed(payload) else {
                badFrames += 1
                if badFrames == 1 || badFrames % 100 == 0 {
                    logWarning("Dropped \(badFrames) undecodable video packet(s); latest starts \(hexPreview(payload, limit: 16))")
                }
                return
            }
            let isKeyFrame = NALUnits.containsKeyFrame(payload, codec: codec)
            let stamp = Double(header.uint64LE(at: 8)) / 4_294_967_296
            let smooth = events?.smoothPlayback ?? true
            let slot = clock.scheduleFrame(stamp: stamp, arrival: arrival, isKeyFrame: isKeyFrame)
            let displayTime = smooth ? slot.displayTime : arrival

            totalFrames += 1
            if totalFrames == 1 {
                logInfo("First video frame: \(payload.count) bytes, NAL types \(NALUnits.types(payload, codec: codec))")
                logDebug("First video frame stamped \(stamp) s (phone clock), arrived \(arrival) s (host clock)")
            }
            stats.record(bytes: payload.count, keyFrame: isKeyFrame, stamp: stamp, slot: slot,
                         held: smooth ? max(0, displayTime - arrival) : nil, quickestTransit: arrival - stamp - slot.jitter)
            events?.mirrorStream(connectionID, didReceive: VideoFrame(data: payload, isKeyFrame: isKeyFrame, displayTime: displayTime))

        case 0x01:
            let option = header.byte(6)
            let pausing = option == 0x56 || option == 0x5e
            if pausing != paused {
                paused = pausing
                logInfo(pausing ? "The phone paused the video (screen locked or asleep)" : "The phone resumed the video")
                events?.mirrorStream(connectionID, didPause: pausing)
            }
            do {
                let format = try VideoStreamFormat.parse(header: header, payload: payload)
                codec = format.codec
                logInfo("Video format: \(format.codec.rawValue), \(format.width)x\(format.height) "
                        + "(source \(format.sourceWidth)x\(format.sourceHeight), option 0x\(String(option, radix: 16)))")
                events?.mirrorStream(connectionID, didChangeFormat: format)
            } catch {
                logError("Could not read the video format: \(error)")
            }

        case 0x02:
            break  // heartbeat

        case 0x05:
            logDebug("Video stream report from the phone (\(payload.count) bytes)")

        default:
            logDebug("Unknown video packet type \(header.byte(4)) (\(payload.count) bytes)")
        }
    }

    /// Every 10 seconds, logs the frame rate and bitrate, how evenly frames arrived (jitter
    /// beyond the quickest frame), how long smooth playback held them, and the phone's spacing.
    private struct Stats {
        var start = Date()
        var frames = 0
        var keyFrames = 0
        var bytes = 0
        var jitter: [Double] = []
        var held: [Double] = []
        var late = 0
        var withSound = 0
        var spacing: [Double] = []
        var lastStamp: Double?
        var quickestTransit = 0.0

        mutating func record(bytes count: Int, keyFrame: Bool, stamp: Double, slot: FramePacer.Slot, held holdTime: Double?,
                             quickestTransit transit: Double) {
            quickestTransit = transit
            frames += 1
            bytes += count
            if keyFrame { keyFrames += 1 }
            jitter.append(slot.jitter)
            if let holdTime {
                held.append(holdTime)
                if slot.isLate && !keyFrame { late += 1 }
                if slot.withSound { withSound += 1 }
            }
            if let lastStamp, stamp > lastStamp { spacing.append(stamp - lastStamp) }
            lastStamp = stamp

            let elapsed = Date().timeIntervalSince(start)
            guard elapsed >= 10 else { return }
            let sortedJitter = jitter.sorted()
            func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
            func percentile(_ sorted: [Double], _ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())]
            }
            var line = String(format: "Video: %.1f fps, %.1f Mbit/s, %d key frame(s) in %.0f s",
                              Double(frames) / elapsed, Double(bytes) * 8 / elapsed / 1_000_000, keyFrames, elapsed)
            line += "; jitter \(ms(percentile(sortedJitter, 0.5)))/\(ms(percentile(sortedJitter, 0.95)))/\(ms(sortedJitter.last ?? 0)) ms (median/95%/max)"
            if held.isEmpty {
                line += "; shown on arrival"
            } else {
                line += "; held \(ms(held.reduce(0, +) / Double(held.count))) ms on average, \(late) late"
                if withSound == held.count {
                    line += ", in step with the sound"
                } else if withSound > 0 {
                    line += ", in step with the sound for \(withSound) of \(held.count) frames"
                }
            }
            if !spacing.isEmpty {
                line += String(format: "; frames %.1f ms apart", percentile(spacing.sorted(), 0.5) * 1000)
            }
            logInfo(line)
            logDebug("Video timing: the quickest frames arrive \(quickestTransit) s after their stamp (host minus phone clock)")
            self = Stats(lastStamp: lastStamp)
        }
    }
}
