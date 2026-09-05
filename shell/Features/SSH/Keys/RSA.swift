import Foundation
import NIOCore
import NIOFoundationCompat
import Crypto      // Must import for Insecure namespace
import Citadel     // Import AFTER Crypto so extensions take precedence
import CCryptoBoringSSL

/// RSA key implementation for SSH authentication using Citadel
/// Wraps Citadel's Insecure.RSA.PrivateKey for use in our SSH key management

/// Pure crypto wrapper with no UI access. Marked `nonisolated` so it can be
/// built and read from the off-main SSH key parse path (e.g.
/// `SSHKeyManager.materializeParsedKey`, which is `nonisolated`) — without it
/// the type re-acquires MainActor isolation because the build sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
public nonisolated struct RSAPrivateKey {
    internal let citadelKey: Insecure.RSA.PrivateKey
    private let _publicKeyData: Data

    /// Initialize RSA private key from raw components (n, e, d)
    /// - Parameters:
    ///   - n: Modulus (public)
    ///   - e: Public exponent (typically 65537)
    ///   - d: Private exponent
    public init(n: Data, e: Data, d: Data) throws {
        // Citadel's RSA.PrivateKey takes raw BIGNUM pointers
        // We need to convert our Data to BIGNUMs using BoringSSL
        // Note: Parameter order in Citadel is (privateExponent, publicExponent, modulus) = (d, e, n)
        let d_bytes = Array(d)
        let e_bytes = Array(e)
        let n_bytes = Array(n)

        // Convert bytes to BIGNUMs with proper error handling
        guard let d_bn = CCryptoBoringSSL_BN_bin2bn(d_bytes, d_bytes.count, nil) else {
            throw RSAError(message: "Failed to convert private exponent to BIGNUM")
        }
        guard let e_bn = CCryptoBoringSSL_BN_bin2bn(e_bytes, e_bytes.count, nil) else {
            throw RSAError(message: "Failed to convert public exponent to BIGNUM")
        }
        guard let n_bn = CCryptoBoringSSL_BN_bin2bn(n_bytes, n_bytes.count, nil) else {
            throw RSAError(message: "Failed to convert modulus to BIGNUM")
        }

        // Create Citadel's RSA private key (parameters: d, e, n)
        self.citadelKey = Insecure.RSA.PrivateKey(
            privateExponent: d_bn,
            publicExponent: e_bn,
            modulus: n_bn
        )

        // Store public key data for fingerprinting
        // SSH public key format: "ssh-rsa" + e (mpint) + n (mpint)
        // MPInt format: 4-byte length + data (with leading 0x00 if high bit set)
        var buffer = ByteBuffer()
        buffer.writeSSHString("ssh-rsa")
        buffer.writeSSHMPInt(Data(e))
        buffer.writeSSHMPInt(Data(n))

        self._publicKeyData = buffer.readData(length: buffer.readableBytes) ?? Data()

    }

    /// Generate RSA signature for SSH authentication
    /// Currently uses SHA-1 for compatibility (TODO: upgrade to SHA-256)
    /// - Parameter message: Data to sign
    /// - Returns: Signature bytes
    public func signature<D: DataProtocol>(for message: D) throws -> Data {
        let signature: Insecure.RSA.Signature = try citadelKey.signature(for: message)
        return Data(signature.rawRepresentation)
    }

    /// Get the public key data for fingerprinting
    public func publicKeyData() -> Data {
        return _publicKeyData
    }
}

// MARK: - ByteBuffer SSH Extensions

extension ByteBuffer {
    /// Write an SSH string (4-byte length prefix + UTF-8 data)
    nonisolated mutating func writeSSHString(_ string: String) {
        let data = string.data(using: .utf8) ?? Data()
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }

    /// Write an SSH buffer (4-byte length prefix + buffer data)
    nonisolated mutating func writeSSHBuffer(_ buffer: ByteBuffer) {
        var buf = buffer
        writeInteger(UInt32(buf.readableBytes))
        writeBuffer(&buf)
    }

    /// Write an SSH MPInt (multi-precision integer)
    /// Format: 4-byte length + data (with leading 0x00 if high bit is set for positive numbers)
    nonisolated mutating func writeSSHMPInt(_ data: Data) {
        var bytes = Array(data)

        // Remove leading zeros (except if it makes the number negative)
        while bytes.count > 1 && bytes[0] == 0 && (bytes[1] & 0x80) == 0 {
            bytes.removeFirst()
        }

        // Add leading zero if high bit is set (to indicate positive number)
        if !bytes.isEmpty && (bytes[0] & 0x80) != 0 {
            bytes.insert(0, at: 0)
        }

        // Write length and data
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }
}

/// RSA Error types
public struct RSAError: Error, LocalizedError {
    let message: String

    public var errorDescription: String? {
        message
    }
}
