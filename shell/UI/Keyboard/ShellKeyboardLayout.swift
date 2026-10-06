//
//  ShellKeyboardLayout.swift
//  shell
//
//  Declarative US-QWERTY layout for the Shell terminal keyboard: stable key
//  IDs, base/shifted output, literal-symbol semantics, rows, and sizing.
//  Labels are never wire data; dispatch uses the key kinds below.
//

import UIKit

// MARK: - Pages and Keys

enum ShellKeyboardPage: String, CaseIterable, Sendable {
    case letters
    case symbols
    case navigation
}

/// Named terminal keys. Encoded by the existing terminal key paths, never by
/// a table in the keyboard view.
enum ShellKeyboardNamedKey: String, CaseIterable, Sendable {
    case escape
    case tab
    case backtab
    case enter
    case backspace
    case forwardDelete
    case home
    case end
    case pageUp
    case pageDown

    /// Logical key for shortcut matching. Backtab is Tab plus Shift.
    var keyCode: KeyCode {
        switch self {
        case .escape: .escape
        case .tab, .backtab: .tab
        case .enter: .enter
        case .backspace: .backspace
        case .forwardDelete: .delete
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        }
    }

    var hidUsage: UIKeyboardHIDUsage {
        switch self {
        case .escape: .keyboardEscape
        case .tab, .backtab: .keyboardTab
        case .enter: .keyboardReturnOrEnter
        case .backspace: .keyboardDeleteOrBackspace
        case .forwardDelete: .keyboardDeleteForward
        case .home: .keyboardHome
        case .end: .keyboardEnd
        case .pageUp: .keyboardPageUp
        case .pageDown: .keyboardPageDown
        }
    }

    var impliesShift: Bool { self == .backtab }

    /// Backspace and Forward Delete repeat while held; nothing else does.
    var repeats: Bool { self == .backspace || self == .forwardDelete }
}

/// Keyboard-local actions. None writes terminal bytes.
enum ShellKeyboardLocalAction: Equatable, Sendable {
    case shift
    case page(ShellKeyboardPage)
    case system
    case clearModifiers
}

/// One printable key press, with its US-layout logical identity kept apart
/// from the text it inserts.
struct ShellKeyboardCharacter: Equatable, Sendable {
    /// Exactly what an unmodified (or Shift-only) press inserts.
    let text: Character
    /// The US base key that produces `text` (`{` → `[`).
    let baseKey: Character
    /// Whether the US layout needs Shift on `baseKey` to produce `text`.
    let impliesShift: Bool
    /// An explicitly labeled symbol key: the user's Shift never changes its
    /// text or its shortcut identity.
    var isLiteral = false

    var keyCode: KeyCode? { KeyCode(uiKeyInput: String(baseKey)) }
}

enum ShellKeyboardKeyKind: Equatable, Sendable {
    /// A base key whose output follows Shift via the US pairs (a→A, 1→!).
    case character(Character)
    /// An explicitly labeled symbol: always inserts exactly this character.
    case literal(Character)
    case named(ShellKeyboardNamedKey)
    case paste
    case local(ShellKeyboardLocalAction)

    /// Printable keys commit on release and may retarget within their row.
    var isPrintable: Bool {
        switch self {
        case .character, .literal: true
        default: false
        }
    }
}

struct ShellKeyboardKey: Equatable, Identifiable, Sendable {
    /// Stable identifier, also the accessibility identifier suffix.
    let id: String
    let kind: ShellKeyboardKeyKind
    /// Relative width in a 10-unit row.
    let width: CGFloat

    init(_ id: String, _ kind: ShellKeyboardKeyKind, width: CGFloat = 1) {
        self.id = id
        self.kind = kind
        self.width = width
    }

    /// The press this key produces with Shift (from the shared model).
    func character(shifted: Bool) -> ShellKeyboardCharacter? {
        switch kind {
        case .character(let base):
            let text = shifted ? ShellKeyboardLayout.shifted(base) : base
            return ShellKeyboardCharacter(text: text, baseKey: base, impliesShift: false)
        case .literal(let symbol):
            var identity = ShellKeyboardLayout.usIdentity(of: symbol)
            identity.isLiteral = true
            return identity
        default:
            return nil
        }
    }
}

struct ShellKeyboardRow: Equatable, Sendable {
    let keys: [ShellKeyboardKey]
    /// Empty units before the first key (row 3 is centered). Its hit region
    /// still belongs to the edge keys.
    let leadingInset: CGFloat

    init(_ keys: [ShellKeyboardKey], leadingInset: CGFloat = 0) {
        self.keys = keys
        self.leadingInset = leadingInset
    }

    var totalUnits: CGFloat { keys.reduce(0) { $0 + $1.width } + leadingInset * 2 }
}

