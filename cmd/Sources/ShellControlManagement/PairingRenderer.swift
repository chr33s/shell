import Foundation
import CoreImage
import ShellControlClient

public enum PairingRenderer {
    public static func output(publicURL: String, token: String, terminal: Bool) throws -> String {
        guard let broker = URL(string: publicURL),
              let link = ControlBrokerAddress.pairingLink(broker: broker, token: token) else {
            throw ManagementError.corrupt("saved pairing URL is invalid")
        }
        var page = URLComponents(url: broker.appendingPathComponent("pair"), resolvingAgainstBaseURL: false)!
        page.queryItems = [URLQueryItem(name: "token", value: token)]
        var result = "broker  \(publicURL)\npair    \(page.url!.absoluteString)\nlink    \(link.absoluteString)\ntoken   \(token)\n"
        if terminal { result += "\n" + (try qr(page.url!.absoluteString)) + "\n" }
        return result
    }

    private static func qr(_ text: String) throws -> String {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ManagementError.unavailable("native QR generator unavailable") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw ManagementError.unavailable("QR generation failed") }
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        guard let bitmap = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: extent),
              let data = bitmap.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw ManagementError.unavailable("QR rendering failed")
        }
        let stride = bitmap.bytesPerRow, channels = max(1, bitmap.bitsPerPixel / 8), quiet = 4
        var lines: [String] = []
        for y in (-quiet)..<(height + quiet) {
            var line = ""
            for x in (-quiet)..<(width + quiet) {
                let black = x >= 0 && y >= 0 && x < width && y < height && bytes[y * stride + x * channels] < 128
                line += black ? "\u{001B}[40m  " : "\u{001B}[47m  "
            }
            lines.append(line + "\u{001B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}
