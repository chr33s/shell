import Foundation

/// Reconciles Korean IME callbacks that arrive without UIKit marked text.
///
/// iOS Korean input commonly rewrites the current Hangul syllable as:
/// `deleteBackward()` followed by `insertText(_:)`, with no replacement range.
/// The terminal must not see that internal delete as a real DEL byte. This model
/// keeps the evolving syllable local as preedit and returns only text that is
/// safe to commit to the terminal byte stream.
struct TerminalKoreanCompositionModel {
    struct InsertResult: Equatable {
        var committedText: String
        var preeditText: String?
    }

    private(set) var preeditText: String?
    private var pendingReplacementDelete = false
    private var canDropSupersededReplacement = false
    private var inputGeneration = 0
    private var pendingReplacementGeneration: Int?
    private var replacementWindowGeneration: Int?
    private var canConsumeNoActiveDelete = false
    private var catalystState = CatalystHangulState()

    var hasActiveComposition: Bool {
        preeditText != nil || pendingReplacementDelete
    }

    var activeReplacementWindowToken: Int? {
        canDropSupersededReplacement ? replacementWindowGeneration : nil
    }

    var isAwaitingReplacementInsert: Bool {
        pendingReplacementDelete
    }

    var activePendingReplacementToken: Int? {
        pendingReplacementDelete ? pendingReplacementGeneration : nil
    }

    mutating func beginInputKey(allowNoActiveDelete: Bool = false) -> Bool {
        inputGeneration += 1
        canDropSupersededReplacement = false
        replacementWindowGeneration = nil
        canConsumeNoActiveDelete = allowNoActiveDelete

        guard pendingReplacementDelete else { return false }

        pendingReplacementDelete = false
        pendingReplacementGeneration = nil
        preeditText = nil
        return true
    }

    mutating func expireReplacementWindow(token: Int) -> Bool {
        guard canDropSupersededReplacement,
              replacementWindowGeneration == token else {
            return false
        }

        canDropSupersededReplacement = false
        replacementWindowGeneration = nil
        return true
    }

    mutating func handleInsert(_ text: String) -> InsertResult? {
        let normalized = text.precomposedStringWithCanonicalMapping
        canConsumeNoActiveDelete = false

        guard Self.isKoreanCompositionText(normalized) else { return nil }

        let characters = Array(normalized)
        guard let last = characters.last else { return nil }

        let wasReplacement = pendingReplacementDelete
        let previousPreedit = preeditText
        let shouldDropSupersededReplacement = !wasReplacement
            && canDropSupersededReplacement
            && previousPreedit != nil
        pendingReplacementDelete = false
        pendingReplacementGeneration = nil

        var committedText = ""
        if wasReplacement || shouldDropSupersededReplacement {
            if characters.count > 1 {
                committedText = String(characters.dropLast())
            }
        } else {
            if let previousPreedit {
                committedText += previousPreedit
            } else if characters.count > 1 {
                // Multi-character inserts with no active composition are more
                // likely paste/dictation/autocorrection than Korean rewrite.
                return nil
            }

            if characters.count > 1 {
                committedText += String(characters.dropLast())
            }
        }

        preeditText = String(last)
        let keepsReplacementWindow = wasReplacement || shouldDropSupersededReplacement
        if keepsReplacementWindow {
            replacementWindowGeneration = inputGeneration
        } else {
            replacementWindowGeneration = nil
        }
        canDropSupersededReplacement = keepsReplacementWindow
        return InsertResult(committedText: committedText, preeditText: preeditText)
    }

