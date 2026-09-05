import Foundation

enum BuildInfo {
    static let date: String = {
        guard
            let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "txt"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Unknown"
        }

        let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unknown" : value
    }()
}
