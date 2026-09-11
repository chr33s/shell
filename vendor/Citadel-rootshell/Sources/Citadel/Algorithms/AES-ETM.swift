import CCryptoBoringSSL
import Foundation
import Crypto
import NIOCore
import NIOSSH

// MARK: - AES128-CTR with Encrypt-Then-MAC

public final class AES128CTR_ETM: NIOSSHTransportProtection {
    private enum Mac {
        case sha256, sha512
    }

    public static let macNames = [
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512-etm@openssh.com"
    ]
    public static let cipherBlockSize = 16
    public static let cipherName = "aes128-ctr"
    public var macBytes: Int {
        keySizes.macKeySize
    }

    public static func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        let macKeySize: Int

        switch mac {
        case "hmac-sha2-256-etm@openssh.com":
            macKeySize = SHA256.byteCount
        case "hmac-sha2-512-etm@openssh.com":
            macKeySize = SHA512.byteCount
        default:
            throw CitadelError.invalidMac
        }

        return ExpectedKeySizes(
            ivSize: 16,
            encryptionKeySize: 16, // 128 bits
            macKeySize: macKeySize
        )
    }

    private var keys: NIOSSHSessionKeys
    private var decryptionContext: UnsafeMutablePointer<EVP_CIPHER_CTX>
    private var encryptionContext: UnsafeMutablePointer<EVP_CIPHER_CTX>
    private let mac: Mac
    private let keySizes: ExpectedKeySizes

    public init(initialKeys: NIOSSHSessionKeys, mac: String?) throws {
        let keySizes = try Self.keySizes(forMac: mac)

        guard
            initialKeys.outboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8,
            initialKeys.inboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8
        else {
            throw CitadelError.invalidKeySize
        }

        switch mac {
        case "hmac-sha2-256-etm@openssh.com":
            self.mac = .sha256
        case "hmac-sha2-512-etm@openssh.com":
            self.mac = .sha512
        default:
            throw CitadelError.invalidMac
        }

        self.keys = initialKeys
        self.keySizes = keySizes
        self.encryptionContext = CCryptoBoringSSL_EVP_CIPHER_CTX_new()
        self.decryptionContext = CCryptoBoringSSL_EVP_CIPHER_CTX_new()

        let outboundEncryptionKey = initialKeys.outboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        let inboundEncryptionKey = initialKeys.inboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            encryptionContext,
            CCryptoBoringSSL_EVP_aes_128_ctr(),
            outboundEncryptionKey,
            initialKeys.initialOutboundIV,
            1
        ) == 1 else {
            throw CitadelError.cryptographicError
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            decryptionContext,
            CCryptoBoringSSL_EVP_aes_128_ctr(),
            inboundEncryptionKey,
            initialKeys.initialInboundIV,
            0
        ) == 1 else {
            throw CitadelError.cryptographicError
        }
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        guard
            newKeys.outboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8,
            newKeys.inboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8
        else {
            throw CitadelError.invalidKeySize
        }

        self.keys = newKeys

        let outboundEncryptionKey = newKeys.outboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        let inboundEncryptionKey = newKeys.inboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            encryptionContext,
            CCryptoBoringSSL_EVP_aes_128_ctr(),
            outboundEncryptionKey,
            newKeys.initialOutboundIV,
            1
        ) == 1 else {
            throw CitadelError.cryptographicError
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            decryptionContext,
            CCryptoBoringSSL_EVP_aes_128_ctr(),
            inboundEncryptionKey,
            newKeys.initialInboundIV,
            0
        ) == 1 else {
            throw CitadelError.cryptographicError
        }
    }

    // ETM: length field is plaintext, no decryption needed.
    // Do NOT consume AES-CTR keystream here.
    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        guard source.readableBytes >= Self.cipherBlockSize else {
            throw CitadelError.invalidKeySize
        }
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        switch mac {
        case .sha256:
            return try _decryptAndVerifyRemainingPacket(&source, hash: SHA256.self, sequenceNumber: sequenceNumber)
        case .sha512:
            return try _decryptAndVerifyRemainingPacket(&source, hash: SHA512.self, sequenceNumber: sequenceNumber)
        }
    }

    internal func _decryptAndVerifyRemainingPacket<H: HashFunction>(_ source: inout ByteBuffer, hash: H.Type, sequenceNumber: UInt32) throws -> ByteBuffer {
        // ETM wire format: [4-byte plaintext length] [ciphertext] [MAC]
        // MAC covers: seq_number || length_bytes || ciphertext
        guard
            let lengthBytes = source.readBytes(length: 4)
        else {
            throw CitadelError.invalidEncryptedPacketLength
        }

        let ciphertextLength = source.readableBytes - keySizes.macKeySize
        guard
            ciphertextLength > 0,
            let ciphertext = source.readBytes(length: ciphertextLength),
            let macHash = source.readBytes(length: keySizes.macKeySize)
        else {
            throw CitadelError.invalidEncryptedPacketLength
        }

        // Verify MAC FIRST (Encrypt-then-MAC: verify before decryption)
        var hmac = Crypto.HMAC<H>(key: keys.inboundMACKey)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { hmac.update(data: $0) }
        hmac.update(data: lengthBytes)
        hmac.update(data: ciphertext)

        let isValid = hmac.finalize().withUnsafeBytes { buffer -> Bool in
            Array(buffer.bindMemory(to: UInt8.self)) == macHash
        }

        guard isValid else {
            throw CitadelError.invalidMac
        }

        // Decrypt ciphertext. AES-CTR is a stream cipher; handles non-block-aligned sizes.
        let plaintext = try ciphertext.withUnsafeBufferPointer { ciphertextBuf -> [UInt8] in
            try [UInt8](unsafeUninitializedCapacity: ciphertextBuf.count) { plaintextBuf, count in
                guard CCryptoBoringSSL_EVP_Cipher(
                    decryptionContext,
                    plaintextBuf.baseAddress!,
                    ciphertextBuf.baseAddress!,
                    ciphertextBuf.count
                ) == 1 else {
                    throw CitadelError.cryptographicError
                }
                count = ciphertextBuf.count
            }
        }

        // Parse: padding_length(1) || payload || padding
        guard !plaintext.isEmpty else {
            throw CitadelError.invalidDecryptedPlaintextLength
        }

        let paddingLength = Int(plaintext[0])

        guard paddingLength + 1 <= plaintext.count else {
            throw CitadelError.invalidDecryptedPlaintextLength
        }

        let payloadEnd = plaintext.count - paddingLength
        let payload = Array(plaintext[1..<payloadEnd])

        return ByteBuffer(bytes: payload)
    }

    public func encryptPacket(
        _ packet: NIOSSHEncryptablePayload,
        to outboundBuffer: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws {
        switch mac {
        case .sha256:
            try _encryptPacket(packet, to: &outboundBuffer, hashFunction: SHA256.self, sequenceNumber: sequenceNumber)
        case .sha512:
            try _encryptPacket(packet, to: &outboundBuffer, hashFunction: SHA512.self, sequenceNumber: sequenceNumber)
        }
    }

    internal func _encryptPacket<H: HashFunction>(
        _ packet: NIOSSHEncryptablePayload,
        to outboundBuffer: inout ByteBuffer,
        hashFunction: H.Type,
        sequenceNumber: UInt32
    ) throws {
        // ETM format: [4-byte plaintext length] [encrypted(padding_len || payload || padding)] [MAC]
        let packetLengthIndex = outboundBuffer.writerIndex
        let packetLengthLength = MemoryLayout<UInt32>.size
        let packetPaddingLength = MemoryLayout<UInt8>.size

        // Placeholders for packet_length + padding_length, overwritten below via
        // setInteger. moveWriterIndex(forwardBy:) does not grow the buffer and traps
        // at a capacity boundary, which this buffer hits as it accumulates packets.
        outboundBuffer.writeMultipleIntegers(UInt32(0), UInt8(0))

        let payloadBytes = outboundBuffer.writeEncryptablePayload(packet)

        // ETM aligns only the encrypted body. The four-byte packet length
        // stays cleartext and is excluded from the block-size calculation.
        let contentWithoutPadding = packetPaddingLength + payloadBytes
        var paddingLength = Self.cipherBlockSize - (contentWithoutPadding % Self.cipherBlockSize)
        if paddingLength < 4 {
            paddingLength += Self.cipherBlockSize
        }

        outboundBuffer.writeSSHPaddingBytes(count: paddingLength)

        // packet_length = padding_length_byte + payload + padding
        let packetLength = packetPaddingLength + payloadBytes + paddingLength
        precondition(packetLength % Self.cipherBlockSize == 0,
                     "ETM encrypted body not block-aligned; got \(packetLength)")

        outboundBuffer.setInteger(UInt32(packetLength), at: packetLengthIndex)
        outboundBuffer.setInteger(UInt8(paddingLength), at: packetLengthIndex + packetLengthLength)

        // Get content to encrypt: padding_length || payload || padding (NOT the length field)
        let plaintextContent = outboundBuffer.getBytes(at: packetLengthIndex + packetLengthLength, length: packetLength)!

        // Encrypt with AES-CTR (single call, handles non-block-aligned sizes)
        let ciphertext = try plaintextContent.withUnsafeBufferPointer { plaintextBuf -> [UInt8] in
            try [UInt8](unsafeUninitializedCapacity: plaintextBuf.count) { ciphertextBuf, count in
                guard CCryptoBoringSSL_EVP_Cipher(
                    encryptionContext,
                    ciphertextBuf.baseAddress!,
                    plaintextBuf.baseAddress!,
                    plaintextBuf.count
                ) == 1 else {
                    throw CitadelError.cryptographicError
                }
                count = plaintextBuf.count
            }
        }

        // Write ciphertext over the plaintext portion (after the 4-byte length)
        outboundBuffer.setBytes(ciphertext, at: packetLengthIndex + packetLengthLength)

        // Compute MAC over: seq_number || plaintext_length || ciphertext
        var hmac = Crypto.HMAC<H>(key: keys.outboundMACKey)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { hmac.update(data: $0) }
        let lengthBytes = outboundBuffer.getBytes(at: packetLengthIndex, length: packetLengthLength)!
        hmac.update(data: lengthBytes)
        hmac.update(data: ciphertext)
        let macHash = hmac.finalize()

        outboundBuffer.writeContiguousBytes(macHash)
    }

    deinit {
        CCryptoBoringSSL_EVP_CIPHER_CTX_free(encryptionContext)
        CCryptoBoringSSL_EVP_CIPHER_CTX_free(decryptionContext)
    }
}

