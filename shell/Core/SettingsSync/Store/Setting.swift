//
//  Setting.swift
//  shell
//
//  SwiftUI property wrapper replacing @AppStorage for registered keys. Reads
//  the registry default, observes its own key only, and writes through the store.
//

import SwiftUI

@MainActor
@propertyWrapper
struct Setting<V: SettingValue>: DynamicProperty {
    private let key: SettingKey<V>
    private let holder = BoxHolder()

    init(_ key: SettingKey<V>) {
        self.key = key
    }

    /// Resolved on first read so declaring a `@Setting` never builds the store or registry.
    private var box: SettingBox {
        if let box = holder.box { return box }
        let box = SettingsStore.shared.box(for: key.name)
        holder.box = box
        return box
    }

    var wrappedValue: V {
        get { box.value.flatMap(V.init(codableValue:)) ?? key.defaultValue }
        nonmutating set { SettingsStore.shared.set(key, newValue) }
    }

    var projectedValue: Binding<V> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }

    /// True when the user has stored a value for this key.
    var isUserSet: Bool { box.value != nil }

    func reset() {
        SettingsStore.shared.reset(key)
    }
}

@MainActor
private final class BoxHolder {
    var box: SettingBox?
}
