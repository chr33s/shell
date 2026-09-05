import Foundation
import NIOSSH
import NIOCore
import os.log

/// A single keyboard-interactive (RFC 4256) prompt to present to the user.
/// Value type so it is safe to hand across the NIO event-loop ↔ MainActor boundary.
struct KeyboardInteractivePrompt: Sendable, Hashable {
    let prompt: String
    /// Whether the typed response should be echoed. `false` for secrets
    /// (passwords, one-time codes); `true` for visible fields.
    let echo: Bool
}

/// Semantic classification of a no-echo keyboard-interactive prompt, derived
/// from the server-supplied prompt text, used to pick the right iOS AutoFill
/// content type. Visible (echo) prompts are not classified here.
enum KeyboardInteractiveSecretKind: Sendable {
    case password      // -> .textContentType(.password)
    case oneTimeCode   // -> .textContentType(.oneTimeCode)

    /// OTP-like phrases are checked FIRST (note "one-time password" contains
    /// "password"); otherwise password-like; otherwise default to `.password`
    /// so the OS password manager remains reachable for unrecognised secrets.
    static func classify(_ promptText: String) -> KeyboardInteractiveSecretKind {
        let t = promptText.lowercased()
        let otp = ["one-time", "one time", "onetime", "otp", "totp", "hotp",
                   "verification", "authenticator", "two-factor", "two factor",
                   "2fa", "token", "duo", "passcode", "yubikey", "security code"]
        if otp.contains(where: t.contains) { return .oneTimeCode }
        if t.contains("password") || t.contains("passphrase") { return .password }
        return .password
    }
}

/// One round of a keyboard-interactive challenge from the server.
/// Built on the event loop, consumed on the MainActor; strings are copied at
/// init to avoid any lifetime/bridging issues across the boundary.
struct KeyboardInteractiveChallenge: Sendable {
    /// A human label for the connection being authenticated (e.g. "user@host"
    /// or "[Jump Host] user@bastion"), used for the prompt UI title.
    let sessionName: String
    /// The SSH login username. Used as a hidden AutoFill anchor so the OS
    /// password manager can match the saved credential for a password prompt.
    let username: String
    /// The server-supplied challenge name (may be empty).
    let name: String
    /// The server-supplied instruction text (may be empty).
    let instruction: String
    /// The prompts to present, in order. May be empty (information-only round).
    let prompts: [KeyboardInteractivePrompt]
}

/// Thrown to abort keyboard-interactive auth when the user cancels.
struct KeyboardInteractiveCancelledError: Error, LocalizedError {
    var errorDescription: String? { "Keyboard-interactive authentication was cancelled" }
}

