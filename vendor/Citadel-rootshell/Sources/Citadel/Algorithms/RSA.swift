import NIOCore
import NIOFoundationCompat
import BigInt
import NIOSSH
import CCryptoBoringSSL
import Foundation
import Crypto

extension Insecure {
    public enum RSA {}
}

extension Insecure.RSA {
    private enum VerificationHashAlgorithm {
        case sha1
        case sha256

        var nid: Int32 {
            switch self {
            case .sha1: return NID_sha1
            case .sha256: return NID_sha256
            }
        }

        func digest<D: DataProtocol>(for data: D) -> [UInt8] {
            switch self {
            case .sha1:
                return Array(Insecure.SHA1.hash(data: data))
            case .sha256:
                return Array(SHA256.hash(data: data))
            }
        }
    }

    public final class PublicKey: NIOSSHPublicKeyProtocol {
        public static let publicKeyPrefix = "ssh-rsa"
        public static var defaultHostKeyAlgorithms: [String]? { ["rsa-sha2-256"] }
        public static var authAlgorithmName: String { "rsa-sha2-256" }
        public static let keyExchangeAlgorithms = ["diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1"]

        /// OpenSSH certificate support: the cert blob carries `ssh-rsa-cert-v01@openssh.com`
        /// while the userauth request names the SHA-2 cert algorithm (RFC 8332 section 3.2).
        /// The signature itself stays `rsa-sha2-256`.
        public static var certifiedKeyPrefix: String? { "ssh-rsa-cert-v01@openssh.com" }
        public static var certifiedAuthAlgorithmName: String? { "rsa-sha2-256-cert-v01@openssh.com" }

        // Explicitly implement instance property to override protocol extension default
        public var authAlgorithmName: String {
            Self.authAlgorithmName
        }

        // PublicExponent e
        internal let publicExponent: UnsafeMutablePointer<BIGNUM>
        
        // Modulus n
        internal let modulus: UnsafeMutablePointer<BIGNUM>
        
        deinit {
            CCryptoBoringSSL_BN_free(modulus)
            CCryptoBoringSSL_BN_free(publicExponent)
        }
        
        public var rawRepresentation: Data {
            var buffer = ByteBuffer()
            buffer.writeMPBignum(publicExponent)
            buffer.writeMPBignum(modulus)
            return buffer.readData(length: buffer.readableBytes)!
        }
        
        enum PubkeyParseError: Error {
            case invalidInitialSequence, invalidAlgorithmIdentifier, invalidSubjectPubkey, forbiddenTrailingData, invalidRSAPubkey
        }
        
        public init(publicExponent: UnsafeMutablePointer<BIGNUM>, modulus: UnsafeMutablePointer<BIGNUM>) {
            self.publicExponent = publicExponent
            self.modulus = modulus
        }
        
        public func encrypt<D: DataProtocol>(for message: D) throws -> EncryptedMessage {
//            let message = BigUInt(Data(message))
//
//            guard message > .zero && message <= modulus - 1 else {
//                throw RSAError.messageRepresentativeOutOfRange
//            }
//
//            let result = message.power(publicExponent, modulus: modulus)
//            return EncryptedMessage(rawRepresentation: result.serialize())
            throw CitadelError.unsupported
        }

        /// Encrypt with PKCS#1 v1.5 EME padding via BoringSSL. Counterpart
        /// to ``PrivateKey/decryptPKCS1v15(_:)`` — useful for round-trip
        /// self-tests (encrypt a known plaintext with the public side,
        /// decrypt with the private side, verify) and for any caller that
        /// needs to mint an OpenPGP-style RSA ciphertext.
        ///
        /// BoringSSL fills the random padding internally (`RSA_PKCS1_PADDING`),
        /// so each call produces a different ciphertext even for the same
        /// plaintext.
        ///
        /// - Parameter message: Plaintext bytes. Must be at most
        ///   `modulus_byte_length - 11` bytes (PKCS#1 v1.5 reserves 11
        ///   bytes for the `00 02 PS 00` framing).
        public func encryptPKCS1v15<M: DataProtocol>(_ message: M) throws -> Data {
            let context = CCryptoBoringSSL_RSA_new()
            defer { CCryptoBoringSSL_RSA_free(context) }

            let modulus = CCryptoBoringSSL_BN_new()!
            let publicExponent = CCryptoBoringSSL_BN_new()!

            CCryptoBoringSSL_BN_copy(modulus, self.modulus)
            CCryptoBoringSSL_BN_copy(publicExponent, self.publicExponent)
            guard CCryptoBoringSSL_RSA_set0_key(
                context,
                modulus,
                publicExponent,
                nil
            ) == 1 else {
                throw RSAError(message: "Failed to assemble RSA context for encrypt")
            }

            let modSize = Int(CCryptoBoringSSL_RSA_size(context))
            let inBytes = Array(message)
            guard inBytes.count + 11 <= modSize else {
                throw RSAError(message: "Plaintext too large for PKCS#1 v1.5 padding")
            }
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: modSize)
            defer { out.deallocate() }

