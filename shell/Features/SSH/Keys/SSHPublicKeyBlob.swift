//
//  SSHPublicKeyBlob.swift
//  shell
//
//  Builds the SSH wire-format public key blob for a loaded identity. The blob
//  is cached in `SSHKey.publicKeyBlob` so public-key comparisons never have to
//  load the private key (and so never trigger a biometric prompt).
//
//  Extracted from the agent signer that used to own this logic; the fork has
//  no SSH agent, but authentication and certificate matching still need the
//  blob.
//

import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Citadel

enum SSHPublicKeyBlob {

    /// SSH wire-format public key blob for `keyVariant`.
    static func make(from keyVariant: SSHPrivateKeyVariant, keyType: SSHKey.KeyType) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)

        switch keyVariant {
        case .nioSSH(let nioKey), .secureEnclaveP256(let nioKey):
            let publicKey = nioKey.publicKey
            writeSSHString(&buffer, keyTypeString(keyType))

            switch keyType {
            case .ed25519:
                // Ed25519: just the raw 32-byte public key
                if let publicData = extractEd25519PublicKey(publicKey) {
                    writeSSHBuffer(&buffer, ByteBuffer(data: publicData))
                }
            case .ecdsaP256, .ecdsaP384, .ecdsaP521, .secureEnclaveP256:
                // ECDSA (incl. Secure Enclave P-256): curve identifier + point
                writeSSHString(&buffer, ecdsaCurveIdentifier(keyType))
                if let publicData = extractECDSAPublicKey(publicKey) {
                    writeSSHBuffer(&buffer, ByteBuffer(data: publicData))
                }
            case .rsa:
                break  // RSA keys arrive as `.rsa`, never as `.nioSSH`
            }

        case .rsa(let rsaKey):
            // RSA: "ssh-rsa" + e (mpint) + n (mpint)
            writeSSHString(&buffer, "ssh-rsa")
            _ = rsaKey.publicKey.write(to: &buffer)
        }

        return buffer
    }

    /// Same as ``make(from:keyType:)`` but returns `Data`.
    static func makeData(from keyVariant: SSHPrivateKeyVariant, keyType: SSHKey.KeyType) -> Data? {
        let buffer = make(from: keyVariant, keyType: keyType)
        return buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
    }

    // MARK: - SSH wire format helpers

    static func keyTypeString(_ keyType: SSHKey.KeyType) -> String {
        keyType.sshKeyTypeString
    }

    static func ecdsaCurveIdentifier(_ keyType: SSHKey.KeyType) -> String {
        switch keyType {
        case .ecdsaP256, .secureEnclaveP256: return "nistp256"
        case .ecdsaP384: return "nistp384"
        case .ecdsaP521: return "nistp521"
        default: return ""
        }
    }

    /// Signature algorithm name to advertise for `keyType`.
    static func signatureAlgorithmName(_ keyType: SSHKey.KeyType) -> String {
        switch keyType {
        case .rsa: return "rsa-sha2-256"
        case .ed25519: return "ssh-ed25519"
        case .ecdsaP256, .secureEnclaveP256: return "ecdsa-sha2-nistp256"
        case .ecdsaP384: return "ecdsa-sha2-nistp384"
        case .ecdsaP521: return "ecdsa-sha2-nistp521"
        }
    }

    private static func extractEd25519PublicKey(_ publicKey: NIOSSHPublicKey) -> Data? {
        // NIOSSHPublicKey doesn't expose the raw bytes, so round-trip through
        // the OpenSSH one-line format and read the blob back out.
        let openSSHString = String(openSSHPublicKey: publicKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1])) else {
            return nil
        }

        var buffer = ByteBuffer(data: keyData)
        _ = readSSHString(&buffer)  // Skip key type
        guard let pubKeyBuffer = readSSHBuffer(&buffer) else {
            return nil
        }
        return pubKeyBuffer.getData(at: pubKeyBuffer.readerIndex, length: pubKeyBuffer.readableBytes)
    }

    private static func extractECDSAPublicKey(_ publicKey: NIOSSHPublicKey) -> Data? {
        let openSSHString = String(openSSHPublicKey: publicKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1])) else {
            return nil
        }

        var buffer = ByteBuffer(data: keyData)
        _ = readSSHString(&buffer)  // Skip key type
        _ = readSSHString(&buffer)  // Skip curve identifier
        guard let pubKeyBuffer = readSSHBuffer(&buffer) else {
            return nil
        }
        return pubKeyBuffer.getData(at: pubKeyBuffer.readerIndex, length: pubKeyBuffer.readableBytes)
    }

    static func readSSHString(_ buffer: inout ByteBuffer) -> String? {
        guard let length = buffer.readInteger(as: UInt32.self),
              let data = buffer.readBytes(length: Int(length)),
              let string = String(bytes: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func readSSHBuffer(_ buffer: inout ByteBuffer) -> ByteBuffer? {
        guard let length = buffer.readInteger(as: UInt32.self),
              let slice = buffer.readSlice(length: Int(length)) else {
            return nil
        }
        return slice
    }

    static func writeSSHString(_ buffer: inout ByteBuffer, _ string: String) {
        let data = string.data(using: .utf8) ?? Data()
        buffer.writeInteger(UInt32(data.count))
        buffer.writeBytes(data)
    }

    static func writeSSHBuffer(_ buffer: inout ByteBuffer, _ data: ByteBuffer) {
        var dataCopy = data
        buffer.writeInteger(UInt32(dataCopy.readableBytes))
        buffer.writeBuffer(&dataCopy)
    }
}
