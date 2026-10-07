// OSC 7501 program status, as SwifttyCore types (re-exported one by one, so
// the rest of SwifttyCore stays out of the host's namespace): Swiftty parses,
// validates and keeps the records; the host only reads them.
@_exported import enum SwifttyCore.ProgramStatusBlockedKind
@_exported import struct SwifttyCore.ProgramStatusRecord
@_exported import struct SwifttyCore.ProgramStatusSnapshot
@_exported import enum SwifttyCore.ProgramStatusState
import SwifttyCore

/// The surface's current records (a tmux pane's, for a pane surface). They
/// live in the terminal, not the surface: a new surface for the same tmux
/// pane reads the same records.
public func swiftty_surface_program_status(_ s: swiftty_surface_t?) -> ProgramStatusSnapshot {
    Surface.from(s)?.programStatus ?? .empty
}

/// For a host-fed surface: the program exited or its transport closed
/// without a final prompt. Drops transient (`working`, `blocked`, `idle`)
/// records, ordered with output already written to the slave fd.
public func swiftty_surface_program_exited(_ s: swiftty_surface_t?) {
    guard let surface = Surface.from(s), !surface.isTmuxPane else { return }
    surface.programExited()
}
