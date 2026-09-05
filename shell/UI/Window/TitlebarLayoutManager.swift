import CoreGraphics
import Foundation
import Combine

@MainActor
@Observable
final class TitlebarLayoutManager {
    static let shared = TitlebarLayoutManager()

    private(set) var leadingInset: CGFloat

    private init() {
        let savedInset = SettingsStore.shared.get(Settings.Window.titlebarLeadingInset)
        leadingInset = savedInset > 0 ? savedInset : 0
    }

    func updateLeadingInset(_ inset: CGFloat) {
        let clampedInset = max(0, inset)
        guard clampedInset > 0 else { return }
        guard abs(clampedInset - leadingInset) > 0.5 else { return }
        leadingInset = clampedInset
        SettingsStore.shared.set(Settings.Window.titlebarLeadingInset, Double(clampedInset))
    }
}
