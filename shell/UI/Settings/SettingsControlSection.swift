//
//  SettingsControlSection.swift
//  shell
//
//  Optional control companion: phone-first enrollment against the baked-in
//  broker, Safari confirmation, and Watch setup assistance
//  (spec.watch.md sections 1 and 5).
//

import SwiftUI

struct SettingsControlSection: View {
    var body: some View {
        ControlSetupView(companion: .shared)
    }
}
