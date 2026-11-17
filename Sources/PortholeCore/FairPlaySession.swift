import CFairPlay
import Foundation

/// The FairPlay part of the handshake (POST /fp-setup, twice) and the session-key decryption
/// that depends on it. All the real work is in the vendored C code.
struct FairPlaySession {
    /// The 164-byte second fp-setup request. FairPlay needs it to decrypt the session key.
    private(set) var keyMessage: Data?

    mutating func handleSetup(_ body: Data) throws -> Data {
        switch body.count {
        case 16:
            var reply = [UInt8](repeating: 0, count: 142)
            let result = body.withUnsafeBytes { request in
                fairplay_reply_setup(request.bindMemory(to: UInt8.self).baseAddress, 16, &reply)
            }
            guard result == 0 else {
                throw AirPlayError.unsupported("FairPlay setup (version \(body.byte(4)), mode \(body.byte(14))); only version 3 is known")
            }
            keyMessage = nil
            return Data(reply)
        case 164:
            var reply = [UInt8](repeating: 0, count: 32)
            let result = body.withUnsafeBytes { request in
                fairplay_reply_handshake(request.bindMemory(to: UInt8.self).baseAddress, 164, &reply)
            }
            guard result == 0 else {
                throw AirPlayError.unsupported("FairPlay handshake (version \(body.byte(4)), mode \(body.byte(12)))")
            }
            keyMessage = Data(body)
            return Data(reply)
        default:
            throw AirPlayError.badRequest("fp-setup body of \(body.count) bytes")
        }
    }

    /// Decrypts the 72-byte `ekey` from the first SETUP into the 16-byte AES session key.
    func decryptKey(_ ekey: Data) throws -> Data {
        guard let keyMessage else { throw AirPlayError.crypto("SETUP arrived before the FairPlay handshake finished") }
        guard ekey.count == 72 else { throw AirPlayError.badRequest("ekey should be 72 bytes, got \(ekey.count)") }
        var key = [UInt8](repeating: 0, count: 16)
        let result = keyMessage.withUnsafeBytes { message in
            ekey.withUnsafeBytes { cipher in
                fairplay_decrypt_key(message.bindMemory(to: UInt8.self).baseAddress,
                                     cipher.bindMemory(to: UInt8.self).baseAddress, &key)
            }
        }
        guard result == 0 else { throw AirPlayError.crypto("FairPlay could not decrypt the session key") }
        return Data(key)
    }
}
