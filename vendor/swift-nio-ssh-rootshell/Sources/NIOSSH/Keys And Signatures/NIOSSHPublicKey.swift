//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat

/// An SSH public key.
///
/// This object identifies a single SSH server or user. It is used as part of the SSH handshake and key exchange process,
/// is presented to clients that want to validate that they are communicating with the appropriate server, and is also used
/// to validate users.
///
/// This key is not capable of signing, only verifying.
public struct NIOSSHPublicKey: Hashable {
    /// The actual key structure used to perform the key operations.
    internal var backingKey: BackingKey

    internal init(backingKey: BackingKey) {
        self.backingKey = backingKey
    }

    /// Create a ``NIOSSHPublicKey`` from the OpenSSH public key string.
    public init(openSSHPublicKey: String) throws {
        // The OpenSSH public key format is like this: "algorithm-id base64-encoded-key comments"
        //
        // We split on spaces, no more than twice. We then check if we know about the algorithm identifier and, if we
        // do, we parse the key.
        var components = ArraySlice(openSSHPublicKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true))
        guard let keyIdentifier = components.popFirst(), let keyData = components.popFirst() else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "invalid number of sections")
        }
        guard let rawBytes = Data(base64Encoded: String(keyData)) else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "could not base64-decode string")
        }

        var buffer = ByteBufferAllocator().buffer(capacity: rawBytes.count)
        buffer.writeContiguousBytes(rawBytes)
        guard let key = try buffer.readSSHHostKey() else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "incomplete key data")
        }
        guard key.keyPrefix.elementsEqual(keyIdentifier.utf8) else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "inconsistent key type within openssh key format")
        }
        self = key
    }

    /// Encapsulate a ``NIOSSHCertifiedPublicKey`` in a ``NIOSSHPublicKey``.
    ///
    /// This initializer can be used to "wrap" a ``NIOSSHCertifiedPublicKey`` into the interface of ``NIOSSHPublicKey``.
    /// It is typically used in cases where the fact that the key is certified is not relevant.
    public init(_ certifiedKey: NIOSSHCertifiedPublicKey) {
        self.backingKey = .certified(certifiedKey)
    }
}

extension NIOSSHPublicKey {
    /// Verifies that a given `NIOSSHSignature` was created by the holder of the private key associated with this
    /// public key.
    public func isValidSignature<DigestBytes: Digest>(_ signature: NIOSSHSignature, for digest: DigestBytes) -> Bool {
        switch (self.backingKey, signature.backingSignature) {
        case (.ed25519(let key), .ed25519(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                switch sig {
                case .byteBuffer(let buf):
                    return key.isValidSignature(buf.readableBytesView, for: digestPtr)
                case .data(let d):
                    return key.isValidSignature(d, for: digestPtr)
                }
            }
        case (.ecdsaP256(let key), .ecdsaP256(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                key.isValidSignature(sig, for: digestPtr)
            }
        case (.ecdsaP384(let key), .ecdsaP384(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                key.isValidSignature(sig, for: digestPtr)
            }
        case (.ecdsaP521(let key), .ecdsaP521(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                key.isValidSignature(sig, for: digestPtr)
            }
        case (.custom(let key), .custom(let sig)):
            return digest.withUnsafeBytes { digestPtr in
                key.isValidSignature(sig, for: digestPtr)
            }
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: digest)
        case (.ed25519, _),
             (.ecdsaP256, _),
             (.ecdsaP384, _),
             (.ecdsaP521, _),
             (.custom, _):
            return false
        }
    }

    internal func isValidSignature(_ signature: NIOSSHSignature, for bytes: ByteBuffer) -> Bool {
        switch (self.backingKey, signature.backingSignature) {
        case (.ed25519(let key), .ed25519(.byteBuffer(let buf))):
            return key.isValidSignature(buf.readableBytesView, for: bytes.readableBytesView)
        case (.ed25519(let key), .ed25519(.data(let buf))):
            return key.isValidSignature(buf, for: bytes.readableBytesView)
        case (.ecdsaP256(let key), .ecdsaP256(let sig)):
            return key.isValidSignature(sig, for: bytes.readableBytesView)
        case (.ecdsaP384(let key), .ecdsaP384(let sig)):
            return key.isValidSignature(sig, for: bytes.readableBytesView)
        case (.ecdsaP521(let key), .ecdsaP521(let sig)):
            return key.isValidSignature(sig, for: bytes.readableBytesView)
        case (.custom(let key), .custom(let sig)):
            return key.isValidSignature(sig, for: bytes.readableBytesView)
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: bytes)
        case (.ed25519, _),
             (.ecdsaP256, _),
             (.ecdsaP384, _),
             (.ecdsaP521, _),
             (.custom, _):
            return false
        }
    }

    internal func isValidSignature(_ signature: NIOSSHSignature, for payload: UserAuthSignablePayload) -> Bool {
        switch (self.backingKey, signature.backingSignature) {
        case (.ed25519(let key), .ed25519(.byteBuffer(let sig))):
            return key.isValidSignature(sig.readableBytesView, for: payload.bytes.readableBytesView)
        case (.ed25519(let key), .ed25519(.data(let sig))):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.ecdsaP256(let key), .ecdsaP256(let sig)):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.ecdsaP384(let key), .ecdsaP384(let sig)):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.ecdsaP521(let key), .ecdsaP521(let sig)):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.custom(let key), .custom(let sig)):
            return key.isValidSignature(sig, for: payload.bytes.readableBytesView)
        case (.certified(let key), _):
            return key.isValidSignature(signature, for: payload)
        case (.ed25519, _),
             (.ecdsaP256, _),
             (.ecdsaP384, _),
             (.ecdsaP521, _),
             (.custom, _):
            return false
        }
    }
}

