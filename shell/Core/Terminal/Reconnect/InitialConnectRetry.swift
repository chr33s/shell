//
//  InitialConnectRetry.swift
//  shell
//
//  Bounded exponential-backoff retry for the connection-establishment phase
//  of SSH bootstraps. Used by `CitadelSSHSession`'s initial connect.
//
//  Distinct from ReconnectionManager (which handles post-connect drops with
//  a different schedule).
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOSSH
import OSLog

enum InitialConnectRetry {

    private nonisolated static let logger = Logger(
        subsystem: "dev.chr33s.shell",
        category: "InitialConnectRetry"
    )

    /// Per-attempt policy. The helper iterates `attempts` in order: sleeps
    /// `backoffBefore` (zero for the first attempt), then runs the operation
    /// with `timeout` available via the closure parameter so the call site
    /// can pass it through to Citadel's `loginTimeout` (which is `TimeAmount`).
    struct AttemptPolicy: Sendable {
        var timeout: TimeAmount
        var backoffBefore: TimeAmount
    }

    struct Config: Sendable {
        var attempts: [AttemptPolicy]

        /// Aggressive ramp suitable for non-interactive bootstraps where the
        /// per-attempt timeout doesn't include any UI wait time (no host-key
        /// approval prompt, no biometric unlock).
        ///
        /// 9 attempts spread across ~5 minutes. Per-attempt loginTimeout
        /// ramps 3s → 6s → 12s → 20s → 30s, then plateaus. Backoff between
        /// attempts ramps 1s → 2s → 4s → 8s → 15s → 30s, then plateaus.
        /// Healthy networks succeed on attempt 1 in ~3s; degraded networks
        /// have ~5min to recover before we give up.
        ///
        /// Cumulative deadline (timeout + backoff, seconds):
        ///   1:   3   2:  10   3:  24   4:  48   5:  86
        ///   6: 131   7: 191   8: 251   9: 311
        nonisolated static let `default` = Config(attempts: [
            AttemptPolicy(timeout: .seconds( 3), backoffBefore: .zero),
            AttemptPolicy(timeout: .seconds( 6), backoffBefore: .seconds( 1)),
            AttemptPolicy(timeout: .seconds(12), backoffBefore: .seconds( 2)),
            AttemptPolicy(timeout: .seconds(20), backoffBefore: .seconds( 4)),
            AttemptPolicy(timeout: .seconds(30), backoffBefore: .seconds( 8)),
            AttemptPolicy(timeout: .seconds(30), backoffBefore: .seconds(15)),
            AttemptPolicy(timeout: .seconds(30), backoffBefore: .seconds(30)),
            AttemptPolicy(timeout: .seconds(30), backoffBefore: .seconds(30)),
            AttemptPolicy(timeout: .seconds(30), backoffBefore: .seconds(30)),
        ])

        /// Conservative ramp for app-side interactive connects. Used by
        /// `CitadelSSHSession`.
        ///
        /// These callers hand the per-attempt `timeout` ONLY to the TCP
        /// connect cap (`min(timeout, tcpConnectTimeoutCap)`) and use it for
        /// retry cadence — NOT as Citadel's `loginTimeout`. The login phase
        /// uses the fixed, generous `SSHTimeoutConfig.citadelLoginTimeout`
        /// (5 min), because that deadline is absolute and non-pausable and
        /// spans human interaction (host-key approval, biometric unlock, and
        /// keyboard-interactive OTP entry). Folding user think-time into the
        /// per-attempt timeout used to drop OTP prompts mid-entry.
        ///
        /// The ramp stays generous on attempt 1 so a transient TCP failure
        /// isn't retried over-eagerly, then backs off further if it persists.
        ///
        /// Cumulative deadline (timeout + backoff, seconds):
        ///   1:  30   2: 122   3: 307
        nonisolated static let interactive = Config(attempts: [
            AttemptPolicy(timeout: .seconds( 30), backoffBefore: .zero),
            AttemptPolicy(timeout: .seconds( 90), backoffBefore: .seconds(2)),
            AttemptPolicy(timeout: .seconds(180), backoffBefore: .seconds(5)),
        ])
    }

    /// Runs `operation` with retry on transient connection failures.
    ///
    /// - Parameters:
    ///   - config: Schedule of attempts (timeouts + backoffs).
    ///   - label: Short identifier used in logs (e.g. "ssh:host").
    ///     Helps distinguish concurrent retries.
    ///   - isPermanent: Decides whether an error is retryable. Returning
    ///     true rethrows immediately without further attempts.
    ///   - operation: The work to retry. Receives the 1-based attempt
    ///     number and the per-attempt timeout (in seconds) the caller
    ///     should plumb through to its connect API.
    /// - Returns: The successful operation result.
    /// - Throws: `CancellationError` immediately on cancellation; the
    ///   permanent error if `isPermanent` returns true; otherwise the
    ///   final attempt's error after the schedule is exhausted.
    static func run<T>(
        config: Config = .default,
        label: String,
        isPermanent: (Error) -> Bool,
        operation: (_ attempt: Int, _ timeout: TimeAmount) async throws -> T
    ) async throws -> T {
        precondition(!config.attempts.isEmpty, "InitialConnectRetry.Config must have at least one attempt")

        let total = config.attempts.count
        var lastError: Error?

        for (index, policy) in config.attempts.enumerated() {
            try Task.checkCancellation()

            if policy.backoffBefore.nanoseconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(policy.backoffBefore.nanoseconds))
            }

            let attempt = index + 1

            do {
                return try await operation(attempt, policy.timeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isPermanent(error) {
                    let desc = error.localizedDescription
                    logger.info("\(label): permanent failure on attempt \(attempt)/\(total), not retrying: \(desc)")
                    throw error
                }
                let desc = error.localizedDescription
                let timeoutSec = Double(policy.timeout.nanoseconds) / 1_000_000_000
                logger.info("\(label): attempt \(attempt)/\(total) failed (timeout=\(timeoutSec)s): \(desc)")
                lastError = error
            }
        }

        // Schedule exhausted. lastError is non-nil here because we returned on
        // success and threw on permanent — every iteration that didn't return
        // populated lastError.
        throw lastError ?? CancellationError()
    }

    // MARK: - Permanent-failure classifier (shared base)

    /// Decides whether an error is permanent (do not retry).
    /// Covers only Citadel/NIO error types; `isPermanentConnectErrorApp`
    /// layers the app's own types (HostKeyRejectedError, SSHError,
    /// SSHJumpError) on top of this base.
    nonisolated static func isPermanentConnectError(_ error: Error) -> Bool {
        if error is CancellationError { return true }

        // Citadel raw auth errors (thrown before any app-level categorizeError)
        if let e = error as? SSHClientError {
            switch e {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication,
                 .unsupportedKeyboardInteractiveAuthentication:
                return true
            default:
                break
            }
        }

        // Citadel-level host key rejection (InvalidHostKey is from Citadel).
        // The app's own HostKeyRejectedError is added in the app-only
        // classifier extension.
        if error is InvalidHostKey { return true }

        // Everything else (NIOConnectionError, ChannelError, CitadelError.loginTimeout,
        // generic NIOSSHError) is transient and gets retried.
        return false
    }
}
