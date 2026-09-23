/// Decides how to handle a missing scrollbar sample. A tmux pane without a
/// surface cannot be queried, so retain its last document until it can be.
/// With a surface, a failed displayed-scrollbar query includes empty history
/// and must reset the document even if it previously contained scrollback.
nonisolated enum TerminalScrollbarAvailabilityPolicy {
    static func preservesExistingDocument(
        isTmuxPane: Bool,
        hasSurface: Bool,
        hasValidSample: Bool
    ) -> Bool {
        isTmuxPane && !hasSurface && hasValidSample
    }
}