extension NIOSSHPublicKey {
    /// The various key types that can be used with NIOSSH.
    enum BackingKey {
        case ed25519(Curve25519.Signing.PublicKey)
        case ecdsaP256(P256.Signing.PublicKey)
        case ecdsaP384(P384.Signing.PublicKey)
        case ecdsaP521(P521.Signing.PublicKey)
        case custom(NIOSSHPublicKeyProtocol)
        case certified(NIOSSHCertifiedPublicKey) // This case recursively contains `NIOSSHPublicKey`.
    }

    /// The prefix of an Ed25519 public key.
    static let ed25519PublicKeyPrefix = "ssh-ed25519".utf8

    /// The prefix of a P256 ECDSA public key.
    static let ecdsaP256PublicKeyPrefix = "ecdsa-sha2-nistp256".utf8

    /// The prefix of a P384 ECDSA public key.
    static let ecdsaP384PublicKeyPrefix = "ecdsa-sha2-nistp384".utf8

    /// The prefix of a P521 ECDSA public key.
    static let ecdsaP521PublicKeyPrefix = "ecdsa-sha2-nistp521".utf8

    var keyPrefix: String.UTF8View {
        switch self.backingKey {
        case .ed25519:
            return Self.ed25519PublicKeyPrefix
        case .ecdsaP256:
            return Self.ecdsaP256PublicKeyPrefix
        case .ecdsaP384:
            return Self.ecdsaP384PublicKeyPrefix
        case .ecdsaP521:
            return Self.ecdsaP521PublicKeyPrefix
        case .custom(let publicKey):
            return publicKey.publicKeyPrefix.utf8
        case .certified(let base):
            return base.keyPrefix
        }
    }

    var authAlgorithmName: String.UTF8View {
        switch self.backingKey {
        case .ed25519:
            return Self.ed25519PublicKeyPrefix
        case .ecdsaP256:
            return Self.ecdsaP256PublicKeyPrefix
        case .ecdsaP384:
            return Self.ecdsaP384PublicKeyPrefix
        case .ecdsaP521:
            return Self.ecdsaP521PublicKeyPrefix
        case .custom(let publicKey):
            return publicKey.authAlgorithmName.utf8
        case .certified(let base):
            return base.authAlgorithmName
        }
    }

    func isValidAuthenticationAlgorithmName<Bytes: Collection>(_ algorithmName: Bytes) -> Bool where Bytes.Element == UInt8 {
        algorithmName.elementsEqual(self.keyPrefix) || algorithmName.elementsEqual(self.authAlgorithmName)
    }

