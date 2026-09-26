import UIKit

/// Owns the terminal's transient overlay scrollbar and its reveal timer.
/// The terminal supplies viewport values; this object owns only presentation.
@MainActor
final class TerminalScrollIndicator {
    private let view = UIView()
    private var hideWorkItem: DispatchWorkItem?
    private var revealDeadline: TimeInterval = 0

    init() {
        view.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        view.layer.cornerRadius = 2
        view.alpha = 0
        view.isUserInteractionEnabled = false
    }

    func attach(to parent: UIView) {
        parent.addSubview(view)
    }

    func stop() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        view.removeFromSuperview()
    }

    func noteUserScroll() {
        revealDeadline = Date().timeIntervalSinceReferenceDate + 1
    }

    func layout(total: UInt64, offset: UInt64, length: UInt64, in bounds: CGRect) {
        let isAtBottom = offset + length >= total
        guard total != 0, !isAtBottom else { return }

        let indicatorWidth: CGFloat = 4
        let inset: CGFloat = 2
        let proportion = Float(length) / Float(total)
        let indicatorHeight = max(CGFloat(proportion) * bounds.height, 30)
        let scrollPosition = Float(offset) / Float(total)
        let indicatorY = CGFloat(scrollPosition) * (bounds.height - indicatorHeight)
        let frame = CGRect(
            x: bounds.width - indicatorWidth - inset,
            y: indicatorY,
            width: indicatorWidth,
            height: indicatorHeight
        )
        if view.frame != frame {
            UIView.performWithoutAnimation { view.frame = frame }
        }
    }

    func scrollbarChanged(total: UInt64, offset: UInt64, length: UInt64, in bounds: CGRect, mouseCaptured: Bool) {
        layout(total: total, offset: offset, length: length, in: bounds)
        let reveal = Date().timeIntervalSinceReferenceDate <= revealDeadline
        revealDeadline = 0
        let isAtBottom = offset + length >= total
        let shouldBeVisible = total != 0 && !isAtBottom && !mouseCaptured
        let targetAlpha: CGFloat = shouldBeVisible ? 1 : 0

        if !shouldBeVisible {
            hideWorkItem?.cancel()
            hideWorkItem = nil
        }
        guard reveal || !shouldBeVisible else { return }

        if view.alpha != targetAlpha {
            UIView.animate(withDuration: 0.2) { self.view.alpha = targetAlpha }
        }
        if shouldBeVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.5) { self.view.alpha = 0 }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
}
