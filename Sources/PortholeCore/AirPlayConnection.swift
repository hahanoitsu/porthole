import Darwin
import Foundation

/// One phone's control connection: the RTSP conversation that pairs, runs FairPlay, and sets up
/// the clock-sync, video and audio streams.
final class AirPlayConnection {
    let id: Int
    let peer: SocketAddress
    private let fd: Int32
    private unowned let receiver: AirPlayReceiver
    private let pairing: PairingSession
    private var fairPlay = FairPlaySession()
    private var sessionKey: Data?  // FairPlay-decrypted, then hashed with the pairing secret
    private var sessionIV: Data?   // used for audio
    private var sessionStart: Date?
    private var volume: Float = 0  // AirPlay dB: 0 is full, -144 muted
    private(set) var clientName: String?

    private let lock = NSLock()
    private var closed = false
    private var timing: NTPTimingClient?
    private var mirror: MirrorStreamReceiver?
    private var audio: AudioStreamReceiver?
    /// Picture and sound in this session share one schedule.
    private let playout: PlayoutClock

    init(id: Int, fd: Int32, peer: SocketAddress, receiver: AirPlayReceiver) {
        self.id = id
        self.fd = fd
        self.peer = peer
        self.receiver = receiver
        pairing = PairingSession(identity: receiver.identity.signingKey)
        playout = PlayoutClock(pictureOffset: receiver.pictureOffset)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "porthole.rtsp.\(id)"
        thread.start()
    }

    /// Ends the connection from another thread.
    func stop() {
        lock.lock()
        if !closed { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    func stopMirroring(reason: String) {
        logInfo("Connection \(id): stopping video (\(reason))")
        lock.lock()
        let stream = mirror
        mirror = nil
        lock.unlock()
        stream?.stop()
    }

    // MARK: - Request loop

    private func run() {
        logInfo("Connection \(id) from \(peer)")
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        reading: while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])

            while true {
                let parsed: (request: RTSPRequest, consumed: Int)?
                do {
                    parsed = try RTSPRequest.parse(buffer)
                } catch {
                    logError("Connection \(id): \(error)")
                    break reading
                }
                guard let parsed else { break }
                buffer = Data(buffer.dropFirst(parsed.consumed))
                let response = handle(parsed.request)
                guard Sockets.writeAll(fd, response.serialized()) else { break reading }
                if response.closeConnection { break reading }
            }
        }

