//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore

/// A signature is a mathematical scheme for verifying the authenticity of digital messages or documents.
///
/// This protocol can be implemented by a type that represents such a signature to NIOSSH.
///
/// - See: https://en.wikipedia.org/wiki/Digital_signature
public protocol NIOSSHSignatureProtocol {
    /// An identifier that represents the type of signature used in an SSH packet.
    /// This identifier MUST be unique to the signature implementation.
    /// The returned value MUST NOT overlap with other signature implementations or a specifications that the signature does not implement.
    static var signaturePrefix: String { get }

    /// The raw reprentation of this signature as a blob.
    var rawRepresentation: Data { get }

    /// Serializes and writes the signature to the buffer. The calling function SHOULD NOT keep track of the size of the written blob.
    /// If the result is not a fixed size, the serialized format SHOULD include a length.
    func write(to buffer: inout ByteBuffer) -> Int

    /// Reads this Signature from the buffer using the same format implemented in `write(to:)`
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

internal extension NIOSSHSignatureProtocol {
    var signaturePrefix: String {
        Self.signaturePrefix
    }
}

public protocol NIOSSHPublicKeyProtocol {
    /// An identifier that represents the type of public key used in an SSH packet.
    /// This identifier MUST be unique to the public key implementation.
    /// The returned value MUST NOT overlap with other public key implementations or a specifications that the public key does not implement.
    static var publicKeyPrefix: String { get }

    /// The public key algorithm name advertised and used for authentication.
    ///
    /// This may differ from ``publicKeyPrefix`` when one key format supports
    /// multiple signature algorithms, as RSA does with `rsa-sha2-256` and
    /// the legacy `ssh-rsa` format. Defaults to ``publicKeyPrefix``.
    static var authAlgorithmName: String { get }

    /// The OpenSSH certificate type name for this key type (e.g. `ssh-rsa-cert-v01@openssh.com`).
    ///
    /// When non-nil, ``NIOSSHCertifiedPublicKey`` can parse and serialize OpenSSH certificates whose
    /// embedded key is of this type: the certificate's key-specific components are read and written via
    /// this type's `read(from:)`/`write(to:)` (with no inner type string, per `PROTOCOL.certkeys`).
    ///
    /// Defaults to `nil`, meaning this key type does not support OpenSSH certificates. This is a
    /// protocol requirement (with a default) rather than a plain extension member so lookups through
    /// `NIOSSHPublicKeyProtocol.Type` existentials dispatch to the conforming type's value.
    static var certifiedKeyPrefix: String? { get }

    /// The public key algorithm name sent in SSH_MSG_USERAUTH_REQUEST when a certificate built on this
    /// key type is used for user authentication. Defaults to ``certifiedKeyPrefix``.
    ///
    /// RSA keys must override this to `rsa-sha2-256-cert-v01@openssh.com` (RFC 8332 section 3.2): the
    /// certificate blob's type string stays `ssh-rsa-cert-v01@openssh.com` while the userauth request
    /// names the SHA-2 cert algorithm.
    static var certifiedAuthAlgorithmName: String? { get }

    /// Restricts default host-key proposals to these signature names. `nil`
    /// permits all registered matching signatures; `[]` keeps a parser available
    /// without advertising it. Explicit preferred registration overrides this.
    static var defaultHostKeyAlgorithms: [String]? { get }

    /// Opts custom certificates into host authentication after interoperability
    /// validation. Parsing/user certificates alone do not imply this capability.
    static var supportsHostCertificates: Bool { get }

    /// The raw reprentation of this publc key as a blob.
    var rawRepresentation: Data { get }

    /// Verifies that `signature` is the result of signing `data` using the private key that this public key is derived from.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool

    /// Serializes and writes the public key to the buffer. The calling function SHOULD NOT keep track of the size of the written blob.
    /// If the result is not a fixed size, the serialized format SHOULD include a length.
    func write(to buffer: inout ByteBuffer) -> Int

