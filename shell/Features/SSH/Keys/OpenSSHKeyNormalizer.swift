//
//  OpenSSHKeyNormalizer.swift
//  shell
//
//  Converts passphrase-encrypted openssh-key-v1 containers into
//  unencrypted containers so stored keys stay usable after iCloud sync
//  (passphrases are device-local and never sync — #285). Pure
//  String -> String: no Keychain access, no UI.
//

import Foundation
import NIOCore
import NIOFoundationCompat

/// `openssh-key-v1` container serialization shared by key generation and
/// normalization so both emit byte-identical layout. `nonisolated` because
/// the build sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum OpenSSHContainer {

    /// Wrap an SSH public-key blob + private section in the `openssh-key-v1`
    /// container and PEM armor (cipher "none", KDF "none").
    static func wrapUnencryptedPrivateKey(publicKeyBlob: ByteBuffer, privateSection: ByteBuffer) -> String {
        var buffer = ByteBuffer()

        // 1. AUTH_MAGIC = "openssh-key-v1\0"
        buffer.writeString("openssh-key-v1")
        buffer.writeInteger(UInt8(0))

        // 2. Cipher name = "none" (unencrypted)
        buffer.writeSSHString("none")

        // 3. KDF name = "none" (no key derivation)
        buffer.writeSSHString("none")

        // 4. KDF options = empty string
        buffer.writeSSHString("")

        // 5. Number of keys = 1
        buffer.writeInteger(UInt32(1))

        // 6. Public key blob (SSH wire format)
        buffer.writeSSHBuffer(publicKeyBlob)

        // 7. Private section padded to 8-byte block boundary
        let padded = padPrivateSection(privateSection, blockSize: 8)
        buffer.writeSSHBuffer(padded)

        let data = Data(buffer.readableBytesView)
        let base64 = data.base64EncodedString()

        var pemLines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var remaining = base64
        while !remaining.isEmpty {
            let lineLength = min(70, remaining.count)
            pemLines.append(String(remaining.prefix(lineLength)))
            remaining = String(remaining.dropFirst(lineLength))
        }
        pemLines.append("-----END OPENSSH PRIVATE KEY-----")
        return pemLines.joined(separator: "\n")
    }

    /// Pad the private section to a multiple of `blockSize` with the
    /// OpenSSH-mandated 01,02,03,... filler. Only adds bytes when the
    /// section isn't already aligned — always writing a full block on a
    /// boundary is non-standard and produces PEMs that `ssh-keygen`
    /// parses but flags.
    static func padPrivateSection(_ section: ByteBuffer, blockSize: Int) -> ByteBuffer {
        var padded = section
        let paddingNeeded = (blockSize - (padded.readableBytes % blockSize)) % blockSize
        for i in 0..<paddingNeeded {
            padded.writeInteger(UInt8(i + 1))
        }
        return padded
    }
}