    mutating func handleCatalystInsert(_ text: String) -> InsertResult? {
        let normalized = text.precomposedStringWithCanonicalMapping
        canConsumeNoActiveDelete = false

        guard Self.isKoreanCompositionText(normalized) else { return nil }

        if pendingReplacementDelete {
            return handleInsert(normalized)
        }

        let characters = Array(normalized)
        guard let last = characters.last else { return nil }

        if characters.count == 1,
           let result = handleCatalystJamo(last) {
            return result
        }

        let previousPreedit = preeditText
        pendingReplacementGeneration = nil
        canDropSupersededReplacement = false
        replacementWindowGeneration = nil
        catalystState.clear()

        if characters.count > 1 {
            preeditText = String(last)
            return InsertResult(
                committedText: String(characters.dropLast()),
                preeditText: preeditText
            )
        }

        if previousPreedit == normalized {
            preeditText = nil
            return InsertResult(committedText: normalized, preeditText: nil)
        }

        preeditText = normalized
        return InsertResult(committedText: "", preeditText: preeditText)
    }

    private mutating func handleCatalystJamo(_ character: Character) -> InsertResult? {
        pendingReplacementDelete = false
        pendingReplacementGeneration = nil
        canDropSupersededReplacement = false
        replacementWindowGeneration = nil

        if let consonant = Self.modernConsonants[character] {
            return handleCatalystConsonant(consonant)
        }

        if let vowel = Self.modernVowels[character] {
            return handleCatalystVowel(vowel)
        }

        return nil
    }

    private mutating func handleCatalystConsonant(_ consonant: CatalystConsonant) -> InsertResult {
        var committed = ""

        if catalystState.leadingIndex == nil {
            if catalystState.vowelIndex != nil {
                committed = catalystState.preeditText() ?? preeditText ?? ""
                catalystState.clear()
            }
            catalystState.leadingIndex = consonant.leadingIndex
        } else if catalystState.vowelIndex == nil {
            if let combinedLeading = Self.combineLeading(
                catalystState.leadingIndex,
                consonant.leadingIndex
            ) {
                catalystState.leadingIndex = combinedLeading
            } else {
                committed = catalystState.preeditText() ?? preeditText ?? ""
                catalystState.leadingIndex = consonant.leadingIndex
            }
        } else if let trailing = consonant.trailingIndex {
            if let existingTrailing = catalystState.trailingIndex {
                if let combinedTrailing = Self.combineTrailing(existingTrailing, trailing) {
                    catalystState.trailingIndex = combinedTrailing
                } else {
                    committed = catalystState.preeditText() ?? preeditText ?? ""
                    catalystState = CatalystHangulState(leadingIndex: consonant.leadingIndex)
                }
            } else {
                catalystState.trailingIndex = trailing
            }
        } else {
            committed = catalystState.preeditText() ?? preeditText ?? ""
            catalystState = CatalystHangulState(leadingIndex: consonant.leadingIndex)
        }

        preeditText = catalystState.preeditText()
        return InsertResult(committedText: committed, preeditText: preeditText)
    }

    private mutating func handleCatalystVowel(_ vowel: Int) -> InsertResult {
        var committed = ""

        if catalystState.leadingIndex == nil {
            if let existingVowel = catalystState.vowelIndex,
               let combinedVowel = Self.combineVowel(existingVowel, vowel) {
                catalystState.vowelIndex = combinedVowel
            } else {
                if catalystState.vowelIndex != nil {
                    committed = catalystState.preeditText() ?? preeditText ?? ""
                }
                catalystState = CatalystHangulState(vowelIndex: vowel)
            }
        } else if catalystState.vowelIndex == nil {
            catalystState.vowelIndex = vowel
        } else if let trailing = catalystState.trailingIndex,
                  let split = Self.splitTrailingBeforeVowel(trailing) {
            catalystState.trailingIndex = split.remainingTrailingIndex
            committed = catalystState.preeditText() ?? preeditText ?? ""
            catalystState = CatalystHangulState(
                leadingIndex: split.nextLeadingIndex,
                vowelIndex: vowel
            )
        } else if let existingVowel = catalystState.vowelIndex,
                  let combinedVowel = Self.combineVowel(existingVowel, vowel) {
            catalystState.vowelIndex = combinedVowel
        } else {
            committed = catalystState.preeditText() ?? preeditText ?? ""
            catalystState = CatalystHangulState(vowelIndex: vowel)
        }

        preeditText = catalystState.preeditText()
        return InsertResult(committedText: committed, preeditText: preeditText)
    }

