//
//  PanePresentationState.swift
//  shell
//
//  Pane-scoped display identity shared by the split chrome and the tab bar.
//

import Foundation
import Observation

/// Live presentation state for one split leaf.
///
/// A tab can contain multiple panes, so a title cannot be faithfully
/// represented by a single value on `TabModel`. Each `SplitPaneView` owns one
/// stable instance; consumers observe only the pane they render, keeping
/// animated terminal titles local to that pane.
@MainActor
@Observable
final class PanePresentationState {
    let paneID: UUID

    /// Resolved user-facing pane title. Never intentionally empty.
    var title: String

    init(paneID: UUID, title: String = "") {
        self.paneID = paneID
        self.title = title
    }
}