    func matchesRegisteredSignature(
        _ signature: NIOSSHSignatureProtocol,
        authenticationAlgorithmName: String
    ) -> Bool {
        let customKey: NIOSSHPublicKeyProtocol
        switch self.backingKey {
        case .custom(let key):
            customKey = key
        case .certified(let certifiedKey):
            guard case .custom(let key) = certifiedKey.key.backingKey else {
                return false
            }
            customKey = key
        default:
            return false
        }

        let registrations = (
            Self.preferredPublicKeyRegistrations + Self.customPublicKeyRegistrations
        ).filter {
            ObjectIdentifier($0.publicKey) == ObjectIdentifier(Swift.type(of: customKey))
        }
        guard let keyType = registrations.first?.publicKey,
              registrations.lazy.flatMap(\.signatures).contains(where: {
                  ObjectIdentifier($0) == ObjectIdentifier(Swift.type(of: signature))
              })
        else {
            return false
        }

        let validAuthenticationNames = [
            keyType.authAlgorithmName,
            keyType.publicKeyPrefix,
            keyType.certifiedAuthAlgorithmName,
            keyType.certifiedKeyPrefix,
        ].compactMap { $0 }
        guard validAuthenticationNames.contains(authenticationAlgorithmName) else {
            return false
        }

        let signatureName = signature.signaturePrefix
        if authenticationAlgorithmName == signatureName {
            return true
        }
        if authenticationAlgorithmName == keyType.certifiedAuthAlgorithmName,
           signatureName == keyType.authAlgorithmName {
            return true
        }
        if authenticationAlgorithmName == keyType.certifiedKeyPrefix,
           signatureName == keyType.publicKeyPrefix {
            return true
        }
        return false
    }

    private static let bundledAlgorithms: [String.UTF8View] = [
        Self.ed25519PublicKeyPrefix, Self.ecdsaP384PublicKeyPrefix, Self.ecdsaP256PublicKeyPrefix, Self.ecdsaP521PublicKeyPrefix,
    ]

    /// The OpenSSH certificate algorithm names for the bundled key types.
    private static let bundledCertificateAlgorithms: [String.UTF8View] = [
        NIOSSHCertifiedPublicKey.ed25519KeyPrefix,
        NIOSSHCertifiedPublicKey.p384KeyPrefix,
        NIOSSHCertifiedPublicKey.p256KeyPrefix,
        NIOSSHCertifiedPublicKey.p521KeyPrefix,
    ]

    static var knownAlgorithms: [String.UTF8View] {
        var algorithms = [String.UTF8View]()

        func appendUnique(_ algorithm: String) {
            if !algorithms.contains(where: { $0.elementsEqual(algorithm.utf8) }) {
                algorithms.append(algorithm.utf8)
            }
        }

        func appendCustomRegistration(_ registration: CustomPublicKeyRegistration) {
            let algorithm = registration.publicKey
            let validPlainNames = [algorithm.authAlgorithmName, algorithm.publicKeyPrefix]
            for signature in registration.signatures where validPlainNames.contains(signature.signaturePrefix) {
                appendUnique(signature.signaturePrefix)
            }
            // Prefer the certificate authentication algorithm over its legacy blob
            // type when they differ (for example RSA SHA-2 versus ssh-rsa).
            if let certPrefix = algorithm.certifiedKeyPrefix {
                if let certAuthName = algorithm.certifiedAuthAlgorithmName, certAuthName != certPrefix {
                    appendUnique(certAuthName)
                }
                appendUnique(certPrefix)
            }
        }

        // Preferred custom algorithms go first (highest priority)
        for registration in preferredPublicKeyRegistrations {
            appendCustomRegistration(registration)
        }

        // Then bundled algorithms (ed25519, ecdsa) and their certificate variants
        algorithms.append(contentsOf: bundledAlgorithms)
        algorithms.append(contentsOf: bundledCertificateAlgorithms)

        // Then regular custom algorithms (appended after bundled)
        for registration in customPublicKeyRegistrations {
            appendCustomRegistration(registration)
        }
        return algorithms
    }

