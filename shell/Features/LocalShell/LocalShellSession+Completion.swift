#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    // MARK: - Shared Host Tab Completion

    /// Handle tab completion for any SSH-family command using extracted destination.
    func handleHostTabCompletion(state: inout HostCompletionState, extraction: ExtractionResult) {
        // Only complete when cursor is on the destination
        guard extraction.context == .inDestination else {
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
            return
        }

        _ = state.handleTabTiming()

        // Get suggestions if cache is empty
        if state.suggestions.isEmpty {
            state.suggestions = QuickConnectSuggestionProvider.shared.getSuggestions(
                matching: extraction.completableText,
                mode: state.matchingMode
            )
            state.suggestionIndex = 0
        }

        guard let suggestion = state.nextSuggestion() else {
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
            return
        }

        lineEditor.setBuffer("\(extraction.bufferPrefix)\(suggestion.completionString)")
        clearGhostText()
        redrawLine()
    }

    /// Update ghost text for any SSH-family command using extracted destination.
    private func updateHostGhostText(extraction: ExtractionResult) {
        guard extraction.context == .inDestination,
              !extraction.completableText.isEmpty else {
            currentGhostText = ""
            return
        }

        let suggestions = QuickConnectSuggestionProvider.shared.getSuggestions(
            matching: extraction.completableText,
            mode: .prefix
        )

        guard let firstSuggestion = suggestions.first else {
            currentGhostText = ""
            return
        }

        let completion = firstSuggestion.completionString
        let lowerCompletion = completion.lowercased()
        let lowerInput = extraction.completableText.lowercased()

        if lowerCompletion.hasPrefix(lowerInput) {
            let suffixStart = completion.index(completion.startIndex, offsetBy: extraction.completableText.count)
            currentGhostText = String(completion[suffixStart...])
        } else {
            currentGhostText = ""
        }
    }

    // MARK: - Command-specific entry points (tab completion)

    /// Handle tab completion for SSH commands
    func handleSSHTabCompletion() {
        let extraction = CommandArgumentExtractor.extractDestination(
            buffer: lineEditor.buffer, commandLength: 4, flagSpec: .ssh
        )
        handleHostTabCompletion(state: &sshCompletion, extraction: extraction)
    }

    // MARK: - Ghost Text

    /// Update ghost text for SSH, SCP, SFTP, Mosh, Trzsz, or ssh-copy-id commands.
    /// This is the main entry point - routes to appropriate handler.
    func updateGhostText() {
        let buffer = lineEditor.buffer
        let lowerBuffer = buffer.lowercased()

        // Don't show ghost text if cursor is not at end
        guard lineEditor.cursorPosition == buffer.count else {
            currentGhostText = ""
            return
        }

        if lowerBuffer.hasPrefix("ssh ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 4, flagSpec: .ssh
            ))
        } else {
            // Just the command name without space, or an unrelated command.
            currentGhostText = ""
        }
    }

    /// Clear ghost text (called when accepting completion or on certain actions)
    func clearGhostText() {
        currentGhostText = ""
    }

}

#endif // !targetEnvironment(macCatalyst)
