import Foundation
import CoreImage
import ShellControlSecurity

public enum PairingRenderer {
    /// The setup QR for the iPhone-gateway profile: bootstrap material only,
    /// shown next to the origin fingerprint for comparison on the phone
    /// (docs/specs/control-protocol.md sections 5.2 and 16).
    public static func invitationOutput(_ invitation: PairingInvitation, terminal: Bool) throws -> String {
        let link = try invitation.link().absoluteString
        var result = """
        Shell origin:
          \(invitation.origin.originID.rawValue)
          fingerprint: \(invitation.origin.fingerprint)
        route   \(invitation.route.url.absoluteString)
        expires \(invitation.expiresAt.rfc3339) (one use)
        link    \(link)

        """
        if terminal { result += "\n" + (try compactQR(link)) + "\n\nScan this QR in Shell on iPhone to pair.\n" }
        return result
    }

    /// The route-only QR. Scanning it updates routing and never changes trust
    /// (docs/specs/control-protocol.md sections 4.5 and 16).
    public static func routeOutput(_ update: OriginRouteUpdate, fingerprint: String, terminal: Bool) throws -> String {
        let link = try update.link().absoluteString
        var result = """
        origin  \(update.originID.rawValue)
        fingerprint: \(fingerprint)
        route   \(update.route.url.absoluteString)
        issued  \(update.issuedAt.rfc3339)
        link    \(link)

        """
        if terminal { result += "\n" + (try compactQR(link)) + "\n\nScan in Shell on iPhone: this is a route update, not a new pairing.\n" }
        return result
    }

    /// Two modules per character cell, so a pairing QR fits a terminal.
    static func compactQR(_ text: String) throws -> String {
        let (width, height, isDark) = try modules(text, correction: "L")
        let quiet = 2
        var lines: [String] = []
        var y = -quiet
        while y < height + quiet {
            var line = ""
            for x in (-quiet)..<(width + quiet) {
                let top = isDark(x, y), bottom = isDark(x, y + 1)
                switch (top, bottom) {
                case (true, true): line += " "
                case (true, false): line += "▄"
                case (false, true): line += "▀"
                case (false, false): line += "█"
                }
            }
            lines.append(line)
            y += 2
        }
        return lines.joined(separator: "\n")
    }

    private static func modules(_ text: String, correction: String) throws -> (Int, Int, (Int, Int) -> Bool) {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ManagementError.unavailable("native QR generator unavailable") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw ManagementError.unavailable("QR generation failed") }
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        guard let bitmap = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: extent),
              let data = bitmap.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw ManagementError.unavailable("QR rendering failed")
        }
        let stride = bitmap.bytesPerRow, channels = max(1, bitmap.bitsPerPixel / 8)
        let copy = Array(UnsafeBufferPointer(start: bytes, count: stride * height))
        return (width, height, { x, y in x >= 0 && y >= 0 && x < width && y < height && copy[y * stride + x * channels] < 128 })
    }
}
