//
//  SettingKey.swift
//  shell
//
//  Typed, declarative description of one UserDefaults-backed setting.
//  Values are decoded by their DECLARED type, never sniffed from the stored
//  object, so an Int stored as 0/1 is never mistaken for a Bool.
//

import Foundation

// MARK: - SettingValue

/// A value type that can live in UserDefaults and be carried as a `CodableValue`.
/// `codableValue == nil` means "unset" and only `Optional` produces it.
nonisolated protocol SettingValue: Sendable, Equatable {
    static var valueType: CodableValue.ValueType { get }
    var codableValue: CodableValue? { get }
    init?(codableValue: CodableValue)
}

nonisolated extension Bool: SettingValue {
    static var valueType: CodableValue.ValueType { .bool }
    var codableValue: CodableValue? { .bool(self) }
    init?(codableValue: CodableValue) {
        guard case .bool(let v) = codableValue else { return nil }
        self = v
    }
}

nonisolated extension Int: SettingValue {
    static var valueType: CodableValue.ValueType { .int }
    var codableValue: CodableValue? { .int(self) }
    init?(codableValue: CodableValue) {
        switch codableValue {
        case .int(let v): self = v
        case .double(let v) where v.rounded() == v: self = Int(v)
        default: return nil
        }
    }
}

nonisolated extension Double: SettingValue {
    static var valueType: CodableValue.ValueType { .double }
    var codableValue: CodableValue? { .double(self) }
    init?(codableValue: CodableValue) {
        switch codableValue {
        case .double(let v): self = v
        case .int(let v): self = Double(v)
        default: return nil
        }
    }
}

nonisolated extension String: SettingValue {
    static var valueType: CodableValue.ValueType { .string }
    var codableValue: CodableValue? { .string(self) }
    init?(codableValue: CodableValue) {
        guard case .string(let v) = codableValue else { return nil }
        self = v
    }
}

nonisolated extension Array: SettingValue where Element == String {
    static var valueType: CodableValue.ValueType { .stringArray }
    var codableValue: CodableValue? { .stringArray(self) }
    init?(codableValue: CodableValue) {
        guard case .stringArray(let v) = codableValue else { return nil }
        self = v
    }
}

nonisolated extension Data: SettingValue {
    static var valueType: CodableValue.ValueType { .data }
    var codableValue: CodableValue? { .data(self) }
    init?(codableValue: CodableValue) {
        guard case .data(let v) = codableValue else { return nil }
        self = v
    }
}

nonisolated extension Optional: SettingValue where Wrapped: SettingValue {
    static var valueType: CodableValue.ValueType { Wrapped.valueType }
    var codableValue: CodableValue? { self?.codableValue }
    init?(codableValue: CodableValue) {
        guard let v = Wrapped(codableValue: codableValue) else { return nil }
        self = .some(v)
    }
}

/// Enums opt in with `extension MyEnum: SettingValue {}`; membership is validated on decode.
nonisolated extension SettingValue where Self: RawRepresentable, RawValue: SettingValue {
    static var valueType: CodableValue.ValueType { RawValue.valueType }
    var codableValue: CodableValue? { rawValue.codableValue }
    init?(codableValue: CodableValue) {
        guard let raw = RawValue(codableValue: codableValue) else { return nil }
        self.init(rawValue: raw)
    }
}

// MARK: - CodableValue bridging

nonisolated extension CodableValue {
    /// Decode a raw UserDefaults object by declared type. Returns nil on type mismatch.
    init?(userDefaultsObject raw: Any, as type: ValueType) {
        switch type {
        case .bool:
            guard let n = raw as? NSNumber else { return nil }
            self = .bool(n.boolValue)
        case .int:
            guard let n = raw as? NSNumber else { return nil }
            self = .int(n.intValue)
        case .double:
            guard let n = raw as? NSNumber else { return nil }
            self = .double(n.doubleValue)
        case .string:
            guard let s = raw as? String else { return nil }
            self = .string(s)
        case .data:
            guard let d = raw as? Data else { return nil }
            self = .data(d)
        case .stringArray:
            guard let a = raw as? [Any] else { return nil }
            var out: [String] = []
            out.reserveCapacity(a.count)
            for e in a {
                guard let s = e as? String else { return nil }
                out.append(s)
            }
            self = .stringArray(out)
        }
    }

    var valueType: ValueType {
        switch self {
        case .string: .string
        case .int: .int
        case .double: .double
        case .bool: .bool
        case .data: .data
        case .stringArray: .stringArray
        }
    }

    /// Short human rendering for pin lists and menus.
    var displayString: String {
        switch self {
        case .string(let v): v
        case .int(let v): String(v)
        case .double(let v): v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v)
        case .bool(let v): v
            ? String(localized: "On", comment: "Setting value display")
            : String(localized: "Off", comment: "Setting value display")
        case .data(let v): String(localized: "\(v.count) bytes", comment: "Setting value display for binary data")
        case .stringArray(let v): v.joined(separator: ", ")
        }
    }
}

