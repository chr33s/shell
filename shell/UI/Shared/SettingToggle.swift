//
//  SettingToggle.swift
//  shell
//
//  The common settings row: a Toggle bound to a registered key, with the
//  pin tag and context menu attached. Call sites keep their `.themedRow()`.
//

import SwiftUI

struct SettingToggle: View {
    private let key: SettingKey<Bool>
    private let title: LocalizedStringKey
    private let icon: String?
    private let inverted: Bool
    private let external: Binding<Bool>?
    private let onChange: ((Bool) -> Void)?
    @Setting private var stored: Bool

    /// Store-backed. `inverted` shows the toggle as the opposite of the stored value.
    init(
        _ key: SettingKey<Bool>,
        title: LocalizedStringKey,
        icon: String? = nil,
        inverted: Bool = false,
        onChange: ((Bool) -> Void)? = nil
    ) {
        self.key = key
        self.title = title
        self.icon = icon
        self.inverted = inverted
        self.external = nil
        self.onChange = onChange
        _stored = Setting(key)
    }

    /// Manager-backed: the value comes from the binding, provenance from the key.
    init(
        _ key: SettingKey<Bool>,
        isOn: Binding<Bool>,
        title: LocalizedStringKey,
        icon: String? = nil
    ) {
        self.key = key
        self.title = title
        self.icon = icon
        self.inverted = false
        self.external = isOn
        self.onChange = nil
        _stored = Setting(key)
    }

    private var binding: Binding<Bool> {
        if let external { return external }
        return Binding(
            get: { inverted ? !stored : stored },
            set: { newValue in
                let value = inverted ? !newValue : newValue
                stored = value
                onChange?(value)
            }
        )
    }

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 12) {
                if let icon {
                    SettingsIcon(systemName: icon)
                }
                Text(title)
                    .layoutPriority(1)
                SettingPinTag(key.erased)
            }
        }
        .disabled(SettingFileLock.isReadOnly(key.name))
        .settingContextMenu(key)
    }
}

/// No settings are file-bound in this fork; every registered key is editable.
@MainActor
enum SettingFileLock {
    static func isReadOnly(_ key: String) -> Bool { false }
}
