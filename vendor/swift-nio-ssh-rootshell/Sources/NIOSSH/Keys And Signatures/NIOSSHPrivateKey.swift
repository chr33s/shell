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
import NIOCore

/// An SSH private key.
///
/// This object identifies a single SSH entity, usually a server. It is used as part of the SSH handshake and key exchange process,
/// and is also presented to clients that want to validate that they are communicating with the appropriate server. Clients use
/// this key to sign data in order to validate their identity as part of user auth.
///
/// Users cannot do much with this key other than construct it, but NIO uses it internally.
public struct NIOSSHPrivateKey {
    /// The actual key structure used to perform the key operations.
    internal var backingKey: BackingKey
    private var authenticationAlgorithmNameOverride: String? = nil

    private init(backingKey: BackingKey) {
        self.backingKey = backingKey
    }

    public init(ed25519Key key: Curve25519.Signing.PrivateKey) {
        self.backingKey = .ed25519(key)
    }

    public init(p256Key key: P256.Signing.PrivateKey) {
        self.backingKey = .ecdsaP256(key)
    }

    public init(p384Key key: P384.Signing.PrivateKey) {
        self.backingKey = .ecdsaP384(key)
    }

    public init(p521Key key: P521.Signing.PrivateKey) {
        self.backingKey = .ecdsaP521(key)
    }

    public init<PrivateKey: NIOSSHPrivateKeyProtocol>(custom key: PrivateKey) {
        self.backingKey = .custom(key)
    }

    #if canImport(Darwin)
    public init(secureEnclaveP256Key key: SecureEnclave.P256.Signing.PrivateKey) {
        self.backingKey = .secureEnclaveP256(key)
    }
    #endif

    /// The underlying Ed25519 private key, if this is an Ed25519 key.
    /// Exposed so callers that need to feed the raw scalar to non-SSH
    /// crypto code (e.g. GPG agent forwarding's PKSIGN, which produces
    /// the EdDSA signature directly rather than going through SSH wire
    /// format) can do so without re-parsing the key text.
    public var ed25519PrivateKey: Curve25519.Signing.PrivateKey? {
        if case .ed25519(let k) = backingKey { return k }
        return nil
    }

    /// The underlying P-256 ECDSA private key, if applicable. See
    /// ``ed25519PrivateKey`` for the rationale.
    public var p256PrivateKey: P256.Signing.PrivateKey? {
        if case .ecdsaP256(let k) = backingKey { return k }
        return nil
    }

    /// The underlying P-384 ECDSA private key, if applicable.
    public var p384PrivateKey: P384.Signing.PrivateKey? {
        if case .ecdsaP384(let k) = backingKey { return k }
        return nil
    }

    /// The underlying P-521 ECDSA private key, if applicable.
    public var p521PrivateKey: P521.Signing.PrivateKey? {
        if case .ecdsaP521(let k) = backingKey { return k }
        return nil
    }

    // The algorithms that apply to this host key.
    internal var hostKeyAlgorithms: [Substring] {
        switch self.backingKey {
        case .ed25519:
            return ["ssh-ed25519"]
        case .ecdsaP256:
            return ["ecdsa-sha2-nistp256"]
        case .ecdsaP384:
            return ["ecdsa-sha2-nistp384"]
        case .ecdsaP521:
            return ["ecdsa-sha2-nistp521"]
        case .custom(let backingKey):
            var seen = Set<Substring>()
            var algorithms: [Substring] = []
            for name in backingKey.hostKeyAlgorithms {
                let name = Substring(name)
                if seen.insert(name).inserted {
                    algorithms.append(name)
                }
            }
            return algorithms
        #if canImport(Darwin)
        case .secureEnclaveP256:
            return ["ecdsa-sha2-nistp256"]
        #endif
        }
    }
}

