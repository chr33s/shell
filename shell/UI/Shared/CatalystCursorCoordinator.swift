import Foundation

#if targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

@MainActor
final class CatalystCursorCoordinator {
    static let shared = CatalystCursorCoordinator()

    enum Priority: Int {
        case terminal = 0
        case ui = 1
        case titlebar = 2
    }

    private struct Entry {
        var cursor: NSCursor
        var priority: Priority
        var order: UInt64
    }

    private var entries: [UUID: Entry] = [:]
    private var orderCounter: UInt64 = 0

    private init() {}

    func register(_ token: UUID, cursor: NSCursor, priority: Priority = .ui) {
        orderCounter &+= 1
        entries[token] = Entry(cursor: cursor, priority: priority, order: orderCounter)
        applyTopCursor()
    }

    func ensure(_ token: UUID, cursor: NSCursor, priority: Priority = .ui) {
        if entries[token] == nil {
            register(token, cursor: cursor, priority: priority)
        } else {
            update(token, cursor: cursor, priority: priority)
        }
    }

    func update(_ token: UUID, cursor: NSCursor, priority: Priority? = nil) {
        guard var entry = entries[token] else { return }
        entry.cursor = cursor
        if let priority {
            entry.priority = priority
        }
        entries[token] = entry
        applyTopCursor()
    }

    func unregister(_ token: UUID) {
        entries.removeValue(forKey: token)

        if entries.isEmpty {
            // Always reset to arrow when no cursors are registered
            NSCursor.arrow.set()
            return
        }

        applyTopCursor()
    }

    func resetAll() {
        entries.removeAll()
        orderCounter = 0
        NSCursor.arrow.set()
    }

    private func applyTopCursor() {
        guard let topCursor = entries.max(by: { lhs, rhs in
            if lhs.value.priority != rhs.value.priority {
                return lhs.value.priority.rawValue < rhs.value.priority.rawValue
            }
            return lhs.value.order < rhs.value.order
        })?.value.cursor else {
            return
        }
        topCursor.set()
    }
}

private struct CatalystCursorRegionModifier: ViewModifier {
    let cursor: NSCursor
    let priority: CatalystCursorCoordinator.Priority
    @State private var cursorToken: UUID?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    if cursorToken == nil {
                        cursorToken = UUID()
                    }
                    if let cursorToken {
                        CatalystCursorCoordinator.shared.ensure(
                            cursorToken,
                            cursor: cursor,
                            priority: priority
                        )
                    }
                } else if let cursorToken {
                    CatalystCursorCoordinator.shared.unregister(cursorToken)
                    self.cursorToken = nil
                }
            }
            .onDisappear {
                if let cursorToken {
                    CatalystCursorCoordinator.shared.unregister(cursorToken)
                    self.cursorToken = nil
                }
            }
    }
}

extension View {
    func catalystCursorRegion(
        _ cursor: NSCursor = .arrow,
        priority: CatalystCursorCoordinator.Priority = .ui
    ) -> some View {
        modifier(CatalystCursorRegionModifier(cursor: cursor, priority: priority))
    }
}
#endif