            let written = CCryptoBoringSSL_RSA_public_encrypt(
                inBytes.count,
                inBytes,
                out,
                context,
                RSA_PKCS1_PADDING
            )
            guard written >= 0 else {
                throw RSAError(message: "RSA encrypt failed")
            }
            return Data(bytes: out, count: Int(written))
        }
        
        public func isValidSignature<D: DataProtocol>(_ signature: Signature, for data: D) -> Bool {
            isValidSignature(
                signature.rawRepresentation,
                for: data,
                hashAlgorithm: .sha256
            )
        }

        public func isValidSignature<D: DataProtocol>(_ signature: SHA1Signature, for data: D) -> Bool {
            isValidSignature(
                signature.rawRepresentation,
                for: data,
                hashAlgorithm: .sha1
            )
        }

        private func isValidSignature<D: DataProtocol>(
            _ signature: Data,
            for data: D,
            hashAlgorithm: VerificationHashAlgorithm
        ) -> Bool {
            let context = CCryptoBoringSSL_RSA_new()
            defer { CCryptoBoringSSL_RSA_free(context) }

            // Copy, so that our local `self.modulus` isn't freed by RSA_free
            let modulus = CCryptoBoringSSL_BN_new()!
            let publicExponent = CCryptoBoringSSL_BN_new()!
            
            CCryptoBoringSSL_BN_copy(modulus, self.modulus)
            CCryptoBoringSSL_BN_copy(publicExponent, self.publicExponent)
            guard CCryptoBoringSSL_RSA_set0_key(
                context,
                modulus,
                publicExponent,
                nil
            ) == 1 else {
                return false
            }

            let digest = hashAlgorithm.digest(for: data)
            let signature = Array(signature)
            return CCryptoBoringSSL_RSA_verify(
                hashAlgorithm.nid,
                digest,
                digest.count,
                signature,
                signature.count,
                context
            ) == 1
        }
        
        public func isValidSignature<D>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool where D : DataProtocol {
            switch signature {
            case let signature as Signature:
                return isValidSignature(signature, for: data)
            case let signature as SHA1Signature:
                return isValidSignature(signature, for: data)
            default:
                return false
            }
        }
        
        public func write(to buffer: inout ByteBuffer) -> Int {
            // For ssh-rsa, the format is public exponent `e` followed by modulus `n`
            var writtenBytes = 0
            writtenBytes += buffer.writeMPBignum(publicExponent)
            writtenBytes += buffer.writeMPBignum(modulus)
            return writtenBytes
        }

        /// Raw big-endian byte representation of the modulus `n`. Used by
        /// callers that need to feed the value to non-NIO crypto code
        /// (e.g. GPG keygrip computation, which canonicalises just the
        /// modulus for RSA).
        public var modulusBytes: Data {
            bnToData(modulus)
        }

        /// Raw big-endian byte representation of the public exponent `e`.
        public var publicExponentBytes: Data {
            bnToData(publicExponent)
        }

        private func bnToData(_ bn: UnsafeMutablePointer<BIGNUM>) -> Data {
            let byteCount = Int(CCryptoBoringSSL_BN_num_bytes(bn))
            guard byteCount > 0 else { return Data() }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            _ = bytes.withUnsafeMutableBufferPointer { buffer in
                CCryptoBoringSSL_BN_bn2bin(bn, buffer.baseAddress)
            }
            return Data(bytes)
        }
        
        static func read(consuming buffer: inout ByteBuffer) throws -> Insecure.RSA.PublicKey {
            try read(from: &buffer)
        }
        
