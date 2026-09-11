import Foundation
import NIOCore
import NIOSSH
import Crypto
import CSntrup761

/// Post-quantum hybrid key exchange: sntrup761x25519-sha512@openssh.com
///
/// Implements the OpenSSH hybrid PQ wire format:
/// - Client sends: sntrup761 public key (1158 bytes) || X25519 public key (32 bytes)
/// - Server replies: sntrup761 ciphertext (1039 bytes) || X25519 public key (32 bytes)
/// - Combined secret: K = SHA-512(sntrup761_ss || x25519_ss)
/// - Exchange hash: H = SHA-512(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || K)
///   where K is encoded as an SSH string, matching OpenSSH's hybrid KEM format.
///
/// No platform availability restriction — sntrup761 is pure C.
public struct Sntrup761X25519Sha512: NIOSSHKeyExchangeAlgorithmProtocol {
    public static let keyExchangeInitMessageId: UInt8 = 30
    public static let keyExchangeReplyMessageId: UInt8 = 31
    public static let keyExchangeAlgorithmNames: [Substring] = ["sntrup761x25519-sha512@openssh.com"]

    // Wire format sizes
    private static let sntrup761PublicKeySize = Int(SNTRUP761_PUBLICKEYBYTES)   // 1158
    private static let sntrup761SecretKeySize = Int(SNTRUP761_SECRETKEYBYTES)   // 1763
    private static let sntrup761CiphertextSize = Int(SNTRUP761_CIPHERTEXTBYTES) // 1039
    private static let sntrup761SharedSecretSize = Int(SNTRUP761_BYTES)         // 32
    private static let x25519PublicKeySize = 32
    private static let clientInitSize = sntrup761PublicKeySize + x25519PublicKeySize   // 1190
    private static let serverReplySize = sntrup761CiphertextSize + x25519PublicKeySize // 1071
    private static let combinedSecretSize = 64  // SHA-512 output

    private var previousSessionIdentifier: ByteBuffer?
    private var ourRole: SSHConnectionRole
    private var sntrup761PublicKey: [UInt8]
    private var sntrup761SecretKey: [UInt8]
    private var x25519PrivateKey: Curve25519.KeyAgreement.PrivateKey

    public init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        self.x25519PrivateKey = Curve25519.KeyAgreement.PrivateKey()

