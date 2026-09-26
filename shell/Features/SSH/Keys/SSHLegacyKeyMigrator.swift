import Foundation
import os

/// Normalizes old passphrase-encrypted Keychain blobs without prompting.
/// The manager applies the resulting metadata changes on the main actor.
nonisolated enum SSHLegacyKeyMigrator {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHLegacyKeyMigrator")

    enum Outcome: Sendable {
        case migrated
        case alreadyNormalized
        case clean
        case needsUnlock
        case skipped
    }

    /// The blob header is authoritative: synchronized metadata can arrive first.
    static func runInteractionFree(identifier: String, expectedFingerprint: String,
                                   hasPassphraseHint: Bool) -> Outcome {
        let keychain = KeychainManager.shared
        let storedPassphrase = keychain.loadPassphrase(forKey: identifier)
        guard let blob = try? keychain.loadPrivateKey(identifier: identifier),
              let keyString = String(data: blob, encoding: .utf8) else {
            return .skipped
        }

        do {
            switch try OpenSSHKeyNormalizer.normalize(keyString: keyString, passphrase: storedPassphrase) {
            case .alreadyPlaintext, .notOpenSSHContainer:
                return (hasPassphraseHint || storedPassphrase != nil) ? .alreadyNormalized : .clean
            case .normalized(let normalizedText):
                guard let normalizedData = normalizedText.data(using: .utf8),
                      let parsed = try? SSHKeyParser.parse(keyString: normalizedText, passphrase: nil),
                      parsed.fingerprint == expectedFingerprint else {
                    return .skipped
                }
                // A newer synced blob must never be overwritten.
                guard let current = try? keychain.loadPrivateKey(identifier: identifier), current == blob else {
                    return .skipped
                }
                do {
                    try keychain.updatePrivateKey(normalizedData, identifier: identifier)
                } catch {
                    logger.warning("Legacy key migration write failed for \(identifier): \(error.localizedDescription)")
                    return .skipped
                }
                return .migrated
            }
        } catch OpenSSHKeyNormalizer.NormalizerError.passphraseRequired,
                OpenSSHKeyNormalizer.NormalizerError.incorrectPassphrase {
            return .needsUnlock
        } catch {
            logger.warning("Legacy key migration failed for \(identifier): \(error.localizedDescription)")
            return .skipped
        }
    }
}
