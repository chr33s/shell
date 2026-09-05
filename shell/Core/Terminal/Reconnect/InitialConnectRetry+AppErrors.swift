//
//  InitialConnectRetry+AppErrors.swift
//  shell
//
//  Main-app-only extension layering app error types (SSHError, SSHJumpError,
//  onto the shared `isPermanentConnectError` base. Lives in the
//  main app target only — the VPN extension uses the shared base classifier
//  directly because it doesn't see these types.
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
            switch jump {
            case .authenticationFailed, .hostKeyRejected:
                return true
            default:
                return false
            }
        }

        return false
    }
}
