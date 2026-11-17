import Foundation

/// The receiver's side of AirPlay's NTP-style clock sync: every few seconds, ask the phone's
/// timing port for its clock. Frame pacing measures the phone's clock against arrivals directly
/// (`FramePacer`), so the offset is only logged; the exchange mainly keeps the session healthy,
/// as UxPlay does.
final class NTPTimingClient {
    let localPort: UInt16
    private let socket: UDPSocket
    private let remote: SocketAddress
    private let lock = NSLock()
    private var stopped = false

    init(remote: SocketAddress) throws {
        socket = try UDPSocket()
        localPort = socket.port
        self.remote = remote
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "porthole.ntp"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        socket.close()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        var request = Data(count: 32)
        request[0] = 0x80
        request[1] = 0xd2  // timing request
        request[3] = 0x07
        var replies = 0
        var misses = 0

        while !isStopped {
            let sent = ntpTimestamp()
            request.replaceSubrange(24..<32, with: bigEndianBytes(sent))
            socket.send(request, to: remote)

            if let response = serviceSocket(for: 0.5, waitingForReply: true) {
                let received = ntpTimestamp()
                let originate = response.uint64BE(at: 8)
                let clientReceive = response.uint64BE(at: 16)
                let clientTransmit = response.uint64BE(at: 24)
                // Echo the phone's transmit time and record our receive time in the next request.
                request.replaceSubrange(8..<16, with: bigEndianBytes(clientTransmit))
                request.replaceSubrange(16..<24, with: bigEndianBytes(received))
                replies += 1
                misses = 0
                if replies == 1 {
                    logInfo("Clock sync with the phone is working (round trip \(String(format: "%.1f", seconds(received &- sent) * 1000)) ms)")
                } else if originate == sent {
                    let offset = (seconds(clientReceive &- originate) + seconds(clientTransmit &- received)) / 2
                    logDebug("NTP offset \(offset) s")
                }
            } else if !isStopped {
                misses += 1
                if misses == 3 || misses % 20 == 0 {
                    logWarning("No clock-sync reply from the phone (\(misses) in a row)")
                }
            }

            _ = serviceSocket(for: 3, waitingForReply: false)
        }
    }

    private var answeredRequests = 0

    /// Reads the socket for up to `duration` seconds, answering any time requests from the phone.
    /// Returns the first reply to our own request when `waitingForReply`.
    private func serviceSocket(for duration: TimeInterval, waitingForReply: Bool) -> Data? {
        let deadline = Date().addingTimeInterval(duration)
        while !isStopped {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            guard remaining > 0, let (packet, from) = socket.receive(maxLength: 128, timeoutMs: min(remaining, 250)) else {
                if remaining <= 0 { return nil }
                continue
            }
            guard packet.count >= 32 else { continue }
            switch packet.byte(1) & 0x7f {
            case 0x53 where waitingForReply:
                return packet
            case 0x52:
                answerTimingRequest(packet, from: from)
            default:
                continue
            }
        }
        return nil
    }

    /// The phone asking for our clock: reply with its transmit time and our receive/transmit times.
    private func answerTimingRequest(_ packet: Data, from address: SocketAddress) {
        let received = ntpTimestamp()
        var reply = Data(packet.prefix(32))
        reply[1] = 0xd3
        reply.replaceSubrange(8..<16, with: packet.bytes(at: 24, count: 8))
        reply.replaceSubrange(16..<24, with: bigEndianBytes(received))
        reply.replaceSubrange(24..<32, with: bigEndianBytes(ntpTimestamp()))
        socket.send(reply, to: address)
        answeredRequests += 1
        if answeredRequests == 1 { logInfo("The phone asked for our clock; answering") }
    }

    private func bigEndianBytes(_ value: UInt64) -> Data {
        var data = Data()
        data.appendUInt64BE(value)
        return data
    }

    /// Converts a difference of two 32.32 fixed-point timestamps to seconds (signed).
    private func seconds(_ difference: UInt64) -> Double {
        Double(Int64(bitPattern: difference)) / 4_294_967_296.0
    }
}

/// Now as an NTP timestamp: seconds since 1900 in the high 32 bits, fraction in the low 32.
func ntpTimestamp(_ date: Date = Date()) -> UInt64 {
    let seconds = date.timeIntervalSince1970 + 2_208_988_800
    let whole = UInt64(seconds)
    let fraction = UInt64((seconds - Double(whole)) * 4_294_967_296.0)
    return whole << 32 | fraction
}