        public static func read(from buffer: inout ByteBuffer) throws -> Insecure.RSA.PublicKey {
            guard
                var publicExponent = buffer.readSSHBuffer(),
                var modulus = buffer.readSSHBuffer()
            else {
                throw RSAError(message: "Invalid signature format")
            }
            
            let publicExponentBytes = publicExponent.readBytes(length: publicExponent.readableBytes)!
            let modulusBytes = modulus.readBytes(length: modulus.readableBytes)!
            return .init(
                publicExponent: CCryptoBoringSSL_BN_bin2bn(publicExponentBytes, publicExponentBytes.count, nil),
                modulus: CCryptoBoringSSL_BN_bin2bn(modulusBytes, modulusBytes.count, nil)
            )
        }
    }
    
    public struct EncryptedMessage: ContiguousBytes {
        public let rawRepresentation: Data
        
        public init<D>(rawRepresentation: D) where D : DataProtocol {
            self.rawRepresentation = Data(rawRepresentation)
        }
        
        public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
            try rawRepresentation.withUnsafeBytes(body)
        }
    }
    
    public protocol SignatureAlgorithmIdentifier {
        static var name: String { get }
    }

    public enum SHA256SignatureAlgorithm: SignatureAlgorithmIdentifier {
        public static let name = "rsa-sha2-256"
    }

    public enum SHA1SignatureAlgorithm: SignatureAlgorithmIdentifier {
        public static let name = "ssh-rsa"
    }

    /// SSH wire representation shared by every RSA signature algorithm.
    public struct RSASignature<Algorithm: SignatureAlgorithmIdentifier>:
        ContiguousBytes,
        NIOSSHSignatureProtocol
    {
        public static var signaturePrefix: String { Algorithm.name }

        public let rawRepresentation: Data

        public init<D>(rawRepresentation: D) where D: DataProtocol {
            self.rawRepresentation = Data(rawRepresentation)
        }

        public func withUnsafeBytes<R>(
            _ body: (UnsafeRawBufferPointer) throws -> R
        ) rethrows -> R {
            try rawRepresentation.withUnsafeBytes(body)
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> Self {
            guard let buffer = buffer.readSSHBuffer() else {
                throw RSAError(message: "Invalid signature format")
            }

            return Self(
                rawRepresentation: buffer.getData(
                    at: 0,
                    length: buffer.readableBytes
                )!
            )
        }
    }

    /// RSA/SHA-256 signature used by modern SSH peers.
    public typealias Signature = RSASignature<SHA256SignatureAlgorithm>

    /// Legacy RSA/SHA-1 signature used when `ssh-rsa` is negotiated for a host
    /// key or selected by the user-authentication compatibility policy.
    public typealias SHA1Signature = RSASignature<SHA1SignatureAlgorithm>
    
    public final class PrivateKey: NIOSSHPrivateKeyProtocol {
        public static let keyPrefix = "ssh-rsa"
        public static var authAlgorithmName: String { "rsa-sha2-256" }
        public static var hostKeyAlgorithms: [String] {
            [Signature.signaturePrefix, SHA1Signature.signaturePrefix]
        }

        // Private Exponent
        internal let privateExponent: UnsafeMutablePointer<BIGNUM>
        
        // Public Exponent e
        internal let _publicKey: PublicKey
        
        public var publicKey: NIOSSHPublicKeyProtocol {
            _publicKey
        }
        
        public init(privateExponent: UnsafeMutablePointer<BIGNUM>, publicExponent: UnsafeMutablePointer<BIGNUM>, modulus: UnsafeMutablePointer<BIGNUM>) {
            self.privateExponent = privateExponent
            self._publicKey = PublicKey(publicExponent: publicExponent, modulus: modulus)
        }

        /// Construct an RSA private key from raw, big-endian Data
        /// representations of the modulus, public exponent, and
        /// private exponent. This is the entry point app code uses when
        /// it has parsed an external key format (e.g. OpenPGP secret
        /// key packet for GPG agent forwarding) and doesn't have
        /// access to BoringSSL's BIGNUM type directly.
        ///
        /// CRT parameters (dp, dq, qInv) are deliberately not exposed
        /// here — BoringSSL falls back to plain `m^d mod n` when they
        /// aren't set, which is slower but produces identical
        /// signatures and matches what OpenPGP secret keys carry.
        ///
        /// - Parameters:
        ///   - modulus: `n` as big-endian bytes, leading zeros allowed
        ///     but typically stripped.
        ///   - publicExponent: `e` as big-endian bytes.
        ///   - privateExponent: `d` as big-endian bytes.
        public convenience init<M: DataProtocol, E: DataProtocol, D: DataProtocol>(
            modulus: M,
            publicExponent: E,
            privateExponent: D
        ) {
            let modulusBytes = Array(modulus)
            let publicExponentBytes = Array(publicExponent)
            let privateExponentBytes = Array(privateExponent)
            let modulusBN = CCryptoBoringSSL_BN_bin2bn(modulusBytes, modulusBytes.count, nil)!
            let publicExponentBN = CCryptoBoringSSL_BN_bin2bn(publicExponentBytes, publicExponentBytes.count, nil)!
            let privateExponentBN = CCryptoBoringSSL_BN_bin2bn(privateExponentBytes, privateExponentBytes.count, nil)!
            self.init(
                privateExponent: privateExponentBN,
                publicExponent: publicExponentBN,
                modulus: modulusBN
            )
        }

        deinit {
            CCryptoBoringSSL_BN_free(privateExponent)
        }
        
        public init(bits: Int = 2047, publicExponent e: BigUInt = 65537) {
            let privateKey = CCryptoBoringSSL_BN_new()!
            let publicKey = CCryptoBoringSSL_BN_new()!
            let group = CCryptoBoringSSL_BN_bin2bn(dh14p, dh14p.count, nil)!
            let generator = CCryptoBoringSSL_BN_bin2bn(generator2, generator2.count, nil)!
            let bignumContext = CCryptoBoringSSL_BN_CTX_new()
            
            CCryptoBoringSSL_BN_rand(privateKey, 256 * 8 - 1, 0, /*-1*/BN_RAND_BOTTOM_ANY)
            CCryptoBoringSSL_BN_mod_exp(publicKey, generator, privateKey, group, bignumContext)
            let eBytes = Array(e.serialize())
            let e = CCryptoBoringSSL_BN_bin2bn(eBytes, eBytes.count, nil)!
            
            CCryptoBoringSSL_BN_CTX_free(bignumContext)
            CCryptoBoringSSL_BN_free(generator)
            CCryptoBoringSSL_BN_free(group)
            
            self.privateExponent = privateKey
            self._publicKey = .init(
                publicExponent: e,
                modulus: publicKey
            )
        }
        
        /// Hash algorithm for RSA signing
        public enum HashAlgorithm {
            case sha256
            case sha512
        }

        public func signature<D: DataProtocol>(for message: D) throws -> Signature {
            try signature(for: message, hashAlgorithm: .sha256)
        }

        public func signature<D: DataProtocol>(for message: D, hashAlgorithm: HashAlgorithm) throws -> Signature {
            let context = CCryptoBoringSSL_RSA_new()
            defer { CCryptoBoringSSL_RSA_free(context) }

            // Copy, so that our local `self.modulus` isn't freed by RSA_free
            let modulus = CCryptoBoringSSL_BN_new()!
            let publicExponent = CCryptoBoringSSL_BN_new()!
            let privateExponent = CCryptoBoringSSL_BN_new()!

            CCryptoBoringSSL_BN_copy(modulus, self._publicKey.modulus)
            CCryptoBoringSSL_BN_copy(publicExponent, self._publicKey.publicExponent)
            CCryptoBoringSSL_BN_copy(privateExponent, self.privateExponent)
            guard CCryptoBoringSSL_RSA_set0_key(
                context,
                modulus,
                publicExponent,
                privateExponent
            ) == 1 else {
                throw CitadelError.signingError
            }

            // Compute hash based on algorithm
            let hash: [UInt8]
            let nid: Int32

            switch hashAlgorithm {
            case .sha256:
                hash = Array(SHA256.hash(data: message))
                nid = NID_sha256
            case .sha512:
                hash = Array(SHA512.hash(data: message))
                nid = NID_sha512
            }

            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { out.deallocate() }
            var outLength: UInt32 = 4096
            let result = CCryptoBoringSSL_RSA_sign(
                nid,
                hash,
                Int(hash.count),
                out,
                &outLength,
                context
            )

            guard result == 1 else {
                throw CitadelError.signingError
            }

            return Signature(rawRepresentation: Data(bytes: out, count: Int(outLength)))
        }
        
        public func signature<D>(for data: D) throws -> NIOSSHSignatureProtocol where D : DataProtocol {
            return try self.signature(for: data) as Signature
        }

        public func signature<D: DataProtocol>(
            for data: D,
            authenticationAlgorithmName: String
        ) throws -> NIOSSHSignatureProtocol {
            switch authenticationAlgorithmName {
            case Signature.signaturePrefix:
                return try self.signature(for: data) as Signature
            case SHA1Signature.signaturePrefix:
                return try self.sha1Signature(for: data)
            default:
                throw RSAError(message: "Unsupported RSA signature algorithm: \(authenticationAlgorithmName)")
            }
        }

        /// Creates a legacy RSA/SHA-1 SSH signature.
        ///
        /// This must only be used for a user-auth attempt whose algorithm name
        /// is explicitly `ssh-rsa`.
        public func sha1Signature<D: DataProtocol>(for data: D) throws -> SHA1Signature {
            let digest = Data(Insecure.SHA1.hash(data: data))
            let signature = try self.signature(
                forPrecomputedDigest: digest,
                hashAlgorithm: .sha1
            )
            return SHA1Signature(rawRepresentation: signature.rawRepresentation)
        }

        /// A NIOSSH key view that names and signs the next authentication
        /// attempt as legacy `ssh-rsa`.
        public var legacySHA1Key: NIOSSHPrivateKey {
            NIOSSHPrivateKey(custom: LegacySHA1PrivateKey(backing: self))
        }

        /// Hash algorithm tag for a precomputed-digest RSA signature.
        /// Broader than ``HashAlgorithm`` so callers that have already
        /// computed an arbitrary digest (e.g. GPG agent forwarding,
        /// where the remote chooses the hash) can request the matching
        /// PKCS#1 v1.5 wrapping.
        public enum PrecomputedHashAlgorithm {
            case sha1
            case sha224
            case sha256
            case sha384
            case sha512

            var nid: Int32 {
                switch self {
                case .sha1: return NID_sha1
                case .sha224: return NID_sha224
                case .sha256: return NID_sha256
                case .sha384: return NID_sha384
                case .sha512: return NID_sha512
                }
            }

            var expectedDigestByteCount: Int {
                switch self {
                case .sha1: return 20
                case .sha224: return 28
                case .sha256: return 32
                case .sha384: return 48
                case .sha512: return 64
                }
            }
        }

        /// Sign a digest that has already been computed by the caller.
        ///
        /// Unlike ``signature(for:hashAlgorithm:)``, which hashes the
        /// supplied data internally, this entry point treats `digest`
        /// as the finished hash and feeds it straight into PKCS#1 v1.5
        /// padding + RSA exponentiation. This is what GPG agent
        /// forwarding needs — the remote's `SETHASH` command delivers a
        /// precomputed digest, and re-hashing would produce a signature
        /// over the wrong bytes.
        ///
        /// - Parameters:
        ///   - digest: The precomputed hash bytes. Length MUST match
        ///     the algorithm (e.g. exactly 32 bytes for SHA-256).
        ///   - hashAlgorithm: Which hash family produced `digest`.
        ///     Determines the DigestInfo OID prefix wrapped around the
        ///     digest by PKCS#1.
        /// - Throws: ``CitadelError/signingError`` if the digest is the
        ///   wrong length, or if BoringSSL refuses the signing
        ///   operation (e.g. modulus too small for the chosen hash).
        public func signature(
            forPrecomputedDigest digest: Data,
            hashAlgorithm: PrecomputedHashAlgorithm
        ) throws -> Signature {
            guard digest.count == hashAlgorithm.expectedDigestByteCount else {
                throw CitadelError.signingError
            }

            let context = CCryptoBoringSSL_RSA_new()
            defer { CCryptoBoringSSL_RSA_free(context) }

            // Same defensive-copy pattern as signature(for:hashAlgorithm:):
            // RSA_free will drop these BIGNUMs, but the receiver's
            // stored modulus/publicExponent/privateExponent are still
            // needed after this call returns. We never set CRT params
            // (dp, dq, qInv) — BoringSSL falls back to plain
            // m^d mod n in their absence, which is slower but correct
            // and matches what's available from an OpenPGP secret key
            // (which doesn't carry CRT params at the wire level).
            let modulus = CCryptoBoringSSL_BN_new()!
            let publicExponent = CCryptoBoringSSL_BN_new()!
            let privateExponent = CCryptoBoringSSL_BN_new()!

            CCryptoBoringSSL_BN_copy(modulus, self._publicKey.modulus)
            CCryptoBoringSSL_BN_copy(publicExponent, self._publicKey.publicExponent)
            CCryptoBoringSSL_BN_copy(privateExponent, self.privateExponent)
            guard CCryptoBoringSSL_RSA_set0_key(
                context,
                modulus,
                publicExponent,
                privateExponent
            ) == 1 else {
                throw CitadelError.signingError
            }

            let digestBytes = Array(digest)
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { out.deallocate() }
            var outLength: UInt32 = 4096
            let result = CCryptoBoringSSL_RSA_sign(
                hashAlgorithm.nid,
                digestBytes,
                digestBytes.count,
                out,
                &outLength,
                context
            )
            guard result == 1 else {
                throw CitadelError.signingError
            }

            return Signature(rawRepresentation: Data(bytes: out, count: Int(outLength)))
        }

        public func decrypt(_ message: EncryptedMessage) throws -> Data {
//            let signature = BigUInt(message.rawRepresentation)
//
//            switch storage {
//            case let .privateExponent(privateExponent, modulus):
//                guard signature >= .zero && signature <= privateExponent else {
//                    throw RSAError.ciphertextRepresentativeOutOfRange
//                }
//
//                return signature.power(privateExponent, modulus: modulus).serialize()
//            }
            throw CitadelError.unsupported
        }

        /// Decrypt a PKCS#1 v1.5 EME-encrypted block (modulus-byte
        /// length) and return the unpadded message bytes. This is the
        /// operation OpenPGP needs when consuming an RSA-encrypted
        /// session key — `gcry_pk_decrypt` does the same thing
        /// internally for the agent's PKDECRYPT verb.
        ///
        /// CRT parameters (dp/dq/qInv) aren't required: BoringSSL
        /// falls back to the slower-but-correct `m^d mod n` path when
        /// they're absent, which matches the OpenPGP secret-key
        /// material we ship in (modulus + private exponent).
        ///
        /// - Parameter ciphertext: The RSA ciphertext, exactly
        ///   `modulus_byte_length` bytes (big-endian, left-padded with
        ///   zeros if needed).
        /// - Throws: ``CitadelError/cryptographicError`` if the
        ///   ciphertext can't be unpadded or BoringSSL refuses the
        ///   operation (modulus mismatch, invalid PKCS#1 framing, …).
        public func decryptPKCS1v15<C: DataProtocol>(_ ciphertext: C) throws -> Data {
            let context = CCryptoBoringSSL_RSA_new()
            defer { CCryptoBoringSSL_RSA_free(context) }

            // Same defensive copy pattern as the precomputed-digest
            // signing path: RSA_free will drop these, but our stored
            // BIGNUMs must survive after this call returns.
            let modulus = CCryptoBoringSSL_BN_new()!
            let publicExponent = CCryptoBoringSSL_BN_new()!
            let privateExponent = CCryptoBoringSSL_BN_new()!

            CCryptoBoringSSL_BN_copy(modulus, self._publicKey.modulus)
            CCryptoBoringSSL_BN_copy(publicExponent, self._publicKey.publicExponent)
            CCryptoBoringSSL_BN_copy(privateExponent, self.privateExponent)
            guard CCryptoBoringSSL_RSA_set0_key(
                context,
                modulus,
                publicExponent,
                privateExponent
            ) == 1 else {
                throw RSAError(message: "Failed to assemble RSA context for decrypt")
            }

            let modSize = Int(CCryptoBoringSSL_RSA_size(context))
            let inBytes = Array(ciphertext)
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: modSize)
            defer { out.deallocate() }

            // `RSA_private_decrypt` with `RSA_PKCS1_PADDING` performs
            // `m = c^d mod n`, then strips the PKCS#1 v1.5 EME
            // padding and returns the message body. Returns -1 on
            // failure (and length on success).
            let written = CCryptoBoringSSL_RSA_private_decrypt(
                inBytes.count,
                inBytes,
                out,
                context,
                RSA_PKCS1_PADDING
            )
            guard written >= 0 else {
                throw RSAError(message: "RSA decrypt failed")
            }
            return Data(bytes: out, count: Int(written))
        }
        
        internal func generatedSharedSecret(with publicKey: PublicKey, modulus: BigUInt) -> Data {
            let secret = CCryptoBoringSSL_BN_new()
            defer { CCryptoBoringSSL_BN_free(secret) }
            
            let ctx = CCryptoBoringSSL_BN_CTX_new()
            defer { CCryptoBoringSSL_BN_CTX_free(ctx) }
            
            let group = CCryptoBoringSSL_BN_bin2bn(dh14p, dh14p.count, nil)!
            defer { CCryptoBoringSSL_BN_free(group) }
            CCryptoBoringSSL_BN_mod_exp(
                secret,
                publicKey.modulus,
                privateExponent,
                group,
                ctx
            )
            
            var array = [UInt8]()
            array.reserveCapacity(Int(CCryptoBoringSSL_BN_num_bytes(secret)))
            CCryptoBoringSSL_BN_bn2bin(secret, &array)
            return Data(array)
        }
    }

    private final class LegacySHA1PublicKey: NIOSSHPublicKeyProtocol {
        static let publicKeyPrefix = "ssh-rsa"
        static let authAlgorithmName = "ssh-rsa"

        private let backing: PublicKey

        var rawRepresentation: Data { backing.rawRepresentation }

        init(backing: PublicKey) {
            self.backing = backing
        }

        func isValidSignature<D: DataProtocol>(
            _ signature: NIOSSHSignatureProtocol,
            for data: D
        ) -> Bool {
            backing.isValidSignature(signature, for: data)
        }

        func write(to buffer: inout ByteBuffer) -> Int {
            backing.write(to: &buffer)
        }

        static func read(from buffer: inout ByteBuffer) throws -> LegacySHA1PublicKey {
            LegacySHA1PublicKey(backing: try PublicKey.read(from: &buffer))
        }
    }

    private final class LegacySHA1PrivateKey: NIOSSHPrivateKeyProtocol {
        static let keyPrefix = "ssh-rsa"
        static let authAlgorithmName = "ssh-rsa"

        private let backing: PrivateKey

        var publicKey: NIOSSHPublicKeyProtocol {
            LegacySHA1PublicKey(backing: backing._publicKey)
        }

        init(backing: PrivateKey) {
            self.backing = backing
        }

        func signature<D: DataProtocol>(
            for data: D
        ) throws -> NIOSSHSignatureProtocol {
            try backing.sha1Signature(for: data)
        }
    }
}

