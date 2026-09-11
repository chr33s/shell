//===----------------------------------------------------------------------===//
//
// This source file is part of the Citadel open source project
//
// Copyright (c) 2025 Citadel contributors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// A delegate protocol for handling SSH agent operations.
///
/// Implement this protocol to provide SSH agent functionality, allowing
/// remote servers to list available keys and request signatures.
public protocol SSHAgentDelegate: Sendable {
    /// Lists all available SSH identities (public keys).
    ///
    /// Called when the remote server requests a list of available keys.
    /// Each identity includes the public key blob and an optional comment.
    ///
    /// - Returns: An array of available SSH identities.
    func listIdentities() async throws -> [SSHAgentIdentity]

    /// Signs data with a specific key.
    ///
    /// Called when the remote server requests a signature using a specific key.
    /// The key is identified by its public key blob.
    ///
    /// - Parameters:
    ///   - publicKeyBlob: The public key blob identifying which key to use.
    ///   - data: The data to be signed.
    ///   - flags: Signature flags (e.g., for RSA algorithm selection).
    /// - Returns: The signature blob, or `nil` to deny the request.
    func sign(
        publicKeyBlob: ByteBuffer,
        data: ByteBuffer,
        flags: UInt32
    ) async throws -> ByteBuffer?
}

/// Represents an SSH identity (public key) available through the agent.
public struct SSHAgentIdentity: Sendable {
    /// The public key blob in SSH wire format.
    public let publicKeyBlob: ByteBuffer

    /// A human-readable comment for this key (typically the key's name or file path).
    public let comment: String

    /// Creates a new SSH agent identity.
    ///
    /// - Parameters:
    ///   - publicKeyBlob: The public key blob in SSH wire format.
    ///   - comment: A human-readable comment for this key.
    public init(publicKeyBlob: ByteBuffer, comment: String) {
        self.publicKeyBlob = publicKeyBlob
        self.comment = comment
    }
}

/// Signature flags for SSH agent sign requests.
///
/// These flags indicate which signature algorithm should be used,
/// particularly for RSA keys which support multiple algorithms.
public struct SSHAgentSignatureFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Request RSA signature using SHA-256 (rsa-sha2-256).
    public static let rsaSha256 = SSHAgentSignatureFlags(rawValue: 2)

    /// Request RSA signature using SHA-512 (rsa-sha2-512).
    public static let rsaSha512 = SSHAgentSignatureFlags(rawValue: 4)
}
