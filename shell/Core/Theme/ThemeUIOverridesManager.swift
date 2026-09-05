//
//  ThemeUIOverridesManager.swift
//  shell
//
//  Singleton store for per-theme UI color overrides. Mirrors the @Observable
//  @MainActor pattern used by ThemeOverrideManager. Persists the entire
//  override dictionary as a single JSON blob in UserDefaults under
//  `themeUIOverrides.v1` so the existing BackupExporter / BackupImporter
//  generic preference path picks it up without bespoke logic.
//

import Foundation
import Combine
import os

@MainActor
@Observable
final class ThemeUIOverridesManager {
    static let shared = ThemeUIOverridesManager()

    @ObservationIgnored private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "ThemeUIOverridesManager")
    @ObservationIgnored static let userDefaultsKey = "themeUIOverrides.v1"

    /// Broadcasts whenever overrides change. Subscribers (e.g. resolved theme
    /// bundles in `MainView`) can invalidate cached colors in response.
    @ObservationIgnored let didChange = PassthroughSubject<Void, Never>()

    private(set) var overrides: [String: ThemeUIOverrides]

    private init() {
        self.overrides = Self.load()
        SettingsRefreshHub.shared.register(keys: [Settings.Theme.uiOverrides.name]) { [weak self] _ in
            self?.reloadFromDefaults()
        }
    }

    // MARK: - Read

    func overrides(for themeName: String) -> ThemeUIOverrides {
        overrides[themeName] ?? .empty
    }

    func hasOverrides(for themeName: String) -> Bool {
        guard let entry = overrides[themeName] else { return false }
        return !entry.isEmpty
    }

    // MARK: - Write

    func setOverrides(_ value: ThemeUIOverrides, for themeName: String) {
        if value.isEmpty {
            guard overrides[themeName] != nil else { return }
            overrides.removeValue(forKey: themeName)
        } else {
            guard overrides[themeName] != value else { return }
            overrides[themeName] = value
        }
        persist()
        didChange.send()
    }

    func setField(_ field: ThemeUIOverrideField, hex: String?, for themeName: String) {
        var entry = overrides[themeName] ?? .empty
        entry[field] = hex
        setOverrides(entry, for: themeName)
    }

    func clearField(_ field: ThemeUIOverrideField, for themeName: String) {
        setField(field, hex: nil, for: themeName)
    }

    func clear(for themeName: String) {
        guard overrides[themeName] != nil else { return }
        overrides.removeValue(forKey: themeName)
        persist()
        didChange.send()
    }

    /// Migrate overrides when a custom theme is renamed so they don't orphan
    /// at the old name. If the destination already has overrides (unusual,
    /// implies a name collision the user accepted), the existing
    /// destination entry wins and the source is dropped.
    func renameOverrides(from oldName: String, to newName: String) {
        guard oldName != newName, let entry = overrides[oldName] else { return }
        overrides.removeValue(forKey: oldName)
        if overrides[newName] == nil {
            overrides[newName] = entry
        }
        persist()
        didChange.send()
    }

    // MARK: - Backup integration

    /// Re-read the persisted blob from UserDefaults. Called by `BackupImporter`
    /// after a restore writes new values straight to UserDefaults.
    func reloadFromDefaults() {
        overrides = Self.load()
        didChange.send()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(overrides)
            SettingsStore.shared.set(Settings.Theme.uiOverrides, data)
        } catch {
            let message = error.localizedDescription
            Self.logger.error("Failed to encode theme UI overrides: \(message)")
        }
    }

    private static func load() -> [String: ThemeUIOverrides] {
        guard let data = SettingsStore.shared.get(Settings.Theme.uiOverrides) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ThemeUIOverrides].self, from: data)
        } catch {
            let message = error.localizedDescription
            logger.error("Failed to decode theme UI overrides: \(message)")
            return [:]
        }
    }
}
