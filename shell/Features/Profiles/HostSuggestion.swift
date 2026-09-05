//
//  HostSuggestion.swift
//  shell
//
//  Autocomplete source for the local shell's `ssh ` ghost text. The fork has
//  no host discovery, so saved SSH profiles are the only source.
//

import Foundation

/// How a suggestion is matched against what the user has typed.
enum MatchingMode {
    case prefix      // Match from the beginning (default)
    case substring   // Match anywhere in the string (double-tab)
}

/// Where a suggestion came from. Only profiles remain in this fork.
enum SuggestionSourceType: String, CaseIterable {
    case profile = "Profiles"
}

/// A completion candidate for a host argument.
struct AnyQuickConnectSuggestion: Identifiable, Hashable {
    let id: UUID
    let sourceType: SuggestionSourceType
    /// Shown in the inline preview.
    let displayString: String
    /// Inserted into the line when the user accepts the completion.
    let completionString: String
    /// Secondary line under the input.
    let detailText: String?
    /// Lower sorts first within a source type.
    let sortPriority: Int

    init(profile: SSHProfile, sortPriority: Int) {
        self.id = profile.id
        self.sourceType = .profile
        self.displayString = profile.displayString
        self.completionString = profile.displayString
        self.detailText = profile.name
        self.sortPriority = sortPriority
    }

    func matches(_ searchText: String, mode: MatchingMode) -> Bool {
        guard !searchText.isEmpty else { return true }
        let needle = searchText.lowercased()
        let haystacks = [completionString.lowercased(), displayString.lowercased()]
        switch mode {
        case .prefix:
            return haystacks.contains { $0.hasPrefix(needle) }
        case .substring:
            return haystacks.contains { $0.contains(needle) }
        }
    }
}

/// Supplies host completions from the saved SSH profiles.
@MainActor
enum QuickConnectSuggestionProvider {
    static let shared = QuickConnectSuggestionProvider.self

    /// Profiles matching `searchText`, most-recently-used first.
    static func getSuggestions(
        matching searchText: String,
        mode: MatchingMode = .prefix,
        limit: Int = 10
    ) -> [AnyQuickConnectSuggestion] {
        ConnectionProfileManager.shared.getSuggestions(matching: "", limit: .max)
            .enumerated()
            .map { AnyQuickConnectSuggestion(profile: $0.element, sortPriority: $0.offset) }
            .filter { $0.matches(searchText, mode: mode) }
            .prefix(limit)
            .map { $0 }
    }
}
