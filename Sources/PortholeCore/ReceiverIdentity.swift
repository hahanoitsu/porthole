import CryptoKit
import Foundation

/// Who the receiver is to an iPhone: a signing key, a device ID shaped like a MAC address and two
/// UUIDs. Kept on disk so the phone sees the same receiver every launch.
public struct ReceiverIdentity {
    public let signingKey: Curve25519.Signing.PrivateKey
    /// Six random bytes, marked "locally administered" so they can't collide with real hardware,
    /// including this Mac's own AirPlay receiver.
    public let hardwareAddress: [UInt8]
    public let pairingIdentifier: String
    public let displayIdentifier: String

    public var publicKey: Data { signingKey.publicKey.rawRepresentation }
    public var publicKeyHex: String { publicKey.hexString }

    /// "aa:bb:cc:dd:ee:ff", as used in the _airplay._tcp record and /info.
    public var deviceID: String { hardwareAddress.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// "AABBCCDDEEFF", the prefix of the _raop._tcp service name.
    public var raopPrefix: String { hardwareAddress.map { String(format: "%02X", $0) }.joined() }

    public static func generate() -> ReceiverIdentity {
        var address = (0..<6).map { _ in UInt8.random(in: 0...255) }
        address[0] = (address[0] & 0xfc) | 0x02  // unicast, locally administered
        return ReceiverIdentity(signingKey: Curve25519.Signing.PrivateKey(),
                                hardwareAddress: address,
                                pairingIdentifier: UUID().uuidString.lowercased(),
                                displayIdentifier: UUID().uuidString.lowercased())
    }

    public static func loadOrCreate(at url: URL) throws -> ReceiverIdentity {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let identity = stored.identity {
            return identity
        }
        let identity = generate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(identity))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        logInfo("Created a new receiver identity at \(url.path)")
        return identity
    }

    private struct Stored: Codable {
        var signingKey: Data
        var hardwareAddress: [UInt8]
        var pairingIdentifier: String
        var displayIdentifier: String

        init(_ identity: ReceiverIdentity) {
            signingKey = identity.signingKey.rawRepresentation
            hardwareAddress = identity.hardwareAddress
            pairingIdentifier = identity.pairingIdentifier
            displayIdentifier = identity.displayIdentifier
        }

        var identity: ReceiverIdentity? {
            guard hardwareAddress.count == 6,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey) else { return nil }
            return ReceiverIdentity(signingKey: key, hardwareAddress: hardwareAddress,
                                    pairingIdentifier: pairingIdentifier, displayIdentifier: displayIdentifier)
        }
    }
}