        // Generate sntrup761 key pair
        var pk = [UInt8](repeating: 0, count: Self.sntrup761PublicKeySize)
        var sk = [UInt8](repeating: 0, count: Self.sntrup761SecretKeySize)
        sntrup761_keypair(&pk, &sk)
        self.sntrup761PublicKey = pk
        self.sntrup761SecretKey = sk
    }

    // MARK: - Client Side

    public func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> ByteBuffer {
        // Q_C = sntrup761_pk (1158 bytes) || x25519_pk (32 bytes)
        let x25519PubKeyBytes = x25519PrivateKey.publicKey.rawRepresentation

        var buffer = allocator.buffer(capacity: Self.clientInitSize)
        buffer.writeBytes(sntrup761PublicKey)
        buffer.writeBytes(x25519PubKeyBytes)

        assert(buffer.readableBytes == Self.clientInitSize,
               "Q_C must be exactly \(Self.clientInitSize) bytes, got \(buffer.readableBytes)")

        return buffer
    }

    public mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage: NIOSSHKeyExchangeServerReply,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        // Reconstruct client init for exchange hash
        let x25519PubKeyBytes = x25519PrivateKey.publicKey.rawRepresentation
        var clientInit = Data(capacity: Self.clientInitSize)
        clientInit.append(contentsOf: sntrup761PublicKey)
        clientInit.append(contentsOf: x25519PubKeyBytes)

        // 1. Parse S_REPLY: sntrup761_ct (1039 bytes) || x25519_pk (32 bytes)
        let serverPublicKeyBuffer = serverKeyExchangeMessage.publicKey
        guard serverPublicKeyBuffer.readableBytes == Self.serverReplySize else {
            throw CitadelError.cryptographicError
        }

        guard let serverReplyBytes = serverPublicKeyBuffer.getBytes(
            at: serverPublicKeyBuffer.readerIndex,
            length: Self.serverReplySize
        ) else {
            throw CitadelError.cryptographicError
        }

        let sntrup761Ciphertext = Array(serverReplyBytes[0..<Self.sntrup761CiphertextSize])
        let serverX25519PubKeyBytes = Array(serverReplyBytes[Self.sntrup761CiphertextSize..<Self.serverReplySize])

        // 2. X25519 key agreement
        let serverX25519PublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: serverX25519PubKeyBytes
        )
        let classicalSharedSecret = try x25519PrivateKey.sharedSecretFromKeyAgreement(
            with: serverX25519PublicKey
        )

        // 3. sntrup761 decapsulation
        var sntrup761SharedSecret = [UInt8](repeating: 0, count: Self.sntrup761SharedSecretSize)
        var ct = sntrup761Ciphertext
        var sk = sntrup761SecretKey
        sntrup761_dec(&sntrup761SharedSecret, &ct, &sk)

        // 4. Combine: K = SHA-512(sntrup761_ss || x25519_ss)
        let combinedSecret = computeCombinedSecret(
            pqSecret: sntrup761SharedSecret,
            classicalSecret: classicalSharedSecret
        )

        // 5. Compute exchange hash
        // H = SHA-512(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || K)
        // initialExchangeBytes already contains V_C, V_S, I_C, I_S

        // K_S as SSH string
        initialExchangeBytes.writeCompositeSSHString {
            serverKeyExchangeMessage.hostKey.write(to: &$0)
        }

        // Q_C as SSH string
        initialExchangeBytes.writeSSHStringBytes(clientInit)

        // Q_S as SSH string
        initialExchangeBytes.writeSSHStringBytes(serverReplyBytes)

        // OpenSSH encodes the hybrid shared secret as a fixed-length SSH
        // string, not an mpint like classical ECDH.
        initialExchangeBytes.writeSSHStringBytes(combinedSecret)
        let exchangeHash = SHA512.hash(data: initialExchangeBytes.readableBytesView)

        // 6. Verify server signature
        guard serverKeyExchangeMessage.hostKey.isValidSignature(
            serverKeyExchangeMessage.signature,
            for: exchangeHash
        ) else {
            throw CitadelError.invalidSignature
        }

        // 7. Determine session ID
        let sessionID: ByteBuffer
        if let previousSessionIdentifier = self.previousSessionIdentifier {
            sessionID = previousSessionIdentifier
        } else {
            var hashBytes = allocator.buffer(capacity: SHA512.byteCount)
            hashBytes.writeContiguousBytes(exchangeHash)
            sessionID = hashBytes
        }

        // 8. Derive session keys using SHA-512
        let keys = generateKeys(
            combinedSecret: combinedSecret,
            exchangeHash: exchangeHash,
            sessionID: sessionID,
            expectedKeySizes: expectedKeySizes
        )

        return KeyExchangeResult(sessionID: sessionID, keys: keys)
    }

    // MARK: - Server Side (not supported)

    public mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage: ByteBuffer,
        serverHostKey: NIOSSHPrivateKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, NIOSSHKeyExchangeServerReply) {
        fatalError("Server-side key exchange not supported")
    }

    // MARK: - Private Helpers

    /// Compute K = SHA-512(sntrup761_ss || x25519_ss)
    private func computeCombinedSecret(
        pqSecret: [UInt8],
        classicalSecret: SharedSecret
    ) -> Data {
        var hasher = SHA512()
        hasher.update(data: pqSecret)
        classicalSecret.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        return Data(digest)
    }

    /// RFC 4253 key derivation using SHA-512.
    /// For sntrup761x25519-sha512@openssh.com, K is SSH string encoded,
    /// matching OpenSSH's fixed-length hybrid shared secret handling.
    private func generateKeys(
        combinedSecret: Data,
        exchangeHash: SHA512.Digest,
        sessionID: ByteBuffer,
        expectedKeySizes: ExpectedKeySizes
    ) -> NIOSSHSessionKeys {
        func calculateKey(letter: UInt8, expectedKeySize size: Int) -> SymmetricKey {
            SymmetricKey(data: calculateKeyBytes(letter: letter, expectedKeySize: size))
        }

        func calculateKeyBytes(letter: UInt8, expectedKeySize size: Int) -> [UInt8] {
            var result = [UInt8]()

            while result.count < size {
                var hasher = SHA512()

                // K as SSH string for OpenSSH hybrid KEMs (not mpint)
                combinedSecret.withUnsafeBytes { hasher.updateAsSSHString($0) }

                // H (exchange hash)
                exchangeHash.withUnsafeBytes { hasher.update(bufferPointer: $0) }

                if !result.isEmpty {
                    // Extension: HASH(K || H || K1 || K2 || ...)
                    result.withUnsafeBytes { hasher.update(bufferPointer: $0) }
                } else {
                    // First round: HASH(K || H || letter || session_id)
                    hasher.update(byte: letter)
                    sessionID.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
                }

                let digest = hasher.finalize()
                digest.withUnsafeBytes { result.append(contentsOf: $0) }
            }

            result.removeLast(result.count - size)
            return result
        }

        switch self.ourRole {
        case .client:
            return NIOSSHSessionKeys(
                initialInboundIV: calculateKeyBytes(letter: UInt8(ascii: "B"), expectedKeySize: expectedKeySizes.ivSize),
                initialOutboundIV: calculateKeyBytes(letter: UInt8(ascii: "A"), expectedKeySize: expectedKeySizes.ivSize),
                inboundEncryptionKey: calculateKey(letter: UInt8(ascii: "D"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                outboundEncryptionKey: calculateKey(letter: UInt8(ascii: "C"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                inboundMACKey: calculateKey(letter: UInt8(ascii: "F"), expectedKeySize: expectedKeySizes.macKeySize),
                outboundMACKey: calculateKey(letter: UInt8(ascii: "E"), expectedKeySize: expectedKeySizes.macKeySize)
            )
        case .server:
            return NIOSSHSessionKeys(
                initialInboundIV: calculateKeyBytes(letter: UInt8(ascii: "A"), expectedKeySize: expectedKeySizes.ivSize),
                initialOutboundIV: calculateKeyBytes(letter: UInt8(ascii: "B"), expectedKeySize: expectedKeySizes.ivSize),
                inboundEncryptionKey: calculateKey(letter: UInt8(ascii: "C"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                outboundEncryptionKey: calculateKey(letter: UInt8(ascii: "D"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                inboundMACKey: calculateKey(letter: UInt8(ascii: "E"), expectedKeySize: expectedKeySizes.macKeySize),
                outboundMACKey: calculateKey(letter: UInt8(ascii: "F"), expectedKeySize: expectedKeySizes.macKeySize)
            )
        }
    }
}
