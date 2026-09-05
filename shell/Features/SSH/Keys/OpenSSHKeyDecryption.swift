import Foundation
import NIOCore
import NIOFoundationCompat
import Crypto
import Citadel
import CCitadelBcrypt
import CCryptoBoringSSL

/// OpenSSH private key decryption support
/// Uses Citadel for AES-CTR and bcrypt support

/// Initialize the SHA512 function pointer for bcrypt
/// CCitadelBcrypt requires this to be set before calling citadel_bcrypt_pbkdf
private nonisolated enum BCryptSHA512Init {
    static let initialized: Bool = {
        citadel_set_crypto_hash_sha512 { output, input, inputLength in
            CCryptoBoringSSL_EVP_Digest(input, Int(inputLength), output, nil, CCryptoBoringSSL_EVP_sha512(), nil)
        }
        return true
    }()

    /// Call this to ensure bcrypt is initialized
    static func ensureInitialized() {
        _ = initialized
    }
}

// Pure crypto/parsing helpers with no UI access. Marked `nonisolated` so the
// off-main SSH key parse path (`SSHKeyParser`, itself `nonisolated`) can call
// them — without it they re-acquire MainActor isolation because the build sets
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum OpenSSH {
    enum KeyError: Error, LocalizedError {
        case missingDecryptionKey
        case cryptoError
        case invalidPadding
        case invalidCheck
        case unsupportedCipher(String)
        case unsupportedKDF(String)
        case encryptedKeysRequireCitadel

        var errorDescription: String? {
            switch self {
            case .missingDecryptionKey:
                return "Decryption key (passphrase) required for encrypted key"
            case .cryptoError:
                return "Cryptographic operation failed"
            case .invalidPadding:
                return "Invalid padding in encrypted data"
            case .invalidCheck:
                return "Decryption failed - invalid passphrase or corrupted data"
            case .unsupportedCipher(let cipher):
                return "Unsupported cipher: \(cipher)"
            case .unsupportedKDF(let kdf):
                return "Unsupported KDF: \(kdf)"
            case .encryptedKeysRequireCitadel:
                return "Encrypted RSA keys are not yet fully supported. Please use an unencrypted RSA key for now."
            }
        }
    }

    /// Supported cipher algorithms for OpenSSH keys
    enum Cipher: String {
        case none
        case aes128ctr = "aes128-ctr"
        case aes256ctr = "aes256-ctr"

        var keyLength: Int {
            switch self {
            case .none:
                return 0
            case .aes128ctr:
                return 16
            case .aes256ctr:
                return 32
            }
        }

        var ivLength: Int {
            switch self {
            case .none:
                return 0
            case .aes128ctr, .aes256ctr:
                return 16
            }
        }

        var blockSize: Int {
            switch self {
            case .none:
                return 8
            case .aes128ctr, .aes256ctr:
                return 16
            }
        }

        func decryptBuffer(
            _ buffer: inout ByteBuffer,
            key: [UInt8],
            iv: [UInt8]
        ) throws {
            switch self {
            case .none:
                // No decryption needed
                return
            case .aes128ctr:
                try buffer.decryptAES(cipher: CCryptoBoringSSL_EVP_aes_128_ctr(), key: key, iv: iv)
            case .aes256ctr:
                try buffer.decryptAES(cipher: CCryptoBoringSSL_EVP_aes_256_ctr(), key: key, iv: iv)
            }
        }
    }

    /// Key Derivation Function support
    enum KDF {
        enum KDFType: String {
            case none
            case bcrypt
        }

        case none
        case bcrypt(salt: ByteBuffer, iterations: UInt32)

        func withKeyAndIV<T>(
            cipher: Cipher,
            basedOnDecryptionKey decryptionKey: Data?,
            perform: (_ key: [UInt8], _ iv: [UInt8]) throws -> T
        ) throws -> T {
            switch self {
            case .none:
                return try perform([], [])
            case .bcrypt(var salt, let iterations):
                // Ensure bcrypt's SHA512 function pointer is initialized
                BCryptSHA512Init.ensureInitialized()

                guard let decryptionKey = decryptionKey else {
                    throw KeyError.missingDecryptionKey
                }

                // Pre-validate salt buffer has data to read
                guard salt.readableBytes > 0 else {
                    throw KeyError.cryptoError
                }
                guard let saltBytes = salt.readBytes(length: salt.readableBytes) else {
                    throw KeyError.cryptoError
                }

                return try decryptionKey.withUnsafeBytes { decryptionKey in
                    guard let baseAddress = decryptionKey.baseAddress else {
                        throw KeyError.missingDecryptionKey
                    }
                    var key = [UInt8](repeating: 0, count: cipher.keyLength + cipher.ivLength)
                    guard citadel_bcrypt_pbkdf(
                        baseAddress,
                        decryptionKey.count,
                        saltBytes,
                        saltBytes.count,
                        &key,
                        cipher.keyLength + cipher.ivLength,
                        iterations
                    ) == 0 else {
                        throw KeyError.cryptoError
                    }

                    return try perform(Array(key[..<cipher.keyLength]), Array(key[cipher.keyLength...]))
                }
            }
        }
    }

    /// SSH key type identifiers
    enum KeyType: String {
        case sshRSA = "ssh-rsa"
        case sshED25519 = "ssh-ed25519"
        case ecdsaSHA2nistp256 = "ecdsa-sha2-nistp256"
        case ecdsaSHA2nistp384 = "ecdsa-sha2-nistp384"
        case ecdsaSHA2nistp521 = "ecdsa-sha2-nistp521"
    }
}

