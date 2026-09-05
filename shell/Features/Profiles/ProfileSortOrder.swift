//
//  ProfileSortOrder.swift
//  shell
//
//  Sort order preference for the connection profiles browser.
//

import Foundation

enum ProfileSortOrder: String, CaseIterable, Codable, Sendable {
    case name
    case recentlyUsed
    case mostUsed
    case dateCreated

    static let storageKey = "profilesSortOrder"

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .recentlyUsed: return "Recently Used"
        case .mostUsed: return "Most Used"
        case .dateCreated: return "Date Created"
        }
    }

    func compare(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        switch self {
        case .name:
            return compareByName(lhs, rhs)
        case .recentlyUsed:
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case (let l?, let r?):
                if l != r { return l > r }
                return compareByName(lhs, rhs)
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return compareByName(lhs, rhs)
            }
        case .mostUsed:
            if lhs.useCount != rhs.useCount {
                return lhs.useCount > rhs.useCount
            }
            return compareByName(lhs, rhs)
        case .dateCreated:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return compareByName(lhs, rhs)
        }
    }

    private func compareByName(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
