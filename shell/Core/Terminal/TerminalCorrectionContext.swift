import Foundation

/// The UIKit document is not a terminal screen. It mirrors what UIKit believes
/// the field contains so IME composition and dictation can ask for accurate
/// positions and ranges. Nothing here grants UIKit authority to rewrite
/// committed terminal input — only dictation may replace text it just produced.
nonisolated struct TerminalCorrectionContext {
    enum Mutation {
        case text(String)
        case backspace
        case legacyDocument(String)
        case correction(Replacement)
        case reset
        case invalidate
    }

    struct Replacement {
        let payload: Data
        let document: String
        let generation: UInt64
        let documentGeneration: UInt64
    }

    private(set) var document = ""
    private(set) var generation: UInt64 = 0
    private(set) var documentGeneration: UInt64 = 0

    static func range(_ range: NSRange, in text: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let result = Range(range, in: text),
              (result.lowerBound == text.endIndex || text.indices.contains(result.lowerBound)),
              (result.upperBound == text.endIndex || text.indices.contains(result.upperBound)) else { return nil }
        return result
    }

    static func isPrintable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return true
            case .format:
                // Joiners and emoji tag sequences participate in legitimate
                // graphemes. Other invisible formatting controls are unsafe.
                return scalar.value != 0x200C && scalar.value != 0x200D
                    && !(0xE0020...0xE007F).contains(scalar.value)
            default:
                return false
            }
        }
    }

    @discardableResult
    mutating func apply(_ mutation: Mutation) -> Bool {
        switch mutation {
        case .correction(let replacement):
            return commit(replacement)
        case .invalidate:
            invalidate()
        case .reset:
            document = ""
            documentGeneration &+= 1
            invalidate()
        case .legacyDocument(let text):
            document = text
            documentGeneration &+= 1
            invalidate()
        case .text(let text):
            if text == "\r" || text == "\n" {
                document = ""
                documentGeneration &+= 1
            } else {
                document += text
            }
            invalidate()
        case .backspace:
            if !document.isEmpty {
                document.removeLast()
                documentGeneration &+= 1
            }
            invalidate()
        }
        boundDocument()
        return true
    }

    private mutating func invalidate() {
        generation &+= 1
    }

    private mutating func boundDocument() {
        if document.utf16.count > 4096 {
            document = Self.suffix(document, maxUTF16: 2048)
            generation &+= 1
            documentGeneration &+= 1
        }
    }

    private static func suffix(_ text: String, maxUTF16: Int) -> String {
        var start = text.endIndex
        var count = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let units = text[previous..<start].utf16.count
            guard count + units <= maxUTF16 else { break }
            start = previous
            count += units
        }
        return String(text[start...])
    }

    /// Build the byte payload that rewrites `range` to `text`. Dictation only —
    /// the writing assistant that used the non-dictation path is gone.
    func replacement(in range: NSRange, with text: String, generation expected: UInt64) -> Replacement? {
        guard expected == generation,
              let indices = Self.range(range, in: document) else { return nil }
        let erased = String(document[indices.lowerBound...])
        let replay = text + document[indices.upperBound...]
        var payload = Data(repeating: 0x7F, count: erased.count)
        payload.append(contentsOf: replay.replacingOccurrences(of: "\n", with: "\r").utf8)
        let updated = String(document[..<indices.lowerBound]) + replay
        return Replacement(payload: payload, document: updated,
                           generation: generation, documentGeneration: documentGeneration)
    }

    @discardableResult
    mutating func commit(_ replacement: Replacement) -> Bool {
        guard replacement.generation == generation,
              replacement.documentGeneration == documentGeneration else { return false }
        document = replacement.document
        documentGeneration &+= 1
        generation &+= 1
        boundDocument()
        return true
    }
}