public struct RSAError: Error {
    let message: String
    
    static let messageRepresentativeOutOfRange = RSAError(message: "message representative out of range")
    static let ciphertextRepresentativeOutOfRange = RSAError(message: "ciphertext representative out of range")
    static let signatureRepresentativeOutOfRange = RSAError(message: "signature representative out of range")
    static let invalidPem = RSAError(message: "invalid PEM")
    static let pkcs1Error = RSAError(message: "PKCS1Error")
}

extension BigUInt {
    public static func randomPrime(bits: Int) -> BigUInt {
        while true {
            var privateExponent = BigUInt.randomInteger(withExactWidth: bits)
            privateExponent |= 1
            
            if privateExponent.isPrime() {
                return privateExponent
            }
        }
    }
    
    fileprivate init(boringSSL bignum: UnsafeMutablePointer<BIGNUM>) {
        var data = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(bignum)))
        CCryptoBoringSSL_BN_bn2bin(bignum, &data)
        self.init(Data(data))
    }
}

extension BigUInt {
    public static let diffieHellmanGroup14 = BigUInt(Data([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xC9, 0x0F, 0xDA, 0xA2, 0x21, 0x68, 0xC2, 0x34,
        0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1,
        0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74,
        0x02, 0x0B, 0xBE, 0xA6, 0x3B, 0x13, 0x9B, 0x22,
        0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
        0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B,
        0x30, 0x2B, 0x0A, 0x6D, 0xF2, 0x5F, 0x14, 0x37,
        0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45,
        0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6,
        0xF4, 0x4C, 0x42, 0xE9, 0xA6, 0x37, 0xED, 0x6B,
        0x0B, 0xFF, 0x5C, 0xB6, 0xF4, 0x06, 0xB7, 0xED,
        0xEE, 0x38, 0x6B, 0xFB, 0x5A, 0x89, 0x9F, 0xA5,
        0xAE, 0x9F, 0x24, 0x11, 0x7C, 0x4B, 0x1F, 0xE6,
        0x49, 0x28, 0x66, 0x51, 0xEC, 0xE4, 0x5B, 0x3D,
        0xC2, 0x00, 0x7C, 0xB8, 0xA1, 0x63, 0xBF, 0x05,
        0x98, 0xDA, 0x48, 0x36, 0x1C, 0x55, 0xD3, 0x9A,
        0x69, 0x16, 0x3F, 0xA8, 0xFD, 0x24, 0xCF, 0x5F,
        0x83, 0x65, 0x5D, 0x23, 0xDC, 0xA3, 0xAD, 0x96,
        0x1C, 0x62, 0xF3, 0x56, 0x20, 0x85, 0x52, 0xBB,
        0x9E, 0xD5, 0x29, 0x07, 0x70, 0x96, 0x96, 0x6D,
        0x67, 0x0C, 0x35, 0x4E, 0x4A, 0xBC, 0x98, 0x04,
        0xF1, 0x74, 0x6C, 0x08, 0xCA, 0x18, 0x21, 0x7C,
        0x32, 0x90, 0x5E, 0x46, 0x2E, 0x36, 0xCE, 0x3B,
        0xE3, 0x9E, 0x77, 0x2C, 0x18, 0x0E, 0x86, 0x03,
        0x9B, 0x27, 0x83, 0xA2, 0xEC, 0x07, 0xA2, 0x8F,
        0xB5, 0xC5, 0x5D, 0xF0, 0x6F, 0x4C, 0x52, 0xC9,
        0xDE, 0x2B, 0xCB, 0xF6, 0x95, 0x58, 0x17, 0x18,
        0x39, 0x95, 0x49, 0x7C, 0xEA, 0x95, 0x6A, 0xE5,
        0x15, 0xD2, 0x26, 0x18, 0x98, 0xFA, 0x05, 0x10,
        0x15, 0x72, 0x8E, 0x5A, 0x8A, 0xAC, 0xAA, 0x68,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    ] as [UInt8]))
}

