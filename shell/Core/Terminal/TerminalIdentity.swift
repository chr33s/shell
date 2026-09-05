//
//  TerminalIdentity.swift
//
//  Product identity advertised to local shells and remote hosts.
//

import Foundation

/// Identifies the terminal as shell via `LC_TERMINAL` / `LC_TERMINAL_VERSION`.
///
/// The `LC_*` namespace is the only one that crosses SSH without server-side setup:
/// stock `ssh_config` ships `SendEnv LANG LC_*` and stock `sshd_config` ships
/// `AcceptEnv LANG LC_*`. `LC_TERMINAL` is not a real locale category, so `setlocale`
/// ignores it.
///
/// This is deliberately separate from `TERM_PROGRAM`, which stays `ghostty` because
/// tools sniff it for terminal capabilities, and from `TERM`, which is terminfo identity.
///
/// All members are `nonisolated` since they are read from NIO event loop contexts.
enum TerminalIdentity: Sendable {

    /// Value of `LC_TERMINAL`.
    nonisolated static let name = "shell"

    /// Value of `LC_TERMINAL_VERSION`: short version plus build, e.g. "1.0.10-126".
    nonisolated static let version: String = {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(short)-\(build)"
    }()

    /// Short version only, for `TERM_PROGRAM_VERSION` (convention is a bare version).
    nonisolated static let shortVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    /// Name/value pairs to forward to remote hosts.
    nonisolated static var forwardedVariables: [(name: String, value: String)] {
        [("LC_TERMINAL", name), ("LC_TERMINAL_VERSION", version)]
    }

    /// Variable carrying a per-pane token, so an out-of-band probe on the same
    /// connection can identify WHICH remote process belongs to this pane.
    ///
    /// Without it a plain SSH pane has no directory source at all unless the
    /// remote shell happens to emit OSC 7, which most do not. Rides the same
    /// `LC_*` namespace as `LC_TERMINAL` for the same reason: stock
    /// `ssh_config` sends `LC_*` and stock `sshd_config` accepts it. A server
    /// that strips it fails nothing, the pane simply shows no project.
    nonisolated static let paneTokenVariable = "LC_ROOTSHELL_PANE"

    /// `forwardedVariables` plus the pane token for a specific pane.
    nonisolated static func forwardedVariables(paneToken: String?) -> [(name: String, value: String)] {
        guard let paneToken, !paneToken.isEmpty else { return forwardedVariables }
        return forwardedVariables + [(paneTokenVariable, paneToken)]
    }
}
