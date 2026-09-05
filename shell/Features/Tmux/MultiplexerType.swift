//
//  MultiplexerType.swift
//  shell
//
//  The one multiplexer this fork knows about. Kept as an enum so the
//  raw-multiplexer binding on a terminal surface stays explicit about what
//  owns the screen.
//

import Foundation

enum MultiplexerType: String, Sendable, Equatable, Hashable {
    case tmux

    /// Whether the multiplexer, rather than its inner program, owns the screen.
    var ownsAlternateScreen: Bool { true }

    /// SF Symbol representing this multiplexer.
    var iconName: String { "rectangle.split.2x1" }
}
