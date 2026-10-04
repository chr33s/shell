//
//  TmuxSyncReadinessTests.swift
//  ShellTests
//
//  docs/specs/mobile-connectivity.md §7 step 6 and §8.5: control-mode
//  readiness needs a committed topology *and* the visible pane synced, both
//  from the current control-mode stream (CON-02 generation isolation).
//

import Testing
@testable import Shell

@Suite
struct TmuxSyncReadinessTests {

    @Test func topologyAloneIsNotReadiness() {
        var readiness = TmuxSyncReadiness()
        readiness.noteTopologyCommitted(generation: 1, visiblePane: 4)
        #expect(!readiness.isReady)
    }

    @Test func aSyncedPaneAloneIsNotReadiness() {
        var readiness = TmuxSyncReadiness()
        readiness.notePaneSynced(4, generation: 1)
        #expect(!readiness.isReady)
    }

    @Test func committedTopologyPlusSyncedVisiblePaneIsReadyInEitherOrder() {
        var a = TmuxSyncReadiness()
        a.noteTopologyCommitted(generation: 1, visiblePane: 4)
        a.notePaneSynced(4, generation: 1)
        #expect(a.isReady)

        var b = TmuxSyncReadiness()
        b.notePaneSynced(4, generation: 1)
        b.noteTopologyCommitted(generation: 1, visiblePane: 4)
        #expect(b.isReady)
    }

    @Test func onlyTheVisiblePaneCounts() {
        var readiness = TmuxSyncReadiness()
        readiness.noteTopologyCommitted(generation: 1, visiblePane: 4)
        readiness.notePaneSynced(5, generation: 1)
        #expect(!readiness.isReady)
    }

    @Test func aTopologyWithoutFocusIsNotReadiness() {
        var readiness = TmuxSyncReadiness()
        readiness.noteTopologyCommitted(generation: 1, visiblePane: nil)
        readiness.notePaneSynced(4, generation: 1)
        #expect(!readiness.isReady)
    }

    @Test func aNewerStreamDiscardsOlderEvidence() {
        var readiness = TmuxSyncReadiness()
        readiness.noteTopologyCommitted(generation: 1, visiblePane: 4)
        readiness.notePaneSynced(4, generation: 1)
        #expect(readiness.isReady)

        readiness.notePaneSynced(4, generation: 2)
        #expect(readiness.generation == 2)
        #expect(!readiness.isReady)
        readiness.noteTopologyCommitted(generation: 2, visiblePane: 4)
        #expect(readiness.isReady)
    }

    @Test func aSupersededStreamCannotSatisfyANewerOne() {
        var readiness = TmuxSyncReadiness()
        readiness.noteTopologyCommitted(generation: 2, visiblePane: 4)
        let accepted = readiness.observe(generation: 1)
        #expect(!accepted)
        readiness.notePaneSynced(4, generation: 1)
        #expect(!readiness.isReady)
        readiness.noteTopologyCommitted(generation: 1, visiblePane: 9)
        #expect(readiness.visiblePane == 4)
    }
}
