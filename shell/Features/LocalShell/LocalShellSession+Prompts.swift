#if !targetEnvironment(macCatalyst)

import Foundation
import Citadel

extension LocalShellSession {
    // MARK: - Password Prompts

    /// Handle password input character (no echo)
    func handlePasswordInput(_ char: Character) {
        guard case .passwordPrompt(let partialConfig) = sessionMode else { return }

        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            let password = passwordBuffer
            passwordBuffer = ""

            // An empty entry is not a credential: never attempt an empty password.
            // Matches the `disabled(password.isEmpty)` invariant the SwiftUI
            // surfaces enforce (PasswordPromptSheet, ReconnectPromptCard) — the
            // prompt simply stays up. This also absorbs the LF of a CRLF pair on
            // the paths below that stay in `.passwordPrompt`.
            guard !password.isEmpty else { return }

            onOutput?(normalizeLineEndings("\n"))

            // Both hops need a secret: the bastion was asked first, now re-enter
            // the SAME prompt for the target. A re-entry of the existing resume
            // path, not a second one. The bastion password rides along in memory
            // on the partial config and is dropped if the user cancels.
            if partialConfig.passwordSubject == .jumpHost, partialConfig.targetAuthMethod == nil {
                var next = partialConfig
                next.passwordSubject = .target
                if var jump = next.jumpHost {
                    jump.authMethod = .password(password)
                    next.jumpHost = jump
                }
                beginPasswordPrompt(.passwordPrompt(next))
                return
            }

            // Immediately switch to connecting mode to prevent double-trigger from CRLF
            sessionMode = .sshSession

            // Build full config with password and start session
            let config = partialConfig.toSSHConfig(password: password)

            // Store password for potential saving after successful connection,
            // keyed by the hop that was actually asked. A bastion password is a
            // row of its own — never merged into the target's entry.
            switch partialConfig.passwordSubject {
            case .target:
                pendingPasswordToSave = (host: partialConfig.host, port: partialConfig.port,
                                         username: partialConfig.username, password: password)
            case .jumpHost:
                if let jump = partialConfig.jumpHost {
                    pendingPasswordToSave = (host: jump.host, port: jump.port,
                                             username: jump.username, password: password)
                }
            }

            Task { @MainActor in
                launchEmbeddedSSHSession(config: config)
            }

        case 0x7F, 0x08:  // Backspace
            if !passwordBuffer.isEmpty {
                passwordBuffer.removeLast()
            }

        case 0x03:  // Ctrl-C - cancel
            passwordBuffer = ""
            let refusal = Self.jumpHostPasswordRefusal(for: partialConfig)
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            if let refusal {
                onOutput?(normalizeLineEndings(refusal + "\n"))
            }
            displayPrompt()

        case 0x15:  // Ctrl-U - clear line
            passwordBuffer = ""

        default:
            if char.isASCII && !char.isNewline {
                passwordBuffer.append(char)
                // No echo for password input
            }
        }
    }

    /// Refusal shown when the user cancels a bastion password prompt. Cancelling
    /// declines the connection outright — an empty password is never presented to
    /// the jump host — so say why, and where to configure a credential.
    /// Returns nil when the cancelled prompt was for the target host.
    static func jumpHostPasswordRefusal(
        for partialConfig: SSHCommandParser.PartialSSHConfig
    ) -> String? {
        guard partialConfig.passwordSubject == .jumpHost,
              let jump = partialConfig.jumpHost else { return nil }
        let jumpName = jump.displayName
        return String(
            localized: "ssh: no credentials for jump host \(jumpName); connection refused. Save a password for it, or set a default SSH identity in Settings → SSH → SSH Identities.",
            comment: "Shown when the user cancels the jump-host password prompt for `ssh -J`"
        )
    }

    /// Handle host key validation input
    func handleHostKeyInput(_ char: Character) {
        guard case .hostKeyPrompt(let continuation) = sessionMode else { return }

        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            onOutput?(normalizeLineEndings("\n"))
            let response = hostKeyResponseBuffer.lowercased().trimmingCharacters(in: .whitespaces)
            hostKeyResponseBuffer = ""

            let result: HostKeyValidationResult
            switch response {
            case "yes", "y":
                result = .accept
            case "once", "o":
                result = .acceptOnce
            default:
                result = .reject
            }

            sessionMode = .sshSession
            continuation.resume(returning: result)

        case 0x7F, 0x08:  // Backspace
            if !hostKeyResponseBuffer.isEmpty {
                hostKeyResponseBuffer.removeLast()
                // Erase character on screen
                onOutput?("\u{08} \u{08}")
            }

        case 0x03:  // Ctrl-C - reject
            hostKeyResponseBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            continuation.resume(returning: .reject)

        default:
            if char.isASCII && !char.isNewline {
                hostKeyResponseBuffer.append(char)
                // Echo the character
                onOutput?(String(char))
            }
        }
    }

    // MARK: - Save Password Prompt

    /// Prompt the user to save their password after a successful SSH connection
    private func promptToSavePassword(_ pending: (host: String, port: Int, username: String, password: String)) {
        sessionMode = .savePasswordPrompt(host: pending.host, port: pending.port,
                                          username: pending.username, password: pending.password)
        savePasswordResponseBuffer = ""
        let prompt = "\r\nSave password for \(pending.username)@\(pending.host)? (yes/no): "
        onOutput?(normalizeLineEndings(prompt))
    }

    /// Handle input during the save password prompt
    func handleSavePasswordInput(_ char: Character) {
        guard case .savePasswordPrompt(let host, let port, let username, let password) = sessionMode else { return }

        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter
            onOutput?(normalizeLineEndings("\n"))
            let response = savePasswordResponseBuffer.lowercased().trimmingCharacters(in: .whitespaces)
            savePasswordResponseBuffer = ""

            if response == "yes" || response == "y" {
                do {
                    try SSHPasswordManager.shared.savePassword(password, host: host, port: port, username: username)
                    onOutput?(normalizeLineEndings("Password saved.\r\n"))
                } catch {
                    onOutput?(normalizeLineEndings("Failed to save password: \(error.localizedDescription)\r\n"))
                }
            }

            sessionMode = .sshSession
            pendingPasswordToSave = nil

        case 0x7F, 0x08:  // Backspace
            if !savePasswordResponseBuffer.isEmpty {
                savePasswordResponseBuffer.removeLast()
                onOutput?("\u{08} \u{08}")
            }

        case 0x03:  // Ctrl-C - skip saving
            savePasswordResponseBuffer = ""
            sessionMode = .sshSession
            pendingPasswordToSave = nil
            onOutput?(normalizeLineEndings("^C\r\n"))

        default:
            if char.isASCII && !char.isNewline {
                savePasswordResponseBuffer.append(char)
                onOutput?(String(char))
            }
        }
    }

    /// Handle host key validation request inline
    func handleHostKeyValidation(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        // Clean up spinner before showing host key prompt
        cleanupInlineSpinner(emitIfEmpty: false)

        // Display the host key prompt
        let promptText: String
        if request.isKeyChanged {
            promptText = "\r\n\u{1B}[1;31mWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\u{1B}[0m\r\n\(request.message)\r\n\r\nAre you sure you want to continue connecting? (yes/no/once): "
        } else {
            promptText = "\r\n\(request.message)\r\n\r\nAre you sure you want to continue connecting? (yes/no/once): "
        }

        onOutput?(normalizeLineEndings(promptText))
        hostKeyResponseBuffer = ""

        // Wait for user input using a continuation
        return await withCheckedContinuation { continuation in
            sessionMode = .hostKeyPrompt(continuation)
        }
    }

    // MARK: - Keyboard-Interactive (RFC 4256) Prompt

    /// Forward a keyboard-interactive challenge from an embedded SSH-style session
    /// (or the rf browser) to the owning terminal view, which presents the shared
    /// SwiftUI prompt sheet — the same UI used for profile/connection-driven
    /// connections. Using the sheet (rather than an inline terminal prompt) keeps
    /// the local shell's `sessionMode` untouched while the embedded connect flow
    /// owns it, and unifies the experience across every launch path.
    func handleKeyboardInteractiveChallenge(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        guard let onChallenge = onKeyboardInteractiveChallenge else { return nil }
        return await onChallenge(challenge)
    }
}

#endif // !targetEnvironment(macCatalyst)
