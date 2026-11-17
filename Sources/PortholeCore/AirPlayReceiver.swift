import Foundation

/// One mirrored frame, ready to decode.
public struct VideoFrame: Sendable {
    /// NAL units, each with a 4-byte big-endian length prefix.
    public let data: Data
    public let isKeyFrame: Bool
    /// When to show it, in `HostClock` seconds.
    public let displayTime: Double
}

/// Mirroring events. Video callbacks arrive on the stream's own thread, in order; the others
/// arrive on background threads too.
public protocol AirPlayReceiverDelegate: AnyObject {
    func receiver(_ receiver: AirPlayReceiver, didStartMirroringFrom clientName: String?)
    /// Comes before the frames that use it, and again when the picture changes shape.
    func receiver(_ receiver: AirPlayReceiver, didChangeVideoFormat format: VideoStreamFormat)
    func receiver(_ receiver: AirPlayReceiver, didReceive frame: VideoFrame)
    func receiver(_ receiver: AirPlayReceiver, didPauseVideo paused: Bool)
    func receiverDidStopMirroring(_ receiver: AirPlayReceiver)
    /// Phones can now see the receiver. Called on the main queue.
    func receiverDidBecomeDiscoverable(_ receiver: AirPlayReceiver)
    /// Advertising failed, so phones can't see the receiver. Called on the main queue.
    func receiver(_ receiver: AirPlayReceiver, couldNotAdvertise reason: String)
}

public extension AirPlayReceiverDelegate {
    func receiverDidBecomeDiscoverable(_ receiver: AirPlayReceiver) {}
    func receiver(_ receiver: AirPlayReceiver, couldNotAdvertise reason: String) {}
}

/// An AirPlay screen-mirroring receiver: advertises itself over Bonjour, accepts phones, and
/// hands their decrypted video to the delegate. One phone mirrors at a time; a new one takes over.
public final class AirPlayReceiver: MirrorStreamEvents {
    public let config: ReceiverConfig
    public let identity: ReceiverIdentity
    public weak var delegate: AirPlayReceiverDelegate?
    public private(set) var port: UInt16 = 0

    let airplayTXT: Data
    let raopTXT: Data

    private let bonjour = BonjourAdvertiser()
    private var listener: TCPListener?
    private let lock = NSLock()
    private var connections: [Int: AirPlayConnection] = [:]
    private var nextConnectionID = 1
    private var mirroringConnectionID: Int?
    private var audioMuted = false
    private var audioSinks: [Int: AudioSink] = [:]  // by connection
    private var smooth = true
    private var frameRate: Int
    private var soundOffset = 0.0

    /// Makes the destination for each audio stream. Tests swap in a recorder.
    var makeAudioSink: () -> AudioSink = { AudioPlayer() }

    /// Silences the phone's sound on this Mac without stopping the stream, so unmuting is instant.
    public var isAudioMuted: Bool {
        get { locked { audioMuted } }
        set {
            let sinks = locked {
                audioMuted = newValue
                return Array(audioSinks.values)
            }
            sinks.forEach { $0.isMuted = newValue }
        }
    }

    /// Show frames on an even schedule, held back as little as recent Wi-Fi delays allow
    /// (`FramePacer`). When false, each frame shows as soon as it's decoded.
    public var smoothPlayback: Bool {
        get { locked { smooth } }
        set { locked { smooth = newValue } }
    }

    /// Moves the picture against the sound while sound plays, in seconds: positive shows the
    /// picture later. Applies to sessions that start after it's set.
    public var pictureOffset: Double {
        get { locked { soundOffset } }
        set { locked { soundOffset = newValue } }
    }

    /// The most frames per second offered to phones. Phones read it when they connect.
    public var maxFPS: Int {
        get { locked { frameRate } }
        set { locked { frameRate = max(1, newValue) } }
    }

    public init(config: ReceiverConfig, identity: ReceiverIdentity) {
        self.config = config
        self.identity = identity
        frameRate = config.maxFPS
        airplayTXT = config.airplayTXT(identity: identity)
        raopTXT = config.raopTXT(identity: identity)
    }

    /// Starts listening. With `advertise` false nothing is announced over Bonjour (for tests).
    public func start(advertise: Bool = true) throws {
        let listener = try TCPListener()
        self.listener = listener
        port = listener.port

        if advertise {
            bonjour.onResult = { [weak self] type, error in
                guard let self else { return }
                if let error {
                    self.delegate?.receiver(self, couldNotAdvertise: error)
                } else if type == "_airplay._tcp" {
                    self.delegate?.receiverDidBecomeDiscoverable(self)
                }
            }
            try bonjour.register(name: config.name, type: "_airplay._tcp", port: port, txt: airplayTXT)
            try bonjour.register(name: "\(identity.raopPrefix)@\(config.name)", type: "_raop._tcp", port: port, txt: raopTXT)
        }

        let thread = Thread { [self] in acceptConnections(on: listener) }
        thread.name = "porthole.rtsp.accept"
        thread.start()
        logInfo("Receiver \"\(config.name)\" on port \(port): features \(config.featuresText), "
                + "display \(config.displayWidth)x\(config.displayHeight), up to \(maxFPS) fps, "
                + "HEVC \(config.allowHEVC ? "on" : "off"), smooth playback \(smoothPlayback ? "on" : "off"), "
                + "device ID \(identity.deviceID)")
    }