    static var preferredPublicKeyRegistrations: [CustomPublicKeyRegistration] {
        _CustomAlgorithms.preferredPublicKeyAlgorithmsLock.withLock {
            _CustomAlgorithms.preferredPublicKeyRegistrations
        }
    }

    static var preferredPublicKeyAlgorithms: [NIOSSHPublicKeyProtocol.Type] {
        preferredPublicKeyRegistrations.map(\.publicKey)
    }

    static var preferredSignatures: [NIOSSHSignatureProtocol.Type] {
        Self.uniqueSignatures(preferredPublicKeyRegistrations.flatMap(\.signatures))
    }

    static var customPublicKeyRegistrations: [CustomPublicKeyRegistration] {
        _CustomAlgorithms.publicKeyAlgorithmsLock.withLock {
            _CustomAlgorithms.publicKeyRegistrations
        }
    }

    static var customPublicKeyAlgorithms: [NIOSSHPublicKeyProtocol.Type] {
        customPublicKeyRegistrations.map(\.publicKey)
    }

    static var customSignatures: [NIOSSHSignatureProtocol.Type] {
        Self.uniqueSignatures(customPublicKeyRegistrations.flatMap(\.signatures))
    }

    private static func uniqueSignatures(
        _ signatures: [NIOSSHSignatureProtocol.Type]
    ) -> [NIOSSHSignatureProtocol.Type] {
        var seen = Set<ObjectIdentifier>()
        return signatures.filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    /// All custom public key algorithms (preferred + regular), used for parsing.
    static var allCustomPublicKeyAlgorithms: [NIOSSHPublicKeyProtocol.Type] {
        preferredPublicKeyAlgorithms + customPublicKeyAlgorithms
    }

    /// All custom signatures (preferred + regular), used for parsing.
    static var allCustomSignatures: [NIOSSHSignatureProtocol.Type] {
        Self.uniqueSignatures(preferredSignatures + customSignatures)
    }

    /// Every public-key algorithm accepted during user authentication.
    /// RFC 8308's `server-sig-algs` extension requires algorithm names, not
    /// merely the underlying signature encodings, so certificate names belong
    /// here too.
    static var supportedUserAuthenticationAlgorithms: [Substring] {
        knownAlgorithms.map { Substring(String($0)) }
    }
}

struct CustomPublicKeyRegistration {
    let publicKey: NIOSSHPublicKeyProtocol.Type
    var signatures: [NIOSSHSignatureProtocol.Type]
}

public enum NIOSSHAlgorithms {
    public static func register(keyExchangeAlgorithm type: NIOSSHKeyExchangeAlgorithmProtocol.Type) {
        _CustomAlgorithms.keyExchangeAlgorithmsLock.withLockVoid {
            if !_CustomAlgorithms.keyExchangeAlgorithms.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(type) }) {
                _CustomAlgorithms.keyExchangeAlgorithms.append(type)
            }
        }
    }

    public static func register(transportProtectionScheme type: NIOSSHTransportProtection.Type) {
        _CustomAlgorithms.transportProtectionSchemesLock.withLockVoid {
            if !_CustomAlgorithms.transportProtectionSchemes.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(type) }) {
                _CustomAlgorithms.transportProtectionSchemes.append(type)
            }
        }
    }

    /// Registers a custom type tuple for use in Public Key Authentication.
    public static func register<
        PublicKey: NIOSSHPublicKeyProtocol,
        Signature: NIOSSHSignatureProtocol
    >(
        publicKey type: PublicKey.Type,
        signature: Signature.Type
    ) {
        self.register(publicKey: type, signatures: [signature])
    }

    /// Atomically registers a custom public-key parser and every signature
    /// parser that may accompany it.
    ///
    /// Use this overload when one wire key format supports multiple signature
    /// algorithms, such as RSA SHA-2 plus legacy RSA/SHA-1.
    public static func register(
        publicKey type: NIOSSHPublicKeyProtocol.Type,
        signatures: [NIOSSHSignatureProtocol.Type]
    ) {
        _CustomAlgorithms.publicKeyAlgorithmsLock.withLockVoid {
            Self.mergeRegistration(
                publicKey: type,
                signatures: signatures,
                into: &_CustomAlgorithms.publicKeyRegistrations
            )
        }
    }

    /// Registers a preferred (highest priority) custom type tuple for Public Key Authentication.
    /// Preferred algorithms are advertised before NIOSSH's built-in algorithms during negotiation.
    public static func registerPreferred<
        PublicKey: NIOSSHPublicKeyProtocol,
        Signature: NIOSSHSignatureProtocol
    >(
        publicKey type: PublicKey.Type,
        signature: Signature.Type
    ) {
        self.registerPreferred(publicKey: type, signatures: [signature])
    }

    /// Atomically registers a preferred custom public-key parser and all of
    /// its signature parsers.
    public static func registerPreferred(
        publicKey type: NIOSSHPublicKeyProtocol.Type,
        signatures: [NIOSSHSignatureProtocol.Type]
    ) {
        _CustomAlgorithms.preferredPublicKeyAlgorithmsLock.withLockVoid {
            Self.mergeRegistration(
                publicKey: type,
                signatures: signatures,
                into: &_CustomAlgorithms.preferredPublicKeyRegistrations
            )
        }
    }

    private static func mergeRegistration(
        publicKey: NIOSSHPublicKeyProtocol.Type,
        signatures: [NIOSSHSignatureProtocol.Type],
        into registrations: inout [CustomPublicKeyRegistration]
    ) {
        guard !signatures.isEmpty else {
            return
        }

        if let index = registrations.firstIndex(where: {
            ObjectIdentifier($0.publicKey) == ObjectIdentifier(publicKey)
        }) {
            for signature in signatures where !registrations[index].signatures.contains(where: {
                ObjectIdentifier($0) == ObjectIdentifier(signature)
            }) {
                registrations[index].signatures.append(signature)
            }
        } else {
            registrations.append(CustomPublicKeyRegistration(
                publicKey: publicKey,
                signatures: signatures
            ))
        }
    }

    /// Used for our unit tests
    internal static func unregisterAlgorithms() {
        _CustomAlgorithms.transportProtectionSchemesLock.withLockVoid {
            _CustomAlgorithms.transportProtectionSchemes = []
        }
        _CustomAlgorithms.preferredPublicKeyAlgorithmsLock.withLockVoid {
            _CustomAlgorithms.preferredPublicKeyRegistrations = []
        }
        _CustomAlgorithms.publicKeyAlgorithmsLock.withLockVoid {
            _CustomAlgorithms.publicKeyRegistrations = []
        }
        _CustomAlgorithms.keyExchangeAlgorithmsLock.withLockVoid {
            _CustomAlgorithms.keyExchangeAlgorithms = []
        }
    }
}

