//
//  WindowDragObserver.swift
//  shell
//
//  Tracks live AppKit window moves on Mac Catalyst.
//

#if targetEnvironment(macCatalyst)
import UIKit
import Combine
import QuartzCore
import os

/// Tracks whether an NSWindow is currently being moved (titlebar or
/// hidden-titlebar drag-strip drag). While a move is in progress Catalyst
/// keeps routing pointer scroll deltas to whatever view slides under the
/// pointer, so the terminal scroll paths consult `isWindowMoving` and swallow
/// them; hit-test shields can't help because the routing follows the live
/// pointer position, not the touch-begin view.
///
/// Detection uses three cooperating signals, because no single one is
/// reliable on Catalyst:
/// 1. A pointer press held on the drag strip (reported by
///    `DragStripEventShield`) — suppresses for the whole press, no timeouts.
/// 2. NSWindowWillMove/DidMove notifications (delivery on Catalyst is not
///    guaranteed on all versions).
/// 3. A display link that polls the actual NSWindow frames through the typed bridge
///    while either signal above is live — the ground truth for "still
///    moving", and the only end-of-move signal AppKit gives us at all.
@MainActor
final class WindowDragObserver {
    static let shared = WindowDragObserver()

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "WindowDragObserver")

    /// Seconds of frame quiet after the last observed movement before the
    /// flag clears (there is no "move ended" event to key off).
    private static let quietPeriod: CFTimeInterval = 0.35

    var isWindowMoving: Bool { dragStripTouches > 0 || moveActivityActive }

    private var dragStripTouches = 0
    private var moveActivityActive = false
    private var displayLink: CADisplayLink?
    private var lastWindowFrames: [CGRect] = []
    private var lastMovementTime: CFTimeInterval = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        for (name, action) in [
            ("ShellMacDragStripHover", { [weak self] in self?.noteDragStripHover() }),
            ("ShellMacDragStripBegan", { [weak self] in self?.dragStripTouchBegan() }),
            ("ShellMacDragStripEnded", { [weak self] in self?.dragStripTouchEnded() })
        ] {
            NotificationCenter.default.publisher(for: Notification.Name(name))
                .receive(on: DispatchQueue.main)
                .sink { _ in action() }
                .store(in: &cancellables)
        }
        for name in ["NSWindowWillMoveNotification", "NSWindowDidMoveNotification"] {
            NotificationCenter.default.publisher(for: Notification.Name(name))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.noteMoveActivity()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Signals

    /// A pointer press began on the hidden-titlebar drag strip.
    func dragStripTouchBegan() {
        dragStripTouches += 1
        Self.logger.debug("Drag strip touch began")
        startMonitoring()
    }

    /// The drag strip press ended or was cancelled. Catalyst cancels the
    /// UIKit touch when AppKit takes over the window drag, so the display
    /// link keeps running until the window frames go quiet.
    func dragStripTouchEnded() {
        dragStripTouches = max(0, dragStripTouches - 1)
    }

    /// The pointer is hovering a draggable strip (AppKit TitlebarDragHandle
    /// tracking). Runs the frame poll speculatively so a drag started here is
    /// caught even when no UIKit touch or AppKit notification is delivered.
    func noteDragStripHover() {
        startMonitoring()
    }

    private func noteMoveActivity() {
        if !moveActivityActive {
            Self.logger.debug("Window move activity began (notification)")
        }
        moveActivityActive = true
        lastMovementTime = CACurrentMediaTime()
        startMonitoring()
    }

    // MARK: - Frame polling

    private func startMonitoring() {
        guard displayLink == nil else { return }
        lastMovementTime = CACurrentMediaTime()
        lastWindowFrames = Self.currentWindowFrames()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let frames = Self.currentWindowFrames()
        if frames != lastWindowFrames {
            lastWindowFrames = frames
            lastMovementTime = CACurrentMediaTime()
            if !moveActivityActive {
                Self.logger.debug("Window move activity began (frame poll)")
            }
            moveActivityActive = true
            return
        }

        if CACurrentMediaTime() - lastMovementTime > Self.quietPeriod {
            if moveActivityActive {
                Self.logger.debug("Window move activity ended")
            }
            moveActivityActive = false
            if dragStripTouches == 0 {
                displayLink?.invalidate()
                displayLink = nil
            }
        }
    }

    /// All NSWindow frames, read through the macOS support bundle.
    /// Only called while a drag signal is live, so the per-frame cost
    /// is limited to actual drags.
    private static func currentWindowFrames() -> [CGRect] {
        guard let bridge = MacSupport.bridge else { return [] }
        return bridge.windows.map { bridge.frame(of: $0) }
    }
}
#endif