extension ByteBuffer {
    @discardableResult
    mutating func readPositiveMPInt() -> BigUInt? {
        guard
            let length = readInteger(as: UInt32.self),
            let data = readData(length: Int(length))
        else {
            return nil
        }
        
        return BigUInt(data)
    }
    
    @discardableResult
    mutating func writePositiveMPInt<Buffer: Collection>(_ value: Buffer) -> Int where Buffer.Element == UInt8 {
        // A positive MPInt must have its high bit set to zero, and not have leading zero bytes unless it needs that
        // high bit set to zero. We address this by dropping all the leading zero bytes in the collection first.
        let trimmed = value.drop(while: { $0 == 0 })
        let needsLeadingZero = ((trimmed.first ?? 0) & 0x80) == 0x80

        // Now we write the length.
        var writtenBytes: Int

        if needsLeadingZero {
            writtenBytes = self.writeInteger(UInt32(trimmed.count + 1))
            writtenBytes += self.writeInteger(UInt8(0))
        } else {
            writtenBytes = self.writeInteger(UInt32(trimmed.count))
        }

        writtenBytes += self.writeBytes(trimmed)
        return writtenBytes
    }
    
    /// Writes the given bytes as an SSH string at the writer index. Moves the writer index forward.
    @discardableResult
    mutating func writeSSHString<Buffer: Collection>(_ value: Buffer) -> Int where Buffer.Element == UInt8 {
        let writtenBytes = self.setSSHString(value, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: writtenBytes)
        return writtenBytes
    }
    