extension NIOSSHPrivateKey {
    /// The various key types that can be used with NIOSSH.
    enum BackingKey {
        case ed25519(Curve25519.Signing.PrivateKey)
        case ecdsaP256(P256.Signing.PrivateKey)
        case ecdsaP384(P384.Signing.PrivateKey)
        case ecdsaP521(P521.Signing.PrivateKey)
        case custom(NIOSSHPrivateKeyProtocol)

        #if canImport(Darwin)
        case secureEnclaveP256(SecureEnclave.P256.Signing.PrivateKey)
        #endif
    }
}

extension NIOSSHPrivateKey {
    public func sign<DigestBytes: Digest>(digest: DigestBytes) throws -> NIOSSHSignature {
        switch self.backingKey {
        case .ed25519(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ed25519(.data(signature)))
        case .ecdsaP256(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        case .ecdsaP384(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP384(signature))
        case .ecdsaP521(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP521(signature))
        case .custom(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                if let authenticationAlgorithmNameOverride {
                    return try key.signature(
                        for: ptr,
                        authenticationAlgorithmName: authenticationAlgorithmNameOverride
                    )
                }
                return try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .custom(signature))

        #if canImport(Darwin)
        case .secureEnclaveP256(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        #endif
        }
    }

    func selectingAuthenticationAlgorithm(_ name: Substring) -> Self {
        var copy = self
        copy.authenticationAlgorithmNameOverride = String(name)
        return copy
    }

    func sign(_ payload: UserAuthSignablePayload) throws -> NIOSSHSignature {
        switch self.backingKey {
        case .ed25519(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ed25519(.data(signature)))
        case .ecdsaP256(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        case .ecdsaP384(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP384(signature))
        case .ecdsaP521(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP521(signature))
        case .custom(let key):
            let signature: NIOSSHSignatureProtocol
            if let authenticationAlgorithmNameOverride {
                signature = try key.signature(
                    for: payload.bytes.readableBytesView,
                    authenticationAlgorithmName: authenticationAlgorithmNameOverride
                )
            } else {
                signature = try key.signature(for: payload.bytes.readableBytesView)
            }
            return NIOSSHSignature(backingSignature: .custom(signature))
        #if canImport(Darwin)
        case .secureEnclaveP256(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        #endif
        }
    }
}

public extension NIOSSHPrivateKey {
    /// Signs raw data using this private key.
    /// - Parameter data: The raw data to sign.
    /// - Returns: The signature.
    /// - Throws: If signing fails.
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignature {
        switch self.backingKey {
        case .ed25519(let key):
            let signature = try key.signature(for: data)
            return NIOSSHSignature(backingSignature: .ed25519(.data(signature)))
        case .ecdsaP256(let key):
            let signature = try key.signature(for: data)
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        case .ecdsaP384(let key):
            let signature = try key.signature(for: data)
            return NIOSSHSignature(backingSignature: .ecdsaP384(signature))
        case .ecdsaP521(let key):
            let signature = try key.signature(for: data)
            return NIOSSHSignature(backingSignature: .ecdsaP521(signature))
        case .custom(let key):
            let signature = try key.signature(for: data)
            return NIOSSHSignature(backingSignature: .custom(signature))
        #if canImport(Darwin)
        case .secureEnclaveP256(let key):
            let signature = try key.signature(for: data)
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        #endif
        }
    }

    /// Obtains the public key for a corresponding private key.
    var publicKey: NIOSSHPublicKey {
        switch self.backingKey {
        case .ed25519(let privateKey):
            return NIOSSHPublicKey(backingKey: .ed25519(privateKey.publicKey))
        case .ecdsaP256(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP256(privateKey.publicKey))
        case .ecdsaP384(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP384(privateKey.publicKey))
        case .ecdsaP521(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP521(privateKey.publicKey))
        case .custom(let privateKey):
            return NIOSSHPublicKey(backingKey: .custom(privateKey.publicKey))
        #if canImport(Darwin)
        case .secureEnclaveP256(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP256(privateKey.publicKey))
        #endif
        }
    }
}
