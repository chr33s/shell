import Foundation
import SwifttyCore

/// The settings Shell writes to `$XDG_CONFIG_HOME/ghostty/config`, parsed
/// from Ghostty's `key = value` format. Unknown keys are ignored; malformed
/// values become diagnostics.
final class Config: @unchecked Sendable {
    enum CursorStyleSetting: String { case block, bar, underline, blockHollow = "block_hollow" }
    enum SelectionColors: Equatable { case theme, invert, custom(fg: UInt32?, bg: UInt32?) }
    enum OptionAsAlt: String { case none = "false", both = "true", left, right }

    var theme: String?
    var fontSize: Double = 13
    var fontFamily: String?
    var fontFeatures: [String] = []
    var adjustCellWidth: Double = 0 // percent
    var adjustCellHeight: Double = 0 // percent
    var scrollbackLines = 10000
    var copyOnSelect = true
    var optionAsAlt = OptionAsAlt.none
    var clipboardRead = true
    var clipboardWrite = true
    var pasteSafeNewline = true
    var backgroundOpacity = 1.0
    var paddingX = 2.0 // points
    var paddingY = 2.0
    var paddingBalance = false
    var cursorStyle = CursorStyleSetting.block
    var cursorBlink: Bool?
    var cursorColor: UInt32?
    var cursorText: UInt32?
    var cursorOpacity = 1.0
    var selection = SelectionColors.theme
    var keybinds: [Keybind] = Keybind.defaults

    // Theme colours (nil = Palette.standard).
    var palette = Palette.standard
    var themeSelectionBackground: UInt32?
    var themeSelectionForeground: UInt32?
    var themeCursorText: UInt32?

    private(set) var diagnostics: [String] = []
    private var themeResolved = false
    private var keybindsCleared = false

    init() {}

    func clone() -> Config {
        let c = Config()
        c.theme = theme; c.fontSize = fontSize; c.fontFamily = fontFamily
        c.fontFeatures = fontFeatures; c.adjustCellWidth = adjustCellWidth; c.adjustCellHeight = adjustCellHeight
        c.scrollbackLines = scrollbackLines; c.copyOnSelect = copyOnSelect; c.optionAsAlt = optionAsAlt
        c.clipboardRead = clipboardRead; c.clipboardWrite = clipboardWrite; c.pasteSafeNewline = pasteSafeNewline
        c.backgroundOpacity = backgroundOpacity; c.paddingX = paddingX; c.paddingY = paddingY
        c.paddingBalance = paddingBalance; c.cursorStyle = cursorStyle; c.cursorBlink = cursorBlink
        c.cursorColor = cursorColor; c.cursorText = cursorText; c.cursorOpacity = cursorOpacity
        c.selection = selection; c.keybinds = keybinds; c.palette = palette
        c.themeSelectionBackground = themeSelectionBackground; c.themeSelectionForeground = themeSelectionForeground
        c.themeCursorText = themeCursorText; c.diagnostics = diagnostics; c.themeResolved = themeResolved
        c.keybindsCleared = keybindsCleared
        return c
    }

    // MARK: Loading

