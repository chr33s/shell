//
//  SSHUserCertificateParser.swift
//  shell
//
//  Parses OpenSSH user certificates (-cert.pub one-liners) for attaching to
//  saved SSH keys. The raw blob is kept verbatim as the source of truth; the
//  parsed metadata is denormalized into SSHUserCertificateInfo for display.
//
//  Copyright (c) 2026 Kit Knox / Shell LLC
//

import Foundation
import NIOCore
import NIOSSH
import Crypto      // Must import for Insecure namespace
import Citadel     // Import AFTER Crypto so extensions take precedence

// MARK: - Errors

enum SSHUserCertificateImportError: LocalizedError {
    /// The pasted text is a plain public key, not a certificate.
    case notACertificate
    /// The pasted text looks like a private key.
    case privateKeyPasted
    /// The certificate is a host certificate (type 2), not a user certificate.
    case hostCertificate
    /// The certificate has an unknown type value.
    case unsupportedType(UInt32)
    /// The certificate's embedded public key does not match the target key.
    case keyMismatch(expectedKeyName: String)
    /// No saved key matches the certificate's embedded public key.
    case noMatchingKey(embeddedKeyType: String, embeddedFingerprint: String)
    /// The text could not be parsed at all.
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notACertificate:
            return String(localized: "This is a public key, not a certificate. Paste the contents of the -cert.pub file issued by your certificate authority.", comment: "Cert import error: plain public key pasted")
        case .privateKeyPasted:
            return String(localized: "This looks like a private key. Paste the certificate (-cert.pub), not the key itself.", comment: "Cert import error: private key pasted")
        case .hostCertificate:
            return String(localized: "This is a host certificate. Host certificate authorities are configured under Settings → Certificate Authorities.", comment: "Cert import error: host certificate pasted")
        case .unsupportedType(let raw):
            return String(localized: "Unsupported certificate type (\(raw)). Only user certificates are supported here.", comment: "Cert import error: unknown certificate type")
        case .keyMismatch(let expectedKeyName):
            return String(localized: "This certificate was not issued for \"\(expectedKeyName)\". Its embedded public key belongs to a different key.", comment: "Cert import error: certificate is for a different key")
        case .noMatchingKey(let embeddedKeyType, let embeddedFingerprint):
            return String(localized: "No saved key matches this certificate. It certifies a \(embeddedKeyType) key with fingerprint \(embeddedFingerprint). Import that key first.", comment: "Cert import error: no matching key found")
        case .parseFailed(let reason):
            return String(localized: "Could not parse the certificate: \(reason)", comment: "Cert import error: parse failure")
        }
    }
}

// MARK: - Parsed result

struct ParsedUserCertificate {
    /// Metadata ready to persist on the SSHKey.
    let info: SSHUserCertificateInfo
    /// Wire blob of the certificate's embedded public key (type string + components),
    /// normalized for comparison against `SSHKey.publicKeyBlob`.
    let embeddedPublicKeyBlob: Data
    /// The parsed certificate, for immediate use in an auth offer (not stored).
    let certifiedKey: NIOSSHCertifiedPublicKey
}

// MARK: - Parser

enum SSHUserCertificateParser {
    /// Custom key types serialize their plain public keys under an internal algorithm
    /// name that differs from the OpenSSH blob type string. Cached `publicKeyBlob`s use
    /// the OpenSSH name, so normalize before comparing.
    private static let blobTypeAliases: [String: String] = [
        "webauthn-sk-ecdsa-sha2-nistp256@openssh.com": "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    /// Registers the custom key algorithms certificates may embed. Idempotent; needed
    /// because cert parsing can run before any SSH connection has registered them.
    static func ensureAlgorithmsRegistered() {
        SSHCustomAlgorithms.ensureRegistered()
    }

    /// Parse a one-line OpenSSH certificate: `<type>-cert-v01@... <base64> [comment]`.
    static func parse(line: String) throws -> ParsedUserCertificate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw SSHUserCertificateImportError.parseFailed(String(localized: "Empty input", comment: "Cert parse failure reason"))
        }
        guard !trimmed.contains("-----BEGIN") else {
            throw SSHUserCertificateImportError.privateKeyPasted
        }

        ensureAlgorithmsRegistered()

        let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2 else {
            throw SSHUserCertificateImportError.parseFailed(String(localized: "Expected \"<type> <base64-data> [comment]\"", comment: "Cert parse failure reason"))
        }
        let certType = String(fields[0])
        let comment = fields.count >= 3 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : nil

