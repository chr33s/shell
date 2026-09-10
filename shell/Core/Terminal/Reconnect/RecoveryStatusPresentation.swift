//
//  RecoveryStatusPresentation.swift
//  shell
//
//  Maps recovery state onto the native status strip's copy and actions
//  (spec.connectivity.md §12).
//
//  This is a pure value mapping with no SwiftUI import, so the wording rules
//  the spec is specific about are unit-testable:
//
//   * age is reported as "Last verified activity … ago", never as a claim
//     about how long the *server* has been offline — Shell does not know that;
//   * a new shell is never labelled "Resume session";
//   * an uncertain command says so plainly rather than implying it did or did
//     not run.
//
//  Nothing here writes to the terminal stream. Recovery spinners, countdowns,
//  success lines, and errors stay out of both the normal and alternate screen.
//

import Foundation

/// One action offered alongside a recovery status.
enum RecoveryStatusAction: String, Equatable, Sendable {
    case retryNow
    case stopRecovery
    case selectSession
    case openNewShell
    case authenticate
    case reviewDraft
    case dismiss

    var title: String {
        switch self {
        case .retryNow:
            return String(localized: "Retry Now", comment: "Recovery action: retry immediately")
        case .stopRecovery:
            return String(localized: "Stop Recovery", comment: "Recovery action: stop reconnecting")
        case .selectSession:
            return String(localized: "Choose Session", comment: "Recovery action: pick a tmux session")
        case .openNewShell:
            // Deliberately NOT "Resume session": a new transport for a plain
            // SSH connection is a new shell, not the old one.
            return String(localized: "Open New Shell", comment: "Recovery action: start a fresh remote shell")
        case .authenticate:
            return String(localized: "Authenticate", comment: "Recovery action: complete authentication")
        case .reviewDraft:
            return String(localized: "Review Draft", comment: "Recovery action: review composed input")
        case .dismiss:
            return String(localized: "Dismiss", comment: "Recovery action: dismiss the status strip")
        }
    }
}

/// Severity, used only for tinting and for deciding what to announce.
enum RecoveryStatusSeverity: String, Equatable, Sendable {
    case informational
    case warning
    case attention
}

/// Everything the status strip needs to render.
struct RecoveryStatusPresentation: Equatable, Sendable {
    var title: String
    /// Secondary line. `nil` when there is nothing honest to add.
    var detail: String?
    var actions: [RecoveryStatusAction]
    var severity: RecoveryStatusSeverity
    /// Whether a determinate/indeterminate progress affordance belongs here.
    var showsActivity: Bool
    /// Whether this transition is worth an accessibility announcement. Only
    /// major changes announce; countdown ticks never do.
    var announces: Bool
    /// Whether the retained terminal contents are stale.
    var isStale: Bool

