//
//  TerminalView+ProgramStatus.swift
//  shell
//
//  OSC 7501 program status for one terminal: reads Swiftty's records,
//  derives the pane summary, tracks what the user has seen, and posts
//  informational notifications. Swiftty owns the records; nothing here
//  removes or edits them.
//

import Foundation
import ShellControlProtocol
import SwifttyKit
import UserNotifications

extension Swiftty.TerminalView {
    /// SWIFTTY_ACTION_PROGRAM_STATUS: the records changed. Delivered even
    /// while backgrounded, so notifications see every revision once; the
    /// observed UI state waits for foreground replay.
    func handleProgramStatusChanged() {
        refreshProgramStatus()
    }

    /// Re-reads the records from Swiftty and, unless backgrounded,
    /// recomputes the presentation.
    func refreshProgramStatus() {
        guard let surface else { return }
        let snapshot = swiftty_surface_program_status(surface)
        // A store's revision never goes backwards, so a lower one is a
        // different terminal (a new local or SSH surface): what was seen
        // or notified in the old one says nothing about it.
        if snapshot.revision < programStatusSnapshot.revision {
            programStatusAcknowledgedRevision = 0
            programStatusNotificationGate.reset()
        }
        programStatusSnapshot = snapshot
        notifyProgramStatus(snapshot)
        guard !Swiftty.isAppBackgroundedAtomic else { return }
        recomputeProgramStatusPresentation()
    }

    func recomputeProgramStatusPresentation() {
        let presentation = ProgramStatusPresentation.reduce(
            programStatusSnapshot,
            acknowledgedRevision: programStatusAcknowledgedRevision
        )
        programStatus = presentation
        programStatusAttention = presentation?.attention
    }

    /// The user has seen this terminal's results: deliberate focus, input,
    /// or opening the status details. Only attention changes; a later
    /// `done`/`error` revision is unseen again.
    func acknowledgeProgramStatus() {
        let snapshot = programStatusSnapshot
        guard ProgramStatusPresentation.hasUnseenResult(snapshot, acknowledgedRevision: programStatusAcknowledgedRevision) else { return }
        programStatusAcknowledgedRevision = snapshot.revision
        recomputeProgramStatusPresentation()
    }

    /// A surface was installed or removed. A tmux pane's new surface reads
    /// the pane's existing records, so acknowledgment carries over; a new
    /// store is detected by its revision (see `refreshProgramStatus`).
    func programStatusSurfaceChanged() {
        if surface == nil {
            programStatus = nil
            programStatusAttention = nil
        } else {
            refreshProgramStatus()
        }
    }

    /// The program on this terminal exited or its transport closed; Swiftty
    /// drops the transient records (never inventing done/error). Ordered
    /// after the session output still in the output pipeline, so a report
    /// written just before the exit cannot outlive it.
    func programStatusProgramExited() {
        guard let surface else { return }
        let id = Int(bitPattern: surface)
        outputPipeline.afterPendingOutput { [weak self] in
            Task { @MainActor in
                // The pane may have closed meanwhile; only a live surface.
                guard let self, let surface = self.surface, Int(bitPattern: surface) == id else { return }
                swiftty_surface_program_exited(surface)
            }
        }
    }

    /// Whether the user is looking at this pane right now.
    private var isProgramStatusInView: Bool {
        !Swiftty.isAppBackgroundedAtomic && isTabVisible && isLogicallyFocused
    }

    /// Informational alerts for blocked, error and done records the user is
    /// not looking at; each record revision at most once. A `permission`
    /// alert only informs: it carries no action and approves nothing.
    private func notifyProgramStatus(_ snapshot: ProgramStatusSnapshot) {
        let records = programStatusNotificationGate.newRecords(in: snapshot)
        guard !records.isEmpty, !isProgramStatusInView else { return }
        // The newest record of the most urgent kind.
        let rank: (ProgramStatusRecord) -> Int = { record in
            switch record.state {
            case .blocked: 3
            case .error: 2
            case .done: 1
            case .working, .idle: 0
            }
        }
        guard let record = records.max(by: { (rank($0), $0.revision) < (rank($1), $1.revision) }),
              let presentation = ProgramStatusPresentation.reduce(
                  ProgramStatusSnapshot(records: [record], revision: snapshot.revision),
                  acknowledgedRevision: 0
              ) else { return }
        // Identify the terminal by what Shell knows about it, never by
        // program text, so a program cannot pose as another terminal. The
        // app name may come from an ancestor record, so read it from the
        // whole snapshot.
        let app = snapshot.app(for: record.id).map { " (\(ProgramStatusText.sanitized($0)))" } ?? ""
        ProgramStatusNotifications.post(
            terminal: connectionConfig.displayName,
            body: presentation.label + app,
            identifier: "program-status.\(uuid.uuidString).\(record.id).\(record.revision)"
        )
    }
}

enum ProgramStatusNotifications {
    static func post(terminal: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = DisplaySanitizer.sanitize(terminal, maxScalars: 120).text
        content.body = DisplaySanitizer.sanitize(body, maxScalars: 300).text
        content.categoryIdentifier = PushCategory.informational
        content.threadIdentifier = "program-status"
        // The identifier is terminal + record + revision: a repeated post
        // replaces rather than duplicates.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}