// MARK: - ByteBuffer Cipher Extensions

nonisolated extension OpenSSH.Cipher {
    init(consuming buffer: inout ByteBuffer) throws {
        guard let cipherString = buffer.readSSHString() else {
            throw OpenSSH.KeyError.cryptoError
        }

        guard let cipher = OpenSSH.Cipher(rawValue: cipherString) else {
            throw OpenSSH.KeyError.unsupportedCipher(cipherString)
        }

        self = cipher
    }
}

nonisolated extension OpenSSH.KDF {
    init(consuming buffer: inout ByteBuffer) throws {
        guard let kdfString = buffer.readSSHString() else {
            throw OpenSSH.KeyError.cryptoError
        }

        guard let kdfType = KDFType(rawValue: kdfString) else {
            throw OpenSSH.KeyError.unsupportedKDF(kdfString)
        }

        // Always read options buffer (even for "none" it should be present but empty)
        guard var kdfOptionsBuffer = buffer.readSSHBuffer() else {
            throw OpenSSH.KeyError.cryptoError
        }

        switch kdfType {
        case .none:
            // Options should be empty for "none" KDF
            guard kdfOptionsBuffer.readableBytes == 0 else {
                throw OpenSSH.KeyError.cryptoError
            }
            self = .none
        case .bcrypt:
            guard
                let salt = kdfOptionsBuffer.readSSHBuffer(),
                let iterations = kdfOptionsBuffer.readInteger(as: UInt32.self)
            else {
                throw OpenSSH.KeyError.cryptoError
            }

            self = .bcrypt(salt: salt, iterations: iterations)
        }
    }
}

nonisolated extension OpenSSH.KeyType {
    init(consuming buffer: inout ByteBuffer) throws {
        guard let keyTypeString = buffer.readSSHString() else {
            throw OpenSSH.KeyError.cryptoError
        }

        guard let keyType = OpenSSH.KeyType(rawValue: keyTypeString) else {
            throw OpenSSH.KeyError.cryptoError
        }

        self = keyType
    }
}

// MARK: - ByteBuffer SSH String Extensions

nonisolated extension ByteBuffer {
    /// Read an SSH string (4-byte length prefix + data)
    mutating func readSSHString() -> String? {
        guard var buffer = readSSHBuffer() else {
            return nil
        }
        guard let data = buffer.readData(length: buffer.readableBytes) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Read an SSH buffer (4-byte length prefix + buffer)
    mutating func readSSHBuffer() -> ByteBuffer? {
        guard let length = readInteger(as: UInt32.self) else {
            return nil
        }
        return readSlice(length: Int(length))
    }

    /// Decrypt buffer in-place using AES-CTR
    /// Ported from Citadel's implementation
    mutating func decryptAES(
        cipher: OpaquePointer,
        key: [UInt8],
        iv: [UInt8]
    ) throws {
        guard self.readableBytes % 16 == 0 else {
            throw OpenSSH.KeyError.invalidPadding
        }

        let context = CCryptoBoringSSL_EVP_CIPHER_CTX_new()
        defer { CCryptoBoringSSL_EVP_CIPHER_CTX_free(context) }

        guard CCryptoBoringSSL_EVP_CipherInit(
            context,
            cipher,
            key,
            iv,
            0
        ) == 1 else {
            throw OpenSSH.KeyError.cryptoError
        }

        // Skip decryption for empty buffers
        guard self.readableBytes > 0 else {
            return
        }

        try self.withUnsafeMutableReadableBytes { buffer in
            guard var byteBufferPointer = buffer.bindMemory(to: UInt8.self).baseAddress else {
                throw OpenSSH.KeyError.cryptoError
            }
            try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { decryptedBuffer in
                guard let decryptedBufferBase = decryptedBuffer.baseAddress else {
                    throw OpenSSH.KeyError.cryptoError
                }
                for _ in 0..<buffer.count / 16 {
                    guard CCryptoBoringSSL_EVP_Cipher(
                        context,
                        decryptedBufferBase,
                        byteBufferPointer,
                        16
                    ) == 1 else {
                        throw OpenSSH.KeyError.cryptoError
                    }

                    byteBufferPointer.update(from: decryptedBufferBase, count: 16)
                    // Move the pointer forward to the next block
                    byteBufferPointer += 16
                }
            }
        }
    }
}
