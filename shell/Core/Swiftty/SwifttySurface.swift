//
//  SwifttySurface.swift
//  shell
//
//  Wrapper around swiftty_surface_t for iOS
//

import Foundation
import SwifttyKit

extension Swiftty {
    /// Static helpers for reading text out of a `swiftty_surface_t`.
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
            surface: swiftty_surface_t
        ) -> String? {
            guard rows > 0, cols > 0 else { return nil }

            var selection = swiftty_selection_s()
            selection.top_left.tag = SWIFTTY_POINT_VIEWPORT
            selection.top_left.coord = SWIFTTY_POINT_COORD_EXACT
            selection.top_left.x = 0
            selection.top_left.y = 0
            selection.bottom_right.tag = SWIFTTY_POINT_VIEWPORT
            selection.bottom_right.coord = SWIFTTY_POINT_COORD_EXACT
            selection.bottom_right.x = UInt32(max(0, cols - 1))
            selection.bottom_right.y = UInt32(max(0, rows - 1))
            selection.rectangle = true

            var textStruct = swiftty_text_s()
            guard swiftty_surface_read_text(surface, selection, &textStruct) else { return nil }
            defer { swiftty_surface_free_text(surface, &textStruct) }

            guard textStruct.text_len > 0, let textPtr = textStruct.text else { return nil }
            let data = Data(bytes: textPtr, count: Int(textStruct.text_len))
            return String(data: data, encoding: .utf8)
        }
    }
}