        guard certType.contains("-cert-v01@openssh.com") else {
            throw SSHUserCertificateImportError.notACertificate
        }
        guard let certificateBlob = Data(base64Encoded: String(fields[1])) else {
            throw SSHUserCertificateImportError.parseFailed(String(localized: "Invalid base64 data", comment: "Cert parse failure reason"))
        }

        let publicKey: NIOSSHPublicKey
        do {
            publicKey = try NIOSSHPublicKey(openSSHPublicKey: trimmed)
        } catch {
            throw SSHUserCertificateImportError.parseFailed(String(describing: error))
        }
        guard let certifiedKey = NIOSSHCertifiedPublicKey(publicKey) else {
            throw SSHUserCertificateImportError.notACertificate
        }

        switch certifiedKey.type {
        case .user:
            break
        case .host:
            throw SSHUserCertificateImportError.hostCertificate
        default:
            throw SSHUserCertificateImportError.unsupportedType(certifiedKey.type.rawValue)
        }

        let info = SSHUserCertificateInfo(
            certificateBlob: certificateBlob,
            certType: certType,
            keyID: certifiedKey.keyID,
            serial: certifiedKey.serial,
            validPrincipals: certifiedKey.validPrincipals,
            validAfter: certifiedKey.validAfter,
            validBefore: certifiedKey.validBefore,
            caKeyType: SSHHostKeyFormatter.keyType(for: certifiedKey.signatureKey),
            caFingerprint: SSHHostKeyFormatter.fingerprint(for: certifiedKey.signatureKey),
            comment: comment,
            addedDate: Date()
        )

        return ParsedUserCertificate(
            info: info,
            embeddedPublicKeyBlob: normalizedEmbeddedBlob(for: certifiedKey.key),
            certifiedKey: certifiedKey
        )
    }

    /// Reconstruct a parsed certificate from its stored blob, e.g. at connection time.
    static func certifiedKey(fromStoredBlob blob: Data) throws -> NIOSSHCertifiedPublicKey {
        ensureAlgorithmsRegistered()
        var buffer = ByteBufferAllocator().buffer(capacity: blob.count)
        buffer.writeBytes(blob)
        return try NIOSSHCertifiedPublicKey(certificateBlob: buffer)
    }

    /// Serialize the certificate's embedded public key as a full wire blob and normalize
    /// any internal algorithm-name alias so it compares equal to cached key blobs.
    static func normalizedEmbeddedBlob(for key: NIOSSHPublicKey) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        key.write(to: &buffer)
        return normalizedRawBlob(buffer)
    }

    /// Normalize a cached key blob the same way (no-op for canonical blobs).
    static func normalizedCachedBlob(_ blob: Data) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: blob.count)
        buffer.writeBytes(blob)
        return normalizedRawBlob(buffer)
    }

    private static func normalizedRawBlob(_ buffer: ByteBuffer) -> Data {
        var copy = buffer
        guard
            var typeBuffer = copy.readSSHStringAsCertParserString(),
            let typeString = typeBuffer.readString(length: typeBuffer.readableBytes),
            let alias = blobTypeAliases[typeString]
        else {
            return Data(buffer.readableBytesView)
        }
        // Rebuild with the canonical OpenSSH type string.
        var rebuilt = ByteBufferAllocator().buffer(capacity: buffer.readableBytes)
        rebuilt.writeInteger(UInt32(alias.utf8.count))
        rebuilt.writeString(alias)
        rebuilt.writeBytes(copy.readableBytesView)
        return Data(rebuilt.readableBytesView)
    }

    /// Human-readable description of the embedded key (type + fingerprint) for
    /// "no matching key" errors.
    static func embeddedKeyDescription(for certifiedKey: NIOSSHCertifiedPublicKey) -> (keyType: String, fingerprint: String) {
        (
            SSHHostKeyFormatter.keyType(for: certifiedKey.key),
            SSHHostKeyFormatter.fingerprint(for: certifiedKey.key)
        )
    }
}

// MARK: - ByteBuffer helper

private extension ByteBuffer {
    /// Read a length-prefixed SSH string (avoids depending on NIOSSH's internal helper).
    mutating func readSSHStringAsCertParserString() -> ByteBuffer? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self),
              readableBytes >= 4 + Int(length) else {
            return nil
        }
        moveReaderIndex(forwardBy: 4)
        return readSlice(length: Int(length))
    }
}
