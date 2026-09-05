//
//  InputSourceSwitcher.swift
//  shell
//
//  Lists the system input sources the user can pick for a Mod-Tap binding.
//
//  Switching is realized by TerminalView's `preferredInputLanguage` +
//  textInputMode override on iPad/visionOS (see TerminalView+InputMode.swift).
//  On Mac Catalyst, switching uses Carbon TIS — the UIKit override is not
//  honored by AppKit's input-source machinery on Catalyst, and matching
//  UITextInputMode languages against TIS sources is fragile (the two
//  namespaces disagree on identifier granularity), so on Catalyst we
//  enumerate TIS sources directly and persist the TIS source ID
//  (e.g. "com.apple.keylayout.ABC") as the binding's identifier.
//
//  The `InputSourceDescriptor.primaryLanguage` field is therefore a
//  platform-defined opaque identifier: a UITextInputMode primaryLanguage
//  on iPad/visionOS, a TIS source ID on Catalyst. Stored rules round-trip
//  on the device they were created on; cross-platform-sourced rules will
//  silently fall through.
//

import Foundation
import UIKit
import os

// On Mac Catalyst, the TIS entry points used below come from
// InputSourceCarbonShim.swift (the Carbon umbrella header doesn't
// compile under the current Catalyst SDK).

/// A user-selectable input source.
struct InputSourceDescriptor: Hashable, Identifiable, Sendable {
    /// Opaque platform identifier. UITextInputMode primary language on iPad/visionOS,
    /// TIS source ID (e.g. "com.apple.keylayout.ABC") on Mac Catalyst.
    let primaryLanguage: String
    /// Localized name suitable for a picker row.
    let displayName: String

    var id: String { primaryLanguage }
}

@MainActor
enum InputSourceCatalog {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "InputSources")

    /// Input sources the user can pick for a binding.
    static func available() -> [InputSourceDescriptor] {
        #if targetEnvironment(macCatalyst)
        return catalystAvailable()
        #else
        return uikitAvailable()
        #endif
    }

    // MARK: - iPad / visionOS

    private static func uikitAvailable() -> [InputSourceDescriptor] {
        var seen = Set<String>()
        var result: [InputSourceDescriptor] = []
        for mode in UITextInputMode.activeInputModes {
            guard let lang = mode.primaryLanguage, !lang.isEmpty else { continue }
            // "emoji" (and "dictation") are pseudo input modes, not real
            // switchable text keyboards — the textInputMode override can't land
            // on them (the keyboard just flashes and reverts), so never offer
            // them for binding or cycling.
            guard lang != "emoji", lang != "dictation" else { continue }
            guard seen.insert(lang).inserted else { continue }
            let display = Locale.current.localizedString(forIdentifier: lang) ?? lang
            result.append(InputSourceDescriptor(primaryLanguage: lang, displayName: display))
        }
        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Mac Catalyst

    #if targetEnvironment(macCatalyst)

    private struct CatalystCurrentInputSourceSnapshot {
        let languages: [String]
        let sourceID: String?
        let expiresAt: TimeInterval
    }

    private static var catalystCurrentInputSourceSnapshot: CatalystCurrentInputSourceSnapshot?
    private static let catalystCurrentInputSourceSnapshotTTL: TimeInterval = 0.2

    private static func catalystAvailable() -> [InputSourceDescriptor] {
        (MacSupport.bridge?.inputSources() ?? []).compactMap { source in
            guard let id = source["id"], let name = source["name"] else { return nil }
            return InputSourceDescriptor(primaryLanguage: id, displayName: name)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @discardableResult
    static func catalystSwitch(toPrimaryLanguage target: String) -> Bool {
        guard MacSupport.bridge?.selectInputSource(target) == true else { return false }
        invalidateCatalystCurrentInputSourceSnapshot()
        return true
    }

    static func currentSourceID() -> String? { MacSupport.bridge?.currentInputSourceID() }

    /// True when the currently-selected macOS input source advertises any of
    /// the requested BCP-47 language prefixes. Falls back to the source ID for
    /// input methods whose UIKit language identifier is too coarse or absent.
    static func catalystCurrentInputSourceHasLanguagePrefix(_ prefixes: [String]) -> Bool {
        guard let snapshot = catalystCurrentInputSourceSnapshotValue() else { return false }

        let normalizedPrefixes = prefixes.map { $0.lowercased() }
        if snapshot.languages.contains(where: { language in
            normalizedPrefixes.contains { language.hasPrefix($0) }
        }) {
            return true
        }

        guard let sourceID = snapshot.sourceID else { return false }

        return normalizedPrefixes.contains { prefix in
            sourceID.contains(".\(prefix)")
                || sourceID.contains("\(prefix)-")
                || sourceID.contains("_\(prefix)")
                || (prefix == "ko" && (sourceID.contains("korean") || sourceID.contains("hangul")))
                || (prefix == "ja" && (sourceID.contains("japanese") || sourceID.contains("kana")))
                || (prefix == "zh" && (sourceID.contains("chinese") || sourceID.contains("pinyin")))
        }
    }

    private static func catalystCurrentInputSourceSnapshotValue() -> CatalystCurrentInputSourceSnapshot? {
        let now = ProcessInfo.processInfo.systemUptime
        if let snapshot = catalystCurrentInputSourceSnapshot, snapshot.expiresAt > now {
            return snapshot
        }

        guard let bridge = MacSupport.bridge else { return nil }

        let snapshot = CatalystCurrentInputSourceSnapshot(
            languages: bridge.currentInputSourceLanguages().map { $0.lowercased() },
            sourceID: bridge.currentInputSourceID()?.lowercased(),
            expiresAt: now + catalystCurrentInputSourceSnapshotTTL
        )
        catalystCurrentInputSourceSnapshot = snapshot
        return snapshot
    }

    private static func invalidateCatalystCurrentInputSourceSnapshot() {
        catalystCurrentInputSourceSnapshot = nil
    }

    #endif
}
