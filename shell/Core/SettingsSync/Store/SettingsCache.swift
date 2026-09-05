//
//  SettingsCache.swift
//  shell
//
//  Lock-protected mirror of user-set registered values, readable from any
//  thread. Until primed it reads through to UserDefaults so early readers see
//  the same values they did before the store existed.
//

import Foundation
import os

nonisolated final class SettingsCache: Sendable {
    private struct State {
        var values: [String: CodableValue] = [:]
        var primed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let registry: SettingsRegistry

    init(registry: SettingsRegistry) {
        self.registry = registry
    }

    var isPrimed: Bool { state.withLock { $0.primed } }

    /// Typed read: cache when primed, otherwise a direct UserDefaults read decoded by declared type.
    func value<V: SettingValue>(_ key: SettingKey<V>) -> V {
        let cached: (primed: Bool, value: CodableValue?) = state.withLock { ($0.primed, $0.values[key.name]) }
        if cached.primed {
            return cached.value.flatMap(V.init(codableValue:)) ?? key.defaultValue
        }
        guard let raw = UserDefaults.standard.object(forKey: key.name),
              let cv = CodableValue(userDefaultsObject: raw, as: V.valueType),
              let typed = V(codableValue: cv) else { return key.defaultValue }
        return typed
    }

    func raw(_ name: String) -> CodableValue? {
        state.withLock { $0.values[name] }
    }

    func snapshot() -> [String: CodableValue] {
        state.withLock { $0.values }
    }

    func replaceAll(_ values: [String: CodableValue]) {
        state.withLock {
            $0.values = values
            $0.primed = true
        }
    }

    /// Returns true when the stored value actually changed.
    @discardableResult
    func update(_ name: String, _ value: CodableValue?) -> Bool {
        state.withLock {
            let old = $0.values[name]
            guard old != value else { return false }
            if let value {
                $0.values[name] = value
            } else {
                $0.values.removeValue(forKey: name)
            }
            return true
        }
    }
}