    /// Sets the given bytes as an SSH string at the given offset. Does not mutate the writer index.
    @discardableResult
    mutating func setSSHString<Buffer: Collection>(_ value: Buffer, at offset: Int) -> Int where Buffer.Element == UInt8 {
        // RFC 4251 § 5:
        //
        // > Arbitrary length binary string.  Strings are allowed to contain
        // > arbitrary binary data, including null characters and 8-bit
        // > characters.  They are stored as a uint32 containing its length
        // > (number of bytes that follow) and zero (= empty string) or more
        // > bytes that are the value of the string.  Terminating null
        // > characters are not used.
        let lengthLength = self.setInteger(UInt32(value.count), at: offset)
        let valueLength = self.setBytes(value, at: offset + lengthLength)
        return lengthLength + valueLength
    }
    
    /// Sets the readable bytes of a ByteBuffer as an SSH string at the given offset. Does not mutate the writer index.
    @discardableResult
    mutating func setSSHString(_ value: ByteBuffer, at offset: Int) -> Int {
        // RFC 4251 § 5:
        //
        // > Arbitrary length binary string.  Strings are allowed to contain
        // > arbitrary binary data, including null characters and 8-bit
        // > characters.  They are stored as a uint32 containing its length
        // > (number of bytes that follow) and zero (= empty string) or more
        // > bytes that are the value of the string.  Terminating null
        // > characters are not used.
        let lengthLength = self.setInteger(UInt32(value.readableBytes), at: offset)
        let valueLength = self.setBuffer(value, at: offset + lengthLength)
        return lengthLength + valueLength
    }
}
