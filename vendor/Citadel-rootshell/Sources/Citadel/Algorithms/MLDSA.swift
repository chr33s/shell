import Foundation
import NIOCore
import NIOSSH
import CryptoKit

/// Post-quantum host key signature algorithms: ssh-mldsa65, ssh-mldsa87
///
/// Implements ML-DSA (FIPS 204) digital signatures for SSH host key verification,
/// matching the OQS OpenSSH reference (`draft-rpe-ssh-mldsa-02`).
///
/// Wire format (NIOSSH handles the algorithm name prefix wrapping):
/// - Public key: SSH string containing raw FIPS 204 public key bytes
/// - Signature: SSH string containing raw FIPS 204 signature bytes
///
/// Signing uses pure ML-DSA (empty context) per the spec.
///
/// Requires iOS 26+ / macOS 26+ for CryptoKit MLDSA support.

// MARK: - ML-DSA-65

@available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *)
public enum MLDSA65SSH {

    public struct PublicKey: NIOSSHPublicKeyProtocol {
        public static let publicKeyPrefix = "ssh-mldsa65"
        public static var defaultHostKeyAlgorithms: [String]? { [] }

        private let backing: CryptoKit.MLDSA65.PublicKey

        public var rawRepresentation: Data {
            backing.rawRepresentation
        }

        public init(_ backing: CryptoKit.MLDSA65.PublicKey) {
            self.backing = backing
        }

        public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let signature = signature as? Signature else {
                return false
            }
            return backing.isValidSignature(signature.rawRepresentation, for: data)
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(backing.rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> PublicKey {
            guard let keyBuffer = buffer.readSSHBuffer() else {
                throw MLDSAError(message: "Invalid ML-DSA-65 public key format")
            }
            guard let keyData = keyBuffer.getData(at: 0, length: keyBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-65 public key data")
            }
            return try PublicKey(CryptoKit.MLDSA65.PublicKey(rawRepresentation: keyData))
        }
    }

    public struct Signature: NIOSSHSignatureProtocol {
        public static let signaturePrefix = "ssh-mldsa65"

        public let rawRepresentation: Data

        public init(rawRepresentation: Data) {
            self.rawRepresentation = rawRepresentation
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> Signature {
            guard let sigBuffer = buffer.readSSHBuffer() else {
                throw MLDSAError(message: "Invalid ML-DSA-65 signature format")
            }
            guard let sigData = sigBuffer.getData(at: 0, length: sigBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-65 signature data")
            }
            return Signature(rawRepresentation: sigData)
        }
    }

    public struct PrivateKey: NIOSSHPrivateKeyProtocol {
        public static let keyPrefix = "ssh-mldsa65"

        private let backing: CryptoKit.MLDSA65.PrivateKey

        public var publicKey: NIOSSHPublicKeyProtocol {
            PublicKey(backing.publicKey)
        }

        /// Typed accessor for the raw FIPS 204 public key bytes.
        public var mldsaPublicKey: PublicKey {
            PublicKey(backing.publicKey)
        }

        /// 32-byte FIPS 204 keygen seed — the durable representation.
        public var seedRepresentation: Data {
            backing.seedRepresentation
        }

        public init(_ backing: CryptoKit.MLDSA65.PrivateKey) {
            self.backing = backing
        }

        public init() throws {
            self.backing = try CryptoKit.MLDSA65.PrivateKey()
        }

        public init(seedRepresentation: Data) throws {
            self.backing = try CryptoKit.MLDSA65.PrivateKey(seedRepresentation: seedRepresentation, publicKey: nil)
        }

        public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            let sigData = try backing.signature(for: data)
            return Signature(rawRepresentation: sigData)
        }
    }
}

// MARK: - ML-DSA-87

@available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *)
public enum MLDSA87SSH {

    public struct PublicKey: NIOSSHPublicKeyProtocol {
        public static let publicKeyPrefix = "ssh-mldsa87"
        public static var defaultHostKeyAlgorithms: [String]? { [] }

        private let backing: CryptoKit.MLDSA87.PublicKey

        public var rawRepresentation: Data {
            backing.rawRepresentation
        }

        public init(_ backing: CryptoKit.MLDSA87.PublicKey) {
            self.backing = backing
        }

        public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let signature = signature as? Signature else {
                return false
            }
            return backing.isValidSignature(signature.rawRepresentation, for: data)
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(backing.rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> PublicKey {
            guard let keyBuffer = buffer.readSSHBuffer() else {
                throw MLDSAError(message: "Invalid ML-DSA-87 public key format")
            }
            guard let keyData = keyBuffer.getData(at: 0, length: keyBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-87 public key data")
            }
            return try PublicKey(CryptoKit.MLDSA87.PublicKey(rawRepresentation: keyData))
        }
    }

    public struct Signature: NIOSSHSignatureProtocol {
        public static let signaturePrefix = "ssh-mldsa87"

        public let rawRepresentation: Data

        public init(rawRepresentation: Data) {
            self.rawRepresentation = rawRepresentation
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> Signature {
            guard let sigBuffer = buffer.readSSHBuffer() else {
                throw MLDSAError(message: "Invalid ML-DSA-87 signature format")
            }
            guard let sigData = sigBuffer.getData(at: 0, length: sigBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-87 signature data")
            }
            return Signature(rawRepresentation: sigData)
        }
    }

    public struct PrivateKey: NIOSSHPrivateKeyProtocol {
        public static let keyPrefix = "ssh-mldsa87"

        private let backing: CryptoKit.MLDSA87.PrivateKey

        public var publicKey: NIOSSHPublicKeyProtocol {
            PublicKey(backing.publicKey)
        }

        /// Typed accessor for the raw FIPS 204 public key bytes.
        public var mldsaPublicKey: PublicKey {
            PublicKey(backing.publicKey)
        }

        /// 32-byte FIPS 204 keygen seed — the durable representation.
        public var seedRepresentation: Data {
            backing.seedRepresentation
        }

        public init(_ backing: CryptoKit.MLDSA87.PrivateKey) {
            self.backing = backing
        }

        public init() throws {
            self.backing = try CryptoKit.MLDSA87.PrivateKey()
        }

        public init(seedRepresentation: Data) throws {
            self.backing = try CryptoKit.MLDSA87.PrivateKey(seedRepresentation: seedRepresentation, publicKey: nil)
        }

        public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            let sigData = try backing.signature(for: data)
            return Signature(rawRepresentation: sigData)
        }
    }
}

// MARK: - Error

public struct MLDSAError: Error {
    public let message: String
}