    public func stop() {
        bonjour.stop()
        listener?.close()
        listener = nil
        let open = locked { Array(connections.values) }
        open.forEach { $0.stop() }
    }

    private func acceptConnections(on listener: TCPListener) {
        while !listener.isClosed {
            guard let (fd, peer) = listener.accept(timeoutMs: 500) else { continue }
            let id = locked {
                defer { nextConnectionID += 1 }
                return nextConnectionID
            }
            // Made outside the lock: setting up a connection reads the receiver's settings.
            let connection = AirPlayConnection(id: id, fd: fd, peer: peer, receiver: self)
            locked { connections[id] = connection }
            connection.start()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - /info

    func infoDictionary(full: Bool) -> [String: Any] {
        var info: [String: Any] = [
            "deviceID": identity.deviceID,
            "macAddress": identity.deviceID,
            "pk": identity.publicKey,
            "features": NSNumber(value: config.features),
            "name": config.name,
            "pi": identity.pairingIdentifier,
            "vv": 2,
            "statusFlags": 68,  // 0x4: audio output connected
            "keepAliveLowPower": true,
            "sourceVersion": ReceiverConfig.sourceVersion,
            "keepAliveSendStatsAsBody": true,
            "model": ReceiverConfig.model,
        ]
        guard full else { return info }

        info["initialVolume"] = 0.0
        info["audioLatencies"] = [100, 101].map { type -> [String: Any] in
            ["type": type, "audioType": "default", "inputLatencyMicros": 0, "outputLatencyMicros": false]
        }
        info["audioFormats"] = [100, 101].map { type -> [String: Any] in
            ["type": type, "audioInputFormats": 0x3ff_fffc, "audioOutputFormats": 0x3ff_fffc]
        }
        let fps = maxFPS
        info["displays"] = [[
            "uuid": identity.displayIdentifier,
            "widthPhysical": 0,
            "heightPhysical": 0,
            "width": config.displayWidth,
            "height": config.displayHeight,
            "widthPixels": config.displayWidth,
            "heightPixels": config.displayHeight,
            "rotation": false,
            "refreshRate": 1.0 / Double(fps),
            "maxFPS": fps,
            "overscanned": false,
            "features": 14,
        ] as [String: Any]]
        return info
    }

    // MARK: - Audio bookkeeping

    func audioDidStart(_ sink: AudioSink, connectionID: Int) {
        let muted = locked {
            audioSinks[connectionID] = sink
            return audioMuted
        }
        sink.isMuted = muted
    }

    func audioDidStop(connectionID: Int) {
        locked { audioSinks[connectionID] = nil }
    }

    func setAudioGain(_ gain: Float, connectionID: Int) {
        locked { audioSinks[connectionID] }?.gain = gain
    }

    // MARK: - Session bookkeeping

    func connectionDidClose(_ connection: AirPlayConnection) {
        locked { connections[connection.id] = nil }
        endMirroring(connection.id)
    }

    func mirrorDidStart(on connection: AirPlayConnection) {
        let previous = locked {
            let previousID = mirroringConnectionID
            mirroringConnectionID = connection.id
            return previousID.flatMap { $0 == connection.id ? nil : connections[$0] }
        }
        previous?.stopMirroring(reason: "another device started mirroring")
        delegate?.receiver(self, didStartMirroringFrom: connection.clientName)
    }

    private func isMirroring(_ connectionID: Int) -> Bool {
        locked { mirroringConnectionID == connectionID }
    }

    private func endMirroring(_ connectionID: Int) {
        let ended = locked {
            guard mirroringConnectionID == connectionID else { return false }
            mirroringConnectionID = nil
            return true
        }
        if ended { delegate?.receiverDidStopMirroring(self) }
    }

    // MARK: - MirrorStreamEvents

    func mirrorStream(_ connectionID: Int, didChangeFormat format: VideoStreamFormat) {
        guard isMirroring(connectionID) else { return }
        delegate?.receiver(self, didChangeVideoFormat: format)
    }

    func mirrorStream(_ connectionID: Int, didReceive frame: VideoFrame) {
        guard isMirroring(connectionID) else { return }
        delegate?.receiver(self, didReceive: frame)
    }

    func mirrorStream(_ connectionID: Int, didPause paused: Bool) {
        guard isMirroring(connectionID) else { return }
        delegate?.receiver(self, didPauseVideo: paused)
    }

    func mirrorStreamDidEnd(_ connectionID: Int) {
        endMirroring(connectionID)
    }
}
