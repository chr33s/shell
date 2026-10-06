//
//  SoftwareKeyboardState.swift
//  shell
//
//  Per-terminal software keyboard state: the Shell keyboard page and the one
//  software modifier model shared by the toolbar and the Shell keyboard body.
//  Holds no text: nothing typed is ever stored here.
//

import Foundation
import UIKit

// MARK: - Mode

/// Which software keyboard a terminal presents. Used both for the device
/// preference and for the implementation actually on screen.
nonisolated enum SoftwareKeyboardMode: String, CaseIterable, Codable, Sendable {
    /// Apple's keyboard (UIKit's primary input view).
    case system
    /// Shell's own terminal keyboard (`ShellKeyboardInputView`).
    case shell

    var displayName: String {
        switch self {
        case .system: String(localized: "System Keyboard")
        case .shell: String(localized: "Shell Keyboard")
        }
    }
}

@MainActor
enum SoftwareKeyboardPreference {
    static var current: SoftwareKeyboardMode {
        SettingsStore.shared.get(Settings.Keyboard.softwareKeyboardMode)
    }

    /// Terminals observe the store's change stream, so every writer —
    /// this, reset, restore, migration — reaches them.
    static func set(_ mode: SoftwareKeyboardMode) {
        SettingsStore.shared.set(Settings.Keyboard.softwareKeyboardMode, mode)
    }
}

/// One-time installation default: new installs use Shell, upgrades keep
/// System until the user chooses. The decision is written once, so the stored
/// value doubles as the "already migrated" marker.
@MainActor
enum SoftwareKeyboardModeMigration {
    /// Pure classification. Returns the value to write, or nil to leave the
    /// setting untouched (already decided, or the install state is uncertain).
    nonisolated static func decision(
        storeIsReady: Bool,
        alreadyDecided: Bool,
        detectedCorruption: Bool,
        hasDefaultsBackup: Bool,
        persistedSettingCount: Int
    ) -> SoftwareKeyboardMode? {
        guard storeIsReady, !alreadyDecided, !detectedCorruption else { return nil }
        // The defaults backup is written on the first unlocked activation, and
        // any registered value means the app has run before.
        if hasDefaultsBackup || persistedSettingCount > 0 { return .system }
        return .shell
    }

    /// Run once protected data is available and the store has bootstrapped.
    static func run(store: SettingsStore = .shared) {
        let key = Settings.Keyboard.softwareKeyboardMode
        guard let mode = decision(
            storeIsReady: store.isReady,
            alreadyDecided: store.isUserSet(key.name),
            detectedCorruption: UserDefaultsBackup.detectedCorruptionThisLaunch,
            hasDefaultsBackup: UserDefaultsBackup.hasBackup,
            persistedSettingCount: store.cache.snapshot().count
        ) else { return }
        store.set(key, mode)
    }
}

/// Pure presentation rules shared by the accessory controller and tests.
nonisolated enum SoftwareKeyboardPresentationPolicy {
    /// What a presentation asks for: the implementation the visibility
    /// control remembered, else the device preference.
    static func requested(restore: SoftwareKeyboardMode?, preference: SoftwareKeyboardMode) -> SoftwareKeyboardMode {
        restore ?? preference
    }

    /// What hiding remembers: the implementation on screen, except that a
    /// transient System fallback keeps the requested (Shell) intent so a later
    /// reopen with room returns to Shell.
    static func rememberedOnHide(
        presented: SoftwareKeyboardMode,
        fallbackActive: Bool,
        requested: SoftwareKeyboardMode
    ) -> SoftwareKeyboardMode {
        presented == .system && fallbackActive ? requested : presented
    }
}

// MARK: - Shared Modifier Model

/// The one source of truth for software modifiers (Ctrl, Alt, Cmd, Shift).
/// Toolbar modifier buttons, the Shell keyboard's Shift key, keycap labels,
/// and dispatch all read and write this model; none keeps its own latch.
@MainActor
final class SoftwareModifierModel {
    /// Tap state machine threshold; unchanged from the toolbar's original.
    static let doubleTapThreshold: CFAbsoluteTime = 0.5