// MARK: - Layout

enum ShellKeyboardLayout {
    static let rowUnits: CGFloat = 10
    static let rowCount = 5
    /// Narrowest content width the layout supports without overlap.
    static let minimumWidth: CGFloat = 320
    static let regularRowHeight: CGFloat = 44
    static let compactRowHeight: CGFloat = 38
    static let verticalPadding: CGFloat = 4

    // MARK: US pairs

    /// Characters a US keyboard types without Shift.
    static let usBaseCharacters: [Character] =
        Array("abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./` ")

    static func shifted(_ base: Character) -> Character {
        HardwareKeyboardText.shiftedCharacter(base)
    }

    /// Logical identity of a literal symbol under the declared US layout.
    static func usIdentity(of symbol: Character) -> ShellKeyboardCharacter {
        if usBaseCharacters.contains(symbol) {
            return ShellKeyboardCharacter(text: symbol, baseKey: symbol, impliesShift: false)
        }
        if let base = usBaseCharacters.first(where: { shifted($0) == symbol && $0 != symbol }) {
            return ShellKeyboardCharacter(text: symbol, baseKey: base, impliesShift: true)
        }
        return ShellKeyboardCharacter(text: symbol, baseKey: symbol, impliesShift: false)
    }

    // MARK: Pages

    static func rows(for page: ShellKeyboardPage) -> [ShellKeyboardRow] {
        switch page {
        case .letters: lettersRows
        case .symbols: symbolsRows
        case .navigation: navigationRows
        }
    }

    private static let numberRow = ShellKeyboardRow(
        "1234567890".map { ShellKeyboardKey("digit.\($0)", .character($0)) }
    )

    private static func letters(_ characters: String) -> [ShellKeyboardKey] {
        characters.map { ShellKeyboardKey("letter.\($0)", .character($0)) }
    }

    private static func literals(_ characters: String) -> [ShellKeyboardKey] {
        characters.map { ShellKeyboardKey("symbol.\(symbolID($0))", .literal($0)) }
    }

    private static let lettersRows: [ShellKeyboardRow] = [
        numberRow,
        ShellKeyboardRow(letters("qwertyuiop")),
        ShellKeyboardRow(letters("asdfghjkl"), leadingInset: 0.5),
        ShellKeyboardRow(
            [ShellKeyboardKey("shift", .local(.shift), width: 1.5)]
                + letters("zxcvbnm")
                + [ShellKeyboardKey("backspace", .named(.backspace), width: 1.5)]
        ),
        ShellKeyboardRow([
            ShellKeyboardKey("page.symbols", .local(.page(.symbols)), width: 1.25),
            ShellKeyboardKey("system", .local(.system), width: 1.25),
            ShellKeyboardKey("letters.slash", .character("/")),
            ShellKeyboardKey("space", .character(" "), width: 4),
            ShellKeyboardKey("letters.period", .character(".")),
            ShellKeyboardKey("return", .named(.enter), width: 1.5)
        ])
    ]

    private static let symbolsRows: [ShellKeyboardRow] = [
        numberRow,
        ShellKeyboardRow(literals("[]{}()<>|\\")),
        ShellKeyboardRow(literals("`~!@#$%^&,")),
        ShellKeyboardRow(
            [ShellKeyboardKey("shift", .local(.shift))]
                + literals("-_=+;:'\"")
                + [ShellKeyboardKey("backspace", .named(.backspace))]
        ),
        ShellKeyboardRow([
            ShellKeyboardKey("page.letters", .local(.page(.letters)), width: 1.25),
            ShellKeyboardKey("system", .local(.system), width: 1.25),
            ShellKeyboardKey("page.navigation", .local(.page(.navigation)), width: 1.25),
            ShellKeyboardKey("space", .character(" "), width: 3.25),
            ShellKeyboardKey("symbol.question", .literal("?")),
            ShellKeyboardKey("return", .named(.enter), width: 2)
        ])
    ]