// MARK: - SettingKey

/// One registered setting. Declared once per key in the `Settings` namespace.
nonisolated struct SettingKey<V: SettingValue>: Sendable, Hashable {
    let name: String
    let defaultValue: V
    let policy: SyncPolicy
    let group: SettingGroup
    /// Name in the text config overlay; ghostty's name when semantics match. Nil = not file-editable.
    let configKey: String?
    let title: String

    init(
        _ name: String,
        default defaultValue: V,
        group: SettingGroup,
        policy: SyncPolicy = .synced,
        configKey: String? = nil,
        title: String
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.policy = policy
        self.group = group
        self.configKey = configKey
        self.title = title
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    var erased: AnySettingDefinition { AnySettingDefinition(self) }
}

// MARK: - AnySettingDefinition

/// Type-erased definition used by the registry, store, sync, and UI.
nonisolated struct AnySettingDefinition: Sendable, Identifiable {
    let name: String
    let policy: SyncPolicy
    let group: SettingGroup
    let configKey: String?
    let title: String
    /// Nil for opaque device-only keys whose value shape the registry does not model.
    let valueType: CodableValue.ValueType?
    let defaultCodable: CodableValue?
    /// Raw UserDefaults object -> typed value, or nil on mismatch.
    let read: @Sendable (Any) -> CodableValue?
    /// Type and enum-membership check for values arriving from outside (iCloud, config file).
    let validate: @Sendable (CodableValue) -> Bool
    /// Value rendering for UI; nil renders the default.
    let display: @Sendable (CodableValue?) -> String

    var id: String { name }
    var isSyncable: Bool { policy != .deviceOnly }

    init<V: SettingValue>(_ key: SettingKey<V>) {
        name = key.name
        policy = key.policy
        group = key.group
        configKey = key.configKey
        title = key.title
        valueType = V.valueType
        defaultCodable = key.defaultValue.codableValue
        read = { raw in
            guard let cv = CodableValue(userDefaultsObject: raw, as: V.valueType),
                  let typed = V(codableValue: cv) else { return nil }
            return typed.codableValue
        }
        validate = { cv in V(codableValue: cv) != nil }
        let fallback = key.defaultValue.codableValue
        display = { cv in
            (cv ?? fallback)?.displayString
                ?? String(localized: "Not set", comment: "Setting value display when unset")
        }
    }

    /// Definition synthesized from a prefix rule; typed by wire type only.
    static func dynamic(
        _ name: String, valueType: CodableValue.ValueType, policy: SyncPolicy, group: SettingGroup, title: String
    ) -> AnySettingDefinition {
        AnySettingDefinition(
            name: name, policy: policy, group: group, configKey: nil, title: title,
            valueType: valueType, defaultCodable: nil,
            read: { CodableValue(userDefaultsObject: $0, as: valueType) },
            validate: { $0.valueType == valueType },
            display: { $0?.displayString ?? String(localized: "Not set", comment: "Setting value display when unset") }
        )
    }

    /// Device-only key with an unmodeled value (Date, dictionary, archived object).
    static func opaque(_ name: String, group: SettingGroup = .system, title: String) -> AnySettingDefinition {
        AnySettingDefinition(
            name: name, policy: .deviceOnly, group: group, configKey: nil, title: title,
            valueType: nil, defaultCodable: nil,
            read: { _ in nil }, validate: { _ in false },
            display: { _ in String(localized: "Device only", comment: "Setting value display for unmodeled device-only keys") }
        )
    }

    private init(
        name: String, policy: SyncPolicy, group: SettingGroup, configKey: String?, title: String,
        valueType: CodableValue.ValueType?, defaultCodable: CodableValue?,
        read: @escaping @Sendable (Any) -> CodableValue?,
        validate: @escaping @Sendable (CodableValue) -> Bool,
        display: @escaping @Sendable (CodableValue?) -> String
    ) {
        self.name = name
        self.policy = policy
        self.group = group
        self.configKey = configKey
        self.title = title
        self.valueType = valueType
        self.defaultCodable = defaultCodable
        self.read = read
        self.validate = validate
        self.display = display
    }
}
