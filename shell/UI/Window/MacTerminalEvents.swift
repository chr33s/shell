#if targetEnvironment(macCatalyst)
import UIKit
import AppKit
import GhosttyKit

@MainActor
enum MacTerminalEvents {
    private static let cursorToken = UUID()

    static func install() {
        MacSupport.bridge?.installTerminalEvents(scroll: { nativeWindow, point, dx, dy, precise, phase in
            guard let (terminal, location) = target(nativeWindow, at: point) else { return false }
            // Preserve the existing horizontal tab-swipe recognizer.
            if abs(dx) > abs(dy) { return false }
            guard !WindowDragObserver.shared.isWindowMoving else { return true }
            terminal.lastMousePosition = location
            _ = terminal.cancelMomentumScrolling()
            let mods = Ghostty.Input.ScrollMods(precision: precise,
                momentum: Ghostty.Input.Momentum(rawValue: UInt8(phase)) ?? .none)
            if let surface = terminal.surface {
                let pixels = terminal.viewToPixelCoordinates(location)
                ghostty_surface_mouse_pos(surface, pixels.x, pixels.y, Ghostty.Input.Mods.none.cMods)
            }
            terminal.sendMouseScroll(deltaX: dx, deltaY: dy, mods: mods.cMods)
            terminal.multiplexerScrollObserver?.notifyScrollActivity()
            return true
        }, hover: { nativeWindow, point in
            guard let nativeWindow, let (terminal, location) = target(nativeWindow, at: point) else {
                CatalystCursorCoordinator.shared.unregister(cursorToken)
                return
            }
            let cursor: NSCursor = location.x >= terminal.bounds.maxX - 14 ? .arrow : .iBeam
            CatalystCursorCoordinator.shared.ensure(cursorToken, cursor: cursor, priority: .terminal)
        }, menu: { nativeWindow, point in
            guard let (terminal, location) = target(nativeWindow, at: point),
                  let surface = terminal.surface, !ghostty_surface_mouse_captured(surface) else { return nil }
            _ = terminal.becomeFirstResponder()
            NotificationCenter.default.post(name: .focusSplit, object: terminal)
            return terminal.nativeContextMenu(at: location)
        })
    }

    private static func target(_ nativeWindow: NSObject, at normalizedPoint: CGPoint) -> (Ghostty.TerminalView, CGPoint)? {
        guard let sceneID = WindowAccessor.sceneSessionId(for: nativeWindow),
              let scene = UIApplication.shared.connectedScenes.first(where: { $0.session.persistentIdentifier == sceneID }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return nil }
        let location = CGPoint(x: normalizedPoint.x * window.bounds.width, y: normalizedPoint.y * window.bounds.height)
        var view = window.hitTest(location, with: nil)
        while let candidate = view {
            if let terminal = candidate as? Ghostty.TerminalView {
                return (terminal, terminal.convert(location, from: window))
            }
            if let scroll = candidate as? Ghostty.TerminalScrollView {
                return (scroll.terminalView, scroll.terminalView.convert(location, from: window))
            }
            view = candidate.superview
        }
        return nil
    }
}

/// Converts the existing menu model using public UIKit APIs, retaining its actions
/// for the duration of AppKit's synchronous menu tracking loop.
final class CatalystMenuEntry: NSObject, MacMenuEntry {
    let title: String
    let enabled: Bool
    let state: Int
    let isSeparator: Bool
    let children: [any MacMenuEntry]
    private let action: () -> Void

    init(title: String = "", enabled: Bool = true, state: Int = 0, separator: Bool = false,
         children: [any MacMenuEntry] = [], action: @escaping () -> Void = {}) {
        self.title = title; self.enabled = enabled; self.state = state
        self.isSeparator = separator; self.children = children; self.action = action
    }
    func invoke() { action() }

    static func entries(_ menu: UIMenu, responder: UIResponder) -> [any MacMenuEntry] {
        var result: [any MacMenuEntry] = []
        for element in menu.children {
            if let group = element as? UIMenu {
                let children = entries(group, responder: responder)
                if group.options.contains(.displayInline) {
                    if !result.isEmpty, !children.isEmpty { result.append(CatalystMenuEntry(separator: true)) }
                    result += children
                } else {
                    result.append(CatalystMenuEntry(title: group.title, children: children))
                }
            } else if let action = element as? UIAction {
                if action.attributes.contains(.hidden) { continue }
                let control = UIControl()
                control.addAction(action, for: .primaryActionTriggered)
                result.append(CatalystMenuEntry(title: action.title, enabled: !action.attributes.contains(.disabled),
                    state: action.state == .mixed ? -1 : (action.state == .on ? 1 : 0)) {
                    control.sendActions(for: .primaryActionTriggered)
                })
            } else if let command = element as? UICommand {
                if command.attributes.contains(.hidden) { continue }
                result.append(CatalystMenuEntry(title: command.title,
                    enabled: !command.attributes.contains(.disabled) && responder.canPerformAction(command.action, withSender: command),
                    state: command.state == .mixed ? -1 : (command.state == .on ? 1 : 0)) {
                    UIApplication.shared.sendAction(command.action, to: responder, from: command, for: nil)
                })
            }
        }
        return result
    }
}
#endif
