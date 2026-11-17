import CryptoKit
import Foundation

/// AirPlay "legacy" pairing: /pair-setup followed by the two /pair-verify steps.
///
/// The X25519 secret agreed here is later mixed into the stream encryption key.
final class PairingSession {
    enum State { case initial, setup, verifying, verified }

    private(set) var state: State = .initial
    private let identity: Curve25519.Signing.PrivateKey
    private var ourAgreementKey: Curve25519.KeyAgreement.PrivateKey?
    private var theirAgreementKey = Data()
    private var theirSigningKey: Curve25519.Signing.PublicKey?
    private(set) var sharedSecret: Data?

    init(identity: Curve25519.Signing.PrivateKey) {
        self.identity = identity
    }

    /// POST /pair-setup: the client sends its 32-byte Ed25519 public key and gets ours back.
    func handlePairSetup(_ body: Data) throws -> Data {
        guard body.count == 32 else {
            throw AirPlayError.badRequest("pair-setup body should be 32 bytes, got \(body.count)")
        }
        if state == .initial { state = .setup }  // never forget a secret already agreed
        return identity.publicKey.rawRepresentation
    }

    /// POST /pair-verify, first step: [flags][client X25519 key][client Ed25519 key] (4 + 32 + 32 bytes).
    /// Answers with our X25519 key and our signature over both X25519 keys, AES-CTR encrypted.
    ///
    /// Phones skip /pair-setup when reconnecting: they already have our public key from the Bonjour
    /// record, and pair-setup only exchanges public keys, so verifying straight away is fine.
    func handlePairVerifyStart(_ body: Data) throws -> Data {
        guard body.count == 68 else {
            throw AirPlayError.badRequest("pair-verify (step 1) body should be 68 bytes, got \(body.count)")
        }
        theirAgreementKey = body.bytes(at: 4, count: 32)
        theirSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: body.bytes(at: 36, count: 32))

        let ours = Curve25519.KeyAgreement.PrivateKey()
        ourAgreementKey = ours
        let secret = try ours.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirAgreementKey))
        sharedSecret = secret.withUnsafeBytes { Data($0) }
        state = .verifying

        let ourPublic = ours.publicKey.rawRepresentation
        let signature = try identity.signature(for: ourPublic + theirAgreementKey)
        return ourPublic + makeCipher().processed(signature)
    }

    /// POST /pair-verify, second step: [flags][client signature], encrypted with the same keystream
    /// continued past the 64 bytes we used. Returns whether the client's signature checks out.
    func handlePairVerifyFinish(_ body: Data) throws -> Bool {
        guard state == .verifying, let ours = ourAgreementKey, let theirs = theirSigningKey else {
            throw AirPlayError.badRequest("pair-verify (step 2) without step 1")
        }
        guard body.count == 68 else {
            throw AirPlayError.badRequest("pair-verify (step 2) body should be 68 bytes, got \(body.count)")
        }
        let cipher = makeCipher()
        _ = cipher.processed(Data(count: 64))
        let signature = cipher.processed(body.bytes(at: 4, count: 64))
        let valid = theirs.isValidSignature(signature, for: theirAgreementKey + ours.publicKey.rawRepresentation)
        if valid { state = .verified }
        return valid
    }

    /// Present once the client has paired; the session key must then be hashed with it.
    var secretForKeyDerivation: Data? {
        switch state {
        case .initial: return nil
        case .setup: return Data(count: 32)  // pair-setup without pair-verify, as UxPlay handles it
        case .verifying, .verified: return sharedSecret
        }
    }

    private func makeCipher() -> AESCTR {
        let secret = sharedSecret ?? Data(count: 32)
        let key = sha512(Data("Pair-Verify-AES-Key".utf8), secret).prefix(16)
        let iv = sha512(Data("Pair-Verify-AES-IV".utf8), secret).prefix(16)
        return AESCTR(key: Data(key), iv: Data(iv))
    }
}