nonisolated enum OpenSSHKeyNormalizer {

    enum Result: Sendable, Equatable {
        /// Container cipher is already "none" — store the original text as-is.
        case alreadyPlaintext
        /// Decrypted and re-armored as an unencrypted container.
        case normalized(keyText: String)
        /// Not an openssh-key-v1 armor (PEM/PKCS#8/other) — caller decides.
        case notOpenSSHContainer
    }

    enum NormalizerError: Error, LocalizedError {
        case passphraseRequired
        case incorrectPassphrase
        case malformedContainer(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .passphraseRequired:
                return "This key is encrypted. Please provide the passphrase to decrypt it."
            case .incorrectPassphrase:
                return "Incorrect passphrase or corrupted key data."
            case .malformedContainer(let message):
                return "Malformed OpenSSH key container: \(message)"
            case .verificationFailed(let message):
                return "Normalized key failed verification: \(message)"
            }
        }
    }

    /// Decrypt an encrypted container and re-armor it with cipher/KDF "none".
    /// All key fields and the comment are preserved byte-for-byte, and the
    /// output is deterministic, so concurrent migration on two synced
    /// devices converges to identical bytes.
    static func normalize(keyString: String, passphrase: String?) throws -> Result {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("BEGIN OPENSSH PRIVATE KEY") else {
            return .notOpenSSHContainer
        }

        let base64Lines = trimmed.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let keyData = Data(base64Encoded: base64Lines.joined()) else {
            throw NormalizerError.malformedContainer("Invalid base64 encoding")
        }

        var buffer = ByteBuffer(data: keyData)
        guard buffer.readString(length: "openssh-key-v1".count) == "openssh-key-v1",
              buffer.readInteger(as: UInt8.self) == 0x00 else {
            throw NormalizerError.malformedContainer("Invalid OpenSSH magic string")
        }

        let cipher: OpenSSH.Cipher
        let kdf: OpenSSH.KDF
        do {
            cipher = try OpenSSH.Cipher(consuming: &buffer)
            kdf = try OpenSSH.KDF(consuming: &buffer)
        } catch {
            throw NormalizerError.malformedContainer(error.localizedDescription)
        }

        guard cipher != .none else {
            return .alreadyPlaintext
        }
        guard let passphraseData = passphrase?.data(using: .utf8) else {
            throw NormalizerError.passphraseRequired
        }

        guard let numKeys = buffer.readInteger(as: UInt32.self), numKeys == 1 else {
            throw NormalizerError.malformedContainer("Invalid or multiple keys not supported")
        }
        guard let publicKeyBlob = buffer.readSSHBuffer() else {
            throw NormalizerError.malformedContainer("Missing public key")
        }
        guard var privateKeyBuffer = buffer.readSSHBuffer() else {
            throw NormalizerError.malformedContainer("Missing private key")
        }

        do {
            try kdf.withKeyAndIV(cipher: cipher, basedOnDecryptionKey: passphraseData) { key, iv in
                try cipher.decryptBuffer(&privateKeyBuffer, key: key, iv: iv)
            }
        } catch OpenSSH.KeyError.invalidCheck {
            throw NormalizerError.incorrectPassphrase
        } catch {
            throw NormalizerError.malformedContainer("Decryption failed: \(error.localizedDescription)")
        }

        let privateSection = try strippedPrivateSection(from: privateKeyBuffer, blockSize: cipher.blockSize)
        let normalizedText = OpenSSHContainer.wrapUnencryptedPrivateKey(
            publicKeyBlob: publicKeyBlob,
            privateSection: privateSection
        )

        try verify(normalizedText: normalizedText, original: trimmed, passphrase: passphrase)
        return .normalized(keyText: normalizedText)
    }

    /// Validate the decrypted private section and drop its trailing padding.
    /// Container-generic: after the check integers, every field of every
    /// supported algorithm is uint32-length-prefixed, so a greedy field walk
    /// stops exactly at the padding — padding starts 01,02,03,… and is under
    /// one cipher block, so its first 4 bytes decode as an impossible length.
    private static func strippedPrivateSection(from decrypted: ByteBuffer, blockSize: Int) throws -> ByteBuffer {
        var walker = decrypted

        guard let check1 = walker.readInteger(as: UInt32.self),
              let check2 = walker.readInteger(as: UInt32.self),
              check1 == check2 else {
            throw NormalizerError.incorrectPassphrase
        }

        while walker.readableBytes >= 4 {
            guard let fieldLength = walker.getInteger(at: walker.readerIndex, as: UInt32.self),
                  Int(fieldLength) <= walker.readableBytes - 4 else {
                break
            }
            walker.moveReaderIndex(forwardBy: 4 + Int(fieldLength))
        }

        let paddingLength = walker.readableBytes
        guard paddingLength < blockSize,
              let paddingBytes = walker.readBytes(length: paddingLength) else {
            throw NormalizerError.malformedContainer("Invalid private-section padding length")
        }
        for (index, byte) in paddingBytes.enumerated() where byte != UInt8(index + 1) {
            throw NormalizerError.malformedContainer("Invalid private-section padding bytes")
        }

        guard let section = decrypted.getSlice(
            at: decrypted.readerIndex,
            length: decrypted.readableBytes - paddingLength
        ) else {
            throw NormalizerError.malformedContainer("Failed to slice private section")
        }
        return section
    }

    /// Reparse both representations and require the same key type and
    /// fingerprint, so a miswalk can never corrupt a stored key.
    private static func verify(normalizedText: String, original: String, passphrase: String?) throws {
        let normalizedParsed: SSHKeyParser.ParsedKey
        let originalParsed: SSHKeyParser.ParsedKey
        do {
            normalizedParsed = try SSHKeyParser.parse(keyString: normalizedText, passphrase: nil)
            originalParsed = try SSHKeyParser.parse(keyString: original, passphrase: passphrase)
        } catch {
            throw NormalizerError.verificationFailed(error.localizedDescription)
        }
        guard normalizedParsed.keyType == originalParsed.keyType,
              normalizedParsed.fingerprint == originalParsed.fingerprint else {
            throw NormalizerError.verificationFailed("Key type or fingerprint mismatch after normalization")
        }
    }
}