    mutating func handleCatalystDeleteBackward() -> Bool {
        guard preeditText != nil || !catalystState.isEmpty else {
            return false
        }

        pendingReplacementDelete = false
        pendingReplacementGeneration = nil
        canDropSupersededReplacement = false
        replacementWindowGeneration = nil
        canConsumeNoActiveDelete = false
        loadCatalystStateFromPreeditIfNeeded()

        if let trailing = catalystState.trailingIndex {
            catalystState.trailingIndex = Self.decomposeTrailing(trailing)
        } else if let vowel = catalystState.vowelIndex {
            catalystState.vowelIndex = Self.decomposeVowel(vowel)
        } else if let leading = catalystState.leadingIndex {
            catalystState.leadingIndex = Self.decomposeLeading(leading)
        } else {
            preeditText = nil
            return true
        }

        preeditText = catalystState.preeditText()
        return true
    }

    private mutating func loadCatalystStateFromPreeditIfNeeded() {
        guard catalystState.isEmpty, let preeditText else { return }

        let characters = Array(preeditText)
        guard characters.count == 1, let character = characters.first else { return }

        if let syllableState = Self.catalystState(fromModernSyllable: character) {
            catalystState = syllableState
        } else if let consonant = Self.modernConsonants[character] {
            catalystState = CatalystHangulState(leadingIndex: consonant.leadingIndex)
        } else if let vowel = Self.modernVowels[character] {
            catalystState = CatalystHangulState(vowelIndex: vowel)
        }
    }

    mutating func handleDeleteBackward() -> Bool {
        guard preeditText != nil || pendingReplacementDelete else {
            guard canConsumeNoActiveDelete else { return false }
            canConsumeNoActiveDelete = false
            return true
        }

        canConsumeNoActiveDelete = false
        pendingReplacementDelete = true
        pendingReplacementGeneration = inputGeneration
        canDropSupersededReplacement = false
        replacementWindowGeneration = nil
        return true
    }

    mutating func finishPendingDeleteIfUnreplaced(token: Int) -> Bool {
        guard pendingReplacementDelete,
              pendingReplacementGeneration == token else {
            return false
        }

        pendingReplacementDelete = false
        pendingReplacementGeneration = nil
        canDropSupersededReplacement = false
        replacementWindowGeneration = nil
        canConsumeNoActiveDelete = false
        preeditText = nil
        return true
    }

    mutating func commitPreedit() -> String? {
        defer {
            pendingReplacementDelete = false
            pendingReplacementGeneration = nil
            canDropSupersededReplacement = false
            replacementWindowGeneration = nil
            canConsumeNoActiveDelete = false
            catalystState.clear()
            preeditText = nil
        }

        guard !pendingReplacementDelete else { return nil }
        return preeditText
    }

    mutating func clear() -> Bool {
        let changed = preeditText != nil || pendingReplacementDelete
        preeditText = nil
        pendingReplacementDelete = false
        pendingReplacementGeneration = nil
        canDropSupersededReplacement = false
        replacementWindowGeneration = nil
        canConsumeNoActiveDelete = false
        catalystState.clear()
        return changed
    }

