//
//  GhosttySurface.swift
//  shell
//
//  Wrapper around ghostty_surface_t for iOS
//

import Foundation
import GhosttyKit

extension Ghostty {
    /// Static helpers for reading text out of a `ghostty_surface_t`.
    ///
    /// Nothing wraps a surface in an instance of this type today. If that
    /// changes, follow the same discipline as every other free path: drop the
    /// surface from the registry first so it can't keep taking config pushes,
    /// then free on the API queue so the free can't overlap one.
    final class Surface: Sendable {
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
    }
}
