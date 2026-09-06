//
//  SettingsRefreshHub.swift
//  shell
//
//  Fan-out for externally applied settings: managers reload the keys they
//  own, then the terminal config is rewritten once for the whole batch.
//

import Foundation
import os

@MainActor
final class SettingsRefreshHub {
    static let shared = SettingsRefreshHub()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SettingsRefreshHub")

    struct Token: Hashable {
        fileprivate let id = UUID()
    }

    private struct Registration {
        let keys: Set<String>?
        let groups: Set<SettingGroup>
        let reload: @MainActor (Set<String>) -> Void
    }

    private var registrations: [Token: Registration] = [:]

    /// Groups whose keys feed the generated GhosttyKit config.
    static let ghosttyGroups: Set<SettingGroup> = [
        .theme, .font, .cursor, .selection, .transparency, .keybinds, .terminal, .keyboard,
    ]

    /// Live-apply consumers that are per-instance (terminal views, keyboard
    /// controllers) rather than a singleton manager. Managers register above and
    /// write their own keys through, so a local write has already been applied
    /// by the time it reaches the hub; these consumers have no such
    /// write-through path, so they are notified on every origin.
    ///
    /// Every entry must have a live observer — a name posted here and observed
    /// nowhere is a silent no-op. `Settings.Connections.healthMonitoring` and
    /// `healthProbeInterval` are deliberately absent: their apply-to-live-session
    /// receivers do not exist (CitadelSSHSession reads both only at monitor
    /// start), so posting for them would be exactly that no-op.
    private static let liveApplyNotifications: [String: Notification.Name] = [
        Settings.Keyboard.forceASCIIKeyboard.name: .forceASCIIKeyboardChanged,
        Settings.KeyboardToolbar.showWithHardwareKeyboard.name: .keyboardToolbarHardwareSettingChanged,
    ]

    @discardableResult
    func register(keys: Set<String>, _ reload: @escaping @MainActor (Set<String>) -> Void) -> Token {
        let token = Token()
        registrations[token] = Registration(keys: keys, groups: [], reload: reload)
        return token
    }

    @discardableResult
    func register(groups: Set<SettingGroup>, _ reload: @escaping @MainActor (Set<String>) -> Void) -> Token {
        let token = Token()
        registrations[token] = Registration(keys: nil, groups: groups, reload: reload)
        return token
    }

    func unregister(_ token: Token) {
        registrations.removeValue(forKey: token)
    }

    /// Called by the store for every batch: the per-instance notifications above
    /// fire on any origin, the manager registrations and the ghostty reload only
    /// for non-local batches, while `isApplyingBatch` is set.
    func dispatch(_ change: SettingsChange) {
        guard !change.keys.isEmpty else { return }

        var posted: Set<Notification.Name> = []
        for key in change.keys {
            guard let name = Self.liveApplyNotifications[key], posted.insert(name).inserted else { continue }
            NotificationCenter.default.post(name: name, object: nil)
        }

        guard change.origin != .local else { return }
        let registry = SettingsRegistry.shared
        var groups: Set<SettingGroup> = []
        for key in change.keys {
            if let def = registry.definition(for: key) { groups.insert(def.group) }
        }

        for registration in registrations.values {
            let hit: Set<String>
            if let keys = registration.keys {
                hit = change.keys.intersection(keys)
            } else if !registration.groups.isDisjoint(with: groups) {
                hit = change.keys.filter { registry.definition(for: $0).map { registration.groups.contains($0.group) } ?? false }
            } else {
                hit = []
            }
            if !hit.isEmpty { registration.reload(hit) }
        }

        if !groups.isDisjoint(with: Self.ghosttyGroups) {
            Ghostty.App.shared?.reloadGlobalConfig()
        }
        Self.logger.info("Dispatched \(change.keys.count) \(change.origin.rawValue, privacy: .public) keys to \(self.registrations.count) registrations")
    }
}
