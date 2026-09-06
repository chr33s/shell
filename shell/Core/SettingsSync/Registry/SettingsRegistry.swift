//
//  SettingsRegistry.swift
//  shell
//
//  Single source of truth for every UserDefaults key the app owns: type,
//  default, sync policy, pin group, and text-config name.
//

import Foundation
import os

/// Namespace for setting declarations. Areas add `nonisolated extension Settings { enum Cursor { ... } }`.
nonisolated enum Settings {}

nonisolated final class SettingsRegistry: Sendable {
    static let shared = SettingsRegistry(areas: Settings.allAreas)

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SettingsRegistry")

    /// A key family whose full names are composed at runtime (`ai.temperature.<providerID>`).
    struct PrefixRule: Sendable {
        let prefix: String
        let valueType: CodableValue.ValueType
        let policy: SyncPolicy
        let group: SettingGroup
        let title: String

        func definition(for key: String) -> AnySettingDefinition {
            .dynamic(key, valueType: valueType, policy: policy, group: group, title: title)
        }
    }

    let definitions: [String: AnySettingDefinition]
    let prefixRules: [PrefixRule]
    /// Explicitly registered syncable names; prefixed keys are resolved via `isSyncable(_:)`.
    let syncableKeys: Set<String>
    private let byGroup: [SettingGroup: [AnySettingDefinition]]

    init(areas: [[AnySettingDefinition]], prefixRules: [PrefixRule] = Settings.System.prefixRules) {
        var defs: [String: AnySettingDefinition] = [:]
        var groups: [SettingGroup: [AnySettingDefinition]] = [:]
        for def in areas.joined() {
            if defs[def.name] != nil {
                Self.logger.fault("Duplicate setting registration: \(def.name, privacy: .public)")
                assertionFailure("Duplicate setting registration: \(def.name)")
            }
            defs[def.name] = def
            groups[def.group, default: []].append(def)
        }
        definitions = defs
        byGroup = groups
        self.prefixRules = prefixRules
        syncableKeys = Set(defs.values.filter(\.isSyncable).map(\.name))
    }

    func prefixRule(for key: String) -> PrefixRule? {
        prefixRules.first { key.hasPrefix($0.prefix) && key.count > $0.prefix.count }
    }

    /// Explicit definition, or one synthesized from a prefix rule.
    func definition(for key: String) -> AnySettingDefinition? {
        definitions[key] ?? prefixRule(for: key)?.definition(for: key)
    }

    func isSyncable(_ key: String) -> Bool {
        if syncableKeys.contains(key) { return true }
        if let rule = prefixRule(for: key) { return rule.policy != .deviceOnly }
        return false
    }

    func keys(in group: SettingGroup) -> [AnySettingDefinition] {
        byGroup[group] ?? []
    }

    // MARK: - Invariants

    /// Volatile defaults registered before protected data is available
    /// (`LaunchDefaults`) must agree with the registry, or sync would
    /// treat a registered default as a user choice.
    static let registeredVolatileDefaults: [String: CodableValue] = [
        "scrollModeEnabled": .bool(true),
        "lineScrollbackEnabled": .bool(false),
        "rubberBandScrollbackEnabled": .bool(true),
    ]

    /// Returns human-readable violations; empty when the registry is consistent.
    func invariantViolations() -> [String] {
        var problems: [String] = []
        for (key, expected) in Self.registeredVolatileDefaults {
            guard let def = definitions[key] else {
                problems.append("Volatile default \(key) is not registered")
                continue
            }
            if def.defaultCodable != expected {
                problems.append("Registry default for \(key) differs from registered volatile default")
            }
        }
        var configKeys: [String: String] = [:]
        for def in definitions.values {
            guard let ck = def.configKey else { continue }
            if let other = configKeys[ck] {
                problems.append("configKey \(ck) used by both \(other) and \(def.name)")
            }
            configKeys[ck] = def.name
            if def.policy == .deviceOnly {
                problems.append("Device-only key \(def.name) must not have a configKey")
            }
            if def.valueType == .data {
                problems.append("Data blob \(def.name) must not have a configKey")
            }
        }
        return problems.sorted()
    }

    func assertInvariants() {
        #if DEBUG
        let problems = invariantViolations()
        if !problems.isEmpty {
            for p in problems { Self.logger.fault("\(p, privacy: .public)") }
            assertionFailure(problems.joined(separator: "\n"))
        }
        #endif
    }
}
