import CommonCrypto
import CryptoKit
import Foundation

/// SHA-512 over the concatenation of `parts`.
func sha512(_ parts: Data...) -> Data {
    var hasher = SHA512()
    for part in parts { hasher.update(data: part) }
    return Data(hasher.finalize())
}

/// AES-128-CBC over the whole 16-byte blocks of `data`, restarting from `iv` each call; any
/// trailing partial block is passed through untouched. This is how each audio packet is encrypted.
func aesCBC(_ operation: CCOperation, blocksOf data: Data, key: Data, iv: Data) -> Data {
    let blockBytes = data.count / 16 * 16
    var output = Data(data)
    guard blockBytes > 0 else { return output }
    var moved = 0
    let status = output.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress, input.baseAddress, blockBytes, out.baseAddress, blockBytes, &moved)
                }
            }
        }
    }
    precondition(status == kCCSuccess, "AES-CBC failed with \(status)")
    return output
}

/// AES-128 in counter mode as one continuous keystream.
///
/// Data can be fed in chunks of any size and the keystream carries on where the previous chunk
/// stopped, including mid-block. The mirror video stream depends on this: each packet's payload
/// continues the keystream of the packet before it.
public final class AESCTR {
    private var cryptor: CCCryptorRef?
    private var counter = [UInt8](repeating: 0, count: 16)
    private var leftover = [UInt8](repeating: 0, count: 16)
    private var leftoverStart = 16  // index of the first unused byte in `leftover`
    private var counterBlocks = [UInt8]()
    private var keystream = [UInt8]()

    public init(key: Data, iv: Data) {
        precondition(key.count == 16 && iv.count == 16, "AES-128 key and IV must be 16 bytes")
        counter = [UInt8](iv)
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, kCCKeySizeAES128, nil, &ref)
        }
        precondition(status == kCCSuccess, "CCCryptorCreate failed with \(status)")
        cryptor = ref
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    /// XORs `buffer` in place with the next `buffer.count` keystream bytes.
    public func xor(_ buffer: UnsafeMutableRawBufferPointer) {
        let count = buffer.count
        guard count > 0, let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

        var offset = 0
        while leftoverStart < 16 && offset < count {
            base[offset] ^= leftover[leftoverStart]
            leftoverStart += 1
            offset += 1
        }
        let remaining = count - offset
        guard remaining > 0 else { return }

        let blocks = (remaining + 15) / 16
        let byteCount = blocks * 16
        if counterBlocks.count < byteCount {
            counterBlocks = [UInt8](repeating: 0, count: byteCount)
            keystream = [UInt8](repeating: 0, count: byteCount)
        }
        var block = counter
        counterBlocks.withUnsafeMutableBufferPointer { blocksOut in
            for index in 0..<blocks {
                for byteIndex in 0..<16 { blocksOut[index * 16 + byteIndex] = block[byteIndex] }
                Self.increment(&block)
            }
        }
        counter = block

        var produced = 0
        let status = CCCryptorUpdate(cryptor, counterBlocks, byteCount, &keystream, byteCount, &produced)
        precondition(status == kCCSuccess && produced == byteCount, "AES keystream generation failed with \(status)")

        keystream.withUnsafeBufferPointer { stream in
            for index in 0..<remaining { base[offset + index] ^= stream[index] }
        }

        let usedInLastBlock = remaining - (blocks - 1) * 16
        if usedInLastBlock < 16 {
            for index in 0..<16 { leftover[index] = keystream[(blocks - 1) * 16 + index] }
            leftoverStart = usedInLastBlock
        } else {
            leftoverStart = 16
        }
    }

    public func process(_ data: inout Data) {
        data.withUnsafeMutableBytes { xor($0) }
    }

    public func processed(_ data: Data) -> Data {
        var copy = Data(data)
        process(&copy)
        return copy
    }

    /// Big-endian increment of the full 128-bit counter, as OpenSSL's CTR mode does.
    private static func increment(_ block: inout [UInt8]) {
        var index = 15
        while index >= 0 {
            block[index] &+= 1
            if block[index] != 0 { return }
            index -= 1
        }
    }
}
