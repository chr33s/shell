//
//  KeyboardToolbarManager.swift
//  shell
//
//  Manages keyboard toolbar layout customization and custom keys.
//  Persists configuration to UserDefaults and notifies observers on changes.
//

import Foundation
import SwiftUI
import Observation
import os

@MainActor
@Observable
class KeyboardToolbarManager {
    static let shared = KeyboardToolbarManager()

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "KeyboardToolbarManager")

    static let layoutDidChangeNotification = Notification.Name("KeyboardToolbarLayoutDidChange")

    // MARK: - Storage Keys

    /// Device-only marker; stays raw because it never syncs.
    private static let deviceIdiomKey = "keyboardToolbarDeviceIdiom"

    private static let ownedKeys: Set<String> = [
        Settings.KeyboardToolbar.config.name,
        Settings.KeyboardToolbar.customKeys.name,
        Settings.KeyboardToolbar.drawerOpenByDefault.name,
        Settings.KeyboardToolbar.drawerToggleMode.name,
    ]

    @ObservationIgnored private var isReloading = false

    // MARK: - Observable Properties

    private(set) var config: ToolbarLayoutConfig {
        didSet {
            guard !isReloading else { return }
            saveConfig()
        }
    }

    private(set) var customKeys: [CustomKey] {
        didSet {
            guard !isReloading else { return }
            saveCustomKeys()
        }
    }

    var drawerOpenByDefault: Bool {
        didSet {
            guard !isReloading else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.drawerOpenByDefault, drawerOpenByDefault)
        }
    }

    /// How the "…" button steps through multiple drawer rows (stack vs cycle).
    var drawerToggleMode: DrawerToggleMode {
        didSet {
            guard !isReloading else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.drawerToggleMode, drawerToggleMode)
        }
    }

    // MARK: - Computed Properties

    var isCustomized: Bool {
        let defaults = ToolbarLayoutConfig.defaultConfig(for: currentIdiom)
        return config != defaults || !customKeys.isEmpty
    }

    private var currentIdiom: UIUserInterfaceIdiom {
        UIDevice.current.userInterfaceIdiom
    }

    // MARK: - Initialization

    private init() {
        let idiom = UIDevice.current.userInterfaceIdiom
        config = Self.loadConfig(idiom: idiom)
        customKeys = Self.loadCustomKeys()
        drawerOpenByDefault = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerOpenByDefault)
        drawerToggleMode = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerToggleMode)

        // Check if device idiom changed (e.g. restored backup from different device)
        let savedIdiom = UserDefaults.standard.string(forKey: Self.deviceIdiomKey)
        let currentIdiomString = idiom == .pad ? "pad" : "phone"
        if let savedIdiom, savedIdiom != currentIdiomString {
            // Reset to defaults for this device
            config = ToolbarLayoutConfig.defaultConfig(for: idiom)
        }
        UserDefaults.standard.set(currentIdiomString, forKey: Self.deviceIdiomKey)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads externally applied values without writing them back.
    func reload(keys: Set<String>) {
        isReloading = true
        if keys.contains(Settings.KeyboardToolbar.config.name) {
            config = Self.loadConfig(idiom: currentIdiom)
        }
        if keys.contains(Settings.KeyboardToolbar.customKeys.name) {
            customKeys = Self.loadCustomKeys()
        }
        if keys.contains(Settings.KeyboardToolbar.drawerOpenByDefault.name) {
            drawerOpenByDefault = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerOpenByDefault)
        }
        if keys.contains(Settings.KeyboardToolbar.drawerToggleMode.name) {
            drawerToggleMode = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerToggleMode)
        }
        isReloading = false
        notifyChange()
    }

    // MARK: - Layout Mutations

    enum ToolbarSection: Equatable, Sendable {
        case mainRow
        case drawer(Int)
    }

    /// Maximum number of configurable drawer rows.
    static let maxDrawerRows = 5

    /// Number of configured drawer rows (1...maxDrawerRows).
    var drawerRowCount: Int { config.drawerRows.count }

    /// Grow or shrink the number of drawer rows. Growing appends empty rows;
    /// shrinking merges the removed rows' keys into the last remaining row so
    /// nothing is destroyed.
    func setDrawerRowCount(_ count: Int) {
        let target = max(1, min(Self.maxDrawerRows, count))
        guard target != config.drawerRows.count else { return }
        var rows = config.drawerRows
        if target > rows.count {
            rows.append(contentsOf: Array(repeating: [], count: target - rows.count))
        } else {
            let overflow = rows[target...].flatMap { $0 }
            rows = Array(rows.prefix(target))
            rows[target - 1].append(contentsOf: overflow)
        }
        config.drawerRows = rows
        notifyChange()
    }

    /// Replaces all rows in a single mutation. Used by the UIKit drag editor,
    /// which computes the complete new ordering (across all sections) from its
    /// diffable snapshot. One assignment → one save → one change notification.
    ///
    /// The editor only ever shows valid slots (hidden/deleted keys are already
    /// removed from all rows by hideKey/deleteCustomKey), so assigning the
    /// snapshot's contents directly preserves the invariant that the rows hold
    /// only valid slots.
    func setLayout(mainRow newMain: [KeySlot], drawerRows newDrawers: [[KeySlot]]) {
        let drawers = newDrawers.isEmpty ? [[]] : newDrawers
        guard config.mainRow != newMain || config.drawerRows != drawers else { return }
        config.mainRow = newMain
        config.drawerRows = drawers
        notifyChange()
    }

    func moveKeyToSection(_ slot: KeySlot, from: ToolbarSection, to: ToolbarSection) {
        guard from != to else { return }

        switch from {
        case .mainRow:
            config.mainRow.removeAll { $0 == slot }
        case .drawer:
            // Remove from every drawer row; the source index may be stale.
            for i in config.drawerRows.indices {
                config.drawerRows[i].removeAll { $0 == slot }
            }
        }

        switch to {
        case .mainRow:
            config.mainRow.append(slot)
        case .drawer(let index):
            let clamped = max(0, min(config.drawerRows.count - 1, index))
            config.drawerRows[clamped].insert(slot, at: 0)
        }
        notifyChange()
    }

    func hideKey(_ keyID: KeyID) {
        config.mainRow.removeAll { $0 == .builtIn(keyID) }
        for i in config.drawerRows.indices {
            config.drawerRows[i].removeAll { $0 == .builtIn(keyID) }
        }
        config.hiddenKeys.insert(keyID)
        notifyChange()
    }

    func unhideKey(_ keyID: KeyID) {
        config.hiddenKeys.remove(keyID)
        // Add back to the first drawer row by default
        config.drawerRows[0].append(.builtIn(keyID))
        notifyChange()
    }

    func resetToDefaults() {
        config = ToolbarLayoutConfig.defaultConfig(for: currentIdiom)
        // Remove custom keys from layout but keep their definitions
        customKeys = []
        notifyChange()
    }

    // MARK: - Custom Key CRUD

    func createCustomKey(_ key: CustomKey) {
        customKeys.append(key)
        // Add to the first drawer row by default
        config.drawerRows[0].append(.custom(key.id))
        notifyChange()
    }

    func updateCustomKey(_ key: CustomKey) {
        if let index = customKeys.firstIndex(where: { $0.id == key.id }) {
            customKeys[index] = key
        }
        notifyChange()
    }

    func deleteCustomKey(id: UUID) {
        customKeys.removeAll { $0.id == id }
        config.mainRow.removeAll { $0 == .custom(id) }
        for i in config.drawerRows.indices {
            config.drawerRows[i].removeAll { $0 == .custom(id) }
        }
        notifyChange()
    }

    func customKey(for id: UUID) -> CustomKey? {
        customKeys.first { $0.id == id }
    }

    /// Custom keys whose UUID isn't placed in the main row or any drawer row.
    var unplacedCustomKeys: [CustomKey] {
        let placedIDs = Set(
            (config.mainRow + config.drawerRows.flatMap { $0 }).compactMap { slot -> UUID? in
                if case .custom(let uuid) = slot { return uuid }
                return nil
            }
        )
        return customKeys.filter { !placedIDs.contains($0.id) }
    }

    /// Removes a custom key from layout without deleting its definition.
    func removeCustomKeyFromLayout(id: UUID) {
        let slot = KeySlot.custom(id)
        config.mainRow.removeAll { $0 == slot }
        for i in config.drawerRows.indices {
            config.drawerRows[i].removeAll { $0 == slot }
        }
        notifyChange()
    }

    /// Adds a custom key slot to the specified section if the definition exists
    /// and the key isn't already placed in any row.
    func addCustomKeyToLayout(id: UUID, section: ToolbarSection) {
        guard customKey(for: id) != nil else { return }
        let slot = KeySlot.custom(id)
        guard !config.mainRow.contains(slot),
              !config.drawerRows.contains(where: { $0.contains(slot) }) else { return }
        switch section {
        case .mainRow:
            config.mainRow.append(slot)
        case .drawer(let index):
            let clamped = max(0, min(config.drawerRows.count - 1, index))
            config.drawerRows[clamped].append(slot)
        }
        notifyChange()
    }

    // MARK: - Capacity & Effective Layout

    /// Minimum button width for calculating capacity
    private func minButtonWidth(for sizes: KeyboardSizes) -> CGFloat {
        sizes.button.normalWidth
    }

    /// How many keys fit in the main row given available width
    func mainRowCapacity(availableWidth: CGFloat) -> Int {
        let sizes = KeyboardSizes.current()
        let buttonWidth = minButtonWidth(for: sizes)
        guard buttonWidth > 0 else { return 0 }
        return max(1, Int(availableWidth / buttonWidth))
    }

    /// Effective main row slots after applying capacity constraints and drawer toggle guarantee.
    func effectiveMainRowSlots(availableWidth: CGFloat) -> [KeySlot] {
        let capacity = mainRowCapacity(availableWidth: availableWidth)
        let allMainSlots = validSlots(config.mainRow)

        var visible = Array(allMainSlots.prefix(capacity))
        let overflow = Array(allMainSlots.dropFirst(capacity))
        var firstDrawer = overflow + validSlots(config.drawerRows[0])
        let anyDrawerContent = !firstDrawer.isEmpty
            || config.drawerRows.dropFirst().contains { !validSlots($0).isEmpty }

        // Guarantee: if any drawer row has content, drawerToggle must be in visible main row
        // (but respect user's explicit hide)
        if anyDrawerContent && !visible.contains(.builtIn(.drawerToggle)) && !config.hiddenKeys.contains(.drawerToggle) {
            if !visible.isEmpty {
                let lastSlot = visible[visible.count - 1]
                visible[visible.count - 1] = .builtIn(.drawerToggle)
                firstDrawer.insert(lastSlot, at: 0)
            } else {
                visible = [.builtIn(.drawerToggle)]
            }
        }

        return visible
    }

    /// Effective drawer rows after applying capacity overflow. Row 0 absorbs the
    /// main-row overflow; later rows are their configured slots unchanged.
    func effectiveDrawerRowSlots(availableWidth: CGFloat) -> [[KeySlot]] {
        let capacity = mainRowCapacity(availableWidth: availableWidth)
        let allMainSlots = validSlots(config.mainRow)

        var overflow = Array(allMainSlots.dropFirst(capacity))
        // Remove drawerToggle from overflow (it's auto-inserted in main row)
        overflow.removeAll { $0 == .builtIn(.drawerToggle) }

        var rows = config.drawerRows.map { validSlots($0) }
        rows[0] = overflow + rows[0]
        return rows
    }

    /// Filter out slots that reference deleted custom keys or hidden built-in keys
    private func validSlots(_ slots: [KeySlot]) -> [KeySlot] {
        let customIDs = Set(customKeys.map(\.id))
        return slots.filter { slot in
            switch slot {
            case .builtIn(let keyID):
                return !config.hiddenKeys.contains(keyID)
            case .custom(let uuid):
                return customIDs.contains(uuid)
            }
        }
    }

    // MARK: - Persistence

    private func saveConfig() {
        do {
            let data = try JSONEncoder().encode(config)
            SettingsStore.shared.set(Settings.KeyboardToolbar.config, data)
        } catch {
            Self.logger.error("Failed to save toolbar config: \(error.localizedDescription)")
        }
    }

    private func saveCustomKeys() {
        do {
            let data = try JSONEncoder().encode(customKeys)
            SettingsStore.shared.set(Settings.KeyboardToolbar.customKeys, data)
        } catch {
            Self.logger.error("Failed to save custom keys: \(error.localizedDescription)")
        }
    }

    private static func loadConfig(idiom: UIUserInterfaceIdiom) -> ToolbarLayoutConfig {
        guard let data = SettingsStore.shared.get(Settings.KeyboardToolbar.config) else {
            return ToolbarLayoutConfig.defaultConfig(for: idiom)
        }
        do {
            var config = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)
            if config.version < ToolbarLayoutConfig.currentVersion {
                config = ToolbarLayoutConfig.migrate(config, idiom: idiom)
            }
            return config
        } catch {
            logger.error("Failed to load toolbar config: \(error.localizedDescription)")
            return ToolbarLayoutConfig.defaultConfig(for: idiom)
        }
    }

    private static func loadCustomKeys() -> [CustomKey] {
        guard let data = SettingsStore.shared.get(Settings.KeyboardToolbar.customKeys) else { return [] }
        do {
            return try JSONDecoder().decode([CustomKey].self, from: data)
        } catch {
            logger.error("Failed to load custom keys: \(error.localizedDescription)")
            return []
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.layoutDidChangeNotification, object: nil)
    }
}
