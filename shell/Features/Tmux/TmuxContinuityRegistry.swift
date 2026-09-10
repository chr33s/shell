//
//  TmuxContinuityRegistry.swift
//  shell
//
//  Device-local record of which tmux session each connection was attached to,
//  and the evidence that proves it is that same session later
//  (spec.connectivity.md §9.1, §14).
//
//  `TmuxGatewaySessionStore` already remembers a session *name* per
//  connection. A name is a fine convenience for choosing what to attach to on
//  a fresh connect, and useless as recovery identity: tmux lets a user rename
//  a session at any moment, and a restarted server happily hands out `$0`
//  again to something else entirely. This registry holds the fields that can
//  actually distinguish those cases.
//
//  Everything here is in-memory plus the device-local descriptor store.
//  Nothing is synced (CON-10).
//

import Foundation
import os

@MainActor
final class TmuxContinuityRegistry {

    private nonisolated static let logger = Logger(
        subsystem: "dev.chr33s.shell", category: "TmuxContinuity")

    static let shared = TmuxContinuityRegistry()

    /// Keyed by `TmuxGatewaySessionStore.connectionKey` — "user@host:port".
    private var evidenceByConnection: [String: TmuxContinuityEvidence] = [:]

    func record(_ evidence: TmuxContinuityEvidence, forConnection key: String) {
        guard evidence.isSufficientForContinuity else {
            // Partial evidence is worse than none: it would let a recovery
            // claim continuity it cannot prove. Drop it.
            Self.logger.debug("Ignoring insufficient tmux continuity evidence")
            return
        }
        evidenceByConnection[key] = evidence
    }

    func evidence(forConnection key: String) -> TmuxContinuityEvidence? {
        evidenceByConnection[key]
    }

    func forget(connection key: String) {
        evidenceByConnection.removeValue(forKey: key)
        verificationHandlers.removeValue(forKey: key)
    }

    /// Handlers waiting to hear whether a reattachment landed on the same
    /// session. Registered by the recovery controller, invoked by the gateway
    /// once the server has answered.
    private var verificationHandlers: [String: (TmuxContinuityVerdict) -> Void] = [:]

    func setVerificationHandler(
        forConnection key: String,
        _ handler: @escaping (TmuxContinuityVerdict) -> Void
    ) {
        verificationHandlers[key] = handler
    }

    /// Report the verdict for a reattachment. Returns whether anyone was
    /// waiting — a fresh connect has no recovery to report to.
    @discardableResult
    func reportVerification(_ verdict: TmuxContinuityVerdict, forConnection key: String) -> Bool {
        guard let handler = verificationHandlers[key] else { return false }
        handler(verdict)
        return true
    }

    /// Compare freshly-discovered evidence against what was stored for this
    /// connection, without adopting it. The caller decides what to do with a
    /// mismatch — this type never silently substitutes one session for another.
    func verify(
        discovered: TmuxContinuityEvidence?,
        forConnection key: String
    ) -> TmuxContinuityVerdict {
        TmuxRecoveryIdentity.verify(stored: evidenceByConnection[key], discovered: discovered)
    }
}

extension TmuxController {

    /// Ask the server for this gateway's continuity evidence and record it.
    ///
    /// One round trip on the existing control channel. Called after an attach
    /// or a session switch, so that if the connection drops a moment later
    /// there is something to prove identity with — evidence gathered *after*
    /// the drop would be evidence about whatever is there now, which is
    /// exactly the question being asked.
    func captureContinuityEvidence() async {
        guard let connectionKey else { return }
        guard let sessionID = currentSessionId else { return }

        do {
            let body = try await sendCommandWithReply(
                TmuxRecoveryIdentity.continuityQuery(sessionID: sessionID),
                timeout: .seconds(4))
            guard var evidence = TmuxRecoveryIdentity.parseContinuity(body) else { return }
            // Trust our own view of which session this gateway is attached to
            // over a format field, in case the server answered for another.
            guard evidence.sessionID == sessionID else { return }
            evidence.windowIDs = projectedWindowIDs()

            // Compare against what was stored *before* recording the new
            // evidence, or the comparison is against itself. A recovery in
            // progress is waiting on exactly this answer; a fresh connect has
            // nobody listening and simply records.
            let verdict = TmuxContinuityRegistry.shared.verify(
                discovered: evidence, forConnection: connectionKey)
            TmuxContinuityRegistry.shared.record(evidence, forConnection: connectionKey)
            TmuxContinuityRegistry.shared.reportVerification(verdict, forConnection: connectionKey)
        } catch {
            // A server too old to answer simply leaves no evidence, and
            // recovery then asks the user to choose. That is the safe
            // fallback, not a reason to fabricate identity.
            Self.continuityLogger.debug(
                "tmux continuity evidence unavailable: \(error.localizedDescription)")
        }
    }

    /// Re-check identity after reattaching, before input is enabled.
    ///
    /// Discovery and attach are separate round trips, so a session can be
    /// killed and recreated between them. Authentication proves the host; it
    /// proves nothing about which tmux process survived (§9.1).
    func verifyContinuityAfterAttach() async -> TmuxContinuityVerdict {
        guard let connectionKey else { return .insufficientEvidence }
        guard let sessionID = currentSessionId else { return .sessionMissing }

        do {
            let body = try await sendCommandWithReply(
                TmuxRecoveryIdentity.continuityQuery(sessionID: sessionID),
                timeout: .seconds(4))
            let discovered = TmuxRecoveryIdentity.parseContinuity(body)
            return TmuxContinuityRegistry.shared.verify(
                discovered: discovered, forConnection: connectionKey)
        } catch {
            return .insufficientEvidence
        }
    }

    private nonisolated static let continuityLogger = Logger(
        subsystem: "dev.chr33s.shell", category: "TmuxContinuity")
}
