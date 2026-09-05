//
//  ThemeUIOverrides.swift
//  shell
//
//  Per-theme overrides for the derived non-terminal chrome colors used when
//  "Theme-Aware UI" is enabled. Each field is an optional hex string;
//  `nil` means "use the algorithmically derived default for this theme".
//

import Foundation

struct ThemeUIOverrides: Codable, Hashable, Sendable {
    // Sheet / modal chrome
    var sheetBackground: String?
    var sheetRowBackground: String?
    var sheetAccent: String?

    // Tab bar chrome
    var tabBarBackground: String?
    var selectedTabBackground: String?
    var unselectedTabBackground: String?
    var tabText: String?
    var tabSecondaryText: String?

    static let empty = ThemeUIOverrides()

    var isEmpty: Bool {
        sheetBackground == nil
            && sheetRowBackground == nil
            && sheetAccent == nil
            && tabBarBackground == nil
            && selectedTabBackground == nil
            && unselectedTabBackground == nil
            && tabText == nil
            && tabSecondaryText == nil
    }
}

enum ThemeUIOverrideField: String, CaseIterable, Sendable {
    case sheetBackground
    case sheetRowBackground
    case sheetAccent
    case tabBarBackground
    case selectedTabBackground
    case unselectedTabBackground
    case tabText
    case tabSecondaryText

    var displayName: String {
        switch self {
        case .sheetBackground: return String(localized: "Sheet Background")
        case .sheetRowBackground: return String(localized: "List Row Background")
        case .sheetAccent: return String(localized: "Accent")
        case .tabBarBackground: return String(localized: "Tab Bar Background")
        case .selectedTabBackground: return String(localized: "Selected Tab")
        case .unselectedTabBackground: return String(localized: "Unselected Tab")
        case .tabText: return String(localized: "Tab Text")
        case .tabSecondaryText: return String(localized: "Tab Secondary Text")
        }
    }
}

extension ThemeUIOverrides {
    subscript(field: ThemeUIOverrideField) -> String? {
        get {
            switch field {
            case .sheetBackground: return sheetBackground
            case .sheetRowBackground: return sheetRowBackground
            case .sheetAccent: return sheetAccent
            case .tabBarBackground: return tabBarBackground
            case .selectedTabBackground: return selectedTabBackground
            case .unselectedTabBackground: return unselectedTabBackground
            case .tabText: return tabText
            case .tabSecondaryText: return tabSecondaryText
            }
        }
        set {
            switch field {
            case .sheetBackground: sheetBackground = newValue
            case .sheetRowBackground: sheetRowBackground = newValue
            case .sheetAccent: sheetAccent = newValue
            case .tabBarBackground: tabBarBackground = newValue
            case .selectedTabBackground: selectedTabBackground = newValue
            case .unselectedTabBackground: unselectedTabBackground = newValue
            case .tabText: tabText = newValue
            case .tabSecondaryText: tabSecondaryText = newValue
            }
        }
    }
}
