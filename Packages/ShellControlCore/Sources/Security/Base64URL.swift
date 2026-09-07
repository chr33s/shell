import Foundation

/// Unpadded base64url, as JOSE requires (RFC 7515).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-")
        text = text.replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    public static func decode(_ text: String) -> Data? {
        // Padding characters are not valid in a JOSE segment: rejecting them
        // keeps a signature's byte representation canonical.
        guard !text.contains("="), !text.contains("+"), !text.contains("/") else { return nil }
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }
}
