//
//  TmuxSyncReadiness.swift
//  shell
//
//  Control-mode readiness evidence (docs/specs/mobile-connectivity.md §8.5).
//
//  A recovered tmux session may be reported ready only when the *current*
//  control-mode stream has committed a full topology and the visible pane
//  shows tmux's state. `syncEnd` alone proves topology, not contents; a
//  timer or prompt-shaped output proves nothing. Every viewer event carries
//  the generation of the control-mode stream that produced it, so evidence
//  from a superseded stream can never satisfy a newer one.
//

import Foundation

nonisolated struct TmuxSyncReadiness: Equatable, Sendable {
    /// Generation of the control-mode stream the evidence belongs to.
    private(set) var generation: UInt64 = 0
    private(set) var topologyCommitted = false
    /// The focused pane of the last committed topology.
    private(set) var visiblePane: Int?
    private(set) var syncedPanes: Set<Int> = []

    /// Adopts `newGeneration`, discarding evidence from older streams.
    /// Returns false when the event belongs to a superseded stream.
    @discardableResult
    mutating func observe(generation newGeneration: UInt64) -> Bool {
        if newGeneration < generation {
            return false
        }
        if newGeneration > generation {
            self = TmuxSyncReadiness(generation: newGeneration)
        }
        return true
    }

    /// A full topology batch applied without failure.
    mutating func noteTopologyCommitted(generation newGeneration: UInt64, visiblePane pane: Int?) {
        guard observe(generation: newGeneration) else { return }
        topologyCommitted = true
        if let pane {
            visiblePane = pane
        }
    }

    /// The viewer replayed `pane`'s captured contents.
    mutating func notePaneSynced(_ pane: Int, generation newGeneration: UInt64) {
        guard observe(generation: newGeneration) else { return }
        syncedPanes.insert(pane)
    }

    var isReady: Bool {
        guard topologyCommitted, let visiblePane else { return false }
        return syncedPanes.contains(visiblePane)
    }

    private init(generation: UInt64) {
        self.generation = generation
    }

    init() {}
}