    static func isKoreanCompositionText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x1100...0x11FF,   // Hangul Jamo
                 0x3130...0x318F,   // Hangul Compatibility Jamo
                 0xA960...0xA97F,   // Hangul Jamo Extended-A
                 0xAC00...0xD7AF,   // Hangul Syllables
                 0xD7B0...0xD7FF:   // Hangul Jamo Extended-B
                return true
            default:
                return false
            }
        }
    }

    static func isTransientHardwareTextDuringReplacement(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first else {
            return false
        }

        return scalar.value >= 0x20 && scalar.value < 0x7F
    }

    private struct CatalystConsonant {
        var leadingIndex: Int
        var trailingIndex: Int?
    }

    private struct CatalystHangulState {
        var leadingIndex: Int?
        var vowelIndex: Int?
        var trailingIndex: Int?

        var isEmpty: Bool {
            leadingIndex == nil && vowelIndex == nil && trailingIndex == nil
        }

        mutating func clear() {
            leadingIndex = nil
            vowelIndex = nil
            trailingIndex = nil
        }

        func preeditText() -> String? {
            guard let leading = leadingIndex else {
                guard let vowel = vowelIndex else { return nil }
                return TerminalKoreanCompositionModel.modernVowelCharacters[vowel]
            }

            guard let vowel = vowelIndex else {
                return TerminalKoreanCompositionModel.modernLeadingCharacters[leading]
            }

            let trailing = trailingIndex ?? 0
            let scalarValue = 0xAC00 + ((leading * 21) + vowel) * 28 + trailing
            guard let scalar = UnicodeScalar(scalarValue) else { return nil }
            return String(Character(scalar))
        }
    }

    private static let modernLeadingCharacters = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ",
        "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]

    private static let modernVowelCharacters = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ",
        "ㅘ", "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ",
        "ㅡ", "ㅢ", "ㅣ"
    ]

    private static let modernConsonants: [Character: CatalystConsonant] = [
        "ㄱ": CatalystConsonant(leadingIndex: 0, trailingIndex: 1),
        "ㄲ": CatalystConsonant(leadingIndex: 1, trailingIndex: 2),
        "ㄴ": CatalystConsonant(leadingIndex: 2, trailingIndex: 4),
        "ㄷ": CatalystConsonant(leadingIndex: 3, trailingIndex: 7),
        "ㄸ": CatalystConsonant(leadingIndex: 4, trailingIndex: nil),
        "ㄹ": CatalystConsonant(leadingIndex: 5, trailingIndex: 8),
        "ㅁ": CatalystConsonant(leadingIndex: 6, trailingIndex: 16),
        "ㅂ": CatalystConsonant(leadingIndex: 7, trailingIndex: 17),
        "ㅃ": CatalystConsonant(leadingIndex: 8, trailingIndex: nil),
        "ㅅ": CatalystConsonant(leadingIndex: 9, trailingIndex: 19),
        "ㅆ": CatalystConsonant(leadingIndex: 10, trailingIndex: 20),
        "ㅇ": CatalystConsonant(leadingIndex: 11, trailingIndex: 21),
        "ㅈ": CatalystConsonant(leadingIndex: 12, trailingIndex: 22),
        "ㅉ": CatalystConsonant(leadingIndex: 13, trailingIndex: nil),
        "ㅊ": CatalystConsonant(leadingIndex: 14, trailingIndex: 23),
        "ㅋ": CatalystConsonant(leadingIndex: 15, trailingIndex: 24),
        "ㅌ": CatalystConsonant(leadingIndex: 16, trailingIndex: 25),
        "ㅍ": CatalystConsonant(leadingIndex: 17, trailingIndex: 26),
        "ㅎ": CatalystConsonant(leadingIndex: 18, trailingIndex: 27)
    ]

    private static let modernVowels: [Character: Int] = [
        "ㅏ": 0, "ㅐ": 1, "ㅑ": 2, "ㅒ": 3, "ㅓ": 4, "ㅔ": 5,
        "ㅕ": 6, "ㅖ": 7, "ㅗ": 8, "ㅘ": 9, "ㅙ": 10, "ㅚ": 11,
        "ㅛ": 12, "ㅜ": 13, "ㅝ": 14, "ㅞ": 15, "ㅟ": 16,
        "ㅠ": 17, "ㅡ": 18, "ㅢ": 19, "ㅣ": 20
    ]

    private static let leadingCombinations: [Int: [Int: Int]] = [
        0: [0: 1],
        3: [3: 4],
        7: [7: 8],
        9: [9: 10],
        12: [12: 13]
    ]

    private static let vowelCombinations: [Int: [Int: Int]] = [
        8: [0: 9, 1: 10, 20: 11],
        13: [4: 14, 5: 15, 20: 16],
        18: [20: 19]
    ]

    private static let trailingCombinations: [Int: [Int: Int]] = [
        1: [1: 2, 19: 3],
        4: [22: 5, 27: 6],
        8: [1: 9, 16: 10, 17: 11, 19: 12, 25: 13, 26: 14, 27: 15],
        17: [19: 18],
        19: [19: 20]
    ]

    private static let leadingDecompositions: [Int: Int] = [
        1: 0,
        4: 3,
        8: 7,
        10: 9,
        13: 12
    ]

    private static let vowelDecompositions: [Int: Int] = [
        9: 8,
        10: 8,
        11: 8,
        14: 13,
        15: 13,
        16: 13,
        19: 18
    ]

    private static let trailingDecompositions: [Int: Int] = [
        2: 1,
        3: 1,
        5: 4,
        6: 4,
        9: 8,
        10: 8,
        11: 8,
        12: 8,
        13: 8,
        14: 8,
        15: 8,
        18: 17,
        20: 19
    ]

    private static let trailingSplits: [Int: (remainingTrailingIndex: Int?, nextLeadingIndex: Int)] = [
        1: (nil, 0),
        2: (nil, 1),
        3: (1, 9),
        4: (nil, 2),
        5: (4, 12),
        6: (4, 18),
        7: (nil, 3),
        8: (nil, 5),
        9: (8, 0),
        10: (8, 6),
        11: (8, 7),
        12: (8, 9),
        13: (8, 16),
        14: (8, 17),
        15: (8, 18),
        16: (nil, 6),
        17: (nil, 7),
        18: (17, 9),
        19: (nil, 9),
        20: (nil, 10),
        21: (nil, 11),
        22: (nil, 12),
        23: (nil, 14),
        24: (nil, 15),
        25: (nil, 16),
        26: (nil, 17),
        27: (nil, 18)
    ]

    private static func combineLeading(_ first: Int?, _ second: Int?) -> Int? {
        guard let first, let second else { return nil }
        return leadingCombinations[first]?[second]
    }

    private static func combineVowel(_ first: Int, _ second: Int) -> Int? {
        vowelCombinations[first]?[second]
    }

    private static func combineTrailing(_ first: Int, _ second: Int) -> Int? {
        trailingCombinations[first]?[second]
    }

    private static func splitTrailingBeforeVowel(
        _ trailing: Int
    ) -> (remainingTrailingIndex: Int?, nextLeadingIndex: Int)? {
        trailingSplits[trailing]
    }

    private static func decomposeLeading(_ leading: Int) -> Int? {
        leadingDecompositions[leading]
    }

    private static func decomposeVowel(_ vowel: Int) -> Int? {
        vowelDecompositions[vowel]
    }

    private static func decomposeTrailing(_ trailing: Int) -> Int? {
        trailingDecompositions[trailing]
    }

    private static func catalystState(fromModernSyllable character: Character) -> CatalystHangulState? {
        guard let scalarValue = character.unicodeScalars.first?.value,
              character.unicodeScalars.count == 1,
              scalarValue >= 0xAC00,
              scalarValue <= 0xD7A3 else {
            return nil
        }

        let offset = Int(scalarValue - 0xAC00)
        let leading = offset / (21 * 28)
        let vowel = (offset % (21 * 28)) / 28
        let trailing = offset % 28
        return CatalystHangulState(
            leadingIndex: leading,
            vowelIndex: vowel,
            trailingIndex: trailing == 0 ? nil : trailing
        )
    }

}
