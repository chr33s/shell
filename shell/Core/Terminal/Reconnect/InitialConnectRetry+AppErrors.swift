//
//  InitialConnectRetry+AppErrors.swift
//  shell
//
//  Extension layering app error types (HostKeyRejectedError, SSHError,
//  SSHJumpError) onto the shared `isPermanentConnectError` base.
//

import Foundation

extension InitialConnectRetry {

    /// App-side classifier: shared base + app-only error types.
    /// Use as `isPermanent: InitialConnectRetry.isPermanentConnectErrorApp`.
    static func isPermanentConnectErrorApp(_ error: Error) -> Bool {
        if isPermanentConnectError(error) { return true }

        // App-side host-key-rejection error (separate from Citadel's InvalidHostKey)
        if error is HostKeyRejectedError { return true }

        // Legacy-encrypted key with no local passphrase — retry can't help;
        // the user must unlock the key once in Settings → SSH Keys.
        if case SSHKeyManager.LoadError.legacyKeyNeedsUnlock = error { return true }

        if let ssh = error as? SSHError, ssh.isAuthenticationRelated { return true }

        if let jump = error as? SSHJumpError {
            // Exhaustive on purpose, with no `default`: both cases are permanent,
            // and a new one must be classified deliberately rather than inheriting
            // "retryable" by omission.
            switch jump {
            case .authenticationFailed, .hostKeyRejected:
                return true
            }
        }

        return false
    }
}
