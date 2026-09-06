//
//  SerializableSplitTree.swift
//  shell
//
//  Codable representation of a split tree for state persistence.
//  Captures tree structure and connection configs without UIView references.
//

import Foundation

/// Codable representation of a split tree for state persistence
nonisolated struct SerializableSplitTree: Codable, Equatable, Sendable {
    let root: SerializableNode?
    let zoomedPath: [PathComponent]?  // Path to zoomed node (if any)

    nonisolated enum PathComponent: String, Codable, Sendable {
        case left
        case right
    }

    nonisolated indirect enum SerializableNode: Codable, Equatable, Sendable {
        case leaf(LeafData)
        case split(SplitData)

        nonisolated struct LeafData: Codable, Equatable, Sendable {
            /// Original terminal UUID (for matching focused terminal)
            let terminalId: UUID

            /// Connection configuration for this terminal
            let connectionConfig: SerializableConnectionConfig

            /// User-overridden title (if any)
            let userOverrideTitle: String?

            /// Last known working directory (for local shells)
            let lastKnownWorkingDirectory: String?

            /// Profile that created this terminal (if any)
            let sourceProfileID: UUID?

            /// Absolute per-surface font size override set by keyboard or
            /// pinch zoom. Nil means this terminal follows the global font.
            let fontSizeOverride: Double?

            /// For trzsz attachable sessions: the most recent moment the
            /// client was confirmed connected to the server. Used on resume
            /// to decide whether the server is still within its 24h
            /// `AliveTimeout` window. `nil` for non-trzsz terminals or
            /// sessions that have never connected.

            /// True when this terminal was running a live `tmux -CC` control-mode
            /// gateway at save time (its `tmuxController` was non-nil). On
            /// restore, once this terminal's tssh session resumes the live pty,
            /// the app calls `ghostty_surface_tmux_resume` to re-enter control
            /// mode and reproject the tmux window tabs. Optional so older saved
            /// state (without the key) decodes as `nil` (= not a gateway).
            let wasTmuxGateway: Bool?

            /// True when the user cancelled restored tmux recovery before the
            /// resumed pty was ready to accept `tmux_resume_abort`. On restore,
            /// the gateway still enters tmux-resume handling, then aborts
            /// immediately so raw control-mode output is not exposed.
            let tmuxResumeCancelRequested: Bool?
        }

        nonisolated struct SplitData: Codable, Equatable, Sendable {
            let direction: Direction
            let ratio: Double
            let left: SerializableNode
            let right: SerializableNode
        }

        nonisolated enum Direction: String, Codable, Sendable {
            case horizontal
            case vertical
        }
    }

    /// Create an empty tree
    init() {
        self.root = nil
        self.zoomedPath = nil
    }

    /// Create from root and zoomed path
    init(root: SerializableNode?, zoomedPath: [PathComponent]?) {
        self.root = root
        self.zoomedPath = zoomedPath
    }

    /// Whether the tree is empty
    var isEmpty: Bool {
        root == nil
    }

    /// Get all terminal IDs in the tree (in order)
    var allTerminalIds: [UUID] {
        guard let root = root else { return [] }
        return root.allTerminalIds
    }

    /// Get all leaf data in the tree (in order)
    var allLeaves: [SerializableNode.LeafData] {
        guard let root = root else { return [] }
        return root.allLeaves
    }
}

// MARK: - Node Operations

nonisolated extension SerializableSplitTree.SerializableNode {
    /// Get all terminal IDs in this subtree
    var allTerminalIds: [UUID] {
        switch self {
        case .leaf(let data):
            return [data.terminalId]
        case .split(let data):
            return data.left.allTerminalIds + data.right.allTerminalIds
        }
    }

    /// Get all leaf data in this subtree
    var allLeaves: [SerializableSplitTree.SerializableNode.LeafData] {
        switch self {
        case .leaf(let data):
            return [data]
        case .split(let data):
            return data.left.allLeaves + data.right.allLeaves
        }
    }
}

// MARK: - SplitTree Extension for Serialization

extension SplitTree where ViewType == SplitPaneView {

    /// Serialize this split tree to a Codable representation
    @MainActor
    func serialize() -> SerializableSplitTree {
        guard let root = self.root, let serializedRoot = serializeNode(root) else {
            return SerializableSplitTree()
        }

        // Serialize zoomed path if present
        var zoomedPath: [SerializableSplitTree.PathComponent]? = nil
        if let zoomed = self.zoomed {
            zoomedPath = pathToNode(zoomed)
        }

        return SerializableSplitTree(root: serializedRoot, zoomedPath: zoomedPath)
    }

