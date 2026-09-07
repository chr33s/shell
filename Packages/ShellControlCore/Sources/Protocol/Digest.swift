import Foundation
import CryptoKit

/// `sha256:<lowercase hex>` digests over JCS-encoded documents.
///
/// The origin and the Watch each recompute this from the full spec; neither
/// substitutes an advertised hash for the computation (spec.watch.md section 9).
public enum ContentDigest {
    public static let prefix = "sha256:"

    public static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Prefixed digest of arbitrary bytes, used for attachments and bodies.
    public static func digest(of bytes: Data) -> String {
        prefix + sha256Hex(bytes)
    }

    /// Prefixed digest of the JCS encoding of `value`.
    public static func digest(ofCanonical value: JSONValue) throws -> String {
        digest(of: try JSONCanonicalization.canonicalize(value))
    }

    /// Constant-time comparison so a digest check cannot be probed by timing.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
