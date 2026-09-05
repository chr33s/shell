//
//  SettingsIcon.swift
//  shell
//

import SwiftUI

struct SettingsIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17))
            .foregroundStyle(.tint)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}