    private static let navigationRows: [ShellKeyboardRow] = [
        numberRow,
        ShellKeyboardRow([
            ShellKeyboardKey("home", .named(.home), width: 2),
            ShellKeyboardKey("end", .named(.end), width: 2),
            ShellKeyboardKey("pageUp", .named(.pageUp), width: 2),
            ShellKeyboardKey("pageDown", .named(.pageDown), width: 2),
            ShellKeyboardKey("forwardDelete", .named(.forwardDelete), width: 2)
        ]),
        ShellKeyboardRow([
            ShellKeyboardKey("tab", .named(.tab), width: 2.5),
            ShellKeyboardKey("backtab", .named(.backtab), width: 2.5),
            ShellKeyboardKey("escape", .named(.escape), width: 2.5),
            ShellKeyboardKey("paste", .paste, width: 2.5)
        ]),
        ShellKeyboardRow([
            ShellKeyboardKey("shift", .local(.shift), width: 2.5),
            ShellKeyboardKey("clearModifiers", .local(.clearModifiers), width: 5),
            ShellKeyboardKey("backspace", .named(.backspace), width: 2.5)
        ]),
        ShellKeyboardRow([
            ShellKeyboardKey("page.letters", .local(.page(.letters)), width: 1.25),
            ShellKeyboardKey("system", .local(.system), width: 1.25),
            ShellKeyboardKey("page.symbols", .local(.page(.symbols)), width: 1.25),
            ShellKeyboardKey("space", .character(" "), width: 3.25),
            ShellKeyboardKey("navigation.slash", .literal("/")),
            ShellKeyboardKey("return", .named(.enter), width: 2)
        ])
    ]

    /// Every character an unmodified or Shift-only press can insert.
    static var reachableCharacters: Set<Character> {
        var result = Set<Character>()
        for page in ShellKeyboardPage.allCases {
            for row in rows(for: page) {
                for key in row.keys {
                    if let plain = key.character(shifted: false) { result.insert(plain.text) }
                    if let shifted = key.character(shifted: true) { result.insert(shifted.text) }
                }
            }
        }
        return result
    }

    private static func symbolID(_ symbol: Character) -> String {
        switch symbol {
        case "[": "leftBracket"
        case "]": "rightBracket"
        case "{": "leftBrace"
        case "}": "rightBrace"
        case "(": "leftParen"
        case ")": "rightParen"
        case "<": "lessThan"
        case ">": "greaterThan"
        case "|": "pipe"
        case "\\": "backslash"
        case "`": "backtick"
        case "~": "tilde"
        case "!": "exclamation"
        case "@": "at"
        case "#": "hash"
        case "$": "dollar"
        case "%": "percent"
        case "^": "caret"
        case "&": "ampersand"
        case ",": "comma"
        case "-": "minus"
        case "_": "underscore"
        case "=": "equal"
        case "+": "plus"
        case ";": "semicolon"
        case ":": "colon"
        case "'": "quote"
        case "\"": "doubleQuote"
        case "?": "question"
        case "/": "slash"
        default: String(symbol.unicodeScalars.first.map { $0.value } ?? 0)
        }
    }

    // MARK: Sizing

    /// Terminal height that must stay visible above the keyboard: two text
    /// rows. The engine reports cell size in pixels; geometry is in points.
    static func minimumTerminalHeight(cellPixelHeight: CGFloat, scale: CGFloat) -> CGFloat {
        max(44, cellPixelHeight / max(1, scale) * 2)
    }

    /// Body row height for the given vertical size class.
    static func rowHeight(for traits: UITraitCollection) -> CGFloat {
        traits.verticalSizeClass == .compact ? compactRowHeight : regularRowHeight
    }

    /// Body height above the bottom safe area.
    static func contentHeight(for traits: UITraitCollection) -> CGFloat {
        CGFloat(rowCount) * rowHeight(for: traits) + verticalPadding * 2
    }

    /// Key cells for one row: non-overlapping and spanning the full row width.
    /// Edge keys absorb the centering inset so the whole row stays hittable.
    static func cellFrames(for row: ShellKeyboardRow, in rect: CGRect) -> [CGRect] {
        guard !row.keys.isEmpty, rect.width > 0 else { return [] }
        let unit = rect.width / max(rowUnits, row.totalUnits)
        let used = row.keys.reduce(0) { $0 + $1.width } * unit
        var x = rect.minX + (rect.width - used) / 2
        var frames: [CGRect] = []
        for key in row.keys {
            let width = key.width * unit
            frames.append(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
            x += width
        }
        // Stretch the hit regions of the edge keys over any centering inset.
        frames[0] = CGRect(x: rect.minX, y: rect.minY, width: frames[0].maxX - rect.minX, height: rect.height)
        let last = frames.count - 1
        frames[last] = CGRect(x: frames[last].minX, y: rect.minY, width: rect.maxX - frames[last].minX, height: rect.height)
        return frames
    }

    /// Visual key frame inside its hit cell; the row inset is visual only.
    static func visualFrame(for key: ShellKeyboardKey, index: Int, in row: ShellKeyboardRow, cells: [CGRect], rowRect: CGRect) -> CGRect {
        let unit = rowRect.width / max(rowUnits, row.totalUnits)
        var cell = cells[index]
        if row.leadingInset > 0 {
            let inset = row.leadingInset * unit
            if index == 0 { cell.origin.x += inset; cell.size.width -= inset }
            if index == row.keys.count - 1 { cell.size.width -= inset }
        }
        return cell.insetBy(dx: 2.5, dy: 4)
    }
}
