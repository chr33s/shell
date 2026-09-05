//
//  SSHAuthBannerCardHostView.swift
//  shell
//
//  UIKit wrapper hosting the SwiftUI SSH auth-banner card inside the
//  UIKit-based TerminalScrollView. Modeled on MoshRoamBannerHostView, but
//  interactive (open/copy/collapse actions) and re-homeable so a mid-auth
//  window transfer keeps the child view controller chain valid.
//

import SwiftUI
import UIKit

@MainActor
final class SSHAuthBannerCardHostView: UIView {

    // MARK: - Properties

    private var hostingController: UIHostingController<SSHAuthBannerCardView>?
    private weak var parentViewController: UIViewController?

    /// Current card state (readable for stacking/cleanup checks).
    private(set) var currentState: SSHAuthBannerCardState?

    /// Collapse lives here, not in SwiftUI @State: the rootView is replaced on
    /// every state update, which would silently reset view-local state.
    private var isCollapsed = false

    /// Opens a banner URL. Injected so the host stays testable/preview-safe;
    /// defaults to the platform browser via UIApplication.
    var onOpenURL: (URL) -> Void = { url in
        UIApplication.shared.open(url)
    }

    /// Copies a banner URL, like the terminal's own Copy Link action.
    var onCopyURL: (URL) -> Void = { url in
        UIPasteboard.general.string = url.absoluteString
    }

    /// Retires the card in the owning session's model. The host hides itself
    /// first for immediacy; this makes the dismissal stick across pane
    /// switches and window transfers, which replay from that model.
    var onDismissRequested: () -> Void = {}

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Updates the card with new state; nil hides and tears down.
    func update(state: SSHAuthBannerCardState?) {
        if state == currentState { return }
        // New banner content must be seen: force-expand when items grow.
        if let state, state.items.count > (currentState?.items.count ?? 0), isCollapsed {
            isCollapsed = false
        }
        currentState = state

        if let state {
            showCard(with: state)
            UIAccessibility.post(notification: .layoutChanged, argument: hostingController?.view)
        } else {
            isCollapsed = false
            hideCard()
        }
    }

    /// Sets (or re-homes to) the parent view controller. Unlike the Mosh
    /// template, an existing hosting controller is moved to the new parent so
    /// a window transfer mid-auth doesn't strand the child VC.
    func setParentViewController(_ viewController: UIViewController?) {
        guard parentViewController !== viewController else { return }
        parentViewController = viewController
        guard let hc = hostingController else { return }
        hc.willMove(toParent: nil)
        hc.removeFromParent()
        if let parent = viewController {
            parent.addChild(hc)
            hc.didMove(toParent: parent)
        }
    }

    // MARK: - Private Methods

    private func rootView(for state: SSHAuthBannerCardState) -> SSHAuthBannerCardView {
        SSHAuthBannerCardView(
            state: state,
            isCollapsed: isCollapsed,
            onToggleCollapse: { [weak self] in
                guard let self else { return }
                self.isCollapsed.toggle()
                if let current = self.currentState {
                    self.showCard(with: current)
                }
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                // Hide locally first so the animation is immediate; the model
                // clear that follows re-broadcasts nil, which update(state:)
                // no-ops on via its state == currentState early return.
                self.update(state: nil)
                self.onDismissRequested()
            },
            onOpenURL: { [weak self] url in self?.onOpenURL(url) },
            onCopyURL: { [weak self] url in self?.onCopyURL(url) }
        )
    }

    private func showCard(with state: SSHAuthBannerCardState) {
        if let hc = hostingController {
            hc.rootView = rootView(for: state)
            hc.view.invalidateIntrinsicContentSize()
            // Reverse an in-flight hide: a reset followed immediately by a new
            // banner (e.g. retry-attempt clear then a fresh banner) must leave
            // the card visible. The hide completion checks currentState, so
            // reanimating here also defuses its teardown.
            if hc.view.alpha < 1 {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    hc.view.alpha = 1
                    hc.view.transform = .identity
                }
            }
        } else {
            let hc = UIHostingController(rootView: rootView(for: state))
            hc.view.backgroundColor = .clear
            hc.view.translatesAutoresizingMaskIntoConstraints = false

            if let parent = parentViewController {
                parent.addChild(hc)
                addSubview(hc.view)
                hc.didMove(toParent: parent)
            } else {
                addSubview(hc.view)
            }

            NSLayoutConstraint.activate([
                hc.view.topAnchor.constraint(equalTo: topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: bottomAnchor),
                hc.view.leadingAnchor.constraint(equalTo: leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            hostingController = hc

            hc.view.alpha = 0
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            if !reduceMotion {
                hc.view.transform = CGAffineTransform(translationX: 0, y: -10)
            }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                hc.view.alpha = 1
                hc.view.transform = .identity
            }
        }
    }

    private func hideCard() {
        guard let hc = hostingController else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
            hc.view.alpha = 0
            if !reduceMotion {
                hc.view.transform = CGAffineTransform(translationX: 0, y: -10)
            }
        } completion: { [weak self] _ in
            // A new banner may have re-shown the card while the hide was
            // animating; tear down only if this controller is still current
            // AND the card is still meant to be hidden.
            guard let self, self.hostingController === hc, self.currentState == nil else {
                return
            }
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
            self.hostingController = nil
        }
    }
}