internal var customTransportProtectionSchemes: [NIOSSHTransportProtection.Type] {
    _CustomAlgorithms.transportProtectionSchemesLock.withLock {
        _CustomAlgorithms.transportProtectionSchemes
    }
}

internal var customKeyExchangeAlgorithms: [NIOSSHKeyExchangeAlgorithmProtocol.Type] {
    _CustomAlgorithms.keyExchangeAlgorithmsLock.withLock {
        _CustomAlgorithms.keyExchangeAlgorithms
    }
}

private enum _CustomAlgorithms {
    static var transportProtectionSchemesLock = NIOLock()
    static var transportProtectionSchemes = [NIOSSHTransportProtection.Type]()
    static var keyExchangeAlgorithmsLock = NIOLock()
    static var keyExchangeAlgorithms = [NIOSSHKeyExchangeAlgorithmProtocol.Type]()
    static var preferredPublicKeyAlgorithmsLock = NIOLock()
    static var preferredPublicKeyRegistrations: [CustomPublicKeyRegistration] = []
    static var publicKeyAlgorithmsLock = NIOLock()
    static var publicKeyRegistrations: [CustomPublicKeyRegistration] = []
}

extension NIOSSHPublicKey.BackingKey: Equatable {
    static func == (lhs: NIOSSHPublicKey.BackingKey, rhs: NIOSSHPublicKey.BackingKey) -> Bool {
        // We implement equatable in terms of the key representation.
        switch (lhs, rhs) {
        case (.ed25519(let lhs), .ed25519(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.ecdsaP256(let lhs), .ecdsaP256(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.ecdsaP384(let lhs), .ecdsaP384(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.ecdsaP521(let lhs), .ecdsaP521(let rhs)):
            return lhs.rawRepresentation == rhs.rawRepresentation
        case (.custom(let lhs), .custom(let rhs)):
            return
                lhs.publicKeyPrefix == rhs.publicKeyPrefix &&
                lhs.rawRepresentation == rhs.rawRepresentation
        case (.certified(let lhs), .certified(let rhs)):
            return lhs == rhs
        case (.ed25519, _),
             (.ecdsaP256, _),
             (.ecdsaP384, _),
             (.ecdsaP521, _),
             (.custom, _),
             (.certified, _):
            return false
        }
    }
}

extension NIOSSHPublicKey.BackingKey: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .ed25519(let pkey):
            hasher.combine(1)
            hasher.combine(pkey.rawRepresentation)
        case .ecdsaP256(let pkey):
            hasher.combine(2)
            hasher.combine(pkey.rawRepresentation)
        case .ecdsaP384(let pkey):
            hasher.combine(3)
            hasher.combine(pkey.rawRepresentation)
        case .ecdsaP521(let pkey):
            hasher.combine(4)
            hasher.combine(pkey.rawRepresentation)
        case .custom(let pkey):
            hasher.combine(5)
            hasher.combine(pkey.publicKeyPrefix)
            hasher.combine(pkey.rawRepresentation)
        case .certified(let pkey):
            hasher.combine(6)
            hasher.combine(pkey)
        }
    }
}