    /// Rebuild a tree around a restored `root`, re-applying the zoom that
    /// `serialize()` recorded as `zoomedPath`. The inverse of the
    /// `pathToNode(zoomed)` capture above, so a pane left zoomed at quit comes
    /// back zoomed.
    ///
    /// The saved path is relative to the SERIALIZED root, and restoration
    /// rebuilds that same shape node-for-node (a leaf that can't be rebuilt
    /// fails the whole tab rather than collapsing one branch), so the
    /// components line up. `node(at:)` returns nil for a path that no longer
    /// resolves — state written against a different tree shape, or a truncated
    /// path — and the tree then restores un-zoomed instead of trapping.
    ///
    /// An EMPTY path is not "no zoom": it is the root itself zoomed (what
    /// zooming a sole pane records), which `node(at:)` resolves back to `root`.
    init(root: Node, restoringZoomedPath zoomedPath: [SerializableSplitTree.PathComponent]?) {
        let zoomed: Node? = zoomedPath.flatMap { saved in
            let components = saved.map { component -> Path.Component in
                switch component {
                case .left: return .left
                case .right: return .right
                }
            }
            return root.node(at: Path(path: components))
        }
        self.init(root: root, zoomed: zoomed)
    }

    /// Serialize a single node. Returns nil for leaves that cannot be
    /// serialized; a split with one serializable child collapses to that
    /// child.
    @MainActor
    private func serializeNode(_ node: Node) -> SerializableSplitTree.SerializableNode? {
        switch node {
        case .leaf(let pane):
            // Genuinely unknown pane kinds are skipped (never crash) so the
            // rest of the tab still persists.
            guard let view = pane.asTerminal else { return nil }

            // connectionConfig is kept up to date at runtime (including the
            // shell-launched SSH transition), so we can serialize it directly.
            let configToSerialize = view.connectionConfig
            let cwd: String? = if case .local = view.connectionConfig { view.pwd } else { nil }

            let leafData = SerializableSplitTree.SerializableNode.LeafData(
                terminalId: view.uuid,
                connectionConfig: SerializableConnectionConfig(from: configToSerialize),
                userOverrideTitle: view.userOverrideTitle,
                lastKnownWorkingDirectory: cwd,
                sourceProfileID: view.sourceProfileID,
                fontSizeOverride: view.fontSizeOverride,
                // A non-nil tmuxController means this leaf is the live tmux -CC
                // control-mode gateway. tmux is the source of remote session
                // persistence: on relaunch the SSH connection is re-established
                // and control mode re-entered (see maybeResumeTmuxControlMode).
                // A local-shell gateway has nothing to reconnect to, so it is
                // never flagged for resume.
                //
                // Also persist the flag for a RESTORED gateway that hasn't resumed
                // yet (controller still nil during the reconnect window): the
                // placeholder window tabs can be persisted during the reconnect
                // window, so without this resume-pending state an autosave there
                // would save placeholders WITHOUT their gateway resume flag —
                // stranding them as "Reconnecting tmux…" tabs forever on the next
                // launch. (id=tmux-resume-flag-symmetric)
                wasTmuxGateway: (
                    view.tmuxController != nil
                    || view.restoredWasTmuxGateway
                    || view.tmuxResumeRequested
                    || view.tmuxResumeCancelRequested
                ) && view.connectionConfig.sshConfig != nil,
                tmuxResumeCancelRequested: view.tmuxResumeCancelRequested ? true : nil
            )
            return .leaf(leafData)

        case .split(let split):
            let direction: SerializableSplitTree.SerializableNode.Direction =
                split.direction == .horizontal ? .horizontal : .vertical

            let left = serializeNode(split.left)
            let right = serializeNode(split.right)
            switch (left, right) {
            case let (left?, right?):
                return .split(SerializableSplitTree.SerializableNode.SplitData(
                    direction: direction,
                    ratio: split.ratio,
                    left: left,
                    right: right
                ))
            case let (left?, nil):
                return left
            case let (nil, right?):
                return right
            case (nil, nil):
                return nil
            }
        }
    }

    /// Find the path to a specific node
    func pathToNode(_ target: Node) -> [SerializableSplitTree.PathComponent]? {
        guard let root = self.root else { return nil }
        return findPath(from: root, to: target)
    }

    private func findPath(from current: Node, to target: Node) -> [SerializableSplitTree.PathComponent]? {
        if current == target {
            return []
        }

        switch current {
        case .leaf:
            return nil

        case .split(let split):
            // Try left
            if let leftPath = findPath(from: split.left, to: target) {
                return [.left] + leftPath
            }
            // Try right
            if let rightPath = findPath(from: split.right, to: target) {
                return [.right] + rightPath
            }
            return nil
        }
    }
}