/// An auth delegate that wraps a primary "inner" offer delegate (key/password/
/// none) and additionally answers keyboard-interactive (RFC 4256) challenges.
///
/// Citadel's `.custom(_)` wraps a single delegate and forwards both
/// `nextAuthenticationType` and `respondToKeyboardInteractiveChallenge` to it,
/// so the keyboard-interactive responder must live on the same object that
/// makes the primary offer. This composing delegate is that object.
///
/// Offer ordering:
///  1. Forward to the inner delegate. While it has offers (e.g. a key, or a
///     password), use them.
///  2. Once the inner delegate is exhausted, offer keyboard-interactive once.
///     This covers "publickey + 2FA", PAM-password (server only advertises
///     keyboard-interactive), and the explicit keyboard-interactive method
///     (no inner delegate at all). The offer is proactive — it is not gated on
///     `availableMethods` because the client only learns a server's
///     keyboard-interactive support from a USERAUTH_FAILURE, and a server that
///     does not support it simply replies with another failure (harmless).
///
/// Marked `nonisolated` + `@unchecked Sendable` because NIO invokes it from the
/// event loop; all MainActor work is funnelled through `Task { @MainActor in }`,
/// mirroring ``SSHHostKeyDelegate``. There is no timeout coordinator: the active
/// Citadel path relies on its 5-minute login timeout, which covers human input.
nonisolated final class KeyboardInteractiveAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let sessionName: String
    private let inner: NIOSSHClientUserAuthenticationDelegate?
    private nonisolated(unsafe) let onChallenge: (KeyboardInteractiveChallenge) async -> [String]?

    /// One-shot password reused to auto-answer a single hidden prompt (OpenSSH
    /// parity for PAM-password servers). Consumed on first use, then nil so any
    /// further rounds (e.g. an OTP) always prompt the user.
    private nonisolated(unsafe) var autoAnswerPassword: String?
    private nonisolated(unsafe) var triedKeyboardInteractive = false

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHKbdInteractive")

    init(
        username: String,
        sessionName: String,
        inner: NIOSSHClientUserAuthenticationDelegate?,
        autoAnswerPassword: String? = nil,
        onChallenge: @escaping (KeyboardInteractiveChallenge) async -> [String]?
    ) {
        self.username = username
        self.sessionName = sessionName
        self.inner = inner
        self.autoAnswerPassword = autoAnswerPassword
        self.onChallenge = onChallenge
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard let inner = inner else {
            // Explicit keyboard-interactive: no primary method, offer it directly.
            offerKeyboardInteractiveOrFinish(promise: nextChallengePromise)
            return
        }

        let eventLoop = nextChallengePromise.futureResult.eventLoop
        let wrapper = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        wrapper.futureResult.whenComplete { [self] result in
            switch result {
            case .success(let offer):
                if let offer = offer {
                    // Inner delegate still has a method to try.
                    nextChallengePromise.succeed(offer)
                } else {
                    // Inner delegate exhausted — fall back to keyboard-interactive.
                    self.offerKeyboardInteractiveOrFinish(promise: nextChallengePromise)
                }
            case .failure(let error):
                // Inner delegate failed hard. Try keyboard-interactive once before
                // giving up, then propagate the original error.
                if !self.triedKeyboardInteractive {
                    self.offerKeyboardInteractiveOrFinish(promise: nextChallengePromise)
                } else {
                    nextChallengePromise.fail(error)
                }
            }
        }
        inner.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: wrapper)
    }

    func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        inner?.serverSignatureAlgorithmsReceived(algorithms)
    }

    private func offerKeyboardInteractiveOrFinish(promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !triedKeyboardInteractive else {
            // Already attempted; nothing left to offer.
            promise.succeed(nil)
            return
        }
        triedKeyboardInteractive = true
        Self.logger.info("Offering keyboard-interactive authentication")
        promise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .keyboardInteractive(.init())
        ))
    }

    func authenticationSucceededPartially() {
        // A prior method (e.g. the password) was accepted and the server now
        // requires a further factor. Drop the stored password so it is never
        // auto-submitted to the next keyboard-interactive prompt (e.g. an OTP).
        autoAnswerPassword = nil
    }

    func respondToKeyboardInteractiveChallenge(
        name: String,
        instruction: String,
        prompts: [NIOSSHKeyboardInteractivePrompt],
        responsePromise: EventLoopPromise<[String]>
    ) {
        // A zero-prompt INFO_REQUEST (RFC 4256) is an information-only round —
        // common in PAM right before success. Respond immediately with an empty
        // answer instead of surfacing a "no input required" prompt to the user.
        if prompts.isEmpty {
            responsePromise.succeed([])
            return
        }

        // Auto-answer OpenSSH-style: a single hidden prompt with a stored/typed
        // password. One-shot, so a later round (e.g. an OTP) still prompts.
        if let password = autoAnswerPassword, prompts.count == 1, prompts[0].echo == false {
            autoAnswerPassword = nil
            Self.logger.info("Auto-answering single hidden keyboard-interactive prompt with stored password")
            responsePromise.succeed([password])
            return
        }

        // Copy to Sendable value types before crossing to the MainActor.
        let mappedPrompts = prompts.map { KeyboardInteractivePrompt(prompt: String($0.prompt), echo: $0.echo) }
        let challenge = KeyboardInteractiveChallenge(
            sessionName: String(sessionName),
            username: String(username),
            name: String(name),
            instruction: String(instruction),
            prompts: mappedPrompts
        )
        let promptCount = mappedPrompts.count
        Self.logger.info("Presenting keyboard-interactive challenge with \(promptCount) prompt(s)")

        Task { @MainActor [self] in
            if let responses = await self.onChallenge(challenge) {
                responsePromise.succeed(responses)
            } else {
                // User cancelled — fail this method; auth then tries the next or fails.
                responsePromise.fail(KeyboardInteractiveCancelledError())
            }
        }
    }
}

/// A minimal offer-only delegate that proposes password authentication once.
///
/// `SSHConnectionHelper` previously used Citadel's `.passwordBased(...)` (a
/// `.user` offer), but Citadel only forwards keyboard-interactive challenges to
/// `.custom` delegates. Routing password auth through this delegate (wrapped in
/// ``KeyboardInteractiveAuthDelegate``) makes keyboard-interactive reachable for
/// PAM-password servers while preserving plain password auth.
nonisolated final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let password: String
    private nonisolated(unsafe) var tried = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !tried, availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil)
            return
        }
        tried = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .password(.init(password: password))
        ))
    }
}
