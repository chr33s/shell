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
}

enum SplitFocusBorderColor: String, CaseIterable, Codable {
    case accent
    case gray
    case custom
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
}