    static let managedModifiers: [KeyModifiers] = [.control, .alt, .command, .shift]

    private(set) var states: [KeyModifiers: ModifierState] = [:]
    private var lastTapTimes: [KeyModifiers: CFAbsoluteTime] = [:]
    private var observers: [UUID: (SoftwareModifierModel) -> Void] = [:]

    /// Union of every one-shot or locked modifier.
    var active: KeyModifiers {
        states.reduce(into: KeyModifiers()) { result, entry in
            if entry.value != .inactive { result.insert(entry.key) }
        }
    }

    func state(for modifier: KeyModifiers) -> ModifierState {
        states[modifier] ?? .inactive
    }

    /// The toolbar's tap behavior: single tap one-shot, quick second tap
    /// locks (also after a one-shot was consumed between the taps), slow
    /// second tap clears, tap on locked clears.
    @discardableResult
    func tap(_ modifier: KeyModifiers, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> ModifierState {
        let elapsed = now - (lastTapTimes[modifier] ?? -.infinity)
        let next: ModifierState
        switch state(for: modifier) {
        case .inactive:
            next = elapsed < Self.doubleTapThreshold ? .locked : .oneShot
            lastTapTimes[modifier] = now
        case .oneShot:
            next = elapsed < Self.doubleTapThreshold ? .locked : .inactive
            lastTapTimes[modifier] = now
        case .locked:
            next = .inactive
            lastTapTimes[modifier] = nil
        }
        apply(next, to: modifier)
        notify()
        return next
    }

    /// Direct state change for accessibility Lock/Unlock (no timing needed).
    func set(_ state: ModifierState, for modifier: KeyModifiers) {
        guard self.state(for: modifier) != state else { return }
        apply(state, to: modifier)
        if state == .inactive { lastTapTimes[modifier] = nil }
        notify()
    }

    /// Consume one-shots after an emitted key or claimed shortcut. Locked
    /// modifiers persist. Tap history is kept so a quick re-tap still locks.
    func consumeOneShots() {
        var changed = false
        for (modifier, state) in states where state == .oneShot {
            states.removeValue(forKey: modifier)
            changed = true
        }
        if changed { notify() }
    }

    /// Reset everything, tap history included. Writes no bytes.
    func clearAll() {
        let changed = !states.isEmpty
        states.removeAll()
        lastTapTimes.removeAll()
        if changed { notify() }
    }

    // MARK: Observation

    /// Observers fire after every change; the token removes its observer
    /// when released.
    func observe(_ handler: @escaping (SoftwareModifierModel) -> Void) -> SoftwareModifierObservation {
        let id = UUID()
        observers[id] = handler
        return SoftwareModifierObservation { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    private func apply(_ state: ModifierState, to modifier: KeyModifiers) {
        if state == .inactive {
            states.removeValue(forKey: modifier)
        } else {
            states[modifier] = state
        }
    }

    private func notify() {
        for handler in observers.values { handler(self) }
    }
}

@MainActor
final class SoftwareModifierObservation {
    private var cancelHandler: (() -> Void)?

    init(_ cancel: @escaping () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        cancelHandler?()
        cancelHandler = nil
    }

    isolated deinit {
        cancel()
    }
}

// MARK: - Per-terminal State

/// Transient, per-terminal keyboard state. Never persisted.
@MainActor
final class SoftwareKeyboardState {
    let modifiers = SoftwareModifierModel()

    /// Current Shell keyboard page. Returns to letters after leaving
    /// terminal input or changing keyboard implementation.
    var page: ShellKeyboardPage = .letters {
        didSet {
            guard oldValue != page else { return }
            onPageChanged?(page)
        }
    }

    var onPageChanged: ((ShellKeyboardPage) -> Void)?

    /// Leaving terminal focus, switching implementation, or deactivating
    /// the scene: no modifier or page may leak to the next input.
    func reset() {
        modifiers.clearAll()
        page = .letters
    }
}
