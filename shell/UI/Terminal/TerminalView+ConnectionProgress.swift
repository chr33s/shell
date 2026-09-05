//
//  TerminalView+ConnectionProgress.swift
//  shell
//
//  TerminalView's side of the connection-progress boundary. The presenter
//  (ConnectionProgressPresenter) owns the SpinnerAnimator and renders the
//  connect-time spinner / OSC 9;4 progress indicator through these two hooks.
//

import UIKit
import GhosttyKit

extension Ghostty.TerminalView: ConnectionProgressHost {

    func writeProgressOutput(_ string: String) {
        writeToGhostty(string: string)
    }

    var progressTerminalWidth: Int {
        Int(surfaceSize?.columns ?? 80)
    }
}