    /// Reads this Public Key from the buffer using the same format implemented in `write(to:)`
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

public extension NIOSSHPublicKeyProtocol {
    /// Optional override for the authentication algorithm name sent in SSH_MSG_USERAUTH_REQUEST.
    /// If not provided, defaults to publicKeyPrefix.
    /// This is useful for RSA keys that use rsa-sha2-* signature algorithms while maintaining ssh-rsa key type.
    static var authAlgorithmName: String { publicKeyPrefix }

    static var defaultHostKeyAlgorithms: [String]? { nil }
    static var supportsHostCertificates: Bool { false }

    /// Default: no OpenSSH certificate support for this key type.
    static var certifiedKeyPrefix: String? { nil }

    /// Default: the userauth algorithm name matches the certificate type name.
    static var certifiedAuthAlgorithmName: String? { certifiedKeyPrefix }
}

internal extension NIOSSHPublicKeyProtocol {
    var publicKeyPrefix: String {
        Self.publicKeyPrefix
    }

    var authAlgorithmName: String {
        Self.authAlgorithmName
    }

    var certifiedKeyPrefix: String? {
        Self.certifiedKeyPrefix
    }

    var certifiedAuthAlgorithmName: String? {
        Self.certifiedAuthAlgorithmName
    }
}

public protocol NIOSSHPrivateKeyProtocol {
    /// An identifier that represents the type of private key used in an SSH packet.
    /// This identifier MUST be unique to the private key implementation.
    /// The returned value MUST NOT overlap with other private key implementations or a specifications that the private key does not implement.
    static var keyPrefix: String { get }

    /// The public-key algorithm name used when authenticating with this key.
    ///
    /// This may differ from ``keyPrefix`` for key formats such as RSA, whose
    /// modern signature algorithm is `rsa-sha2-256` while its key blob remains
    /// `ssh-rsa`. Defaults to ``keyPrefix``.
    static var authAlgorithmName: String { get }

    /// Host-key algorithms this key can negotiate, in preference order.
    /// Defaults to ``authAlgorithmName``. Keys that can sign with multiple
    /// algorithms, such as RSA SHA-2 plus legacy RSA/SHA-1, must list each one
    /// and implement ``signature(for:authenticationAlgorithmName:)``.
    static var hostKeyAlgorithms: [String] { get }

    /// A public key instance that is able to verify signatures that are created using this private key.
    var publicKey: NIOSSHPublicKeyProtocol { get }

    /// Creates a signature, proving that `data` has been sent by the holder of this private key, and can be verified by `publicKey`.
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol

    /// Creates a signature for a specific negotiated authentication
    /// algorithm. Most key types have only one algorithm and use the default
    /// implementation. RSA implementations can select SHA-2 or SHA-1 without
    /// changing the public key blob.
    func signature<D: DataProtocol>(
        for data: D,
        authenticationAlgorithmName: String
    ) throws -> NIOSSHSignatureProtocol
}

public extension NIOSSHPrivateKeyProtocol {
    /// Optional override for the authentication algorithm name sent in SSH_MSG_USERAUTH_REQUEST.
    /// If not provided, defaults to keyPrefix.
    /// This is useful for RSA keys that use rsa-sha2-* signature algorithms while maintaining ssh-rsa key type.
    static var authAlgorithmName: String { keyPrefix }

    static var hostKeyAlgorithms: [String] { [authAlgorithmName] }

    func signature<D: DataProtocol>(
        for data: D,
        authenticationAlgorithmName _: String
    ) throws -> NIOSSHSignatureProtocol {
        try signature(for: data)
    }
}

internal extension NIOSSHPrivateKeyProtocol {
    var keyPrefix: String {
        Self.keyPrefix
    }

    var authAlgorithmName: String {
        Self.authAlgorithmName
    }

    var hostKeyAlgorithms: [String] {
        Self.hostKeyAlgorithms
    }
}