// MARK: - AES256-CTR with Encrypt-Then-MAC

public final class AES256CTR_ETM: NIOSSHTransportProtection {
    private enum Mac {
        case sha256, sha512
    }

    public static let macNames = [
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512-etm@openssh.com"
    ]
    public static let cipherBlockSize = 16
    public static let cipherName = "aes256-ctr"
    public var macBytes: Int {
        keySizes.macKeySize
    }

    public static func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        let macKeySize: Int

        switch mac {
        case "hmac-sha2-256-etm@openssh.com":
            macKeySize = SHA256.byteCount
        case "hmac-sha2-512-etm@openssh.com":
            macKeySize = SHA512.byteCount
        default:
            throw CitadelError.invalidMac
        }

        return ExpectedKeySizes(
            ivSize: 16,
            encryptionKeySize: 32, // 256 bits
            macKeySize: macKeySize
        )
    }

    private var keys: NIOSSHSessionKeys
    private var decryptionContext: UnsafeMutablePointer<EVP_CIPHER_CTX>
    private var encryptionContext: UnsafeMutablePointer<EVP_CIPHER_CTX>
    private let mac: Mac
    private let keySizes: ExpectedKeySizes

    public init(initialKeys: NIOSSHSessionKeys, mac: String?) throws {
        let keySizes = try Self.keySizes(forMac: mac)

        guard
            initialKeys.outboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8,
            initialKeys.inboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8
        else {
            throw CitadelError.invalidKeySize
        }

        switch mac {
        case "hmac-sha2-256-etm@openssh.com":
            self.mac = .sha256
        case "hmac-sha2-512-etm@openssh.com":
            self.mac = .sha512
        default:
            throw CitadelError.invalidMac
        }

        self.keys = initialKeys
        self.keySizes = keySizes
        self.encryptionContext = CCryptoBoringSSL_EVP_CIPHER_CTX_new()
        self.decryptionContext = CCryptoBoringSSL_EVP_CIPHER_CTX_new()

        let outboundEncryptionKey = initialKeys.outboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        let inboundEncryptionKey = initialKeys.inboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            encryptionContext,
            CCryptoBoringSSL_EVP_aes_256_ctr(),
            outboundEncryptionKey,
            initialKeys.initialOutboundIV,
            1
        ) == 1 else {
            throw CitadelError.cryptographicError
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            decryptionContext,
            CCryptoBoringSSL_EVP_aes_256_ctr(),
            inboundEncryptionKey,
            initialKeys.initialInboundIV,
            0
        ) == 1 else {
            throw CitadelError.cryptographicError
        }
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        guard
            newKeys.outboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8,
            newKeys.inboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8
        else {
            throw CitadelError.invalidKeySize
        }

        self.keys = newKeys

        let outboundEncryptionKey = newKeys.outboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        let inboundEncryptionKey = newKeys.inboundEncryptionKey.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.bindMemory(to: UInt8.self))
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            encryptionContext,
            CCryptoBoringSSL_EVP_aes_256_ctr(),
            outboundEncryptionKey,
            newKeys.initialOutboundIV,
            1
        ) == 1 else {
            throw CitadelError.cryptographicError
        }

        guard CCryptoBoringSSL_EVP_CipherInit(
            decryptionContext,
            CCryptoBoringSSL_EVP_aes_256_ctr(),
            inboundEncryptionKey,
            newKeys.initialInboundIV,
            0
        ) == 1 else {
            throw CitadelError.cryptographicError
        }
    }

    // ETM: length field is plaintext, no decryption needed.
    // Do NOT consume AES-CTR keystream here.
    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        guard source.readableBytes >= Self.cipherBlockSize else {
            throw CitadelError.invalidKeySize
        }
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        switch mac {
        case .sha256:
            return try _decryptAndVerifyRemainingPacket(&source, hash: SHA256.self, sequenceNumber: sequenceNumber)
        case .sha512:
            return try _decryptAndVerifyRemainingPacket(&source, hash: SHA512.self, sequenceNumber: sequenceNumber)
        }
    }

    internal func _decryptAndVerifyRemainingPacket<H: HashFunction>(_ source: inout ByteBuffer, hash: H.Type, sequenceNumber: UInt32) throws -> ByteBuffer {
        // ETM wire format: [4-byte plaintext length] [ciphertext] [MAC]
        // MAC covers: seq_number || length_bytes || ciphertext
        guard
            let lengthBytes = source.readBytes(length: 4)
        else {
            throw CitadelError.invalidEncryptedPacketLength
        }

        let ciphertextLength = source.readableBytes - keySizes.macKeySize
        guard
            ciphertextLength > 0,
            let ciphertext = source.readBytes(length: ciphertextLength),
            let macHash = source.readBytes(length: keySizes.macKeySize)
        else {
            throw CitadelError.invalidEncryptedPacketLength
        }

        // Verify MAC FIRST (Encrypt-then-MAC: verify before decryption)
        var hmac = Crypto.HMAC<H>(key: keys.inboundMACKey)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { hmac.update(data: $0) }
        hmac.update(data: lengthBytes)
        hmac.update(data: ciphertext)

        let isValid = hmac.finalize().withUnsafeBytes { buffer -> Bool in
            Array(buffer.bindMemory(to: UInt8.self)) == macHash
        }

        guard isValid else {
            throw CitadelError.invalidMac
        }

        // Decrypt ciphertext. AES-CTR is a stream cipher; handles non-block-aligned sizes.
        let plaintext = try ciphertext.withUnsafeBufferPointer { ciphertextBuf -> [UInt8] in
            try [UInt8](unsafeUninitializedCapacity: ciphertextBuf.count) { plaintextBuf, count in
                guard CCryptoBoringSSL_EVP_Cipher(
                    decryptionContext,
                    plaintextBuf.baseAddress!,
                    ciphertextBuf.baseAddress!,
                    ciphertextBuf.count
                ) == 1 else {
                    throw CitadelError.cryptographicError
                }
                count = ciphertextBuf.count
            }
        }

        // Parse: padding_length(1) || payload || padding
        guard !plaintext.isEmpty else {
            throw CitadelError.invalidDecryptedPlaintextLength
        }

        let paddingLength = Int(plaintext[0])

        guard paddingLength + 1 <= plaintext.count else {
            throw CitadelError.invalidDecryptedPlaintextLength
        }

        let payloadEnd = plaintext.count - paddingLength
        let payload = Array(plaintext[1..<payloadEnd])

        return ByteBuffer(bytes: payload)
    }

    public func encryptPacket(
        _ packet: NIOSSHEncryptablePayload,
        to outboundBuffer: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws {
        switch mac {
        case .sha256:
            try _encryptPacket(packet, to: &outboundBuffer, hashFunction: SHA256.self, sequenceNumber: sequenceNumber)
        case .sha512:
            try _encryptPacket(packet, to: &outboundBuffer, hashFunction: SHA512.self, sequenceNumber: sequenceNumber)
        }
    }

    internal func _encryptPacket<H: HashFunction>(
        _ packet: NIOSSHEncryptablePayload,
        to outboundBuffer: inout ByteBuffer,
        hashFunction: H.Type,
        sequenceNumber: UInt32
    ) throws {
        // ETM format: [4-byte plaintext length] [encrypted(padding_len || payload || padding)] [MAC]
        let packetLengthIndex = outboundBuffer.writerIndex
        let packetLengthLength = MemoryLayout<UInt32>.size
        let packetPaddingLength = MemoryLayout<UInt8>.size

        // Placeholders for packet_length + padding_length, overwritten below via
        // setInteger. moveWriterIndex(forwardBy:) does not grow the buffer and traps
        // at a capacity boundary, which this buffer hits as it accumulates packets.
        outboundBuffer.writeMultipleIntegers(UInt32(0), UInt8(0))

        let payloadBytes = outboundBuffer.writeEncryptablePayload(packet)

        // ETM aligns only the encrypted body. The four-byte packet length
        // stays cleartext and is excluded from the block-size calculation.
        let contentWithoutPadding = packetPaddingLength + payloadBytes
        var paddingLength = Self.cipherBlockSize - (contentWithoutPadding % Self.cipherBlockSize)
        if paddingLength < 4 {
            paddingLength += Self.cipherBlockSize
        }

        outboundBuffer.writeSSHPaddingBytes(count: paddingLength)

        // packet_length = padding_length_byte + payload + padding
        let packetLength = packetPaddingLength + payloadBytes + paddingLength
        precondition(packetLength % Self.cipherBlockSize == 0,
                     "ETM encrypted body not block-aligned; got \(packetLength)")

        outboundBuffer.setInteger(UInt32(packetLength), at: packetLengthIndex)
        outboundBuffer.setInteger(UInt8(paddingLength), at: packetLengthIndex + packetLengthLength)

        // Get content to encrypt: padding_length || payload || padding (NOT the length field)
        let plaintextContent = outboundBuffer.getBytes(at: packetLengthIndex + packetLengthLength, length: packetLength)!

        // Encrypt with AES-CTR (single call, handles non-block-aligned sizes)
        let ciphertext = try plaintextContent.withUnsafeBufferPointer { plaintextBuf -> [UInt8] in
            try [UInt8](unsafeUninitializedCapacity: plaintextBuf.count) { ciphertextBuf, count in
                guard CCryptoBoringSSL_EVP_Cipher(
                    encryptionContext,
                    ciphertextBuf.baseAddress!,
                    plaintextBuf.baseAddress!,
                    plaintextBuf.count
                ) == 1 else {
                    throw CitadelError.cryptographicError
                }
                count = plaintextBuf.count
            }
        }

        // Write ciphertext over the plaintext portion (after the 4-byte length)
        outboundBuffer.setBytes(ciphertext, at: packetLengthIndex + packetLengthLength)

        // Compute MAC over: seq_number || plaintext_length || ciphertext
        var hmac = Crypto.HMAC<H>(key: keys.outboundMACKey)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { hmac.update(data: $0) }
        let lengthBytes = outboundBuffer.getBytes(at: packetLengthIndex, length: packetLengthLength)!
        hmac.update(data: lengthBytes)
        hmac.update(data: ciphertext)
        let macHash = hmac.finalize()

        outboundBuffer.writeContiguousBytes(macHash)
    }

    deinit {
        CCryptoBoringSSL_EVP_CIPHER_CTX_free(encryptionContext)
        CCryptoBoringSSL_EVP_CIPHER_CTX_free(decryptionContext)
    }
}
