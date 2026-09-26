import SwiftUI
import UIKit

/// Presents one short-lived message over a terminal surface.
@MainActor
final class TerminalTransientOverlay {
    private var host: UIHostingController<InputModeOverlayView>?
    private var dismissTask: Task<Void, Never>?
    private var presentation = 0

    func show(_ text: String, in parent: UIView, for duration: Duration) {
        presentation += 1
        dismissTask?.cancel()

        if let host {
            host.rootView = InputModeOverlayView(text: text)
            host.view.layer.removeAllAnimations()
            host.view.alpha = 1
        } else {
            let host = UIHostingController(rootView: InputModeOverlayView(text: text))
            host.sizingOptions = [.intrinsicContentSize]
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                host.view.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            ])
            self.host = host
            host.view.alpha = 0
            UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
                host.view.alpha = 1
            }
        }

        let current = presentation
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide(ifCurrent: current)
        }
    }

    func stop() {
        presentation += 1
        dismissTask?.cancel()
        dismissTask = nil
        host?.view.layer.removeAllAnimations()
        host?.view.removeFromSuperview()
        host = nil
    }

    private func hide(ifCurrent current: Int) {
        guard presentation == current, let host else { return }
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn) {
            host.view.alpha = 0
        } completion: { [weak self] finished in
            guard finished, let self, self.presentation == current else { return }
            host.view.removeFromSuperview()
            self.host = nil
        }
    }
}