        stopStreams()
        lock.lock()
        closed = true
        Darwin.close(fd)
        lock.unlock()
        logInfo("Connection \(id) closed\(sessionAge)")
        receiver.connectionDidClose(self)
    }

    private func handle(_ request: RTSPRequest) -> RTSPResponse {
        let routine = request.path == "/feedback" || request.method == "GET_PARAMETER" || request.method == "SET_PARAMETER"
        let summary = "\(request.method) \(request.uri)" + (request.body.isEmpty ? "" : " (\(request.body.count) bytes)")
        if routine { logDebug("Connection \(id) ← \(summary)") } else { logInfo("Connection \(id) ← \(summary)") }

        var response = RTSPResponse(proto: request.proto)
        if request.cseq != nil && request.method != "RECORD" {
            response.addHeader("Audio-Jack-Status", "connected; type=digital")
        }
        do {
            switch request.method {
            case "GET" where request.path.hasPrefix("/info"):
                try handleInfo(request, &response)
            case "POST":
                try handlePost(request, &response)
            case "OPTIONS":
                response.addHeader("Public", "SETUP, RECORD, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER")
            case "SETUP":
                try handleSetup(request, &response)
            case "GET_PARAMETER":
                handleGetParameter(request, &response)
            case "SET_PARAMETER":
                handleSetParameter(request)
            case "RECORD":
                response.addHeader("Audio-Latency", "11025")
                response.addHeader("Audio-Jack-Status", "connected; type=analog")
            case "FLUSH":
                lock.lock()
                let stream = audio
                lock.unlock()
                stream?.flush()
            case "TEARDOWN":
                handleTeardown(request, &response)
            default:
                logWarning("Connection \(id): unsupported request \(request.method) \(request.uri)")
                response.setStatus(501, "Not Implemented")
            }
        } catch {
            logError("Connection \(id): \(request.method) \(request.path) failed: \(error)")
            response = RTSPResponse(proto: request.proto)
            response.setStatus(400, "Bad Request")
        }
        response.addHeader("Server", "AirTunes/\(ReceiverConfig.sourceVersion)")
        if let cseq = request.cseq { response.addHeader("CSeq", cseq) }
        if !routine { logDebug("Connection \(id) → \(response.status), \(response.body.count) bytes") }
        return response
    }

    // MARK: - Handlers

    private func handleInfo(_ request: RTSPRequest, _ response: inout RTSPResponse) throws {
        var qualifiers: [String] = []
        let hasContentType = request.header("Content-Type") != nil
        if hasContentType,
           let plist = (try? PropertyListSerialization.propertyList(from: request.body, format: nil)) as? [String: Any],
           let requested = plist["qualifier"] as? [String] {
            qualifiers = requested
        }
        let fromBluetoothBeacon = request.cseq == nil
        if fromBluetoothBeacon {
            if request.uri.contains("txtAirPlay") { qualifiers.append("txtAirPlay") }
            if request.uri.contains("txtRAOP") { qualifiers.append("txtRAOP") }
        }

        var info: [String: Any] = [:]
        if qualifiers.contains("txtAirPlay") { info["txtAirPlay"] = receiver.airplayTXT }
        if qualifiers.contains("txtRAOP") { info["txtRAOP"] = receiver.raopTXT }
        if !hasContentType {
            info.merge(receiver.infoDictionary(full: !fromBluetoothBeacon)) { current, _ in current }
        }
        try response.setPlistBody(info)
    }

    private func handlePost(_ request: RTSPRequest, _ response: inout RTSPResponse) throws {
        switch request.path {
        case "/pair-setup":
            response.body = try pairing.handlePairSetup(request.body)
            response.addHeader("Content-Type", "application/octet-stream")

        case "/pair-verify":
            guard request.body.count >= 4 else { throw AirPlayError.badRequest("pair-verify body too short") }
            if request.body.byte(0) == 1 {
                response.body = try pairing.handlePairVerifyStart(request.body)
            } else if try pairing.handlePairVerifyFinish(request.body) {
                logInfo("Connection \(id): paired")
            } else {
                logError("Connection \(id): the phone's pairing signature didn't verify; closing")
                response.closeConnection = true
            }
            response.addHeader("Content-Type", "application/octet-stream")

        case "/fp-setup":
            response.body = try fairPlay.handleSetup(request.body)
            response.addHeader("Content-Type", "application/octet-stream")
            if request.body.count == 164 { logInfo("Connection \(id): FairPlay handshake done") }

        case "/feedback":
            if !request.body.isEmpty { logDebug("Connection \(id): feedback \(describePlist(request.body))") }

        case "/audioMode":
            logInfo("Connection \(id): audio mode \(describePlist(request.body))\(sessionAge)")

        default:
            logInfo("Connection \(id): ignoring POST \(request.path)")
        }
    }

    private func handleSetup(_ request: RTSPRequest, _ response: inout RTSPResponse) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: request.body, format: nil) as? [String: Any] else {
            throw AirPlayError.badRequest("SETUP body is not a dictionary")
        }
        logInfo("Connection \(id): SETUP \(describePlist(request.body))")
        var result: [String: Any] = [:]

        if let ekey = plist["ekey"] as? Data, let eiv = plist["eiv"] as? Data {
            try setUpSession(plist, ekey: ekey, eiv: eiv, userAgent: request.header("User-Agent"), result: &result)
        }

        if let streams = plist["streams"] as? [[String: Any]] {
            var described: [[String: Any]] = []
            for stream in streams {
                let type = (stream["type"] as? NSNumber)?.intValue ?? -1
                switch type {
                case 110:
                    described.append(try setUpMirrorStream(stream))
                case 96:
                    described.append(try setUpAudioStream(stream))
                default:
                    logError("Connection \(id): SETUP for unknown stream type \(type)")
                    response.closeConnection = true
                }
            }
            result["streams"] = described
        }
        try response.setPlistBody(result)
    }

    private func setUpSession(_ plist: [String: Any], ekey: Data, eiv: Data, userAgent: String?, result: inout [String: Any]) throws {
        guard ekey.count == 72, eiv.count == 16 else {
            throw AirPlayError.badRequest("SETUP ekey/eiv sizes \(ekey.count)/\(eiv.count), expected 72/16")
        }
        clientName = plist["name"] as? String
        sessionStart = Date()
        let model = plist["model"] as? String ?? "?"
        let os = plist["osVersion"] as? String ?? "?"
        logInfo("Connection \(id): session from \"\(clientName ?? "?")\" (\(model), OS \(os), \(userAgent ?? "no user agent"))")

        var key = try fairPlay.decryptKey(ekey)
        if let secret = pairing.secretForKeyDerivation {
            key = Data(sha512(key, secret).prefix(16))
        }
        sessionKey = key
        sessionIV = eiv

        let timingProtocol = plist["timingProtocol"] as? String
        if let timingProtocol, timingProtocol != "NTP" {
            logWarning("Connection \(id): phone asked for timing protocol \(timingProtocol); only NTP is supported")
        }
        let timingPort = (plist["timingPort"] as? NSNumber)?.uint16Value ?? 0
        let clock = try NTPTimingClient(remote: peer.withPort(timingPort))
        if timingPort != 0 { clock.start() } else { logWarning("Connection \(id): no timing port from the phone") }

        lock.lock()
        let previous = timing
        timing = clock
        lock.unlock()
        previous?.stop()

        result["timingPort"] = Int(clock.localPort)
        result["eventPort"] = 0
    }

    private func setUpMirrorStream(_ stream: [String: Any]) throws -> [String: Any] {
        guard let sessionKey else { throw AirPlayError.badRequest("video SETUP before the session SETUP") }
        let streamConnectionID = (stream["streamConnectionID"] as? NSNumber)?.uint64Value ?? 0
        let receiverStream = try MirrorStreamReceiver(sessionKey: sessionKey, streamConnectionID: streamConnectionID,
                                                      connectionID: id, clock: playout, events: receiver)
        lock.lock()
        let previous = mirror
        mirror = receiverStream
        lock.unlock()
        previous?.stop()

        receiverStream.start()
        receiver.mirrorDidStart(on: self)
        logInfo("Connection \(id): video stream on port \(receiverStream.port)")
        return ["type": 110, "dataPort": Int(receiverStream.port)]
    }

    private func setUpAudioStream(_ stream: [String: Any]) throws -> [String: Any] {
        let compression = (stream["ct"] as? NSNumber)?.intValue ?? 0
        let samplesPerFrame = (stream["spf"] as? NSNumber)?.intValue ?? 0
        let format = (stream["audioFormat"] as? NSNumber)?.uint64Value ?? 0
        let usingScreen = (stream["usingScreen"] as? NSNumber)?.boolValue ?? false
        logInfo("Connection \(id): audio stream ct=\(compression) spf=\(samplesPerFrame) format=0x\(String(format, radix: 16)) usingScreen=\(usingScreen)")
        guard let sessionKey, let sessionIV else { throw AirPlayError.badRequest("audio SETUP before the session SETUP") }

        let sink = receiver.makeAudioSink()
        sink.isMuted = receiver.isAudioMuted
        sink.gain = gain(forAirPlayVolume: volume)
        let receiverStream = try AudioStreamReceiver(key: sessionKey, iv: sessionIV, compressionType: compression,
                                                     framesPerPacket: samplesPerFrame, sink: sink, clock: playout)
        lock.lock()
        let previous = audio
        audio = receiverStream
        lock.unlock()
        previous?.stop()

        receiver.audioDidStart(sink, connectionID: id)
        receiverStream.start()
        return ["type": 96, "dataPort": Int(receiverStream.dataPort), "controlPort": Int(receiverStream.controlPort)]
    }

    /// " after 1m 05s" once a session has started, for spotting the phone giving up at a set time.
    private var sessionAge: String {
        guard let sessionStart else { return "" }
        let seconds = Int(Date().timeIntervalSince(sessionStart))
        return " after \(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }

    private func handleGetParameter(_ request: RTSPRequest, _ response: inout RTSPResponse) {
        guard request.header("Content-Type") == "text/parameters" else {
            response.setStatus(451, "Parameter not understood")
            return
        }
        if String(decoding: request.body, as: UTF8.self).hasPrefix("volume") {
            response.addHeader("Content-Type", "text/parameters")
            response.body = Data(String(format: "volume: %.6f\r\n", volume).utf8)
        }
    }

    private func handleSetParameter(_ request: RTSPRequest) {
        guard request.header("Content-Type") == "text/parameters" else { return }
        let text = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.hasPrefix("volume:"), let value = Float(text.dropFirst("volume:".count).trimmingCharacters(in: .whitespaces)) {
            volume = value
            logInfo("Connection \(id): phone volume \(value <= -144 ? "muted" : String(format: "%.1f dB", value))")
            lock.lock()
            let stream = audio
            lock.unlock()
            if stream != nil { receiver.setAudioGain(gain(forAirPlayVolume: value), connectionID: id) }
        } else {
            logDebug("Connection \(id): parameter \(text)")
        }
    }

    private func handleTeardown(_ request: RTSPRequest, _ response: inout RTSPResponse) {
        let plist = (try? PropertyListSerialization.propertyList(from: request.body, format: nil)) as? [String: Any]
        let types = (plist?["streams"] as? [[String: Any]])?.compactMap { ($0["type"] as? NSNumber)?.intValue } ?? []
        logInfo("Connection \(id): teardown of \(types.isEmpty ? "the whole session" : "stream(s) \(types)")\(sessionAge); "
                + "request: \(describePlist(request.body))")
        response.addHeader("Connection", "close")
        if types.isEmpty {
            stopStreams()
        } else {
            if types.contains(110) { stopMirroring(reason: "phone stopped mirroring") }
            if types.contains(96) { stopAudio() }
        }
    }

    // MARK: - Streams

    private func stopAudio() {
        lock.lock()
        let stream = audio
        audio = nil
        lock.unlock()
        stream?.stop()
        if stream != nil { receiver.audioDidStop(connectionID: id) }
    }

    private func stopStreams() {
        lock.lock()
        let streams = (mirror, audio, timing)
        mirror = nil
        audio = nil
        timing = nil
        lock.unlock()
        streams.0?.stop()
        streams.1?.stop()
        streams.2?.stop()
        if streams.1 != nil { receiver.audioDidStop(connectionID: id) }
    }
}