extension NIOSSHPublicKey {
    @discardableResult
    public func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHHostKey(self)
    }

    @discardableResult
    func writeWithoutHeader(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHHostKeyWithoutHeader(self)
    }

    /// True when both keys serialize to the same SSH wire blob.
    ///
    /// `==` compares within a backing only: a key parsed off the wire uses
    /// the bundled backing for bundled algorithms, so it never compares
    /// equal to the same key held in a `.custom` backing (external signers
    /// such as hardware tokens or ssh-agents). Offer/echo checks like
    /// USERAUTH_PK_OK must compare the canonical serialization instead.
    func hasSameWireRepresentation(as other: NIOSSHPublicKey) -> Bool {
        if self == other {
            return true
        }
        var lhs = ByteBufferAllocator().buffer(capacity: 512)
        var rhs = ByteBufferAllocator().buffer(capacity: 512)
        lhs.writeSSHHostKey(self)
        rhs.writeSSHHostKey(other)
        return lhs.readableBytesView.elementsEqual(rhs.readableBytesView)
    }
}

extension ByteBuffer {
    @discardableResult
    mutating func writeSSHHostKeyWithoutHeader(_ key: NIOSSHPublicKey) -> Int {
        switch key.backingKey {
        case .ed25519(let key):
            return self.writeEd25519PublicKey(baseKey: key)
        case .ecdsaP256(let key):
            return self.writeECDSAP256PublicKey(baseKey: key)
        case .ecdsaP384(let key):
            return self.writeECDSAP384PublicKey(baseKey: key)
        case .ecdsaP521(let key):
            return self.writeECDSAP521PublicKey(baseKey: key)
        case .custom(let key):
            return key.write(to: &self)
        case .certified(let key):
            return self.writeCertifiedKey(key)
        }
    }

    /// Writes an SSH host key to this `ByteBuffer`.
    @discardableResult
    mutating func writeSSHHostKey(_ key: NIOSSHPublicKey) -> Int {
        var writtenBytes = 0

        switch key.backingKey {
        case .ed25519(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ed25519PublicKeyPrefix)
            writtenBytes += self.writeEd25519PublicKey(baseKey: key)
        case .ecdsaP256(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP256PublicKeyPrefix)
            writtenBytes += self.writeECDSAP256PublicKey(baseKey: key)
        case .ecdsaP384(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP384PublicKeyPrefix)
            writtenBytes += self.writeECDSAP384PublicKey(baseKey: key)
        case .ecdsaP521(let key):
            writtenBytes += self.writeSSHString(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix)
            writtenBytes += self.writeECDSAP521PublicKey(baseKey: key)
        case .custom(let key):
            writtenBytes += writeSSHString(key.publicKeyPrefix.utf8)
            writtenBytes += key.write(to: &self)
        case .certified(let key):
            return self.writeCertifiedKey(key)
        }

        return writtenBytes
    }

