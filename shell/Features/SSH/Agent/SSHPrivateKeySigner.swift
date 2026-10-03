//
//  SSHPrivateKeySigner.swift
//  shell
//
//  Produces a standard SSH signature blob (`string algorithm, string sig`)
//  for a loaded Shell identity. Used by the local SSH agent bridge
//  (ssh-agent-bridge-spec.md §11.3–11.4).
//
//  Ed25519, ECDSA and Secure Enclave keys sign through NIOSSH's public
//  `NIOSSHPrivateKey.signature(for:)` and are encoded with NIOSSH's own
//  `writeSSHSignature`, so the wire format is the one native authentication
//  emits. A Secure Enclave key signs inside the enclave: only the reference
//  reconstructed by `SSHKeyManager` is touched, never the scalar.
//

import Foundation
import NIOCore
import NIOSSH
import Crypto
import Citadel

nonisolated enum SSHPrivateKeySigner {

    enum SignerError: Error, Equatable {
        /// The loaded key's variant does not match the identity's key type.
        case keyTypeMismatch
        /// An RSA request without `SSH_AGENT_RSA_SHA2_256/512`, i.e. legacy
        /// `ssh-rsa` (SHA-1).
        case legacyRSASHA1Refused
    }

    /// RSA signature algorithm selected for an agent sign request.
    enum RSAAlgorithm: String, Equatable {
        case sha256 = "rsa-sha2-256"
        case sha512 = "rsa-sha2-512"

        /// `SSH_AGENT_RSA_SHA2_512` wins over `SSH_AGENT_RSA_SHA2_256` (as in
        /// OpenSSH's agent). With neither flag the request is for legacy
        /// `ssh-rsa` (SHA-1). Native authentication makes that attempt only
        /// after inspecting the server's `server-sig-algs`
        /// (`SSHRSASignaturePolicy`); the agent sees no server and any local
        /// program can ask, so it refuses rather than hand out SHA-1
        /// signatures on demand.
        init?(flags: SSHAgentSignatureFlags) {
            if flags.contains(.rsaSha512) {
                self = .sha512
            } else if flags.contains(.rsaSha256) {
                self = .sha256
            } else {
                return nil
            }
        }
    }

    /// Signs `data` for an agent `SSH_AGENT_SIGN_RESPONSE`.
    ///
    /// The returned buffer is the signature blob only; the caller wraps it in
    /// the agent message. Certificate identities sign with the same private
    /// key, so the blob format is that of the underlying key.
    static func signAgentPayload(
        key: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        data: ByteBuffer,
        flags: SSHAgentSignatureFlags
    ) throws -> ByteBuffer {
        var output = ByteBufferAllocator().buffer(capacity: 512)

        switch key {
        case .nioSSH(let nioKey):
            guard keyType != .rsa, keyType != .secureEnclaveP256 else {
                throw SignerError.keyTypeMismatch
            }
            let signature = try nioKey.signature(for: data.readableBytesView)
            output.writeSSHSignature(signature)

        case .secureEnclaveP256(let nioKey):
            guard keyType == .secureEnclaveP256 else {
                throw SignerError.keyTypeMismatch
            }
            let signature = try nioKey.signature(for: data.readableBytesView)
            output.writeSSHSignature(signature)

        case .rsa(let rsaKey):
            guard keyType == .rsa else {
                throw SignerError.keyTypeMismatch
            }
            guard let algorithm = RSAAlgorithm(flags: flags) else {
                throw SignerError.legacyRSASHA1Refused
            }
            let hash: Insecure.RSA.PrivateKey.HashAlgorithm = algorithm == .sha512 ? .sha512 : .sha256
            let rawSignature = try rsaKey.signature(for: data.readableBytesView, hashAlgorithm: hash).rawRepresentation
            SSHPublicKeyBlob.writeSSHString(&output, algorithm.rawValue)
            SSHPublicKeyBlob.writeSSHBuffer(&output, ByteBuffer(bytes: rawSignature))
        }

        return output
    }
}
