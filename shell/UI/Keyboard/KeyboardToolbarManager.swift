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

        // Check if device idiom changed (e.g. restored backup from different device).
        //
        // The whole check is gated on protected data. The marker is raw UserDefaults,
        // and on a locked background launch (VPN, CloudKit push) reads come back empty
        // while writes land on top of the real values: `savedIdiom` would read as nil,
        // which is indistinguishable from "no idiom change", and the marker write below
        // would then stamp this device's own idiom over the foreign one — destroying
        // the only record that a reset is owed, exactly the permanent loss the missing
        // save below used to cause. While locked, touch nothing and let the next
        // unlocked launch run the check.
        if ProtectedDataGuard.isAvailable {
            let savedIdiom = UserDefaults.standard.string(forKey: Self.deviceIdiomKey)
            let currentIdiomString = idiom == .pad ? "pad" : "phone"
            var didResetForIdiomChange = true
            if let savedIdiom, savedIdiom != currentIdiomString {
                // Reset to defaults for this device.
                // `config`'s didSet is not a dependable hook here: assignments to self's
                // own stored properties inside the declaring class's initializer go
                // straight to storage and skip observers, so the reset has to be
                // persisted by hand. Without this the new layout existed only in memory
                // and the next launch decoded the foreign-idiom layout again —
                // permanently, since the marker below had already been advanced.
                config = ToolbarLayoutConfig.defaultConfig(for: idiom)
                // Only advance the idiom marker if the reset actually reached the store;
                // otherwise leave the stale marker so the next launch retries the reset
                // rather than losing the record that one is owed.
                didResetForIdiomChange = saveConfig()
            }
            if didResetForIdiomChange {
                UserDefaults.standard.set(currentIdiomString, forKey: Self.deviceIdiomKey)
            }
        }

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
        effectiveLayout(availableWidth: availableWidth).main
    }

    /// Effective drawer rows after applying capacity overflow. Row 0 absorbs the
    /// main-row overflow plus any key displaced by the drawer toggle guarantee;
    /// later rows are their configured slots unchanged.
    func effectiveDrawerRowSlots(availableWidth: CGFloat) -> [[KeySlot]] {
        effectiveLayout(availableWidth: availableWidth).drawers
    }

    /// Single source of truth for both effective rows.
    ///
    /// The two halves used to be computed independently, and the drawer-toggle
    /// guarantee below overwrote the last visible main-row key while pushing the
    /// displaced key into a function-local array that was then thrown away — so
    /// that key was rendered by neither row and disappeared from the UI entirely
    /// (any width where capacity cuts before `.drawerToggle`, or any layout where
    /// the user moved `.drawerToggle` out of the main row). Computing main row and
    /// drawer rows together keeps the displacement and its re-insertion in step.
    private func effectiveLayout(availableWidth: CGFloat) -> (main: [KeySlot], drawers: [[KeySlot]]) {
        let capacity = mainRowCapacity(availableWidth: availableWidth)
        let customIDs = Set(customKeys.map(\.id))
        let allMainSlots = validSlots(config.mainRow, customIDs: customIDs)

        var visible = Array(allMainSlots.prefix(capacity))
        var overflow = Array(allMainSlots.dropFirst(capacity))

        // Hoist the two toggles back out of the overflow: a drawer row cannot draw
        // them (see `isDrawerRenderable`), so letting the capacity cut push one down
        // deletes it from the UI exactly as the thrown-away-array bug did. On the
        // shipped iPad default they sit at indices 7-8, so every capacity below 9 —
        // a half-width Split View or Slide Over — strands one or both. The main row
        // is `.fillEqually`, so carrying at most two extra buttons only narrows it.
        let stranded = overflow.filter { !Self.isDrawerRenderable($0) }
        if !stranded.isEmpty {
            overflow.removeAll { !Self.isDrawerRenderable($0) }
            visible.append(contentsOf: stranded)
        }

        var rows = config.drawerRows.map { validSlots($0, customIDs: customIDs) }
        // A config with no drawer rows would otherwise trap on `rows[0]` below.
        if rows.isEmpty { rows = [[]] }

        let anyDrawerContent = !overflow.isEmpty || rows.contains { !$0.isEmpty }

        // Guarantee: if any drawer row has content, drawerToggle must be in visible main row
        // (but respect user's explicit hide)
        var displaced: KeySlot?
        if anyDrawerContent && !visible.contains(.builtIn(.drawerToggle))
            && !config.hiddenKeys.contains(.drawerToggle) {
            // Evict the last slot the drawer can actually render, not `visible.last`
            // blindly: the last slot is often `.arrowDrawerToggle`, and evicting that
            // into a row that skips it loses the arrows key and every arrow behind it.
            if let victim = visible.lastIndex(where: { Self.isDrawerRenderable($0) }) {
                displaced = visible.remove(at: victim)
            }
            // Nothing evictable (a one-slot row holding only a toggle, or no main-row
            // slots at all): append instead of overwriting, so the guarantee never
            // costs a key. `.fillEqually` absorbs the extra button.
            visible.append(.builtIn(.drawerToggle))
        }

        // drawerToggle now always holds a main-row seat, and the hoist above already
        // pulled it out of `overflow`, so it never repeats in a drawer.
        rows[0] = (displaced.map { [$0] } ?? []) + overflow + rows[0]
        return (visible, rows)
    }

    /// Whether a drawer row is able to render `slot`.
    ///
    /// `KeyboardToolbarView.populateExtraKeysRow` skips `.drawerToggle` and
    /// `.arrowDrawerToggle` on sight — they are main-row chrome — so any layout pass
    /// that moves one into a drawer makes it vanish from the UI entirely while the
    /// settings editor still lists it as placed. Every demotion here is gated on this.
    ///
    /// Stays main-actor isolated (every caller is): the build sets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so `KeySlot`'s synthesized
    /// `Equatable` conformance is main-actor isolated too, and `nonisolated` here
    /// would make the `!=` below an error under the Swift 6 language mode.
    private static func isDrawerRenderable(_ slot: KeySlot) -> Bool {
        slot != .builtIn(.drawerToggle) && slot != .builtIn(.arrowDrawerToggle)
    }

    /// Filter out slots that reference deleted custom keys or hidden built-in keys.
    /// `customIDs` is passed in so a full layout pass builds the set once.
    private func validSlots(_ slots: [KeySlot], customIDs: Set<UUID>) -> [KeySlot] {
        slots.filter { slot in
            switch slot {
            case .builtIn(let keyID):
                return !config.hiddenKeys.contains(keyID)
            case .custom(let uuid):
                return customIDs.contains(uuid)
            }
        }
    }

    // MARK: - Persistence

    /// Returns whether the config actually reached the store: encoding can fail, and
    /// `SettingsStore.set` silently drops writes while protected data is unavailable
    /// (background launch before first unlock). Callers that record "this is now
    /// persisted" state elsewhere must check the result.
    @discardableResult
    private func saveConfig() -> Bool {
        guard ProtectedDataGuard.isAvailable else {
            Self.logger.warning("Skipping toolbar config save; protected data unavailable")
            return false
        }
        do {
            let data = try JSONEncoder().encode(config)
            SettingsStore.shared.set(Settings.KeyboardToolbar.config, data)
            return true
        } catch {
            Self.logger.error("Failed to save toolbar config: \(error.localizedDescription)")
            return false
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
