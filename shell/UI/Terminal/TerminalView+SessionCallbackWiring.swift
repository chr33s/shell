//
//  TerminalView+SessionCallbackWiring.swift
//  shell
//
//  Small reusable helpers for the per-session-type callback wiring in
//  setupPTYAndShell.
//

import UIKit
import GhosttyKit

extension Ghostty.TerminalView {

    /// Wire the standard "display the error in the terminal" onError handler.
    /// The SSH path keeps its own onError (auth-failure detection / re-auth flow).
    func wireStandardSessionError(on session: some TerminalSession, prefix: String? = nil) {
        session.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleSessionError(error, prefix: prefix)
            }
        }
    }
}
