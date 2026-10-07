import Foundation
import SwifttyKit
import Testing

@testable import Shell

/// OSC 7501 presentation: pane summary, acknowledgment, tab rollup and
/// notification dedup, all derived from Swiftty's snapshot.
@MainActor
@Suite
struct ProgramStatusPresentationTests {
    private func record(
        _ id: String, _ state: ProgramStatusState, revision: UInt64,
        kind: ProgramStatusBlockedKind? = nil, progress: UInt8? = nil,
        app: String? = nil, title: String? = nil, message: String? = nil
    ) -> ProgramStatusRecord {
        ProgramStatusRecord(id: id, state: state, kind: kind, progress: progress, app: app, title: title, message: message, revision: revision)
    }

    private func snapshot(_ records: ProgramStatusRecord...) -> ProgramStatusSnapshot {
        ProgramStatusSnapshot(records: records, revision: records.map(\.revision).max() ?? 0)
    }

    private func summary(_ s: ProgramStatusSnapshot, seen: UInt64 = 0) -> ProgramStatusPresentation? {
        ProgramStatusPresentation.reduce(s, acknowledgedRevision: seen)
    }

    @Test func emptySnapshotShowsNothing() {
        #expect(summary(.empty) == nil)
    }

    @Test func eachStateMapsToItsSeverity() {
        let cases: [(ProgramStatusState, ProgramStatusPresentation.Severity)] = [
            (.idle, .idle), (.working, .working), (.done, .done), (.error, .error), (.blocked, .blocked),
        ]
        for (state, severity) in cases {
            #expect(summary(snapshot(record("", state, revision: 1)))?.severity == severity)
        }
    }

    @Test func fieldsComeFromThePrimaryRecord() throws {
        let s = snapshot(
            record("build", .working, revision: 1, app: "make"),
            record("build/test", .blocked, revision: 2, kind: .permission, progress: 40, title: "Apply changes?", message: "3 files")
        )
        let p = try #require(summary(s))
        #expect(p.primaryRecordID == "build/test")
        #expect(p.blockedKind == .permission)
        #expect(p.progress == 40)
        #expect(p.app == "make") // inherited from the parent record
        #expect(p.title == "Apply changes?")
        #expect(p.message == "3 files")
        #expect(p.revision == 2)
        #expect(p.activeRecordCount == 2)
        #expect(!p.requiresAcknowledgment)
    }

    @Test func blockedBeatsErrorDoneAndWorking() {
        let s = snapshot(
            record("a", .blocked, revision: 1),
            record("b", .error, revision: 2),
            record("c", .done, revision: 3),
            record("d", .working, revision: 4)
        )
        #expect(summary(s)?.primaryRecordID == "a")
    }

    @Test func errorBeatsUnseenDoneAndWorking() {
        let s = snapshot(record("e", .error, revision: 1), record("d", .done, revision: 2), record("w", .working, revision: 3))
        #expect(summary(s)?.severity == .error)
        #expect(summary(s)?.requiresAcknowledgment == true)
    }

    @Test func newestRecordWinsWithinALevel() {
        let s = snapshot(record("old", .working, revision: 1), record("new", .working, revision: 2))
        #expect(summary(s)?.primaryRecordID == "new")
    }

    @Test func progressIsNeverAggregated() {
        let s = snapshot(record("a", .working, revision: 1, progress: 10), record("b", .working, revision: 2))
        #expect(summary(s)?.progress == nil)
    }

    @Test func acknowledgedResultsDropOutAndNewRevisionsReturn() {
        let done = snapshot(record("x", .done, revision: 3), record("w", .working, revision: 2))
        #expect(summary(done)?.severity == .done)
        #expect(ProgramStatusPresentation.hasUnseenResult(done, acknowledgedRevision: 0))
        // Seen: working shows again; the done record stays in Swiftty.
        #expect(summary(done, seen: 3)?.severity == .working)
        #expect(!ProgramStatusPresentation.hasUnseenResult(done, acknowledgedRevision: 3))
        // A later done revision is unseen again.
        let again = snapshot(record("w", .working, revision: 2), record("x", .done, revision: 5))
        #expect(summary(again, seen: 3)?.severity == .done)
    }

    @Test func tabRollupAcrossPanes() {
        #expect(ProgramStatusAttention.reduce([nil, .working, .done]) == .done)
        #expect(ProgramStatusAttention.reduce([.done, .error, .working]) == .error)
        #expect(ProgramStatusAttention.reduce([.error, .blocked]) == .blocked)
        #expect(ProgramStatusAttention.reduce([nil, nil]) == nil)
        // Idle draws no attention; a seen done contributes nothing.
        #expect(summary(snapshot(record("", .idle, revision: 1)))?.attention == nil)
        #expect(summary(snapshot(record("", .done, revision: 1)), seen: 1)?.attention == nil)
    }

    @Test func labelsAndAccessibilityAreTextual() throws {
        let working = try #require(summary(snapshot(record("", .working, revision: 1, progress: 42))))
        #expect(working.label == "Working — 42%")
        #expect(working.accessibilityLabel == "Terminal status: working, 42 percent")
        let permission = try #require(summary(snapshot(record("", .blocked, revision: 1, kind: .permission, title: "Apply changes?"))))
        #expect(permission.label == "Needs permission — Apply changes?")
        #expect(permission.accessibilityLabel == "Terminal needs permission: Apply changes?")
        let question = try #require(summary(snapshot(record("", .blocked, revision: 1, kind: .question, message: "Choose deployment region"))))
        #expect(question.label == "Question — Choose deployment region")
        let auth = try #require(summary(snapshot(record("", .blocked, revision: 1, kind: .auth))))
        #expect(auth.label == "Authentication required")
        let failed = try #require(summary(snapshot(record("", .error, revision: 1, title: "Deployment failed"))))
        #expect(failed.label == "Error — Deployment failed")
        #expect(failed.accessibilityLabel == "Terminal status: error, Deployment failed")
        // Every state has its own symbol, so color is never the only cue.
        let symbols = Set([working, permission, question, auth, failed].map(\.symbolName))
        #expect(symbols.count == 5)
    }

    @Test func programTextIsPlainAndCannotReorderUI() throws {
        let s = snapshot(record("", .error, revision: 1, title: "\u{202E}deliaf\u{202C} <b>x</b>"))
        let p = try #require(summary(s))
        #expect(p.title == "deliaf <b>x</b>")
    }

    @Test func notificationsFireOncePerRevision() {
        var gate = ProgramStatusNotificationGate()
        let first = snapshot(record("w", .working, revision: 1), record("b", .blocked, revision: 2))
        #expect(gate.newRecords(in: first).map(\.id) == ["b"])
        // Hydration of the same snapshot is not news.
        #expect(gate.newRecords(in: first).isEmpty)
        let second = snapshot(record("w", .working, revision: 1), record("b", .blocked, revision: 2), record("d", .done, revision: 3))
        #expect(gate.newRecords(in: second).map(\.id) == ["d"])
    }
}
