import Foundation

/// What the receiver advertises to the phone.
public struct ReceiverConfig: Sendable {
    /// The name shown in the iPhone's Screen Mirroring list.
    public var name = "Porthole"

    /// The display we claim to have. The phone scales its screen to the largest size that fits
    /// inside it, keeping its shape, and scales up when the box is bigger than its screen. A
    /// square as tall as the phone's screen gets its exact pixels both ways up. A 3840x2160 box
    /// got 994x2160 upright (75% of an iPhone 17 Pro Max's 1320x2868) and an upscaled 3840x1768
    /// on its side.
    public var displayWidth = 2868
    public var displayHeight = 2868

    /// The most frames per second the phone may send; also the display's refresh rate.
    public var maxFPS = 60

    /// Feature bit 42 ("screen multi-codec"): lets the phone send HEVC, which it does for
    /// resolutions above 1080p.
    public var allowHEVC = true

    /// Feature bit 27: the phone runs /pair-setup and /pair-verify before streaming.
    public var legacyPairing = true

    public init() {}

    static let model = "AppleTV3,2"
    static let sourceVersion = "220.68"
    /// UxPlay's default set: mirroring, audio, FairPlay, metadata.
    static let baseFeatures: UInt64 = 0x5A7F_FEE6

    public var features: UInt64 {
        var features = Self.baseFeatures
        if !legacyPairing { features &= ~(1 << 27) }
        if allowHEVC { features |= 1 << 42 }
        return features
    }

    /// The features in the Bonjour record, as "0xLOW,0xHIGH".
    public var featuresText: String {
        String(format: "0x%X,0x%X", UInt32(features & 0xffff_ffff), UInt32(features >> 32))
    }

    func airplayTXT(identity: ReceiverIdentity) -> Data {
        TXTRecord.encode([
            ("deviceid", identity.deviceID),
            ("features", featuresText),
            ("pw", "false"),
            ("flags", "0x4"),
            ("model", Self.model),
            ("pk", identity.publicKeyHex),
            ("pi", identity.pairingIdentifier),
            ("srcvers", Self.sourceVersion),
            ("vv", "2"),
        ])
    }

    func raopTXT(identity: ReceiverIdentity) -> Data {
        TXTRecord.encode([
            ("ch", "2"),
            ("cn", "0,1,2,3"),
            ("da", "true"),
            ("et", "0,3,5"),
            ("vv", "2"),
            ("ft", featuresText),
            ("am", Self.model),
            ("md", "0,1,2"),
            ("rhd", "5.6.0.0"),
            ("pw", "false"),
            ("sf", "0x4"),
            ("sr", "44100"),
            ("ss", "16"),
            ("sv", "false"),
            ("tp", "UDP"),
            ("txtvers", "1"),
            ("vs", Self.sourceVersion),
            ("vn", "65537"),
            ("pk", identity.publicKeyHex),
        ])
    }
}

enum TXTRecord {
    /// DNS TXT wire format: each "key=value" string prefixed with its length.
    static func encode(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8)
            precondition(entry.count < 256, "TXT entry too long: \(key)")
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }
}
