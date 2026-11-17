import CommonCrypto
import CryptoKit
import XCTest
@testable import PortholeCore

final class CryptoTests: XCTestCase {
    private func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// NIST SP 800-38A, F.5.1 (CTR-AES128.Encrypt).
    func testAESCTRMatchesNISTVector() {
        let cipher = AESCTR(key: hex("2b7e151628aed2a6abf7158809cf4f3c"), iv: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"))
        let plain = hex("6bc1bee22e409f96e93d7e117393172a" + "ae2d8a571e03ac9c9eb76fac45af8e51"
                        + "30c81c46a35ce411e5fbc1191a0a52ef" + "f69f2445df4f9b17ad2b417be66c3710")
        let expected = hex("874d6191b620e3261bef6864990db6ce" + "9806f66b7970fdff8617187bb9fffdff"
                           + "5ae4df3edbd5d35e5b4f09020db03eab" + "1e031dda2fbe03d1792170a0f3009cee")
        XCTAssertEqual(cipher.processed(plain), expected)
    }

    /// The keystream must carry over between calls, including mid-block, like the phone's.
    func testAESCTRChunkingDoesNotChangeOutput() {
        let key = randomData(16), iv = randomData(16), plain = randomData(5000)
        let whole = AESCTR(key: key, iv: iv).processed(plain)

        let chunked = AESCTR(key: key, iv: iv)
        var output = Data()
        var offset = 0
        for size in [1, 15, 16, 17, 3, 100, 0, 31, 1000, 7] + Array(repeating: 250, count: 20) where offset < plain.count {
            let end = min(offset + size, plain.count)
            output += chunked.processed(plain[offset..<end])
            offset = end
        }
        output += chunked.processed(plain[offset...])
        XCTAssertEqual(output, whole)
    }

    /// The counter is a full 128-bit big-endian number (carry crosses into the high 64 bits).
    func testAESCTRCounterCarriesAcrossAll128Bits() throws {
        let key = randomData(16)
        let iv = hex("0000000000000000ffffffffffffffff")
        let keystream = AESCTR(key: key, iv: iv).processed(Data(count: 32))
        let secondCounter = hex("00000000000000010000000000000000")
        XCTAssertEqual(keystream.suffix(16), try ecbEncrypt(key: key, block: secondCounter))
    }

    private func ecbEncrypt(key: Data, block: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            block.withUnsafeBytes { input in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, 16, nil, input.baseAddress, 16, &output, 16, &moved)
            }
        }
        guard status == kCCSuccess else { throw TestError.failed("CCCrypt \(status)") }
        return Data(output)
    }

    func testPairingRoundTrip() throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let session = PairingSession(identity: serverKey)
        let clientSigning = Curve25519.Signing.PrivateKey()
        let clientAgreement = Curve25519.KeyAgreement.PrivateKey()

        XCTAssertEqual(try session.handlePairSetup(clientSigning.publicKey.rawRepresentation), serverKey.publicKey.rawRepresentation)
        let reply = try session.handlePairVerifyStart(Data([1, 0, 0, 0]) + clientAgreement.publicKey.rawRepresentation
                                                      + clientSigning.publicKey.rawRepresentation)
        XCTAssertEqual(reply.count, 96)

        let serverAgreement = reply.prefix(32)
        let secret = try clientAgreement.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: serverAgreement))
            .withUnsafeBytes { Data($0) }
        XCTAssertEqual(session.sharedSecret, secret)

        let cipher = AESCTR(key: Data(sha512(Data("Pair-Verify-AES-Key".utf8), secret).prefix(16)),
                            iv: Data(sha512(Data("Pair-Verify-AES-IV".utf8), secret).prefix(16)))
        let serverSignature = cipher.processed(reply.suffix(64))
        XCTAssertTrue(serverKey.publicKey.isValidSignature(serverSignature, for: serverAgreement + clientAgreement.publicKey.rawRepresentation))

        let clientSignature = try clientSigning.signature(for: clientAgreement.publicKey.rawRepresentation + serverAgreement)
        XCTAssertTrue(try session.handlePairVerifyFinish(Data([0, 0, 0, 0]) + cipher.processed(clientSignature)))
        XCTAssertEqual(session.state, .verified)
    }

    func testPairingRejectsForgedSignature() throws {
        let session = PairingSession(identity: Curve25519.Signing.PrivateKey())
        let clientSigning = Curve25519.Signing.PrivateKey()
        let clientAgreement = Curve25519.KeyAgreement.PrivateKey()
        _ = try session.handlePairSetup(clientSigning.publicKey.rawRepresentation)
        _ = try session.handlePairVerifyStart(Data([1, 0, 0, 0]) + clientAgreement.publicKey.rawRepresentation
                                              + clientSigning.publicKey.rawRepresentation)
        XCTAssertFalse(try session.handlePairVerifyFinish(Data([0, 0, 0, 0]) + randomData(64)))
    }

    /// Reconnecting phones go straight to pair-verify, using the key from the Bonjour record.
    func testPairVerifyWithoutSetup() throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let session = PairingSession(identity: serverKey)
        XCTAssertNil(session.secretForKeyDerivation, "no pairing yet")

        let clientSigning = Curve25519.Signing.PrivateKey()
        let clientAgreement = Curve25519.KeyAgreement.PrivateKey()
        let reply = try session.handlePairVerifyStart(Data([1, 0, 0, 0]) + clientAgreement.publicKey.rawRepresentation
                                                      + clientSigning.publicKey.rawRepresentation)
        let serverAgreement = reply.prefix(32)
        let secret = try clientAgreement.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: serverAgreement))
            .withUnsafeBytes { Data($0) }
        let cipher = AESCTR(key: Data(sha512(Data("Pair-Verify-AES-Key".utf8), secret).prefix(16)),
                            iv: Data(sha512(Data("Pair-Verify-AES-IV".utf8), secret).prefix(16)))
        XCTAssertTrue(serverKey.publicKey.isValidSignature(cipher.processed(reply.suffix(64)),
                                                           for: serverAgreement + clientAgreement.publicKey.rawRepresentation))
        let signature = try clientSigning.signature(for: clientAgreement.publicKey.rawRepresentation + serverAgreement)
        XCTAssertTrue(try session.handlePairVerifyFinish(Data([0, 0, 0, 0]) + cipher.processed(signature)))
        XCTAssertEqual(session.secretForKeyDerivation, secret)
    }

    func testPairVerifyFinishBeforeStartIsRejected() {
        let session = PairingSession(identity: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try session.handlePairVerifyFinish(Data(count: 68)))
    }
}
