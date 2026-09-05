//
//  GhosttySurface.swift
//  shell
//
//  Wrapper around ghostty_surface_t for iOS
//

import Foundation
import GhosttyKit

extension Ghostty {
    /// Represents a single terminal surface within Ghostty
    final class Surface: Sendable {
        private let surface: ghostty_surface_t

        /// Read the underlying C value for this surface
        /// This is unsafe because the value will be freed when the Surface class is deinitialized
        var unsafeCValue: ghostty_surface_t {
            surface
        }

        /// Initialize from the C structure
        init(cSurface: ghostty_surface_t) {
            self.surface = cSurface
        }

        deinit {
            // Nothing constructs this type today; only the static helpers below
            // are used. If that changes, follow the same discipline as every
            // other free path: drop the surface from the registry first so it
            // can't keep taking config pushes, then free on the API queue so the
            // free can't overlap one.
            let surfaceAddress = Int(bitPattern: surface)
            Task { @MainActor in
                guard let ptr = UnsafeMutableRawPointer(bitPattern: surfaceAddress) else { return }

                if let app = Ghostty.App.shared {
                    app.unregisterSurfaceTab(ptr)
                    app.unregisterSurfaceWindow(ptr)
                    app.unregisterSurfaceDelegate(ptr)
                    app.unregisterSurface(ptr)
                }

                nonisolated(unsafe) let surfacePtr = ptr
                Ghostty.TerminalView.ghosttyAPIQueue.async {
                    if ScrollbackPersistenceManager.waitForSurfaceSave(surfacePtr) {
                        ghostty_surface_free(surfacePtr)
                    }
                }
            }
        }

        // MARK: - Text Input

        /// Send text to the terminal as if it was typed
        @MainActor
        func sendText(_ text: String) {
            let len = text.utf8CString.count
            if len == 0 { return }

            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Send a key event to the terminal
        @MainActor
        func sendKeyEvent(_ event: Input.KeyEvent) {
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        // MARK: - Mouse/Touch Input

        /// Whether the terminal has captured mouse input
        @MainActor
        var mouseCaptured: Bool {
            ghostty_surface_mouse_captured(surface)
        }

        /// Send a mouse button event to the terminal
        @MainActor
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods
            )
        }