    /// Writes an SSH host key to this `ByteBuffer`, without a prefix.
    ///
    /// This is mostly used as part of the certified key structure.
    @discardableResult
    mutating func writePublicKeyWithoutPrefix(_ key: NIOSSHPublicKey) -> Int {
        switch key.backingKey {
        case .ed25519(let key):
            return self.writeEd25519PublicKey(baseKey: key)
        case .ecdsaP256(let key):
            return self.writeECDSAP256PublicKey(baseKey: key)
        case .ecdsaP384(let key):
            return self.writeECDSAP384PublicKey(baseKey: key)
        case .ecdsaP521(let key):
            return self.writeECDSAP521PublicKey(baseKey: key)
        case .custom(let key):
            // Certificates embed the key-specific components directly, with NO inner
            // type string (PROTOCOL.certkeys) — same as the built-in key types above.
            return key.write(to: &self)
        case .certified:
            preconditionFailure("Certified keys are the only callers of this method, and cannot contain themselves")
        }
    }

    mutating func readSSHHostKey() throws -> NIOSSHPublicKey? {
        try self.rewindOnNilOrError { buffer in
            // The wire format always begins with an SSH string containing the key format identifier. Let's grab that.
            guard let keyIdentifierBytes = buffer.readSSHString() else {
                return nil
            }

            // Now we need to check if they match our supported key algorithms.
            return try buffer.readPublicKeyWithoutPrefixForIdentifier(keyIdentifierBytes.readableBytesView)
        }
    }

