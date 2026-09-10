//
//  TerminalReadinessGate.swift
//  shell
//
//  One-shot terminal-readiness rendezvous (spec.connectivity.md §9.5).
//
//  Recovery must not report a restored session when all it has is a TCP
//  connection and a completed SSH handshake (CON-03). For an ordinary SSH
//  session the real evidence is PTY allocation plus an accepted shell/exec
//  request with I/O handlers installed — which the session signals through
//  `onReady`. A quiet shell need not emit a single byte, so waiting for
//  output would be wrong, and parsing the 8-bit stream for a prompt-shaped
//  string is explicitly forbidden.
//
//  This gate turns that callback into something a recovery attempt can await,
//  with a real deadline and exactly-once resolution.
//

import Foundation

@MainActor
final class TerminalReadinessGate {

    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var settled = false

    /// Resolve the gate. Later calls are ignored: readiness and session-end
    /// can race, and whichever lands first is the outcome.
    func resolve(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            // The signal beat the waiter (a session that is ready inside
            // `start()`). Hold the result so `wait` returns immediately.
            pendingResult = result
        }
    }

    /// Wait for readiness, up to `seconds`.
    ///
    /// Expiry throws rather than resolving successfully. A timer that
    /// declares success is exactly the shortcut §9.5 rules out.
    func wait(seconds: TimeInterval) async throws {
        if let pendingResult {
            self.pendingResult = nil
            try pendingResult.get()
            return
        }

        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            self?.resolve(.failure(TerminalSessionController.ReconnectionError.readinessTimedOut))
        }
        defer { timeout.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pendingResult)
                    return
                }
                if settled {
                    // Settled with no stored result: treat as cancelled
                    // rather than leaving the caller suspended.
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(.failure(CancellationError()))
            }
        }
    }
}