        /// Send a mouse position event to the terminal
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods
            )
        }

        /// Send a mouse scroll event to the terminal
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            ghostty_surface_mouse_scroll(
                surface,
                event.deltaX,
                event.deltaY,
                event.mods.cMods
            )
        }

        // MARK: - Surface Operations

        /// Request that this surface be closed
        @MainActor
        func requestClose() {
            ghostty_surface_request_close(surface)
        }

        /// Set the size of the surface
        @MainActor
        func setSize(width: UInt32, height: UInt32) {
            ghostty_surface_set_size(surface, width, height)
        }

        /// Request a redraw
        @MainActor
        func draw() {
            ghostty_surface_draw(surface)
        }

        /// Force a refresh
        @MainActor
        func refresh() {
            ghostty_surface_refresh(surface)
        }

        /// Set the render-only vertical scroll offset in pixels.
        @MainActor
        func setSmoothScrollOffset(_ offset: Double) {
            ghostty_surface_set_smooth_scroll_offset(surface, offset)
        }

        /// Set the render-only signed rubber-band offset in pixels.
        @MainActor
        func setRubberBandOffset(_ offset: Double) {
            ghostty_surface_set_rubber_band_offset(surface, offset)
        }

        /// Scroll to an absolute row and set the render-only vertical offset.
        @MainActor
        func scrollToRowSmooth(row: Int, offset: Double) {
            ghostty_surface_scroll_to_row_smooth(surface, UInt(row), offset)
        }

        /// Set focus state
        @MainActor
        func setFocus(_ focused: Bool) {
            ghostty_surface_set_focus(surface, focused)
            ghostty_surface_refresh(surface)  // Force cursor redraw with new focus state
        }

        // MARK: - Actions

        /// Perform a binding action on this surface
        /// - Parameter action: The action string (e.g., "scroll_to_row:100", "select_all")
        /// - Returns: True if the action was performed successfully
        @MainActor
        func perform(action: String) -> Bool {
            let len = action.utf8CString.count
            if len == 0 { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }

        // MARK: - Terminal Mode Queries

        /// Returns whether cursor key application mode (DECCKM) is active.
        /// When true, arrow keys should send SS3 sequences (\x1bOA, etc.)
        /// When false, arrow keys should send CSI sequences (\x1b[A, etc.)
        @MainActor
        var cursorKeyApplicationMode: Bool {
            ghostty_surface_cursor_key_mode(surface)
        }

        // MARK: - Scrollback Persistence

        /// Total rows in the primary screen (including scrollback).
        /// Cheap check useful for detecting whether a dump is needed.
        @MainActor
        var totalRows: Int {
            Int(ghostty_surface_total_rows(surface))
        }

        /// Dump the entire primary screen with ANSI styling as raw bytes.
        /// Returns nil if the screen is empty.
        @MainActor
        func dumpPrimaryScreen() -> Data? {
            var len: UInt = 0
            guard let ptr = ghostty_surface_dump_primary_screen(surface, &len) else { return nil }
            let data = Data(bytes: ptr, count: Int(len))
            ghostty_surface_free_dump(ptr, len)
            return data
        }

        /// Whether the alternate screen is currently active (a TUI app is running).
        @MainActor
        var isAlternateScreenActive: Bool {
            ghostty_surface_is_alternate_active(surface)
        }

        /// Dump the alternate screen viewport with ANSI styling as raw bytes.
        /// Returns nil if the alternate screen is not initialized or empty.
        @MainActor
        func dumpAlternateScreen() -> Data? {
            var len: UInt = 0
            guard let ptr = ghostty_surface_dump_alternate_screen(surface, &len) else { return nil }
            let data = Data(bytes: ptr, count: Int(len))
            ghostty_surface_free_dump(ptr, len)
            return data
        }

        /// Read the top `rows` rows of the visible viewport as plain UTF-8 text
        /// (no ANSI styling). Used to scrape tmux's copy-mode position indicator.
        /// Returns nil if the read fails or returns no text.
        @MainActor
        static func readTopRows(
            _ rows: Int,
            cols: Int,
            surface: ghostty_surface_t
        ) -> String? {
            guard rows > 0, cols > 0 else { return nil }

            var selection = ghostty_selection_s()
            selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
            selection.top_left.coord = GHOSTTY_POINT_COORD_EXACT
            selection.top_left.x = 0
            selection.top_left.y = 0
            selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
            selection.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
            selection.bottom_right.x = UInt32(max(0, cols - 1))
            selection.bottom_right.y = UInt32(max(0, rows - 1))
            selection.rectangle = true

            var textStruct = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &textStruct) else { return nil }
            defer { ghostty_surface_free_text(surface, &textStruct) }

            guard textStruct.text_len > 0, let textPtr = textStruct.text else { return nil }
            let data = Data(bytes: textPtr, count: Int(textStruct.text_len))
            return String(data: data, encoding: .utf8)
        }

        /// Read the bottom `rows` rows of the ACTIVE screen as plain UTF-8
        /// text (no ANSI styling). The active screen ignores the user's
        /// scrollback position: this is the live tail that agent detection
        /// needs, and it is the alternate screen whenever a TUI is running.
        @MainActor
        static func readBottomRows(
            _ rows: Int,
            gridRows: Int,
            cols: Int,
            surface: ghostty_surface_t
        ) -> String? {
            guard rows > 0, gridRows > 0, cols > 0 else { return nil }
            let count = min(rows, gridRows)

            var selection = ghostty_selection_s()
            selection.top_left.tag = GHOSTTY_POINT_ACTIVE
            selection.top_left.coord = GHOSTTY_POINT_COORD_EXACT
            selection.top_left.x = 0
            selection.top_left.y = UInt32(gridRows - count)
            selection.bottom_right.tag = GHOSTTY_POINT_ACTIVE
            selection.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
            selection.bottom_right.x = UInt32(max(0, cols - 1))
            selection.bottom_right.y = UInt32(max(0, gridRows - 1))
            selection.rectangle = true

            var textStruct = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &textStruct) else { return nil }
            defer { ghostty_surface_free_text(surface, &textStruct) }

            guard textStruct.text_len > 0, let textPtr = textStruct.text else { return nil }
            let data = Data(bytes: textPtr, count: Int(textStruct.text_len))
            return String(data: data, encoding: .utf8)
        }

        /// Non-blocking variant of `readBottomRows` for background scanners.
        /// When the terminal mutex is contended (heavy output being parsed),
        /// sets `busy` and returns nil immediately instead of parking the
        /// main thread behind the parse.
        @MainActor
        static func tryReadBottomRows(
            _ rows: Int,
            gridRows: Int,
            cols: Int,
            surface: ghostty_surface_t,
            busy: inout Bool
        ) -> String? {
            busy = false
            guard rows > 0, gridRows > 0, cols > 0 else { return nil }
            let count = min(rows, gridRows)

            var selection = ghostty_selection_s()
            selection.top_left.tag = GHOSTTY_POINT_ACTIVE
            selection.top_left.coord = GHOSTTY_POINT_COORD_EXACT
            selection.top_left.x = 0
            selection.top_left.y = UInt32(gridRows - count)
            selection.bottom_right.tag = GHOSTTY_POINT_ACTIVE
            selection.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
            selection.bottom_right.x = UInt32(max(0, cols - 1))
            selection.bottom_right.y = UInt32(max(0, gridRows - 1))
            selection.rectangle = true

            var textStruct = ghostty_text_s()
            guard ghostty_surface_try_read_text(surface, selection, &textStruct, &busy) else {
                return nil
            }
            defer { ghostty_surface_free_text(surface, &textStruct) }

            guard textStruct.text_len > 0, let textPtr = textStruct.text else { return nil }
            let data = Data(bytes: textPtr, count: Int(textStruct.text_len))
            return String(data: data, encoding: .utf8)
        }
    }
}
