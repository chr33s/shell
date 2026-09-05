//
//  TerminalContainer.swift
//  shell
//
//  SwiftUI wrapper for TerminalView
//

import SwiftUI
import GhosttyKit
import os

struct TerminalContainer: UIViewRepresentable {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    let uuid: UUID
    let windowId: String
    let connectionConfig: ConnectionConfig
    let onAuthenticationRequired: (@MainActor @Sendable (SSHConfig) -> Void)?

    @Binding var isFocused: Bool

    init(uuid: UUID? = nil, windowId: String, isFocused: Binding<Bool> = .constant(true), connectionConfig: ConnectionConfig = .local(), onAuthenticationRequired: (@MainActor @Sendable (SSHConfig) -> Void)? = nil) {
        self.uuid = uuid ?? UUID()
        self.windowId = windowId
        self._isFocused = isFocused
        self.connectionConfig = connectionConfig
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    @MainActor
    func makeUIView(context: Context) -> Ghostty.TerminalScrollView {
        Ghostty.logger.info("TerminalContainer: makeUIView called")

        guard let app = ghosttyApp.app else {
            fatalError("Ghostty app not initialized")
        }

        // Create the terminal view
        Ghostty.logger.info("TerminalContainer: Creating TerminalView")
        let terminalView = Ghostty.TerminalView(app, ghosttyApp: ghosttyApp, uuid: uuid, connectionConfig: connectionConfig, windowId: windowId)
        terminalView.setWindowActive(isFocused)

        // Set authentication callback
        let authCallback = onAuthenticationRequired
        terminalView.onAuthenticationRequired = authCallback

        // Set initial focus
        terminalView.focusDidChange(isFocused)

        // Wrap in scroll view for native iOS scrollback
        Ghostty.logger.info("TerminalContainer: Creating TerminalScrollView wrapper")
        let scrollView = Ghostty.TerminalScrollView(terminalView: terminalView)

        Ghostty.logger.info("TerminalContainer: Returning TerminalScrollView")
        return scrollView
    }

    func updateUIView(_ uiView: Ghostty.TerminalScrollView, context: Context) {
        // Update focus state on the wrapped terminal view
        uiView.terminalView.focusDidChange(isFocused)
        uiView.terminalView.setWindowActive(isFocused)
    }

    static func dismantleUIView(_ uiView: Ghostty.TerminalScrollView, coordinator: ()) {
        // Cleanup is handled in TerminalView.deinit
    }
}