    static var defaultFilePath: String? {
        guard let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] else { return nil }
        return (base as NSString).appendingPathComponent("ghostty/config")
    }

    func loadDefaultFiles() {
        guard let path = Self.defaultFilePath, FileManager.default.fileExists(atPath: path) else { return }
        load(path: path)
    }

    func load(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            diagnostics.append("unable to read config file \(path)")
            return
        }
        load(text: text)
    }

    func load(text: String) {
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !set(key, value) {
                diagnostics.append("line \(number + 1): invalid value for \(key): \(value)")
            }
        }
    }

    /// Applies one setting; false when the value does not parse.
    private func set(_ key: String, _ value: String) -> Bool {
        switch key {
        case "theme": theme = value.isEmpty ? nil : value; themeResolved = false
        case "font-size": guard let v = Double(value), v > 0 else { return false }; fontSize = v
        case "font-family": fontFamily = value.isEmpty ? nil : value
        case "font-feature": fontFeatures.append(value)
        case "adjust-cell-width": guard let v = Self.percent(value) else { return false }; adjustCellWidth = v
        case "adjust-cell-height": guard let v = Self.percent(value) else { return false }; adjustCellHeight = v
        case "scrollback-limit-lines": guard let v = Int(value), v >= 0 else { return false }; scrollbackLines = v
        case "copy-on-select": copyOnSelect = value != "false"
        case "macos-option-as-alt": guard let v = OptionAsAlt(rawValue: value) else { return false }; optionAsAlt = v
        case "clipboard-read": clipboardRead = value != "deny"
        case "clipboard-write": clipboardWrite = value != "deny"
        case "clipboard-paste-bracketed-safe-newline": pasteSafeNewline = value == "true"
        case "background-opacity": guard let v = Double(value) else { return false }; backgroundOpacity = min(max(v, 0), 1)
        case "window-padding-x": guard let v = Self.firstNumber(value) else { return false }; paddingX = v
        case "window-padding-y": guard let v = Self.firstNumber(value) else { return false }; paddingY = v
        case "window-padding-balance": paddingBalance = value == "true"
        case "cursor-style": guard let v = CursorStyleSetting(rawValue: value) else { return false }; cursorStyle = v
        case "cursor-style-blink": cursorBlink = value.isEmpty ? nil : value == "true"
        case "cursor-color": cursorColor = Self.color(value)
        case "cursor-text": cursorText = Self.color(value)
        case "cursor-opacity": guard let v = Double(value) else { return false }; cursorOpacity = min(max(v, 0), 1)
        case "selection-invert-fg-bg": if value == "true" { selection = .invert } else if selection == .invert { selection = .theme }
        case "selection-foreground", "selection-background":
            guard let c = Self.color(value) else { return false }
            var fg: UInt32?, bg: UInt32?
            if case let .custom(f, b) = selection { fg = f; bg = b }
            if key == "selection-foreground" { fg = c } else { bg = c }
            selection = .custom(fg: fg, bg: bg)
        case "keybind":
            if value == "clear" {
                keybinds = []
                keybindsCleared = true
            } else if let bind = Keybind(value) {
                keybinds.removeAll { $0.trigger == bind.trigger }
                if bind.action != "unbind" {
                    keybinds.append(bind)
                }
            } else {
                return false
            }
        default: break // other Ghostty keys have no effect here
        }
        return true
    }

    /// Resolves the theme file into the palette. Themes live in
    /// `$GHOSTTY_RESOURCES_DIR/themes/<name>`.
    func finalize() {
        guard !themeResolved else { return }
        themeResolved = true
        palette = .standard
        themeSelectionBackground = nil
        themeSelectionForeground = nil
        themeCursorText = nil
        guard let theme else { return }
        let candidates: [String] = {
            var dirs: [String] = []
            if let resources = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] {
                dirs.append((resources as NSString).appendingPathComponent("themes"))
            }
            if let config = Self.defaultFilePath {
                dirs.append(((config as NSString).deletingLastPathComponent as NSString).appendingPathComponent("themes"))
            }
            return dirs.map { ($0 as NSString).appendingPathComponent(theme) }
        }()
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            diagnostics.append("theme \"\(theme)\" not found")
            return
        }
        applyTheme(text)
    }

    func applyTheme(_ text: String) {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": if let c = Self.color(value) { palette.background = c }
            case "foreground": if let c = Self.color(value) { palette.foreground = c }
            case "cursor-color": if let c = Self.color(value) { palette.cursor = c }
            case "cursor-text": themeCursorText = Self.color(value)
            case "selection-background": themeSelectionBackground = Self.color(value)
            case "selection-foreground": themeSelectionForeground = Self.color(value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   (0 ..< 256).contains(index), let c = Self.color(parts[1].trimmingCharacters(in: .whitespaces)) {
                    palette.colors[index] = c
                }
            default: break
            }
        }
    }

    var diagnosticCount: Int {
        diagnostics.count
    }

    func diagnostic(_ i: Int) -> String? {
        i >= 0 && i < diagnostics.count ? diagnostics[i] : nil
    }

    // MARK: Derived

    /// Cursor colour, falling back to the theme then the foreground.
    var effectiveCursorColor: UInt32 {
        cursorColor ?? palette.cursor
    }

    var effectiveSelection: (fg: UInt32?, bg: UInt32?, invert: Bool) {
        switch selection {
        case .invert: (nil, nil, true)
        case let .custom(fg, bg): (fg ?? themeSelectionForeground, bg ?? themeSelectionBackground, false)
        case .theme:
            if themeSelectionBackground == nil, themeSelectionForeground == nil {
                (nil, nil, true)
            } else {
                (themeSelectionForeground, themeSelectionBackground, false)
            }
        }
    }

    /// Font family to render with: the configured one, else the bundled
    /// Geist Mono, else the system monospaced font (CoreText's fallback).
    var effectiveFontFamily: String {
        fontFamily ?? "Geist Mono"
    }

    // MARK: Parsing helpers

    static func color(_ s: String) -> UInt32? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return v
    }

    static func percent(_ s: String) -> Double? {
        Double(s.hasSuffix("%") ? String(s.dropLast()) : s)
    }

    static func firstNumber(_ s: String) -> Double? {
        Double(s.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? s)
    }
}
