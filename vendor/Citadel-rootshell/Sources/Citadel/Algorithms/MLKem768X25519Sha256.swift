import Foundation
import NIOCore
import NIOSSH
import Crypto
import CryptoKit

/// Post-quantum hybrid key exchange: mlkem768x25519-sha256
///
/// Implements the IETF draft `draft-ietf-sshm-mlkem-hybrid-kex` wire format:
/// - Client sends: C_PK2 (ML-KEM-768 public key, 1184 bytes) || C_PK1 (X25519 public key, 32 bytes)
/// - Server replies: S_CT2 (ML-KEM-768 ciphertext, 1088 bytes) || S_PK1 (X25519 public key, 32 bytes)
/// - Combined secret: K = SHA-256(K_PQ || K_CL)
///
/// Requires iOS 26+ / macOS 26+ for CryptoKit MLKEM768 support.
@available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *)
public struct MLKem768X25519Sha256: NIOSSHKeyExchangeAlgorithmProtocol {
    public static let keyExchangeInitMessageId: UInt8 = 30
    public static let keyExchangeReplyMessageId: UInt8 = 31
    public static let keyExchangeAlgorithmNames: [Substring] = ["mlkem768x25519-sha256"]

    // Wire format sizes
    private static let mlkemPublicKeySize = 1184
    private static let x25519PublicKeySize = 32
    private static let mlkemCiphertextSize = 1088
    private static let clientInitSize = mlkemPublicKeySize + x25519PublicKeySize  // 1216
    private static let serverReplySize = mlkemCiphertextSize + x25519PublicKeySize  // 1120
    private static let combinedSecretSize = 32  // SHA-256 output

    private var previousSessionIdentifier: ByteBuffer?
    private var ourRole: SSHConnectionRole
    private var mlkemPrivateKey: CryptoKit.MLKEM768.PrivateKey
    private var x25519PrivateKey: Curve25519.KeyAgreement.PrivateKey

    public init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        // swiftlint:disable:next force_try
        self.mlkemPrivateKey = try! CryptoKit.MLKEM768.PrivateKey()
        self.x25519PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    // MARK: - Client Side

    public func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> ByteBuffer {
        // C_INIT = C_PK2 (ML-KEM pubkey, 1184 bytes) || C_PK1 (X25519 pubkey, 32 bytes)
        let mlkemPubKeyBytes = mlkemPrivateKey.publicKey.rawRepresentation
        let x25519PubKeyBytes = x25519PrivateKey.publicKey.rawRepresentation

        var buffer = allocator.buffer(capacity: Self.clientInitSize)
        buffer.writeBytes(mlkemPubKeyBytes)
        buffer.writeBytes(x25519PubKeyBytes)

        assert(buffer.readableBytes == Self.clientInitSize,
               "C_INIT must be exactly \(Self.clientInitSize) bytes, got \(buffer.readableBytes)")

        return buffer
    }

    public mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage: NIOSSHKeyExchangeServerReply,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        // Store client init payload from our own keys for exchange hash
        let mlkemPubKeyBytes = mlkemPrivateKey.publicKey.rawRepresentation
        let x25519PubKeyBytes = x25519PrivateKey.publicKey.rawRepresentation
        var clientInit = Data(capacity: Self.clientInitSize)
        clientInit.append(contentsOf: mlkemPubKeyBytes)
        clientInit.append(contentsOf: x25519PubKeyBytes)

        // 1. Parse S_REPLY: S_CT2 (1088 bytes) || S_PK1 (32 bytes)
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

        let mlkemCiphertextBytes = Array(serverReplyBytes[0..<Self.mlkemCiphertextSize])
        let serverX25519PubKeyBytes = Array(serverReplyBytes[Self.mlkemCiphertextSize..<Self.serverReplySize])

        // 2. X25519 ECDH
        let serverX25519PublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: serverX25519PubKeyBytes
        )
        let classicalSharedSecret = try x25519PrivateKey.sharedSecretFromKeyAgreement(
            with: serverX25519PublicKey
        )

        // 3. ML-KEM decapsulate (decapsulate takes DataProtocol directly)
        let pqSharedSecret = try mlkemPrivateKey.decapsulate(mlkemCiphertextBytes)

        // 4. Combine: K = SHA-256(K_PQ || K_CL)
        let combinedSecret = computeCombinedSecret(
            pqSecret: pqSharedSecret,
            classicalSecret: classicalSharedSecret
        )

        // 5. Compute exchange hash
        // H = SHA-256(V_C || V_S || I_C || I_S || K_S || C_INIT || S_REPLY || K)
        // initialExchangeBytes already contains V_C, V_S, I_C, I_S

        // K_S as SSH string
        initialExchangeBytes.writeCompositeSSHString {
            serverKeyExchangeMessage.hostKey.write(to: &$0)
        }

        // C_INIT as SSH string
        initialExchangeBytes.writeSSHStringBytes(clientInit)

        // S_REPLY as SSH string
        initialExchangeBytes.writeSSHStringBytes(serverReplyBytes)

        // K as SSH string (fixed-length 32 bytes, NOT mpint — per IETF draft §3.1)
        initialExchangeBytes.writeSSHStringBytes(combinedSecret)

        let exchangeHash = SHA256.hash(data: initialExchangeBytes.readableBytesView)

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
            var hashBytes = allocator.buffer(capacity: SHA256.byteCount)
            hashBytes.writeContiguousBytes(exchangeHash)
            sessionID = hashBytes
        }

        // 8. Derive session keys
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

    /// Compute K = SHA-256(K_PQ || K_CL)
    private func computeCombinedSecret(
        pqSecret: SymmetricKey,
        classicalSecret: SharedSecret
    ) -> Data {
        var hasher = SHA256()
        pqSecret.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        classicalSecret.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        return Data(digest)
    }

    /// RFC 4253 key derivation: HASH(K || H || discriminator || session_id)
    /// For mlkem768x25519-sha256, K is SSH string encoded (4-byte length + raw bytes),
    /// matching OpenSSH's encoding where the shared secret hash is stored as a string.
    private func generateKeys(
        combinedSecret: Data,
        exchangeHash: SHA256.Digest,
        sessionID: ByteBuffer,
        expectedKeySizes: ExpectedKeySizes
    ) -> NIOSSHSessionKeys {
        func calculateKey(letter: UInt8, expectedKeySize size: Int) -> SymmetricKey {
            SymmetricKey(data: calculateKeyBytes(letter: letter, expectedKeySize: size))
        }

        func calculateKeyBytes(letter: UInt8, expectedKeySize size: Int) -> [UInt8] {
            var result = [UInt8]()

            while result.count < size {
                var hasher = SHA256()

                // K as SSH string for hybrid PQ KDF (not mpint)
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