    /// Build the presentation for a state.
    ///
    /// - Parameters:
    ///   - lastVerifiedActivityAge: seconds since the last confirmed activity,
    ///     or `nil` when nothing has been verified yet.
    ///   - retrySecondsRemaining: seconds until the scheduled attempt.
    ///   - sessionName: the tmux session being reattached, for display only.
    ///   - hopDescription: which hop is prompting, e.g. "jump host bastion.example".
    ///   - isInCooldown: the rapid burst is spent and attempts continue at the
    ///     slower rate. Still recovering — not a failure.
    static func make(
        for state: RecoveryState,
        intent: RecoveryIntent,
        isStale: Bool = false,
        lastVerifiedActivityAge: TimeInterval? = nil,
        retrySecondsRemaining: TimeInterval? = nil,
        sessionName: String? = nil,
        hopDescription: String? = nil,
        isInCooldown: Bool = false
    ) -> RecoveryStatusPresentation? {
        switch state {
        case .live:
            return nil

        case .suspect:
            return RecoveryStatusPresentation(
                title: String(localized: "Checking connection…", comment: "Recovery status: validating transport"),
                detail: activityDetail(lastVerifiedActivityAge),
                // Input is gated while suspect, so the strip has to carry the
                // way out. A buttonless "Checking connection…" is a dead end
                // if nothing else resolves the doubt.
                actions: [.retryNow, .stopRecovery],
                severity: .informational,
                showsActivity: true,
                announces: false,
                isStale: isStale)

        case .waitingForConnectivity:
            return RecoveryStatusPresentation(
                title: String(localized: "Waiting for network", comment: "Recovery status: no usable route"),
                detail: activityDetail(lastVerifiedActivityAge),
                actions: [.retryNow, .stopRecovery],
                severity: .warning,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .waitingForRetry:
            let detail: String?
            if let retrySecondsRemaining {
                let seconds = max(0, Int(retrySecondsRemaining.rounded(.up)))
                detail = String(
                    localized: "Retrying in \(seconds)s",
                    comment: "Recovery status: countdown to next attempt")
            } else {
                detail = activityDetail(lastVerifiedActivityAge)
            }
            let title = isInCooldown
                ? String(localized: "Still trying to reconnect",
                         comment: "Recovery status: retrying at the slower cooldown rate")
                : String(localized: "Reconnecting", comment: "Recovery status: scheduled retry")
            return RecoveryStatusPresentation(
                title: title,
                detail: detail,
                actions: [.retryNow, .stopRecovery],
                severity: .warning,
                showsActivity: false,
                // The countdown updates every tick; announcing each one would
                // make VoiceOver unusable.
                announces: false,
                isStale: isStale)

        case .recovering(let stage):
            return presentation(for: stage, intent: intent, sessionName: sessionName,
                                hopDescription: hopDescription, isStale: isStale)

        case .awaitingUser(let reason):
            return presentation(for: reason, intent: intent, hopDescription: hopDescription, isStale: isStale)

        case .suspended:
            // No animated polling continues while suspended, and nothing is
            // announced: the app is not on screen.
            return RecoveryStatusPresentation(
                title: String(localized: "Paused", comment: "Recovery status: app suspended"),
                detail: nil,
                actions: [],
                severity: .informational,
                showsActivity: false,
                announces: false,
                isStale: isStale)

        case .stopped:
            return RecoveryStatusPresentation(
                title: String(localized: "Recovery stopped", comment: "Recovery status: user stopped"),
                detail: nil,
                actions: [.retryNow, .dismiss],
                severity: .informational,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .exited:
            return nil
        }
    }

    private static func presentation(
        for stage: RecoveryStage,
        intent: RecoveryIntent,
        sessionName: String?,
        hopDescription: String?,
        isStale: Bool
    ) -> RecoveryStatusPresentation {
        switch stage {
        case .connecting:
            return RecoveryStatusPresentation(
                title: String(localized: "Connecting…", comment: "Recovery status: dialing"),
                detail: hopDescription,
                actions: [.stopRecovery],
                severity: .informational,
                showsActivity: true,
                announces: true,
                isStale: isStale)

        case .authenticating:
            return RecoveryStatusPresentation(
                title: String(localized: "Authentication required", comment: "Recovery status: auth"),
                // Naming the hop matters: a jump-host prompt must not look
                // like a destination prompt.
                detail: hopDescription,
                actions: [.authenticate, .stopRecovery],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .attaching:
            let title: String
            if intent == .attachExistingTmux, let sessionName {
                title = String(
                    localized: "Reattaching to session \(sessionName)",
                    comment: "Recovery status: reattaching to a named tmux session")
            } else {
                title = String(localized: "Attaching…", comment: "Recovery status: attaching")
            }
            return RecoveryStatusPresentation(
                title: title,
                detail: nil,
                actions: [.stopRecovery],
                severity: .informational,
                showsActivity: true,
                announces: true,
                isStale: isStale)

        case .synchronizing:
            return RecoveryStatusPresentation(
                title: String(localized: "Restoring terminal state…", comment: "Recovery status: syncing panes"),
                detail: nil,
                actions: [.stopRecovery],
                severity: .informational,
                showsActivity: true,
                announces: true,
                isStale: isStale)
        }
    }

    private static func presentation(
        for reason: RecoveryAttentionReason,
        intent: RecoveryIntent,
        hopDescription: String?,
        isStale: Bool
    ) -> RecoveryStatusPresentation {
        switch reason {
        case .tmuxSessionMissing, .tmuxIdentityAmbiguous:
            return RecoveryStatusPresentation(
                title: String(
                    localized: "The previous session is unavailable",
                    comment: "Recovery status: tmux session cannot be verified"),
                detail: String(
                    localized: "Choose a session to attach to, or open a new shell.",
                    comment: "Recovery detail: explicit selection required"),
                actions: [.selectSession, .openNewShell],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .commandOutcomeUnknown:
            return RecoveryStatusPresentation(
                title: String(
                    localized: "Connection lost. Command outcome unknown.",
                    comment: "Recovery status: one-shot command dispatch uncertain"),
                detail: String(
                    localized: "The command was not run again.",
                    comment: "Recovery detail: no automatic re-dispatch"),
                actions: [.dismiss],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .hostTrustRejected:
            return RecoveryStatusPresentation(
                title: String(localized: "Host key changed", comment: "Recovery status: host trust"),
                detail: hopDescription,
                actions: [.dismiss],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .credentialUnavailable:
            return RecoveryStatusPresentation(
                title: String(localized: "Credentials unavailable", comment: "Recovery status: no usable credential"),
                detail: hopDescription,
                actions: [.authenticate, .stopRecovery],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .authenticationCancelled:
            return RecoveryStatusPresentation(
                title: String(localized: "Authentication required", comment: "Recovery status: auth cancelled"),
                detail: hopDescription,
                actions: [.authenticate, .stopRecovery],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .unsupportedRecovery, .protocolIncompatible:
            return RecoveryStatusPresentation(
                title: String(
                    localized: "This session can't be restored",
                    comment: "Recovery status: unsupported"),
                detail: intent.promisesSessionContinuity ? nil : String(
                    localized: "Session-preserving recovery requires tmux.",
                    comment: "Recovery detail: plain SSH limitation"),
                actions: [.openNewShell, .dismiss],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .burstExhausted:
            return RecoveryStatusPresentation(
                title: String(localized: "Still trying to reconnect", comment: "Recovery status: cooldown"),
                detail: String(
                    localized: "Attempts continue at a slower rate.",
                    comment: "Recovery detail: cooldown pace"),
                actions: [.retryNow, .stopRecovery],
                severity: .warning,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .roundTripUnverified:
            return RecoveryStatusPresentation(
                title: String(
                    localized: "Connection not responding",
                    comment: "Recovery status: keepalive went unanswered"),
                detail: String(
                    localized: "The last screen is kept. Session-preserving recovery requires tmux.",
                    comment: "Recovery detail: plain SSH cannot resume"),
                // Never "Resume session": a replacement transport for a plain
                // shell is a new shell (§9.3).
                actions: [.retryNow, .openNewShell, .stopRecovery],
                severity: .attention,
                showsActivity: false,
                announces: true,
                isStale: isStale)

        case .autoReconnectDisabled:
            return RecoveryStatusPresentation(
                title: String(localized: "Disconnected", comment: "Recovery status: auto-reconnect off"),
                detail: String(
                    localized: "Auto Reconnect is off.",
                    comment: "Recovery detail: master gate disabled"),
                actions: [.retryNow, .openNewShell],
                severity: .warning,
                showsActivity: false,
                announces: true,
                isStale: isStale)
        }
    }

    /// "Last verified activity … ago" — a statement about what Shell observed,
    /// never a claim about the server's state.
    private static func activityDetail(_ age: TimeInterval?) -> String? {
        guard let age, age >= 0 else { return nil }
        let formatted = formatAge(age)
        return String(
            localized: "Last verified activity \(formatted) ago",
            comment: "Recovery detail: age of last confirmed activity")
    }

    static func formatAge(_ age: TimeInterval) -> String {
        let seconds = Int(age.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
