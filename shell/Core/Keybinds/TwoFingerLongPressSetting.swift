//
//  TwoFingerLongPressSetting.swift
//  shell
//
//  Shared constants for the user-configurable two-finger long-press gesture
//  that opens the new connection sheet. Stored as a Double in UserDefaults
//  where the value is `minimumPressDuration` in seconds and 0 means Off.
//

import Foundation

enum TwoFingerLongPressSetting {
    static let key = "twoFingerLongPressDuration"
    static let defaultDuration: Double = 0.5

    struct Option: Identifiable {
        let label: String
        let value: Double
        var id: Double { value }
    }

    static let options: [Option] = [
        Option(label: String(localized: "0.5s", comment: "Two-finger long press duration: 0.5 seconds (the original default)"), value: 0.5),
        Option(label: String(localized: "1.0s", comment: "Two-finger long press duration: 1 second"), value: 1.0),
        Option(label: String(localized: "2.0s", comment: "Two-finger long press duration: 2 seconds"), value: 2.0),
        Option(label: String(localized: "Off", comment: "Two-finger long press: gesture disabled"), value: 0.0),
    ]

    nonisolated static func storedDuration() -> Double {
        SettingsStore.shared.value(Settings.Gestures.twoFingerLongPressDuration)
    }
}
