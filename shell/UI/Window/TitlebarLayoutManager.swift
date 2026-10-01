import CoreGraphics
import Foundation

@MainActor
@Observable
final class TitlebarLayoutManager {
    static let shared = TitlebarLayoutManager()

    private(set) var leadingInset: CGFloat

    /// Width of the native toolbar's item area at the trailing edge of the
    /// title bar. Measured by the AppKit bundle after the toolbar lays out;
    /// not persisted, since it depends only on the current toolbar.
    private(set) var trailingInset: CGFloat = 0

    /// Height of the title bar including its unified toolbar. The tab strip
    /// shares that row with the toolbar items and sizes itself to it.
    private(set) var titlebarHeight: CGFloat = 0

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

    func updateTrailingInset(_ inset: CGFloat) {
        let clamped = max(0, inset)
        guard abs(clamped - trailingInset) > 0.5 else { return }
        trailingInset = clamped
    }

    func updateTitlebarHeight(_ height: CGFloat) {
        let clamped = max(0, height)
        guard abs(clamped - titlebarHeight) > 0.5 else { return }
        titlebarHeight = clamped
    }
}
