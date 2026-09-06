//
//  SettingPinTag.swift
//  shell
//
//  Provenance glyph for a settings row or group header: kept on this device,
//  or nothing. A single small symbol so it never competes with the title for
//  width; the words live in the context menu and the accessibility label.
//  Renders as EmptyView when there is nothing to say so it drops into any
//  HStack without spacing artifacts.
//

import SwiftUI

struct SettingPinTag: View {
    private enum Subject {
        case key(String)
        case group(SettingGroup)
    }

    private let subject: Subject
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var syncManager = CloudKitSyncManager.shared

    init(_ definition: AnySettingDefinition) {
        subject = .key(definition.name)
    }

    init(key: String) {
        subject = .key(key)
    }

    init(group: SettingGroup) {
        subject = .group(group)
    }

    var body: some View {
        switch subject {
        case .key(let name):
            if syncManager.isAppSettingsSyncEnabled {
                keyGlyph(coordinator.pinState(for: name))
            }
        case .group(let group):
            if syncManager.isAppSettingsSyncEnabled {
                groupGlyph(coordinator.pinState(for: group))
            }
        }
    }

    @ViewBuilder
    private func keyGlyph(_ state: SettingPinState) -> some View {
        switch state {
        case .key:
            glyph("pin.fill", tint: .tint)
                .accessibilityLabel(Text("Kept on this device"))
        case .group:
            glyph("pin", tint: .secondary)
                .accessibilityLabel(Text("Kept on this device with its group"))
        case .none, .deviceOnly:
            EmptyView()
        }
    }

    @ViewBuilder
    private func groupGlyph(_ state: GroupPinState) -> some View {
        switch state {
        case .all:
            glyph("pin.fill", tint: .tint)
                .accessibilityLabel(Text("Whole group kept on this device"))
        case .partial(let pinned, let total):
            glyph("pin", tint: .secondary)
                .accessibilityLabel(Text(String(localized: "\(pinned) of \(total) settings kept on this device",
                                                comment: "Partially pinned group accessibility label")))
        case .none:
            EmptyView()
        }
    }

    private func glyph(_ symbol: String, tint: some ShapeStyle) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .fixedSize()
            .accessibilityHidden(false)
    }
}
