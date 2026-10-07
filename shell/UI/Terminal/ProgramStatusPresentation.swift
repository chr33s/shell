//
//  ProgramStatusPresentation.swift
//  shell
//
//  What Shell shows for OSC 7501 program status. Swiftty parses the protocol
//  and owns the records (`ProgramStatusSnapshot`); this file only derives the
//  pane summary and tab attention from a snapshot plus the revision the user
//  has acknowledged. Nothing here parses OSC or changes the records.
//

import Foundation
import SwifttyKit

/// The pane summary of one terminal's program status.
struct ProgramStatusPresentation: Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case idle, working, done, error, blocked

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let severity: Severity
    let primaryRecordID: String
    let app: String?
    let title: String?
    let message: String?
    /// The primary record's own progress; never aggregated across records.
    let progress: UInt8?
    let blockedKind: ProgramStatusBlockedKind?
    /// Records that are not acknowledged results.
    let activeRecordCount: Int
    /// The primary record's revision.
    let revision: UInt64
    /// An unseen `done` or `error`.
    let requiresAcknowledgment: Bool

    /// The summary of `snapshot`, or nil when nothing is worth showing:
    /// `blocked` > unseen `error` > unseen `done` > `working` > `idle`, the
    /// most recently updated record first within a level. A `done` or
    /// `error` at or below `acknowledgedRevision` has been seen and drops
    /// out (it stays in Swiftty's records).
    static func reduce(_ snapshot: ProgramStatusSnapshot, acknowledgedRevision: UInt64) -> Self? {
        var best: (record: ProgramStatusRecord, rank: Int)?
        var active = 0
        for record in snapshot.records {
            guard let rank = rank(record, acknowledgedRevision: acknowledgedRevision) else { continue }
            active += 1
            if let current = best, current.rank > rank || (current.rank == rank && current.record.revision > record.revision) {
                continue
            }
            best = (record, rank)
        }
        guard let record = best?.record else { return nil }
        let severity: Severity = switch record.state {
        case .idle: .idle
        case .working: .working
        case .done: .done
        case .error: .error
        case .blocked: .blocked
        }
        return Self(
            severity: severity,
            primaryRecordID: record.id,
            app: snapshot.app(for: record.id).map(ProgramStatusText.sanitized),
            title: record.title.map(ProgramStatusText.sanitized),
            message: record.message.map(ProgramStatusText.sanitized),
            progress: record.progress,
            blockedKind: record.kind,
            activeRecordCount: active,
            revision: record.revision,
            requiresAcknowledgment: severity == .done || severity == .error
        )
    }

    /// Summary priority; nil for a seen result.
    private static func rank(_ record: ProgramStatusRecord, acknowledgedRevision: UInt64) -> Int? {
        let unseen = record.revision > acknowledgedRevision
        switch record.state {
        case .blocked: return 4
        case .error: return unseen ? 3 : nil
        case .done: return unseen ? 2 : nil
        case .working: return 1
        case .idle: return 0
        }
    }

    /// Whether `snapshot` holds a `done` or `error` newer than
    /// `acknowledgedRevision` (what acknowledging would change).
    static func hasUnseenResult(_ snapshot: ProgramStatusSnapshot, acknowledgedRevision: UInt64) -> Bool {
        snapshot.records.contains { ($0.state == .done || $0.state == .error) && $0.revision > acknowledgedRevision }
    }

    /// Tab-level attention for this pane; nil for `idle`.
    var attention: ProgramStatusAttention? {
        switch severity {
        case .idle: nil
        case .working: .working
        case .done: .done
        case .error: .error
        case .blocked: .blocked
        }
    }

    /// Short visible text, e.g. "Working — 42%", "Needs permission — Apply changes?".
    var label: String {
        if severity == .working, let progress {
            return "\(stateText) — \(progress)%"
        }
        return (title ?? message).map { "\(stateText) — \($0)" } ?? stateText
    }

    /// The state alone, e.g. "Needs permission".
    var stateText: String {
        switch severity {
        case .idle: String(localized: "Idle")
        case .working: String(localized: "Working")
        case .done: String(localized: "Done")
        case .error: String(localized: "Error")
        case .blocked:
            switch blockedKind {
            case .permission?: String(localized: "Needs permission")
            case .question?: String(localized: "Question")
            case .auth?: String(localized: "Authentication required")
            case nil: String(localized: "Blocked")
            }
        }
    }

    /// Spoken text, e.g. "Terminal status: working, 42 percent".
    var accessibilityLabel: String {
        let detail = title ?? message
        switch severity {
        case .blocked:
            let prefix = switch blockedKind {
            case .permission?: String(localized: "Terminal needs permission")
            case .question?: String(localized: "Terminal has a question")
            case .auth?: String(localized: "Terminal needs authentication")
            case nil: String(localized: "Terminal is blocked")
            }
            return detail.map { "\(prefix): \($0)" } ?? prefix
        case .working:
            var text = String(localized: "Terminal status: working")
            if let progress { text += ", " + String(localized: "\(Int(progress)) percent") }
            if let detail { text += ", \(detail)" }
            return text
        case .idle, .done, .error:
            let state = stateText.lowercased()
            return String(localized: "Terminal status: \(state)") + (detail.map { ", \($0)" } ?? "")
        }
    }

    /// SF Symbol for the state; distinct per state so color is never the
    /// only cue.
    var symbolName: String {
        switch severity {
        case .idle: "pause.circle"
        case .working: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .blocked:
            switch blockedKind {
            case .permission?: "lock.shield.fill"
            case .question?: "questionmark.bubble.fill"
            case .auth?: "key.fill"
            case nil: "exclamationmark.circle.fill"
            }
        }
    }
}

/// A tab's rolled-up program status: what its badge shows.
enum ProgramStatusAttention: Int, Comparable, Sendable {
    case working, done, error, blocked

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Across a tab's panes, focused or not: `blocked` > `error` > unseen
    /// `done` > `working` (each pane's attention already excludes seen
    /// results).
    static func reduce(_ panes: some Sequence<ProgramStatusAttention?>) -> Self? {
        panes.compactMap(\.self).max()
    }

    var symbolName: String {
        switch self {
        case .working: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .blocked: "exclamationmark.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .working: String(localized: "A program is working")
        case .done: String(localized: "A program finished")
        case .error: String(localized: "A program failed")
        case .blocked: String(localized: "A program needs attention")
        }
    }
}

/// Program-provided text is untrusted: plain text only, with bidirectional
/// controls removed so it cannot reorder the surrounding UI text. (Swiftty
/// already rejects C0/C1 controls.)
enum ProgramStatusText {
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isBidiControl($0) }))
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069: true
        default: false
        }
    }
}

/// Deduplicates OSC 7501 notifications per terminal: each record revision
/// notifies at most once, so foreground hydration never repeats one.
struct ProgramStatusNotificationGate {
    private(set) var notifiedRevision: UInt64 = 0

    /// Records newer than the last call that warrant a notification
    /// (`blocked`, `error`, `done`); advances past `snapshot`.
    mutating func newRecords(in snapshot: ProgramStatusSnapshot) -> [ProgramStatusRecord] {
        defer { notifiedRevision = max(notifiedRevision, snapshot.revision) }
        return snapshot.records.filter { $0.revision > notifiedRevision && $0.state != .working && $0.state != .idle }
    }

    /// A different terminal store (new surface) starts over.
    mutating func reset() {
        notifiedRevision = 0
    }
}