    mutating func readPublicKeyWithoutPrefixForIdentifier<Bytes: Collection>(_ keyIdentifierBytes: Bytes) throws -> NIOSSHPublicKey? where Bytes.Element == UInt8 {
        try self.rewindOnNilOrError { buffer in
            if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ed25519PublicKeyPrefix) {
                return try buffer.readEd25519PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP256PublicKeyPrefix) {
                return try buffer.readECDSAP256PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP384PublicKeyPrefix) {
                return try buffer.readECDSAP384PublicKey()
            } else if keyIdentifierBytes.elementsEqual(NIOSSHPublicKey.ecdsaP521PublicKeyPrefix) {
                return try buffer.readECDSAP521PublicKey()
            } else {
                var firstParserError: Error?
                for type in NIOSSHPublicKey.allCustomPublicKeyAlgorithms {
                    if keyIdentifierBytes.elementsEqual(type.publicKeyPrefix.utf8) {
                        var candidateBuffer = buffer
                        do {
                            let publicKey = try type.read(from: &candidateBuffer)
                            buffer = candidateBuffer
                            return NIOSSHPublicKey(backingKey: .custom(publicKey))
                        } catch {
                            firstParserError = firstParserError ?? error
                        }
                    }
                }

                if let firstParserError {
                    throw firstParserError
                }

                // We don't know this public key type. Maybe the certified keys do.
                return try buffer.readCertifiedKeyWithoutKeyPrefix(keyIdentifierBytes).map(NIOSSHPublicKey.init)
            }
        }
    }

    private mutating func writeEd25519PublicKey(baseKey: Curve25519.Signing.PublicKey) -> Int {
        // For Ed25519 the key format is  Q as a String.
        self.writeSSHString(baseKey.rawRepresentation)
    }

    private mutating func writeECDSAP256PublicKey(baseKey: P256.Signing.PublicKey) -> Int {
        // For ECDSA-P256, the key format is the string "nistp256", followed by the
        // the public point Q.
        var writtenBytes = 0
        writtenBytes += self.writeSSHString("nistp256".utf8)
        writtenBytes += self.writeSSHString(baseKey.x963Representation)
        return writtenBytes
    }

    private mutating func writeECDSAP384PublicKey(baseKey: P384.Signing.PublicKey) -> Int {
        // For ECDSA-P384, the key format is the string "nistp384", followed by the
        // the public point Q.
        var writtenBytes = 0
        writtenBytes += self.writeSSHString("nistp384".utf8)
        writtenBytes += self.writeSSHString(baseKey.x963Representation)
        return writtenBytes
    }

    private mutating func writeECDSAP521PublicKey(baseKey: P521.Signing.PublicKey) -> Int {
        // For ECDSA-P521, the key format is the string "nistp521", followed by the
        // the public point Q.
        var writtenBytes = 0
        writtenBytes += self.writeSSHString("nistp521".utf8)
        writtenBytes += self.writeSSHString(baseKey.x963Representation)
        return writtenBytes
    }

    /// A helper function that reads an Ed25519 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readEd25519PublicKey() throws -> NIOSSHPublicKey? {
        // For ed25519 the key format is just Q encoded as a String.
        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try Curve25519.Signing.PublicKey(rawRepresentation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ed25519(key))
    }

    /// A helper function that reads an ECDSA P-256 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readECDSAP256PublicKey() throws -> NIOSSHPublicKey? {
        // For ECDSA-P256, the key format is the string "nistp256" followed by the
        // the public point Q.
        guard var domainParameter = self.readSSHString() else {
            return nil
        }
        guard domainParameter.readableBytesView.elementsEqual("nistp256".utf8) else {
            let unexpectedParameter = domainParameter.readString(length: domainParameter.readableBytes) ?? "<unknown domain parameter>"
            throw NIOSSHError.invalidDomainParametersForKey(parameters: unexpectedParameter)
        }

        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try P256.Signing.PublicKey(x963Representation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ecdsaP256(key))
    }

    /// A helper function that reads an ECDSA P-384 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readECDSAP384PublicKey() throws -> NIOSSHPublicKey? {
        // For ECDSA-P384, the key format is the string "nistp384" followed by the
        // the public point Q.
        guard var domainParameter = self.readSSHString() else {
            return nil
        }
        guard domainParameter.readableBytesView.elementsEqual("nistp384".utf8) else {
            let unexpectedParameter = domainParameter.readString(length: domainParameter.readableBytes) ?? "<unknown domain parameter>"
            throw NIOSSHError.invalidDomainParametersForKey(parameters: unexpectedParameter)
        }

        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try P384.Signing.PublicKey(x963Representation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ecdsaP384(key))
    }

    /// A helper function that reads an ECDSA P-521 public key.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    private mutating func readECDSAP521PublicKey() throws -> NIOSSHPublicKey? {
        // For ECDSA-P521, the key format is the string "nistp521" followed by the
        // the public point Q.
        guard var domainParameter = self.readSSHString() else {
            return nil
        }
        guard domainParameter.readableBytesView.elementsEqual("nistp521".utf8) else {
            let unexpectedParameter = domainParameter.readString(length: domainParameter.readableBytes) ?? "<unknown domain parameter>"
            throw NIOSSHError.invalidDomainParametersForKey(parameters: unexpectedParameter)
        }

        guard let qBytes = self.readSSHString() else {
            return nil
        }

        let key = try P521.Signing.PublicKey(x963Representation: qBytes.readableBytesView)
        return NIOSSHPublicKey(backingKey: .ecdsaP521(key))
    }

    /// A helper function for complex readers that will reset a buffer on nil or on error, as though the read
    /// never occurred.
    internal mutating func rewindOnNilOrError<T>(_ body: (inout ByteBuffer) throws -> T?) rethrows -> T? {
        let originalSelf = self

        let returnValue: T?
        do {
            returnValue = try body(&self)
        } catch {
            self = originalSelf
            throw error
        }

        if returnValue == nil {
            self = originalSelf
        }

        return returnValue
    }
}

extension String {
    /// Takes a NIOSSHPublicKey and turns it into OpenSSH public key string in the format of "algorithm-id base64-encoded-key"
    public init(openSSHPublicKey: NIOSSHPublicKey) {
        var buffer = ByteBuffer()
        buffer.writeSSHHostKey(openSSHPublicKey)
        let next = Data(buffer.readableBytesView).base64EncodedString()
        let publicKeyString = String(openSSHPublicKey.keyPrefix) + " " + next
        self = publicKeyString
    }
}
