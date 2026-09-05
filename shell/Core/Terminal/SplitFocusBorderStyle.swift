//
//  SplitFocusBorderStyle.swift
//  shell
//
//  Split focus border appearance settings
//

import UIKit

enum SplitFocusBorderStyle: String, CaseIterable, Codable {
    case none
    case subtle
    case standard
    case bold

    var displayName: String {
        switch self {
        case .none: return String(localized: "None", comment: "Split border style: no border")
        case .subtle: return String(localized: "Subtle", comment: "Split border style: subtle border")
        case .standard: return String(localized: "Standard", comment: "Split border style: standard border")
        case .bold: return String(localized: "Bold", comment: "Split border style: bold border")
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .none: return 0
        case .subtle: return 1
        case .standard: return 2
        case .bold: return 3
        }
    }

    var opacity: CGFloat {
        switch self {
        case .none: return 0
        case .subtle: return 0.5
        case .standard: return 1.0
        case .bold: return 1.0
        }
    }

    static let storageKey = "splitFocusBorderStyle"
}

enum SplitFocusBorderColor: String, CaseIterable, Codable {
    case accent
    case gray
    case custom

    var displayName: String {
        switch self {
        case .accent: return String(localized: "Accent", comment: "Split border color: accent color")
        case .gray: return String(localized: "Gray", comment: "Split border color: gray color")
        case .custom: return String(localized: "Custom", comment: "Split border color: custom color")
        }
    }

    static let storageKey = "splitFocusBorderColor"
    static let customHexKey = "splitFocusBorderCustomColor"
}

extension UIColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let toByte: (CGFloat) -> Int = { component in
            Int((max(0, min(component, 1)) * 255).rounded())
        }
        return String(format: "%02X%02X%02X", toByte(r), toByte(g), toByte(b))
    }
}
