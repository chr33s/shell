import Crypto
import Foundation
import os

@MainActor
final class ScrollbackEncryptionManager {
    static let shared = ScrollbackEncryptionManager()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "ScrollbackEncryption")

    private var cachedKey: SymmetricKey?

    private init() {}

    // MARK: - Errors

    enum ScrollbackEncryptionError: LocalizedError {
        case keyGenerationFailed
        case encryptionFailed(Error)
        case decryptionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .keyGenerationFailed:
                return "Failed to generate or retrieve scrollback encryption key"
            case .encryptionFailed(let error):
                return "Scrollback encryption failed: \(error.localizedDescription)"
            case .decryptionFailed(let error):
                return "Scrollback decryption failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Key Management

    private func getOrCreateKey() throws -> SymmetricKey {
        if let cached = cachedKey {
            return cached
        }

        // Load from Keychain. Only a genuinely absent item may fall through to
        // key generation. This used to be `try?`, which collapsed
        // `unexpectedStatus`/`dataConversionFailed` into the same "no key" answer
        // as `itemNotFound` — and because `saveScrollbackEncryptionKey` upserts
        // (SecItemAdd -> errSecDuplicateItem -> SecItemUpdate), minting a key
        // after a read that failed for any *other* reason silently overwrote the
        // still-present key. Every existing `<uuid>.ansi.enc` then failed
        // AES.GCM.open and was deleted as "corrupted", unrecoverably. Read
        // failures of that kind are live here: the item is
        // AfterFirstUnlockThisDeviceOnly in a named access group, so
        // errSecInteractionNotAllowed (before first unlock after reboot) and
        // errSecMissingEntitlement (access-group / provisioning change) both
        // reach this call. Fail closed instead — callers all skip saving or
        // restoring on a throw, leaving key and ciphertext intact.
        do {
            let keyData = try KeychainManager.shared.loadScrollbackEncryptionKey()
            let key = SymmetricKey(data: keyData)
            cachedKey = key
            Self.logger.debug("Loaded scrollback encryption key from Keychain")
            return key
        } catch KeychainManager.KeychainError.itemNotFound {
            // Genuinely no key yet: first run, or a device restore (the item is
            // ThisDeviceOnly, so it is never present in a backup). Fall through.
            Self.logger.debug("No scrollback encryption key in Keychain; generating one")
        } catch {
            Self.logger.error(
                "Scrollback encryption key read failed; refusing to rotate: \(error.localizedDescription)")
            throw error
        }

        // Generate new key
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        do {
            try KeychainManager.shared.saveScrollbackEncryptionKey(keyData)
        } catch {
            Self.logger.error("Failed to save scrollback encryption key: \(error.localizedDescription)")
            throw ScrollbackEncryptionError.keyGenerationFailed
        }

        cachedKey = key
        Self.logger.info("Generated and saved new scrollback encryption key")
        return key
    }

    // MARK: - Key Access

    /// Pre-fetch the encryption key on MainActor so it can be passed to background work.
    func getKey() throws -> SymmetricKey {
        return try getOrCreateKey()
    }

    // MARK: - Encrypt / Decrypt

    func encrypt(_ plaintext: Data) throws -> Data {
        let key = try getOrCreateKey()
        return try Self.encrypt(plaintext, using: key)
    }

    /// Encrypt data using a pre-fetched key. Can be called from any thread.
    nonisolated static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else {
                throw ScrollbackEncryptionError.encryptionFailed(
                    NSError(domain: "ScrollbackEncryption", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to produce combined sealed box"])
                )
            }
            return combined
        } catch let error as ScrollbackEncryptionError {
            throw error
        } catch {
            throw ScrollbackEncryptionError.encryptionFailed(error)
        }
    }

    func decrypt(_ combined: Data) throws -> Data {
        let key = try getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw ScrollbackEncryptionError.decryptionFailed(error)
        }
    }
}
